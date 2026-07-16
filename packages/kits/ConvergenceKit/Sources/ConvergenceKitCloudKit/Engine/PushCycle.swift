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
// 5. Confirm sent entries by deleting them from the outbox.

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
        // the transport confirms success. A transport failure throws before confirm(),
        // leaving all entries intact for the next push cycle. This is R4's
        // durability guarantee: no change is lost to a transport failure.
        //
        // P1-M6 seam: until per-record push results land, PushCycle confirms
        // the full batch on transport success and retains the full batch on
        // transport failure. Per-record confirmation (partial success from
        // modifyRecords(atomically: false)) requires the per-record result
        // surface from P1-M6; confirm(ids:) already accepts a list so the
        // P1-M6 upgrade is a call-site change here, not a schema or
        // OutboxStore API change.
        let batch = try await OutboxStore.readBatch(from: storage)

        var saved: [CKRecord] = []
        // WHY no `deleted: [CKRecord.ID]` queue: we no longer send typed deletions.
        // CKRecord.ID deletions carry no record type so the receiver fans out to
        // every non-pushOnly manifest table (D1 defect). Tombstone CKRecords encode
        // the table in their recordType (`kitID_tableName`) — the pull path routes
        // them correctly. All delete events are pushed as tombstone CKRecords and
        // saved alongside regular upserts in the single `modifyRecords` call.
        var confirmedIDs: [UUID] = []
        var pushedCount = 0

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
                    confirmedIDs.append(entry.id)
                    pushedCount += 1
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
                confirmedIDs.append(entry.id)
                pushedCount += 1
            }
        }

        // Step 3: Send to CloudKit via the injectable database seam.
        // All changes (upserts and tombstones) go as saves.
        if !saved.isEmpty {
            do {
                _ = try await database.modifyRecords(
                    saving: saved,
                    deleting: [],
                    savePolicy: .changedKeys,
                    atomically: false
                )
            } catch {
                // Transport failed. Do NOT confirm — leave all outbox entries intact.
                // They will be retried on the next push cycle (either triggered by
                // the next local write or by the host app's retry timer).
                throw SyncError.transportFailure(detail: "CKDatabase.modifyRecords: \(error)")
            }
        }

        // Step 4: Transport succeeded: confirm the entries that were encoded and sent.
        // Entries that were skipped (missing table, bad rowKey, decode failure)
        // are not in confirmedIDs and remain in the outbox.
        try await OutboxStore.confirm(ids: confirmedIDs, from: storage)

        let receipt = SyncReceipt(pushed: pushedCount, pulled: 0, conflicts: 0)
        lastPushAt = Date()
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }
}
