import Foundation
import Testing

@Suite("SecretSync shipping linkage audit")
struct SecretSyncShippingLinkageAuditTests {
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

  private func tool(_ path: String, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ShippingLinkageAuditError.toolFailed(String(decoding: data, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
  }

  private func demangledSymbols(in executable: URL) throws -> String {
    let nm = Process()
    let demangle = Process()
    let symbols = Pipe()
    let output = Pipe()
    nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
    nm.arguments = ["-gj", executable.path]
    nm.standardOutput = symbols
    demangle.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    demangle.arguments = ["swift-demangle"]
    demangle.standardInput = symbols
    demangle.standardOutput = output
    try demangle.run()
    try nm.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    nm.waitUntilExit()
    demangle.waitUntilExit()
    guard nm.terminationStatus == 0, demangle.terminationStatus == 0 else {
      throw ShippingLinkageAuditError.toolFailed("nm/swift-demangle pipeline failed")
    }
    return String(decoding: data, as: UTF8.self)
  }
}

private enum ShippingLinkageAuditError: Error {
  case toolFailed(String)
  case buildArtifactMissing(String)
}
