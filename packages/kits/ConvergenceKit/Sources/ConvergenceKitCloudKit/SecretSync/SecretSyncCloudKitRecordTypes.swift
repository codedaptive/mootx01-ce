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
    case fullLossRecoveryAuthorization = "SSFullLossRecoveryAuthorizationV1"
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
        case .fullLossRecoveryAuthorization: .fullLossRecoveryAuthorization
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
    case digestComputationFailed
    case digestMismatch
    case recordTooLarge
    case canonicalSchemaViolation
    case invalidRecordIdentity
    case invalidFieldSchema
    case immutableCollision
    case incompleteModifyResults
    case invalidWriteBatch
}

/// Validated immutable SecretSync record ready for CloudKit transport.
public struct SecretSyncCloudKitImmutableRecord: Sendable, Equatable {
    /// CloudKit caps non-asset record data at 1 MB. The canonical payload is
    /// capped at 900 KB so its 32-byte digest, field framing, record metadata,
    /// and future compatible system overhead cannot cross that hard limit.
    static let maximumCanonicalByteCount = 900_000

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
        guard canonicalBytes.count <= Self.maximumCanonicalByteCount else {
            throw SecretSyncCloudKitError.recordTooLarge
        }
        let computed: SecretRecordDigest
        do {
            computed = try digester.digest(canonicalBytes: canonicalBytes)
        } catch {
            throw SecretSyncCloudKitError.digestComputationFailed
        }
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
            try tags(fields, required: Array(1...11).map(UInt16.init), optional: [12])
            try uuid(fields[1]); try uuid(fields[2]); try positiveU16(fields[3])
            try oneOf(fields[4], ["active", "revoked"])
            try algorithm(fields[5]); try opaque(fields[6]); try opaque(fields[7])
            try algorithm(fields[8]); try opaque(fields[9]); try opaque(fields[10])
            try nested(fields[11], domain: .deviceEnrollmentProof, as: .deviceEnrollmentProof)
            guard fields[6] != fields[9], fields[7] != fields[10] else { try fail() }
            let enrollment = try SecretSyncCanonicalEncoding.decode(
                try required(fields[11]),
                expectedDomain: .deviceEnrollmentProof
            )
            let enrollmentTags = Set(enrollment.fields.map(\.tag))
            if enrollmentTags == Set([1, 2, 3, 4, 5]) {
                try opaque(fields[12])
                guard enrollment.fields.first(where: { $0.tag == 5 })?.value != fields[2]
                else { try fail() }
            } else {
                guard enrollmentTags == Set([1, 2, 3, 4, 6, 7]), fields[12] == nil
                else { try fail() }
            }
        case .deviceEnrollmentProof:
            let fieldTags = Set(fields.keys)
            guard fieldTags == Set([1, 2, 3, 4, 5])
                    || fieldTags == Set([1, 2, 3, 4, 6, 7])
            else { try fail() }
            try uuid(fields[1]); try opaque(fields[2]); try opaque(fields[3]); try opaque(fields[4])
            if fields[5] != nil { try uuid(fields[5]) }
            if fields[6] != nil { try uuid(fields[6]); try uuid(fields[7]) }
        case .deviceTrustRecord:
            try tags(fields, required: 1...5)
            try digest(fields[1]); try uuid(fields[2]); try uuid(fields[3])
            try oneOf(fields[4], ["pendingEnrollment", "trusted", "revoked"])
            try positiveU64(fields[5])
        case .scopeSnapshot:
            try tags(fields, required: 1...3)
            try uuid(fields[1]); try uuid(fields[2]); _ = try uuidSequence(fields[3])
        case .policyEpoch:
            try tags(fields, required: [1, 2, 4, 5, 6, 7, 8, 10], optional: [3, 9])
            guard try u16Value(fields[1]) == SecretSyncCanonicalEncoding.schemaVersion else {
                try fail()
            }
            let epoch = try positiveU64(fields[2])
            try validatePredecessor(epoch: epoch, predecessor: fields[3])
            try nested(fields[4], domain: .secretScopeSnapshot, as: .scopeSnapshot)
            try digest(fields[5]); try uuid(fields[6]); let recipients = try uuidSequence(fields[7])
            try digestSequence(fields[8])
            if let recovery = fields[9] {
                let recoveryID = try recoveryDescriptor(recovery)
                guard !recipients.contains(recoveryID) else { try fail() }
            }
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
        case .fullLossRecoveryAuthorization:
            try tags(fields, required: 1...2)
            try opaque(fields[1]); try opaque(fields[2])
            let canonicalBytes = try SecretSyncCanonicalEncoding.encode(
                domain: .fullLossRecoveryAuthorization,
                fields: document.fields.map {
                    SecretSyncCanonicalField(tag: $0.tag, value: $0.value)
                }
            )
            _ = try FullLossRecoveryAuthorization(
                recordDigest: SecretRecordDigest(
                    bytes: Data(repeating: 0, count: SecretRecordDigest.byteCount)
                ),
                canonicalBytes: canonicalBytes
            )
        case .purgeRequirement:
            try tags(fields, required: 1...7)
            try uuid(fields[1]); try positiveU64(fields[2]); try digest(fields[3])
            try uuid(fields[4]); try uuid(fields[5]); try uuid(fields[6])
            try purgeCategorySequence(fields[7])
        case .purgeReceipt:
            try tags(fields, required: 1...11)
            try digest(fields[1]); try uuid(fields[2]); try positiveU64(fields[3]); try digest(fields[4])
            try uuid(fields[5]); try uuid(fields[6]); try uuid(fields[7])
            try purgeCategorySequence(fields[8])
            try oneOf(fields[9], ["completed", "partial", "failed"])
            try uuid(fields[10]); try opaque(fields[11])
        case .transitionCommit:
            try tags(fields, required: [1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 14], optional: [3, 9, 13])
            try uuid(fields[1]); let epoch = try positiveU64(fields[2])
            try validatePredecessor(epoch: epoch, predecessor: fields[3])
            try digest(fields[4]); try digest(fields[5]); try uuid(fields[6]); try digest(fields[7])
            try digestSequence(fields[8]); if fields[9] != nil { try digest(fields[9]) }
            try digestSequence(fields[10], allowEmpty: true)
            try digestSequence(fields[11], allowEmpty: true)
            if fields[13] != nil { try digest(fields[13]) }
            try uuid(fields[12]); try opaque(fields[14])
        case .controlRecords:
            try tags(fields, required: [1, 2, 3, 4, 6, 7], optional: [5, 8])
            try oneOf(fields[1], ["staged", "committed", "rejected"])
            try digest(fields[2]); try digest(fields[3]); try digestSequence(fields[4])
            if fields[5] != nil { try digest(fields[5]) }
            try digestSequence(fields[6], allowEmpty: true)
            try digestSequence(fields[7], allowEmpty: true)
            if fields[8] != nil { try digest(fields[8]) }
        case .freshnessCommitment:
            try tags(fields, required: 1...4)
            try uuid(fields[1]); try positiveU64(fields[2]); try digest(fields[3]); try digest(fields[4])
        case .sealedPayload:
            try boundRecord(fields, lastTag: 7)
            try opaque(fields[7])
        case .scopeHead:
            try fail()
        }
    }

    private static func boundRecord(_ fields: [UInt16: Data], lastTag: UInt16) throws {
        try tags(fields, required: Array(UInt16(1)...lastTag))
        try uuid(fields[1]); try digest(fields[2]); try positiveU64(fields[3])
        try digest(fields[4]); try uuid(fields[5])
        guard try u16Value(fields[6]) == 1 else { try fail() }
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

    private static func u16Value(_ value: Data?) throws -> UInt16 {
        guard let value, value.count == 2 else { try fail() }
        return value.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    @discardableResult
    private static func positiveU16(_ value: Data?) throws -> UInt16 {
        let decoded = try u16Value(value)
        guard decoded > 0 else { try fail() }
        return decoded
    }

    private static func u64Value(_ value: Data?) throws -> UInt64 {
        guard let value, value.count == 8 else { try fail() }
        return value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    @discardableResult
    private static func positiveU64(_ value: Data?) throws -> UInt64 {
        let decoded = try u64Value(value)
        guard decoded > 0 else { try fail() }
        return decoded
    }

    private static func opaque(_ value: Data?) throws {
        guard let value, !value.isEmpty, value.count <= 65_536 else { try fail() }
    }

    private static func algorithm(_ value: Data?) throws {
        guard let value, !value.isEmpty, value.count <= 128,
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

    private static func recoveryDescriptor(_ value: Data) throws -> Data {
        let values = try sequenceValues(value, allowEmpty: false)
        guard values.count == 7,
              values[1] == Data(RecoveryRecipientDescriptor.agreementAlgorithmIdentifier.utf8),
              values[4] == Data(RecoveryRecipientDescriptor.authorizationSigningAlgorithmIdentifier.utf8),
              values[2] != values[5], values[3] != values[6],
              values[3].count == 65, values[3].first == 0x04,
              values[6].count == 65, values[6].first == 0x04 else { try fail() }
        try uuid(values[0]); try algorithm(values[1]); try opaque(values[2]); try opaque(values[3])
        try algorithm(values[4]); try opaque(values[5]); try opaque(values[6])
        return values[0]
    }

    private static func uuidSequence(_ value: Data?) throws -> [Data] {
        let values = try validatedSequence(value, allowEmpty: false, element: uuid)
        try requireSortedUnique(values)
        return values
    }

    private static func digestSequence(_ value: Data?, allowEmpty: Bool = false) throws {
        let values = try validatedSequence(value, allowEmpty: allowEmpty, element: digest)
        try requireSortedUnique(values)
    }

    private static func purgeCategorySequence(_ value: Data?) throws {
        let allowed = Set(PurgeArtifactCategory.allCases.map(\.rawValue))
        let values = try validatedSequence(value, allowEmpty: false) { item in
            guard let item, let text = String(data: item, encoding: .utf8),
                  allowed.contains(text) else { try fail() }
        }
        try requireSortedUnique(values)
    }

    private static func validatedSequence(
        _ value: Data?,
        allowEmpty: Bool,
        element: (Data?) throws -> Void
    ) throws -> [Data] {
        guard let value else { try fail() }
        let values = try sequenceValues(value, allowEmpty: allowEmpty)
        for item in values { try element(item) }
        return values
    }

    private static func requireSortedUnique(_ values: [Data]) throws {
        for index in values.indices.dropFirst() {
            guard values[index - 1].lexicographicallyPrecedes(values[index]) else {
                try fail()
            }
        }
    }

    private static func validatePredecessor(epoch: UInt64, predecessor: Data?) throws {
        if epoch == 1 {
            guard predecessor == nil else { try fail() }
        } else {
            try digest(predecessor)
        }
    }

    private static func required(_ value: Data?) throws -> Data {
        guard let value else { try fail() }
        return value
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
