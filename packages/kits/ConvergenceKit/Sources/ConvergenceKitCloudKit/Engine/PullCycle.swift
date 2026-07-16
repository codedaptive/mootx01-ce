// PullCycle.swift
//
// Inbound pull path for CloudKitStateActor. Fetches remote record
// changes and deletions from the private CloudKit database and applies
// them through the conflict-policy switch in ApplyInbound.swift.

import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "Engine")

// MARK: - Pull

extension CloudKitStateActor {

    func pull() async throws -> SyncReceipt {
        guard isEnabled, let manifest, let storage else { throw SyncError.notEnabled }
        let zoneID = CKRecordZone.ID(zoneName: manifest.zoneIdentifier, ownerName: CKCurrentUserDefaultName)

        // Pull via async recordZoneChanges(inZoneWith:since:) API.
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = serverChangeToken

        var pulledRecords: [CKRecord] = []
        var deletedIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken? = serverChangeToken

        do {
            let result = try await container.privateCloudDatabase.recordZoneChanges(
                inZoneWith: zoneID,
                since: serverChangeToken
            )
            for (_, modResult) in result.modificationResultsByID {
                if case .success(let mod) = modResult {
                    pulledRecords.append(mod.record)
                }
            }
            for deletion in result.deletions {
                deletedIDs.append(deletion.recordID)
            }
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
            throw SyncError.transportFailure(detail: "recordZoneChanges: \(error)")
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

        // Apply deletions. Deletion events carry only a CKRecord.ID, no record type
        // that could identify the target table. Deletion is attempted against every
        // non-pushOnly manifest table; the manifest is the scope guard.
        for recordID in deletedIDs {
            let parts = recordID.recordName.split(separator: ":")
            guard let rowKey = UUID(uuidString: String(parts[0])) else { continue }
            for syncedTable in manifest.tables where syncedTable.direction != .pushOnly {
                let predicate = StoragePredicate.eq(
                    Column(table: syncedTable.name, name: syncedTable.primaryKeyColumn),
                    .uuid(rowKey)
                )
                _ = try? await storage.rowStore.delete(table: syncedTable.name, where: predicate)
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
