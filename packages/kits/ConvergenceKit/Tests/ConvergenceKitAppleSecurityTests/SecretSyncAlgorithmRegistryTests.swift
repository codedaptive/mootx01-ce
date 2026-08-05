import Foundation
import Testing
@testable import ConvergenceKitAppleSecurity

@Suite("SecretSync closed algorithm registry")
struct SecretSyncAlgorithmRegistryTests {
    @Test("v1 freezes the ratified suite and every component identifier")
    func frozenV1TupleIsExact() throws {
        #expect(SecretSyncAlgorithmRegistry.suiteID == 0x0001)
        #expect(
            SecretSyncAlgorithmRegistry.suiteName
                == "mootx01.secret-sync.hpke-p256-aesgcm-sha256.v1"
        )
        #expect(SecretSyncAlgorithmRegistry.version == 1)
        #expect(SecretSyncAlgorithmRegistry.digestAlgorithm == "sha256")
        #expect(
            SecretSyncAlgorithmRegistry.signatureAlgorithm
                == "ecdsa-p256-sha256-raw64"
        )
        #expect(
            SecretSyncAlgorithmRegistry.publicKeyEncoding
                == "p256-x963-uncompressed"
        )
        #expect(
            SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm
                == "hpke-p256-hkdf-sha256-aesgcm256-base"
        )
        #expect(
            SecretSyncAlgorithmRegistry.payloadAlgorithm
                == "aes-gcm-256-nonce12-tag16"
        )

        let suite = try SecretSyncAlgorithmRegistry.resolve(
            exactIdentifiers(),
            availability: .available
        )
        #expect(suite.suiteID == SecretSyncAlgorithmRegistry.suiteID)
        #expect(suite.suiteName == SecretSyncAlgorithmRegistry.suiteName)
        #expect(suite.version == SecretSyncAlgorithmRegistry.version)
        #expect(
            suite.digestAlgorithm
                == SecretSyncAlgorithmRegistry.digestAlgorithm
        )
        #expect(
            suite.signatureAlgorithm
                == SecretSyncAlgorithmRegistry.signatureAlgorithm
        )
        #expect(
            suite.publicKeyEncoding
                == SecretSyncAlgorithmRegistry.publicKeyEncoding
        )
        #expect(
            suite.keyEnvelopeAlgorithm
                == SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm
        )
        #expect(
            suite.payloadAlgorithm
                == SecretSyncAlgorithmRegistry.payloadAlgorithm
        )
    }

    @Test("case, whitespace, prefixes, suffixes, and trailing bytes reject")
    func textualNearMatchesReject() {
        let suiteName = SecretSyncAlgorithmRegistry.suiteName
        let digest = SecretSyncAlgorithmRegistry.digestAlgorithm

        expectUnsupported(
            identifiers(suiteName: suiteName.uppercased())
        )
        expectUnsupported(identifiers(digest: digest.uppercased()))
        expectUnsupported(identifiers(suiteName: " \(suiteName)"))
        expectUnsupported(identifiers(suiteName: "\(suiteName) "))
        expectUnsupported(identifiers(suiteName: "prefix.\(suiteName)"))
        expectUnsupported(identifiers(suiteName: "\(suiteName).extra"))

        var nulTerminated = bytes(suiteName)
        nulTerminated.append(0)
        expectUnsupported(
            identifiers(suiteNameUTF8: nulTerminated)
        )
    }

    @Test("Unicode lookalikes and alternate suite spellings reject")
    func unicodeAndAliasesReject() {
        expectUnsupported(
            identifiers(
                suiteName:
                    "mootx01.secret-sync.hpke-p２56-aesgcm-sha256.v1"
            )
        )
        expectUnsupported(
            identifiers(
                suiteName:
                    "mootx01.secret-sync.hpke-p256-aesgcm-sha\u{0301}256.v1"
            )
        )
        expectUnsupported(
            identifiers(
                suiteName:
                    "mootx01.secret-sync.p256-aesgcm-sha256.v1"
            )
        )
        expectUnsupported(identifiers(digest: "sha-256"))
        expectUnsupported(identifiers(signature: "ecdsa-p256-sha256"))
        expectUnsupported(identifiers(publicKeyEncoding: "p256-x963"))
        expectUnsupported(
            identifiers(
                keyEnvelope: "hpke-p256-sha256-aesgcm256"
            )
        )
        expectUnsupported(
            identifiers(payload: "aes256-gcm")
        )
    }

    @Test("unknown suite and version numeric boundaries reject")
    func unknownNumericValuesReject() {
        for suiteID: UInt16 in [0, 2, .max] {
            expectUnsupported(identifiers(suiteID: suiteID))
        }
        for version: UInt16 in [0, 2, .max] {
            expectUnsupported(identifiers(version: version))
        }
    }

    @Test("every component mismatch rejects the complete tuple atomically")
    func componentMismatchesRejectAtomically() {
        let mismatches = [
            identifiers(digest: "sha512"),
            identifiers(signature: "ecdsa-p384-sha384-raw96"),
            identifiers(publicKeyEncoding: "p384-x963-uncompressed"),
            identifiers(
                keyEnvelope: "hpke-p384-hkdf-sha384-aesgcm256-base"
            ),
            identifiers(payload: "aes-gcm-128-nonce12-tag16"),
        ]
        for mismatch in mismatches {
            expectUnsupported(mismatch)
        }
    }

    @Test("unavailable exact suite fails closed without selecting another")
    func unavailableExactSuiteRejects() {
        do {
            _ = try SecretSyncAlgorithmRegistry.resolve(
                exactIdentifiers(),
                availability: .unavailable
            )
            Issue.record("an unavailable suite was accepted")
        } catch let error as SecretSyncAppleSecurityError {
            #expect(error == .suiteUnavailable)
        } catch {
            Issue.record("registry threw an unexpected error type")
        }
    }

    @Test("registry errors are payload-free stable cases")
    func errorsCarryNoAssociatedValues() {
        let errors: [SecretSyncAppleSecurityError] = [
            .unsupportedSuite,
            .suiteUnavailable,
        ]
        for error in errors {
            #expect(Mirror(reflecting: error).children.isEmpty)
        }
        #expect(
            SecretSyncAppleSecurityError.unsupportedSuite
                == .unsupportedSuite
        )
    }

    @Test("manifest preserves leaf isolation and test-only conformance edges")
    func dependencyEdgesAreExact() throws {
        let manifest = try packageManifest()

        #expect(
            manifest.contains(
                """
                .library(
                            name: "ConvergenceKitAppleSecurity",
                            targets: ["ConvergenceKitAppleSecurity"]
                        )
                """
            )
        )
        #expect(
            manifest.contains(
                """
                .target(
                            name: "ConvergenceKitAppleSecurity",
                            dependencies: [
                                "ConvergenceKit",
                            ],
                            path: "Sources/ConvergenceKitAppleSecurity"
                        )
                """
            )
        )
        #expect(
            manifest.contains(
                """
                .testTarget(
                            name: "ConvergenceKitAppleSecurityTests",
                            dependencies: [
                                "ConvergenceKitAppleSecurity",
                                "ConvergenceKit",
                            ],
                            path: "Tests/ConvergenceKitAppleSecurityTests"
                        )
                """
            )
        )
        #expect(
            manifest.contains(
                """
                .testTarget(
                            name: "ConvergenceKitSecretSyncConformanceTests",
                            dependencies: [
                                "ConvergenceKit",
                                "ConvergenceKitAppleSecurity",
                                "ConvergenceKitCloudKit",
                            ],
                            path: "Tests/ConvergenceKitSecretSyncConformanceTests"
                        )
                """
            )
        )
    }
}

private func exactIdentifiers() -> SecretSyncAlgorithmSuiteIdentifiers {
    identifiers()
}

private func identifiers(
    suiteID: UInt16 = SecretSyncAlgorithmRegistry.suiteID,
    suiteName: String = SecretSyncAlgorithmRegistry.suiteName,
    suiteNameUTF8: [UInt8]? = nil,
    version: UInt16 = SecretSyncAlgorithmRegistry.version,
    digest: String = SecretSyncAlgorithmRegistry.digestAlgorithm,
    signature: String = SecretSyncAlgorithmRegistry.signatureAlgorithm,
    publicKeyEncoding: String =
        SecretSyncAlgorithmRegistry.publicKeyEncoding,
    keyEnvelope: String =
        SecretSyncAlgorithmRegistry.keyEnvelopeAlgorithm,
    payload: String = SecretSyncAlgorithmRegistry.payloadAlgorithm
) -> SecretSyncAlgorithmSuiteIdentifiers {
    SecretSyncAlgorithmSuiteIdentifiers(
        suiteID: suiteID,
        suiteNameUTF8: suiteNameUTF8 ?? bytes(suiteName),
        version: version,
        digestUTF8: bytes(digest),
        signatureUTF8: bytes(signature),
        publicKeyEncodingUTF8: bytes(publicKeyEncoding),
        keyEnvelopeUTF8: bytes(keyEnvelope),
        payloadUTF8: bytes(payload)
    )
}

private func expectUnsupported(
    _ identifiers: SecretSyncAlgorithmSuiteIdentifiers
) {
    do {
        _ = try SecretSyncAlgorithmRegistry.resolve(
            identifiers,
            availability: .available
        )
        Issue.record("a non-exact suite tuple was accepted")
    } catch let error as SecretSyncAppleSecurityError {
        #expect(error == .unsupportedSuite)
    } catch {
        Issue.record("registry threw an unexpected error type")
    }
}

private func bytes(_ value: String) -> [UInt8] {
    Array(value.utf8)
}

private func packageManifest() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
}
