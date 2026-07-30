import Foundation

/// Stable device identity used by the SecretSync trust plane.
///
/// This UUID is intentionally unrelated to ConvergenceKit's reusable HLC
/// `DeviceSlot`; an HLC slot is never an authorization identity.
public struct TrustedDeviceID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Stable identifier for one versioned device credential.
public struct DeviceCredentialID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Product-neutral identifier for one exact Secret scope.
public struct SecretScopeID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Identifier for a single immutable sealed generation.
public struct SecretGenerationID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Fixed-width opaque digest produced by an injected future implementation.
///
/// This type validates framing only. It performs no hashing.
public struct SecretRecordDigest: Sendable, Hashable {
    public static let byteCount = 32
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw SecretSyncContractError.invalidDigestLength(actual: bytes.count)
        }
        self.bytes = bytes
    }
}

extension SecretRecordDigest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(bytes: container.decode(Data.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

/// Compatibility vocabulary for the mission's general digest seam.
public typealias SecretSyncDigest = SecretRecordDigest

/// Public signing-key descriptor. The bytes are opaque to this contract layer.
public struct SigningPublicKeyDescriptor: Sendable, Codable, Hashable {
    public let algorithmIdentifier: String
    public let keyIdentifier: Data
    public let publicKeyBytes: Data

    public init(
        algorithmIdentifier: String,
        keyIdentifier: Data,
        publicKeyBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireAlgorithmIdentifier(algorithmIdentifier)
        try SecretSyncContractBounds.requireOpaqueBytes(
            keyIdentifier,
            field: "signingKeyIdentifier"
        )
        try SecretSyncContractBounds.requireOpaqueBytes(
            publicKeyBytes,
            field: "signingPublicKeyBytes"
        )
        self.algorithmIdentifier = algorithmIdentifier
        self.keyIdentifier = keyIdentifier
        self.publicKeyBytes = publicKeyBytes
    }

    private enum CodingKeys: String, CodingKey {
        case algorithmIdentifier
        case keyIdentifier
        case publicKeyBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            algorithmIdentifier: container.decode(
                String.self,
                forKey: .algorithmIdentifier
            ),
            keyIdentifier: container.decode(Data.self, forKey: .keyIdentifier),
            publicKeyBytes: container.decode(Data.self, forKey: .publicKeyBytes)
        )
    }
}

/// Public key-agreement descriptor, kept type-distinct from signing keys.
public struct KeyAgreementPublicKeyDescriptor: Sendable, Codable, Hashable {
    public let algorithmIdentifier: String
    public let keyIdentifier: Data
    public let publicKeyBytes: Data

    public init(
        algorithmIdentifier: String,
        keyIdentifier: Data,
        publicKeyBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireAlgorithmIdentifier(algorithmIdentifier)
        try SecretSyncContractBounds.requireOpaqueBytes(
            keyIdentifier,
            field: "keyAgreementKeyIdentifier"
        )
        try SecretSyncContractBounds.requireOpaqueBytes(
            publicKeyBytes,
            field: "keyAgreementPublicKeyBytes"
        )
        self.algorithmIdentifier = algorithmIdentifier
        self.keyIdentifier = keyIdentifier
        self.publicKeyBytes = publicKeyBytes
    }

    private enum CodingKeys: String, CodingKey {
        case algorithmIdentifier
        case keyIdentifier
        case publicKeyBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            algorithmIdentifier: container.decode(
                String.self,
                forKey: .algorithmIdentifier
            ),
            keyIdentifier: container.decode(Data.self, forKey: .keyIdentifier),
            publicKeyBytes: container.decode(Data.self, forKey: .publicKeyBytes)
        )
    }
}

/// Opaque proof-of-possession and policy-authority evidence for enrollment.
public struct DeviceCredentialEnrollmentProof:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let challengeID: UUID
    public let challengeBytes: Data
    public let signingProofBytes: Data
    public let keyAgreementProofBytes: Data
    public let authorityCredentialID: DeviceCredentialID
    public let authoritySignature: Data

    public init(
        challengeID: UUID,
        challengeBytes: Data,
        signingProofBytes: Data,
        keyAgreementProofBytes: Data,
        authorityCredentialID: DeviceCredentialID,
        authoritySignature: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            challengeBytes,
            field: "challengeBytes"
        )
        try SecretSyncContractBounds.requireOpaqueBytes(
            signingProofBytes,
            field: "signingProofBytes"
        )
        try SecretSyncContractBounds.requireOpaqueBytes(
            keyAgreementProofBytes,
            field: "keyAgreementProofBytes"
        )
        try SecretSyncContractBounds.requireOpaqueBytes(
            authoritySignature,
            field: "authoritySignature"
        )
        self.challengeID = challengeID
        self.challengeBytes = challengeBytes
        self.signingProofBytes = signingProofBytes
        self.keyAgreementProofBytes = keyAgreementProofBytes
        self.authorityCredentialID = authorityCredentialID
        self.authoritySignature = authoritySignature
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .deviceEnrollmentProof
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uuid(challengeID)
            ),
            SecretSyncCanonicalField(tag: 2, value: challengeBytes),
            SecretSyncCanonicalField(tag: 3, value: signingProofBytes),
            SecretSyncCanonicalField(tag: 4, value: keyAgreementProofBytes),
            SecretSyncCanonicalField(
                tag: 5,
                value: SecretSyncCanonicalValue.uuid(authorityCredentialID.rawValue)
            ),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case challengeID
        case challengeBytes
        case signingProofBytes
        case keyAgreementProofBytes
        case authorityCredentialID
        case authoritySignature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            challengeID: container.decode(UUID.self, forKey: .challengeID),
            challengeBytes: container.decode(Data.self, forKey: .challengeBytes),
            signingProofBytes: container.decode(Data.self, forKey: .signingProofBytes),
            keyAgreementProofBytes: container.decode(
                Data.self,
                forKey: .keyAgreementProofBytes
            ),
            authorityCredentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .authorityCredentialID
            ),
            authoritySignature: container.decode(
                Data.self,
                forKey: .authoritySignature
            )
        )
    }
}

/// Immutable lifecycle status for one credential record.
public enum TrustedDeviceCredentialStatus: String, Sendable, Codable, Hashable {
    case active
    case revoked
}

/// Immutable device credential with distinct signing and agreement roles.
public struct TrustedDeviceCredential:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let deviceID: TrustedDeviceID
    public let credentialID: DeviceCredentialID
    public let credentialVersion: UInt16
    public let status: TrustedDeviceCredentialStatus
    public let signingPublicKey: SigningPublicKeyDescriptor
    public let keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor
    public let enrollmentProof: DeviceCredentialEnrollmentProof

    public init(
        deviceID: TrustedDeviceID,
        credentialID: DeviceCredentialID,
        credentialVersion: UInt16,
        status: TrustedDeviceCredentialStatus,
        signingPublicKey: SigningPublicKeyDescriptor,
        keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor,
        enrollmentProof: DeviceCredentialEnrollmentProof
    ) throws {
        guard credentialVersion > 0 else {
            throw SecretSyncContractError.invalidCredentialVersion
        }
        guard
            signingPublicKey.keyIdentifier != keyAgreementPublicKey.keyIdentifier,
            signingPublicKey.publicKeyBytes != keyAgreementPublicKey.publicKeyBytes
        else {
            throw SecretSyncContractError.keyRoleReuse
        }
        guard enrollmentProof.authorityCredentialID != credentialID else {
            throw SecretSyncContractError.selfAuthorizedEnrollment
        }

        self.deviceID = deviceID
        self.credentialID = credentialID
        self.credentialVersion = credentialVersion
        self.status = status
        self.signingPublicKey = signingPublicKey
        self.keyAgreementPublicKey = keyAgreementPublicKey
        self.enrollmentProof = enrollmentProof
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .trustedDeviceCredential
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            SecretSyncCanonicalField(
                tag: 1,
                value: SecretSyncCanonicalValue.uuid(deviceID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 2,
                value: SecretSyncCanonicalValue.uuid(credentialID.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 3,
                value: SecretSyncCanonicalValue.uint16(credentialVersion)
            ),
            SecretSyncCanonicalField(
                tag: 4,
                value: SecretSyncCanonicalValue.string(status.rawValue)
            ),
            SecretSyncCanonicalField(
                tag: 5,
                value: SecretSyncCanonicalValue.string(
                    signingPublicKey.algorithmIdentifier
                )
            ),
            SecretSyncCanonicalField(tag: 6, value: signingPublicKey.keyIdentifier),
            SecretSyncCanonicalField(tag: 7, value: signingPublicKey.publicKeyBytes),
            SecretSyncCanonicalField(
                tag: 8,
                value: SecretSyncCanonicalValue.string(
                    keyAgreementPublicKey.algorithmIdentifier
                )
            ),
            SecretSyncCanonicalField(
                tag: 9,
                value: keyAgreementPublicKey.keyIdentifier
            ),
            SecretSyncCanonicalField(
                tag: 10,
                value: keyAgreementPublicKey.publicKeyBytes
            ),
            SecretSyncCanonicalField(
                tag: 11,
                value: try enrollmentProof.canonicalBytes()
            ),
            SecretSyncCanonicalField(
                tag: 12,
                value: enrollmentProof.authoritySignature
            ),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case credentialID
        case credentialVersion
        case status
        case signingPublicKey
        case keyAgreementPublicKey
        case enrollmentProof
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceID: container.decode(TrustedDeviceID.self, forKey: .deviceID),
            credentialID: container.decode(
                DeviceCredentialID.self,
                forKey: .credentialID
            ),
            credentialVersion: container.decode(
                UInt16.self,
                forKey: .credentialVersion
            ),
            status: container.decode(
                TrustedDeviceCredentialStatus.self,
                forKey: .status
            ),
            signingPublicKey: container.decode(
                SigningPublicKeyDescriptor.self,
                forKey: .signingPublicKey
            ),
            keyAgreementPublicKey: container.decode(
                KeyAgreementPublicKeyDescriptor.self,
                forKey: .keyAgreementPublicKey
            ),
            enrollmentProof: container.decode(
                DeviceCredentialEnrollmentProof.self,
                forKey: .enrollmentProof
            )
        )
    }
}
