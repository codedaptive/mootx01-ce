import Foundation

/// Fail-closed validation errors for SecretSync interface records.
public enum SecretSyncInterfaceError: Error, Sendable, Equatable {
    case invalidPolicyEpoch
    case duplicateCredentialID
    case unapprovedCredentialStatus
    case trustSnapshotEpochMismatch
    case trustedGroupContainsUnapprovedCredential
    case trustRecordMismatch
    case invalidPolicyAdvancePrecondition
    case invalidPolicyStoreEntry
    case invalidPurgeReceipt
    case admissionWouldBypassPendingPurge
    case generationReuse
    case recoveryRecipientMismatch
}

/// Opaque reference to signing-key material held by a future custody provider.
///
/// The identifier is only a provider-local lookup token. It cannot export or
/// reconstruct signing-key material.
public struct SigningPrivateKeyHandle:
    RawRepresentable,
    Sendable,
    Codable,
    Hashable
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Opaque reference to key-agreement material held by a future custody provider.
///
/// A distinct type prevents a signing handle from being passed to an agreement
/// operation even when a provider happens to use the same identifier format.
public struct KeyAgreementPrivateKeyHandle:
    RawRepresentable,
    Sendable,
    Codable,
    Hashable
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Opaque challenge input for proving possession of one signing credential.
public struct SigningProofOfPossessionRequest: Sendable, Hashable {
    public let credentialID: DeviceCredentialID
    public let privateKeyHandle: SigningPrivateKeyHandle
    public let challengeID: UUID
    public let challengeBytes: Data

    public init(
        credentialID: DeviceCredentialID,
        privateKeyHandle: SigningPrivateKeyHandle,
        challengeID: UUID,
        challengeBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            challengeBytes,
            field: "signingPossessionChallengeBytes"
        )
        self.credentialID = credentialID
        self.privateKeyHandle = privateKeyHandle
        self.challengeID = challengeID
        self.challengeBytes = challengeBytes
    }
}

/// Opaque challenge input for proving possession of one agreement credential.
public struct KeyAgreementProofOfPossessionRequest: Sendable, Hashable {
    public let credentialID: DeviceCredentialID
    public let privateKeyHandle: KeyAgreementPrivateKeyHandle
    public let challengeID: UUID
    public let challengeBytes: Data

    public init(
        credentialID: DeviceCredentialID,
        privateKeyHandle: KeyAgreementPrivateKeyHandle,
        challengeID: UUID,
        challengeBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            challengeBytes,
            field: "keyAgreementPossessionChallengeBytes"
        )
        self.credentialID = credentialID
        self.privateKeyHandle = privateKeyHandle
        self.challengeID = challengeID
        self.challengeBytes = challengeBytes
    }
}

/// Opaque output from a signing proof-of-possession operation.
///
/// This record is evidence for a later verifier; its presence does not claim
/// that verification or enrollment succeeded.
public struct SigningProofOfPossessionResult: Sendable, Hashable {
    public let credentialID: DeviceCredentialID
    public let challengeID: UUID
    public let proofBytes: Data

    public init(
        credentialID: DeviceCredentialID,
        challengeID: UUID,
        proofBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            proofBytes,
            field: "signingPossessionProofBytes"
        )
        self.credentialID = credentialID
        self.challengeID = challengeID
        self.proofBytes = proofBytes
    }
}

/// Opaque output from a key-agreement proof-of-possession operation.
///
/// This record is evidence for a later verifier; its presence does not claim
/// that verification or enrollment succeeded.
public struct KeyAgreementProofOfPossessionResult: Sendable, Hashable {
    public let credentialID: DeviceCredentialID
    public let challengeID: UUID
    public let proofBytes: Data

    public init(
        credentialID: DeviceCredentialID,
        challengeID: UUID,
        proofBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            proofBytes,
            field: "keyAgreementPossessionProofBytes"
        )
        self.credentialID = credentialID
        self.challengeID = challengeID
        self.proofBytes = proofBytes
    }
}

/// Retrieves only the public signing descriptor for a stable credential UUID.
public protocol SecretSyncSigningPublicCredentialRetrieving: Sendable {
    func signingPublicCredential(
        for credentialID: DeviceCredentialID
    ) async throws -> SigningPublicKeyDescriptor
}

/// Retrieves only the public agreement descriptor for a stable credential UUID.
public protocol SecretSyncKeyAgreementPublicCredentialRetrieving: Sendable {
    func keyAgreementPublicCredential(
        for credentialID: DeviceCredentialID
    ) async throws -> KeyAgreementPublicKeyDescriptor
}

/// Custody seam for opaque signing handles and possession evidence.
public protocol SecretSyncSigningKeyCustody: Sendable {
    func signingPrivateKeyHandle(
        for credentialID: DeviceCredentialID
    ) async throws -> SigningPrivateKeyHandle

    func proveSigningKeyPossession(
        _ request: SigningProofOfPossessionRequest
    ) async throws -> SigningProofOfPossessionResult
}

/// Custody seam for opaque agreement handles and possession evidence.
public protocol SecretSyncKeyAgreementKeyCustody: Sendable {
    func keyAgreementPrivateKeyHandle(
        for credentialID: DeviceCredentialID
    ) async throws -> KeyAgreementPrivateKeyHandle

    func proveKeyAgreementKeyPossession(
        _ request: KeyAgreementProofOfPossessionRequest
    ) async throws -> KeyAgreementProofOfPossessionResult
}
