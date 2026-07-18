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

// MARK: - DecodedRecord → SyncRecord conversion (skew-queue enqueue, R9)

extension DecodedRecord {
    /// Convert this DecodedRecord to a SyncRecord for storage in the
    /// pending-skew queue.
    ///
    /// Event kind is conservative: tombstones map to `.delete` (syncDeleted = true);
    /// live records map to `.update`. The upsert semantics of applyInbound handle
    /// both insert-new-row and update-existing-row via `.update` correctly under
    /// all four conflict policies.
    ///
    /// The full column-HLC map is preserved so replay restores per-column
    /// ordering for fieldLevelLWW tables.
    fileprivate func asSyncRecord() -> SyncRecord {
        SyncRecord(
            table: table,
            event: isTombstone ? .delete : .update,
            rowKey: rowKey,
            values: values.isEmpty ? nil : SyncValueMap(values),
            hlc: PackedHLC(syncMeta.hlc),
            schemaVersion: syncMeta.schemaVersion,
            kitID: syncMeta.kitID,
            syncDeleted: isTombstone ? true : nil,
            columnHLCs: columnHLCs
        )
    }
}

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
        // Count of records held in the skew queue this pull cycle (R9).
        // Incremented for each future-schema record; never decremented.
        // Used to emit SyncEvent.recordsHeldForMigration after the loop.
        var skewHeldCount = 0

        // Collect row keys per table for the post-apply integrity hook (R3).
        // Tombstone records are deletions from the consumer's point of view,
        // so they land in deletedByTable even though they arrive through the
        // typed-record path rather than the legacy CKRecord.ID deletion path.
        var appliedByTable: [String: [UUID]] = [:]
        var deletedByTable: [String: [UUID]] = [:]

        // Batch pre-load _ck_sync_meta for the entire pulled batch (CVK-WB5 perf Q5).
        //
        // WHY: applyInbound issues one readSyncHLC query per record in the
        // lastWriterWinsByHLC (and fieldLevelLWW row-grain) path. For a batch of N
        // records, this is N sequential queries. The batch pre-load reduces this to
        // one query + N in-memory dict lookups, saving approximately N-1 storage
        // actor hops per pull cycle.
        //
        // Decode is attempted with `try?` here (not counted as a conflict) because
        // any records that fail to decode will be counted as conflicts in the main
        // loop below where the error is properly classified.
        let batchKeys: [(table: String, rowKey: UUID)] = pulledRecords.compactMap { record in
            guard let decoded = try? CKRecordMapping.decode(record) else { return nil }
            return (table: decoded.table, rowKey: decoded.rowKey)
        }
        let preloadedSyncHLCs = try? await readSyncHLCs(batch: batchKeys, storage: storage)

        for record in pulledRecords {
            do {
                let decoded = try CKRecordMapping.decode(record)
                guard decoded.kitID == manifest.kitID else {
                    throw SyncError.kitMismatch(expected: manifest.kitID, received: decoded.kitID)
                }
                // Schema-skew split (R9, CVK-ICLOUD P3-M4):
                //
                // Future-schema (sender on newer schema than receiver):
                //   Enqueue in _ck_pending_skew. NOT a conflict — the record is valid
                //   and will be replayed on enable() after the receiver's schema updates.
                //   `continue` advances to the next record without applying or counting
                //   this record toward appliedCount.
                //
                // Downgrade-apply (sender on older schema than receiver):
                //   WHY reject: applying an older-schema record could overwrite newer-schema
                //   columns with missing-field defaults, silently corrupting data. The sender
                //   resends with the current schema after it updates. Count as conflict.
                if decoded.schemaVersion > manifest.schemaVersion {
                    let syncRecord = decoded.asSyncRecord()
                    try await PendingSkewQueue.enqueue(
                        syncRecord,
                        to: storage,
                        sideTable: CKSideSchema.pendingSkewTable
                    )
                    skewHeldCount += 1
                    continue
                } else if decoded.schemaVersion < manifest.schemaVersion {
                    throw SyncError.schemaMismatch(
                        expected: manifest.schemaVersion,
                        received: decoded.schemaVersion
                    )
                }
                // decoded.schemaVersion == manifest.schemaVersion — normal apply path.
                guard let syncedTable = manifest.table(named: decoded.table) else {
                    throw SyncError.unsupportedTable(name: decoded.table)
                }
                guard syncedTable.direction != .pushOnly else { continue }

                try await applyInbound(decoded, syncedTable: syncedTable, storage: storage,
                                       preloadedSyncHLCs: preloadedSyncHLCs)
                appliedCount += 1
                if decoded.isTombstone {
                    deletedByTable[decoded.table, default: []].append(decoded.rowKey)
                } else {
                    appliedByTable[decoded.table, default: []].append(decoded.rowKey)
                }
            } catch let err as SyncError {
                logger.error("pull apply failed: \(String(describing: err))")
                conflicts += 1
            } catch {
                logger.error("pull apply failed (other): \(String(describing: error))")
                conflicts += 1
            }
        }

        // Emit recordsHeldForMigration when at least one future-schema record
        // was enqueued this cycle (R9). Subscribers can use this to surface a
        // "waiting for app update" indicator in the UI.
        if skewHeldCount > 0 {
            emit(.recordsHeldForMigration(count: skewHeldCount))
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
                // Track for post-apply hook: legacy deletions attributed per-table.
                deletedByTable[syncedTable.name, default: []].append(rowKey)
            }
            appliedCount += 1
        }

        // Post-apply integrity hook (R3): invoked once per batch when at least
        // one record was applied. Hook throws count as one additional conflict
        // but never abort the cycle. Hook writes carry origin == .local and
        // flow into the outbox (hook-writes-must-ship, Kong Q2).
        if appliedCount > 0 {
            let batch = AppliedBatch(
                storage: storage,
                appliedByTable: appliedByTable,
                deletedByTable: deletedByTable
            )
            conflicts += await invokeIntegrityHook(manifest.postApplyIntegrityHook, batch: batch)
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
