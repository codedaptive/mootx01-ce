// ApplyInbound.swift
//
// Conflict-policy apply switch for CloudKitStateActor. Dispatches
// each inbound DecodedRecord to the correct persistence strategy
// based on the SyncedTable's configured ConflictPolicy.

import Foundation
import ConvergenceKit
import PersistenceKit
import SubstrateTypes

extension CloudKitStateActor {

    // Internal (not private) so the LWW tests can call it directly
    // via @testable import without going through the CloudKit stack.
    func applyInbound(
        _ decoded: DecodedRecord,
        syncedTable: SyncedTable,
        storage: any Storage
    ) async throws {
        switch syncedTable.conflictPolicy {
        case .appendOnly:
            // Audit log style. Idempotent upsert with the row key as primary.
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .lastWriterWinsByHLC:
            // (#12) LWW comparison reads the persisted HLC from the
            // _ck_sync_meta side table. If the remote HLC is older than
            // the local HLC, the remote record is skipped (the local row
            // is newer). The side table is created at engine init so it
            // exists on all backends (SQLite, PG, InMemory).
            let localHLC = try await readSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn)
            if let localHLC, decoded.hlc < localHLC {
                return // local is newer — skip remote
            }
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )
            // Persist the sync HLC in the side table for future comparisons.
            try await writeSyncHLC(
                storage: storage, table: decoded.table,
                primaryKey: decoded.rowKey, pkColumn: syncedTable.primaryKeyColumn,
                hlc: decoded.syncMeta.hlc, schemaVersion: decoded.syncMeta.schemaVersion,
                kitID: decoded.syncMeta.kitID)

        case .remoteWins:
            _ = try await storage.rowStore.upsert(
                table: decoded.table,
                values: decoded.values,
                conflictColumns: [syncedTable.primaryKeyColumn]
            )

        case .localWins:
            // Only insert if no row exists.
            let existing = try? await storage.rowStore.count(
                table: decoded.table,
                where: .eq(Column(table: decoded.table, name: syncedTable.primaryKeyColumn), .uuid(decoded.rowKey))
            )
            if (existing ?? 0) == 0 {
                _ = try await storage.rowStore.insert(table: decoded.table, values: decoded.values)
            }
        }
    }
}
