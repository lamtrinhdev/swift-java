//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift.org project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import SwiftBasicFormat
import SwiftParser
import SwiftSyntax

/// Takes swift interfaces and translates them into Java used to access those.
public final class Swift2JavaTranslator {
  static let SWIFT_INTERFACE_SUFFIX = ".swiftinterface"

  public var log = Logger(label: "translator", logLevel: .info)

  // ==== Input configuration
  let swiftModuleName: String

  // ==== Output configuration
  let javaPackage: String

  var javaPackagePath: String {
    javaPackage.replacingOccurrences(of: ".", with: "/")
  }

  // ==== Output state

  // TODO: consider how/if we need to store those etc
  public var importedGlobalFuncs: [ImportedFunc] = []

  /// A mapping from Swift type names (e.g., A.B) over to the imported nominal
  /// type representation.
  public var importedTypes: [String: ImportedNominalType] = [:]

  let nominalResolution: NominalTypeResolution = NominalTypeResolution()

  public init(
    javaPackage: String,
    swiftModuleName: String
  ) {
    self.javaPackage = javaPackage
    self.swiftModuleName = swiftModuleName
  }
}

// ===== --------------------------------------------------------------------------------------------------------------
// MARK: Analysis

extension Swift2JavaTranslator {
  public func analyze(
    swiftInterfacePath: String,
    text: String? = nil
  ) async throws {
    if text == nil {
      precondition(
        swiftInterfacePath.hasSuffix(Self.SWIFT_INTERFACE_SUFFIX),
        "Swift interface path must end with \(Self.SWIFT_INTERFACE_SUFFIX), was: \(swiftInterfacePath)"
      )

      if !FileManager.default.fileExists(atPath: swiftInterfacePath) {
        throw Swift2JavaTranslatorError(message: "Missing input file: \(swiftInterfacePath)")
      }
    }

    log.trace("Analyze: \(swiftInterfacePath)")
    let text = try text ?? String(contentsOfFile: swiftInterfacePath)

    try await analyzeSwiftInterface(interfaceFilePath: swiftInterfacePath, text: text)

    log.info("Done processing: \(swiftInterfacePath)")
  }

  package func analyzeSwiftInterface(interfaceFilePath: String, text: String) async throws {
    assert(interfaceFilePath.hasSuffix(Self.SWIFT_INTERFACE_SUFFIX))

    let sourceFileSyntax = Parser.parse(source: text)

    // Find all of the types and extensions, then bind the extensions.
    nominalResolution.addSourceFile(sourceFileSyntax)
    nominalResolution.bindExtensions()

    let visitor = Swift2JavaVisitor(
      moduleName: self.swiftModuleName,
      targetJavaPackage: self.javaPackage,
      translator: self
    )
    visitor.walk(sourceFileSyntax)

    try await self.postProcessImportedDecls()
  }

  public func postProcessImportedDecls() async throws {
    log.info(
      "Post process imported decls...",
      metadata: [
        "types": "\(importedTypes.count)",
        "global/funcs": "\(importedGlobalFuncs.count)",
      ]
    )

    // FIXME: the use of dylibs to get symbols is a hack we need to remove and replace with interfaces containing mangled names
    let dylibPath = ".build/arm64-apple-macosx/debug/lib\(swiftModuleName).dylib"
    guard var dylib = SwiftDylib(path: dylibPath) else {
      log.warning(
        """
        Unable to find mangled names for imported symbols. Dylib not found: \(dylibPath) This method of obtaining symbols is a workaround; it will be removed.
        """
      )
      return
    }

    importedGlobalFuncs = try await importedGlobalFuncs._mapAsync { funcDecl in
      let funcDecl = try await dylib.fillInMethodMangledName(funcDecl)
      log.info("Mapped method '\(funcDecl.identifier)' -> '\(funcDecl.swiftMangledName)'")
      return funcDecl
    }

    importedTypes = Dictionary(uniqueKeysWithValues: try await importedTypes._mapAsync { (tyName, tyDecl) in
      var tyDecl = tyDecl
      log.info("Mapping type: \(tyDecl.name)")

      tyDecl = try await dylib.fillInTypeMangledName(tyDecl)

      log.info("Mapping members of: \(tyDecl.name)")
      tyDecl.initializers = try await tyDecl.initializers._mapAsync { initDecl in
        dylib.log.logLevel = .trace

        let initDecl = try await dylib.fillInAllocatingInitMangledName(initDecl)
        log.info("Mapped initializer '\(initDecl.identifier)' -> '\(initDecl.swiftMangledName)'")
        return initDecl
      }

      tyDecl.methods = try await tyDecl.methods._mapAsync { funcDecl in
        let funcDecl = try await dylib.fillInMethodMangledName(funcDecl)
        log.info("Mapped method '\(funcDecl.identifier)' -> '\(funcDecl.swiftMangledName)'")
        return funcDecl
      }

      return (tyName, tyDecl)
    })
  }
}

// ===== --------------------------------------------------------------------------------------------------------------
// MARK: Defaults

extension Swift2JavaTranslator {
  /// Default formatting options.
  static let defaultFormat = BasicFormat(indentationWidth: .spaces(2))

  /// Default set Java imports for every generated file
  static let defaultJavaImports: Array<String> = [
    // Support library in Java
    "org.swift.javakit.SwiftKit",

    // Necessary for native calls and type mapping
    "java.lang.foreign.*",
    "java.lang.invoke.*",
    "java.util.Arrays",
    "java.util.stream.Collectors",
    "java.nio.charset.StandardCharsets",
  ]

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public struct Swift2JavaTranslatorError: Error {
  let message: String

  public init(message: String) {
    self.message = message
  }
}
