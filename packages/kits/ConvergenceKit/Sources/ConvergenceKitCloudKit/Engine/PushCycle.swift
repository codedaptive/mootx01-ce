// PushCycle.swift
//
// Outbound push path for CloudKitStateActor. Encodes pending local
// changes into CKRecords and sends them to the private CloudKit database.

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
        // transport confirms success. A transport failure throws before confirm(),
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
        var deleted: [CKRecord.ID] = []
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
                let ckID = CKRecordMapping.recordID(rowKey: rowKey, zone: zoneID)
                deleted.append(ckID)
                confirmedIDs.append(entry.id)
                pushedCount += 1
            }
        }

        // Send to CloudKit.
        if !saved.isEmpty || !deleted.isEmpty {
            do {
                _ = try await container.privateCloudDatabase.modifyRecords(
                    saving: saved,
                    deleting: deleted,
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

        // Transport succeeded: confirm the entries that were encoded and sent.
        // Entries that were skipped (missing table, bad rowKey, decode failure)
        // are not in confirmedIDs and remain in the outbox.
        try await OutboxStore.confirm(ids: confirmedIDs, from: storage)

        let receipt = SyncReceipt(pushed: pushedCount, pulled: 0, conflicts: 0)
        lastPushAt = Date()
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }
}
