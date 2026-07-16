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
        // storage must be configured to push, but push() drives the CloudKit
        // operations directly off `manifest`/`pendingOutbound` and does not
        // read it here — so assert configuration without binding the value.
        guard isEnabled, let manifest, storage != nil else { throw SyncError.notEnabled }

        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)
        let pending = pendingOutbound
        pendingOutbound.removeAll()

        var saved: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var pushedCount = 0

        for change in pending {
            guard let syncedTable = manifest.table(named: change.table) else { continue }
            guard syncedTable.direction != .pullOnly else { continue }
            guard let rowKey = change.rowKey else { continue }

            switch change.event {
            case .insert, .update:
                guard let values = change.values else { continue }
                // Prefer the HLC that already ordered the change. If
                // the observation carried none (the InMemory and
                // SQLite observers do not stamp an HLC on the change
                // notification today), mint a monotonic one through
                // the HLC generator. send(now:) takes the clock as a
                // parameter so the engine stays deterministic, and
                // advances per-replica state so two changes pushed in
                // the same millisecond still order via the logical
                // counter. The earlier code fabricated an HLC inline
                // from Date() with nodeID 0, which both violated the
                // deterministic-engine rule and risked node collisions.
                let hlc = change.hlc ?? hlcGenerator.send(now: nowMillis())
                do {
                    let record = try CKRecordMapping.record(
                        from: values,
                        table: change.table,
                        rowKey: rowKey,
                        hlc: hlc,
                        schemaVersion: manifest.schemaVersion,
                        kitID: manifest.kitID,
                        zone: zoneID
                    )
                    saved.append(record)
                    pushedCount += 1
                } catch {
                    logger.error("push encode failed: \(String(describing: error))")
                }
            case .delete:
                let id = CKRecordMapping.recordID(rowKey: rowKey, zone: zoneID)
                deleted.append(id)
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
                throw SyncError.transportFailure(detail: "CKDatabase.modifyRecords: \(error)")
            }
        }

        let receipt = SyncReceipt(pushed: pushedCount, pulled: 0, conflicts: 0)
        lastPushAt = Date()
        emit(.pushCompleted(receipt: receipt))
        return receipt
    }
}
