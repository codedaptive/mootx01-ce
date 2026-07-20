// PushResults.swift
//
// Processes the per-record result dictionaries from a
// modifyRecords(atomically: false) call and classifies each result via
// CKErrorTaxonomy into one of four outcome buckets (CVK-ICLOUD P1-M6 R6).
//
// DESIGN — pure function:
// process(saveResults:recordToEntryID:classifyError:) takes data, performs no
// CloudKit operations, and returns a PushOutcome value. This makes the function
// unit-testable with synthetic result dictionaries without needing a live
// CloudKit container. PushCycle.swift owns the effectful outer loop that
// applies the outcome to the outbox.
//
// CONFLICT RESOLUTION:
// serverRecordChanged entries are classified .retryIDs. The pull cycle applies
// the winning server record under LWW semantics; the outbox entry either becomes
// stale (server wins, no re-push needed) or remains live for the next push
// (local wins). No in-push re-fetch is performed here — that would couple
// PushResults to the CloudKit database, destroying the pure-function property.
//
// RECLAIM:
// When any per-record error is classified .reclaim, the first such ReclaimKind
// is surfaced in the PushOutcome.reclaimNeeded field. The caller (PushCycle)
// must execute the reclaim before the next push attempt. The entry itself is
// added to retryIDs (not parkedIDs) because the reclaim will resolve the
// underlying precondition.

import Foundation
import CloudKit

// MARK: - PushOutcome

/// The classified outcome of one modifyRecords call.
public struct PushOutcome: Sendable {
    /// Entry IDs whose records were accepted by CloudKit. PushCycle calls
    /// OutboxStore.confirm(ids:from:) to remove these from the outbox.
    public let confirmedIDs: [UUID]

    /// Entry IDs whose records failed with a retryable, conflict, or reclaim
    /// error. PushCycle calls OutboxStore.incrementRetryCount(id:from:) for
    /// each. The entries stay in the outbox for the next push cycle.
    public let retryIDs: [UUID]

    /// Entry IDs whose records failed permanently (quota or size exceeded).
    /// PushCycle calls OutboxStore.park(id:from:) for each. The entries stay
    /// in the outbox for diagnostics but are excluded from future push batches.
    public let parkedIDs: [UUID]

    /// If any per-record error requires a reclaim action (zone re-creation or
    /// token reset), this is set to the first such ReclaimKind encountered.
    /// The caller must execute the reclaim before the next push attempt.
    /// Nil when all failures were retryable, conflict, or permanent.
    public let reclaimNeeded: ReclaimKind?

    /// Number of records accepted on this call. Equal to confirmedIDs.count.
    /// Used to populate the `pushed` field in SyncReceipt so the receipt
    /// counts only truly-accepted records (B-2).
    public var pushedCount: Int { confirmedIDs.count }
}

// MARK: - PushResults

/// Stateless namespace for per-record result processing.
public enum PushResults {

    /// Classify the per-record save results from a modifyRecords call.
    ///
    /// - Parameters:
    ///   - saveResults: The `saveResults` dictionary from the modifyRecords tuple.
    ///     Maps `CKRecord.ID → Result<CKRecord, Error>`. Produced by
    ///     `CKDatabase.modifyRecords(saving:deleting:savePolicy:atomically:)` with
    ///     `atomically: false`.
    ///   - recordToEntryID: A mapping from the `CKRecord.ID` used for each saved
    ///     record to the corresponding outbox entry `UUID`. Built in PushCycle
    ///     alongside the encoded `CKRecord` array. Records absent from this map
    ///     (e.g. CloudKit-internal diagnostic records) are silently skipped.
    ///   - classifyError: Classifies an Error into a CKErrorClass. Defaults to
    ///     `CKErrorClass.classify(_:)`; supply a scripted closure in tests to
    ///     inject specific CKError codes without constructing real CKError objects.
    public static func process(
        saveResults: [CKRecord.ID: Result<CKRecord, Error>],
        recordToEntryID: [CKRecord.ID: UUID],
        classifyError: (Error) -> CKErrorClass = CKErrorClass.classify(_:)
    ) -> PushOutcome {
        var confirmedIDs: [UUID] = []
        var retryIDs: [UUID] = []
        var parkedIDs: [UUID] = []
        var reclaimNeeded: ReclaimKind? = nil

        for (recordID, result) in saveResults {
            guard let entryID = recordToEntryID[recordID] else {
                // No outbox entry for this CKRecord.ID — CloudKit may include
                // internal or metadata records we didn't push. Skip safely.
                continue
            }

            switch result {
            case .success:
                // CloudKit accepted the record. Confirm (remove from outbox).
                confirmedIDs.append(entryID)

            case .failure(let error):
                switch classifyError(error) {
                case .retryableBackoff:
                    // Transient: leave in outbox, increment retry_count.
                    retryIDs.append(entryID)

                case .reclaim(let kind):
                    // Zone or token invalid: entry is still valid but needs
                    // reclaim before re-push. Surface the reclaim kind to caller.
                    // Keep first reclaim kind encountered; all are equivalent for
                    // the current zone.
                    if reclaimNeeded == nil { reclaimNeeded = kind }
                    retryIDs.append(entryID)

                case .conflict:
                    // serverRecordChanged: pull cycle resolves via LWW.
                    // Leave in outbox, increment retry_count.
                    retryIDs.append(entryID)

                case .permanent:
                    // Unrecoverable: park the entry.
                    parkedIDs.append(entryID)
                }
            }
        }

        return PushOutcome(
            confirmedIDs: confirmedIDs,
            retryIDs: retryIDs,
            parkedIDs: parkedIDs,
            reclaimNeeded: reclaimNeeded
        )
    }
}
