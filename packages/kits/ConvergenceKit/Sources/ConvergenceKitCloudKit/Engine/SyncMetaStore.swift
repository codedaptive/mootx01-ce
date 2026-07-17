// SyncMetaStore.swift
//
// _ck_sync_meta side table management for CloudKitStateActor.
// Provides ensure/read/write operations for the HLC-keyed row
// metadata used by the lastWriterWinsByHLC conflict policy (#12).

import Foundation
import ConvergenceKit
import PersistenceKit
import SubstrateTypes

// MARK: - Sync metadata side table (#12)

extension CloudKitStateActor {

    /// Side table name. The declaration lives in CKSideSchema (B-12
    /// governance); this alias keeps local read/write helpers readable.
    private static let syncMetaTable = CKSideSchema.syncMetaTable

    /// Ensure ALL ConvergenceKit side tables exist. Delegates to CKSideSchema,
    /// which owns the single consolidated SchemaDeclaration (kitID
    /// "ConvergenceKit", version counter covers _ck_sync_meta at v1 and
    /// _ck_outbox at v2). See SideSchema.swift for the governance rationale.
    ///
    /// Kept as a static func (not inlined at the enable() call site) so the
    /// call signature is stable for tests that exercise the ensure path.
    static func ensureSyncMetaTable(storage: any Storage) async throws {
        try await CKSideSchema.ensure(storage: storage)
    }

    /// Read the persisted sync HLC for a specific row.
    func readSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String
    ) async throws -> HLC? {
        let rows = try await storage.rowStore.query(
            table: Self.syncMetaTable,
            where: .and([
                .eq(Column(table: Self.syncMetaTable, name: "table_name"), .text(table)),
                .eq(Column(table: Self.syncMetaTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
        guard let row = rows.first,
              case .int(let packed) = row["sync_hlc"] else { return nil }
        return HLC(packed: UInt64(bitPattern: packed))
    }

    /// Persist the sync HLC for a specific row after a successful upsert.
    /// Sets `is_deleted = 0` (live row, not a tombstone).
    func writeSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await storage.rowStore.upsertSync(
            table: Self.syncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc": .int(Int64(bitPattern: hlc.packed)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID),
                "is_deleted": .int(0)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }

    /// Persist the delete HLC in `_ck_sync_meta` after a hard-delete (A6).
    ///
    /// WHY the tombstone HLC must persist after the row is gone:
    /// a stale insert or upsert for the same (table, rowKey) arriving
    /// after the delete would find `localHLC = nil` if the side table entry
    /// were removed, accept the write, and resurrect the deleted row.
    /// Keeping the tombstone HLC blocks stale resurrections via the standard
    /// LWW gate. A newer insert (higher HLC) is still allowed — the gate
    /// only blocks HLCs strictly older than the tombstone (intentional
    /// recreate). The entry is eligible for GC after
    /// `SyncTombstone.gcRetentionSeconds`.
    func writeTombstoneHLC(
        storage: any Storage, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await storage.rowStore.upsertSync(
            table: Self.syncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc": .int(Int64(bitPattern: hlc.packed)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID),
                "is_deleted": .int(1)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }
}
