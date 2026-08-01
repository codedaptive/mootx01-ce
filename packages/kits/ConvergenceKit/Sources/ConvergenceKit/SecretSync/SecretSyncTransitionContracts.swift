import Foundation

/// Artifact classes that must be purged before normal admission resumes.
public enum PurgeArtifactCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case plaintext
    case localCache
    case searchIndex
    case embedding
    case spotlightDonation
    case notification
    case widget
    case archive
    case preview
    case derivedProjection
}

/// Immutable instruction requiring one credential holder to purge exact
/// artifact categories for a superseded plaintext generation.
public struct PurgeRequirement:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let policyEpoch: UInt64
    public let policyDigest: SecretRecordDigest
    public let supersededGenerationID: SecretGenerationID
    public let replacementGenerationID: SecretGenerationID
    public let targetCredentialID: DeviceCredentialID
    public let requiredCategories: [PurgeArtifactCategory]

    public init(
        recordDigest: SecretRecordDigest,
        scopeID: SecretScopeID,
        policyEpoch: UInt64,
        policyDigest: SecretRecordDigest,
        supersededGenerationID: SecretGenerationID,
        replacementGenerationID: SecretGenerationID,
        targetCredentialID: DeviceCredentialID,
        requiredCategories: [PurgeArtifactCategory]
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncContractError.invalidPolicyEpoch
        }
        self.recordDigest = recordDigest
        self.scopeID = scopeID
        self.policyEpoch = policyEpoch
        self.policyDigest = policyDigest
        self.supersededGenerationID = supersededGenerationID
        self.replacementGenerationID = replacementGenerationID
        self.targetCredentialID = targetCredentialID
        self.requiredCategories = try sortedUniqueCategories(
            requiredCategories,
            field: "requiredCategories"
        )
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .purgeRequirement
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uint64(policyEpoch)
            ),
            SecretSyncCanonicalField(tag: 3, value: policyDigest.bytes),
            SecretSyncCanonicalField(
                tag: 4,
                value: SecretSyncCanonicalValue.uuid(
                    supersededGenerationID.rawValue
                )
            ),
            SecretSyncCanonicalField(
                tag: 5,
                value: SecretSyncCanonicalValue.uuid(
                    replacementGenerationID.rawValue
                )
            ),
            SecretSyncCanonicalField(
                tag: 6,
                value: SecretSyncCanonicalValue.uuid(targetCredentialID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 7,
                value: try SecretSyncCanonicalValue.sequence(
                    requiredCategories.map {
                        SecretSyncCanonicalValue.string($0.rawValue)
                    }
                )
            ),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case scopeID
        case policyEpoch
        case policyDigest
        case supersededGenerationID
        case replacementGenerationID
        case targetCredentialID
        case requiredCategories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            policyEpoch: container.decode(UInt64.self, forKey: .policyEpoch),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            ),
            supersededGenerationID: container.decode(
                SecretGenerationID.self,
                forKey: .supersededGenerationID
            ),
            replacementGenerationID: container.decode(
                SecretGenerationID.self,
                forKey: .replacementGenerationID
            ),
            targetCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .targetCredentialID
            ),
            requiredCategories: container.decode(
                [PurgeArtifactCategory].self,
                forKey: .requiredCategories
            )
        )
    }
}

/// A purge receipt is admissible only when every required category completed.
public enum PurgeReceiptStatus: String, Sendable, Codable, Hashable {
    case completed
    case partial
    case failed
}

/// Signed, content-addressed evidence for one purge requirement.
public struct SignedPurgeReceipt:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let requirementDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let policyEpoch: UInt64
    public let policyDigest: SecretRecordDigest
    public let supersededGenerationID: SecretGenerationID
    public let replacementGenerationID: SecretGenerationID
    public let respondingCredentialID: DeviceCredentialID
    public let coveredCategories: [PurgeArtifactCategory]
    public let status: PurgeReceiptStatus
    public let signerCredentialID: DeviceCredentialID
    public let signature: Data

    public init(
        recordDigest: SecretRecordDigest,
        requirementDigest: SecretRecordDigest,
        scopeID: SecretScopeID,
        policyEpoch: UInt64,
        policyDigest: SecretRecordDigest,
        supersededGenerationID: SecretGenerationID,
        replacementGenerationID: SecretGenerationID,
        respondingCredentialID: DeviceCredentialID,
        coveredCategories: [PurgeArtifactCategory],
        status: PurgeReceiptStatus,
        signerCredentialID: DeviceCredentialID,
        signature: Data
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncContractError.invalidPolicyEpoch
        }
        try SecretSyncContractBounds.requireOpaqueBytes(
            signature,
            field: "purgeReceiptSignature"
        )
        self.recordDigest = recordDigest
        self.requirementDigest = requirementDigest
        self.scopeID = scopeID
        self.policyEpoch = policyEpoch
        self.policyDigest = policyDigest
        self.supersededGenerationID = supersededGenerationID
        self.replacementGenerationID = replacementGenerationID
        self.respondingCredentialID = respondingCredentialID
        self.coveredCategories = try sortedUniqueCategories(
            coveredCategories,
            field: "coveredCategories"
        )
        self.status = status
        self.signerCredentialID = signerCredentialID
        self.signature = signature
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .purgeReceipt
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        try unsignedFields()
            + [SecretSyncCanonicalField(tag: 11, value: signature)]
    }

    public func signingBytes() throws -> Data {
        try SecretSyncCanonicalEncoding.encode(
            domain: .purgeReceipt,
            fields: unsignedFields()
        )
    }

    private func unsignedFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(tag: 1, value: requirementDigest.bytes),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 3,
                value: SecretSyncCanonicalValue.uint64(policyEpoch)
            ),
            SecretSyncCanonicalField(
                tag: 4,
                value: policyDigest.bytes
            ),
            SecretSyncCanonicalField(
                tag: 5,
                value: SecretSyncCanonicalValue.uuid(
                    supersededGenerationID.rawValue
                )
            ),
            SecretSyncCanonicalField(
                tag: 6,
                value: SecretSyncCanonicalValue.uuid(
                    replacementGenerationID.rawValue
                )
            ),
            SecretSyncCanonicalField(
                tag: 7,
                value: SecretSyncCanonicalValue.uuid(
                    respondingCredentialID.rawValue
                )
            ),
            SecretSyncCanonicalField(
                tag: 8,
                value: try SecretSyncCanonicalValue.sequence(
                    coveredCategories.map {
                        SecretSyncCanonicalValue.string($0.rawValue)
                    }
                )
            ),
            SecretSyncCanonicalField(
                tag: 9,
                value: SecretSyncCanonicalValue.string(status.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 10,
                value: SecretSyncCanonicalValue.uuid(signerCredentialID.rawValue)
            ),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case requirementDigest
        case scopeID
        case policyEpoch
        case policyDigest
        case supersededGenerationID
        case replacementGenerationID
        case respondingCredentialID
        case coveredCategories
        case status
        case signerCredentialID
        case signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            requirementDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .requirementDigest
            ),
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            policyEpoch: container.decode(UInt64.self, forKey: .policyEpoch),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            ),
            supersededGenerationID: container.decode(
                SecretGenerationID.self,
                forKey: .supersededGenerationID
            ),
            replacementGenerationID: container.decode(
                SecretGenerationID.self,
                forKey: .replacementGenerationID
            ),
            respondingCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .respondingCredentialID
            ),
            coveredCategories: container.decode(
                [PurgeArtifactCategory].self,
                forKey: .coveredCategories
            ),
            status: container.decode(PurgeReceiptStatus.self, forKey: .status),
            signerCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .signerCredentialID
            ),
            signature: container.decode(Data.self, forKey: .signature)
        )
    }
}

/// Short vocabulary used by the readable charter.
public typealias PurgeReceipt = SignedPurgeReceipt

/// Lifecycle state of an immutable transition record set.
public enum SecretTransitionState: String, Sendable, Codable, Hashable {
    case staged
    case committed
    case rejected
}

/// Signed certificate referencing every exact record in one transition.
public struct SecretTransitionCommit:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let policyEpoch: UInt64
    public let predecessorCommitDigest: SecretRecordDigest?
    public let policyDigest: SecretRecordDigest
    public let scopeSnapshotDigest: SecretRecordDigest
    public let generationID: SecretGenerationID
    public let sealedPayloadDigest: SecretRecordDigest
    public let recipientEnvelopeDigests: [SecretRecordDigest]
    public let recoveryEnvelopeDigest: SecretRecordDigest?
    public let purgeRequirementDigests: [SecretRecordDigest]
    public let purgeReceiptDigests: [SecretRecordDigest]
    public let recoveryAuthorizationDigest: SecretRecordDigest?
    public let signerCredentialID: DeviceCredentialID
    public let signature: Data

    public init(
        recordDigest: SecretRecordDigest,
        scopeID: SecretScopeID,
        policyEpoch: UInt64,
        predecessorCommitDigest: SecretRecordDigest?,
        policyDigest: SecretRecordDigest,
        scopeSnapshotDigest: SecretRecordDigest,
        generationID: SecretGenerationID,
        sealedPayloadDigest: SecretRecordDigest,
        recipientEnvelopeDigests: [SecretRecordDigest],
        recoveryEnvelopeDigest: SecretRecordDigest?,
        purgeRequirementDigests: [SecretRecordDigest],
        purgeReceiptDigests: [SecretRecordDigest],
        recoveryAuthorizationDigest: SecretRecordDigest?,
        signerCredentialID: DeviceCredentialID,
        signature: Data
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncContractError.invalidPolicyEpoch
        }
        if policyEpoch == 1, predecessorCommitDigest != nil {
            throw SecretSyncContractError.unexpectedPredecessor
        }
        if policyEpoch > 1, predecessorCommitDigest == nil {
            throw SecretSyncContractError.missingPredecessor
        }
        try SecretSyncContractBounds.requireOpaqueBytes(
            signature,
            field: "transitionCommitSignature"
        )
        self.recordDigest = recordDigest
        self.scopeID = scopeID
        self.policyEpoch = policyEpoch
        self.predecessorCommitDigest = predecessorCommitDigest
        self.policyDigest = policyDigest
        self.scopeSnapshotDigest = scopeSnapshotDigest
        self.generationID = generationID
        self.sealedPayloadDigest = sealedPayloadDigest
        self.recipientEnvelopeDigests = try sortedUniqueDigests(
            recipientEnvelopeDigests,
            field: "recipientEnvelopeDigests"
        )
        self.recoveryEnvelopeDigest = recoveryEnvelopeDigest
        self.purgeRequirementDigests = try sortedUniqueDigests(
            purgeRequirementDigests,
            field: "purgeRequirementDigests",
            allowEmpty: true
        )
        self.purgeReceiptDigests = try sortedUniqueDigests(
            purgeReceiptDigests,
            field: "purgeReceiptDigests",
            allowEmpty: true
        )
        self.recoveryAuthorizationDigest = recoveryAuthorizationDigest
        self.signerCredentialID = signerCredentialID
        self.signature = signature
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .secretTransitionCommit
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        try unsignedFields()
            + [SecretSyncCanonicalField(tag: 14, value: signature)]
    }

    public func signingBytes() throws -> Data {
        try SecretSyncCanonicalEncoding.encode(
            domain: .secretTransitionCommit,
            fields: unsignedFields()
        )
    }

    private func unsignedFields() throws -> [SecretSyncCanonicalField] {
        var fields = [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uint64(policyEpoch)
            ),
            SecretSyncCanonicalField(tag: 4, value: policyDigest.bytes),
            SecretSyncCanonicalField(tag: 5, value: scopeSnapshotDigest.bytes),
            SecretSyncCanonicalField(
                tag: 6,
                value: SecretSyncCanonicalValue.uuid(generationID.rawValue)
            ),
            SecretSyncCanonicalField(tag: 7, value: sealedPayloadDigest.bytes),
            SecretSyncCanonicalField(
                tag: 8,
                value: try SecretSyncCanonicalValue.sequence(
                    recipientEnvelopeDigests.map(\.bytes)
                )
            ),
            SecretSyncCanonicalField(
                tag: 10,
                value: try SecretSyncCanonicalValue.sequence(
                    purgeRequirementDigests.map(\.bytes)
                )
            ),
            SecretSyncCanonicalField(
                tag: 11,
                value: try SecretSyncCanonicalValue.sequence(
                    purgeReceiptDigests.map(\.bytes)
                )
            ),
            SecretSyncCanonicalField(
                tag: 12,
                value: SecretSyncCanonicalValue.uuid(signerCredentialID.rawValue)
            ),
        ]
        if let predecessorCommitDigest {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 3,
                    value: predecessorCommitDigest.bytes
                )
            )
        }
        if let recoveryEnvelopeDigest {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 9,
                    value: recoveryEnvelopeDigest.bytes
                )
            )
        }
        if let recoveryAuthorizationDigest {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 13,
                    value: recoveryAuthorizationDigest.bytes
                )
            )
        }
        return fields
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest
        case scopeID
        case policyEpoch
        case predecessorCommitDigest
        case policyDigest
        case scopeSnapshotDigest
        case generationID
        case sealedPayloadDigest
        case recipientEnvelopeDigests
        case recoveryEnvelopeDigest
        case purgeRequirementDigests
        case purgeReceiptDigests
        case recoveryAuthorizationDigest
        case signerCredentialID
        case signature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            policyEpoch: container.decode(UInt64.self, forKey: .policyEpoch),
            predecessorCommitDigest: container.decodeIfPresent(
                SecretRecordDigest.self,
                forKey: .predecessorCommitDigest
            ),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            ),
            scopeSnapshotDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .scopeSnapshotDigest
            ),
            generationID: container.decode(
                SecretGenerationID.self,
                forKey: .generationID
            ),
            sealedPayloadDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .sealedPayloadDigest
            ),
            recipientEnvelopeDigests: container.decode(
                [SecretRecordDigest].self,
                forKey: .recipientEnvelopeDigests
            ),
            recoveryEnvelopeDigest: container.decodeIfPresent(
                SecretRecordDigest.self,
                forKey: .recoveryEnvelopeDigest
            ),
            purgeRequirementDigests: container.decode(
                [SecretRecordDigest].self,
                forKey: .purgeRequirementDigests
            ),
            purgeReceiptDigests: container.decode(
                [SecretRecordDigest].self,
                forKey: .purgeReceiptDigests
            ),
            recoveryAuthorizationDigest: container.decodeIfPresent(
                SecretRecordDigest.self,
                forKey: .recoveryAuthorizationDigest
            ),
            signerCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .signerCredentialID
            ),
            signature: container.decode(Data.self, forKey: .signature)
        )
    }
}

/// Complete immutable record set that must validate as a unit before commit.
public struct SecretControlRecords:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let state: SecretTransitionState
    public let signedPolicy: SignedSecretPolicyEpoch
    public let sealedPayload: SealedPayload
    public let recipientEnvelopes: [RecipientKeyEnvelope]
    public let recoveryEnvelope: RecoveryEnvelope?
    public let purgeRequirements: [PurgeRequirement]
    public let purgeReceipts: [SignedPurgeReceipt]
    public let recoveryAuthorization: FullLossRecoveryAuthorization?

    public init(
        state: SecretTransitionState,
        signedPolicy: SignedSecretPolicyEpoch,
        sealedPayload: SealedPayload,
        recipientEnvelopes: [RecipientKeyEnvelope],
        recoveryEnvelope: RecoveryEnvelope?,
        purgeRequirements: [PurgeRequirement],
        purgeReceipts: [SignedPurgeReceipt],
        recoveryAuthorization: FullLossRecoveryAuthorization?
    ) throws {
        self.state = state
        self.signedPolicy = signedPolicy
        self.sealedPayload = sealedPayload
        self.recipientEnvelopes = try sortedUniqueRecords(
            recipientEnvelopes,
            digest: \.recordDigest,
            field: "recipientEnvelopes"
        )
        self.recoveryEnvelope = recoveryEnvelope
        self.purgeRequirements = try sortedUniqueRecords(
            purgeRequirements,
            digest: \.recordDigest,
            field: "purgeRequirements",
            allowEmpty: true
        )
        self.purgeReceipts = try sortedUniqueRecords(
            purgeReceipts,
            digest: \.recordDigest,
            field: "purgeReceipts",
            allowEmpty: true
        )
        self.recoveryAuthorization = recoveryAuthorization
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .secretControlRecords
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        var fields = [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.string(state.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: signedPolicy.recordDigest.bytes
            ),
            SecretSyncCanonicalField(
                tag: 3,
                value: sealedPayload.recordDigest.bytes
            ),
            SecretSyncCanonicalField(
                tag: 4,
                value: try SecretSyncCanonicalValue.sequence(
                    recipientEnvelopes.map(\.recordDigest.bytes)
                )
            ),
            SecretSyncCanonicalField(
                tag: 6,
                value: try SecretSyncCanonicalValue.sequence(
                    purgeRequirements.map(\.recordDigest.bytes)
                )
            ),
            SecretSyncCanonicalField(
                tag: 7,
                value: try SecretSyncCanonicalValue.sequence(
                    purgeReceipts.map(\.recordDigest.bytes)
                )
            ),
        ]
        if let recoveryEnvelope {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 5,
                    value: recoveryEnvelope.recordDigest.bytes
                )
            )
        }
        if let recoveryAuthorization {
            fields.append(
                SecretSyncCanonicalField(
                    tag: 8,
                    value: recoveryAuthorization.recordDigest.bytes
                )
            )
        }
        return fields
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case signedPolicy
        case sealedPayload
        case recipientEnvelopes
        case recoveryEnvelope
        case purgeRequirements
        case purgeReceipts
        case recoveryAuthorization
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: container.decode(SecretTransitionState.self, forKey: .state),
            signedPolicy: container.decode(
                SignedSecretPolicyEpoch.self,
                forKey: .signedPolicy
            ),
            sealedPayload: container.decode(
                SealedPayload.self,
                forKey: .sealedPayload
            ),
            recipientEnvelopes: container.decode(
                [RecipientKeyEnvelope].self,
                forKey: .recipientEnvelopes
            ),
            recoveryEnvelope: container.decodeIfPresent(
                RecoveryEnvelope.self,
                forKey: .recoveryEnvelope
            ),
            purgeRequirements: container.decode(
                [PurgeRequirement].self,
                forKey: .purgeRequirements
            ),
            purgeReceipts: container.decode(
                [SignedPurgeReceipt].self,
                forKey: .purgeReceipts
            ),
            recoveryAuthorization: container.decodeIfPresent(
                FullLossRecoveryAuthorization.self,
                forKey: .recoveryAuthorization
            )
        )
    }

    func committedCopy() throws -> SecretControlRecords {
        try SecretControlRecords(
            state: .committed,
            signedPolicy: signedPolicy,
            sealedPayload: sealedPayload,
            recipientEnvelopes: recipientEnvelopes,
            recoveryEnvelope: recoveryEnvelope,
            purgeRequirements: purgeRequirements,
            purgeReceipts: purgeReceipts,
            recoveryAuthorization: recoveryAuthorization
        )
    }
}

/// Validated view of one authoritative committed head and its exact records.
///
/// Construction is module-internal so external callers cannot manufacture an
/// authoritative head without passing `SecretPolicyValidator`.
public struct SecretControlSnapshot: Sendable, Hashable {
    public var state: SecretTransitionState { .committed }
    public let commit: SecretTransitionCommit
    public let records: SecretControlRecords
    public let trustedDeviceRecords: [DeviceTrustRecord]

    init(
        commit: SecretTransitionCommit,
        records: SecretControlRecords,
        trustedDeviceRecords: [DeviceTrustRecord]
    ) throws {
        guard records.state == .committed else {
            throw SecretPolicyValidationError.currentHeadNotCommitted
        }
        self.commit = commit
        self.records = records
        self.trustedDeviceRecords = trustedDeviceRecords
    }
}

/// Commitment supplied by a source independent of the local hydrated store.
public struct SecretBootstrapFreshnessCommitment:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let scopeID: SecretScopeID
    public let latestPolicyEpoch: UInt64
    public let headCommitDigest: SecretRecordDigest
    public let policyDigest: SecretRecordDigest

    public init(
        scopeID: SecretScopeID,
        latestPolicyEpoch: UInt64,
        headCommitDigest: SecretRecordDigest,
        policyDigest: SecretRecordDigest
    ) throws {
        guard latestPolicyEpoch > 0 else {
            throw SecretSyncContractError.invalidPolicyEpoch
        }
        self.scopeID = scopeID
        self.latestPolicyEpoch = latestPolicyEpoch
        self.headCommitDigest = headCommitDigest
        self.policyDigest = policyDigest
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .bootstrapFreshnessCommitment
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uint64(latestPolicyEpoch)
            ),
            SecretSyncCanonicalField(tag: 3, value: headCommitDigest.bytes),
            SecretSyncCanonicalField(tag: 4, value: policyDigest.bytes),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case scopeID
        case latestPolicyEpoch
        case headCommitDigest
        case policyDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scopeID: container.decode(SecretScopeID.self, forKey: .scopeID),
            latestPolicyEpoch: container.decode(
                UInt64.self,
                forKey: .latestPolicyEpoch
            ),
            headCommitDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .headCommitDigest
            ),
            policyDigest: container.decode(
                SecretRecordDigest.self,
                forKey: .policyDigest
            )
        )
    }
}

/// A nonlocal source of the latest policy/head commitment.
///
/// Local database state cannot conform implicitly; callers must supply a
/// separately obtained implementation such as an enrolled peer or recovery
/// checkpoint in a later, independently gated mission.
public protocol ExternalBootstrapFreshnessAnchor: Sendable {
    func latestCommitment(
        for scopeID: SecretScopeID
    ) async throws -> SecretBootstrapFreshnessCommitment
}

/// Explicit fail-closed outcomes for pure Secret policy validation.
public enum SecretPolicyValidationError: Error, Sendable, Equatable {
    case enrollmentChallengeMismatch
    case enrollmentAuthorityMismatch
    case signerNotTrusted
    case duplicateTrustedCredential
    case duplicateTrustRecord
    case trustedDeviceMismatch
    case trustRecordNotEffective
    case trustRecordSetMismatch
    case staleTrustRecord
    case revokedCredentialReplay
    case recipientNotTrusted
    case signatureRejected
    case digestMismatch(domain: SecretSyncCanonicalDomain)
    case lowerEpoch
    case sameEpochFork
    case replayedHead
    case wrongPredecessor
    case samePredecessorForkDecisionRequired
    case scopeMismatch
    case generationMismatch
    case generationNotRotated
    case policyMismatch
    case recipientSetMismatch
    case recoveryMismatch
    case recoveryAuthorizationUnexpected
    case recoveryAuthorizationMismatch
    case fullLossRecoveryCurrentAuthorityMissing
    case fullLossRecoveryChallengeExpired
    case fullLossRecoveryProofRejected
    case fullLossRecoveryCandidateMismatch
    case fullLossRecoveryTrustMismatch
    case fullLossRecoveryPurgeMismatch
    case incompletePurgeReceipts
    case purgeCoverageMismatch
    case stagedStateRequired
    case currentHeadNotCommitted
    case staleExternalFreshness
    case externalFreshnessFork
    case referenceMismatch(field: String)
}

/// Pure admission validator for immutable policy and transition records.
public enum SecretPolicyValidator {
    public static func validateEnrollment(
        _ candidate: TrustedDeviceCredential,
        expectedChallengeID: UUID,
        authorityCredential: TrustedDeviceCredential,
        signatureVerifier: any SecretSignatureVerifying
    ) throws {
        guard candidate.enrollmentProof.challengeID == expectedChallengeID else {
            throw SecretPolicyValidationError.enrollmentChallengeMismatch
        }
        guard
            let authority = candidate.enrollmentProof.trustedDeviceAuthority,
            authority.credentialID == authorityCredential.credentialID,
            authorityCredential.status == .active
        else {
            throw SecretPolicyValidationError.enrollmentAuthorityMismatch
        }
        guard try signatureVerifier.verify(
            signature: authority.signature,
            canonicalBytes: candidate.enrollmentSigningBytes(),
            signingPublicKey: authorityCredential.signingPublicKey
        ) else {
            throw SecretPolicyValidationError.signatureRejected
        }
    }

    public static func validateMonotonicTransition(
        currentHead: SecretTransitionCommit?,
        candidate: SecretTransitionCommit,
        knownCompetingChildDigests: [SecretRecordDigest]
    ) throws {
        if let currentHead {
            guard candidate.scopeID == currentHead.scopeID else {
                throw SecretPolicyValidationError.scopeMismatch
            }
            if candidate.policyEpoch < currentHead.policyEpoch {
                throw SecretPolicyValidationError.lowerEpoch
            }
            if candidate.policyEpoch == currentHead.policyEpoch {
                if candidate.recordDigest == currentHead.recordDigest {
                    throw SecretPolicyValidationError.replayedHead
                }
                throw SecretPolicyValidationError.sameEpochFork
            }
            guard candidate.predecessorCommitDigest == currentHead.recordDigest else {
                throw SecretPolicyValidationError.wrongPredecessor
            }
            guard candidate.generationID != currentHead.generationID else {
                throw SecretPolicyValidationError.generationNotRotated
            }
        }

        if knownCompetingChildDigests.contains(where: {
            $0 != candidate.recordDigest
        }) {
            throw SecretPolicyValidationError
                .samePredecessorForkDecisionRequired
        }
    }

    public static func validateBootstrapFreshness(
        localCommit: SecretTransitionCommit,
        against external: SecretBootstrapFreshnessCommitment
    ) throws {
        guard localCommit.scopeID == external.scopeID else {
            throw SecretPolicyValidationError.scopeMismatch
        }
        guard localCommit.policyEpoch == external.latestPolicyEpoch else {
            throw SecretPolicyValidationError.staleExternalFreshness
        }
        guard localCommit.headIdentityMatches(external.headCommitDigest) else {
            throw SecretPolicyValidationError.externalFreshnessFork
        }
        guard localCommit.policyDigest == external.policyDigest else {
            throw SecretPolicyValidationError.policyMismatch
        }
    }

    /// Rejects rollback, equivocation, and re-trust of a revoked credential
    /// across two already-authenticated trust-record snapshots.
    public static func validateTrustRecordTransition(
        current: [DeviceTrustRecord],
        candidate: [DeviceTrustRecord]
    ) throws {
        func indexed(
            _ records: [DeviceTrustRecord]
        ) throws -> [DeviceCredentialID: DeviceTrustRecord] {
            var result: [DeviceCredentialID: DeviceTrustRecord] = [:]
            for record in records {
                guard result[record.credentialID] == nil else {
                    throw SecretPolicyValidationError.duplicateTrustRecord
                }
                result[record.credentialID] = record
            }
            return result
        }
        try validateTrustMonotonicity(
            current: indexed(current),
            candidate: indexed(candidate)
        )
    }

    public static func validateTransition(
        currentSnapshot: SecretControlSnapshot?,
        stagedRecords: SecretControlRecords,
        commit: SecretTransitionCommit,
        trustedCredentials: [TrustedDeviceCredential],
        trustedDeviceRecords: [DeviceTrustRecord],
        knownCompetingChildDigests: [SecretRecordDigest],
        externalFreshness: SecretBootstrapFreshnessCommitment,
        digester: any SecretSyncDigesting,
        signatureVerifier: any SecretSignatureVerifying
    ) throws -> SecretControlSnapshot {
        guard
            stagedRecords.recoveryAuthorization == nil,
            commit.recoveryAuthorizationDigest == nil
        else {
            throw SecretPolicyValidationError.recoveryAuthorizationUnexpected
        }
        try validateMonotonicTransition(
            currentHead: currentSnapshot?.commit,
            candidate: commit,
            knownCompetingChildDigests: knownCompetingChildDigests
        )
        try validateBootstrapFreshness(
            localCommit: commit,
            against: externalFreshness
        )
        guard stagedRecords.state == .staged else {
            throw SecretPolicyValidationError.stagedStateRequired
        }

        var credentialsByID: [
            DeviceCredentialID: TrustedDeviceCredential
        ] = [:]
        for credential in trustedCredentials {
            guard credentialsByID[credential.credentialID] == nil else {
                throw SecretPolicyValidationError.duplicateTrustedCredential
            }
            credentialsByID[credential.credentialID] = credential
        }
        try validateContentAddresses(
            records: stagedRecords,
            commit: commit,
            digester: digester
        )
        let trustRecordsByID = try validateTrustBindings(
            trustedDeviceRecords,
            expectedDigests: stagedRecords.signedPolicy.policy
                .trustedDeviceRecordDigests,
            at: commit.policyEpoch,
            credentialsByID: credentialsByID,
            digester: digester
        )
        let authorityTrustRecordsByID: [
            DeviceCredentialID: DeviceTrustRecord
        ]
        if let currentSnapshot {
            authorityTrustRecordsByID = try validateTrustBindings(
                currentSnapshot.trustedDeviceRecords,
                expectedDigests: currentSnapshot.records.signedPolicy.policy
                    .trustedDeviceRecordDigests,
                at: currentSnapshot.commit.policyEpoch,
                credentialsByID: credentialsByID,
                digester: digester
            )
            try validateTrustMonotonicity(
                current: authorityTrustRecordsByID,
                candidate: trustRecordsByID
            )
        } else {
            authorityTrustRecordsByID = trustRecordsByID
        }
        try validateSignatures(
            records: stagedRecords,
            commit: commit,
            credentialsByID: credentialsByID,
            authorityTrustRecordsByID: authorityTrustRecordsByID,
            signatureVerifier: signatureVerifier
        )
        try validateReferences(
            records: stagedRecords,
            commit: commit,
            currentSnapshot: currentSnapshot,
            credentialsByID: credentialsByID,
            trustRecordsByID: trustRecordsByID
        )

        return try SecretControlSnapshot(
            commit: commit,
            records: stagedRecords.committedCopy(),
            trustedDeviceRecords: trustedDeviceRecords
        )
    }

    /// Admits one break-glass transition only when the current recovery
    /// authority, both fresh replacement keys, the exact candidate graph, and
    /// every old-device revocation agree on one atomic transcript.
    public static func validateFullLossRecoveryTransition(
        currentSnapshot: SecretControlSnapshot,
        preparedTransition: RecoveryPreparedTransition,
        knownCompetingChildDigests: [SecretRecordDigest],
        externalFreshness: SecretBootstrapFreshnessCommitment,
        appNamespace: String,
        estateID: UUID,
        nowMilliseconds: UInt64,
        digester: any SecretSyncDigesting,
        signatureVerifier: any SecretSignatureVerifying,
        recoveryVerifier: any FullLossRecoveryProofVerifying
    ) throws -> SecretControlSnapshot {
        let entry = preparedTransition.entry
        let records = entry.records
        let commit = entry.commit
        guard let authorization = records.recoveryAuthorization,
              let currentRecovery = currentSnapshot.records.signedPolicy.policy
                .recoveryRecipient else {
            throw SecretPolicyValidationError
                .fullLossRecoveryCurrentAuthorityMissing
        }
        let intent = authorization.intent

        try validateMonotonicTransition(
            currentHead: currentSnapshot.commit,
            candidate: commit,
            knownCompetingChildDigests: knownCompetingChildDigests
        )
        // Full-loss recovery proves the independently observed current head;
        // the candidate does not become fresh until its CAS succeeds.
        try validateBootstrapFreshness(
            localCommit: currentSnapshot.commit,
            against: externalFreshness
        )
        guard intent.challenge.isValid(atMilliseconds: nowMilliseconds) else {
            throw SecretPolicyValidationError.fullLossRecoveryChallengeExpired
        }
        guard
            intent.appNamespace == appNamespace,
            intent.estateID == estateID,
            intent.scopeID == currentSnapshot.commit.scopeID,
            intent.currentCommitDigest == currentSnapshot.commit.recordDigest,
            intent.currentPolicyDigest == currentSnapshot.commit.policyDigest,
            intent.currentPolicyEpoch == currentSnapshot.commit.policyEpoch,
            intent.currentGenerationID == currentSnapshot.commit.generationID,
            intent.currentRecoveryRecipient == currentRecovery,
            intent.candidatePolicyEpoch == commit.policyEpoch,
            intent.candidateGenerationID == commit.generationID,
            intent.candidateSignedPolicyDigest == commit.policyDigest,
            intent.recoveryEnvelopeDigest == commit.recoveryEnvelopeDigest,
            commit.recoveryAuthorizationDigest == authorization.recordDigest
        else {
            throw SecretPolicyValidationError.fullLossRecoveryCandidateMismatch
        }

        try validateContentAddresses(
            records: records,
            commit: commit,
            digester: digester
        )
        guard try recoveryVerifier.verifyRecoveryAuthorization(
            signature: authorization.signature,
            canonicalBytes: authorization.signingBytes(),
            signingPublicKey: currentRecovery.authorizationSigningPublicKey
        ) else {
            throw SecretPolicyValidationError.fullLossRecoveryProofRejected
        }
        guard try recoveryVerifier.verifyReplacementSigningPossession(
            proof: intent.signingPossessionProof,
            canonicalBytes: intent.signingPossessionChallengeBytes(),
            signingPublicKey: intent.replacementSigningPublicKey
        ) else {
            throw SecretPolicyValidationError.fullLossRecoveryProofRejected
        }
        guard try recoveryVerifier.verifyReplacementAgreementPossession(
            proof: intent.agreementPossessionProof,
            canonicalBytes: intent.agreementPossessionChallengeBytes(),
            agreementPublicKey: intent.replacementAgreementPublicKey
        ) else {
            throw SecretPolicyValidationError.fullLossRecoveryProofRejected
        }

        var credentialsByID: [
            DeviceCredentialID: TrustedDeviceCredential
        ] = [:]
        for credential in entry.credentials {
            guard credentialsByID.updateValue(
                credential,
                forKey: credential.credentialID
            ) == nil else {
                throw SecretPolicyValidationError.duplicateTrustedCredential
            }
        }
        let currentTrust = try validateTrustBindings(
            currentSnapshot.trustedDeviceRecords,
            expectedDigests: currentSnapshot.records.signedPolicy.policy
                .trustedDeviceRecordDigests,
            at: currentSnapshot.commit.policyEpoch,
            credentialsByID: credentialsByID,
            digester: digester
        )
        let candidateTrust = try validateTrustBindings(
            entry.trustRecords,
            expectedDigests: records.signedPolicy.policy
                .trustedDeviceRecordDigests,
            at: commit.policyEpoch,
            credentialsByID: credentialsByID,
            digester: digester
        )
        try validateTrustMonotonicity(
            current: currentTrust,
            candidate: candidateTrust
        )
        try validateFullLossRecoveryTrust(
            intent: intent,
            currentTrust: currentTrust,
            candidateTrust: candidateTrust,
            credentialsByID: credentialsByID,
            commit: commit
        )
        try validateFullLossRecoveryReferences(
            currentSnapshot: currentSnapshot,
            records: records,
            commit: commit,
            intent: intent
        )

        guard let replacement = credentialsByID[
            intent.replacementCredentialID
        ] else {
            throw SecretPolicyValidationError.fullLossRecoveryTrustMismatch
        }
        guard try signatureVerifier.verify(
            signature: records.signedPolicy.signature,
            canonicalBytes: records.signedPolicy.policy.canonicalBytes(),
            signingPublicKey: replacement.signingPublicKey
        ), try signatureVerifier.verify(
            signature: commit.signature,
            canonicalBytes: commit.signingBytes(),
            signingPublicKey: replacement.signingPublicKey
        ) else {
            throw SecretPolicyValidationError.signatureRejected
        }

        return try SecretControlSnapshot(
            commit: commit,
            records: records.committedCopy(),
            trustedDeviceRecords: entry.trustRecords
        )
    }

    private static func validateFullLossRecoveryTrust(
        intent: GlobalRecoveryTransitionIntent,
        currentTrust: [DeviceCredentialID: DeviceTrustRecord],
        candidateTrust: [DeviceCredentialID: DeviceTrustRecord],
        credentialsByID: [DeviceCredentialID: TrustedDeviceCredential],
        commit: SecretTransitionCommit
    ) throws {
        let replacementID = intent.replacementCredentialID
        let newIDs = Set(candidateTrust.keys).subtracting(currentTrust.keys)
        guard
            newIDs == Set([replacementID]),
            Set(credentialsByID.keys) == Set(candidateTrust.keys),
            let replacement = credentialsByID[replacementID],
            replacement.status == .active,
            replacement.deviceID == intent.replacementDeviceID,
            replacement.signingPublicKey == intent.replacementSigningPublicKey,
            replacement.keyAgreementPublicKey
                == intent.replacementAgreementPublicKey,
            replacement.enrollmentProof.challengeID
                == intent.challenge.challengeID,
            replacement.enrollmentProof.signingProofBytes
                == intent.signingPossessionProof,
            replacement.enrollmentProof.keyAgreementProofBytes
                == intent.agreementPossessionProof,
            replacement.enrollmentProof.globalRecoveryAuthority
                == GlobalRecoveryEnrollmentAuthority(
                    requestID: intent.challenge.requestID,
                    recoveryRecipientID: intent.currentRecoveryRecipient
                        .recoveryRecipientID
                ),
            let replacementTrust = candidateTrust[replacementID],
            replacementTrust.trustState == .trusted,
            replacementTrust.effectivePolicyEpoch == commit.policyEpoch,
            currentTrust.keys.allSatisfy({
                candidateTrust[$0]?.trustState == .revoked
            }),
            candidateTrust.values.filter({ $0.trustState == .trusted }).count
                == 1
        else {
            throw SecretPolicyValidationError.fullLossRecoveryTrustMismatch
        }
    }

    private static func validateFullLossRecoveryReferences(
        currentSnapshot: SecretControlSnapshot,
        records: SecretControlRecords,
        commit: SecretTransitionCommit,
        intent: GlobalRecoveryTransitionIntent
    ) throws {
        let policy = records.signedPolicy.policy
        guard
            records.state == .staged,
            policy.epoch == commit.policyEpoch,
            policy.predecessorPolicyDigest
                == currentSnapshot.commit.policyDigest,
            policy.scopeSnapshot.scopeID == commit.scopeID,
            policy.scopeSnapshot.snapshotDigest == commit.scopeSnapshotDigest,
            policy.generationID == commit.generationID,
            policy.signerCredentialID == intent.replacementCredentialID,
            commit.signerCredentialID == intent.replacementCredentialID,
            policy.authorizedRecipientCredentialIDs
                == [intent.replacementCredentialID],
            policy.recoveryRecipient == intent.replacementRecoveryRecipient,
            intent.replacementRecoveryRecipient != intent.currentRecoveryRecipient,
            records.recipientEnvelopes.count == 1,
            records.recipientEnvelopes.first?.recipientCredentialID
                == intent.replacementCredentialID,
            records.recipientEnvelopes.map(\.recordDigest)
                == commit.recipientEnvelopeDigests,
            let recoveryEnvelope = records.recoveryEnvelope,
            recoveryEnvelope.recordDigest == commit.recoveryEnvelopeDigest,
            recoveryEnvelope.recoveryRecipientID
                == intent.replacementRecoveryRecipient.recoveryRecipientID,
            recoveryEnvelope.scopeID == commit.scopeID,
            recoveryEnvelope.scopeSnapshotDigest == commit.scopeSnapshotDigest,
            recoveryEnvelope.policyEpoch == commit.policyEpoch,
            recoveryEnvelope.policyDigest == commit.policyDigest,
            recoveryEnvelope.generationID == commit.generationID,
            records.sealedPayload.recordDigest == commit.sealedPayloadDigest,
            records.sealedPayload.scopeID == commit.scopeID,
            records.sealedPayload.scopeSnapshotDigest
                == commit.scopeSnapshotDigest,
            records.sealedPayload.policyEpoch == commit.policyEpoch,
            records.sealedPayload.policyDigest == commit.policyDigest,
            records.sealedPayload.generationID == commit.generationID
        else {
            throw SecretPolicyValidationError.fullLossRecoveryCandidateMismatch
        }

        let oldRecipients = Set(
            currentSnapshot.records.signedPolicy.policy
                .authorizedRecipientCredentialIDs
        )
        let targets = Set(records.purgeRequirements.map(\.targetCredentialID))
        guard
            records.purgeReceipts.isEmpty,
            commit.purgeReceiptDigests.isEmpty,
            targets == oldRecipients,
            records.purgeRequirements.count == oldRecipients.count,
            records.purgeRequirements.map(\.recordDigest)
                == commit.purgeRequirementDigests,
            records.purgeRequirements.allSatisfy({ requirement in
                requirement.scopeID == commit.scopeID
                    && requirement.policyEpoch == commit.policyEpoch
                    && requirement.policyDigest == commit.policyDigest
                    && requirement.supersededGenerationID
                        == currentSnapshot.commit.generationID
                    && requirement.replacementGenerationID
                        == commit.generationID
            })
        else {
            throw SecretPolicyValidationError.fullLossRecoveryPurgeMismatch
        }
    }

    private static func validateContentAddresses(
        records: SecretControlRecords,
        commit: SecretTransitionCommit,
        digester: any SecretSyncDigesting
    ) throws {
        try requireDigest(
            records.signedPolicy.policy.scopeSnapshot,
            expected: records.signedPolicy.policy.scopeSnapshot.snapshotDigest,
            domain: .secretScopeSnapshot,
            digester: digester
        )
        try requireDigest(
            records.signedPolicy,
            expected: records.signedPolicy.recordDigest,
            domain: .signedSecretPolicyEpoch,
            digester: digester
        )
        try requireDigest(
            records.sealedPayload,
            expected: records.sealedPayload.recordDigest,
            domain: .sealedPayload,
            digester: digester
        )
        for envelope in records.recipientEnvelopes {
            try requireDigest(
                envelope,
                expected: envelope.recordDigest,
                domain: .recipientKeyEnvelope,
                digester: digester
            )
        }
        if let recoveryEnvelope = records.recoveryEnvelope {
            try requireDigest(
                recoveryEnvelope,
                expected: recoveryEnvelope.recordDigest,
                domain: .recoveryEnvelope,
                digester: digester
            )
        }
        for requirement in records.purgeRequirements {
            try requireDigest(
                requirement,
                expected: requirement.recordDigest,
                domain: .purgeRequirement,
                digester: digester
            )
        }
        for receipt in records.purgeReceipts {
            try requireDigest(
                receipt,
                expected: receipt.recordDigest,
                domain: .purgeReceipt,
                digester: digester
            )
        }
        if let authorization = records.recoveryAuthorization {
            try requireDigest(
                authorization,
                expected: authorization.recordDigest,
                domain: .fullLossRecoveryAuthorization,
                digester: digester
            )
        }
        try requireDigest(
            commit,
            expected: commit.recordDigest,
            domain: .secretTransitionCommit,
            digester: digester
        )
    }

    private static func requireDigest<T: SecretSyncCanonicalEncodable>(
        _ value: T,
        expected: SecretRecordDigest,
        domain: SecretSyncCanonicalDomain,
        digester: any SecretSyncDigesting
    ) throws {
        guard try digester.digest(canonicalBytes: value.canonicalBytes()) == expected else {
            throw SecretPolicyValidationError.digestMismatch(domain: domain)
        }
    }

    private static func validateTrustBindings(
        _ records: [DeviceTrustRecord],
        expectedDigests: [SecretRecordDigest],
        at policyEpoch: UInt64,
        credentialsByID: [DeviceCredentialID: TrustedDeviceCredential],
        digester: any SecretSyncDigesting
    ) throws -> [DeviceCredentialID: DeviceTrustRecord] {
        let suppliedDigests = records.map(\.recordDigest).sorted {
            $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
        guard suppliedDigests == expectedDigests else {
            throw SecretPolicyValidationError.trustRecordSetMismatch
        }

        var recordsByID: [DeviceCredentialID: DeviceTrustRecord] = [:]
        for record in records {
            guard record.effectivePolicyEpoch <= policyEpoch else {
                throw SecretPolicyValidationError.trustRecordNotEffective
            }
            guard recordsByID[record.credentialID] == nil else {
                throw SecretPolicyValidationError.duplicateTrustRecord
            }
            try requireDigest(
                record,
                expected: record.recordDigest,
                domain: .deviceTrustRecord,
                digester: digester
            )
            if let credential = credentialsByID[record.credentialID] {
                guard credential.deviceID == record.deviceID else {
                    throw SecretPolicyValidationError.trustedDeviceMismatch
                }
                if credential.status == .active {
                    guard
                        try digester.digest(
                            canonicalBytes: credential.canonicalBytes()
                        ) == record.credentialDigest
                    else {
                        throw SecretPolicyValidationError.trustedDeviceMismatch
                    }
                }
            }
            recordsByID[record.credentialID] = record
        }
        return recordsByID
    }

    private static func validateTrustMonotonicity(
        current: [DeviceCredentialID: DeviceTrustRecord],
        candidate: [DeviceCredentialID: DeviceTrustRecord]
    ) throws {
        guard Set(current.keys).isSubset(of: Set(candidate.keys)) else {
            throw SecretPolicyValidationError.staleTrustRecord
        }
        for (credentialID, candidateRecord) in candidate {
            guard let currentRecord = current[credentialID] else {
                continue
            }
            guard
                candidateRecord.deviceID == currentRecord.deviceID,
                candidateRecord.credentialDigest == currentRecord.credentialDigest
            else {
                throw SecretPolicyValidationError.trustedDeviceMismatch
            }
            guard
                candidateRecord.effectivePolicyEpoch
                    >= currentRecord.effectivePolicyEpoch
            else {
                throw SecretPolicyValidationError.staleTrustRecord
            }
            if candidateRecord.effectivePolicyEpoch
                == currentRecord.effectivePolicyEpoch
            {
                guard candidateRecord.recordDigest == currentRecord.recordDigest else {
                    throw SecretPolicyValidationError.staleTrustRecord
                }
            }
            if currentRecord.trustState == .revoked,
               candidateRecord.trustState != .revoked {
                throw SecretPolicyValidationError.revokedCredentialReplay
            }
        }
    }

    private static func validateSignatures(
        records: SecretControlRecords,
        commit: SecretTransitionCommit,
        credentialsByID: [DeviceCredentialID: TrustedDeviceCredential],
        authorityTrustRecordsByID: [DeviceCredentialID: DeviceTrustRecord],
        signatureVerifier: any SecretSignatureVerifying
    ) throws {
        let policy = records.signedPolicy
        let policySigner = try activeCredential(
            policy.policy.signerCredentialID,
            at: commit.policyEpoch,
            credentialsByID: credentialsByID,
            trustRecordsByID: authorityTrustRecordsByID
        )
        guard try signatureVerifier.verify(
            signature: policy.signature,
            canonicalBytes: policy.policy.canonicalBytes(),
            signingPublicKey: policySigner.signingPublicKey
        ) else {
            throw SecretPolicyValidationError.signatureRejected
        }

        for receipt in records.purgeReceipts {
            let receiptSigner = try activeCredential(
                receipt.signerCredentialID,
                at: commit.policyEpoch,
                credentialsByID: credentialsByID,
                trustRecordsByID: authorityTrustRecordsByID
            )
            guard try signatureVerifier.verify(
                signature: receipt.signature,
                canonicalBytes: receipt.signingBytes(),
                signingPublicKey: receiptSigner.signingPublicKey
            ) else {
                throw SecretPolicyValidationError.signatureRejected
            }
        }

        let commitSigner = try activeCredential(
            commit.signerCredentialID,
            at: commit.policyEpoch,
            credentialsByID: credentialsByID,
            trustRecordsByID: authorityTrustRecordsByID
        )
        guard try signatureVerifier.verify(
            signature: commit.signature,
            canonicalBytes: commit.signingBytes(),
            signingPublicKey: commitSigner.signingPublicKey
        ) else {
            throw SecretPolicyValidationError.signatureRejected
        }
    }

    private static func activeCredential(
        _ id: DeviceCredentialID,
        at policyEpoch: UInt64,
        credentialsByID: [DeviceCredentialID: TrustedDeviceCredential],
        trustRecordsByID: [DeviceCredentialID: DeviceTrustRecord]
    ) throws -> TrustedDeviceCredential {
        guard
            let credential = credentialsByID[id],
            credential.status == .active
        else {
            throw SecretPolicyValidationError.signerNotTrusted
        }
        guard let trustRecord = trustRecordsByID[id] else {
            throw SecretPolicyValidationError.signerNotTrusted
        }
        guard trustRecord.deviceID == credential.deviceID else {
            throw SecretPolicyValidationError.trustedDeviceMismatch
        }
        guard trustRecord.trustState == .trusted else {
            throw SecretPolicyValidationError.signerNotTrusted
        }
        guard trustRecord.effectivePolicyEpoch <= policyEpoch else {
            throw SecretPolicyValidationError.trustRecordNotEffective
        }
        return credential
    }

    private static func validateReferences(
        records: SecretControlRecords,
        commit: SecretTransitionCommit,
        currentSnapshot: SecretControlSnapshot?,
        credentialsByID: [DeviceCredentialID: TrustedDeviceCredential],
        trustRecordsByID: [DeviceCredentialID: DeviceTrustRecord]
    ) throws {
        let policy = records.signedPolicy.policy
        guard
            policy.epoch == commit.policyEpoch,
            records.signedPolicy.recordDigest == commit.policyDigest
        else {
            throw SecretPolicyValidationError.policyMismatch
        }
        guard
            policy.scopeSnapshot.scopeID == commit.scopeID,
            policy.scopeSnapshot.snapshotDigest == commit.scopeSnapshotDigest
        else {
            throw SecretPolicyValidationError.scopeMismatch
        }
        guard policy.generationID == commit.generationID else {
            throw SecretPolicyValidationError.generationMismatch
        }
        if let currentSnapshot {
            guard
                policy.predecessorPolicyDigest
                    == currentSnapshot.commit.policyDigest
            else {
                throw SecretPolicyValidationError.wrongPredecessor
            }
        }

        let payload = records.sealedPayload
        guard
            payload.recordDigest == commit.sealedPayloadDigest,
            payload.scopeID == commit.scopeID,
            payload.scopeSnapshotDigest == commit.scopeSnapshotDigest,
            payload.policyEpoch == commit.policyEpoch,
            payload.policyDigest == commit.policyDigest,
            payload.generationID == commit.generationID
        else {
            throw SecretPolicyValidationError.referenceMismatch(
                field: "sealedPayload"
            )
        }

        let recipientIDs = records.recipientEnvelopes
            .map(\.recipientCredentialID)
            .sorted {
                $0.rawValue.uuidString.lowercased()
                    < $1.rawValue.uuidString.lowercased()
            }
        guard recipientIDs == policy.authorizedRecipientCredentialIDs else {
            throw SecretPolicyValidationError.recipientSetMismatch
        }
        guard
            records.recipientEnvelopes.map(\.recordDigest)
                == commit.recipientEnvelopeDigests
        else {
            throw SecretPolicyValidationError.referenceMismatch(
                field: "recipientEnvelopeDigests"
            )
        }
        guard records.recoveryAuthorization?.recordDigest
                == commit.recoveryAuthorizationDigest
        else {
            throw SecretPolicyValidationError.recoveryAuthorizationMismatch
        }
        for envelope in records.recipientEnvelopes {
            try validateRecipientTrust(
                envelope.recipientCredentialID,
                at: commit.policyEpoch,
                credentialsByID: credentialsByID,
                trustRecordsByID: trustRecordsByID
            )
            guard
                envelope.scopeID == commit.scopeID,
                envelope.scopeSnapshotDigest == commit.scopeSnapshotDigest,
                envelope.policyEpoch == commit.policyEpoch,
                envelope.policyDigest == commit.policyDigest,
                envelope.generationID == commit.generationID
            else {
                throw SecretPolicyValidationError.referenceMismatch(
                    field: "recipientEnvelope"
                )
            }
        }

        try validateRecovery(records: records, commit: commit)
        try validatePurge(
            records: records,
            commit: commit,
            currentSnapshot: currentSnapshot
        )
    }

    private static func validateRecipientTrust(
        _ id: DeviceCredentialID,
        at policyEpoch: UInt64,
        credentialsByID: [DeviceCredentialID: TrustedDeviceCredential],
        trustRecordsByID: [DeviceCredentialID: DeviceTrustRecord]
    ) throws {
        guard
            let credential = credentialsByID[id],
            credential.status == .active,
            let trustRecord = trustRecordsByID[id],
            trustRecord.trustState == .trusted
        else {
            throw SecretPolicyValidationError.recipientNotTrusted
        }
        guard trustRecord.deviceID == credential.deviceID else {
            throw SecretPolicyValidationError.trustedDeviceMismatch
        }
        guard trustRecord.effectivePolicyEpoch <= policyEpoch else {
            throw SecretPolicyValidationError.trustRecordNotEffective
        }
    }

    private static func validateRecovery(
        records: SecretControlRecords,
        commit: SecretTransitionCommit
    ) throws {
        switch (
            records.signedPolicy.policy.recoveryRecipient,
            records.recoveryEnvelope,
            commit.recoveryEnvelopeDigest
        ) {
        case (nil, nil, nil):
            return
        case let (.some(descriptor), .some(envelope), .some(digest)):
            guard
                descriptor.recoveryRecipientID == envelope.recoveryRecipientID,
                envelope.recordDigest == digest,
                envelope.scopeID == commit.scopeID,
                envelope.scopeSnapshotDigest == commit.scopeSnapshotDigest,
                envelope.policyEpoch == commit.policyEpoch,
                envelope.policyDigest == commit.policyDigest,
                envelope.generationID == commit.generationID,
                envelope.usage == .breakGlassRecoveryOnly
            else {
                throw SecretPolicyValidationError.recoveryMismatch
            }
        default:
            throw SecretPolicyValidationError.recoveryMismatch
        }
    }

    private static func validatePurge(
        records: SecretControlRecords,
        commit: SecretTransitionCommit,
        currentSnapshot: SecretControlSnapshot?
    ) throws {
        let requirementDigests = records.purgeRequirements.map(\.recordDigest)
        guard requirementDigests == commit.purgeRequirementDigests else {
            throw SecretPolicyValidationError.referenceMismatch(
                field: "purgeRequirementDigests"
            )
        }
        guard records.purgeRequirements.count == records.purgeReceipts.count else {
            throw SecretPolicyValidationError.incompletePurgeReceipts
        }
        let receiptDigests = records.purgeReceipts.map(\.recordDigest)
        guard receiptDigests == commit.purgeReceiptDigests else {
            throw SecretPolicyValidationError.referenceMismatch(
                field: "purgeReceiptDigests"
            )
        }

        var receiptsByRequirement: [
            SecretRecordDigest: SignedPurgeReceipt
        ] = [:]
        if let currentSnapshot {
            let priorRecipients = Set(
                currentSnapshot.records.signedPolicy.policy
                    .authorizedRecipientCredentialIDs
            )
            let candidateRecipients = Set(
                records.signedPolicy.policy.authorizedRecipientCredentialIDs
            )
            let removedRecipients = priorRecipients.subtracting(candidateRecipients)
            let requiredTargets = Set(
                records.purgeRequirements.map(\.targetCredentialID)
            )
            guard
                requiredTargets == removedRecipients,
                records.purgeRequirements.count == removedRecipients.count
            else {
                throw SecretPolicyValidationError.purgeCoverageMismatch
            }
        }
        for receipt in records.purgeReceipts {
            guard receiptsByRequirement[receipt.requirementDigest] == nil else {
                throw SecretPolicyValidationError.purgeCoverageMismatch
            }
            receiptsByRequirement[receipt.requirementDigest] = receipt
        }
        for requirement in records.purgeRequirements {
            guard
                requirement.scopeID == commit.scopeID,
                requirement.policyEpoch == commit.policyEpoch,
                requirement.policyDigest == commit.policyDigest,
                requirement.replacementGenerationID == commit.generationID,
                requirement.supersededGenerationID
                    == currentSnapshot?.commit.generationID
            else {
                throw SecretPolicyValidationError.purgeCoverageMismatch
            }
            guard let receipt = receiptsByRequirement[requirement.recordDigest] else {
                throw SecretPolicyValidationError.incompletePurgeReceipts
            }
            guard
                receipt.status == .completed,
                receipt.coveredCategories == requirement.requiredCategories,
                receipt.scopeID == requirement.scopeID,
                receipt.policyEpoch == requirement.policyEpoch,
                receipt.policyDigest == requirement.policyDigest,
                receipt.supersededGenerationID
                    == requirement.supersededGenerationID,
                receipt.replacementGenerationID
                    == requirement.replacementGenerationID,
                receipt.respondingCredentialID == requirement.targetCredentialID,
                receipt.signerCredentialID == receipt.respondingCredentialID
            else {
                throw SecretPolicyValidationError.purgeCoverageMismatch
            }
        }
    }
}

private extension SecretTransitionCommit {
    func headIdentityMatches(_ digest: SecretRecordDigest) -> Bool {
        recordDigest == digest
    }
}

private func sortedUniqueCategories(
    _ values: [PurgeArtifactCategory],
    field: String
) throws -> [PurgeArtifactCategory] {
    guard !values.isEmpty else {
        throw SecretSyncContractError.emptySet(field: field)
    }
    let sorted = values.sorted { $0.rawValue < $1.rawValue }
    for index in sorted.indices.dropFirst() where sorted[index] == sorted[index - 1] {
        throw SecretSyncContractError.duplicateIdentifier(field: field)
    }
    return sorted
}

private func sortedUniqueDigests(
    _ values: [SecretRecordDigest],
    field: String,
    allowEmpty: Bool = false
) throws -> [SecretRecordDigest] {
    if !allowEmpty, values.isEmpty {
        throw SecretSyncContractError.emptySet(field: field)
    }
    let sorted = values.sorted {
        $0.bytes.lexicographicallyPrecedes($1.bytes)
    }
    for index in sorted.indices.dropFirst() where sorted[index] == sorted[index - 1] {
        throw SecretSyncContractError.duplicateIdentifier(field: field)
    }
    return sorted
}

private func sortedUniqueRecords<Record>(
    _ values: [Record],
    digest: KeyPath<Record, SecretRecordDigest>,
    field: String,
    allowEmpty: Bool = false
) throws -> [Record] {
    if !allowEmpty, values.isEmpty {
        throw SecretSyncContractError.emptySet(field: field)
    }
    let sorted = values.sorted {
        $0[keyPath: digest].bytes.lexicographicallyPrecedes(
            $1[keyPath: digest].bytes
        )
    }
    for index in sorted.indices.dropFirst()
    where sorted[index][keyPath: digest] == sorted[index - 1][keyPath: digest] {
        throw SecretSyncContractError.duplicateIdentifier(field: field)
    }
    return sorted
}
