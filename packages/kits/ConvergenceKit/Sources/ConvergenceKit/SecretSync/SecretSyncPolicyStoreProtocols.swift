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
        self.expectedHead = expectedHead
        self.candidateEntry = candidateEntry
        self.validatedSnapshot = validatedSnapshot
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
