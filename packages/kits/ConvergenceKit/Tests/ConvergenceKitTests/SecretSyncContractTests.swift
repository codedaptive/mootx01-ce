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

    @Test("scope snapshots and recipient sets are exact, sorted, and duplicate-free")
    func exactScopeAndRecipientSnapshots() throws {
        let memberA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let memberB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let snapshotDigest = try digest(0x40)
        let forward = try SecretScopeSnapshot(
            scopeID: scopeID,
            rootRecordID: rootRecordID,
            memberRecordIDs: [memberA, memberB],
            snapshotDigest: snapshotDigest
        )
        let reverse = try SecretScopeSnapshot(
            scopeID: scopeID,
            rootRecordID: rootRecordID,
            memberRecordIDs: [memberB, memberA],
            snapshotDigest: snapshotDigest
        )

        #expect(forward.memberRecordIDs == [memberA, memberB])
        #expect(try forward.canonicalBytes() == reverse.canonicalBytes())

        expectContractError(.duplicateIdentifier(field: "memberRecordIDs")) {
            _ = try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: rootRecordID,
                memberRecordIDs: [memberA, memberA],
                snapshotDigest: snapshotDigest
            )
        }
        expectContractError(.emptySet(field: "memberRecordIDs")) {
            _ = try SecretScopeSnapshot(
                scopeID: scopeID,
                rootRecordID: rootRecordID,
                memberRecordIDs: [],
                snapshotDigest: snapshotDigest
            )
        }
    }

    @Test("policy epochs are monotonic immutable snapshots with recovery separated")
    func immutablePolicyEpochs() throws {
        let snapshot = try scopeSnapshot()
        let recipientA = DeviceCredentialID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let recipientB = DeviceCredentialID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )
        let recovery = try recoveryRecipient()
        let predecessor = try digest(0x41)

        let forward = try SecretPolicyEpoch(
            epoch: 2,
            predecessorPolicyDigest: predecessor,
            scopeSnapshot: snapshot,
            generationID: generationID,
            authorizedRecipientCredentialIDs: [recipientA, recipientB],
            recoveryRecipient: recovery,
            signerCredentialID: signerCredentialID
        )
        let reverse = try SecretPolicyEpoch(
            epoch: 2,
            predecessorPolicyDigest: predecessor,
            scopeSnapshot: snapshot,
            generationID: generationID,
            authorizedRecipientCredentialIDs: [recipientB, recipientA],
            recoveryRecipient: recovery,
            signerCredentialID: signerCredentialID
        )

        #expect(forward.authorizedRecipientCredentialIDs == [recipientA, recipientB])
        #expect(try forward.canonicalBytes() == reverse.canonicalBytes())
        #expect(
            !forward.authorizedRecipientCredentialIDs.contains(
                DeviceCredentialID(
                    UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
                )
            )
        )

        expectContractError(.duplicateIdentifier(field: "authorizedRecipientCredentialIDs")) {
            _ = try SecretPolicyEpoch(
                epoch: 2,
                predecessorPolicyDigest: predecessor,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipientA, recipientA],
                recoveryRecipient: recovery,
                signerCredentialID: signerCredentialID
            )
        }
        expectContractError(.recoveryRecipientIsRoutineRecipient) {
            _ = try SecretPolicyEpoch(
                epoch: 2,
                predecessorPolicyDigest: predecessor,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [
                    DeviceCredentialID(recovery.recoveryRecipientID),
                ],
                recoveryRecipient: recovery,
                signerCredentialID: signerCredentialID
            )
        }
    }

    @Test("policy epoch shape rejects zero and invalid predecessor relationships")
    func policyEpochShapeFailsClosed() throws {
        let snapshot = try scopeSnapshot()
        let recipient = DeviceCredentialID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        expectContractError(.invalidPolicyEpoch) {
            _ = try SecretPolicyEpoch(
                epoch: 0,
                predecessorPolicyDigest: nil,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipient],
                recoveryRecipient: nil,
                signerCredentialID: signerCredentialID
            )
        }
        expectContractError(.missingPredecessor) {
            _ = try SecretPolicyEpoch(
                epoch: 2,
                predecessorPolicyDigest: nil,
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipient],
                recoveryRecipient: nil,
                signerCredentialID: signerCredentialID
            )
        }
        expectContractError(.unexpectedPredecessor) {
            _ = try SecretPolicyEpoch(
                epoch: 1,
                predecessorPolicyDigest: try digest(0x42),
                scopeSnapshot: snapshot,
                generationID: generationID,
                authorizedRecipientCredentialIDs: [recipient],
                recoveryRecipient: nil,
                signerCredentialID: signerCredentialID
            )
        }
    }

    @Test("validating Codable cannot bypass epoch invariants")
    func policyCodableRejectsMalformedState() throws {
        let policy = try policyEpoch()
        let valid = try JSONEncoder().encode(policy)
        var object = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["epoch"] = 0
        let malformed = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(SecretPolicyEpoch.self, from: malformed)
        }
    }

    @Test("sealed payload and recipient envelopes expose only opaque bound bytes")
    func opaqueEnvelopeContracts() throws {
        let policyDigest = try digest(0x43)
        let snapshotDigest = try digest(0x44)
        let payload = try SealedPayload(
            recordDigest: try digest(0x45),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshotDigest,
            policyEpoch: 2,
            policyDigest: policyDigest,
            generationID: generationID,
            formatVersion: 1,
            ciphertextBytes: Data([0x50, 0x51])
        )
        let recipient = try RecipientKeyEnvelope(
            recordDigest: try digest(0x46),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshotDigest,
            policyEpoch: 2,
            policyDigest: policyDigest,
            generationID: generationID,
            recipientCredentialID: DeviceCredentialID(
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            ),
            formatVersion: 1,
            wrappedKeyBytes: Data([0x52, 0x53])
        )
        let recovery = try RecoveryEnvelope(
            recordDigest: try digest(0x47),
            scopeID: scopeID,
            scopeSnapshotDigest: snapshotDigest,
            policyEpoch: 2,
            policyDigest: policyDigest,
            generationID: generationID,
            recoveryRecipientID: UUID(
                uuidString: "20000000-0000-0000-0000-000000000001"
            )!,
            formatVersion: 1,
            wrappedKeyBytes: Data([0x54, 0x55])
        )

        #expect(payload.ciphertextBytes == Data([0x50, 0x51]))
        #expect(recipient.wrappedKeyBytes == Data([0x52, 0x53]))
        #expect(recovery.usage == .breakGlassRecoveryOnly)
        #expect(
            try recipient.canonicalBytes()
                != recovery.canonicalBytes()
        )
    }

    @Test("device trust is a policy-epoch record, not a transient slot")
    func deviceTrustRecordIsStable() throws {
        let record = try DeviceTrustRecord(
            recordDigest: try digest(0x48),
            deviceID: TrustedDeviceID(
                UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
            ),
            credentialID: DeviceCredentialID(
                UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ),
            trustState: .trusted,
            effectivePolicyEpoch: 2
        )

        #expect(record.trustState == .trusted)
        #expect(record.effectivePolicyEpoch == 2)
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

private let scopeID = SecretScopeID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
)
private let rootRecordID = UUID(
    uuidString: "30000000-0000-0000-0000-000000000002"
)!
private let generationID = SecretGenerationID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
)
private let signerCredentialID = DeviceCredentialID(
    UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
)

private func digest(_ byte: UInt8) throws -> SecretRecordDigest {
    try SecretRecordDigest(bytes: Data(repeating: byte, count: SecretRecordDigest.byteCount))
}

private func scopeSnapshot() throws -> SecretScopeSnapshot {
    try SecretScopeSnapshot(
        scopeID: scopeID,
        rootRecordID: rootRecordID,
        memberRecordIDs: [
            rootRecordID,
            UUID(uuidString: "30000000-0000-0000-0000-000000000005")!,
        ],
        snapshotDigest: digest(0x60)
    )
}

private func recoveryRecipient() throws -> RecoveryRecipientDescriptor {
    try RecoveryRecipientDescriptor(
        recoveryRecipientID: UUID(
            uuidString: "20000000-0000-0000-0000-000000000001"
        )!,
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "opaque-recovery-agreement-suite",
            keyIdentifier: Data([0x61]),
            publicKeyBytes: Data([0x62])
        )
    )
}

private func policyEpoch() throws -> SecretPolicyEpoch {
    try SecretPolicyEpoch(
        epoch: 2,
        predecessorPolicyDigest: digest(0x63),
        scopeSnapshot: scopeSnapshot(),
        generationID: generationID,
        authorizedRecipientCredentialIDs: [
            DeviceCredentialID(
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            ),
        ],
        recoveryRecipient: recoveryRecipient(),
        signerCredentialID: signerCredentialID
    )
}
