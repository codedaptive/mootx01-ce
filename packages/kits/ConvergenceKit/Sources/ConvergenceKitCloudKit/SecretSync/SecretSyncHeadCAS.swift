import CloudKit
import ConvergenceKit
import Foundation

/// Payload-free failures for the single mutable SecretSync CloudKit record.
public enum SecretSyncHeadCASError: Error, Sendable, Equatable {
    case incompleteFetchResults
    case invalidHead
    case rollbackDetected
    case conditionalWriteFailed
    case transportFailure
    case recoveryCapabilityMismatch
    case recoveryAuthorizationNotYetValid
    case recoveryAuthorizationExpired
    case recoveryPublicationCancelled
    case recoveryCapabilityConsumed
}

enum SecretSyncHeadCASAttempt: Sendable {
    case advanced(SecretPolicyStoreHead)
    case stale(SecretPolicyStoreHead?)
}

/// The sole writer of `SSScopeHeadV1`.
///
/// Every replacement starts from the exact fetched `CKRecord`, preserving its
/// server change tag, and crosses the U4 atomic conditional-write seam. This
/// actor never merges fields and never treats record presence as authority.
public actor SecretSyncHeadCAS {
    private let database: any CloudKitDatabaseProtocol
    private let digester: any SecretSyncDigesting
    private let recoveryTimeSource: @Sendable () -> UInt64
    private var cancelledRecoveryCapabilities:
        Set<SecretRecoveryPublicationCapability> = []
    private var consumedRecoveryCapabilities:
        Set<SecretRecoveryPublicationCapability> = []

    public init(
        database: any CloudKitDatabaseProtocol,
        digester: any SecretSyncDigesting
    ) {
        self.database = database
        self.digester = digester
        // Recovery authorization timestamps are Unix wall-time milliseconds.
        // The production authority therefore trusts the platform wall clock;
        // privileged clock rollback remains outside this threat model.
        self.recoveryTimeSource = {
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            return milliseconds > 0 ? UInt64(milliseconds) : 0
        }
    }

    init(
        database: any CloudKitDatabaseProtocol,
        digester: any SecretSyncDigesting,
        recoveryTimeSource: @escaping @Sendable () -> UInt64
    ) {
        self.database = database
        self.digester = digester
        self.recoveryTimeSource = recoveryTimeSource
    }

    public func currentHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretPolicyStoreHead? {
        let id = Self.recordID(for: scopeID)
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.fetch(withRecordIDs: [id])
        } catch {
            throw SecretSyncHeadCASError.transportFailure
        }
        guard Set(results.keys) == [id], let result = results[id] else {
            throw SecretSyncHeadCASError.incompleteFetchResults
        }
        switch result {
        case .success(let record):
            return try Self.storeHead(from: record)
        case .failure(let error):
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                return nil
            }
            throw SecretSyncHeadCASError.transportFailure
        }
    }

    func attempt(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretSyncHeadCASAttempt {
        // Fetch, detach, conditionally write, and classify the server outcome
        // remain one bounded state machine so no helper can accidentally reuse
        // a stale fetched record or bypass the sole-writer conditional seam.
        let currentRecord = try await fetchCurrentRecord(
            for: precondition.candidateHead.scopeID
        )
        let recordToSave: CKRecord

        if let expected = precondition.expectedHead {
            guard let currentRecord else {
                throw SecretSyncHeadCASError.rollbackDetected
            }
            let current = try Self.storeHead(from: currentRecord)
            guard current == expected else {
                return .stale(current)
            }
            // CKRecord is reference-backed. Mutating the fetched instance can
            // alias a database cache or test transport before CloudKit accepts
            // the conditional write. A secure-coding round trip preserves its
            // system fields/change tag while isolating the candidate mutation.
            let candidateRecord = try Self.detachedCopy(of: currentRecord)
            recordToSave = try CKRecordMapping.applyingSecretSyncScopeHead(
                Self.cloudHead(from: precondition.candidateHead),
                to: candidateRecord
            )
        } else {
            if let currentRecord {
                return .stale(try Self.storeHead(from: currentRecord))
            }
            recordToSave = try CKRecordMapping.secretSyncScopeHeadRecord(
                Self.cloudHead(from: precondition.candidateHead)
            )
        }

        // This is the recovery publication linearization boundary. It runs
        // after the awaited fetch and record construction. The owned clock
        // sample, validity check, cancellation check, and one-shot consumption
        // are synchronous actor-isolated operations immediately before the
        // single database invocation below.
        try admitRecoveryPublicationIfNeeded(precondition)

        let result: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        )
        do {
            result = try await database.modifySecretSyncRecords(
                saving: [recordToSave],
                digester: digester
            )
        } catch {
            // A thrown transport result is ambiguous: CloudKit may have
            // accepted the conditional write. Recovery never reissues the
            // consumed capability; only the exact candidate head can classify
            // this one issued attempt as successful.
            if precondition.recoveryPublicationCapability != nil,
               let authoritative = try? await currentHead(
                   for: precondition.candidateHead.scopeID
               ),
               authoritative == precondition.candidateHead
            {
                return .advanced(authoritative)
            }
            throw SecretSyncHeadCASError.transportFailure
        }
        guard let item = result.saveResults[recordToSave.recordID] else {
            throw SecretSyncHeadCASError.conditionalWriteFailed
        }
        switch item {
        case .success:
            return .advanced(precondition.candidateHead)
        case .failure(let error):
            if let cloudError = error as? CKError,
               cloudError.code == .serverRecordChanged
            {
                return .stale(
                    try await currentHead(for: precondition.candidateHead.scopeID)
                )
            }
            throw SecretSyncHeadCASError.conditionalWriteFailed
        }
    }

    func cancelRecoveryAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) -> SecretRecoveryAdvanceCancellationResult {
        guard let capability = precondition.recoveryPublicationCapability else {
            return .notRecovery
        }
        guard !consumedRecoveryCapabilities.contains(capability) else {
            return .tooLate
        }
        cancelledRecoveryCapabilities.insert(capability)
        return .cancelled
    }

    private func admitRecoveryPublicationIfNeeded(
        _ precondition: SecretPolicyAdvancePrecondition
    ) throws {
        guard let capability = precondition.recoveryPublicationCapability else {
            return
        }
        guard let authorization = precondition.candidateEntry.records
                .recoveryAuthorization,
              capability.matches(
                  authorization: authorization,
                  candidateHead: precondition.candidateHead
              )
        else {
            throw SecretSyncHeadCASError.recoveryCapabilityMismatch
        }
        let nowMilliseconds = recoveryTimeSource()
        guard nowMilliseconds >= capability.issuedAtMilliseconds else {
            throw SecretSyncHeadCASError.recoveryAuthorizationNotYetValid
        }
        guard nowMilliseconds < capability.expiresAtMilliseconds else {
            throw SecretSyncHeadCASError.recoveryAuthorizationExpired
        }
        guard !cancelledRecoveryCapabilities.contains(capability) else {
            throw SecretSyncHeadCASError.recoveryPublicationCancelled
        }
        guard consumedRecoveryCapabilities.insert(capability).inserted else {
            throw SecretSyncHeadCASError.recoveryCapabilityConsumed
        }
    }

    private func fetchCurrentRecord(
        for scopeID: SecretScopeID
    ) async throws -> CKRecord? {
        let id = Self.recordID(for: scopeID)
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.fetch(withRecordIDs: [id])
        } catch {
            throw SecretSyncHeadCASError.transportFailure
        }
        guard Set(results.keys) == [id], let result = results[id] else {
            throw SecretSyncHeadCASError.incompleteFetchResults
        }
        switch result {
        case .success(let record):
            _ = try Self.storeHead(from: record)
            return record
        case .failure(let error):
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                return nil
            }
            throw SecretSyncHeadCASError.transportFailure
        }
    }

    private static func detachedCopy(of record: CKRecord) throws -> CKRecord {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: record,
                requiringSecureCoding: true
            )
            guard let copy = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKRecord.self,
                from: data
            ) else {
                throw SecretSyncHeadCASError.invalidHead
            }
            return copy
        } catch let error as SecretSyncHeadCASError {
            throw error
        } catch {
            throw SecretSyncHeadCASError.invalidHead
        }
    }

    static func recordID(for scopeID: SecretScopeID) -> CKRecord.ID {
        var uuid = scopeID.rawValue.uuid
        let bytes = withUnsafeBytes(of: &uuid) { Data($0) }
        return CKRecord.ID(
            recordName: bytes.secretSyncLowercaseHex,
            zoneID: SecretSyncCloudKitZones.controlZoneID
        )
    }

    static func storeHead(from record: CKRecord) throws -> SecretPolicyStoreHead {
        let value: SecretSyncCloudKitScopeHead
        do {
            value = try CKRecordMapping.decodeSecretSyncScopeHead(record)
        } catch {
            throw SecretSyncHeadCASError.invalidHead
        }
        return try SecretPolicyStoreHead(
            scopeID: value.scopeID,
            policyEpoch: value.policyEpoch,
            commitDigest: value.headCommitDigest,
            policyDigest: value.policyDigest
        )
    }

    private static func cloudHead(
        from head: SecretPolicyStoreHead
    ) throws -> SecretSyncCloudKitScopeHead {
        try SecretSyncCloudKitScopeHead(
            scopeID: head.scopeID,
            policyEpoch: head.policyEpoch,
            headCommitDigest: head.commitDigest,
            policyDigest: head.policyDigest
        )
    }
}
