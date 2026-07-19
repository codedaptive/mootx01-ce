// SyncMetaStore.swift
//
// _ck_sync_meta side table management for CloudKitStateActor.
// Provides ensure/read/write operations for the HLC-keyed row
// metadata used by the lastWriterWinsByHLC conflict policy (#12).
//
// GAP 6 (2026-07, D38.1): reads/writes the full-width `sync_hlc_wire` BLOB
// (HLC.wireBytes) instead of the legacy 40-bit-truncated `sync_hlc` packed
// column. `_ck_sync_meta` is the ONE gap-6 carrier with real shipped
// v1.0.33 data; `CKSideSchema.ensure(storage:)` runs a one-time BACKFILL
// (`backfillSyncHLCWireIfNeeded`) that reconstructs `sync_hlc_wire` from the
// legacy `sync_hlc` value — see `LegacyPackedHLCMigration.swift` for the
// recoverability proof and `SideSchema.swift`'s v9→v10 migration for the
// backfill call site. By the time any function below runs, every row
// already has `sync_hlc_wire` populated (backfilled or freshly written);
// callers do not need to fall back to `sync_hlc`.

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
              case .blob(let wire) = row["sync_hlc_wire"],
              let hlc = try? HLC(wireBytes: [UInt8](wire)) else { return nil }
        return hlc
    }

    /// Read the row-grain tombstone HLC for a specific row — ONLY if that row
    /// is currently tombstoned (`is_deleted == 1`). Returns `nil` when there is
    /// no `_ck_sync_meta` entry at all, OR when an entry exists but the row is
    /// live (`is_deleted == 0`) — in both cases there is no active tombstone to
    /// gate against.
    ///
    /// Gap 2 fix: `ApplyInbound`'s `.fieldLevelLWW` normal-apply arm has no
    /// visibility, from `ColumnHLCStore` alone, into whether a column's absence
    /// means "never written" or "history cleared by a tombstone"
    /// (`ColumnHLCStore.clearAll` wipes ALL column entries when a tombstone
    /// wins — see the `.fieldLevelLWW` tombstone arm above). Without this
    /// row-grain check, a stale edit that predates a delete is indistinguishable
    /// from a first-ever write and gets applied, resurrecting a correctly-deleted
    /// row. The row-grain tombstone HLC survives the delete specifically for
    /// this purpose (A6) and is untouched by the gap-3 fix (which only ever
    /// writes ColumnHLCStore on local writes, never `_ck_sync_meta`'s
    /// `is_deleted` flag) — it remains the reliable signal.
    ///
    /// Distinct from `readSyncHLC`, which returns the row-grain HLC
    /// unconditionally (used by `.lastWriterWinsByHLC`, where a single
    /// whole-row HLC comparison is always the correct gate — no per-column
    /// ambiguity exists there). Gating `.fieldLevelLWW`'s column merge on the
    /// UNCONDITIONAL row-grain HLC instead of ONLY the tombstone case would be
    /// wrong in the other direction: it would reject a legitimate concurrent
    /// edit to a DIFFERENT column merely because some other column in the same
    /// row was touched more recently, defeating fieldLevelLWW's whole purpose
    /// (independent per-column conflict resolution).
    func readTombstoneHLC(
        storage: any Storage, table: String, primaryKey: UUID
    ) async throws -> HLC? {
        let rows = try await storage.rowStore.query(
            table: Self.syncMetaTable,
            where: .and([
                .eq(Column(table: Self.syncMetaTable, name: "table_name"), .text(table)),
                .eq(Column(table: Self.syncMetaTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
        guard let row = rows.first,
              case .int(let isDeleted) = row["is_deleted"], isDeleted == 1,
              case .blob(let wire) = row["sync_hlc_wire"],
              let hlc = try? HLC(wireBytes: [UInt8](wire)) else { return nil }
        return hlc
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
                case .blob(let wire)       = row["sync_hlc_wire"],
                let hlc = try? HLC(wireBytes: [UInt8](wire))
            else { continue }
            let key = "\(tableName)|\(primaryKey)"
            result[key] = hlc
        }
        return result
    }

    /// Persist the sync HLC for a specific row after a successful upsert.
    /// Sets `is_deleted = 0` (live row, not a tombstone).
    func writeSyncHLC(
        storage: any Storage, table: String, primaryKey: UUID, pkColumn: String,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        try await writeSyncHLC(rowStore: storage.rowStore, table: table, primaryKey: primaryKey,
                                pkColumn: pkColumn, hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Transactional variant of `writeSyncHLC(storage:table:primaryKey:pkColumn:hlc:schemaVersion:kitID:)`.
    ///
    /// N1 fix: `ApplyInbound`'s `.lastWriterWinsByHLC` and `.fieldLevelLWW` arms
    /// call this overload from inside an open `storage.transaction { txn in ... }`
    /// block so the row-grain HLC bookkeeping write commits atomically with the
    /// application-row value write. Previously these were two separate top-level
    /// `await` calls; a crash/kill between them could leave a committed value
    /// row with a stale (or missing) `_ck_sync_meta` HLC, letting a later stale
    /// edit silently overwrite the newer value.
    func writeSyncHLC(
        storage transaction: any StorageTransaction, table: String, primaryKey: UUID, pkColumn: String,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        try await writeSyncHLC(rowStore: transaction.rowStore, table: table, primaryKey: primaryKey,
                                pkColumn: pkColumn, hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Shared implementation — both overloads above only ever touch `.rowStore`.
    private func writeSyncHLC(
        rowStore: any RowStore, table: String, primaryKey: UUID, pkColumn: String,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await rowStore.upsertSync(
            table: Self.syncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc_wire": .blob(Data(hlc.wireBytes)),
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
        try await writeTombstoneHLC(rowStore: storage.rowStore, table: table, primaryKey: primaryKey,
                                     hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Transactional variant of `writeTombstoneHLC(storage:table:primaryKey:hlc:schemaVersion:kitID:)`.
    ///
    /// N1 fix: `ApplyInbound`'s `.lastWriterWinsByHLC` and `.fieldLevelLWW` tombstone
    /// arms call this overload from inside an open `storage.transaction { txn in ... }`
    /// block so the hard-delete of the application row and the persisted tombstone
    /// HLC commit atomically. Without this, a crash between the delete and this
    /// write could leave a deleted row with no tombstone HLC recorded, letting a
    /// later stale insert resurrect it (defeating the A6 stale-resurrect guard).
    func writeTombstoneHLC(
        storage transaction: any StorageTransaction, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        try await writeTombstoneHLC(rowStore: transaction.rowStore, table: table, primaryKey: primaryKey,
                                     hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
    }

    /// Shared implementation — both overloads above only ever touch `.rowStore`.
    private func writeTombstoneHLC(
        rowStore: any RowStore, table: String, primaryKey: UUID,
        hlc: HLC, schemaVersion: Int, kitID: String
    ) async throws {
        _ = try await rowStore.upsertSync(
            table: Self.syncMetaTable,
            values: [
                "table_name": .text(table),
                "primary_key": .text(primaryKey.uuidString),
                "sync_hlc_wire": .blob(Data(hlc.wireBytes)),
                "schema_version": .int(Int64(schemaVersion)),
                "kit_id": .text(kitID),
                "is_deleted": .int(1)
            ],
            conflictColumns: ["table_name", "primary_key"]
        )
    }
}
