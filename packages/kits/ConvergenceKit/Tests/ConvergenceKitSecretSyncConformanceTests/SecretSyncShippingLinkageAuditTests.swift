import ConvergenceKit
import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
import Foundation
import Testing

@Suite("SecretSync shipping linkage audit")
struct SecretSyncShippingLinkageAuditTests {
#if os(macOS)
  @Test("built conformance product contains production SecretSync symbols only")
  func builtProductSymbolAudit() throws {
    let buildRoot = try buildRoot()
    let executable = buildRoot.appendingPathComponent(
      "Products/Debug/ConvergenceKitSecretSyncConformanceTests.xctest/Contents/MacOS/ConvergenceKitSecretSyncConformanceTests"
    )
    let symbols = try demangledSymbols(in: executable)

    for required in [
      "SecretSyncSecureEnclaveCustody",
      "SecretSyncV1CryptoProvider",
      "SecretPolicyValidator",
      "SecretSyncCloudKitPolicyStore",
      "SecretSyncHeadCAS",
    ] {
      #expect(symbols.contains(required), "missing production symbol \(required)")
    }
    for forbidden in [
      "SecretSyncTestOnlyCustodyProvider",
      "TestOnlyCustodyProvider",
      "ConvergenceKitAppleSecurityTests",
    ] {
      #expect(!symbols.contains(forbidden), "test-only symbol linked: \(forbidden)")
    }
  }

  @Test("linker input list admits production modules and excludes provider tests")
  func productionLinkerInputs() throws {
    let buildRoot = try buildRoot()
    let linkLists = try FileManager.default.subpathsOfDirectory(atPath: buildRoot.path)
      .filter { $0.hasSuffix(".LinkFileList") }
      .map { buildRoot.appendingPathComponent($0) }
      .filter { url in
        (try? String(contentsOf: url, encoding: .utf8))?.contains(
          "ConvergenceKitSecretSyncConformanceTests"
        ) == true
      }
    let linkList = try #require(linkLists.first)
    let inputs = try String(contentsOf: linkList, encoding: .utf8)

    #expect(inputs.contains("/Products/Debug/ConvergenceKit.o"))
    #expect(inputs.contains("/Products/Debug/ConvergenceKitAppleSecurity.o"))
    #expect(inputs.contains("/Products/Debug/ConvergenceKitCloudKit.o"))
    #expect(!inputs.contains("ConvergenceKitAppleSecurityTests.build"))
    #expect(!inputs.contains("SecretSyncTestOnlyCustodyProvider"))
  }

  private func buildRoot() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = packageRoot.appendingPathComponent(".build/out")
    guard FileManager.default.fileExists(atPath: root.path) else {
      throw ShippingLinkageAuditError.buildArtifactMissing(root.path)
    }
    return root
  }

  private func demangledSymbols(in executable: URL) throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("u7-shipping-audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let rawURL = directory.appendingPathComponent("symbols.raw")
    let demangledURL = directory.appendingPathComponent("symbols.demangled")
    FileManager.default.createFile(atPath: rawURL.path, contents: nil)
    FileManager.default.createFile(atPath: demangledURL.path, contents: nil)

    let nm = Process()
    nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
    nm.arguments = ["-gj", executable.path]
    nm.standardOutput = try FileHandle(forWritingTo: rawURL)
    nm.standardError = FileHandle.nullDevice
    try nm.run()
    nm.waitUntilExit()
    guard nm.terminationStatus == 0 else {
      throw ShippingLinkageAuditError.toolFailed("nm failed")
    }

    let demangle = Process()
    demangle.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    demangle.arguments = ["swift-demangle"]
    demangle.standardInput = try FileHandle(forReadingFrom: rawURL)
    demangle.standardOutput = try FileHandle(forWritingTo: demangledURL)
    demangle.standardError = FileHandle.nullDevice
    try demangle.run()
    demangle.waitUntilExit()
    guard demangle.terminationStatus == 0 else {
      throw ShippingLinkageAuditError.toolFailed("swift-demangle failed")
    }
    return try String(contentsOf: demangledURL, encoding: .utf8)
  }
#else
  @Test("non-macOS product compiles and links every production SecretSync owner")
  func productionOwnersCompileAndLink() throws {
    let suite = try U7GoldenVectors.suite()
    _ = SecretSyncSecureEnclaveCustody.self
    _ = try SecretSyncV1CryptoProvider(suite: suite)
    _ = SecretPolicyValidator.self
    _ = SecretSyncCloudKitPolicyStore.self
    _ = SecretSyncHeadCAS.self
  }
#endif
}

#if os(macOS)
private enum ShippingLinkageAuditError: Error {
  case toolFailed(String)
  case buildArtifactMissing(String)
}
#endif
