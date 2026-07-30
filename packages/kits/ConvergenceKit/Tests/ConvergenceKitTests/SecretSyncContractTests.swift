import Foundation
import Testing
@testable import ConvergenceKit

@Suite("SecretSync contract")
struct SecretSyncContractTests {
    @Test("stable security identifiers round-trip without HLC slot vocabulary")
    func stableIdentifiersRoundTrip() throws {
        let deviceID = TrustedDeviceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let credentialID = DeviceCredentialID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let scopeID = SecretScopeID(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!)
        let generationID = SecretGenerationID(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)

        let encoded = try JSONEncoder().encode([deviceID.rawValue, credentialID.rawValue, scopeID.rawValue, generationID.rawValue])
        let decoded = try JSONDecoder().decode([UUID].self, from: encoded)

        #expect(decoded == [deviceID.rawValue, credentialID.rawValue, scopeID.rawValue, generationID.rawValue])
    }

    @Test("signing and key-agreement roles are distinct and cannot reuse one key")
    func credentialKeyRolesAreDistinct() throws {
        let signing = try SigningPublicKeyDescriptor(
            algorithmIdentifier: "opaque-signature-suite",
            keyIdentifier: Data([0x01]),
            publicKeyBytes: Data([0x10, 0x11])
        )
        let agreement = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-agreement-suite",
            keyIdentifier: Data([0x02]),
            publicKeyBytes: Data([0x20, 0x21])
        )
        let proof = try DeviceCredentialEnrollmentProof(
            challengeID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            challengeBytes: Data([0x30]),
            signingProofBytes: Data([0x31]),
            keyAgreementProofBytes: Data([0x32]),
            authorityCredentialID: DeviceCredentialID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!),
            authoritySignature: Data([0x33])
        )

        let credential = try TrustedDeviceCredential(
            deviceID: TrustedDeviceID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
            credentialID: DeviceCredentialID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!),
            credentialVersion: 1,
            status: .active,
            signingPublicKey: signing,
            keyAgreementPublicKey: agreement,
            enrollmentProof: proof
        )

        #expect(credential.signingPublicKey.keyIdentifier == Data([0x01]))
        #expect(credential.keyAgreementPublicKey.keyIdentifier == Data([0x02]))

        let reusedAgreement = try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-agreement-suite",
            keyIdentifier: signing.keyIdentifier,
            publicKeyBytes: signing.publicKeyBytes
        )
        expectContractError(.keyRoleReuse) {
            _ = try TrustedDeviceCredential(
                deviceID: credential.deviceID,
                credentialID: credential.credentialID,
                credentialVersion: 1,
                status: .active,
                signingPublicKey: signing,
                keyAgreementPublicKey: reusedAgreement,
                enrollmentProof: proof
            )
        }
    }

    @Test("opaque record digests are exactly 32 bytes")
    func digestWidthIsFixed() throws {
        let bytes = Data(repeating: 0xAB, count: SecretRecordDigest.byteCount)
        let digest = try SecretRecordDigest(bytes: bytes)
        #expect(digest.bytes == bytes)

        expectContractError(.invalidDigestLength(actual: 31)) {
            _ = try SecretRecordDigest(bytes: Data(repeating: 0xAB, count: 31))
        }
    }

    @Test("canonical fields are sorted and the golden frame is stable")
    func canonicalGoldenFrame() throws {
        let first = SecretSyncCanonicalField(tag: 1, value: Data([0xAA]))
        let second = SecretSyncCanonicalField(tag: 2, value: Data([0xBB]))

        let ascending = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [first, second]
        )
        let descending = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [second, first]
        )
        #expect(ascending == descending)

        let oneField = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [first]
        )
        #expect(
            oneField.hexString
                == "53534350000100257365637265742d73796e632f747275737465642d6465766963652d63726564656e7469616c0001000100000001aa"
        )

        let decoded = try SecretSyncCanonicalEncoding.decode(
            ascending,
            expectedDomain: .trustedDeviceCredential
        )
        #expect(decoded.fields.map(\.tag) == [1, 2])
        #expect(decoded.fields.map(\.value) == [Data([0xAA]), Data([0xBB])])
    }

    @Test("canonical framing rejects ambiguity and malformed input")
    func canonicalFramingFailsClosed() throws {
        let field = SecretSyncCanonicalField(tag: 1, value: Data([0xAA]))
        let valid = try SecretSyncCanonicalEncoding.encode(
            domain: .trustedDeviceCredential,
            fields: [field]
        )

        expectContractError(.duplicateField(tag: 1)) {
            _ = try SecretSyncCanonicalEncoding.encode(
                domain: .trustedDeviceCredential,
                fields: [field, field]
            )
        }
        expectContractError(.domainMismatch) {
            _ = try SecretSyncCanonicalEncoding.decode(valid, expectedDomain: .secretPolicyEpoch)
        }

        var unknownVersion = valid
        unknownVersion[5] = 0x02
        expectContractError(.unsupportedSchemaVersion(2)) {
            _ = try SecretSyncCanonicalEncoding.decode(
                unknownVersion,
                expectedDomain: .trustedDeviceCredential
            )
        }

        expectContractError(.truncatedCanonicalBytes) {
            _ = try SecretSyncCanonicalEncoding.decode(
                Data(valid.dropLast()),
                expectedDomain: .trustedDeviceCredential
            )
        }

        var trailing = valid
        trailing.append(0)
        expectContractError(.trailingCanonicalBytes) {
            _ = try SecretSyncCanonicalEncoding.decode(
                trailing,
                expectedDomain: .trustedDeviceCredential
            )
        }

        expectContractError(.fieldTooLarge) {
            _ = try SecretSyncCanonicalEncoding.encode(
                domain: .trustedDeviceCredential,
                fields: [
                    SecretSyncCanonicalField(
                        tag: 1,
                        value: Data(
                            repeating: 0,
                            count: SecretSyncCanonicalEncoding.maximumFieldByteCount + 1
                        )
                    ),
                ]
            )
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func expectContractError(
    _ expected: SecretSyncContractError,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected \(expected)")
    } catch let error as SecretSyncContractError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
