// PullCycle.swift
//
// Inbound pull path for CloudKitStateActor. Fetches remote record
// changes and deletions from the private CloudKit database via the
// injectable CloudKitDatabaseProtocol seam and applies them through
// the conflict-policy switch in ApplyInbound.swift.

import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "Engine")

// MARK: - Pull

extension CloudKitStateActor {

    func pull() async throws -> SyncReceipt {
        guard isEnabled, let manifest, let storage, let database else { throw SyncError.notEnabled }
        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

        // Fetch zone changes via the injectable database seam.
        //
        // database.fetchZoneChanges(inZoneWith:since:) returns a CloudKitZoneChanges
        // mirror type (constructible in tests, unlike CKDatabase.RecordZoneChanges
        // which has no public init). The real CKDatabase conformance translates
        // from recordZoneChanges(inZoneWith:since:) in the retroactive extension.
        var pulledRecords: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken? = serverChangeToken

        do {
            let result = try await database.fetchZoneChanges(
                inZoneWith: zoneID,
                since: serverChangeToken
            )
            // CloudKitZoneChanges.modifiedRecords is a [CKRecord] direct list
            // (already unwrapped from the per-record Result in the CKDatabase
            // conformance). Only successful modification results are included.
            pulledRecords = result.modifiedRecords

            // CloudKitZoneChanges.deletedRecordIDs mirrors CKDatabase.RecordZoneChanges
            // deletions as [CKRecord.ID]. These are legacy external deletions (the
            // engine itself uses typed tombstone CKRecords for its own deletes — see
            // PushCycle.swift and the D1 fix rationale below).
            deletedIDs = result.deletedRecordIDs

            newToken = result.changeToken
        } catch let ckError as CKError where ckError.code == .changeTokenExpired {
            // The server has invalidated the token (zone history truncated or
            // token too old). Clear the persisted token and reset in-memory
            // state, then re-pull from scratch. Safe: applyInbound is
            // idempotent under all four conflict policies — remoteWins,
            // localWins, appendOnly, and lastWriterWinsByHLC all handle
            // duplicate inbound records correctly without data loss.
            //
            // The guard on serverChangeToken != nil prevents infinite
            // recursion: if we had no token, changeTokenExpired is
            // unexpected and we surface it rather than looping.
            guard serverChangeToken != nil else {
                throw SyncError.transportFailure(detail: "changeTokenExpired on a nil token — unexpected: \(ckError)")
            }
            logger.info("changeTokenExpired for zone \(manifest.zoneIdentifier) — clearing token and re-pulling from scratch")
            try? await TokenStore.clear(zoneName: manifest.zoneIdentifier, storage: storage)
            serverChangeToken = nil
            return try await pull()
        } catch {
            throw SyncError.transportFailure(detail: "fetchZoneChanges: \(error)")
        }

        var appliedCount = 0
        var conflicts = 0

        for record in pulledRecords {
            do {
                let decoded = try CKRecordMapping.decode(record)
                guard decoded.kitID == manifest.kitID else {
                    throw SyncError.kitMismatch(expected: manifest.kitID, received: decoded.kitID)
                }
                guard decoded.schemaVersion == manifest.schemaVersion else {
                    throw SyncError.schemaMismatch(expected: manifest.schemaVersion, received: decoded.schemaVersion)
                }
                guard let syncedTable = manifest.table(named: decoded.table) else {
                    throw SyncError.unsupportedTable(name: decoded.table)
                }
                guard syncedTable.direction != .pushOnly else { continue }

                try await applyInbound(decoded, syncedTable: syncedTable, storage: storage)
                appliedCount += 1
            } catch let err as SyncError {
                logger.error("pull apply failed: \(String(describing: err))")
                conflicts += 1
            } catch {
                logger.error("pull apply failed (other): \(String(describing: error))")
                conflicts += 1
            }
        }

        // Legacy CKRecord.ID deletions: arrives when a record is deleted outside
        // our engine (e.g. directly via CloudKit Dashboard or iCloud.com). Our engine
        // no longer produces CKRecord.ID deletions — all deletes are pushed as typed
        // tombstone CKRecords and arrive via `pulledRecords` above with full table
        // routing. This path is a best-effort fallback for external deletions only.
        //
        // WHY we keep it: silently ignoring external deletions would leave ghost rows.
        // WHY we skip the HLC gate here: no HLC is available from CKRecord.ID.
        // The fan-out to all tables is accepted here because this is a legacy path
        // for externally-sourced deletions; our own deletes never enter this path.
        for recordID in deletedIDs {
            guard let rowKey = UUID(uuidString: recordID.recordName) else { continue }
            for syncedTable in manifest.tables where syncedTable.direction != .pushOnly {
                let predicate = StoragePredicate.eq(
                    Column(table: syncedTable.name, name: syncedTable.primaryKeyColumn),
                    .uuid(rowKey)
                )
                // Use deleteSync so the emitted TableChange carries origin: .syncApply,
                // preventing the deletion from re-entering the outbox (I-10).
                _ = try? await storage.rowStore.deleteSync(table: syncedTable.name, where: predicate)
            }
            appliedCount += 1
        }

        serverChangeToken = newToken
        // Persist the updated token so the next process launch resumes from
        // here rather than re-pulling the full zone. R5. A save failure is
        // non-fatal — the pull succeeded; worst case is a redundant full-zone
        // pull on next launch.
        if let token = newToken {
            try? await TokenStore.save(token: token, zoneName: manifest.zoneIdentifier, storage: storage)
        }
        let receipt = SyncReceipt(pushed: 0, pulled: appliedCount, conflicts: conflicts)
        lastPullAt = Date()
        if appliedCount > 0 {
            emit(.remoteChangesApplied(count: appliedCount))
        }
        return receipt
    }
}
