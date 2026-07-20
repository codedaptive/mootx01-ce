// ApplyInbound.swift
//
// Conflict-policy apply switch for CloudKitStateActor. Dispatches
// each inbound DecodedRecord to the correct persistence strategy
// based on the SyncedTable's configured ConflictPolicy.

import Foundation
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
import os

// File-scoped logger for apply-inbound diagnostics. Uses the same subsystem
// and category as the parent actor so all CloudKit engine events appear
// under one filter in Console.app.
private let applyLogger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "Engine")

extension CloudKitStateActor {

    // Internal (not private) so the LWW tests can call it directly
    // via @testable import without going through the CloudKit stack.
    //
    // `preloadedSyncHLCs`: optional batch-preloaded map of "\(table)|\(rowKey.uuidString)"
    // → HLC, produced by SyncMetaStore.readSyncHLCs(batch:) in PullCycle.pull() before
    // the apply loop. When present, _ck_sync_meta lookups for the LWW gate consult the
    // map instead of issuing a per-row query — reducing pull-cycle storage I/O from O(N)
    // queries to 1 batch query + O(N) dict lookups (CVK-WB5 perf Q5).
    //
    // Direct callers (LWW tests, skew replay) omit this parameter (default nil) and fall
    // back to the per-row readSyncHLC path, preserving unchanged semantics.
    func applyInbound(
        _ decoded: DecodedRecord,
        syncedTable: SyncedTable,
        storage: any Storage,
        preloadedSyncHLCs: [String: HLC]? = nil
    ) async throws {
        // All writes use the sync-tagged variants (upsertSync / insertSync /
        // deleteSync) so the emitted TableChange carries origin: .syncApply.
        // CloudKitStateActor's recordOutbound discards .syncApply changes,
        // preventing the echo loop (I-10).

        // Tombstone path: delete the local row through the standard LWW gate and
        // persist the delete HLC in _ck_sync_meta (A6 adjudication). The tombstone
        // HLC outlives the row so subsequent stale inserts with older HLCs are
        // rejected — even after the row itself is gone from the application table.
        if decoded.isTombstone {
            switch syncedTable.conflictPolicy {
            case .appendOnly:
                // Append-only tables are write-once; silently reject remote deletes.
                return
            case .localWins:
                // Local state is authoritative; silently reject remote deletes.
                return
            case .remoteWins:
                // Remote delete wins unconditionally.
                let predicate = StoragePredicate.eq(
                    Column(table: decoded.table, name: syncedTable.primaryKeyColumn),
                    .uuid(decoded.rowKey)
                )
                _ = try? await storage.rowStore.deleteSync(table: decoded.table, where: predicate)
                // P5-M1b: purge stale skew-queue and parked-outbox payloads for this row.
                // remoteWins has no HLC gate — tombstone applies unconditionally — so purge
                // all older skew entries (any HLC < the tombstone's HLC) and all parked outbox entries.
                let tombstoneHLCRW = PackedHLC(decoded.syncMeta.hlc)
                _ = try? await PendingSkewQueue.deleteMatchingOlderThan(
                    tableName: decoded.table, rowKey: decoded.rowKey,
                    tombstoneHLC: tombstoneHLCRW,
                    from: storage, sideTable: CKSideSchema.pendingSkewTable)
                _ = try? await OutboxStore.deleteMatchingParked(
                    tableName: decoded.table, rowKey: decoded.rowKey.uuidString, from: storage)
            case .lastWriterWinsByHLC:
                // LWW gate: a stale tombstone (incoming HLC < local `_ck_sync_meta` HLC)
                // must not delete a newer local row (D2 fix).
                let localHLC = try await cachedOrReadSyncHLC(
                    table: decoded.table, rowKey: decoded.rowKey,
                    pkColumn: syncedTable.primaryKeyColumn,
                    storage: storage, preloaded: preloadedSyncHLCs)
                if let localHLC, decoded.hlc < localHLC {
                    return // stale tombstone — local is newer, keep the row
                }
                let predicate = StoragePredicate.eq(
                    Column(table: decoded.table, name: syncedTable.primaryKeyColumn),
                    .uuid(decoded.rowKey)
                )
                // N1 fix: the hard-delete and the tombstone-HLC bookkeeping write
                // commit as ONE transaction. Previously these were two separate
                // top-level `await` calls; a crash/kill between them could leave
                // the row deleted with no tombstone HLC recorded in _ck_sync_meta,
                // defeating the A6 stale-resurrect guard (a later stale insert
                // would find `localHLC == nil` and resurrect the row).
                //
                // The delete keeps its pre-existing `try?` (best-effort) semantics
                // inside the transaction — a delete failure here is swallowed the
                // same way it always was, it just now happens inside the same
                // atomic unit as the tombstone-HLC write instead of before it.
                try await storage.transaction(isolation: .serializable) { txn in
                    _ = try? await txn.rowStore.deleteSync(table: decoded.table, where: predicate)
                    // A6: persist tombstone HLC in _ck_sync_meta after hard-delete so
                    // subsequent stale inserts for this (table, rowKey) are still gated.
                    try await self.writeTombstoneHLC(
                        storage: txn, table: decoded.table,
                        primaryKey: decoded.rowKey,
                        hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                        kitID: decoded.syncMeta.kitID)
                }
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // The tombstone has won the LWW gate; any pending-skew entries whose
                // record HLC is older than the tombstone are already superseded and
                // would be rejected by the same gate on replay. Parked outbox entries
                // for this row will never be pushed (is_parked = 1) — retaining them
                // after the row is deleted is indefinite payload retention (Perkins P4-M4).
                // These purges remain outside the transaction: they are a separate,
                // already best-effort (`try?`) storage-reclaim concern (skew queue /
                // outbox), not part of the value+HLC correctness gate this fix closes.
                let tombstoneHLCLWW = PackedHLC(decoded.syncMeta.hlc)
                _ = try? await PendingSkewQueue.deleteMatchingOlderThan(
                    tableName: decoded.table, rowKey: decoded.rowKey,
                    tombstoneHLC: tombstoneHLCLWW,
                    from: storage, sideTable: CKSideSchema.pendingSkewTable)
                _ = try? await OutboxStore.deleteMatchingParked(
                    tableName: decoded.table, rowKey: decoded.rowKey.uuidString, from: storage)

            case .fieldLevelLWW:
                // Tombstone interplay: edit-beats-delete rule.
                // The tombstone wins only when its HLC is >= ALL local per-column
                // HLCs. If any column was written after the delete (local column HLC
                // > tombstone HLC), the row survives.
                let localColumnHLCs = try await ColumnHLCStore.readAll(
                    from: storage, sideTable: CKSideSchema.syncMetaColsTable,
                    tableName: decoded.table, primaryKey: decoded.rowKey)
                let tombstoneHLC = PackedHLC(decoded.syncMeta.hlc)
                if !FieldLWWMerge.tombstoneWins(
                    tombstoneHLC: tombstoneHLC, localColumnHLCs: localColumnHLCs) {
                    return // edit-beats-delete: a local column was written later
                }
                // Tombstone wins: hard-delete the row and clear column HLC side table.
                let predicate = StoragePredicate.eq(
                    Column(table: decoded.table, name: syncedTable.primaryKeyColumn),
                    .uuid(decoded.rowKey)
                )
                // N1 fix: the hard-delete, the column-HLC side-table clear, and the
                // row-grain tombstone-HLC write commit as ONE transaction. Previously
                // these were three separate top-level `await` calls; a crash/kill
                // between any two of them could leave a deleted row with stale
                // column-HLC entries still on record (confusing a future re-insert
                // under fieldLevelLWW) or with no tombstone HLC in _ck_sync_meta
                // (defeating the A6 stale-resurrect guard).
                //
                // The delete and the column-HLC clear keep their pre-existing `try?`
                // (best-effort) semantics inside the transaction — a failure there
                // is swallowed exactly as before, just now inside the same atomic
                // unit as the tombstone-HLC write instead of before it.
                try await storage.transaction(isolation: .serializable) { txn in
                    _ = try? await txn.rowStore.deleteSync(table: decoded.table, where: predicate)
                    // Clear column-grain side table entries — row is gone.
                    try? await ColumnHLCStore.clearAll(
                        from: txn, sideTable: CKSideSchema.syncMetaColsTable,
                        tableName: decoded.table, primaryKey: decoded.rowKey)
                    // A6: persist tombstone HLC in _ck_sync_meta for stale-resurrect guard.
                    try await self.writeTombstoneHLC(
                        storage: txn, table: decoded.table,
                        primaryKey: decoded.rowKey,
                        hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                        kitID: decoded.syncMeta.kitID)
                }
                // P5-M1b: purge stale skew-queue entries and parked outbox entries.
                // tombstoneHLC is already declared above in this arm; reuse it.
                // These purges remain outside the transaction — see the identical
                // note in the .lastWriterWinsByHLC tombstone arm above.
                _ = try? await PendingSkewQueue.deleteMatchingOlderThan(
                    tableName: decoded.table, rowKey: decoded.rowKey,
                    tombstoneHLC: tombstoneHLC,
                    from: storage, sideTable: CKSideSchema.pendingSkewTable)
                _ = try? await OutboxStore.deleteMatchingParked(
                    tableName: decoded.table, rowKey: decoded.rowKey.uuidString, from: storage)
            }
            return
        }

        // Normal (non-tombstone) apply path.

        // Inbound projection (R2, CVK-ICLOUD P2-M2): drop excluded columns before
        // the conflict-policy switch. A peer on a different manifest version may
        // send columns this manifest marks excluded. Writing them would overwrite
        // locally-computed derived values with stale remote copies, defeating
        // the purpose of projection.
        var inboundValues: [String: TypedValue]
        if !syncedTable.excludedColumns.isEmpty {
            let droppedKeys = decoded.values.keys.filter { syncedTable.excludedColumns.contains($0) }
            if !droppedKeys.isEmpty {
                let keyList = droppedKeys.sorted().joined(separator: ", ")
                applyLogger.warning("inbound projection: dropping \(droppedKeys.count) excluded column(s) for table '\(syncedTable.name)': \(keyList)")
            }
            inboundValues = Projection.outboundStrip(
                values: decoded.values,
                excluded: syncedTable.excludedColumns
            )
        } else {
            inboundValues = decoded.values
        }

        // Primary-key type coercion (belt-and-braces after P4-M2 tag-map fix):
        // CKRecordMapping now writes a _syncTypeTags map that restores .uuid
        // discriminators for ALL columns — including the primary key — during
        // decode (P4-M2). This coercion retains the PK specifically because the
        // rowKey is authoritative (derived from the CKRecord.ID, not from the
        // decoded column value), making the coerce exact and not heuristic.
        // Without this line, records from older peers that lack _syncTypeTags
        // would still land with a .text PK and fail upsert deduplication.
        // Belt-and-braces: keep this coercion even when the tag map is present
        // so the PK is always correct regardless of peer encoder version.
        inboundValues[syncedTable.primaryKeyColumn] = .uuid(decoded.rowKey)

        switch syncedTable.conflictPolicy {
        case .appendOnly:
            // Audit log style. Idempotent upsert with the row key as primary.
            _ = try await storage.rowStore.upsertSync(
                table: decoded.table,
                values: inboundValues,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .lastWriterWinsByHLC:
            // LWW comparison reads the persisted HLC from the _ck_sync_meta side
            // table. If the remote HLC is older than the local HLC, the remote record
            // is skipped (the local row is newer). The side table entry exists even
            // after a delete (tombstone HLC), so a stale resurrect is also gated.
            let localHLC = try await cachedOrReadSyncHLC(
                table: decoded.table, rowKey: decoded.rowKey,
                pkColumn: syncedTable.primaryKeyColumn,
                storage: storage, preloaded: preloadedSyncHLCs)
            if let localHLC, decoded.hlc < localHLC {
                return // local is newer — skip remote
            }
            // N1 fix: the value upsert and the sync-HLC bookkeeping write commit as
            // ONE transaction. Previously these were two separate top-level `await`
            // calls; a crash/kill between them could leave a committed value row
            // with a stale (or missing) `_ck_sync_meta` HLC, letting a later stale
            // edit silently overwrite the newer value (the exact N1 failure mode).
            //
            // `inboundValues` is snapshotted into a `let` here (rather than captured
            // directly) because it is a `var` — a `var` cannot be captured by the
            // `@Sendable` transaction closure below (Swift 6 strict concurrency).
            let inboundValuesForWrite = inboundValues
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try await txn.rowStore.upsertSync(
                    table: decoded.table,
                    values: inboundValuesForWrite,
                    conflictColumns: [syncedTable.primaryKeyColumn]
                )
                // Persist the sync HLC in the side table for future comparisons.
                try await self.writeSyncHLC(
                    storage: txn, table: decoded.table,
                    primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn,
                    hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                    kitID: decoded.syncMeta.kitID)
            }

        case .remoteWins:
            _ = try await storage.rowStore.upsertSync(
                table: decoded.table,
                values: inboundValues,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .localWins:
            // Only insert if no row exists.
            let existing = try? await storage.rowStore.count(
                table: decoded.table,
                where: .eq(Column(table: decoded.table, name: syncedTable.primaryKeyColumn), .uuid(decoded.rowKey))
            )
            if (existing ?? 0) == 0 {
                _ = try await storage.rowStore.insertSync(table: decoded.table, values: inboundValues)
            }

        case .fieldLevelLWW:
            // Gap 2 fix: reject a stale edit that predates a recorded row-grain
            // tombstone. Without this, a column's absence from ColumnHLCStore
            // (either genuinely never-written, OR wiped by the tombstone arm's
            // ColumnHLCStore.clearAll) is indistinguishable to FieldLWWMerge.merge
            // — its "no local HLC recorded" fallback treats the stale edit as a
            // first-ever write and applies it unconditionally, resurrecting a
            // row that was correctly deleted. Trigger-agnostic: reproducible via
            // ordinary clock skew or a 3-device race, no crash required (P4.5).
            //
            // Strict `<` — matching the existing `.lastWriterWinsByHLC` gates
            // above (both the tombstone-apply gate and the normal-apply gate):
            // an edit STRICTLY older than the tombstone is rejected; an edit at
            // or after the tombstone HLC proceeds to a normal apply below,
            // correctly resurrecting the row when the edit is a genuine
            // post-delete revival. Getting this boundary wrong in either
            // direction is a data-loss bug (over-reject) or a zombie-row bug
            // (under-reject) — both directions are covered by dedicated tests.
            if let tombstoneHLC = try await readTombstoneHLC(
                storage: storage, table: decoded.table, primaryKey: decoded.rowKey),
               decoded.hlc < tombstoneHLC {
                return // stale-before-tombstone edit — row stays deleted, no resurrection
            }

            // Per-column LWW apply. Read local column HLCs from the side table,
            // compute which incoming columns win, apply them, and persist the
            // updated column HLC map. See FieldLWWMerge for the commutativity proof.
            let localColumnHLCs = try await ColumnHLCStore.readAll(
                from: storage, sideTable: CKSideSchema.syncMetaColsTable,
                tableName: decoded.table, primaryKey: decoded.rowKey)

            // Wire-carried column HLCs (A7: receiver must not fabricate them).
            // Fall back to empty map when absent (backward-compat with older senders).
            let incomingColumnHLCs = decoded.columnHLCs ?? ColumnHLCMap()
            let incomingRowHLC = PackedHLC(decoded.syncMeta.hlc)

            let (columnsToApply, updatedColumnHLCs) = FieldLWWMerge.merge(
                incomingValues: decoded.values,
                incomingColumnHLCs: incomingColumnHLCs,
                incomingRowHLC: incomingRowHLC,
                localColumnHLCs: localColumnHLCs
            )

            // Also update the row-grain HLC in _ck_sync_meta when this record's
            // row HLC is newer. This guards against stale-resurrect at the row grain
            // when a peer sends a delete for this row after a fieldLevelLWW write.
            // Read BEFORE the write transaction below — this decision is independent
            // of (does not read back) any of the writes the transaction makes.
            let existingRowHLC = try await cachedOrReadSyncHLC(
                table: decoded.table, rowKey: decoded.rowKey,
                pkColumn: syncedTable.primaryKeyColumn,
                storage: storage, preloaded: preloadedSyncHLCs)
            let rowHLCIsNewer = existingRowHLC == nil || decoded.hlc > (existingRowHLC ?? decoded.hlc)

            // N1 fix: the winning-column value upsert, the column-HLC bookkeeping
            // write, and the (conditional) row-grain HLC bookkeeping write all
            // commit as ONE transaction. Previously these were up to three separate
            // top-level `await` calls; a crash/kill between any two of them could
            // leave a committed value row with stale (or missing) HLC bookkeeping
            // in either side table, letting a later stale edit silently overwrite
            // the newer value (the exact N1 failure mode).
            try await storage.transaction(isolation: .serializable) { txn in
                if !columnsToApply.isEmpty {
                    // Apply only the winning columns as an upsert on the primary key.
                    // This writes a partial row update — PersistenceKit's upsert preserves
                    // columns not included in `columnsToApply`.
                    var upsertValues = columnsToApply
                    upsertValues[syncedTable.primaryKeyColumn] = .uuid(decoded.rowKey)
                    _ = try await txn.rowStore.upsertSync(
                        table: decoded.table,
                        values: upsertValues,
                        conflictColumns: [syncedTable.primaryKeyColumn]
                    )
                }

                // Persist updated column HLCs regardless of whether any columns were
                // applied. The map may be updated even when no columns win (e.g., the
                // incoming HLC ties with local, updating the stored HLC to the incoming).
                if !updatedColumnHLCs.isEmpty {
                    try await ColumnHLCStore.writeAll(
                        map: updatedColumnHLCs,
                        to: txn, sideTable: CKSideSchema.syncMetaColsTable,
                        tableName: decoded.table, primaryKey: decoded.rowKey)
                }

                if rowHLCIsNewer {
                    try await self.writeSyncHLC(
                        storage: txn, table: decoded.table,
                        primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn,
                        hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                        kitID: decoded.syncMeta.kitID)
                }
            }
        }
    }

    // MARK: - Private helpers

    /// Return the sync HLC for (table, rowKey) from the preloaded map when available,
    /// falling back to a per-row `_ck_sync_meta` query when the map is absent.
    ///
    /// WHY this indirection:
    /// The pull cycle pre-loads `_ck_sync_meta` for the entire batch via
    /// `readSyncHLCs(batch:)` (one query) and passes the result as
    /// `preloadedSyncHLCs`. Inside `applyInbound`, all three LWW-gated paths call
    /// this helper instead of `readSyncHLC` directly, so the batch path pays zero
    /// extra queries while the fallback path (tests, skew replay, direct calls)
    /// retains the original single-row semantics without any change to their callers.
    ///
    /// Key format mirrors `readSyncHLCs`: `"\(table)|\(rowKey.uuidString)"`.
    private func cachedOrReadSyncHLC(
        table: String, rowKey: UUID, pkColumn: String,
        storage: any Storage,
        preloaded: [String: HLC]?
    ) async throws -> HLC? {
        if let preloaded {
            // Key absent → no entry in _ck_sync_meta (same semantic as nil from readSyncHLC).
            return preloaded["\(table)|\(rowKey.uuidString)"]
        }
        return try await readSyncHLC(storage: storage, table: table, primaryKey: rowKey, pkColumn: pkColumn)
    }
}
