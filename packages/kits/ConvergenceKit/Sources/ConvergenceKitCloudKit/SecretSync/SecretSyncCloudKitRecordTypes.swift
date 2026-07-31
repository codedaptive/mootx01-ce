import ConvergenceKit
import Foundation

/// Frozen CloudKit record vocabulary for SecretSync schema version 1.
public enum SecretSyncCloudKitRecordType: String, CaseIterable, Sendable {
    case deviceCredential = "SSDeviceCredentialV1"
    case deviceEnrollmentProof = "SSDeviceEnrollmentProofV1"
    case deviceTrustRecord = "SSDeviceTrustRecordV1"
    case scopeSnapshot = "SSScopeSnapshotV1"
    case policyEpoch = "SSPolicyEpochV1"
    case signedPolicyEpoch = "SSSignedPolicyEpochV1"
    case recipientEnvelope = "SSRecipientEnvelopeV1"
    case recoveryEnvelope = "SSRecoveryEnvelopeV1"
    case purgeRequirement = "SSPurgeRequirementV1"
    case purgeReceipt = "SSPurgeReceiptV1"
    case transitionCommit = "SSTransitionCommitV1"
    case controlRecords = "SSControlRecordsV1"
    case freshnessCommitment = "SSFreshnessCommitmentV1"
    case scopeHead = "SSScopeHeadV1"
    case sealedPayload = "SSSealedPayloadV1"

    /// Canonical domain whose bytes this record type may carry.
    /// `SSScopeHeadV1` is the sole mutable transport record and therefore has
    /// no canonical immutable document.
    public var canonicalDomain: SecretSyncCanonicalDomain? {
        switch self {
        case .deviceCredential: .trustedDeviceCredential
        case .deviceEnrollmentProof: .deviceEnrollmentProof
        case .deviceTrustRecord: .deviceTrustRecord
        case .scopeSnapshot: .secretScopeSnapshot
        case .policyEpoch: .secretPolicyEpoch
        case .signedPolicyEpoch: .signedSecretPolicyEpoch
        case .recipientEnvelope: .recipientKeyEnvelope
        case .recoveryEnvelope: .recoveryEnvelope
        case .purgeRequirement: .purgeRequirement
        case .purgeReceipt: .purgeReceipt
        case .transitionCommit: .secretTransitionCommit
        case .controlRecords: .secretControlRecords
        case .freshnessCommitment: .bootstrapFreshnessCommitment
        case .sealedPayload: .sealedPayload
        case .scopeHead: nil
        }
    }

    /// Whether this record is immutable and content-addressed.
    public var isImmutable: Bool { self != .scopeHead }
}

/// Fail-closed CloudKit transport errors. Cases intentionally carry no user
/// content, record bytes, key material, or authorization explanation.
public enum SecretSyncCloudKitError: Error, Sendable, Equatable {
    case unsupportedRecordType
    case digestMismatch
    case canonicalSchemaViolation
    case invalidRecordIdentity
    case invalidFieldSchema
    case immutableCollision
    case incompleteModifyResults
    case invalidWriteBatch
}

/// Validated immutable SecretSync record ready for CloudKit transport.
public struct SecretSyncCloudKitImmutableRecord: Sendable, Equatable {
    public let type: SecretSyncCloudKitRecordType
    public let digest: SecretRecordDigest
    public let canonicalBytes: Data

    /// Validate domain, exact canonical field schema, and digest before the
    /// bytes may cross the CloudKit boundary.
    public init(
        type: SecretSyncCloudKitRecordType,
        digest: SecretRecordDigest,
        canonicalBytes: Data,
        digester: any SecretSyncDigesting
    ) throws {
        guard type.isImmutable, let domain = type.canonicalDomain else {
            throw SecretSyncCloudKitError.unsupportedRecordType
        }
        let computed = try digester.digest(canonicalBytes: canonicalBytes)
        guard computed == digest else {
            throw SecretSyncCloudKitError.digestMismatch
        }
        do {
            let document = try SecretSyncCanonicalEncoding.decode(
                canonicalBytes,
                expectedDomain: domain
            )
            try SecretSyncCloudKitCanonicalSchema.validate(document, as: type)
        } catch let error as SecretSyncCloudKitError {
            throw error
        } catch {
            throw SecretSyncCloudKitError.canonicalSchemaViolation
        }
        self.type = type
        self.digest = digest
        self.canonicalBytes = canonicalBytes
    }
}

/// The single mutable SecretSync CloudKit record. Updates must be applied to a
/// fetched `CKRecord` so CloudKit's server change tag remains the CAS token.
public struct SecretSyncCloudKitScopeHead: Sendable, Equatable {
    public let scopeID: SecretScopeID
    public let policyEpoch: UInt64
    public let headCommitDigest: SecretRecordDigest
    public let policyDigest: SecretRecordDigest

    public init(
        scopeID: SecretScopeID,
        policyEpoch: UInt64,
        headCommitDigest: SecretRecordDigest,
        policyDigest: SecretRecordDigest
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
        self.scopeID = scopeID
        self.policyEpoch = policyEpoch
        self.headCommitDigest = headCommitDigest
        self.policyDigest = policyDigest
    }
}

enum SecretSyncCloudKitCanonicalSchema {
    static func validate(
        _ document: SecretSyncCanonicalDocument,
        as type: SecretSyncCloudKitRecordType
    ) throws {
        guard document.domain == type.canonicalDomain else { try fail() }
        let fields = Dictionary(uniqueKeysWithValues: document.fields.map { ($0.tag, $0.value) })

        switch type {
        case .deviceCredential:
            try tags(fields, required: 1...12)
            try uuid(fields[1]); try uuid(fields[2]); try u16(fields[3])
            try oneOf(fields[4], ["active", "revoked"])
            try algorithm(fields[5]); try opaque(fields[6]); try opaque(fields[7])
            try algorithm(fields[8]); try opaque(fields[9]); try opaque(fields[10])
            try nested(fields[11], domain: .deviceEnrollmentProof, as: .deviceEnrollmentProof)
            try opaque(fields[12])
        case .deviceEnrollmentProof:
            try tags(fields, required: 1...5)
            try uuid(fields[1]); try opaque(fields[2]); try opaque(fields[3])
            try opaque(fields[4]); try uuid(fields[5])
        case .deviceTrustRecord:
            try tags(fields, required: 1...5)
            try digest(fields[1]); try uuid(fields[2]); try uuid(fields[3])
            try oneOf(fields[4], ["pendingEnrollment", "trusted", "revoked"])
            try u64(fields[5])
        case .scopeSnapshot:
            try tags(fields, required: 1...3)
            try uuid(fields[1]); try uuid(fields[2]); try sequence(fields[3], element: uuid)
        case .policyEpoch:
            try tags(fields, required: [1, 2, 4, 5, 6, 7, 8, 10], optional: [3, 9])
            try u16(fields[1]); try u64(fields[2]); if fields[3] != nil { try digest(fields[3]) }
            try nested(fields[4], domain: .secretScopeSnapshot, as: .scopeSnapshot)
            try digest(fields[5]); try uuid(fields[6]); try sequence(fields[7], element: uuid)
            try sequence(fields[8], element: digest)
            if let recovery = fields[9] { try recoveryDescriptor(recovery) }
            try uuid(fields[10])
        case .signedPolicyEpoch:
            try tags(fields, required: 1...2)
            try nested(fields[1], domain: .secretPolicyEpoch, as: .policyEpoch)
            try opaque(fields[2])
        case .recipientEnvelope:
            try boundRecord(fields, lastTag: 8)
            try uuid(fields[7]); try opaque(fields[8])
        case .recoveryEnvelope:
            try boundRecord(fields, lastTag: 9)
            try uuid(fields[7]); try exact(fields[8], "breakGlassRecoveryOnly")
            try opaque(fields[9])
        case .purgeRequirement:
            try tags(fields, required: 1...7)
            try uuid(fields[1]); try u64(fields[2]); try digest(fields[3])
            try uuid(fields[4]); try uuid(fields[5]); try uuid(fields[6])
            try sequence(fields[7], element: nonemptyString)
        case .purgeReceipt:
            try tags(fields, required: 1...11)
            try digest(fields[1]); try uuid(fields[2]); try u64(fields[3]); try digest(fields[4])
            try uuid(fields[5]); try uuid(fields[6]); try uuid(fields[7])
            try sequence(fields[8], element: nonemptyString)
            try oneOf(fields[9], ["completed", "partial", "failed"])
            try uuid(fields[10]); try opaque(fields[11])
        case .transitionCommit:
            try tags(fields, required: [1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 14], optional: [3, 9])
            try uuid(fields[1]); try u64(fields[2]); if fields[3] != nil { try digest(fields[3]) }
            try digest(fields[4]); try digest(fields[5]); try uuid(fields[6]); try digest(fields[7])
            try sequence(fields[8], element: digest); if fields[9] != nil { try digest(fields[9]) }
            try sequence(fields[10], allowEmpty: true, element: digest)
            try sequence(fields[11], allowEmpty: true, element: digest)
            try uuid(fields[12]); try opaque(fields[14])
        case .controlRecords:
            try tags(fields, required: [1, 2, 3, 4, 6, 7], optional: [5])
            try oneOf(fields[1], ["staged", "committed", "rejected"])
            try digest(fields[2]); try digest(fields[3]); try sequence(fields[4], element: digest)
            if fields[5] != nil { try digest(fields[5]) }
            try sequence(fields[6], allowEmpty: true, element: digest)
            try sequence(fields[7], allowEmpty: true, element: digest)
        case .freshnessCommitment:
            try tags(fields, required: 1...4)
            try uuid(fields[1]); try u64(fields[2]); try digest(fields[3]); try digest(fields[4])
        case .sealedPayload:
            try boundRecord(fields, lastTag: 7)
            try opaque(fields[7])
        case .scopeHead:
            try fail()
        }
    }

    private static func boundRecord(_ fields: [UInt16: Data], lastTag: UInt16) throws {
        try tags(fields, required: Array(UInt16(1)...lastTag))
        try uuid(fields[1]); try digest(fields[2]); try u64(fields[3])
        try digest(fields[4]); try uuid(fields[5]); try u16(fields[6])
    }

    private static func tags(
        _ fields: [UInt16: Data],
        required: ClosedRange<Int>,
        optional: Set<UInt16> = []
    ) throws {
        try tags(fields, required: required.map(UInt16.init), optional: optional)
    }

    private static func tags(
        _ fields: [UInt16: Data],
        required: [UInt16],
        optional: Set<UInt16> = []
    ) throws {
        let requiredSet = Set(required)
        guard requiredSet.isSubset(of: fields.keys),
              Set(fields.keys).isSubset(of: requiredSet.union(optional)) else { try fail() }
    }

    private static func uuid(_ value: Data?) throws {
        guard let value, value.count == 36,
              let text = String(data: value, encoding: .utf8),
              text == text.lowercased(), UUID(uuidString: text) != nil else { try fail() }
    }

    private static func digest(_ value: Data?) throws {
        guard value?.count == SecretRecordDigest.byteCount else { try fail() }
    }

    private static func u16(_ value: Data?) throws { guard value?.count == 2 else { try fail() } }
    private static func u64(_ value: Data?) throws { guard value?.count == 8 else { try fail() } }

    private static func opaque(_ value: Data?) throws {
        guard let value, !value.isEmpty, value.count <= 65_536 else { try fail() }
    }

    private static func algorithm(_ value: Data?) throws {
        guard let value, !value.isEmpty, value.count <= 128,
              String(data: value, encoding: .utf8) != nil else { try fail() }
    }

    private static func nonemptyString(_ value: Data?) throws {
        guard let value, !value.isEmpty,
              String(data: value, encoding: .utf8) != nil else { try fail() }
    }

    private static func oneOf(_ value: Data?, _ choices: Set<String>) throws {
        guard let value, let text = String(data: value, encoding: .utf8),
              choices.contains(text) else { try fail() }
    }

    private static func exact(_ value: Data?, _ expected: String) throws {
        guard value == Data(expected.utf8) else { try fail() }
    }

    private static func nested(
        _ value: Data?,
        domain: SecretSyncCanonicalDomain,
        as type: SecretSyncCloudKitRecordType
    ) throws {
        guard let value else { try fail() }
        let document = try SecretSyncCanonicalEncoding.decode(value, expectedDomain: domain)
        try validate(document, as: type)
    }

    private static func recoveryDescriptor(_ value: Data) throws {
        let values = try sequenceValues(value, allowEmpty: false)
        guard values.count == 4 else { try fail() }
        try uuid(values[0]); try algorithm(values[1]); try opaque(values[2]); try opaque(values[3])
    }

    private static func sequence(
        _ value: Data?,
        allowEmpty: Bool = false,
        element: (Data?) throws -> Void
    ) throws {
        guard let value else { try fail() }
        for item in try sequenceValues(value, allowEmpty: allowEmpty) { try element(item) }
    }

    private static func sequenceValues(_ value: Data, allowEmpty: Bool) throws -> [Data] {
        let bytes = [UInt8](value)
        guard bytes.count >= 2 else { try fail() }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        guard allowEmpty || count > 0 else { try fail() }
        var cursor = 2
        var values: [Data] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 4 <= bytes.count else { try fail() }
            let length = (Int(bytes[cursor]) << 24) | (Int(bytes[cursor + 1]) << 16)
                | (Int(bytes[cursor + 2]) << 8) | Int(bytes[cursor + 3])
            cursor += 4
            guard cursor + length <= bytes.count else { try fail() }
            values.append(Data(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        guard cursor == bytes.count else { try fail() }
        return values
    }

    private static func fail() throws -> Never {
        throw SecretSyncCloudKitError.canonicalSchemaViolation
    }
}

extension Data {
    var secretSyncLowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
