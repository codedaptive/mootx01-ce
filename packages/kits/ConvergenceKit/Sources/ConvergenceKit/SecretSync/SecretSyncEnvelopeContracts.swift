import Foundation

/// Immutable opaque ciphertext generation.
///
/// The contract binds ciphertext bytes to scope, snapshot, policy, and
/// generation identifiers. It does not expose plaintext or perform crypto.
public struct SealedPayload:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let scopeSnapshotDigest: SecretRecordDigest
    public let policyEpoch: UInt64
    public let policyDigest: SecretRecordDigest
    public let generationID: SecretGenerationID
    public let formatVersion: UInt16
    public let ciphertextBytes: Data

    public init(
        recordDigest: SecretRecordDigest,
        scopeID: SecretScopeID,
        scopeSnapshotDigest: SecretRecordDigest,
        policyEpoch: UInt64,
        policyDigest: SecretRecordDigest,
        generationID: SecretGenerationID,
        formatVersion: UInt16,
        ciphertextBytes: Data
    ) throws {
        try validateBoundOpaqueRecord(
            policyEpoch: policyEpoch,
            formatVersion: formatVersion,
            bytes: ciphertextBytes,
            field: "ciphertextBytes"
        )
        self.recordDigest = recordDigest
        self.scopeID = scopeID
        self.scopeSnapshotDigest = scopeSnapshotDigest
        self.policyEpoch = policyEpoch
        self.policyDigest = policyDigest
        self.generationID = generationID
        self.formatVersion = formatVersion
        self.ciphertextBytes = ciphertextBytes
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .sealedPayload
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        boundRecordFields(
            scopeID: scopeID,
            scopeSnapshotDigest: scopeSnapshotDigest,
            policyEpoch: policyEpoch,
            policyDigest: policyDigest,
            generationID: generationID,
            formatVersion: formatVersion
        ) + [SecretSyncCanonicalField(tag: 7, value: ciphertextBytes)]
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case scopeID
        case scopeSnapshotDigest
        case policyEpoch
        case policyDigest
        case generationID
        case formatVersion
        case ciphertextBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            scopeSnapshotDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .scopeSnapshotDigest
            ),
            policyEpoch: container.decode(UInt64.self, forKey: .policyEpoch),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            ),
            generationID: container.decode(
                SecretGenerationID.self,
                forKey: .generationID
            ),
            formatVersion: container.decode(UInt16.self, forKey: .formatVersion),
            ciphertextBytes: container.decode(Data.self, forKey: .ciphertextBytes)
        )
    }
}

/// Opaque per-device wrapped access to one sealed generation.
public struct RecipientKeyEnvelope:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let scopeSnapshotDigest: SecretRecordDigest
    public let policyEpoch: UInt64
    public let policyDigest: SecretRecordDigest
    public let generationID: SecretGenerationID
    public let recipientCredentialID: DeviceCredentialID
    public let formatVersion: UInt16
    public let wrappedKeyBytes: Data

    public init(
        recordDigest: SecretRecordDigest,
        scopeID: SecretScopeID,
        scopeSnapshotDigest: SecretRecordDigest,
        policyEpoch: UInt64,
        policyDigest: SecretRecordDigest,
        generationID: SecretGenerationID,
        recipientCredentialID: DeviceCredentialID,
        formatVersion: UInt16,
        wrappedKeyBytes: Data
    ) throws {
        try validateBoundOpaqueRecord(
            policyEpoch: policyEpoch,
            formatVersion: formatVersion,
            bytes: wrappedKeyBytes,
            field: "wrappedKeyBytes"
        )
        self.recordDigest = recordDigest
        self.scopeID = scopeID
        self.scopeSnapshotDigest = scopeSnapshotDigest
        self.policyEpoch = policyEpoch
        self.policyDigest = policyDigest
        self.generationID = generationID
        self.recipientCredentialID = recipientCredentialID
        self.formatVersion = formatVersion
        self.wrappedKeyBytes = wrappedKeyBytes
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .recipientKeyEnvelope
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        boundRecordFields(
            scopeID: scopeID,
            scopeSnapshotDigest: scopeSnapshotDigest,
            policyEpoch: policyEpoch,
            policyDigest: policyDigest,
            generationID: generationID,
            formatVersion: formatVersion
        ) + [
            SecretSyncCanonicalField(
                tag: 7,
                value: SecretSyncCanonicalValue.uuid(
                    recipientCredentialID.rawValue
                )
            ),
            SecretSyncCanonicalField(tag: 8, value: wrappedKeyBytes),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case scopeID
        case scopeSnapshotDigest
        case policyEpoch
        case policyDigest
        case generationID
        case recipientCredentialID
        case formatVersion
        case wrappedKeyBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            scopeSnapshotDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .scopeSnapshotDigest
            ),
            policyEpoch: container.decode(UInt64.self, forKey: .policyEpoch),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            ),
            generationID: container.decode(
                SecretGenerationID.self,
                forKey: .generationID
            ),
            recipientCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .recipientCredentialID
            ),
            formatVersion: container.decode(UInt16.self, forKey: .formatVersion),
            wrappedKeyBytes: container.decode(Data.self, forKey: .wrappedKeyBytes)
        )
    }
}

/// Recovery use is statically restricted to explicit break-glass flows.
public enum RecoveryEnvelopeUsage: String, Sendable, Codable, Hashable {
    case breakGlassRecoveryOnly
}

/// Opaque recovery wrapping, intentionally distinct from routine recipients.
public struct RecoveryEnvelope:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let scopeSnapshotDigest: SecretRecordDigest
    public let policyEpoch: UInt64
    public let policyDigest: SecretRecordDigest
    public let generationID: SecretGenerationID
    public let recoveryRecipientID: UUID
    public let usage: RecoveryEnvelopeUsage
    public let formatVersion: UInt16
    public let wrappedKeyBytes: Data

    public init(
        recordDigest: SecretRecordDigest,
        scopeID: SecretScopeID,
        scopeSnapshotDigest: SecretRecordDigest,
        policyEpoch: UInt64,
        policyDigest: SecretRecordDigest,
        generationID: SecretGenerationID,
        recoveryRecipientID: UUID,
        formatVersion: UInt16,
        wrappedKeyBytes: Data
    ) throws {
        try validateBoundOpaqueRecord(
            policyEpoch: policyEpoch,
            formatVersion: formatVersion,
            bytes: wrappedKeyBytes,
            field: "wrappedKeyBytes"
        )
        self.recordDigest = recordDigest
        self.scopeID = scopeID
        self.scopeSnapshotDigest = scopeSnapshotDigest
        self.policyEpoch = policyEpoch
        self.policyDigest = policyDigest
        self.generationID = generationID
        self.recoveryRecipientID = recoveryRecipientID
        self.usage = .breakGlassRecoveryOnly
        self.formatVersion = formatVersion
        self.wrappedKeyBytes = wrappedKeyBytes
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .recoveryEnvelope
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        boundRecordFields(
            scopeID: scopeID,
            scopeSnapshotDigest: scopeSnapshotDigest,
            policyEpoch: policyEpoch,
            policyDigest: policyDigest,
            generationID: generationID,
            formatVersion: formatVersion
        ) + [
            SecretSyncCanonicalField(
                tag: 7,
                value: SecretSyncCanonicalValue.uuid(recoveryRecipientID)
            ),
            SecretSyncCanonicalField(
                tag: 8,
                value: SecretSyncCanonicalValue.string(usage.rawValue)
            ),
            SecretSyncCanonicalField(tag: 9, value: wrappedKeyBytes),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case scopeID
        case scopeSnapshotDigest
        case policyEpoch
        case policyDigest
        case generationID
        case recoveryRecipientID
        case usage
        case formatVersion
        case wrappedKeyBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usage = try container.decode(RecoveryEnvelopeUsage.self, forKey: .usage)
        guard usage == .breakGlassRecoveryOnly else {
            throw SecretSyncContractError.invalidCanonicalDomain
        }
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            scopeSnapshotDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .scopeSnapshotDigest
            ),
            policyEpoch: container.decode(UInt64.self, forKey: .policyEpoch),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            ),
            generationID: container.decode(
                SecretGenerationID.self,
                forKey: .generationID
            ),
            recoveryRecipientID: container.decode(
                UUID.self,
                forKey: .recoveryRecipientID
            ),
            formatVersion: container.decode(UInt16.self, forKey: .formatVersion),
            wrappedKeyBytes: container.decode(Data.self, forKey: .wrappedKeyBytes)
        )
    }
}

private func validateBoundOpaqueRecord(
    policyEpoch: UInt64,
    formatVersion: UInt16,
    bytes: Data,
    field: String
) throws {
    guard policyEpoch > 0 else {
        throw SecretSyncContractError.invalidPolicyEpoch
    }
    guard formatVersion == 1 else {
        throw SecretSyncContractError.unsupportedSchemaVersion(formatVersion)
    }
    try SecretSyncContractBounds.requireOpaqueBytes(bytes, field: field)
}

private func boundRecordFields(
    scopeID: SecretScopeID,
    scopeSnapshotDigest: SecretRecordDigest,
    policyEpoch: UInt64,
    policyDigest: SecretRecordDigest,
    generationID: SecretGenerationID,
    formatVersion: UInt16
) -> [SecretSyncCanonicalField] {
    [
        SecretSyncCanonicalField(
            tag: 1,
            value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)
        ),
        SecretSyncCanonicalField(tag: 2, value: scopeSnapshotDigest.bytes),
        SecretSyncCanonicalField(
            tag: 3,
            value: SecretSyncCanonicalValue.uint64(policyEpoch)
        ),
        SecretSyncCanonicalField(tag: 4, value: policyDigest.bytes),
        SecretSyncCanonicalField(
            tag: 5,
            value: SecretSyncCanonicalValue.uuid(generationID.rawValue)
        ),
        SecretSyncCanonicalField(
            tag: 6,
            value: SecretSyncCanonicalValue.uint16(formatVersion)
        ),
    ]
}
