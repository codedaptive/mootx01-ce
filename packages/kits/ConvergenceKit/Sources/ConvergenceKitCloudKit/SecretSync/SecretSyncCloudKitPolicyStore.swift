import CloudKit
import ConvergenceKit
import Foundation

/// Fixed, payload-free failures from exact CloudKit policy reconstruction.
public enum SecretSyncCloudKitPolicyStoreError: Error, Sendable, Equatable {
    case incompleteFetchResults
    case incompleteRecordSet
    case invalidCanonicalRecord
    case referenceMismatch
    case competingStagedPolicies
    case immutableWriteFailed
    case headRollbackDetected
    case conditionalWriteConflict
    case transportFailure
}

/// CloudKit-backed append-only policy store.
///
/// Immutable records may stage in either SecretSync zone but remain
/// non-authoritative. Only `compareAndAdvance` accepts the core module's
/// `SecretPolicyAdvancePrecondition`, and only its database-bound
/// `SecretSyncHeadCAS` can replace the per-scope mutable head.
public actor SecretSyncCloudKitPolicyStore: SecretSyncPolicyStore {
    private let database: any CloudKitDatabaseProtocol
    private let digester: any SecretSyncDigesting
    private let headCAS: SecretSyncHeadCAS

    public init(
        database: any CloudKitDatabaseProtocol,
        digester: any SecretSyncDigesting
    ) {
        self.database = database
        self.digester = digester
        self.headCAS = SecretSyncHeadCAS(database: database, digester: digester)
    }

    public func stagedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry? {
        let committedDigest = try await committedPolicy(
            for: scopeID,
            epoch: epoch
        )?.commit.recordDigest
        let candidates = try await transitionCommits(in: scopeID, epoch: epoch)
            .filter { $0.recordDigest != committedDigest }
        guard candidates.count <= 1 else {
            throw SecretSyncCloudKitPolicyStoreError.competingStagedPolicies
        }
        guard let candidate = candidates.first else { return nil }
        return try await reconstructPolicy(
            commitDigest: candidate.recordDigest,
            state: .staged
        )
    }

    public func committedPolicy(
        for scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> SecretPolicyStoreEntry? {
        guard var head = try await headCAS.currentHead(for: scopeID),
              head.policyEpoch >= epoch else {
            return nil
        }
        while true {
            let entry = try await reconstructPolicy(
                commitDigest: head.commitDigest,
                state: .committed
            )
            guard entry.commit.scopeID == head.scopeID,
                  entry.commit.policyEpoch == head.policyEpoch,
                  entry.commit.recordDigest == head.commitDigest,
                  entry.commit.policyDigest == head.policyDigest else {
                throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
            }
            if head.policyEpoch == 1 {
                guard epoch == 1,
                      entry.commit.predecessorCommitDigest == nil,
                      entry.records.signedPolicy.policy
                        .predecessorPolicyDigest == nil,
                      entry.records.purgeRequirements.isEmpty,
                      entry.records.purgeReceipts.isEmpty else {
                    throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
                }
                return entry
            }
            guard let predecessor = entry.commit.predecessorCommitDigest else {
                throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
            }
            let predecessorEntry = try await reconstructPolicy(
                commitDigest: predecessor,
                state: .committed
            )
            let priorRecipients = Set(
                predecessorEntry.records.signedPolicy.policy
                    .authorizedRecipientCredentialIDs
            )
            let currentRecipients = Set(
                entry.records.signedPolicy.policy
                    .authorizedRecipientCredentialIDs
            )
            let removedRecipients = priorRecipients
                .subtracting(currentRecipients)
            let purgeTargets = Set(
                entry.records.purgeRequirements.map(\.targetCredentialID)
            )
            guard predecessorEntry.commit.scopeID == head.scopeID,
                  predecessorEntry.commit.recordDigest == predecessor,
                  predecessorEntry.commit.policyEpoch
                    == head.policyEpoch - 1,
                  entry.records.signedPolicy.policy.predecessorPolicyDigest
                    == predecessorEntry.commit.policyDigest,
                  entry.commit.generationID
                    != predecessorEntry.commit.generationID,
                  purgeTargets == removedRecipients,
                  entry.records.purgeRequirements.count
                    == removedRecipients.count,
                  entry.records.purgeRequirements.allSatisfy({ requirement in
                      requirement.supersededGenerationID
                        == predecessorEntry.commit.generationID
                  })
            else {
                throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
            }
            if head.policyEpoch == epoch { return entry }
            head = try SecretPolicyStoreHead(
                scopeID: predecessorEntry.commit.scopeID,
                policyEpoch: predecessorEntry.commit.policyEpoch,
                commitDigest: predecessorEntry.commit.recordDigest,
                policyDigest: predecessorEntry.commit.policyDigest
            )
        }
    }

    public func policyHead(
        for scopeID: SecretScopeID
    ) async throws -> SecretPolicyStoreHead? {
        try await headCAS.currentHead(for: scopeID)
    }

    public func appendStagedPolicy(
        _ entry: SecretPolicyStoreEntry
    ) async throws {
        // Keep the full immutable graph enumeration together: this list is the
        // auditable WRITE-SURFACE, and splitting it across helpers risks adding
        // a model record without adding its corresponding CloudKit write.
        guard entry.records.state == .staged else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        var values: [(SecretSyncCloudKitRecordType, SecretRecordDigest, Data)] = []
        func append<T: SecretSyncCanonicalEncodable>(
            _ type: SecretSyncCloudKitRecordType,
            _ digest: SecretRecordDigest,
            _ value: T
        ) throws {
            values.append((type, digest, try value.canonicalBytes()))
        }

        try append(
            .signedPolicyEpoch,
            entry.records.signedPolicy.recordDigest,
            entry.records.signedPolicy
        )
        try append(
            .scopeSnapshot,
            entry.records.signedPolicy.policy.scopeSnapshot.snapshotDigest,
            entry.records.signedPolicy.policy.scopeSnapshot
        )
        try append(
            .sealedPayload,
            entry.records.sealedPayload.recordDigest,
            entry.records.sealedPayload
        )
        for value in entry.records.recipientEnvelopes {
            try append(.recipientEnvelope, value.recordDigest, value)
        }
        if let value = entry.records.recoveryEnvelope {
            try append(.recoveryEnvelope, value.recordDigest, value)
        }
        if let value = entry.records.recoveryAuthorization {
            try append(
                .fullLossRecoveryAuthorization,
                value.recordDigest,
                value
            )
        }
        for value in entry.records.purgeRequirements {
            try append(.purgeRequirement, value.recordDigest, value)
        }
        for value in entry.records.purgeReceipts {
            try append(.purgeReceipt, value.recordDigest, value)
        }
        for value in entry.trustRecords {
            try append(.deviceTrustRecord, value.recordDigest, value)
        }
        for value in entry.credentials {
            let proofBytes = try value.enrollmentProof.canonicalBytes()
            let proofDigest = try digester.digest(canonicalBytes: proofBytes)
            values.append((.deviceEnrollmentProof, proofDigest, proofBytes))
            try append(
                .deviceCredential,
                digester.digest(canonicalBytes: value.canonicalBytes()),
                value
            )
        }
        // The commit is staged last so a partially written graph cannot leave
        // a discoverable commit that references absent authority records.
        try append(.transitionCommit, entry.commit.recordDigest, entry.commit)

        for (type, digest, canonicalBytes) in values {
            let value: SecretSyncCloudKitImmutableRecord
            do {
                value = try SecretSyncCloudKitImmutableRecord(
                    type: type,
                    digest: digest,
                    canonicalBytes: canonicalBytes,
                    digester: digester
                )
            } catch {
                throw SecretSyncCloudKitPolicyStoreError.invalidCanonicalRecord
            }
            let record = try CKRecordMapping.secretSyncRecord(value)
            try await saveImmutable(record)
        }
    }

    public func compareAndAdvance(
        _ precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretPolicyAdvanceResult {
        // The unforgeable core precondition proves validation, while this
        // reconstruction proves that the exact candidate graph reached
        // CloudKit before its mutable head can reference it.
        let staged = try await reconstructPolicy(
            commitDigest: precondition.candidateHead.commitDigest,
            state: .staged
        )
        guard staged == precondition.candidateEntry else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        switch try await headCAS.attempt(precondition) {
        case .advanced(let head):
            return .advanced(head)
        case .stale(let current):
            return try await resolveStale(
                current: current,
                precondition: precondition
            )
        }
    }

    /// Reconstruct one exact staged entry from a transition-commit digest.
    public func reconstructPolicy(
        commitDigest: SecretRecordDigest
    ) async throws -> SecretPolicyStoreEntry {
        try await reconstructPolicy(commitDigest: commitDigest, state: .staged)
    }

    private func resolveStale(
        current: SecretPolicyStoreHead?,
        precondition: SecretPolicyAdvancePrecondition
    ) async throws -> SecretPolicyAdvanceResult {
        guard let current else {
            throw SecretSyncCloudKitPolicyStoreError.headRollbackDetected
        }
        if current == precondition.candidateHead {
            return .advanced(current)
        }
        guard current == precondition.expectedHead else {
            return .forkDetected(
                currentHead: current,
                competingCommitDigest: precondition.candidateHead.commitDigest
            )
        }

        // Reconstruct the exact immutable graph referenced by the refetched
        // logical head before retrying. This is structural revalidation only;
        // it deliberately makes no claim to rerun SecretPolicyValidator without
        // its credential, signature, competing-child, and freshness inputs.
        let reconstructed = try await reconstructPolicy(
            commitDigest: current.commitDigest,
            state: .committed
        )
        guard reconstructed.commit.scopeID == current.scopeID,
              reconstructed.commit.policyEpoch == current.policyEpoch,
              reconstructed.commit.policyDigest == current.policyDigest else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        let retry = try SecretPolicyAdvancePrecondition(
            expectedHead: current,
            candidateEntry: precondition.candidateEntry,
            validatedSnapshot: precondition.validatedSnapshot
        )
        switch try await headCAS.attempt(retry) {
        case .advanced(let head):
            return .advanced(head)
        case .stale(let latest):
            guard let latest else {
                throw SecretSyncCloudKitPolicyStoreError.headRollbackDetected
            }
            if latest == retry.candidateHead { return .advanced(latest) }
            return .forkDetected(
                currentHead: latest,
                competingCommitDigest: retry.candidateHead.commitDigest
            )
        }
    }

    private func saveImmutable(_ record: CKRecord) async throws {
        let result: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        )
        do {
            result = try await database.modifySecretSyncRecords(
                saving: [record],
                digester: digester
            )
        } catch {
            throw SecretSyncCloudKitPolicyStoreError.immutableWriteFailed
        }
        guard let item = result.saveResults[record.recordID] else {
            throw SecretSyncCloudKitPolicyStoreError.immutableWriteFailed
        }
        switch item {
        case .success:
            return
        case .failure(let error):
            guard let cloudError = error as? CKError,
                  cloudError.code == .serverRecordChanged else {
                throw SecretSyncCloudKitPolicyStoreError.immutableWriteFailed
            }
            let existing = try await fetchExact([record.recordID])
            guard let value = existing[record.recordID] else {
                throw SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
            }
            do {
                try CKRecordMapping.validateSecretSyncImmutableIdempotency(
                    existing: value,
                    retry: record,
                    digester: digester
                )
            } catch {
                throw SecretSyncCloudKitPolicyStoreError.immutableWriteFailed
            }
        }
    }

    private func transitionCommits(
        in scopeID: SecretScopeID,
        epoch: UInt64
    ) async throws -> [SecretTransitionCommit] {
        let changes: CloudKitZoneChanges
        do {
            changes = try await database.fetchZoneChanges(
                inZoneWith: SecretSyncCloudKitZones.controlZoneID,
                since: nil
            )
        } catch {
            throw SecretSyncCloudKitPolicyStoreError.transportFailure
        }
        var commits: [SecretTransitionCommit] = []
        for record in changes.modifiedRecords
            where record.recordType == SecretSyncCloudKitRecordType.transitionCommit.rawValue
        {
            let immutable = try decode(record, as: .transitionCommit)
            let commit = try parseTransitionCommit(immutable)
            if commit.scopeID == scopeID, commit.policyEpoch == epoch {
                commits.append(commit)
            }
        }
        let unique = Set(commits.map(\.recordDigest))
        guard unique.count == commits.count else {
            throw SecretSyncCloudKitPolicyStoreError.competingStagedPolicies
        }
        return commits
    }

    // Reconstruction deliberately remains one sequential method: every fetch
    // depends on a digest parsed from the preceding record, and preserving that
    // order makes the authority boundary auditable and prevents partial graphs
    // from being accidentally promoted by independent helper tasks.
    private func reconstructPolicy(
        commitDigest: SecretRecordDigest,
        state: SecretTransitionState
    ) async throws -> SecretPolicyStoreEntry {
        let commitRecord = try await fetchImmutable(
            digest: commitDigest,
            type: .transitionCommit
        )
        let commit = try parseTransitionCommit(commitRecord)

        let policyRecord = try await fetchImmutable(
            digest: commit.policyDigest,
            type: .signedPolicyEpoch
        )
        let signedPolicy = try parseSignedPolicy(policyRecord)
        guard signedPolicy.recordDigest == commit.policyDigest else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }

        let scopeRecord = try await fetchImmutable(
            digest: commit.scopeSnapshotDigest,
            type: .scopeSnapshot
        )
        let scope = try parseScopeSnapshot(scopeRecord)
        guard scope == signedPolicy.policy.scopeSnapshot,
              try scope.canonicalBytes()
                == signedPolicy.policy.scopeSnapshot.canonicalBytes() else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }

        let payload = try parseSealedPayload(
            await fetchImmutable(
                digest: commit.sealedPayloadDigest,
                type: .sealedPayload
            )
        )
        var recipients: [RecipientKeyEnvelope] = []
        recipients.reserveCapacity(commit.recipientEnvelopeDigests.count)
        for digest in commit.recipientEnvelopeDigests {
            let record = try await fetchImmutable(
                digest: digest,
                type: .recipientEnvelope
            )
            recipients.append(try parseRecipientEnvelope(record))
        }
        let recovery: RecoveryEnvelope?
        if let digest = commit.recoveryEnvelopeDigest {
            let record = try await fetchImmutable(
                digest: digest,
                type: .recoveryEnvelope
            )
            recovery = try parseRecoveryEnvelope(record)
        } else {
            recovery = nil
        }
        var purgeRequirements: [PurgeRequirement] = []
        purgeRequirements.reserveCapacity(commit.purgeRequirementDigests.count)
        for digest in commit.purgeRequirementDigests {
            let record = try await fetchImmutable(
                digest: digest,
                type: .purgeRequirement
            )
            purgeRequirements.append(try parsePurgeRequirement(record))
        }
        var purgeReceipts: [SignedPurgeReceipt] = []
        purgeReceipts.reserveCapacity(commit.purgeReceiptDigests.count)
        for digest in commit.purgeReceiptDigests {
            let record = try await fetchImmutable(
                digest: digest,
                type: .purgeReceipt
            )
            purgeReceipts.append(try parsePurgeReceipt(record))
        }
        let recoveryAuthorization: FullLossRecoveryAuthorization?
        if let digest = commit.recoveryAuthorizationDigest {
            let record = try await fetchImmutable(
                digest: digest,
                type: .fullLossRecoveryAuthorization
            )
            recoveryAuthorization = try FullLossRecoveryAuthorization(
                recordDigest: digest,
                canonicalBytes: record.canonicalBytes
            )
        } else {
            recoveryAuthorization = nil
        }
        var trustRecords: [DeviceTrustRecord] = []
        trustRecords.reserveCapacity(
            signedPolicy.policy.trustedDeviceRecordDigests.count
        )
        for digest in signedPolicy.policy.trustedDeviceRecordDigests {
            let record = try await fetchImmutable(
                digest: digest,
                type: .deviceTrustRecord
            )
            trustRecords.append(try parseTrustRecord(record))
        }
        var credentials: [TrustedDeviceCredential] = []
        credentials.reserveCapacity(trustRecords.count)
        for trustRecord in trustRecords {
            let credentialRecord = try await fetchImmutable(
                digest: trustRecord.credentialDigest,
                type: .deviceCredential
            )
            let credential = try parseCredential(credentialRecord)
            let proofBytes = try credential.enrollmentProof.canonicalBytes()
            let proofDigest = try digester.digest(canonicalBytes: proofBytes)
            let proofRecord = try await fetchImmutable(
                digest: proofDigest,
                type: .deviceEnrollmentProof
            )
            guard proofRecord.canonicalBytes == proofBytes else {
                throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
            }
            credentials.append(credential)
        }

        try validateStructuralBindings(
            commit: commit,
            signedPolicy: signedPolicy,
            payload: payload,
            recipients: recipients,
            recovery: recovery,
            purgeRequirements: purgeRequirements,
            purgeReceipts: purgeReceipts,
            recoveryAuthorization: recoveryAuthorization,
            credentials: credentials,
            trustRecords: trustRecords
        )

        do {
            let records = try SecretControlRecords(
                state: state,
                signedPolicy: signedPolicy,
                sealedPayload: payload,
                recipientEnvelopes: recipients,
                recoveryEnvelope: recovery,
                purgeRequirements: purgeRequirements,
                purgeReceipts: purgeReceipts,
                recoveryAuthorization: recoveryAuthorization
            )
            return try SecretPolicyStoreEntry(
                commit: commit,
                records: records,
                credentials: credentials,
                trustRecords: trustRecords,
                digester: digester
            )
        } catch {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
    }

    private func validateStructuralBindings(
        commit: SecretTransitionCommit,
        signedPolicy: SignedSecretPolicyEpoch,
        payload: SealedPayload,
        recipients: [RecipientKeyEnvelope],
        recovery: RecoveryEnvelope?,
        purgeRequirements: [PurgeRequirement],
        purgeReceipts: [SignedPurgeReceipt],
        recoveryAuthorization: FullLossRecoveryAuthorization?,
        credentials: [TrustedDeviceCredential],
        trustRecords: [DeviceTrustRecord]
    ) throws {
        let policy = signedPolicy.policy
        guard commit.recoveryAuthorizationDigest
                == recoveryAuthorization?.recordDigest,
              commit.signerCredentialID == policy.signerCredentialID,
              payload.scopeID == commit.scopeID,
              payload.scopeSnapshotDigest == commit.scopeSnapshotDigest,
              payload.policyEpoch == commit.policyEpoch,
              payload.policyDigest == commit.policyDigest,
              payload.generationID == commit.generationID else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        let recipientIDs = recipients.map(\.recipientCredentialID).sorted {
            $0.rawValue.uuidString.lowercased()
                < $1.rawValue.uuidString.lowercased()
        }
        guard recipientIDs == policy.authorizedRecipientCredentialIDs,
              recipients.allSatisfy({ envelope in
                  envelope.scopeID == commit.scopeID
                    && envelope.scopeSnapshotDigest
                        == commit.scopeSnapshotDigest
                    && envelope.policyEpoch == commit.policyEpoch
                    && envelope.policyDigest == commit.policyDigest
                    && envelope.generationID == commit.generationID
              }) else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        switch (policy.recoveryRecipient, recovery) {
        case (nil, nil):
            break
        case let (.some(descriptor), .some(envelope)):
            guard descriptor.recoveryRecipientID
                    == envelope.recoveryRecipientID,
                  envelope.scopeID == commit.scopeID,
                  envelope.scopeSnapshotDigest == commit.scopeSnapshotDigest,
                  envelope.policyEpoch == commit.policyEpoch,
                  envelope.policyDigest == commit.policyDigest,
                  envelope.generationID == commit.generationID else {
                throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
            }
        default:
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        let fullLossRecovery = recoveryAuthorization != nil
        guard (fullLossRecovery ? purgeReceipts.isEmpty
                : purgeRequirements.count == purgeReceipts.count),
              purgeRequirements.allSatisfy({ requirement in
                  requirement.scopeID == commit.scopeID
                    && requirement.policyEpoch == commit.policyEpoch
                    && requirement.policyDigest == commit.policyDigest
                    && requirement.replacementGenerationID
                        == commit.generationID
              }) else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        let requirements = Dictionary(
            uniqueKeysWithValues: purgeRequirements.map {
                ($0.recordDigest, $0)
            }
        )
        guard purgeReceipts.allSatisfy({ receipt in
            guard let requirement = requirements[receipt.requirementDigest]
            else { return false }
            return receipt.status == .completed
                && receipt.coveredCategories == requirement.requiredCategories
                && receipt.scopeID == requirement.scopeID
                && receipt.policyEpoch == requirement.policyEpoch
                && receipt.policyDigest == requirement.policyDigest
                && receipt.supersededGenerationID
                    == requirement.supersededGenerationID
                && receipt.replacementGenerationID
                    == requirement.replacementGenerationID
                && receipt.respondingCredentialID
                    == requirement.targetCredentialID
                && receipt.signerCredentialID
                    == receipt.respondingCredentialID
        }) else {
            throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
        }
        if let recoveryAuthorization {
            let intent = recoveryAuthorization.intent
            let semantics = intent.candidateSemantics
            let credentialDigests = try credentials.map {
                try digester.digest(canonicalBytes: $0.canonicalBytes())
            }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            let trustDigests = trustRecords.map(\.recordDigest).sorted {
                $0.bytes.lexicographicallyPrecedes($1.bytes)
            }
            guard
                intent.scopeID == commit.scopeID,
                intent.candidatePolicyEpoch == commit.policyEpoch,
                intent.candidateGenerationID == commit.generationID,
                intent.candidateSignedPolicyDigest == commit.policyDigest,
                intent.recoveryEnvelopeDigest == commit.recoveryEnvelopeDigest,
                intent.replacementCredentialID == commit.signerCredentialID,
                intent.replacementCredentialID == policy.signerCredentialID,
                intent.replacementRecoveryRecipient == policy.recoveryRecipient,
                semantics.scopeSnapshotDigest == commit.scopeSnapshotDigest,
                semantics.signedPolicyDigest == signedPolicy.recordDigest,
                semantics.sealedPayloadDigest == payload.recordDigest,
                semantics.recipientEnvelopeDigests
                    == recipients.map(\.recordDigest),
                semantics.recoveryEnvelopeDigest == recovery?.recordDigest,
                semantics.purgeRequirementDigests
                    == purgeRequirements.map(\.recordDigest),
                semantics.purgeReceiptDigests.isEmpty,
                semantics.credentialDigests == credentialDigests,
                semantics.trustRecordDigests == trustDigests
            else {
                throw SecretSyncCloudKitPolicyStoreError.referenceMismatch
            }
        }
    }

    private func fetchImmutable(
        digest: SecretRecordDigest,
        type: SecretSyncCloudKitRecordType
    ) async throws -> SecretSyncCloudKitImmutableRecord {
        let id = Self.recordID(digest: digest, type: type)
        let fetched = try await fetchExact([id])
        guard let record = fetched[id] else {
            throw SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
        }
        return try decode(record, as: type)
    }

    private func fetchExact(
        _ ids: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: CKRecord] {
        guard Set(ids).count == ids.count else {
            throw SecretSyncCloudKitPolicyStoreError.incompleteFetchResults
        }
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.fetch(withRecordIDs: ids)
        } catch {
            throw SecretSyncCloudKitPolicyStoreError.transportFailure
        }
        guard Set(results.keys) == Set(ids) else {
            throw SecretSyncCloudKitPolicyStoreError.incompleteFetchResults
        }
        var records: [CKRecord.ID: CKRecord] = [:]
        for id in ids {
            guard let result = results[id] else {
                throw SecretSyncCloudKitPolicyStoreError.incompleteFetchResults
            }
            switch result {
            case .success(let record):
                records[id] = record
            case .failure:
                throw SecretSyncCloudKitPolicyStoreError.incompleteRecordSet
            }
        }
        return records
    }

    private func decode(
        _ record: CKRecord,
        as expected: SecretSyncCloudKitRecordType
    ) throws -> SecretSyncCloudKitImmutableRecord {
        do {
            let value = try CKRecordMapping.decodeSecretSyncImmutableRecord(
                record,
                digester: digester
            )
            guard value.type == expected else {
                throw SecretSyncCloudKitPolicyStoreError.invalidCanonicalRecord
            }
            return value
        } catch let error as SecretSyncCloudKitPolicyStoreError {
            throw error
        } catch {
            throw SecretSyncCloudKitPolicyStoreError.invalidCanonicalRecord
        }
    }

    private static func recordID(
        digest: SecretRecordDigest,
        type: SecretSyncCloudKitRecordType
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: digest.bytes.secretSyncLowercaseHex,
            zoneID: SecretSyncCloudKitZones.zoneID(for: type)
        )
    }
}

// MARK: - Canonical reconstruction

private extension SecretSyncCloudKitPolicyStore {
    func parseTransitionCommit(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> SecretTransitionCommit {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .secretTransitionCommit,
            required: [1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 14],
            optional: [3, 9, 13]
        )
        let parsed = try SecretTransitionCommit(
            recordDigest: value.digest,
            scopeID: SecretScopeID(fields.uuid(1)),
            policyEpoch: fields.uint64(2),
            predecessorCommitDigest: fields.optionalDigest(3),
            policyDigest: fields.digest(4),
            scopeSnapshotDigest: fields.digest(5),
            generationID: SecretGenerationID(fields.uuid(6)),
            sealedPayloadDigest: fields.digest(7),
            recipientEnvelopeDigests: fields.digestSequence(8),
            recoveryEnvelopeDigest: fields.optionalDigest(9),
            purgeRequirementDigests: fields.digestSequence(10),
            purgeReceiptDigests: fields.digestSequence(11),
            recoveryAuthorizationDigest: fields.optionalDigest(13),
            signerCredentialID: DeviceCredentialID(fields.uuid(12)),
            signature: fields.data(14)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parseSignedPolicy(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> SignedSecretPolicyEpoch {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .signedSecretPolicyEpoch,
            required: [1, 2]
        )
        let parsed = try SignedSecretPolicyEpoch(
            recordDigest: value.digest,
            policy: parsePolicy(fields.data(1)),
            signature: fields.data(2)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parsePolicy(_ bytes: Data) throws -> SecretPolicyEpoch {
        let fields = try U5CanonicalFields(
            bytes,
            domain: .secretPolicyEpoch,
            required: [1, 2, 4, 5, 6, 7, 8, 10],
            optional: [3, 9]
        )
        let snapshotBytes = try fields.data(4)
        let snapshot = try parseScopeSnapshot(
            bytes: snapshotBytes,
            digest: fields.digest(5)
        )
        let recovery: RecoveryRecipientDescriptor?
        if let bytes = fields.optionalData(9) {
            let values = try U5CanonicalFields.sequence(bytes)
            guard values.count == 7 else { throw U5CanonicalError.invalid }
            recovery = try RecoveryRecipientDescriptor(
                recoveryRecipientID: try U5CanonicalFields.uuid(values[0]),
                keyAgreementPublicKey: try KeyAgreementPublicKeyDescriptor(
                    algorithmIdentifier: try U5CanonicalFields.string(values[1]),
                    keyIdentifier: values[2],
                    publicKeyBytes: values[3]
                ),
                authorizationSigningPublicKey: try SigningPublicKeyDescriptor(
                    algorithmIdentifier: try U5CanonicalFields.string(values[4]),
                    keyIdentifier: values[5],
                    publicKeyBytes: values[6]
                )
            )
        } else {
            recovery = nil
        }
        let parsed = try SecretPolicyEpoch(
            schemaVersion: fields.uint16(1),
            epoch: fields.uint64(2),
            predecessorPolicyDigest: fields.optionalDigest(3),
            scopeSnapshot: snapshot,
            generationID: SecretGenerationID(fields.uuid(6)),
            authorizedRecipientCredentialIDs: try fields.uuidSequence(7)
                .map { DeviceCredentialID($0) },
            trustedDeviceRecordDigests: fields.digestSequence(8),
            recoveryRecipient: recovery,
            signerCredentialID: DeviceCredentialID(fields.uuid(10))
        )
        try requireRoundTrip(parsed, equals: bytes)
        return parsed
    }

    func parseScopeSnapshot(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> SecretScopeSnapshot {
        try parseScopeSnapshot(
            bytes: value.canonicalBytes,
            digest: value.digest
        )
    }

    func parseScopeSnapshot(
        bytes: Data,
        digest: SecretRecordDigest
    ) throws -> SecretScopeSnapshot {
        let fields = try U5CanonicalFields(
            bytes,
            domain: .secretScopeSnapshot,
            required: [1, 2, 3]
        )
        let parsed = try SecretScopeSnapshot(
            scopeID: SecretScopeID(fields.uuid(1)),
            rootRecordID: fields.uuid(2),
            memberRecordIDs: fields.uuidSequence(3),
            snapshotDigest: digest
        )
        try requireRoundTrip(parsed, equals: bytes)
        return parsed
    }

    func parseSealedPayload(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> SealedPayload {
        let fields = try U5CanonicalFields.bound(value, domain: .sealedPayload)
        let parsed = try SealedPayload(
            recordDigest: value.digest,
            scopeID: SecretScopeID(fields.uuid(1)),
            scopeSnapshotDigest: fields.digest(2),
            policyEpoch: fields.uint64(3),
            policyDigest: fields.digest(4),
            generationID: SecretGenerationID(fields.uuid(5)),
            formatVersion: fields.uint16(6),
            ciphertextBytes: fields.data(7)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parseRecipientEnvelope(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> RecipientKeyEnvelope {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .recipientKeyEnvelope,
            required: Array(1...8).map(UInt16.init)
        )
        let parsed = try RecipientKeyEnvelope(
            recordDigest: value.digest,
            scopeID: SecretScopeID(fields.uuid(1)),
            scopeSnapshotDigest: fields.digest(2),
            policyEpoch: fields.uint64(3),
            policyDigest: fields.digest(4),
            generationID: SecretGenerationID(fields.uuid(5)),
            recipientCredentialID: DeviceCredentialID(fields.uuid(7)),
            formatVersion: fields.uint16(6),
            wrappedKeyBytes: fields.data(8)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parseRecoveryEnvelope(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> RecoveryEnvelope {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .recoveryEnvelope,
            required: Array(1...9).map(UInt16.init)
        )
        guard try fields.string(8) == RecoveryEnvelopeUsage.breakGlassRecoveryOnly.rawValue else {
            throw U5CanonicalError.invalid
        }
        let parsed = try RecoveryEnvelope(
            recordDigest: value.digest,
            scopeID: SecretScopeID(fields.uuid(1)),
            scopeSnapshotDigest: fields.digest(2),
            policyEpoch: fields.uint64(3),
            policyDigest: fields.digest(4),
            generationID: SecretGenerationID(fields.uuid(5)),
            recoveryRecipientID: fields.uuid(7),
            formatVersion: fields.uint16(6),
            wrappedKeyBytes: fields.data(9)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parsePurgeRequirement(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> PurgeRequirement {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .purgeRequirement,
            required: Array(1...7).map(UInt16.init)
        )
        let parsed = try PurgeRequirement(
            recordDigest: value.digest,
            scopeID: SecretScopeID(fields.uuid(1)),
            policyEpoch: fields.uint64(2),
            policyDigest: fields.digest(3),
            supersededGenerationID: SecretGenerationID(fields.uuid(4)),
            replacementGenerationID: SecretGenerationID(fields.uuid(5)),
            targetCredentialID: DeviceCredentialID(fields.uuid(6)),
            requiredCategories: try fields.stringSequence(7).map {
                guard let value = PurgeArtifactCategory(rawValue: $0) else {
                    throw U5CanonicalError.invalid
                }
                return value
            }
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parsePurgeReceipt(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> SignedPurgeReceipt {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .purgeReceipt,
            required: Array(1...11).map(UInt16.init)
        )
        guard let status = PurgeReceiptStatus(rawValue: try fields.string(9)) else {
            throw U5CanonicalError.invalid
        }
        let parsed = try SignedPurgeReceipt(
            recordDigest: value.digest,
            requirementDigest: fields.digest(1),
            scopeID: SecretScopeID(fields.uuid(2)),
            policyEpoch: fields.uint64(3),
            policyDigest: fields.digest(4),
            supersededGenerationID: SecretGenerationID(fields.uuid(5)),
            replacementGenerationID: SecretGenerationID(fields.uuid(6)),
            respondingCredentialID: DeviceCredentialID(fields.uuid(7)),
            coveredCategories: try fields.stringSequence(8).map {
                guard let value = PurgeArtifactCategory(rawValue: $0) else {
                    throw U5CanonicalError.invalid
                }
                return value
            },
            status: status,
            signerCredentialID: DeviceCredentialID(fields.uuid(10)),
            signature: fields.data(11)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parseTrustRecord(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> DeviceTrustRecord {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .deviceTrustRecord,
            required: Array(1...5).map(UInt16.init)
        )
        guard let state = DeviceTrustState(rawValue: try fields.string(4)) else {
            throw U5CanonicalError.invalid
        }
        let parsed = try DeviceTrustRecord(
            recordDigest: value.digest,
            credentialDigest: fields.digest(1),
            deviceID: TrustedDeviceID(fields.uuid(2)),
            credentialID: DeviceCredentialID(fields.uuid(3)),
            trustState: state,
            effectivePolicyEpoch: fields.uint64(5)
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func parseCredential(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> TrustedDeviceCredential {
        let fields = try U5CanonicalFields(
            value.canonicalBytes,
            domain: .trustedDeviceCredential,
            required: Array(1...11).map(UInt16.init),
            optional: [12]
        )
        let proofBytes = try fields.data(11)
        let proofDocument = try SecretSyncCanonicalEncoding.decode(
            proofBytes,
            expectedDomain: .deviceEnrollmentProof
        )
        let proofTags = Set(proofDocument.fields.map(\.tag))
        let proofFields: U5CanonicalFields
        let provenance: DeviceCredentialEnrollmentProvenance
        if proofTags == Set([1, 2, 3, 4, 5]) {
            proofFields = try U5CanonicalFields(
                proofBytes,
                domain: .deviceEnrollmentProof,
                required: [1, 2, 3, 4, 5]
            )
            provenance = .trustedDevice(
                try TrustedDeviceEnrollmentAuthority(
                    credentialID: DeviceCredentialID(proofFields.uuid(5)),
                    signature: fields.data(12)
                )
            )
        } else if proofTags == Set([1, 2, 3, 4, 6, 7]) {
            guard fields.optionalData(12) == nil else {
                throw U5CanonicalError.invalid
            }
            proofFields = try U5CanonicalFields(
                proofBytes,
                domain: .deviceEnrollmentProof,
                required: [1, 2, 3, 4, 6, 7]
            )
            provenance = .globalRecovery(
                GlobalRecoveryEnrollmentAuthority(
                    requestID: try proofFields.uuid(6),
                    recoveryRecipientID: try proofFields.uuid(7)
                )
            )
        } else {
            throw U5CanonicalError.invalid
        }
        guard let status = TrustedDeviceCredentialStatus(
            rawValue: try fields.string(4)
        ) else {
            throw U5CanonicalError.invalid
        }
        let parsed = try TrustedDeviceCredential(
            deviceID: TrustedDeviceID(fields.uuid(1)),
            credentialID: DeviceCredentialID(fields.uuid(2)),
            credentialVersion: fields.uint16(3),
            status: status,
            signingPublicKey: SigningPublicKeyDescriptor(
                algorithmIdentifier: fields.string(5),
                keyIdentifier: fields.data(6),
                publicKeyBytes: fields.data(7)
            ),
            keyAgreementPublicKey: KeyAgreementPublicKeyDescriptor(
                algorithmIdentifier: fields.string(8),
                keyIdentifier: fields.data(9),
                publicKeyBytes: fields.data(10)
            ),
            enrollmentProof: DeviceCredentialEnrollmentProof(
                challengeID: proofFields.uuid(1),
                challengeBytes: proofFields.data(2),
                signingProofBytes: proofFields.data(3),
                keyAgreementProofBytes: proofFields.data(4),
                provenance: provenance
            )
        )
        try requireRoundTrip(parsed, equals: value.canonicalBytes)
        return parsed
    }

    func requireRoundTrip<T: SecretSyncCanonicalEncodable>(
        _ value: T,
        equals bytes: Data
    ) throws {
        guard try value.canonicalBytes() == bytes else {
            throw SecretSyncCloudKitPolicyStoreError.invalidCanonicalRecord
        }
    }
}

private enum U5CanonicalError: Error { case invalid }

private struct U5CanonicalFields {
    private let fields: [UInt16: Data]

    init(
        _ bytes: Data,
        domain: SecretSyncCanonicalDomain,
        required: [UInt16],
        optional: Set<UInt16> = []
    ) throws {
        let document = try SecretSyncCanonicalEncoding.decode(
            bytes,
            expectedDomain: domain
        )
        let dictionary = Dictionary(
            uniqueKeysWithValues: document.fields.map { ($0.tag, $0.value) }
        )
        let requiredSet = Set(required)
        guard requiredSet.isSubset(of: dictionary.keys),
              Set(dictionary.keys).isSubset(of: requiredSet.union(optional)) else {
            throw U5CanonicalError.invalid
        }
        self.fields = dictionary
    }

    static func bound(
        _ value: SecretSyncCloudKitImmutableRecord,
        domain: SecretSyncCanonicalDomain
    ) throws -> U5CanonicalFields {
        try U5CanonicalFields(
            value.canonicalBytes,
            domain: domain,
            required: Array(1...7).map(UInt16.init)
        )
    }

    func data(_ tag: UInt16) throws -> Data {
        guard let value = fields[tag] else { throw U5CanonicalError.invalid }
        return value
    }

    func optionalData(_ tag: UInt16) -> Data? { fields[tag] }

    func uuid(_ tag: UInt16) throws -> UUID { try Self.uuid(data(tag)) }

    static func uuid(_ value: Data) throws -> UUID {
        guard value.count == 36,
              let text = String(data: value, encoding: .utf8),
              text == text.lowercased(),
              let uuid = UUID(uuidString: text) else {
            throw U5CanonicalError.invalid
        }
        return uuid
    }

    func uint16(_ tag: UInt16) throws -> UInt16 {
        let value = try data(tag)
        guard value.count == 2 else { throw U5CanonicalError.invalid }
        return value.reduce(UInt16.zero) { ($0 << 8) | UInt16($1) }
    }

    func uint64(_ tag: UInt16) throws -> UInt64 {
        let value = try data(tag)
        guard value.count == 8 else { throw U5CanonicalError.invalid }
        return value.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
    }

    func digest(_ tag: UInt16) throws -> SecretRecordDigest {
        try SecretRecordDigest(bytes: data(tag))
    }

    func optionalDigest(_ tag: UInt16) throws -> SecretRecordDigest? {
        try fields[tag].map(SecretRecordDigest.init(bytes:))
    }

    func string(_ tag: UInt16) throws -> String { try Self.string(data(tag)) }

    static func string(_ value: Data) throws -> String {
        guard let text = String(data: value, encoding: .utf8), !text.isEmpty else {
            throw U5CanonicalError.invalid
        }
        return text
    }

    func digestSequence(_ tag: UInt16) throws -> [SecretRecordDigest] {
        try Self.sequence(data(tag)).map(SecretRecordDigest.init(bytes:))
    }

    func uuidSequence(_ tag: UInt16) throws -> [UUID] {
        try Self.sequence(data(tag)).map(Self.uuid)
    }

    func stringSequence(_ tag: UInt16) throws -> [String] {
        try Self.sequence(data(tag)).map(Self.string)
    }

    static func sequence(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw U5CanonicalError.invalid }
        let count = Int(bytes[0]) << 8 | Int(bytes[1])
        var cursor = 2
        var result: [Data] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 4 <= bytes.count else { throw U5CanonicalError.invalid }
            let length = Int(bytes[cursor]) << 24
                | Int(bytes[cursor + 1]) << 16
                | Int(bytes[cursor + 2]) << 8
                | Int(bytes[cursor + 3])
            cursor += 4
            guard cursor + length <= bytes.count else { throw U5CanonicalError.invalid }
            result.append(Data(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        guard cursor == bytes.count else { throw U5CanonicalError.invalid }
        return result
    }
}
