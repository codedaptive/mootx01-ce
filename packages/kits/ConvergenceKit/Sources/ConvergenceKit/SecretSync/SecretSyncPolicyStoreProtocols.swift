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

/// Exact compare-and-advance expectation for a monotonic policy append.
public struct SecretPolicyAdvancePrecondition: Sendable, Hashable {
    public let expectedHead: SecretPolicyStoreHead?
    public let candidateHead: SecretPolicyStoreHead
    public let predecessorCommitDigest: SecretRecordDigest?

    public init(
        expectedHead: SecretPolicyStoreHead?,
        candidateHead: SecretPolicyStoreHead,
        predecessorCommitDigest: SecretRecordDigest?
    ) throws {
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
        self.expectedHead = expectedHead
        self.candidateHead = candidateHead
        self.predecessorCommitDigest = predecessorCommitDigest
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
/// record set. Full transition validation separately requires the current
/// snapshot, trust inputs, competing-child knowledge, external freshness,
/// a digester, and a signature verifier.
public struct SecretPolicyStoreEntry: Sendable, Hashable {
    public let commit: SecretTransitionCommit
    public let records: SecretControlRecords

    public init(
        commit: SecretTransitionCommit,
        records: SecretControlRecords
    ) throws {
        let policy = records.signedPolicy.policy
        guard
            records.state != .rejected,
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
                == records.purgeReceipts.map(\.recordDigest)
        else {
            throw SecretSyncInterfaceError.invalidPolicyStoreEntry
        }
        self.commit = commit
        self.records = records
    }
}

/// Append-only storage seam for immutable staged and committed policy entries.
public protocol SecretSyncPolicyStore: Sendable {
    func stagedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry?

    func committedPolicy(
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
}
