import CloudKit
import ConvergenceKit
import Foundation
import Testing
@testable import ConvergenceKitCloudKit

@Suite("SecretSync CloudKit record mapping")
struct SecretSyncRecordMappingTests {
    @Test("fixed immutable registry round-trips canonical bytes and digests")
    func immutableRegistryRoundTrips() throws {
        let digester = U4TestDigester()

        for recordType in SecretSyncCloudKitRecordType.allCases where recordType != .scopeHead {
            let canonicalBytes = try U4CanonicalFixture.bytes(for: recordType)
            let digest = try digester.digest(canonicalBytes: canonicalBytes)
            let value = try SecretSyncCloudKitImmutableRecord(
                type: recordType,
                digest: digest,
                canonicalBytes: canonicalBytes,
                digester: digester
            )

            let record = try CKRecordMapping.secretSyncRecord(value)
            let decoded = try CKRecordMapping.decodeSecretSyncImmutableRecord(
                record,
                digester: digester
            )

            #expect(decoded == value)
            #expect(record.recordType == recordType.rawValue)
            #expect(Set(record.allKeys()) == ["ss_canonical_bytes", "ss_record_digest"])
            #expect(record.encryptedValues.allKeys().isEmpty)
            #expect(record.recordID.zoneID == SecretSyncCloudKitZones.zoneID(for: recordType))
        }
    }

    @Test("registry contains only the frozen v1 record vocabulary")
    func fixedRecordVocabulary() {
        #expect(Set(SecretSyncCloudKitRecordType.allCases.map(\.rawValue)) == [
            "SSDeviceCredentialV1",
            "SSDeviceEnrollmentProofV1",
            "SSDeviceTrustRecordV1",
            "SSScopeSnapshotV1",
            "SSPolicyEpochV1",
            "SSSignedPolicyEpochV1",
            "SSRecipientEnvelopeV1",
            "SSRecoveryEnvelopeV1",
            "SSFullLossRecoveryAuthorizationV1",
            "SSPurgeRequirementV1",
            "SSPurgeReceiptV1",
            "SSTransitionCommitV1",
            "SSControlRecordsV1",
            "SSFreshnessCommitmentV1",
            "SSScopeHeadV1",
            "SSSealedPayloadV1",
        ])
    }

    @Test("digest, domain, field schema, and record name fail closed")
    func malformedImmutableRecordsFailClosed() throws {
        let digester = U4TestDigester()
        let canonicalBytes = try U4CanonicalFixture.bytes(for: .deviceTrustRecord)
        let digest = try digester.digest(canonicalBytes: canonicalBytes)
        let value = try SecretSyncCloudKitImmutableRecord(
            type: .deviceTrustRecord,
            digest: digest,
            canonicalBytes: canonicalBytes,
            digester: digester
        )

        let alteredBytes = try U4CanonicalFixture.bytes(
            for: .deviceTrustRecord,
            replacing: SecretSyncCanonicalField(tag: 1, value: Data(repeating: 0xEE, count: 32))
        )
        #expect(throws: SecretSyncCloudKitError.digestMismatch) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .deviceTrustRecord,
                digest: digest,
                canonicalBytes: alteredBytes,
                digester: digester
            )
        }

        let wrongDomain = try SecretSyncCanonicalEncoding.encode(
            domain: .sealedPayload,
            fields: U4CanonicalFixture.fields(for: .sealedPayload)
        )
        #expect(throws: SecretSyncCloudKitError.canonicalSchemaViolation) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .deviceTrustRecord,
                digest: try digester.digest(canonicalBytes: wrongDomain),
                canonicalBytes: wrongDomain,
                digester: digester
            )
        }

        #expect(throws: SecretSyncCloudKitError.digestComputationFailed) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .deviceTrustRecord,
                digest: digest,
                canonicalBytes: canonicalBytes,
                digester: U4ThrowingDigester()
            )
        }

        let unknownTagBytes = try SecretSyncCanonicalEncoding.encode(
            domain: .deviceTrustRecord,
            fields: U4CanonicalFixture.fields(for: .deviceTrustRecord)
                + [SecretSyncCanonicalField(tag: 99, value: Data([0x01]))]
        )
        #expect(throws: SecretSyncCloudKitError.canonicalSchemaViolation) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .deviceTrustRecord,
                digest: try digester.digest(canonicalBytes: unknownTagBytes),
                canonicalBytes: unknownTagBytes,
                digester: digester
            )
        }

        let record = try CKRecordMapping.secretSyncRecord(value)
        let wrongID = CKRecord.ID(
            recordName: record.recordID.recordName + "ff",
            zoneID: record.recordID.zoneID
        )
        let wrongName = CKRecord(recordType: record.recordType, recordID: wrongID)
        for key in record.allKeys() {
            wrongName[key] = record[key]
        }
        #expect(throws: SecretSyncCloudKitError.invalidRecordIdentity) {
            _ = try CKRecordMapping.decodeSecretSyncImmutableRecord(
                wrongName,
                digester: digester
            )
        }
    }

    @Test("plaintext, key, label, and encrypted-channel fields are rejected")
    func plaintextMetadataIsRejected() throws {
        let digester = U4TestDigester()
        let canonicalBytes = try U4CanonicalFixture.bytes(for: .sealedPayload)
        let value = try SecretSyncCloudKitImmutableRecord(
            type: .sealedPayload,
            digest: digester.digest(canonicalBytes: canonicalBytes),
            canonicalBytes: canonicalBytes,
            digester: digester
        )
        let forbiddenKeys = [
            "title", "path", "content", "human_device_name", "privacy_label",
            "authorization_explanation", "private_key", "raw_key", "recovery_phrase",
        ]

        for forbiddenKey in forbiddenKeys {
            let record = try CKRecordMapping.secretSyncRecord(value)
            record[forbiddenKey] = Data([0x01]) as NSData
            #expect(throws: SecretSyncCloudKitError.invalidFieldSchema) {
                _ = try CKRecordMapping.decodeSecretSyncImmutableRecord(
                    record,
                    digester: digester
                )
            }
        }

        let encryptedFieldRecord = try CKRecordMapping.secretSyncRecord(value)
        // CloudKit itself aborts when one key is written to both channels, so
        // use a distinct encrypted key to prove the mapper rejects the entire
        // encrypted channel without invoking that framework precondition.
        encryptedFieldRecord.encryptedValues["ss_encrypted_shadow"] = Data([0x01]) as NSData
        #expect(throws: SecretSyncCloudKitError.invalidFieldSchema) {
            _ = try CKRecordMapping.decodeSecretSyncImmutableRecord(
                encryptedFieldRecord,
                digester: digester
            )
        }
    }

    @Test("immutable retry is idempotent only for exact bytes")
    func immutableIdempotencyIsExact() throws {
        let digester = U4ConstantDigester()
        let firstBytes = try U4CanonicalFixture.bytes(for: .deviceEnrollmentProof)
        let secondBytes = try U4CanonicalFixture.bytes(
            for: .deviceEnrollmentProof,
            replacing: SecretSyncCanonicalField(tag: 2, value: Data([0xFE]))
        )
        let digest = try digester.digest(canonicalBytes: firstBytes)
        let first = try CKRecordMapping.secretSyncRecord(
            SecretSyncCloudKitImmutableRecord(
                type: .deviceEnrollmentProof,
                digest: digest,
                canonicalBytes: firstBytes,
                digester: digester
            )
        )
        let exactRetry = try CKRecordMapping.secretSyncRecord(
            SecretSyncCloudKitImmutableRecord(
                type: .deviceEnrollmentProof,
                digest: digest,
                canonicalBytes: firstBytes,
                digester: digester
            )
        )
        let collision = try CKRecordMapping.secretSyncRecord(
            SecretSyncCloudKitImmutableRecord(
                type: .deviceEnrollmentProof,
                digest: digest,
                canonicalBytes: secondBytes,
                digester: digester
            )
        )

        try CKRecordMapping.validateSecretSyncImmutableIdempotency(
            existing: first,
            retry: exactRetry,
            digester: digester
        )
        #expect(throws: SecretSyncCloudKitError.immutableCollision) {
            try CKRecordMapping.validateSecretSyncImmutableIdempotency(
                existing: first,
                retry: collision,
                digester: digester
            )
        }
    }

    @Test("full-loss authorization schema and immutable identity fail closed")
    func recoveryAuthorizationSchemaFailsClosed() throws {
        let digester = U4TestDigester()
        let authorizationFields = U4CanonicalFixture.fields(
            for: .fullLossRecoveryAuthorization
        )
        let authorizationBytes = try SecretSyncCanonicalEncoding.encode(
            domain: .fullLossRecoveryAuthorization,
            fields: authorizationFields
        )

        let extraProofField = try SecretSyncCanonicalEncoding.encode(
            domain: .fullLossRecoveryAuthorization,
            fields: authorizationFields
                + [.init(tag: 3, value: Data([0x01]))]
        )
        #expect(throws: SecretSyncCloudKitError.canonicalSchemaViolation) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .fullLossRecoveryAuthorization,
                digest: digester.digest(canonicalBytes: extraProofField),
                canonicalBytes: extraProofField,
                digester: digester
            )
        }

        #expect(throws: SecretSyncContractError.duplicateField(tag: 2)) {
            _ = try SecretSyncCanonicalEncoding.encode(
                domain: .fullLossRecoveryAuthorization,
                fields: authorizationFields
                    + [.init(tag: 2, value: Data([0x02]))]
            )
        }

        let authorizationDocument = try SecretSyncCanonicalEncoding.decode(
            authorizationBytes,
            expectedDomain: .fullLossRecoveryAuthorization
        )
        let intentBytes = try #require(
            authorizationDocument.fields.first { $0.tag == 1 }
        ).value
        let intentDocument = try SecretSyncCanonicalEncoding.decode(
            intentBytes,
            expectedDomain: .globalRecoveryTransitionIntent
        )
        let oldFourElementDescriptor = U4CanonicalFixture
            .sequenceBytesForTesting([
                U4CanonicalFixture.uuidBytesForTesting(0x61),
                Data(
                    RecoveryRecipientDescriptor.agreementAlgorithmIdentifier
                        .utf8
                ),
                Data([0x62]),
                Data([0x04]) + Data(repeating: 0x63, count: 64),
            ])
        let oldDescriptorIntent = try SecretSyncCanonicalEncoding.encode(
            domain: .globalRecoveryTransitionIntent,
            fields: intentDocument.fields.map {
                $0.tag == 16
                    ? .init(tag: 16, value: oldFourElementDescriptor)
                    : $0
            }
        )
        let oldDescriptorAuthorization = try SecretSyncCanonicalEncoding.encode(
            domain: .fullLossRecoveryAuthorization,
            fields: authorizationDocument.fields.map {
                $0.tag == 1
                    ? .init(tag: 1, value: oldDescriptorIntent)
                    : $0
            }
        )
        #expect(throws: SecretSyncCloudKitError.canonicalSchemaViolation) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .fullLossRecoveryAuthorization,
                digest: digester.digest(
                    canonicalBytes: oldDescriptorAuthorization
                ),
                canonicalBytes: oldDescriptorAuthorization,
                digester: digester
            )
        }

        let constantDigester = U4ConstantDigester()
        let alteredBytes = try SecretSyncCanonicalEncoding.encode(
            domain: .fullLossRecoveryAuthorization,
            fields: authorizationFields.map {
                $0.tag == 2
                    ? .init(tag: 2, value: Data([0xFE]))
                    : $0
            }
        )
        let constantDigest = try constantDigester.digest(
            canonicalBytes: authorizationBytes
        )
        let first = try CKRecordMapping.secretSyncRecord(
            SecretSyncCloudKitImmutableRecord(
                type: .fullLossRecoveryAuthorization,
                digest: constantDigest,
                canonicalBytes: authorizationBytes,
                digester: constantDigester
            )
        )
        let collision = try CKRecordMapping.secretSyncRecord(
            SecretSyncCloudKitImmutableRecord(
                type: .fullLossRecoveryAuthorization,
                digest: constantDigest,
                canonicalBytes: alteredBytes,
                digester: constantDigester
            )
        )
        #expect(throws: SecretSyncCloudKitError.immutableCollision) {
            try CKRecordMapping.validateSecretSyncImmutableIdempotency(
                existing: first,
                retry: collision,
                digester: constantDigester
            )
        }
    }

    @Test("scope head is the sole mutable mapping and update preserves the fetched object")
    func scopeHeadUpdatePreservesSystemFields() throws {
        let scopeID = SecretScopeID(U4CanonicalFixture.uuid(0x61))
        let first = try SecretSyncCloudKitScopeHead(
            scopeID: scopeID,
            policyEpoch: 1,
            headCommitDigest: U4CanonicalFixture.digest(0x62),
            policyDigest: U4CanonicalFixture.digest(0x63)
        )
        let next = try SecretSyncCloudKitScopeHead(
            scopeID: scopeID,
            policyEpoch: 2,
            headCommitDigest: U4CanonicalFixture.digest(0x64),
            policyDigest: U4CanonicalFixture.digest(0x65)
        )
        let fetched = try CKRecordMapping.secretSyncScopeHeadRecord(first)
        let identity = ObjectIdentifier(fetched)

        let updated = try CKRecordMapping.applyingSecretSyncScopeHead(next, to: fetched)

        #expect(ObjectIdentifier(updated) == identity)
        #expect(try CKRecordMapping.decodeSecretSyncScopeHead(updated) == next)
        #expect(Set(updated.allKeys()) == [
            "ss_scope_id", "ss_policy_epoch", "ss_head_commit_digest", "ss_policy_digest",
        ])
        #expect(updated.recordType == SecretSyncCloudKitRecordType.scopeHead.rawValue)
    }

    @Test("canonical payloads retain a margin below CloudKit's 1 MB record limit")
    func cloudKitRecordLimitFailsClosed() throws {
        let oversizedBytes = try SecretSyncCanonicalEncoding.encode(
            domain: .sealedPayload,
            fields: U4CanonicalFixture.fields(for: .sealedPayload).map { field in
                field.tag == 7
                    ? SecretSyncCanonicalField(
                        tag: 7,
                        value: Data(
                            repeating: 0xAA,
                            count: SecretSyncCloudKitImmutableRecord.maximumCanonicalByteCount
                        )
                    )
                    : field
            }
        )
        let digester = U4TestDigester()

        #expect(throws: SecretSyncCloudKitError.recordTooLarge) {
            _ = try SecretSyncCloudKitImmutableRecord(
                type: .sealedPayload,
                digest: digester.digest(canonicalBytes: oversizedBytes),
                canonicalBytes: oversizedBytes,
                digester: digester
            )
        }
    }

    @Test("hand-built canonical bytes cannot bypass core semantic contracts")
    func handBuiltCanonicalSemanticsFailClosed() throws {
        let zeroEpoch = Data(repeating: 0, count: 8)
        let identifier = U4CanonicalFixture.uuidBytesForTesting(0x21)
        let digest11 = try U4CanonicalFixture.digest(0x11).bytes
        let digest12 = try U4CanonicalFixture.digest(0x12).bytes

        let invalidDocuments: [(SecretSyncCloudKitRecordType, Data)] = [
            (
                .deviceCredential,
                try U4CanonicalFixture.bytes(
                    for: .deviceCredential,
                    replacing: .init(tag: 3, value: Data([0, 0]))
                )
            ),
            (
                .deviceTrustRecord,
                try U4CanonicalFixture.bytes(
                    for: .deviceTrustRecord,
                    replacing: .init(tag: 5, value: zeroEpoch)
                )
            ),
            (
                .policyEpoch,
                try U4CanonicalFixture.bytes(
                    for: .policyEpoch,
                    replacing: .init(tag: 1, value: Data([0, 2]))
                )
            ),
            (
                .policyEpoch,
                try SecretSyncCanonicalEncoding.encode(
                    domain: .secretPolicyEpoch,
                    fields: U4CanonicalFixture.fields(for: .policyEpoch) + [
                        .init(tag: 3, value: digest11),
                    ]
                )
            ),
            (
                .scopeSnapshot,
                try U4CanonicalFixture.bytes(
                    for: .scopeSnapshot,
                    replacing: .init(
                        tag: 3,
                        value: U4CanonicalFixture.sequenceBytesForTesting([
                            identifier, identifier,
                        ])
                    )
                )
            ),
            (
                .purgeRequirement,
                try U4CanonicalFixture.bytes(
                    for: .purgeRequirement,
                    replacing: .init(
                        tag: 7,
                        value: U4CanonicalFixture.sequenceBytesForTesting([
                            Data("Private Project Title".utf8),
                        ])
                    )
                )
            ),
            (
                .transitionCommit,
                try U4CanonicalFixture.bytes(
                    for: .transitionCommit,
                    replacing: .init(
                        tag: 8,
                        value: U4CanonicalFixture.sequenceBytesForTesting([
                            digest12, digest11,
                        ])
                    )
                )
            ),
            (
                .sealedPayload,
                try U4CanonicalFixture.bytes(
                    for: .sealedPayload,
                    replacing: .init(tag: 6, value: Data([0, 2]))
                )
            ),
        ]
        let digester = U4TestDigester()

        for (type, bytes) in invalidDocuments {
            #expect(throws: SecretSyncCloudKitError.canonicalSchemaViolation) {
                _ = try SecretSyncCloudKitImmutableRecord(
                    type: type,
                    digest: digester.digest(canonicalBytes: bytes),
                    canonicalBytes: bytes,
                    digester: digester
                )
            }
        }
    }
}

private struct U4TestDigester: SecretSyncDigesting {
    func digest(canonicalBytes: Data) throws -> SecretRecordDigest {
        var output = [UInt8](repeating: 0, count: SecretRecordDigest.byteCount)
        for (index, byte) in canonicalBytes.enumerated() {
            let slot = index % output.count
            output[slot] = output[slot] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        return try SecretRecordDigest(bytes: Data(output))
    }
}

private struct U4ConstantDigester: SecretSyncDigesting {
    func digest(canonicalBytes _: Data) throws -> SecretRecordDigest {
        try U4CanonicalFixture.digest(0xA5)
    }
}

private struct U4ThrowingDigester: SecretSyncDigesting {
    private enum Failure: Error { case scripted }

    func digest(canonicalBytes _: Data) throws -> SecretRecordDigest {
        throw Failure.scripted
    }
}

private enum U4CanonicalFixture {
    static func bytes(
        for type: SecretSyncCloudKitRecordType,
        replacing replacement: SecretSyncCanonicalField? = nil
    ) throws -> Data {
        var values = fields(for: type)
        if let replacement,
           let index = values.firstIndex(where: { $0.tag == replacement.tag }) {
            values[index] = replacement
        }
        return try SecretSyncCanonicalEncoding.encode(
            domain: try #require(type.canonicalDomain),
            fields: values
        )
    }

    static func fields(for type: SecretSyncCloudKitRecordType) -> [SecretSyncCanonicalField] {
        let d1 = try! digest(0x11).bytes
        let d2 = try! digest(0x12).bytes
        let id1 = uuidBytes(0x21)
        let id2 = uuidBytes(0x22)
        let id3 = uuidBytes(0x23)
        let enrollment = try! SecretSyncCanonicalEncoding.encode(
            domain: .deviceEnrollmentProof,
            fields: [
                .init(tag: 1, value: id1), .init(tag: 2, value: Data([0x01])),
                .init(tag: 3, value: Data([0x02])), .init(tag: 4, value: Data([0x03])),
                .init(tag: 5, value: id3),
            ]
        )
        let scope = try! SecretSyncCanonicalEncoding.encode(
            domain: .secretScopeSnapshot,
            fields: [
                .init(tag: 1, value: id1), .init(tag: 2, value: id2),
                .init(tag: 3, value: sequence([id2])),
            ]
        )
        let policy = try! SecretSyncCanonicalEncoding.encode(
            domain: .secretPolicyEpoch,
            fields: [
                .init(tag: 1, value: uint16(1)), .init(tag: 2, value: uint64(1)),
                .init(tag: 4, value: scope), .init(tag: 5, value: d1),
                .init(tag: 6, value: id1), .init(tag: 7, value: sequence([id2])),
                .init(tag: 8, value: sequence([d2])), .init(tag: 10, value: id2),
            ]
        )

        switch type {
        case .deviceCredential:
            return [
                .init(tag: 1, value: id1), .init(tag: 2, value: id2),
                .init(tag: 3, value: uint16(1)), .init(tag: 4, value: Data("active".utf8)),
                .init(tag: 5, value: Data("sign-v1".utf8)), .init(tag: 6, value: Data([0x31])),
                .init(tag: 7, value: Data([0x32])), .init(tag: 8, value: Data("agree-v1".utf8)),
                .init(tag: 9, value: Data([0x33])), .init(tag: 10, value: Data([0x34])),
                .init(tag: 11, value: enrollment), .init(tag: 12, value: Data([0x35])),
            ]
        case .deviceEnrollmentProof:
            return try! SecretSyncCanonicalEncoding.decode(
                enrollment,
                expectedDomain: .deviceEnrollmentProof
            ).fields
        case .deviceTrustRecord:
            return [
                .init(tag: 1, value: d1), .init(tag: 2, value: id1),
                .init(tag: 3, value: id2), .init(tag: 4, value: Data("trusted".utf8)),
                .init(tag: 5, value: uint64(1)),
            ]
        case .scopeSnapshot:
            return try! SecretSyncCanonicalEncoding.decode(
                scope,
                expectedDomain: .secretScopeSnapshot
            ).fields
        case .policyEpoch:
            return try! SecretSyncCanonicalEncoding.decode(
                policy,
                expectedDomain: .secretPolicyEpoch
            ).fields
        case .signedPolicyEpoch:
            return [.init(tag: 1, value: policy), .init(tag: 2, value: Data([0x41]))]
        case .recipientEnvelope:
            return boundFields(id1: id1, d1: d1, id2: id2) + [
                .init(tag: 7, value: id2), .init(tag: 8, value: Data([0x51])),
            ]
        case .recoveryEnvelope:
            return boundFields(id1: id1, d1: d1, id2: id2) + [
                .init(tag: 7, value: id2),
                .init(tag: 8, value: Data("breakGlassRecoveryOnly".utf8)),
                .init(tag: 9, value: Data([0x52])),
            ]
        case .fullLossRecoveryAuthorization:
            return recoveryAuthorizationFields()
        case .purgeRequirement:
            return [
                .init(tag: 1, value: id1), .init(tag: 2, value: uint64(1)),
                .init(tag: 3, value: d1), .init(tag: 4, value: id1),
                .init(tag: 5, value: id2), .init(tag: 6, value: id2),
                .init(tag: 7, value: sequence([Data("plaintext".utf8)])),
            ]
        case .purgeReceipt:
            return [
                .init(tag: 1, value: d1), .init(tag: 2, value: id1),
                .init(tag: 3, value: uint64(1)), .init(tag: 4, value: d2),
                .init(tag: 5, value: id1), .init(tag: 6, value: id2),
                .init(tag: 7, value: id2),
                .init(tag: 8, value: sequence([Data("plaintext".utf8)])),
                .init(tag: 9, value: Data("completed".utf8)),
                .init(tag: 10, value: id2), .init(tag: 11, value: Data([0x53])),
            ]
        case .transitionCommit:
            return [
                .init(tag: 1, value: id1), .init(tag: 2, value: uint64(1)),
                .init(tag: 4, value: d1), .init(tag: 5, value: d2),
                .init(tag: 6, value: id1), .init(tag: 7, value: d1),
                .init(tag: 8, value: sequence([d2])),
                .init(tag: 10, value: sequence([])), .init(tag: 11, value: sequence([])),
                .init(tag: 12, value: id2), .init(tag: 14, value: Data([0x54])),
            ]
        case .controlRecords:
            return [
                .init(tag: 1, value: Data("staged".utf8)),
                .init(tag: 2, value: d1), .init(tag: 3, value: d2),
                .init(tag: 4, value: sequence([d1])),
                .init(tag: 6, value: sequence([])), .init(tag: 7, value: sequence([])),
            ]
        case .freshnessCommitment:
            return [
                .init(tag: 1, value: id1), .init(tag: 2, value: uint64(1)),
                .init(tag: 3, value: d1), .init(tag: 4, value: d2),
            ]
        case .sealedPayload:
            return boundFields(id1: id1, d1: d1, id2: id2)
                + [.init(tag: 7, value: Data([0x55]))]
        case .scopeHead:
            return []
        }
    }

    private static func recoveryAuthorizationFields()
        -> [SecretSyncCanonicalField]
    {
        let currentRecovery = try! recoveryDescriptor(
            idByte: 0x61,
            agreementByte: 0x62,
            signingByte: 0x63
        )
        let replacementRecovery = try! recoveryDescriptor(
            idByte: 0x64,
            agreementByte: 0x65,
            signingByte: 0x66
        )
        let signing = try! SigningPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x67]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x68, count: 64)
        )
        let agreement = try! KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: "P256",
            keyIdentifier: Data([0x69]),
            publicKeyBytes: Data([0x04]) + Data(repeating: 0x6A, count: 64)
        )
        let candidateDigest = try! digest(0x71)
        let recoveryEnvelopeDigest = try! digest(0x72)
        let semantics = try! FullLossRecoveryCandidateSemantics(
            scopeSnapshotDigest: try! digest(0x70),
            signedPolicyDigest: candidateDigest,
            sealedPayloadDigest: try! digest(0x73),
            recipientEnvelopeDigests: [try! digest(0x74)],
            recoveryEnvelopeDigest: recoveryEnvelopeDigest,
            purgeRequirementDigests: [],
            purgeReceiptDigests: [],
            credentialDigests: [try! digest(0x75)],
            trustRecordDigests: [try! digest(0x76)]
        )
        let challenge = try! FullLossRecoveryChallenge(
            requestID: uuid(0x77),
            challengeID: uuid(0x78),
            sessionID: uuid(0x79),
            nonce: Data(repeating: 0x7A, count: 16),
            issuedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 2_000
        )
        let intent = try! GlobalRecoveryTransitionIntent(
            appNamespace: "com.codedaptive.test",
            estateID: uuid(0x7B),
            scopeID: SecretScopeID(uuid(0x7C)),
            challenge: challenge,
            warning: try! FullLossRecoveryWarningAcknowledgement(
                acknowledgement: "acknowledged-no-erasure-and-rollback-risk"
            ),
            currentCommitDigest: try! digest(0x7D),
            currentPolicyDigest: try! digest(0x7E),
            currentPolicyEpoch: 1,
            currentGenerationID: SecretGenerationID(uuid(0x7F)),
            currentRecoveryRecipient: currentRecovery,
            replacementDeviceID: TrustedDeviceID(uuid(0x80)),
            replacementCredentialID: DeviceCredentialID(uuid(0x81)),
            replacementSigningPublicKey: signing,
            replacementAgreementPublicKey: agreement,
            signingPossessionProof: Data([0x82]),
            agreementPossessionProof: Data([0x83]),
            candidatePolicyEpoch: 2,
            candidateGenerationID: SecretGenerationID(uuid(0x84)),
            candidateSignedPolicyDigest: candidateDigest,
            replacementRecoveryRecipient: replacementRecovery,
            recoveryEnvelopeDigest: recoveryEnvelopeDigest,
            candidateSemantics: semantics
        )
        let authorization = try! FullLossRecoveryAuthorization(
            recordDigest: try! digest(0x85),
            intent: intent,
            signature: Data([0x86])
        )
        return try! SecretSyncCanonicalEncoding.decode(
            authorization.canonicalBytes(),
            expectedDomain: .fullLossRecoveryAuthorization
        ).fields
    }

    private static func recoveryDescriptor(
        idByte: UInt8,
        agreementByte: UInt8,
        signingByte: UInt8
    ) throws -> RecoveryRecipientDescriptor {
        try RecoveryRecipientDescriptor(
            recoveryRecipientID: uuid(idByte),
            keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
                algorithmIdentifier: RecoveryRecipientDescriptor
                    .agreementAlgorithmIdentifier,
                keyIdentifier: Data([agreementByte]),
                publicKeyBytes: Data([0x04])
                    + Data(repeating: agreementByte, count: 64)
            ),
            authorizationSigningPublicKey: SigningPublicKeyDescriptor(
                algorithmIdentifier: RecoveryRecipientDescriptor
                    .authorizationSigningAlgorithmIdentifier,
                keyIdentifier: Data([signingByte]),
                publicKeyBytes: Data([0x04])
                    + Data(repeating: signingByte, count: 64)
            )
        )
    }

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, byte, byte, byte, byte, byte, byte, byte,
            byte, byte, byte, byte, byte, byte, byte, byte
        ))
    }

    static func digest(_ byte: UInt8) throws -> SecretRecordDigest {
        try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
    }

    static func uuidBytesForTesting(_ byte: UInt8) -> Data {
        uuidBytes(byte)
    }

    static func sequenceBytesForTesting(_ values: [Data]) -> Data {
        sequence(values)
    }

    private static func uuidBytes(_ byte: UInt8) -> Data {
        Data(uuid(byte).uuidString.lowercased().utf8)
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private static func uint64(_ value: UInt64) -> Data {
        Data((0 ..< 8).map { shift in
            UInt8(truncatingIfNeeded: value >> UInt64((7 - shift) * 8))
        })
    }

    private static func sequence(_ values: [Data]) -> Data {
        var output = uint16(UInt16(values.count))
        for value in values {
            let count = UInt32(value.count)
            output.append(contentsOf: [
                UInt8(count >> 24), UInt8((count >> 16) & 0xFF),
                UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF),
            ])
            output.append(value)
        }
        return output
    }

    private static func boundFields(id1: Data, d1: Data, id2: Data) -> [SecretSyncCanonicalField] {
        [
            .init(tag: 1, value: id1), .init(tag: 2, value: d1),
            .init(tag: 3, value: uint64(1)), .init(tag: 4, value: d1),
            .init(tag: 5, value: id2), .init(tag: 6, value: uint16(1)),
        ]
    }
}
