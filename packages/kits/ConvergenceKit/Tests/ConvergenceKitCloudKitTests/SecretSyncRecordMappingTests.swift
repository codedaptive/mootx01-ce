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
        let enrollment = try! SecretSyncCanonicalEncoding.encode(
            domain: .deviceEnrollmentProof,
            fields: [
                .init(tag: 1, value: id1), .init(tag: 2, value: Data([0x01])),
                .init(tag: 3, value: Data([0x02])), .init(tag: 4, value: Data([0x03])),
                .init(tag: 5, value: id2),
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

    static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, byte, byte, byte, byte, byte, byte, byte,
            byte, byte, byte, byte, byte, byte, byte, byte
        ))
    }

    static func digest(_ byte: UInt8) throws -> SecretRecordDigest {
        try SecretRecordDigest(bytes: Data(repeating: byte, count: 32))
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
