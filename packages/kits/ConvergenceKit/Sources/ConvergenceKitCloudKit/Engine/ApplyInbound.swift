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
    func applyInbound(
        _ decoded: DecodedRecord,
        syncedTable: SyncedTable,
        storage: any Storage
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
            case .lastWriterWinsByHLC:
                // LWW gate: a stale tombstone (incoming HLC < local `_ck_sync_meta` HLC)
                // must not delete a newer local row (D2 fix).
                let localHLC = try await readSyncHLC(
                    storage: storage, table: decoded.table,
                    primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn)
                if let localHLC, decoded.hlc < localHLC {
                    return // stale tombstone — local is newer, keep the row
                }
                let predicate = StoragePredicate.eq(
                    Column(table: decoded.table, name: syncedTable.primaryKeyColumn),
                    .uuid(decoded.rowKey)
                )
                _ = try? await storage.rowStore.deleteSync(table: decoded.table, where: predicate)
                // A6: persist tombstone HLC in _ck_sync_meta after hard-delete so
                // subsequent stale inserts for this (table, rowKey) are still gated.
                try await writeTombstoneHLC(
                    storage: storage, table: decoded.table,
                    primaryKey: decoded.rowKey,
                    hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                    kitID: decoded.syncMeta.kitID)

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
                _ = try? await storage.rowStore.deleteSync(table: decoded.table, where: predicate)
                // Clear column-grain side table entries — row is gone.
                try? await ColumnHLCStore.clearAll(
                    from: storage, sideTable: CKSideSchema.syncMetaColsTable,
                    tableName: decoded.table, primaryKey: decoded.rowKey)
                // A6: persist tombstone HLC in _ck_sync_meta for stale-resurrect guard.
                try await writeTombstoneHLC(
                    storage: storage, table: decoded.table,
                    primaryKey: decoded.rowKey,
                    hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                    kitID: decoded.syncMeta.kitID)
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

        // Primary-key type coercion (P4-M1 harness finding): CKRecord fields are
        // lossy for the uuid/text discriminator — CKRecordMapping stores .uuid as
        // an NSString and decodes it back as .text. Without coercion, a pulled
        // row lands with a .text primary key while locally-written rows carry
        // .uuid, so upsert conflict detection misses the existing row and the
        // receiver DUPLICATES it, and tombstone delete predicates (.uuid) miss
        // pulled rows entirely. The recordName IS the row UUID (decoded.rowKey),
        // so restoring the PK's uuid type here is exact, not heuristic. Full
        // non-PK uuid-column fidelity through CKRecord is scoped in P4-M2.
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
            let localHLC = try await readSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn)
            if let localHLC, decoded.hlc < localHLC {
                return // local is newer — skip remote
            }
            _ = try await storage.rowStore.upsertSync(
                table: decoded.table,
                values: inboundValues,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )
            // Persist the sync HLC in the side table for future comparisons.
            try await writeSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn,
                hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                kitID: decoded.syncMeta.kitID)

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

            if !columnsToApply.isEmpty {
                // Apply only the winning columns as an upsert on the primary key.
                // This writes a partial row update — PersistenceKit's upsert preserves
                // columns not included in `columnsToApply`.
                var upsertValues = columnsToApply
                upsertValues[syncedTable.primaryKeyColumn] = .uuid(decoded.rowKey)
                _ = try await storage.rowStore.upsertSync(
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
                    to: storage, sideTable: CKSideSchema.syncMetaColsTable,
                    tableName: decoded.table, primaryKey: decoded.rowKey)
            }

            // Also update the row-grain HLC in _ck_sync_meta when this record's
            // row HLC is newer. This guards against stale-resurrect at the row grain
            // when a peer sends a delete for this row after a fieldLevelLWW write.
            let existingRowHLC = try await readSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn)
            if existingRowHLC == nil || decoded.hlc > (existingRowHLC ?? decoded.hlc) {
                try await writeSyncHLC(
                    storage: storage, table: decoded.table,
                    primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn,
                    hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                    kitID: decoded.syncMeta.kitID)
            }
        }
    }
}
