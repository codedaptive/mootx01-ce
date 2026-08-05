import Foundation

/// Fixed, payload-free failures for full-loss recovery contracts.
public enum FullLossRecoveryContractError: Error, Sendable, Equatable {
    case invalidNonce
    case invalidTimeWindow
    case duplicateDigest
    case emptyDigestSet
    case invalidWarningAcknowledgement
    case invalidSuite
    case invalidNamespace
    case invalidEpoch
    case invalidPossessionTranscript
    case invalidAuthorization
    case invalidCanonicalShape
}

/// Frozen identifiers and bounds for the full-loss recovery proof suite.
public enum FullLossRecoveryContract {
    public static let suiteIdentifier =
        "mootx01.secret-recovery.full-loss-authorization.v1"
    public static let warningSemanticIdentifier =
        "mootx01.secret-recovery.full-loss-no-erasure-warning.v1"
    public static let warningVersion: UInt16 = 1
    public static let maximumTTLMilliseconds: UInt64 = 300_000
    public static let minimumNonceByteCount = 16
}

/// One short-lived, replay-bounded challenge for a full-loss operation.
public struct FullLossRecoveryChallenge: Sendable, Codable, Hashable {
    public let requestID: UUID
    public let challengeID: UUID
    public let sessionID: UUID
    public let nonce: Data
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64

    public init(
        requestID: UUID,
        challengeID: UUID,
        sessionID: UUID,
        nonce: Data,
        issuedAtMilliseconds: UInt64,
        expiresAtMilliseconds: UInt64
    ) throws {
        guard nonce.count >= FullLossRecoveryContract.minimumNonceByteCount else {
            throw FullLossRecoveryContractError.invalidNonce
        }
        guard
            expiresAtMilliseconds > issuedAtMilliseconds,
            expiresAtMilliseconds - issuedAtMilliseconds
                <= FullLossRecoveryContract.maximumTTLMilliseconds
        else {
            throw FullLossRecoveryContractError.invalidTimeWindow
        }
        self.requestID = requestID
        self.challengeID = challengeID
        self.sessionID = sessionID
        self.nonce = nonce
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    /// Applies the exact half-open law `issuedAt <= now < expiresAt`.
    public func isValid(atMilliseconds now: UInt64) -> Bool {
        issuedAtMilliseconds <= now && now < expiresAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, challengeID, sessionID, nonce
        case issuedAtMilliseconds, expiresAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: values.decode(UUID.self, forKey: .requestID),
            challengeID: values.decode(UUID.self, forKey: .challengeID),
            sessionID: values.decode(UUID.self, forKey: .sessionID),
            nonce: values.decode(Data.self, forKey: .nonce),
            issuedAtMilliseconds: values.decode(
                UInt64.self,
                forKey: .issuedAtMilliseconds
            ),
            expiresAtMilliseconds: values.decode(
                UInt64.self,
                forKey: .expiresAtMilliseconds
            )
        )
    }
}

/// Signed acknowledgement that full-loss recovery cannot prove old-device erasure.
public struct FullLossRecoveryWarningAcknowledgement:
    Sendable,
    Codable,
    Hashable
{
    public let semanticIdentifier: String
    public let version: UInt16
    public let acknowledgement: String

    public init(
        semanticIdentifier: String = FullLossRecoveryContract
            .warningSemanticIdentifier,
        version: UInt16 = FullLossRecoveryContract.warningVersion,
        acknowledgement: String
    ) throws {
        guard
            semanticIdentifier
                == FullLossRecoveryContract.warningSemanticIdentifier,
            version == FullLossRecoveryContract.warningVersion,
            acknowledgement == "acknowledged-no-erasure-and-rollback-risk"
        else {
            throw FullLossRecoveryContractError.invalidWarningAcknowledgement
        }
        self.semanticIdentifier = semanticIdentifier
        self.version = version
        self.acknowledgement = acknowledgement
    }

    func canonicalValue() throws -> Data {
        try SecretSyncCanonicalValue.sequence([
            SecretSyncCanonicalValue.string(semanticIdentifier),
            SecretSyncCanonicalValue.uint16(version),
            SecretSyncCanonicalValue.string(acknowledgement),
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case semanticIdentifier, version, acknowledgement
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            semanticIdentifier: values.decode(
                String.self,
                forKey: .semanticIdentifier
            ),
            version: values.decode(UInt16.self, forKey: .version),
            acknowledgement: values.decode(
                String.self,
                forKey: .acknowledgement
            )
        )
    }
}

/// Exact digest set authenticated by the recovery authorization proof.
///
/// The candidate commit is intentionally absent to prevent a proof/commit
/// digest cycle. The commit instead references the finished proof digest.
public struct FullLossRecoveryCandidateSemantics:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let scopeSnapshotDigest: SecretRecordDigest
    public let signedPolicyDigest: SecretRecordDigest
    public let sealedPayloadDigest: SecretRecordDigest
    public let recipientEnvelopeDigests: [SecretRecordDigest]
    public let recoveryEnvelopeDigest: SecretRecordDigest
    public let purgeRequirementDigests: [SecretRecordDigest]
    public let purgeReceiptDigests: [SecretRecordDigest]
    public let credentialDigests: [SecretRecordDigest]
    public let trustRecordDigests: [SecretRecordDigest]

    public init(
        scopeSnapshotDigest: SecretRecordDigest,
        signedPolicyDigest: SecretRecordDigest,
        sealedPayloadDigest: SecretRecordDigest,
        recipientEnvelopeDigests: [SecretRecordDigest],
        recoveryEnvelopeDigest: SecretRecordDigest,
        purgeRequirementDigests: [SecretRecordDigest],
        purgeReceiptDigests: [SecretRecordDigest],
        credentialDigests: [SecretRecordDigest],
        trustRecordDigests: [SecretRecordDigest]
    ) throws {
        self.scopeSnapshotDigest = scopeSnapshotDigest
        self.signedPolicyDigest = signedPolicyDigest
        self.sealedPayloadDigest = sealedPayloadDigest
        self.recipientEnvelopeDigests = try recoverySortedDigests(
            recipientEnvelopeDigests,
            allowEmpty: false
        )
        self.recoveryEnvelopeDigest = recoveryEnvelopeDigest
        self.purgeRequirementDigests = try recoverySortedDigests(
            purgeRequirementDigests,
            allowEmpty: true
        )
        self.purgeReceiptDigests = try recoverySortedDigests(
            purgeReceiptDigests,
            allowEmpty: true
        )
        self.credentialDigests = try recoverySortedDigests(
            credentialDigests,
            allowEmpty: false
        )
        self.trustRecordDigests = try recoverySortedDigests(
            trustRecordDigests,
            allowEmpty: false
        )
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .fullLossRecoveryCandidateSemantics
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            .init(tag: 1, value: scopeSnapshotDigest.bytes),
            .init(tag: 2, value: signedPolicyDigest.bytes),
            .init(tag: 3, value: sealedPayloadDigest.bytes),
            .init(
                tag: 4,
                value: try recoveryDigestSequence(recipientEnvelopeDigests)
            ),
            .init(tag: 5, value: recoveryEnvelopeDigest.bytes),
            .init(
                tag: 6,
                value: try recoveryDigestSequence(purgeRequirementDigests)
            ),
            .init(
                tag: 7,
                value: try recoveryDigestSequence(purgeReceiptDigests)
            ),
            .init(tag: 8, value: try recoveryDigestSequence(credentialDigests)),
            .init(tag: 9, value: try recoveryDigestSequence(trustRecordDigests)),
        ]
    }

    /// Strictly reconstructs the exact canonical candidate-semantics record.
    public init(canonicalBytes: Data) throws {
        let fields = try RecoveryCanonicalFields(
            canonicalBytes,
            domain: .fullLossRecoveryCandidateSemantics,
            required: Array(1...9).map(UInt16.init)
        )
        try self.init(
            scopeSnapshotDigest: fields.digest(1),
            signedPolicyDigest: fields.digest(2),
            sealedPayloadDigest: fields.digest(3),
            recipientEnvelopeDigests: fields.digestSequence(4),
            recoveryEnvelopeDigest: fields.digest(5),
            purgeRequirementDigests: fields.digestSequence(6),
            purgeReceiptDigests: fields.digestSequence(7),
            credentialDigests: fields.digestSequence(8),
            trustRecordDigests: fields.digestSequence(9)
        )
        guard try self.canonicalBytes() == canonicalBytes else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
    }

    private enum CodingKeys: String, CodingKey {
        case scopeSnapshotDigest, signedPolicyDigest, sealedPayloadDigest
        case recipientEnvelopeDigests, recoveryEnvelopeDigest
        case purgeRequirementDigests, purgeReceiptDigests
        case credentialDigests, trustRecordDigests
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scopeSnapshotDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .scopeSnapshotDigest
            ),
            signedPolicyDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .signedPolicyDigest
            ),
            sealedPayloadDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .sealedPayloadDigest
            ),
            recipientEnvelopeDigests: values.decode(
                [SecretRecordDigest].self,
                forKey: .recipientEnvelopeDigests
            ),
            recoveryEnvelopeDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .recoveryEnvelopeDigest
            ),
            purgeRequirementDigests: values.decode(
                [SecretRecordDigest].self,
                forKey: .purgeRequirementDigests
            ),
            purgeReceiptDigests: values.decode(
                [SecretRecordDigest].self,
                forKey: .purgeReceiptDigests
            ),
            credentialDigests: values.decode(
                [SecretRecordDigest].self,
                forKey: .credentialDigests
            ),
            trustRecordDigests: values.decode(
                [SecretRecordDigest].self,
                forKey: .trustRecordDigests
            )
        )
    }
}

/// Role label for independently verified fresh-device possession proofs.
public enum FullLossRecoveryPossessionRole: String, Sendable, Codable, Hashable {
    case signing
    case agreement
}

/// Role-separated transcript proved by the fresh replacement private keys.
public struct FullLossRecoveryPossessionChallenge:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let role: FullLossRecoveryPossessionRole
    public let challenge: FullLossRecoveryChallenge
    public let scopeID: SecretScopeID
    public let currentCommitDigest: SecretRecordDigest
    public let candidateEpoch: UInt64
    public let replacementDeviceID: TrustedDeviceID
    public let replacementCredentialID: DeviceCredentialID
    public let signingPublicKey: SigningPublicKeyDescriptor
    public let agreementPublicKey: KeyAgreementPublicKeyDescriptor

    public init(
        role: FullLossRecoveryPossessionRole,
        challenge: FullLossRecoveryChallenge,
        scopeID: SecretScopeID,
        currentCommitDigest: SecretRecordDigest,
        candidateEpoch: UInt64,
        replacementDeviceID: TrustedDeviceID,
        replacementCredentialID: DeviceCredentialID,
        signingPublicKey: SigningPublicKeyDescriptor,
        agreementPublicKey: KeyAgreementPublicKeyDescriptor
    ) throws {
        guard
            candidateEpoch > 0,
            signingPublicKey.keyIdentifier != agreementPublicKey.keyIdentifier,
            signingPublicKey.publicKeyBytes != agreementPublicKey.publicKeyBytes
        else {
            throw FullLossRecoveryContractError.invalidPossessionTranscript
        }
        self.role = role
        self.challenge = challenge
        self.scopeID = scopeID
        self.currentCommitDigest = currentCommitDigest
        self.candidateEpoch = candidateEpoch
        self.replacementDeviceID = replacementDeviceID
        self.replacementCredentialID = replacementCredentialID
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .fullLossRecoveryPossessionChallenge
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            .init(tag: 1, value: SecretSyncCanonicalValue.string(role.rawValue)),
            .init(tag: 2, value: SecretSyncCanonicalValue.uuid(challenge.requestID)),
            .init(tag: 3, value: SecretSyncCanonicalValue.uuid(challenge.challengeID)),
            .init(tag: 4, value: SecretSyncCanonicalValue.uuid(challenge.sessionID)),
            .init(tag: 5, value: challenge.nonce),
            .init(tag: 6, value: SecretSyncCanonicalValue.uint64(challenge.issuedAtMilliseconds)),
            .init(tag: 7, value: SecretSyncCanonicalValue.uint64(challenge.expiresAtMilliseconds)),
            .init(tag: 8, value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)),
            .init(tag: 9, value: currentCommitDigest.bytes),
            .init(tag: 10, value: SecretSyncCanonicalValue.uint64(candidateEpoch)),
            .init(tag: 11, value: SecretSyncCanonicalValue.uuid(replacementDeviceID.rawValue)),
            .init(tag: 12, value: SecretSyncCanonicalValue.uuid(replacementCredentialID.rawValue)),
            .init(tag: 13, value: try recoverySigningDescriptor(signingPublicKey)),
            .init(tag: 14, value: try recoveryAgreementDescriptor(agreementPublicKey)),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case role, challenge, scopeID, currentCommitDigest, candidateEpoch
        case replacementDeviceID, replacementCredentialID
        case signingPublicKey, agreementPublicKey
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            role: values.decode(
                FullLossRecoveryPossessionRole.self,
                forKey: .role
            ),
            challenge: values.decode(
                FullLossRecoveryChallenge.self,
                forKey: .challenge
            ),
            scopeID: values.decode(SecretScopeID.self, forKey: .scopeID),
            currentCommitDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .currentCommitDigest
            ),
            candidateEpoch: values.decode(UInt64.self, forKey: .candidateEpoch),
            replacementDeviceID: values.decode(
                TrustedDeviceID.self,
                forKey: .replacementDeviceID
            ),
            replacementCredentialID: values.decode(
                DeviceCredentialID.self,
                forKey: .replacementCredentialID
            ),
            signingPublicKey: values.decode(
                SigningPublicKeyDescriptor.self,
                forKey: .signingPublicKey
            ),
            agreementPublicKey: values.decode(
                KeyAgreementPublicKeyDescriptor.self,
                forKey: .agreementPublicKey
            )
        )
    }
}

/// Complete break-glass intent signed by the current recovery authorization key.
public struct GlobalRecoveryTransitionIntent:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let suiteIdentifier: String
    public let appNamespace: String
    public let estateID: UUID
    public let scopeID: SecretScopeID
    public let challenge: FullLossRecoveryChallenge
    public let warning: FullLossRecoveryWarningAcknowledgement
    public let currentCommitDigest: SecretRecordDigest
    public let currentPolicyDigest: SecretRecordDigest
    public let currentPolicyEpoch: UInt64
    public let currentGenerationID: SecretGenerationID
    public let currentRecoveryRecipient: RecoveryRecipientDescriptor
    public let replacementDeviceID: TrustedDeviceID
    public let replacementCredentialID: DeviceCredentialID
    public let replacementSigningPublicKey: SigningPublicKeyDescriptor
    public let replacementAgreementPublicKey: KeyAgreementPublicKeyDescriptor
    public let signingPossessionProof: Data
    public let agreementPossessionProof: Data
    public let candidatePolicyEpoch: UInt64
    public let candidateGenerationID: SecretGenerationID
    public let candidateSignedPolicyDigest: SecretRecordDigest
    public let replacementRecoveryRecipient: RecoveryRecipientDescriptor
    public let recoveryEnvelopeDigest: SecretRecordDigest
    public let candidateSemantics: FullLossRecoveryCandidateSemantics

    public init(
        suiteIdentifier: String = FullLossRecoveryContract.suiteIdentifier,
        appNamespace: String,
        estateID: UUID,
        scopeID: SecretScopeID,
        challenge: FullLossRecoveryChallenge,
        warning: FullLossRecoveryWarningAcknowledgement,
        currentCommitDigest: SecretRecordDigest,
        currentPolicyDigest: SecretRecordDigest,
        currentPolicyEpoch: UInt64,
        currentGenerationID: SecretGenerationID,
        currentRecoveryRecipient: RecoveryRecipientDescriptor,
        replacementDeviceID: TrustedDeviceID,
        replacementCredentialID: DeviceCredentialID,
        replacementSigningPublicKey: SigningPublicKeyDescriptor,
        replacementAgreementPublicKey: KeyAgreementPublicKeyDescriptor,
        signingPossessionProof: Data,
        agreementPossessionProof: Data,
        candidatePolicyEpoch: UInt64,
        candidateGenerationID: SecretGenerationID,
        candidateSignedPolicyDigest: SecretRecordDigest,
        replacementRecoveryRecipient: RecoveryRecipientDescriptor,
        recoveryEnvelopeDigest: SecretRecordDigest,
        candidateSemantics: FullLossRecoveryCandidateSemantics
    ) throws {
        guard suiteIdentifier == FullLossRecoveryContract.suiteIdentifier else {
            throw FullLossRecoveryContractError.invalidSuite
        }
        guard !appNamespace.isEmpty, appNamespace.count <= 256 else {
            throw FullLossRecoveryContractError.invalidNamespace
        }
        guard
            currentPolicyEpoch < UInt64.max,
            candidatePolicyEpoch == currentPolicyEpoch + 1
        else {
            throw FullLossRecoveryContractError.invalidEpoch
        }
        guard
            replacementSigningPublicKey.keyIdentifier
                != replacementAgreementPublicKey.keyIdentifier,
            replacementSigningPublicKey.publicKeyBytes
                != replacementAgreementPublicKey.publicKeyBytes,
            !signingPossessionProof.isEmpty,
            !agreementPossessionProof.isEmpty,
            candidateSignedPolicyDigest == candidateSemantics.signedPolicyDigest,
            recoveryEnvelopeDigest == candidateSemantics.recoveryEnvelopeDigest
        else {
            throw FullLossRecoveryContractError.invalidPossessionTranscript
        }
        self.suiteIdentifier = suiteIdentifier
        self.appNamespace = appNamespace
        self.estateID = estateID
        self.scopeID = scopeID
        self.challenge = challenge
        self.warning = warning
        self.currentCommitDigest = currentCommitDigest
        self.currentPolicyDigest = currentPolicyDigest
        self.currentPolicyEpoch = currentPolicyEpoch
        self.currentGenerationID = currentGenerationID
        self.currentRecoveryRecipient = currentRecoveryRecipient
        self.replacementDeviceID = replacementDeviceID
        self.replacementCredentialID = replacementCredentialID
        self.replacementSigningPublicKey = replacementSigningPublicKey
        self.replacementAgreementPublicKey = replacementAgreementPublicKey
        self.signingPossessionProof = signingPossessionProof
        self.agreementPossessionProof = agreementPossessionProof
        self.candidatePolicyEpoch = candidatePolicyEpoch
        self.candidateGenerationID = candidateGenerationID
        self.candidateSignedPolicyDigest = candidateSignedPolicyDigest
        self.replacementRecoveryRecipient = replacementRecoveryRecipient
        self.recoveryEnvelopeDigest = recoveryEnvelopeDigest
        self.candidateSemantics = candidateSemantics
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .globalRecoveryTransitionIntent
    }

    /// Role-separated canonical challenge for the replacement signing key.
    public func signingPossessionChallengeBytes() throws -> Data {
        try possessionChallenge(role: .signing).canonicalBytes()
    }

    /// Role-separated canonical challenge for the replacement agreement key.
    public func agreementPossessionChallengeBytes() throws -> Data {
        try possessionChallenge(role: .agreement).canonicalBytes()
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            .init(tag: 1, value: SecretSyncCanonicalValue.string(suiteIdentifier)),
            .init(tag: 2, value: SecretSyncCanonicalValue.string(appNamespace)),
            .init(tag: 3, value: SecretSyncCanonicalValue.uuid(estateID)),
            .init(tag: 4, value: SecretSyncCanonicalValue.uuid(scopeID.rawValue)),
            .init(tag: 5, value: SecretSyncCanonicalValue.uuid(challenge.requestID)),
            .init(tag: 6, value: SecretSyncCanonicalValue.uuid(challenge.challengeID)),
            .init(tag: 7, value: SecretSyncCanonicalValue.uuid(challenge.sessionID)),
            .init(tag: 8, value: challenge.nonce),
            .init(tag: 9, value: SecretSyncCanonicalValue.uint64(challenge.issuedAtMilliseconds)),
            .init(tag: 10, value: SecretSyncCanonicalValue.uint64(challenge.expiresAtMilliseconds)),
            .init(tag: 11, value: try warning.canonicalValue()),
            .init(tag: 12, value: currentCommitDigest.bytes),
            .init(tag: 13, value: currentPolicyDigest.bytes),
            .init(tag: 14, value: SecretSyncCanonicalValue.uint64(currentPolicyEpoch)),
            .init(tag: 15, value: SecretSyncCanonicalValue.uuid(currentGenerationID.rawValue)),
            .init(tag: 16, value: try currentRecoveryRecipient.canonicalValue()),
            .init(tag: 17, value: SecretSyncCanonicalValue.uuid(replacementDeviceID.rawValue)),
            .init(tag: 18, value: SecretSyncCanonicalValue.uuid(replacementCredentialID.rawValue)),
            .init(tag: 19, value: try recoverySigningDescriptor(replacementSigningPublicKey)),
            .init(tag: 20, value: try recoveryAgreementDescriptor(replacementAgreementPublicKey)),
            .init(tag: 21, value: try signingPossessionChallengeBytes()),
            .init(tag: 22, value: signingPossessionProof),
            .init(tag: 23, value: try agreementPossessionChallengeBytes()),
            .init(tag: 24, value: agreementPossessionProof),
            .init(tag: 25, value: SecretSyncCanonicalValue.uint64(candidatePolicyEpoch)),
            .init(tag: 26, value: SecretSyncCanonicalValue.uuid(candidateGenerationID.rawValue)),
            .init(tag: 27, value: candidateSignedPolicyDigest.bytes),
            .init(tag: 28, value: try replacementRecoveryRecipient.canonicalValue()),
            .init(tag: 29, value: recoveryEnvelopeDigest.bytes),
            .init(tag: 30, value: try candidateSemantics.canonicalBytes()),
            .init(tag: 31, value: SecretSyncCanonicalValue.string("all-trusted-devices-lost")),
        ]
    }

    private func possessionChallenge(
        role: FullLossRecoveryPossessionRole
    ) throws -> FullLossRecoveryPossessionChallenge {
        try FullLossRecoveryPossessionChallenge(
            role: role,
            challenge: challenge,
            scopeID: scopeID,
            currentCommitDigest: currentCommitDigest,
            candidateEpoch: candidatePolicyEpoch,
            replacementDeviceID: replacementDeviceID,
            replacementCredentialID: replacementCredentialID,
            signingPublicKey: replacementSigningPublicKey,
            agreementPublicKey: replacementAgreementPublicKey
        )
    }

    /// Strictly reconstructs the exact canonical full-loss intent.
    public init(canonicalBytes: Data) throws {
        let fields = try RecoveryCanonicalFields(
            canonicalBytes,
            domain: .globalRecoveryTransitionIntent,
            required: Array(1...31).map(UInt16.init)
        )
        guard try fields.string(31) == "all-trusted-devices-lost" else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        let warningValues = try RecoveryCanonicalFields.sequence(fields.data(11))
        guard warningValues.count == 3 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        let challenge = try FullLossRecoveryChallenge(
            requestID: fields.uuid(5),
            challengeID: fields.uuid(6),
            sessionID: fields.uuid(7),
            nonce: fields.data(8),
            issuedAtMilliseconds: fields.uint64(9),
            expiresAtMilliseconds: fields.uint64(10)
        )
        let currentRecovery = try RecoveryRecipientDescriptor(
            recoveryCanonicalValue: fields.data(16)
        )
        let replacementRecovery = try RecoveryRecipientDescriptor(
            recoveryCanonicalValue: fields.data(28)
        )
        let signing = try RecoveryCanonicalFields.signingDescriptor(fields.data(19))
        let agreement = try RecoveryCanonicalFields.agreementDescriptor(fields.data(20))
        try self.init(
            suiteIdentifier: fields.string(1),
            appNamespace: fields.string(2),
            estateID: fields.uuid(3),
            scopeID: SecretScopeID(fields.uuid(4)),
            challenge: challenge,
            warning: FullLossRecoveryWarningAcknowledgement(
                semanticIdentifier: try RecoveryCanonicalFields.string(warningValues[0]),
                version: try RecoveryCanonicalFields.uint16(warningValues[1]),
                acknowledgement: try RecoveryCanonicalFields.string(warningValues[2])
            ),
            currentCommitDigest: fields.digest(12),
            currentPolicyDigest: fields.digest(13),
            currentPolicyEpoch: fields.uint64(14),
            currentGenerationID: SecretGenerationID(fields.uuid(15)),
            currentRecoveryRecipient: currentRecovery,
            replacementDeviceID: TrustedDeviceID(fields.uuid(17)),
            replacementCredentialID: DeviceCredentialID(fields.uuid(18)),
            replacementSigningPublicKey: signing,
            replacementAgreementPublicKey: agreement,
            signingPossessionProof: fields.data(22),
            agreementPossessionProof: fields.data(24),
            candidatePolicyEpoch: fields.uint64(25),
            candidateGenerationID: SecretGenerationID(fields.uuid(26)),
            candidateSignedPolicyDigest: fields.digest(27),
            replacementRecoveryRecipient: replacementRecovery,
            recoveryEnvelopeDigest: fields.digest(29),
            candidateSemantics: FullLossRecoveryCandidateSemantics(
                canonicalBytes: fields.data(30)
            )
        )
        guard
            try signingPossessionChallengeBytes() == fields.data(21),
            try agreementPossessionChallengeBytes() == fields.data(23),
            try self.canonicalBytes() == canonicalBytes
        else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
    }

    private enum CodingKeys: String, CodingKey {
        case suiteIdentifier, appNamespace, estateID, scopeID, challenge, warning
        case currentCommitDigest, currentPolicyDigest, currentPolicyEpoch
        case currentGenerationID, currentRecoveryRecipient
        case replacementDeviceID, replacementCredentialID
        case replacementSigningPublicKey, replacementAgreementPublicKey
        case signingPossessionProof, agreementPossessionProof
        case candidatePolicyEpoch, candidateGenerationID
        case candidateSignedPolicyDigest, replacementRecoveryRecipient
        case recoveryEnvelopeDigest, candidateSemantics
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            suiteIdentifier: values.decode(
                String.self,
                forKey: .suiteIdentifier
            ),
            appNamespace: values.decode(String.self, forKey: .appNamespace),
            estateID: values.decode(UUID.self, forKey: .estateID),
            scopeID: values.decode(SecretScopeID.self, forKey: .scopeID),
            challenge: values.decode(
                FullLossRecoveryChallenge.self,
                forKey: .challenge
            ),
            warning: values.decode(
                FullLossRecoveryWarningAcknowledgement.self,
                forKey: .warning
            ),
            currentCommitDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .currentCommitDigest
            ),
            currentPolicyDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .currentPolicyDigest
            ),
            currentPolicyEpoch: values.decode(
                UInt64.self,
                forKey: .currentPolicyEpoch
            ),
            currentGenerationID: values.decode(
                SecretGenerationID.self,
                forKey: .currentGenerationID
            ),
            currentRecoveryRecipient: values.decode(
                RecoveryRecipientDescriptor.self,
                forKey: .currentRecoveryRecipient
            ),
            replacementDeviceID: values.decode(
                TrustedDeviceID.self,
                forKey: .replacementDeviceID
            ),
            replacementCredentialID: values.decode(
                DeviceCredentialID.self,
                forKey: .replacementCredentialID
            ),
            replacementSigningPublicKey: values.decode(
                SigningPublicKeyDescriptor.self,
                forKey: .replacementSigningPublicKey
            ),
            replacementAgreementPublicKey: values.decode(
                KeyAgreementPublicKeyDescriptor.self,
                forKey: .replacementAgreementPublicKey
            ),
            signingPossessionProof: values.decode(
                Data.self,
                forKey: .signingPossessionProof
            ),
            agreementPossessionProof: values.decode(
                Data.self,
                forKey: .agreementPossessionProof
            ),
            candidatePolicyEpoch: values.decode(
                UInt64.self,
                forKey: .candidatePolicyEpoch
            ),
            candidateGenerationID: values.decode(
                SecretGenerationID.self,
                forKey: .candidateGenerationID
            ),
            candidateSignedPolicyDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .candidateSignedPolicyDigest
            ),
            replacementRecoveryRecipient: values.decode(
                RecoveryRecipientDescriptor.self,
                forKey: .replacementRecoveryRecipient
            ),
            recoveryEnvelopeDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .recoveryEnvelopeDigest
            ),
            candidateSemantics: values.decode(
                FullLossRecoveryCandidateSemantics.self,
                forKey: .candidateSemantics
            )
        )
    }
}

/// Immutable, content-addressed proof signed by current recovery authority.
public struct FullLossRecoveryAuthorization:
    Sendable,
    Codable,
    Hashable,
    SecretSyncCanonicalEncodable
{
    public let recordDigest: SecretRecordDigest
    public let intent: GlobalRecoveryTransitionIntent
    public let signature: Data

    public init(
        recordDigest: SecretRecordDigest,
        intent: GlobalRecoveryTransitionIntent,
        signature: Data
    ) throws {
        guard !signature.isEmpty else {
            throw FullLossRecoveryContractError.invalidAuthorization
        }
        self.recordDigest = recordDigest
        self.intent = intent
        self.signature = signature
    }

    public var canonicalDomain: SecretSyncCanonicalDomain {
        .fullLossRecoveryAuthorization
    }

    public func canonicalFields() throws -> [SecretSyncCanonicalField] {
        [
            .init(tag: 1, value: try intent.canonicalBytes()),
            .init(tag: 2, value: signature),
        ]
    }

    /// Returns the exact bytes signed by the current recovery authorization key.
    public func signingBytes() throws -> Data {
        try intent.canonicalBytes()
    }

    /// Strictly reconstructs an immutable proof from canonical transport bytes.
    public init(recordDigest: SecretRecordDigest, canonicalBytes: Data) throws {
        let fields = try RecoveryCanonicalFields(
            canonicalBytes,
            domain: .fullLossRecoveryAuthorization,
            required: [1, 2]
        )
        try self.init(
            recordDigest: recordDigest,
            intent: GlobalRecoveryTransitionIntent(
                canonicalBytes: fields.data(1)
            ),
            signature: fields.data(2)
        )
        guard try self.canonicalBytes() == canonicalBytes else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
    }

    private enum CodingKeys: String, CodingKey {
        case recordDigest, intent, signature
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            recordDigest: values.decode(
                SecretRecordDigest.self,
                forKey: .recordDigest
            ),
            intent: values.decode(
                GlobalRecoveryTransitionIntent.self,
                forKey: .intent
            ),
            signature: values.decode(Data.self, forKey: .signature)
        )
    }
}

/// Prompt-free verifier seam for current recovery authority and both fresh keys.
public protocol FullLossRecoveryProofVerifying: Sendable {
    func verifyRecoveryAuthorization(
        signature: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool

    func verifyReplacementSigningPossession(
        proof: Data,
        canonicalBytes: Data,
        signingPublicKey: SigningPublicKeyDescriptor
    ) throws -> Bool

    func verifyReplacementAgreementPossession(
        proof: Data,
        canonicalBytes: Data,
        agreementPublicKey: KeyAgreementPublicKeyDescriptor
    ) throws -> Bool
}

extension RecoveryRecipientDescriptor {
    init(recoveryCanonicalValue bytes: Data) throws {
        let values = try RecoveryCanonicalFields.sequence(bytes)
        guard values.count == 7 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        try self.init(
            recoveryRecipientID: RecoveryCanonicalFields.uuid(values[0]),
            keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
                algorithmIdentifier: RecoveryCanonicalFields.string(values[1]),
                keyIdentifier: values[2],
                publicKeyBytes: values[3]
            ),
            authorizationSigningPublicKey: SigningPublicKeyDescriptor(
                algorithmIdentifier: RecoveryCanonicalFields.string(values[4]),
                keyIdentifier: values[5],
                publicKeyBytes: values[6]
            )
        )
    }
}

private func recoverySortedDigests(
    _ values: [SecretRecordDigest],
    allowEmpty: Bool
) throws -> [SecretRecordDigest] {
    if values.isEmpty, !allowEmpty {
        throw FullLossRecoveryContractError.emptyDigestSet
    }
    let sorted = values.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    for index in sorted.indices.dropFirst() where sorted[index] == sorted[index - 1] {
        throw FullLossRecoveryContractError.duplicateDigest
    }
    return sorted
}

private func recoveryDigestSequence(
    _ values: [SecretRecordDigest]
) throws -> Data {
    try SecretSyncCanonicalValue.sequence(values.map(\.bytes))
}

private func recoverySigningDescriptor(
    _ value: SigningPublicKeyDescriptor
) throws -> Data {
    try SecretSyncCanonicalValue.sequence([
        SecretSyncCanonicalValue.string(value.algorithmIdentifier),
        value.keyIdentifier,
        value.publicKeyBytes,
    ])
}

private func recoveryAgreementDescriptor(
    _ value: KeyAgreementPublicKeyDescriptor
) throws -> Data {
    try SecretSyncCanonicalValue.sequence([
        SecretSyncCanonicalValue.string(value.algorithmIdentifier),
        value.keyIdentifier,
        value.publicKeyBytes,
    ])
}

private struct RecoveryCanonicalFields {
    private let values: [UInt16: Data]

    init(
        _ bytes: Data,
        domain: SecretSyncCanonicalDomain,
        required: [UInt16]
    ) throws {
        let document = try SecretSyncCanonicalEncoding.decode(
            bytes,
            expectedDomain: domain
        )
        let values = Dictionary(
            uniqueKeysWithValues: document.fields.map { ($0.tag, $0.value) }
        )
        guard Set(values.keys) == Set(required) else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        self.values = values
    }

    func data(_ tag: UInt16) throws -> Data {
        guard let value = values[tag] else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return value
    }

    func uuid(_ tag: UInt16) throws -> UUID { try Self.uuid(data(tag)) }
    func string(_ tag: UInt16) throws -> String { try Self.string(data(tag)) }
    func uint64(_ tag: UInt16) throws -> UInt64 { try Self.uint64(data(tag)) }
    func digest(_ tag: UInt16) throws -> SecretRecordDigest {
        try SecretRecordDigest(bytes: data(tag))
    }
    func digestSequence(_ tag: UInt16) throws -> [SecretRecordDigest] {
        try Self.sequence(data(tag)).map(SecretRecordDigest.init(bytes:))
    }

    static func uuid(_ data: Data) throws -> UUID {
        guard
            data.count == 36,
            let text = String(data: data, encoding: .utf8),
            text == text.lowercased(),
            let value = UUID(uuidString: text)
        else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return value
    }

    static func string(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return value
    }

    static func uint16(_ data: Data) throws -> UInt16 {
        guard data.count == 2 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return data.reduce(UInt16.zero) { ($0 << 8) | UInt16($1) }
    }

    static func uint64(_ data: Data) throws -> UInt64 {
        guard data.count == 8 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return data.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    static func sequence(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        var cursor = 2
        var result: [Data] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 4 <= bytes.count else {
                throw FullLossRecoveryContractError.invalidCanonicalShape
            }
            let length = Int(bytes[cursor]) << 24
                | Int(bytes[cursor + 1]) << 16
                | Int(bytes[cursor + 2]) << 8
                | Int(bytes[cursor + 3])
            cursor += 4
            guard cursor + length <= bytes.count else {
                throw FullLossRecoveryContractError.invalidCanonicalShape
            }
            result.append(Data(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        guard cursor == bytes.count else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return result
    }

    static func signingDescriptor(
        _ data: Data
    ) throws -> SigningPublicKeyDescriptor {
        let values = try sequence(data)
        guard values.count == 3 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return try SigningPublicKeyDescriptor(
            algorithmIdentifier: string(values[0]),
            keyIdentifier: values[1],
            publicKeyBytes: values[2]
        )
    }

    static func agreementDescriptor(
        _ data: Data
    ) throws -> KeyAgreementPublicKeyDescriptor {
        let values = try sequence(data)
        guard values.count == 3 else {
            throw FullLossRecoveryContractError.invalidCanonicalShape
        }
        return try KeyAgreementPublicKeyDescriptor(
            algorithmIdentifier: string(values[0]),
            keyIdentifier: values[1],
            publicKeyBytes: values[2]
        )
    }
}
