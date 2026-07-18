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
    ///
    /// Single-row path. Used by direct callers (tests, skew replay). For the
    /// CloudKit pull loop, prefer `readSyncHLCs(batch:)` to amortise the query
    /// cost across the entire batch.
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

    /// Batch-read sync HLCs for a set of (table, rowKey) pairs in one query.
    ///
    /// Used by `PullCycle.pull()` to pre-load `_ck_sync_meta` for the entire
    /// inbound batch before the per-record apply loop, reducing pull-cycle storage
    /// I/O from O(N) queries to 1 query + O(N) in-memory lookups (CVK-WB5 perf Q5).
    ///
    /// - Returns: A dictionary keyed by `"\(table)|\(rowKey.uuidString)"`.
    ///   A key's presence means a sync HLC was found; absent key means no entry
    ///   (equivalent to `nil` from `readSyncHLC`).
    ///
    /// - Note: The query uses `primary_key IN [...]` so it fetches in one round-trip.
    ///   Results are then grouped by `(table_name, primary_key)` in Swift for
    ///   correctness across tables that share a row UUID (extremely unlikely in
    ///   practice, but the composite primary key of `_ck_sync_meta` requires it).
    func readSyncHLCs(
        batch: [(table: String, rowKey: UUID)],
        storage: any Storage
    ) async throws -> [String: HLC] {
        guard !batch.isEmpty else { return [:] }

        // Collect unique primary_key strings for the IN predicate.
        // Distinct de-duplication is unnecessary — the IN clause handles repeats.
        let primaryKeyValues = batch.map { TypedValue.text($0.rowKey.uuidString) }

        // One query: WHERE primary_key IN (...). Rows from different tables that
        // happen to share the same UUID are filtered by table_name in Swift below.
        let rows = try await storage.rowStore.query(
            table: Self.syncMetaTable,
            where: .in(Column(table: Self.syncMetaTable, name: "primary_key"), primaryKeyValues)
        )

        // Build the result dictionary. Key format: "\(table_name)|\(primary_key)".
        var result: [String: HLC] = [:]
        for row in rows {
            guard
                case .text(let tableName)  = row["table_name"],
                case .text(let primaryKey) = row["primary_key"],
                case .int(let packed)      = row["sync_hlc"]
            else { continue }
            let key = "\(tableName)|\(primaryKey)"
            result[key] = HLC(packed: UInt64(bitPattern: packed))
        }
        return result
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
