// PushCycle.swift
//
// Outbound push path for CloudKitStateActor. Calls the epoch fence, then
// encodes pending local changes into CKRecords and sends them to the private
// CloudKit database via the injectable CloudKitDatabaseProtocol seam.
//
// PUSH LIFECYCLE:
// 1. EpochFence.heartbeat() verifies (slot, epoch) is still current and
//    updates last_active_hlc. MUST run BEFORE reading the outbox so that
//    a reenrollRequired event (slot was evicted while we were away) can
//    trigger remintAll on the outbox BEFORE any stale-nodeID records
//    reach the wire (A2, A5).
// 2. If reenrollRequired is thrown: call actor.reenroll() (re-claim slot,
//    remint outbox HLCs, update identity) and retry from the batch read.
//    Only one re-enrollment is attempted per push cycle to avoid loops.
// 3. Read the outbox batch (without consuming). Entries survive a transport
//    failure (R4 durability).
// 4. Encode and send via database.modifyRecords.
// 5. Per-record push results (R6, CVK-ICLOUD P1-M6): each record's result is
//    classified via CKErrorTaxonomy and the outbox is updated via
//    PushResults.process — confirmed entries are removed, retryable entries
//    have their retry_count incremented, permanently-failed entries are
//    parked. Only truly-accepted records count in the SyncReceipt (B-2).

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
        guard isEnabled, let manifest, let storage, let database else { throw SyncError.notEnabled }

        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

        // Step 1: Epoch fence — verify (slot, epoch) is still current and heartbeat.
        //
        // Must run BEFORE reading the outbox batch. If this device was evicted while
        // inactive, the outbox entries carry an old nodeID. Sending them would produce
        // HLC collisions that different replicas resolve differently (silent LWW
        // divergence). The fence detects the superseded epoch LOUDLY so re-enrollment
        // can remint the outbox before any records reach the wire.
        if let identity = currentIdentity {
            // Mint an HLC for the heartbeat's last_active_hlc field.
            let heartbeatHLC = hlcGenerator.send(now: nowMillis())
            do {
                try await EpochFence.heartbeat(
                    identity: identity,
                    currentHLC: heartbeatHLC,
                    database: database,
                    zoneID: zoneID
                )
            } catch SyncError.reenrollRequired(let slot, let staleEpoch, let currentEpoch) {
                logger.warning("push: epoch fence triggered re-enrollment (slot=\(slot) staleEpoch=\(staleEpoch) currentEpoch=\(currentEpoch))")
                // Re-enroll: re-claim slot, remint outbox HLCs under new nodeID, persist identity.
                try await reenroll(zoneID: zoneID)
                // Fall through to push with the re-minted outbox entries.
            }
            // Other errors (transportFailure) bubble up — push is aborted.
        }

        // Step 2: Read batch WITHOUT clearing. Entries remain in the outbox until
        // the transport confirms success per-record. R4's durability guarantee:
        // a process death or transport failure before confirm leaves entries
        // intact for the next push cycle. Parked entries are excluded by readBatch.
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
            // After re-enrollment, remintAll replaced these with new nodeID HLCs.
            // Gap 6 (D38.1): decoded from the full-width `hlcWireBytes`, not
            // the legacy 40-bit-truncated `HLC(packed:)`.
            guard let hlc = try? HLC(wireBytes: [UInt8](entry.hlcWireBytes)) else {
                logger.error("push: malformed hlcWireBytes for entry \(entry.id)")
                continue
            }

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
                // Decode column HLC map for fieldLevelLWW outbox entries (B-8).
                // Nil when absent — non-fieldLevelLWW tables or entries written before v6.
                let columnHLCs: ColumnHLCMap?
                if let colData = entry.columnHLCsData {
                    columnHLCs = try? JSONDecoder().decode(ColumnHLCMap.self, from: colData)
                } else {
                    columnHLCs = nil
                }
                do {
                    let record = try CKRecordMapping.record(
                        from: values,
                        table: entry.tableName,
                        rowKey: rowKey,
                        hlc: hlc,
                        schemaVersion: manifest.schemaVersion,
                        kitID: manifest.kitID,
                        zone: zoneID,
                        columnHLCs: columnHLCs,
                        // Route declared columns through CKRecord.encryptedValues (FAB5-EV Phase 2).
                        // Empty default for undeclared tables preserves byte-identical wire format.
                        encryptedColumns: manifest.encryptedContentColumns[entry.tableName] ?? []
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

        // Step 3: Send to CloudKit via the injectable database seam.
        // All changes (upserts and tombstones) go as saves. With
        // atomically: false, some records may succeed and others fail —
        // the per-record results dictionary is the authoritative source of truth.
        if !saved.isEmpty {
            let modifyResult: (saveResults: [CKRecord.ID: Result<CKRecord, Error>],
                               deleteResults: [CKRecord.ID: Result<Void, Error>])
            do {
                modifyResult = try await database.modifyRecords(
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
