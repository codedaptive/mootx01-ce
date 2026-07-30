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

/// Append-only storage seam for immutable staged and committed policy records.
public protocol SecretSyncPolicyStore: Sendable {
    func stagedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretControlRecords?

    func committedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretControlRecords?

    func policyHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretPolicyStoreHead?

    func appendStagedPolicy(
        _ records: SecretControlRecords
    ) async throws

    func compareAndAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretPolicyAdvanceResult
}
