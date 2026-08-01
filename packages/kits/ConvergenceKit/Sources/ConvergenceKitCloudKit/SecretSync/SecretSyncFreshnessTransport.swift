import CloudKit
import ConvergenceKit
import Foundation

/// Device-local rollback-floor seam implemented by the AppleSecurity owner.
///
/// This protocol is deliberately not an external freshness anchor. It exposes
/// only the exact highest protected local commitment already held by a device.
public protocol SecretSyncProtectedHeadProviding: Sendable {
    func protectedHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretBootstrapFreshnessCommitment
}

/// Provenance-bearing normal-path freshness authorities.
public enum SecretSyncFreshnessAuthority: Sendable {
    case protectedLocal(any SecretSyncProtectedHeadProviding)
    case authenticatedTrustedPeer(any ExternalBootstrapFreshnessAnchor)
}

/// A CloudKit-current value carried toward U6 recovery custody.
///
/// Its type exposes that transport succeeded while making no authorization or
/// recovery claim. U6 must supply an unforgeable recovery capability.
public struct SecretSyncRecoveryTransportCandidate: Sendable, Hashable {
    public let commitment: SecretBootstrapFreshnessCommitment
    public var authorizesRecovery: Bool { false }

    public init(commitment: SecretBootstrapFreshnessCommitment) {
        self.commitment = commitment
    }
}

/// Fixed, payload-free freshness failures.
public enum SecretSyncFreshnessTransportError: Error, Sendable, Equatable {
    case rollbackOrRestoreMismatch
    case forkDetected
    case catchUpIncomplete
    case cloudHeadUnavailable
    case invalidCloudHead
    case transportFailure
}

/// Opaque transport for normal freshness evidence and recovery candidates.
///
/// CloudKit heads, account membership, zone presence, and change tokens are
/// never accepted as normal-path authority by this actor.
public actor SecretSyncFreshnessTransport {
    private let database: any CloudKitDatabaseProtocol

    public init(database: any CloudKitDatabaseProtocol) {
        self.database = database
    }

    public func normalPathCommitment(
        for scopeID: SecretScopeID,
        authority: SecretSyncFreshnessAuthority
    ) async throws -> SecretBootstrapFreshnessCommitment {
        // Both authority modes stay in one exhaustive switch because their
        // CloudKit failure laws intentionally differ: protected local permits
        // offline use, while trusted-peer catch-up requires exact convergence.
        switch authority {
        case .protectedLocal(let provider):
            let protected: SecretBootstrapFreshnessCommitment
            do {
                protected = try await provider.protectedHead(for: scopeID)
            } catch {
                throw SecretSyncFreshnessTransportError
                    .rollbackOrRestoreMismatch
            }
            guard protected.scopeID == scopeID else {
                throw SecretSyncFreshnessTransportError
                    .rollbackOrRestoreMismatch
            }
            let cloud: SecretBootstrapFreshnessCommitment
            do {
                cloud = try await cloudCommitment(for: scopeID)
            } catch SecretSyncFreshnessTransportError.cloudHeadUnavailable {
                throw SecretSyncFreshnessTransportError
                    .rollbackOrRestoreMismatch
            } catch SecretSyncFreshnessTransportError.transportFailure {
                // An enrolled device remains usable offline from its exact
                // protected floor. No CloudKit-derived value is returned.
                return protected
            }
            if cloud.latestPolicyEpoch < protected.latestPolicyEpoch {
                throw SecretSyncFreshnessTransportError
                    .rollbackOrRestoreMismatch
            }
            if cloud.latestPolicyEpoch == protected.latestPolicyEpoch,
               cloud != protected
            {
                throw SecretSyncFreshnessTransportError.forkDetected
            }
            // A CloudKit-ahead value remains a transport candidate only. The
            // protected exact commitment is the normal authority until a
            // validator advances the protected floor or a peer anchors catch-up.
            return protected

        case .authenticatedTrustedPeer(let peer):
            let trusted: SecretBootstrapFreshnessCommitment
            do {
                trusted = try await peer.latestCommitment(for: scopeID)
            } catch {
                throw SecretSyncFreshnessTransportError.transportFailure
            }
            guard trusted.scopeID == scopeID else {
                throw SecretSyncFreshnessTransportError.forkDetected
            }
            let cloud: SecretBootstrapFreshnessCommitment
            do {
                cloud = try await cloudCommitment(for: scopeID)
            } catch SecretSyncFreshnessTransportError.cloudHeadUnavailable {
                throw SecretSyncFreshnessTransportError.catchUpIncomplete
            }
            if trusted == cloud { return trusted }
            if trusted.latestPolicyEpoch == cloud.latestPolicyEpoch {
                throw SecretSyncFreshnessTransportError.forkDetected
            }
            // Different epochs are an incomplete replication observation, not
            // proof of equivocation. The caller may retry until exact equality.
            throw SecretSyncFreshnessTransportError.catchUpIncomplete
        }
    }

    public func recoveryTransportCandidate(
        for scopeID: SecretScopeID
    ) async throws -> SecretSyncRecoveryTransportCandidate {
        SecretSyncRecoveryTransportCandidate(
            commitment: try await cloudCommitment(for: scopeID)
        )
    }

    private func cloudCommitment(
        for scopeID: SecretScopeID
    ) async throws -> SecretBootstrapFreshnessCommitment {
        let id = SecretSyncHeadCAS.recordID(for: scopeID)
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.fetch(withRecordIDs: [id])
        } catch {
            throw SecretSyncFreshnessTransportError.transportFailure
        }
        guard Set(results.keys) == [id], let result = results[id] else {
            throw SecretSyncFreshnessTransportError.transportFailure
        }
        let record: CKRecord
        switch result {
        case .success(let value):
            record = value
        case .failure(let error):
            if let cloudError = error as? CKError,
               cloudError.code == .unknownItem
            {
                throw SecretSyncFreshnessTransportError.cloudHeadUnavailable
            }
            throw SecretSyncFreshnessTransportError.transportFailure
        }
        let head: SecretPolicyStoreHead
        do {
            head = try SecretSyncHeadCAS.storeHead(from: record)
        } catch {
            throw SecretSyncFreshnessTransportError.invalidCloudHead
        }
        return try SecretBootstrapFreshnessCommitment(
            scopeID: head.scopeID,
            latestPolicyEpoch: head.policyEpoch,
            headCommitDigest: head.commitDigest,
            policyDigest: head.policyDigest
        )
    }
}
