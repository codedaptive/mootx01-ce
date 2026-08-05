import Foundation

/// Exact, product-supplied membership snapshot for one Secret scope.
///
/// ConvergenceKit stores and validates the supplied set; it never derives a
/// product tree or silently includes future records.
public struct SecretScopeSnapshot:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let scopeID: SecretScopeID
    public let rootRecordID: UUID
    public let memberRecordIDs: [UUID]
    public let snapshotDigest: SecretRecordDigest

    public init(
        scopeID: SecretScopeID,
        rootRecordID: UUID,
        memberRecordIDs: [UUID],
        snapshotDigest: SecretRecordDigest
    ) throws {
        self.scopeID = scopeID
        self.rootRecordID = rootRecordID
        self.memberRecordIDs = try SecretSyncContractBounds.sortedUniqueUUIDs(
            memberRecordIDs,
            field: "memberRecordIDs"
        )
        self.snapshotDigest = snapshotDigest
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .secretScopeSnapshot
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uuid(rootRecordID)
            ),
            SecretSyncCanonicalField(
                tag: 3,
                value: try SecretSyncCanonicalValue.sequence(
                    memberRecordIDs.map(SecretSyncCanonicalValue.uuid)
                )
            ),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case scopeID
        case rootRecordID
        case memberRecordIDs
        case snapshotDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            rootRecordID: container.decode(UUID.self, forKey: .rootRecordID),
            memberRecordIDs: container.decode([UUID].self, forKey: .memberRecordIDs),
            snapshotDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .snapshotDigest
            )
        )
    }
}

/// Separately typed break-glass recovery recipient.
///
/// A recovery recipient is never inserted into the routine device credential
/// audience and cannot be interpreted as a `DeviceCredentialID`.
public struct RecoveryRecipientDescriptor: Sendable, Codable, Hashable {
    public static let agreementAlgorithmIdentifier =
        "mootx01.secret-recovery.hkdf-sha256-p256-agreement.v2"
    public static let authorizationSigningAlgorithmIdentifier =
        "mootx01.secret-recovery.hkdf-sha256-p256-ecdsa-sha256-authorization.v2"

    public let recoveryRecipientID: UUID
    public let keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor
    public let authorizationSigningPublicKey: SigningPublicKeyDescriptor

    public init(
        recoveryRecipientID: UUID,
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor,
        authorizationSigningPublicKey: SigningPublicKeyDescriptor
    ) throws {
        guard
            keyAgreementPublicKey.algorithmIdentifier
                == Self.agreementAlgorithmIdentifier,
            authorizationSigningPublicKey.algorithmIdentifier
                == Self.authorizationSigningAlgorithmIdentifier,
            keyAgreementPublicKey.publicKeyBytes.count == 65,
            keyAgreementPublicKey.publicKeyBytes.first == 0x04,
            authorizationSigningPublicKey.publicKeyBytes.count == 65,
            authorizationSigningPublicKey.publicKeyBytes.first == 0x04
        else {
            throw SecretSyncContractError.invalidRecoveryDescriptor
        }
        guard
            keyAgreementPublicKey.keyIdentifier
                != authorizationSigningPublicKey.keyIdentifier,
            keyAgreementPublicKey.publicKeyBytes
                != authorizationSigningPublicKey.publicKeyBytes
        else {
            throw SecretSyncContractError.keyRoleReuse
        }
        self.recoveryRecipientID = recoveryRecipientID
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.authorizationSigningPublicKey = authorizationSigningPublicKey
    }

    func canonicalValue() throws -> Data {
        try SecretSyncCanonicalValue.sequence([
            SecretSyncCanonicalValue.uuid(recoveryRecipientID),
            SecretSyncCanonicalValue.string(
                keyAgreementPublicKey.algorithmIdentifier
            ),
            keyAgreementPublicKey.keyIdentifier,
            keyAgreementPublicKey.publicKeyBytes,
            SecretSyncCanonicalValue.string(
                authorizationSigningPublicKey.algorithmIdentifier
            ),
            authorizationSigningPublicKey.keyIdentifier,
            authorizationSigningPublicKey.publicKeyBytes,
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case recoveryRecipientID
        case keyAgreementPublicKey
        case authorizationSigningPublicKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recoveryRecipientID: container.decode(
                UUID.self,
                forKey: .recoveryRecipientID
            ),
            keyAgreementPublicKey: container.decode(
                KeyAgreementPublicKeyDescriptor.self,
                forKey: .keyAgreementPublicKey
            ),
            authorizationSigningPublicKey: container.decode(
                SigningPublicKeyDescriptor.self,
                forKey: .authorizationSigningPublicKey
            )
        )
    }
}

/// Immutable authorization policy for one monotonically increasing epoch.
public struct SecretPolicyEpoch:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let schemaVersion: UInt16
    public let epoch: UInt64
    public let predecessorPolicyDigest: SecretRecordDigest?
    public let scopeSnapshot: SecretScopeSnapshot
    public let generationID: SecretGenerationID
    public let authorizedRecipientCredentialIDs: [DeviceCredentialID]
    public let trustedDeviceRecordDigests: [SecretRecordDigest]
    public let recoveryRecipient: RecoveryRecipientDescriptor?
    public let signerCredentialID: DeviceCredentialID

    public init(
        schemaVersion: UInt16 = SecretSyncCanonicalEncoding.schemaVersion,
        epoch: UInt64,
        predecessorPolicyDigest: SecretRecordDigest?,
        scopeSnapshot: SecretScopeSnapshot,
        generationID: SecretGenerationID,
        authorizedRecipientCredentialIDs: [DeviceCredentialID],
        trustedDeviceRecordDigests: [SecretRecordDigest],
        recoveryRecipient: RecoveryRecipientDescriptor?,
        signerCredentialID: DeviceCredentialID
    ) throws {
        guard schemaVersion == SecretSyncCanonicalEncoding.schemaVersion else {
            throw SecretSyncContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard epoch > 0 else {
            throw SecretSyncContractError.invalidPolicyEpoch
        }
        if epoch == 1, predecessorPolicyDigest != nil {
            throw SecretSyncContractError.unexpectedPredecessor
        }
        if epoch > 1, predecessorPolicyDigest == nil {
            throw SecretSyncContractError.missingPredecessor
        }

        let sortedRecipientUUIDs = try SecretSyncContractBounds.sortedUniqueUUIDs(
            authorizedRecipientCredentialIDs.map(\.rawValue),
            field: "authorizedRecipientCredentialIDs"
        )
        if let recoveryRecipient,
           sortedRecipientUUIDs.contains(recoveryRecipient.recoveryRecipientID)
        {
            throw SecretSyncContractError.recoveryRecipientIsRoutineRecipient
        }

        self.schemaVersion = schemaVersion
        self.epoch = epoch
        self.predecessorPolicyDigest = predecessorPolicyDigest
        self.scopeSnapshot = scopeSnapshot
        self.generationID = generationID
        self.authorizedRecipientCredentialIDs = sortedRecipientUUIDs.map {
            DeviceCredentialID($0)
        }
        self.trustedDeviceRecordDigests = try sortedUniquePolicyDigests(
            trustedDeviceRecordDigests
        )
        self.recoveryRecipient = recoveryRecipient
        self.signerCredentialID = signerCredentialID
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .secretPolicyEpoch
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        var fields = [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uint16(schemaVersion)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uint64(epoch)
            ),
            SecretSyncCanonicalField(
                tag: 4,
                value: try scopeSnapshot.canonicalBytes()
            ),
            SecretSyncCanonicalField(
                tag: 5,
                value: scopeSnapshot.snapshotDigest.bytes
            ),
            SecretSyncCanonicalField(
                tag: 6,
                value: SecretSyncCanonicalValue.uuid(generationID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 7,
                value: try SecretSyncCanonicalValue.sequence(
                    authorizedRecipientCredentialIDs.map {
                        SecretSyncCanonicalValue.uuid($0.rawValue)
                    }
                )
            ),
            SecretSyncCanonicalField(
                tag: 8,
                value: try SecretSyncCanonicalValue.sequence(
                    trustedDeviceRecordDigests.map(\.bytes)
                )
            ),
            SecretSyncCanonicalField(
                tag: 10,
                value: SecretSyncCanonicalValue.uuid(signerCredentialID.rawValue)
            ),
        ]
        if let predecessorPolicyDigest {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 3,
                    value: predecessorPolicyDigest.bytes
                )
            )
        }
        if let recoveryRecipient {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 9,
                    value: try recoveryRecipient.canonicalValue()
                )
            )
        }
        return fields
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case epoch
        case predecessorPolicyDigest
        case scopeSnapshot
        case generationID
        case authorizedRecipientCredentialIDs
        case trustedDeviceRecordDigests
        case recoveryRecipient
        case signerCredentialID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            epoch: container.decode(UInt64.self, forKey: .epoch),
            predecessorPolicyDigest: container.decodeIfPresent(
                SecretRecordDigest.self,
                forKey: .predecessorPolicyDigest
            ),
            scopeSnapshot: container.decode(
                SecretScopeSnapshot.self,
                forKey: .scopeSnapshot
            ),
            generationID: container.decode(
                SecretGenerationID.self,
                forKey: .generationID
            ),
            authorizedRecipientCredentialIDs: container.decode(
                [DeviceCredentialID].self,
                forKey: .authorizedRecipientCredentialIDs
            ),
            trustedDeviceRecordDigests: container.decode(
                [SecretRecordDigest].self,
                forKey: .trustedDeviceRecordDigests
            ),
            recoveryRecipient: container.decodeIfPresent(
                RecoveryRecipientDescriptor.self,
                forKey: .recoveryRecipient
            ),
            signerCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .signerCredentialID
            )
        )
    }
}

private func sortedUniquePolicyDigests(
    _ values: [SecretRecordDigest]
) throws -> [SecretRecordDigest] {
    guard !values.isEmpty else {
        throw SecretSyncContractError.emptySet(
            field: "trustedDeviceRecordDigests"
        )
    }
    let sorted = values.sorted {
        $0.bytes.lexicographicallyPrecedes($1.bytes)
    }
    for index in sorted.indices.dropFirst() where sorted[index] == sorted[index - 1] {
        throw SecretSyncContractError.duplicateIdentifier(
            field: "trustedDeviceRecordDigests"
        )
    }
    return sorted
}

/// Signature-verification seam for later audited implementations.
///
/// The verifier receives canonical bytes and a public descriptor. This
/// protocol does not select an algorithm or provide an implementation.
public protocol SecretSignatureVerifying: Sendable {
    func verify(
        signature: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool
}

/// Content-addressed signed wrapper for an immutable policy epoch.
public struct SignedSecretPolicyEpoch:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let policy: SecretPolicyEpoch
    public let signature: Data

    public init(
        recordDigest: SecretRecordDigest,
        policy: SecretPolicyEpoch,
        signature: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            signature,
            field: "policySignature"
        )
        self.recordDigest = recordDigest
        self.policy = policy
        self.signature = signature
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .signedSecretPolicyEpoch
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(tag: 1, value: try policy.canonicalBytes()),
            SecretSyncCanonicalField(tag: 2, value: signature),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case policy
        case signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            policy: container.decode(SecretPolicyEpoch.self, forKey: .policy),
            signature: container.decode(Data.self, forKey: .signature)
        )
    }
}
