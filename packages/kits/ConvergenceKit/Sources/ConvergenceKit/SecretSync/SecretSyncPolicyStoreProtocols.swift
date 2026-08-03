import Foundation

/// Immutable public identity of one committed policy head.
public struct SecretPolicyStoreHead: Sendable, Hashable {
    public let scopeID: SecretScopeID
    public let policyEpoch: UInt64
    public let commitDigest: SecretRecordDigest
    public let policyDigest: SecretRecordDigest

    public init(
        scopeID: SecretScopeID,
        policyEpoch: UInt64,
        commitDigest: SecretRecordDigest,
        policyDigest: SecretRecordDigest
    ) throws {
        guard policyEpoch > 0 else {
            throw SecretSyncInterfaceError.invalidPolicyEpoch
        }
        self.scopeID = scopeID
        self.policyEpoch = policyEpoch
        self.commitDigest = commitDigest
        self.policyDigest = policyDigest
    }
}

/// Validator-bound authority for one final full-loss recovery publication.
///
/// The type deliberately has no public initializer. A caller can retain or
/// copy the value embedded in a policy precondition, but cannot manufacture a
/// different authorization, session, time window, or candidate binding.
public struct SecretRecoveryPublicationCapability: Sendable, Hashable {
    public let recoveryAuthorizationDigest: SecretRecordDigest
    public let scopeID: SecretScopeID
    public let candidatePolicyEpoch: UInt64
    public let candidateCommitDigest: SecretRecordDigest
    public let candidatePolicyDigest: SecretRecordDigest
    public let requestID: UUID
    public let challengeID: UUID
    public let sessionID: UUID
    public let issuedAtMilliseconds: UInt64
    public let expiresAtMilliseconds: UInt64

    init(
        authorization: FullLossRecoveryAuthorization,
        candidateHead: SecretPolicyStoreHead
    ) {
        let challenge = authorization.intent.challenge
        self.recoveryAuthorizationDigest = authorization.recordDigest
        self.scopeID = candidateHead.scopeID
        self.candidatePolicyEpoch = candidateHead.policyEpoch
        self.candidateCommitDigest = candidateHead.commitDigest
        self.candidatePolicyDigest = candidateHead.policyDigest
        self.requestID = challenge.requestID
        self.challengeID = challenge.challengeID
        self.sessionID = challenge.sessionID
        self.issuedAtMilliseconds = challenge.issuedAtMilliseconds
        self.expiresAtMilliseconds = challenge.expiresAtMilliseconds
    }

    /// Confirms that reconstructed CloudKit authority still agrees with every
    /// value captured when the validator-produced precondition was created.
    public func matches(
        authorization: FullLossRecoveryAuthorization,
        candidateHead: SecretPolicyStoreHead
    ) -> Bool {
        let challenge = authorization.intent.challenge
        return recoveryAuthorizationDigest == authorization.recordDigest
            && scopeID == candidateHead.scopeID
            && candidatePolicyEpoch == candidateHead.policyEpoch
            && candidateCommitDigest == candidateHead.commitDigest
            && candidatePolicyDigest == candidateHead.policyDigest
            && requestID == challenge.requestID
            && challengeID == challenge.challengeID
            && sessionID == challenge.sessionID
            && issuedAtMilliseconds == challenge.issuedAtMilliseconds
            && expiresAtMilliseconds == challenge.expiresAtMilliseconds
    }
}

/// Truthful result from cancelling one live recovery publication capability.
public enum SecretRecoveryAdvanceCancellationResult: Sendable, Hashable {
    case cancelled
    case tooLate
    case notRecovery
}

/// Exact staged and validator-produced authority for a monotonic policy append.
///
/// External callers cannot construct `SecretControlSnapshot`; they can only
/// supply the snapshot returned by `SecretPolicyValidator`.
public struct SecretPolicyAdvancePrecondition: Sendable, Hashable {
    public let expectedHead: SecretPolicyStoreHead?
    public let candidateEntry: SecretPolicyStoreEntry
    public let validatedSnapshot: SecretControlSnapshot
    public let candidateHead: SecretPolicyStoreHead
    public let predecessorCommitDigest: SecretRecordDigest?
    public let recoveryPublicationCapability:
        SecretRecoveryPublicationCapability?

    public init(
        expectedHead: SecretPolicyStoreHead?,
        candidateEntry: SecretPolicyStoreEntry,
        validatedSnapshot: SecretControlSnapshot
    ) throws {
        let committedRecords = try candidateEntry.records.committedCopy()
        guard
            candidateEntry.records.state == .staged,
            validatedSnapshot.commit == candidateEntry.commit,
            validatedSnapshot.records == committedRecords,
            validatedSnapshot.trustedDeviceRecords
                == candidateEntry.trustRecords
        else {
            throw SecretSyncInterfaceError.invalidPolicyAdvancePrecondition
        }
        let commit = candidateEntry.commit
        let candidateHead = try SecretPolicyStoreHead(
            scopeID: commit.scopeID,
            policyEpoch: commit.policyEpoch,
            commitDigest: commit.recordDigest,
            policyDigest: commit.policyDigest
        )
        let predecessorCommitDigest = commit.predecessorCommitDigest
        if let expectedHead {
            guard
                expectedHead.policyEpoch < UInt64.max,
                candidateHead.scopeID == expectedHead.scopeID,
                candidateHead.policyEpoch == expectedHead.policyEpoch + 1,
                predecessorCommitDigest == expectedHead.commitDigest
            else {
                throw SecretSyncInterfaceError.invalidPolicyAdvancePrecondition
            }
        } else {
            guard
                candidateHead.policyEpoch == 1,
                predecessorCommitDigest == nil
            else {
                throw SecretSyncInterfaceError.invalidPolicyAdvancePrecondition
            }
        }
        let recoveryPublicationCapability:
            SecretRecoveryPublicationCapability?
        if let authorization = candidateEntry.records.recoveryAuthorization {
            let intent = authorization.intent
            guard let expectedHead,
                  commit.recoveryAuthorizationDigest
                    == authorization.recordDigest,
                  intent.scopeID == candidateHead.scopeID,
                  intent.currentCommitDigest == expectedHead.commitDigest,
                  intent.currentPolicyDigest == expectedHead.policyDigest,
                  intent.currentPolicyEpoch == expectedHead.policyEpoch,
                  intent.candidatePolicyEpoch == candidateHead.policyEpoch,
                  intent.candidateGenerationID == commit.generationID,
                  intent.candidateSignedPolicyDigest
                    == candidateHead.policyDigest,
                  intent.recoveryEnvelopeDigest
                    == commit.recoveryEnvelopeDigest,
                  intent.replacementRecoveryRecipient
                    == candidateEntry.records.signedPolicy.policy
                        .recoveryRecipient
            else {
                throw SecretSyncInterfaceError
                    .invalidPolicyAdvancePrecondition
            }
            recoveryPublicationCapability =
                SecretRecoveryPublicationCapability(
                    authorization: authorization,
                    candidateHead: candidateHead
                )
        } else {
            recoveryPublicationCapability = nil
        }
        self.expectedHead = expectedHead
        self.candidateEntry = candidateEntry
        self.validatedSnapshot = validatedSnapshot
        self.candidateHead = candidateHead
        self.predecessorCommitDigest = predecessorCommitDigest
        self.recoveryPublicationCapability = recoveryPublicationCapability
    }
}

/// Explicit outcome from a compare-and-advance attempt.
public enum SecretPolicyAdvanceResult: Sendable, Hashable {
    case advanced(SecretPolicyStoreHead)
    case forkDetected(
        currentHead: SecretPolicyStoreHead,
        competingCommitDigest: SecretRecordDigest
    )
}

/// Immutable policy-store value retaining one commit and its referenced records.
///
/// The entry keeps the signed transition certificate beside its complete
/// control and policy-referenced trust-record sets, including revoked
/// tombstones. Full transition validation separately requires the current
/// snapshot, trusted credentials, competing-child knowledge, external
/// freshness, a digester, and a signature verifier.
public struct SecretPolicyStoreEntry: Sendable, Hashable {
    public let commit: SecretTransitionCommit
    public let records: SecretControlRecords
    public let credentials: [TrustedDeviceCredential]
    public let trustRecords: [DeviceTrustRecord]

    public init(
        commit: SecretTransitionCommit,
        records: SecretControlRecords,
        credentials: [TrustedDeviceCredential],
        trustRecords: [DeviceTrustRecord],
        digester: any SecretSyncDigesting
    ) throws {
        let policy = records.signedPolicy.policy
        let sortedCredentials = credentials.sorted {
            $0.credentialID.rawValue.uuidString.lowercased()
                < $1.credentialID.rawValue.uuidString.lowercased()
        }
        let sortedTrustRecords = trustRecords.sorted {
            $0.recordDigest.bytes.lexicographicallyPrecedes(
                $1.recordDigest.bytes
            )
        }
        var credentialDigestsByID: [
            DeviceCredentialID: SecretRecordDigest
        ] = [:]
        for credential in sortedCredentials {
            guard credentialDigestsByID[credential.credentialID] == nil else {
                throw SecretSyncInterfaceError.invalidPolicyStoreEntry
            }
            credentialDigestsByID[credential.credentialID] = try digester.digest(
                canonicalBytes: credential.canonicalBytes()
            )
        }
        guard
            records.state != .rejected,
            sortedCredentials.count == sortedTrustRecords.count,
            Set(sortedCredentials.map(\.credentialID))
                == Set(sortedTrustRecords.map(\.credentialID)),
            sortedTrustRecords.allSatisfy({ record in
                credentialDigestsByID[record.credentialID]
                    == record.credentialDigest
            }),
            sortedTrustRecords.map(\.recordDigest)
                == policy.trustedDeviceRecordDigests,
            commit.scopeID == policy.scopeSnapshot.scopeID,
            commit.policyEpoch == policy.epoch,
            commit.policyDigest == records.signedPolicy.recordDigest,
            commit.scopeSnapshotDigest == policy.scopeSnapshot.snapshotDigest,
            commit.generationID == policy.generationID,
            commit.sealedPayloadDigest == records.sealedPayload.recordDigest,
            commit.recipientEnvelopeDigests
                == records.recipientEnvelopes.map(\.recordDigest),
            commit.recoveryEnvelopeDigest
                == records.recoveryEnvelope?.recordDigest,
            commit.purgeRequirementDigests
                == records.purgeRequirements.map(\.recordDigest),
            commit.purgeReceiptDigests
                == records.purgeReceipts.map(\.recordDigest),
            commit.recoveryAuthorizationDigest
                == records.recoveryAuthorization?.recordDigest
        else {
            throw SecretSyncInterfaceError.invalidPolicyStoreEntry
        }
        self.commit = commit
        self.records = records
        self.credentials = sortedCredentials
        self.trustRecords = sortedTrustRecords
    }
}

/// Append-only storage seam for immutable policy entries.
///
/// The store is transport. It can prove that an exact content-addressed graph
/// reached storage and that the graph's structural bindings hold; it cannot
/// admit authority, because it holds none of the inputs authority requires.
/// `compareAndAdvance` is the only member that acts on validated authority, and
/// only because `SecretPolicyAdvancePrecondition` cannot be constructed without
/// a `SecretControlSnapshot` that `SecretPolicyValidator` produced.
public protocol SecretSyncPolicyStore: Sendable {
    func stagedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry?

    /// Reconstructs the graph the mutable scope head references at `epoch`,
    /// making no claim about its authority.
    ///
    /// Reconstruction proves content-addressing — every record's digest matches
    /// its canonical bytes — together with the predecessor chain and the
    /// recipient-to-purge correspondence. It proves nothing about authority:
    /// signature fields are carried as opaque bytes and no verifier runs,
    /// because a store holds neither trusted credentials, nor an external
    /// freshness commitment, nor a signature verifier.
    ///
    /// The scope head is mutable transport. A party able to write records into
    /// the backing database can stage a structurally valid graph carrying
    /// arbitrary signature bytes and point the head at it. A conformer that
    /// answers by reading such a head therefore returns `.staged`: it has no
    /// basis for any stronger claim. A conformer that already holds
    /// validator-admitted material may return it as it stands — what this
    /// requirement forbids is inferring authority from the head.
    ///
    /// The caller — which does hold credentials, a verifier and a freshness
    /// commitment — must validate through `SecretPolicyValidator` before
    /// treating the result as authoritative. This is the hydration path after a
    /// restart, not a trust decision.
    func unvalidatedHeadPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry?

    func policyHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretPolicyStoreHead?

    func appendStagedPolicy(
        _ entry: SecretPolicyStoreEntry
    ) async throws

    func compareAndAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretPolicyAdvanceResult

    /// Cancels a full-loss recovery before its final head write is issued.
    func cancelRecoveryAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async -> SecretRecoveryAdvanceCancellationResult
}
