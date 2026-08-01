import Foundation

/// Opaque evidence that a recovery descriptor was confirmed out of band.
///
/// The bytes are input to a future verifier and do not claim confirmation,
/// biometric approval, or enrollment occurred.
public struct BlindRecoveryConfirmationEvidence: Sendable, Hashable {
    public let recoveryRecipientID: UUID
    public let challengeID: UUID
    public let evidenceBytes: Data

    public init(
        recoveryRecipientID: UUID,
        challengeID: UUID,
        evidenceBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            evidenceBytes,
            field: "blindRecoveryConfirmationEvidenceBytes"
        )
        self.recoveryRecipientID = recoveryRecipientID
        self.challengeID = challengeID
        self.evidenceBytes = evidenceBytes
    }
}

/// Request to stage the one global recovery recipient.
public struct RecoveryEnrollmentRequest: Sendable, Hashable {
    public let requestID: UUID
    public let recoveryRecipient: RecoveryRecipientDescriptor
    public let blindConfirmation: BlindRecoveryConfirmationEvidence

    public init(
        requestID: UUID,
        recoveryRecipient: RecoveryRecipientDescriptor,
        blindConfirmation: BlindRecoveryConfirmationEvidence
    ) throws {
        guard
            recoveryRecipient.recoveryRecipientID
                == blindConfirmation.recoveryRecipientID
        else {
            throw SecretSyncInterfaceError.recoveryRecipientMismatch
        }
        self.requestID = requestID
        self.recoveryRecipient = recoveryRecipient
        self.blindConfirmation = blindConfirmation
    }
}

/// Request to rotate recovery custody into a fresh sealed generation.
public struct RecoveryRotationRequest: Sendable, Hashable {
    public let requestID: UUID
    public let scopeID: SecretScopeID
    public let currentRecoveryRecipientID: UUID
    public let replacementRecoveryRecipient: RecoveryRecipientDescriptor
    public let currentGenerationID: SecretGenerationID
    public let replacementGenerationID: SecretGenerationID
    public let expectedFreshnessCommitment: SecretBootstrapFreshnessCommitment
    public let blindConfirmation: BlindRecoveryConfirmationEvidence

    public init(
        requestID: UUID,
        scopeID: SecretScopeID,
        currentRecoveryRecipientID: UUID,
        replacementRecoveryRecipient: RecoveryRecipientDescriptor,
        currentGenerationID: SecretGenerationID,
        replacementGenerationID: SecretGenerationID,
        expectedFreshnessCommitment: SecretBootstrapFreshnessCommitment,
        blindConfirmation: BlindRecoveryConfirmationEvidence
    ) throws {
        guard currentGenerationID != replacementGenerationID else {
            throw SecretSyncInterfaceError.generationReuse
        }
        guard
            replacementRecoveryRecipient.recoveryRecipientID
                == blindConfirmation.recoveryRecipientID,
            scopeID == expectedFreshnessCommitment.scopeID
        else {
            throw SecretSyncInterfaceError.recoveryRecipientMismatch
        }
        self.requestID = requestID
        self.scopeID = scopeID
        self.currentRecoveryRecipientID = currentRecoveryRecipientID
        self.replacementRecoveryRecipient = replacementRecoveryRecipient
        self.currentGenerationID = currentGenerationID
        self.replacementGenerationID = replacementGenerationID
        self.expectedFreshnessCommitment = expectedFreshnessCommitment
        self.blindConfirmation = blindConfirmation
    }
}

/// Explicit break-glass request bound to one scope and external head commitment.
public struct BreakGlassRecoveryRequest: Sendable, Hashable {
    public let requestID: UUID
    public let scopeID: SecretScopeID
    public let recoveryRecipientID: UUID
    public let sealedGenerationID: SecretGenerationID
    public let expectedFreshnessCommitment: SecretBootstrapFreshnessCommitment
    public let blindConfirmation: BlindRecoveryConfirmationEvidence

    public init(
        requestID: UUID,
        scopeID: SecretScopeID,
        recoveryRecipientID: UUID,
        sealedGenerationID: SecretGenerationID,
        expectedFreshnessCommitment: SecretBootstrapFreshnessCommitment,
        blindConfirmation: BlindRecoveryConfirmationEvidence
    ) throws {
        guard
            recoveryRecipientID == blindConfirmation.recoveryRecipientID,
            scopeID == expectedFreshnessCommitment.scopeID
        else {
            throw SecretSyncInterfaceError.recoveryRecipientMismatch
        }
        self.requestID = requestID
        self.scopeID = scopeID
        self.recoveryRecipientID = recoveryRecipientID
        self.sealedGenerationID = sealedGenerationID
        self.expectedFreshnessCommitment = expectedFreshnessCommitment
        self.blindConfirmation = blindConfirmation
    }
}

/// Opaque provider output for a staged recovery request.
///
/// The value is evidence for a later gate. It does not assert that recovery,
/// rotation, enrollment, or any cryptographic operation succeeded.
public struct RecoveryOperationEvidence: Sendable, Hashable {
    public let requestID: UUID
    public let evidenceBytes: Data

    public init(
        requestID: UUID,
        evidenceBytes: Data
    ) throws {
        try SecretSyncContractBounds.requireOpaqueBytes(
            evidenceBytes,
            field: "recoveryOperationEvidenceBytes"
        )
        self.requestID = requestID
        self.evidenceBytes = evidenceBytes
    }
}

/// Atomic staged graph admitted by the full-loss recovery validator.
///
/// The wrapper prevents callers from presenting a recovery proof separately
/// from the exact commit, credentials, trust tombstones, and sealed records it
/// authorizes. Cryptographic signatures remain the validator's responsibility.
public struct RecoveryPreparedTransition: Sendable, Hashable {
    public let entry: SecretPolicyStoreEntry

    public init(
        commit: SecretTransitionCommit,
        records: SecretControlRecords,
        credentials: [TrustedDeviceCredential],
        trustRecords: [DeviceTrustRecord],
        digester: any SecretSyncDigesting
    ) throws {
        guard
            records.state == .staged,
            let authorization = records.recoveryAuthorization,
            commit.recoveryAuthorizationDigest == authorization.recordDigest,
            records.purgeReceipts.isEmpty,
            commit.purgeReceiptDigests.isEmpty
        else {
            throw SecretSyncInterfaceError.invalidPolicyStoreEntry
        }
        let intent = authorization.intent
        let semantics = intent.candidateSemantics
        let credentialDigests = try credentials.map {
            try digester.digest(canonicalBytes: $0.canonicalBytes())
        }
        guard
            semantics.scopeSnapshotDigest
                == records.signedPolicy.policy.scopeSnapshot.snapshotDigest,
            semantics.signedPolicyDigest == records.signedPolicy.recordDigest,
            semantics.sealedPayloadDigest == records.sealedPayload.recordDigest,
            semantics.recipientEnvelopeDigests
                == records.recipientEnvelopes.map(\.recordDigest),
            semantics.recoveryEnvelopeDigest
                == records.recoveryEnvelope?.recordDigest,
            semantics.purgeRequirementDigests
                == records.purgeRequirements.map(\.recordDigest),
            semantics.purgeReceiptDigests.isEmpty,
            semantics.credentialDigests == credentialDigests.sorted(by: {
                $0.bytes.lexicographicallyPrecedes($1.bytes)
            }),
            semantics.trustRecordDigests
                == trustRecords.map(\.recordDigest).sorted(by: {
                    $0.bytes.lexicographicallyPrecedes($1.bytes)
                }),
            records.signedPolicy.policy.signerCredentialID
                == intent.replacementCredentialID,
            commit.signerCredentialID == intent.replacementCredentialID,
            records.signedPolicy.policy.authorizedRecipientCredentialIDs
                == [intent.replacementCredentialID]
        else {
            throw SecretSyncInterfaceError.invalidPolicyStoreEntry
        }
        self.entry = try SecretPolicyStoreEntry(
            commit: commit,
            records: records,
            credentials: credentials,
            trustRecords: trustRecords,
            digester: digester
        )
    }
}

/// Custody seam for the one global break-glass recovery recipient.
///
/// Rotation and break-glass require the existing independent freshness-anchor
/// seam; local storage alone cannot satisfy those parameters.
public protocol SecretSyncRecoveryRecipientCustody: Sendable {
    func globalRecoveryRecipient() async throws -> RecoveryRecipientDescriptor?

    func stageEnrollment(
        _ request: RecoveryEnrollmentRequest
    ) async throws -> RecoveryOperationEvidence

    func stageRotation(
        _ request: RecoveryRotationRequest,
        freshnessAnchor: any ExternalBootstrapFreshnessAnchor
    ) async throws -> RecoveryOperationEvidence

    func stageBreakGlass(
        _ request: BreakGlassRecoveryRequest,
        freshnessAnchor: any ExternalBootstrapFreshnessAnchor
    ) async throws -> RecoveryOperationEvidence
}
