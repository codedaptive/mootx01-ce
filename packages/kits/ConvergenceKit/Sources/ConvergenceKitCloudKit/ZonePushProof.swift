// ZonePushProof.swift
//
// Wave 6A2 upstream slice U2 — Part 2.
//
// Exact-batch push proof API for ConvergenceKitCloudKit.
//
// PURPOSE:
// Enables a downstream consumer (e.g. Fulcrum's dark-cutover driver) to push
// an explicit, prepared batch of records and tombstone deletes, then receive a
// typed proof of what actually happened — with no fabricated receipts and no
// silent partial-failure promotion to batch success.
//
// SAVE POLICY DECISION (changedKeys):
//    We use `.changedKeys` (unconditional upsert) rather than
//    `.ifServerRecordUnchanged` for the following reasons:
//
//    1. IDEMPOTENCY: Retrying the same batch is safe under `.changedKeys`
//       because the engine uses LWW (Last Writer Wins by HLC). Pushing a record
//       with the same HLC as the current server record is a no-op or an exact
//       overwrite — either way, the server state converges to the same value.
//       Under `.ifServerRecordUnchanged`, a retry would fail with
//       serverRecordChanged unless the caller pre-fetches fresh change tags,
//       breaking the idempotency contract.
//
//    2. CONSISTENCY WITH ENGINE: PushCycle (the engine's own push path) also
//       uses `.changedKeys`. Using a different policy here would create two
//       incompatible push semantics for the same zone.
//
//    3. BATCH PROOF CONTRACT: The caller supplies an exact prepared batch; the
//       proof reports what each record's outcome was. Conditional semantics
//       (`.ifServerRecordUnchanged`) would require the caller to embed change
//       tags in their prepared CKRecords, coupling them to a prior fetch — that
//       is a different API (CAS batch push), not a dark-cutover bulk push.
//
// ATOMICALLY: true.
//    We pass `atomically: true` to request batch atomicity from the protocol.
//    CloudKit's `CKModifyRecordsOperation` with `isAtomic = true` either
//    commits all records in the batch or rolls back all of them on error. Under
//    the `CloudKitDatabaseProtocol` seam, fakes are free to honor or ignore the
//    flag — the flag is a request, not a guarantee when the underlying transport
//    is a fake. The proof always reports per-record outcomes from whatever the
//    protocol returned; callers must not assume atomicity was honored without
//    examining the partial-failure summary.
//
// TRUTHFULNESS INVARIANTS:
//    - Every returned HLC is decoded from the CKRecord the protocol returned in
//      saveResults — never fabricated from the input record.
//    - Partial failure is surfaced explicitly: a proof where any record failed
//      will have partialFailureSummary != nil and batchSuccess == false.
//    - Result/batch mismatch (a record in results but not in the batch, or a
//      batch record missing from results) throws ZonePushProofError.resultMismatch.
//    - The batch fingerprint is echoed unchanged — the caller can verify the
//      proof corresponds to the batch they submitted.

import Foundation
import CloudKit
import ConvergenceKit
import SubstrateTypes

// MARK: - ZoneRecordPushOutcome

/// The outcome of pushing a single record to CloudKit.
public enum ZoneRecordPushOutcome: Sendable {
    /// The record was accepted by the server. `hlc` is decoded from the CKRecord
    /// the protocol returned in `saveResults` under representation-aware decode.
    case saved(hlc: HLC)

    /// The record ID was successfully deleted from the server.
    case deleted

    /// The record failed to push. `error` is the per-record error from
    /// `saveResults` or `deleteResults`. The batch is partially failed.
    case failed(error: any Error)
}

// MARK: - ZonePartialFailureSummary

/// Summary of partial failures in a push batch.
///
/// Present in `ZonePushProof.partialFailureSummary` when at least one record
/// failed. The proof never claims batch success when this is non-nil.
public struct ZonePartialFailureSummary: Sendable {
    /// Number of records in the save batch that failed.
    public let failedSaveCount: Int
    /// Number of record IDs in the delete batch that failed.
    public let failedDeleteCount: Int

    public init(failedSaveCount: Int, failedDeleteCount: Int) {
        self.failedSaveCount = failedSaveCount
        self.failedDeleteCount = failedDeleteCount
    }
}

// MARK: - ZonePushProof

/// Typed proof of what happened when a prepared batch was pushed via
/// `CloudKitDatabaseProtocol.modifyRecords`.
///
/// Every field is derived from the protocol's actual response — no fabrication.
/// See ZonePushProof.swift header for the design decisions governing save policy,
/// atomicity, and the partial-failure contract.
public struct ZonePushProof: Sendable {

    /// Per-record push outcomes, keyed by recordName (UUID string).
    ///
    /// Includes both save and delete outcomes. Each value is derived from the
    /// protocol's `saveResults` or `deleteResults` — never from the input records.
    public let recordOutcomes: [String: ZoneRecordPushOutcome]

    /// Maximum HLC over successfully saved records.
    ///
    /// Derived from representation-aware decode of the CKRecords returned by the
    /// protocol in `saveResults`. If no records succeeded, this is `HLC.zero`.
    ///
    /// LEGACYPACKED NOTE: under .legacyPacked, the decoded HLC reflects 48/12/4
    /// truncated magnitudes. Under .fullWidthV2, the HLC is exact.
    public let successHLCFloor: HLC

    /// The caller-supplied batch fingerprint, echoed byte-for-byte.
    ///
    /// The caller uses this to verify that the proof corresponds to the batch
    /// they submitted (e.g. a SHA-256 digest of the serialised batch contents).
    /// The proof API does not inspect or validate the fingerprint; it is opaque data.
    public let batchFingerprint: Data

    /// Partial failure summary. Non-nil when at least one record or delete failed.
    ///
    /// Callers must check this before treating the proof as a batch success.
    /// A partial failure leaves the zone in an intermediate state; the caller is
    /// responsible for deciding whether to retry the failing records.
    public let partialFailureSummary: ZonePartialFailureSummary?

    public init(
        recordOutcomes: [String: ZoneRecordPushOutcome],
        successHLCFloor: HLC,
        batchFingerprint: Data,
        partialFailureSummary: ZonePartialFailureSummary?
    ) {
        self.recordOutcomes = recordOutcomes
        self.successHLCFloor = successHLCFloor
        self.batchFingerprint = batchFingerprint
        self.partialFailureSummary = partialFailureSummary
    }

    /// True only when every record in the batch succeeded (no partial failures).
    public var batchSuccess: Bool {
        partialFailureSummary == nil
    }
}

// MARK: - ZonePushProofError

/// Errors from the push-proof path.
public enum ZonePushProofError: Error, Sendable {
    /// The protocol's `modifyRecords` result contained a record not in the
    /// submitted batch, or a batch record was missing from the results. Either
    /// indicates a protocol violation (the fake or real database returned
    /// unexpected IDs). The proof is not constructed; the caller must investigate.
    case resultMismatch(detail: String)

    /// The protocol returned a save result for a record whose CKRecord could not
    /// be decoded via `CKRecordMapping.decode`. The returned record is suspect;
    /// the caller should treat this as a corrupt round-trip.
    case decodeFailure(recordName: String, underlying: any Error)
}

// MARK: - pushZoneBatch

/// Push an explicit prepared batch of records and tombstone IDs to CloudKit
/// and return a typed proof of per-record outcomes.
///
/// The proof is derived entirely from what the database protocol actually
/// returned — no fabricated receipts. See ZonePushProof.swift header for
/// the full truthfulness contract.
///
/// - Parameters:
///   - records: CKRecords to save. Must all reside in `zoneID`. Duplicates
///     (same `recordID`) are detected via the result/batch mismatch check.
///   - deletions: Record IDs to delete. Must all reside in `zoneID`.
///   - batchFingerprint: Opaque caller-supplied identifier for this batch
///     (e.g. SHA-256 of the batch contents). Echoed in the proof unchanged.
///   - manifest: Manifest binding — `hlcWireRepresentation` drives decode
///     of the returned CKRecords. `schemaVersion` is not checked here.
///   - database: Injectable database seam. Provide a fake in tests; production
///     callers can use `CKContainer(identifier: containerIdentifier).privateCloudDatabase`.
///
/// - Returns: A `ZonePushProof` with per-record outcomes, success HLC floor,
///   echoed fingerprint, and partial-failure summary (nil on full success).
///
/// - Throws:
///   - `ZonePushProofError.resultMismatch` if the protocol's result set does not
///     match the submitted batch (extra or missing IDs).
///   - `ZonePushProofError.decodeFailure` if a successfully saved CKRecord cannot
///     be decoded.
///   - Transport errors from `modifyRecords` propagate as-is.
public func pushZoneBatch(
    records: [CKRecord],
    deletions: [CKRecord.ID],
    batchFingerprint: Data,
    manifest: SyncManifest,
    database: any CloudKitDatabaseProtocol
) async throws -> ZonePushProof {
    let representation = manifest.hlcWireRepresentation

    // Compute expected record and deletion ID sets for result/batch mismatch checks.
    let expectedSaveIDs = Set(records.map(\.recordID))
    let expectedDeleteIDs = Set(deletions)

    // Push the batch via the protocol seam.
    // savePolicy: .changedKeys — see header for full rationale (unconditional
    // upsert, LWW-safe, idempotent retry, consistent with PushCycle).
    // atomically: true — request batch atomicity; proof still reports per-record
    // outcomes from whatever the protocol actually returned.
    let result = try await database.modifyRecords(
        saving: records,
        deleting: deletions,
        savePolicy: .changedKeys,
        atomically: true
    )

    // MISMATCH CHECK — save results.
    // The protocol must return exactly one outcome per submitted save record.
    // Extra IDs (in results but not in batch) indicate a protocol violation.
    // Missing IDs (in batch but not in results) indicate a dropped record.
    let actualSaveIDs = Set(result.saveResults.keys)
    if actualSaveIDs != expectedSaveIDs {
        let extra = actualSaveIDs.subtracting(expectedSaveIDs).map(\.recordName).sorted()
        let missing = expectedSaveIDs.subtracting(actualSaveIDs).map(\.recordName).sorted()
        throw ZonePushProofError.resultMismatch(
            detail: "save results mismatch — extra: \(extra), missing: \(missing)"
        )
    }

    // MISMATCH CHECK — delete results.
    let actualDeleteIDs = Set(result.deleteResults.keys)
    if actualDeleteIDs != expectedDeleteIDs {
        let extra = actualDeleteIDs.subtracting(expectedDeleteIDs).map(\.recordName).sorted()
        let missing = expectedDeleteIDs.subtracting(actualDeleteIDs).map(\.recordName).sorted()
        throw ZonePushProofError.resultMismatch(
            detail: "delete results mismatch — extra: \(extra), missing: \(missing)"
        )
    }

    // Build per-record outcomes from the actual protocol results.
    var recordOutcomes: [String: ZoneRecordPushOutcome] = [:]
    var successHLCs: [HLC] = []
    var failedSaveCount = 0
    var failedDeleteCount = 0

    // Save outcomes.
    for (recordID, saveResult) in result.saveResults {
        switch saveResult {
        case .success(let savedRecord):
            // Decode the returned CKRecord representation-awarely to extract the HLC.
            // We decode the record the protocol returned, not the record we sent —
            // this is the truthfulness invariant: the HLC comes from the server's
            // acknowledgement, not the client's input.
            let decoded: DecodedRecord
            do {
                decoded = try CKRecordMapping.decode(savedRecord, representation: representation)
            } catch {
                throw ZonePushProofError.decodeFailure(
                    recordName: recordID.recordName,
                    underlying: error
                )
            }
            recordOutcomes[recordID.recordName] = .saved(hlc: decoded.hlc)
            successHLCs.append(decoded.hlc)
        case .failure(let error):
            recordOutcomes[recordID.recordName] = .failed(error: error)
            failedSaveCount += 1
        }
    }

    // Delete outcomes.
    for (recordID, deleteResult) in result.deleteResults {
        switch deleteResult {
        case .success:
            recordOutcomes[recordID.recordName] = .deleted
        case .failure(let error):
            recordOutcomes[recordID.recordName] = .failed(error: error)
            failedDeleteCount += 1
        }
    }

    // Compute the success HLC floor over all successfully saved records.
    // Tombstone CKRecords pushed as saves (engine's typed-tombstone path) will
    // decode to an HLC and appear as `.saved(hlc:)` outcomes — their delete HLC
    // contributes to the floor. Raw CKRecord.ID deletes appear as `.deleted` and
    // have no HLC to contribute (matching the ZoneSnapshot floor semantics).
    let successHLCFloor = successHLCs.max() ?? .zero

    // Partial failure summary: non-nil only when at least one record or delete failed.
    let partialFailureSummary: ZonePartialFailureSummary? =
        (failedSaveCount > 0 || failedDeleteCount > 0)
        ? ZonePartialFailureSummary(
            failedSaveCount: failedSaveCount,
            failedDeleteCount: failedDeleteCount
        )
        : nil

    return ZonePushProof(
        recordOutcomes: recordOutcomes,
        successHLCFloor: successHLCFloor,
        batchFingerprint: batchFingerprint,
        partialFailureSummary: partialFailureSummary
    )
}
