import ConvergenceKit
import ConvergenceKitAppleSecurity
import ConvergenceKitCloudKit
import Foundation
import Testing

@Suite("SecretSync shipping linkage audit")
struct SecretSyncShippingLinkageAuditTests {
  @Test("conformance target links all three public production leaves")
  func productionLeavesAreLinked() throws {
    let suite = try U7GoldenVectors.suite()
    let provider = try SecretSyncV1CryptoProvider(suite: suite)

    #expect(
      String(reflecting: type(of: provider.digestProvider))
        == "ConvergenceKitAppleSecurity.SecretSyncSHA256DigestProvider"
    )
    #expect(String(reflecting: SecretPolicyValidator.self).hasPrefix("ConvergenceKit."))
    #expect(
      String(reflecting: SecretSyncSecureEnclaveCustody.self)
        .hasPrefix("ConvergenceKitAppleSecurity.")
    )
    #expect(
      String(reflecting: SecretSyncCloudKitPolicyStore.self)
        .hasPrefix("ConvergenceKitCloudKit.")
    )
    #expect(
      String(reflecting: SecretSyncHeadCAS.self)
        .hasPrefix("ConvergenceKitCloudKit.")
    )
  }

  @Test("package graph preserves product direction and isolates test custody")
  func manifestAndSourceIsolation() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let manifest = try String(
      contentsOf: packageRoot.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )
    let targetBlock = try #require(
      manifest.range(of: ".testTarget(\n            name: \"ConvergenceKitSecretSyncConformanceTests\"")
    )
    let targetSuffix = manifest[targetBlock.lowerBound...]

    #expect(targetSuffix.contains("\"ConvergenceKit\""))
    #expect(targetSuffix.contains("\"ConvergenceKitAppleSecurity\""))
    #expect(targetSuffix.contains("\"ConvergenceKitCloudKit\""))
    #expect(!manifest.contains("SecretSyncTestOnlyCustodyProvider.swift"))

    let productionRoot = packageRoot.appendingPathComponent("Sources")
    let productionFiles = try FileManager.default.subpathsOfDirectory(
      atPath: productionRoot.path
    )
    #expect(
      productionFiles.allSatisfy {
        !$0.contains("TestOnlyCustodyProvider")
          && !$0.contains("ConformanceTests")
      }
    )
    let testProvider = packageRoot.appendingPathComponent(
      "Tests/ConvergenceKitAppleSecurityTests/SecretSyncTestOnlyCustodyProvider.swift"
    )
    #expect(FileManager.default.fileExists(atPath: testProvider.path))
  }

  @Test("frozen live constants match production CloudKit linkage")
  func liveConstantsMatchProduction() {
    #expect(
      SecretSyncLiveCloudKitProofConfiguration.canonicalContainerIdentifier
        == "iCloud.com.codedaptive.simplemachines"
    )
    #expect(
      SecretSyncCloudKitZones.controlZoneName == "moot-secret-control-v1"
    )
    #expect(
      SecretSyncCloudKitZones.payloadZoneName == "moot-secret-payload-v1"
    )
    #expect(
      SecretSyncCloudKitZoneRole.allCases.allSatisfy {
        !$0.presenceGrantsAuthorization
      }
    )
  }
}
