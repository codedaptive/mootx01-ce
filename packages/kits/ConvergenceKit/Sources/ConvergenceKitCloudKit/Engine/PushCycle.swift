// PushCycle.swift
//
// Outbound push path for CloudKitStateActor. Encodes pending local
// changes into CKRecords and sends them to the private CloudKit database.
//
// Per-record push results (R6, CVK-ICLOUD P1-M6):
// modifyRecords(atomically: false) returns per-record success/failure. Each
// record's result is classified via CKErrorTaxonomy and the outbox is updated
// via PushResults.process: confirmed entries are removed, retryable entries
// have their retry_count incremented, and permanently-failed entries are parked.
// Only truly-accepted records are counted in the SyncReceipt (B-2).

import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "Engine")

// MARK: - Push

extension CloudKitStateActor {

    func push() async throws -> SyncReceipt {
        // Bind storage: push() reads from the durable outbox, which requires
        // a live storage reference (unlike the old pendingOutbound array path).
        guard isEnabled, let manifest, let storage else { throw SyncError.notEnabled }

        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

        // Read batch WITHOUT clearing. Entries remain in the outbox until the
        // transport confirms success per-record. R4's durability guarantee:
        // a process death or transport failure before confirm leaves entries intact
        // for the next push cycle. Parked entries are excluded by readBatch.
        let batch = try await OutboxStore.readBatch(from: storage)

        var saved: [CKRecord] = []
        // WHY no `deleted: [CKRecord.ID]` queue: we no longer send typed deletions.
        // CKRecord.ID deletions carry no record type so the receiver fans out to
        // every non-pushOnly manifest table (D1 defect). Tombstone CKRecords encode
        // the table in their recordType (`kitID_tableName`) — the pull path routes
        // them correctly. All delete events are pushed as tombstone CKRecords and
        // saved alongside regular upserts in the single `modifyRecords` call.

        // recordToEntryID: maps each CKRecord.ID back to its outbox entry UUID so
        // PushResults.process can correlate per-record transport results with the
        // outbox entries that need to be confirmed, retried, or parked.
        var recordToEntryID: [CKRecord.ID: UUID] = [:]

        for entry in batch {
            guard let syncedTable = manifest.table(named: entry.tableName) else { continue }
            guard syncedTable.direction != .pullOnly else { continue }
            guard let rowKey = UUID(uuidString: entry.rowKey) else {
                logger.error("push: malformed row_key in outbox entry \(entry.id): \(entry.rowKey)")
                continue
            }

            // Recover the stored HLC from the outbox entry. This is the HLC
            // that was minted at observe time (recordOutbound), not a fresh
            // mint — preserving the logical ordering established at capture.
            let hlc = HLC(packed: UInt64(bitPattern: entry.packedHLC))

            switch entry.event {
            case .insert, .update:
                guard let valuesData = entry.valuesData else {
                    logger.error("push: missing values blob for \(entry.event.rawValue) entry \(entry.id)")
                    continue
                }
                let values: [String: TypedValue]
                do {
                    let valueMap = try JSONDecoder().decode(SyncValueMap.self, from: valuesData)
                    values = valueMap.asTypedValues
                } catch {
                    logger.error("push: values decode failed for entry \(entry.id): \(error)")
                    continue
                }
                do {
                    let record = try CKRecordMapping.record(
                        from: values,
                        table: entry.tableName,
                        rowKey: rowKey,
                        hlc: hlc,
                        schemaVersion: manifest.schemaVersion,
                        kitID: manifest.kitID,
                        zone: zoneID
                    )
                    saved.append(record)
                    recordToEntryID[record.recordID] = entry.id
                } catch {
                    logger.error("push encode failed for entry \(entry.id): \(String(describing: error))")
                }
            case .delete:
                // Push a tombstone CKRecord instead of a CKRecord.ID deletion.
                // The typed record (`kitID_tableName`) gives the pull path the
                // table identity it needs for routing (D1 fix). The delete HLC
                // in `_syncHLC` enables the receiver's LWW gate (D2 fix) and
                // the A6 tombstone-HLC persistence in `_ck_sync_meta`. The HLC
                // is the outbox entry's capture-time HLC, preserving ordering.
                let tombstone = CKRecordMapping.tombstoneRecord(
                    rowKey: rowKey,
                    table: entry.tableName,
                    kitID: manifest.kitID,
                    deleteHLC: hlc,
                    schemaVersion: manifest.schemaVersion,
                    zone: zoneID
                )
                saved.append(tombstone)
                recordToEntryID[tombstone.recordID] = entry.id
            }
        }

        // Send to CloudKit. All changes (upserts and tombstones) go as saves.
        // With atomically: false, some records may succeed and others fail —
        // the per-record results dictionary is the authoritative source of truth.
        if !saved.isEmpty {
            let modifyResult: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                               deleteResults: [CKRecord.ID: Result<Void, Error>])
            do {
                modifyResult = try await container.privateCloudDatabase.modifyRecords(
                    saving: saved,
                    deleting: [],
                    savePolicy: .changedKeys,
                    atomically: false
                )
            } catch {
                // Whole-batch transport failure (network outage, authentication error,
                // etc.) before CloudKit processed any records. Leave all outbox entries
                // intact; they will be retried on the next push cycle.
                throw SyncError.transportFailure(detail: "CKDatabase.modifyRecords: \(error)")
            }

            // Classify each per-record result via CKErrorTaxonomy.
            let outcome = PushResults.process(
                saveResults: modifyResult.saveResults,
                recordToEntryID: recordToEntryID
            )

            // Confirm accepted records (remove from outbox). Only truly-accepted
            // records count toward the receipt's pushed count (B-2).
            try await OutboxStore.confirm(ids: outcome.confirmedIDs, from: storage)

            // Park permanently-failed entries. is_parked = 1 excludes them from
            // future readBatch calls; they remain visible via parkedEntries.
            for id in outcome.parkedIDs {
                try? await OutboxStore.park(id: id, from: storage)
                logger.warning("push: entry \(id) parked (permanent failure)")
            }

            // Increment retry count for retryable and conflict failures.
            for id in outcome.retryIDs {
                try? await OutboxStore.incrementRetryCount(id: id, from: storage)
            }

            // Surface reclaim need. Zone re-creation and token reset are the
            // caller's responsibility; logging here informs the operator.
            if let reclaim = outcome.reclaimNeeded {
                logger.warning("push: reclaim needed — \(String(describing: reclaim))")
            }

            let receipt = SyncReceipt(pushed: outcome.pushedCount, pulled: 0, conflicts: 0)
            lastPushAt = Date()
            emit(.pushCompleted(receipt: receipt))
            return receipt
        }

        // No records encoded: outbox was empty or all entries were filtered out.
        // Emit a zero receipt so subscribers know a push cycle completed.
        let receipt = SyncReceipt(pushed: 0, pulled: 0, conflicts: 0)
        lastPushAt = Date()
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }
}
