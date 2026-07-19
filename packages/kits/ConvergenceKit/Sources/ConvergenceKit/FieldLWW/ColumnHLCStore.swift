// ColumnHLCStore.swift
//
// Stateless CRUD namespace for the `_*_sync_meta_cols` per-column HLC
// side tables used by the `fieldLevelLWW` conflict policy.
//
// SCHEMA (v10, gap 6 — full-width column HLC storage, D38.1 full-width-atomic
// scope — every carrier, uniform 16-byte wireBytes encoding):
//   table_name    TEXT NOT NULL — application table name
//   primary_key   TEXT NOT NULL — row UUID as TEXT
//   column_name   TEXT NOT NULL — application column name
//   col_hlc_wire  BLOB NOT NULL — HLC.wireBytes(hlc) / Rust wire_bytes(), the
//                                 already-lockstep-audited 16-byte lossless
//                                 wire format (HLC.swift:205-245): 8 bytes
//                                 physicalTime LE + 4 bytes logicalCount LE +
//                                 4 bytes nodeID LE. No bit-packing anywhere
//                                 in this encoding, so no truncation is
//                                 possible at ANY physicalTime magnitude.
//   col_hlc       INT  NOT NULL — LEGACY, retained for additive-migration safety
//                                 only. No longer read or meaningfully written
//                                 (always 0 for rows written after gap 6). Was:
//                                 packed HLC (Int64, same 40-bit-truncated layout
//                                 as _ck_sync_meta.sync_hlc) — see gap 6 below.
//   PRIMARY KEY (table_name, primary_key, column_name)
//
// GAP 6 — WHY col_hlc_wire REPLACED col_hlc (2026-07, D38.1):
// `col_hlc` stored the per-column HLC via `HLC.packed`/`HLC(packed:)`
// (HLC.swift:99-104), which bit-packs physicalTime into 40 bits
// (`phys = UInt64(physicalTime) & 0xFF_FFFF_FFFF`, max ~1.0995e12 ms). The
// WIRE format for the same value (`SyncRecord.swift`'s `PackedHLC`, used
// for `SyncRecord.columnHLCs`) stores `physicalTime` LOSSLESSLY (a plain
// Int64 field, no truncation). Real wall-clock `physicalTime` (ms since
// Unix epoch) has exceeded the 40-bit ceiling since ~2004 — so EVERY
// persisted column HLC was silently truncated to a much smaller number
// than the lossless wire value it was compared against in
// `FieldLWWMerge.merge` (FieldLWWMerge.swift:106), making
// `incomingColumnHLC >= local` evaluate true unconditionally regardless
// of true HLC order (whichever edit arrived last always won).
//
// D38.1 widened the fix from "this one table" to "every HLC carrier, both
// legs, one uniform encoding" after Kong found that a column-store-only fix
// regresses CloudKit deletes (edit-beats-delete): the row-grain tombstone
// HLC arrives via a STILL-truncated carrier while local column HLCs are now
// full-width, reproducing the exact same truncated-vs-lossless mismatch one
// level up. `HLC.wireBytes`/`HLC(wireBytes:)` — already Swift/Rust lockstep-
// audited (see HLC.swift:205-245) and already used elsewhere for lossless
// hashing (AuditGate.swift, UnifiedAuditLog.swift) — is reused verbatim as
// the ONE encoding for every carrier this gap touches, rather than inventing
// a different shape per table. `col_hlc` is kept in the schema (additive-
// only migration policy, see SideSchema.swift) but is dead: `ColumnHLCStore`
// no longer reads it, and only ever writes the SQL column default (0), via
// omission from the values map (SQL DEFAULT fills it in — see `writeAll`
// below).
//
// WHY one row per column (not a JSON blob in one row):
// Per-column rows enable point reads and partial upserts without
// deserialising the entire map. For a table with 50 columns and 10k
// rows, a targeted read for (table, rowKey, columnA) touches one row
// instead of decoding a 50-key JSON blob. Upsert-on-conflict replaces
// a single row when one column advances. The row count is bounded by
// (rows × columns_per_row) which is proportional to the existing
// application row count.
//
// WHY the table name is a parameter (not hardcoded):
// CloudKit uses `_ck_sync_meta_cols`; Federation uses `_fed_sync_meta_cols`.
// Both are declared by their respective schema owners (CKSideSchema v6
// and FederationStateActor v2). ColumnHLCStore is transport-agnostic
// and receives the table name from the caller.

import Foundation
import PersistenceKit
import SubstrateTypes

// MARK: - ColumnHLCStore

/// Stateless namespace for per-column HLC side-table CRUD.
///
/// Callers must ensure the target side table exists (via
/// `CKSideSchema.ensure(storage:)` or `ensureFedSyncMetaTable`) before
/// calling any of these functions.
public enum ColumnHLCStore {

    // MARK: - Read

    /// Read the ColumnHLCMap for a given (table, row) pair.
    ///
    /// Returns all (column_name, col_hlc_wire) rows matching
    /// the given `tableName` and `primaryKey`, decoded into a
    /// ColumnHLCMap. Returns an empty map if no entries exist (first
    /// write, or the row has never been written under fieldLevelLWW).
    ///
    /// Gap 6: reads the full-width `col_hlc_wire` BLOB directly — NOT the
    /// legacy `col_hlc` packed column, which truncates `physicalTime` to 40
    /// bits (see the file header comment for the full defect writeup). A
    /// row written before the v10 migration has `col_hlc_wire` absent (this
    /// is a develop/1.1.x-only table — CLEAN REGENERATE, no pre-existing
    /// data — confirmed absent from the shipped v1.0.33 tag), so it is
    /// skipped by the `case .blob` guard below exactly like a row that has
    /// never been written under fieldLevelLWW. This is intentional and
    /// self-healing: such a row is treated as "not yet observed" under
    /// full-width tracking, so the next incoming edit for that (table, row,
    /// column) always wins (correctly) and repopulates `col_hlc_wire` going
    /// forward.
    ///
    /// - Parameters:
    ///   - storage: PersistenceKit storage instance.
    ///   - sideTable: Name of the side table (e.g. `"_ck_sync_meta_cols"`).
    ///   - tableName: Application table name.
    ///   - primaryKey: Row UUID.
    /// - Returns: The per-column HLC map for this row, or an empty map.
    public static func readAll(
        from storage: any Storage,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws -> ColumnHLCMap {
        let rows = try await storage.rowStore.query(
            table: sideTable,
            where: .and([
                .eq(Column(table: sideTable, name: "table_name"), .text(tableName)),
                .eq(Column(table: sideTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
        var entries: [String: PackedHLC] = [:]
        for row in rows {
            guard
                case .text(let columnName) = row["column_name"],
                case .blob(let wire) = row["col_hlc_wire"],
                let hlc = try? HLC(wireBytes: [UInt8](wire))
            else { continue }
            entries[columnName] = PackedHLC(hlc)
        }
        return ColumnHLCMap(entries: entries)
    }

    // MARK: - Write

    /// Persist a ColumnHLCMap for a given (table, row) pair.
    ///
    /// Upserts one row per column (using the three-column PK on conflict).
    /// Existing entries for columns not in `map` are left unchanged;
    /// call `clearAll` first if you need to replace the entire map.
    ///
    /// - Parameters:
    ///   - map: The column HLC map to write. Empty map is a no-op.
    ///   - storage: PersistenceKit storage instance.
    ///   - sideTable: Name of the side table.
    ///   - tableName: Application table name.
    ///   - primaryKey: Row UUID.
    public static func writeAll(
        map: ColumnHLCMap,
        to storage: any Storage,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws {
        try await writeAll(map: map, to: storage.rowStore, sideTable: sideTable,
                            tableName: tableName, primaryKey: primaryKey)
    }

    /// Transactional variant of `writeAll(map:to:sideTable:tableName:primaryKey:)`.
    ///
    /// N1 fix: callers that must commit this write atomically with the
    /// application-row value write (e.g. `ApplyInbound`'s `.fieldLevelLWW` arm)
    /// call this overload from inside an open `storage.transaction { txn in ... }`
    /// block instead of the `any Storage` overload above. Both writes then land
    /// (or roll back) as one unit, closing the crash window where a value upsert
    /// commits without its column-HLC bookkeeping (or vice versa).
    public static func writeAll(
        map: ColumnHLCMap,
        to transaction: any StorageTransaction,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws {
        try await writeAll(map: map, to: transaction.rowStore, sideTable: sideTable,
                            tableName: tableName, primaryKey: primaryKey)
    }

    /// Shared implementation — both the `any Storage` and `any StorageTransaction`
    /// overloads above only ever touch `.rowStore`, so the actual write logic
    /// lives here once, keyed on the common `any RowStore` surface.
    ///
    /// Gap 6: writes the full-width `col_hlc_wire` BLOB directly from
    /// `HLC.wireBytes` — NOT `hlc.packed` (which truncates `physicalTime`
    /// to 40 bits; see the file header comment). The legacy `col_hlc`
    /// column is deliberately OMITTED from `values`: it is NOT NULL with a
    /// SQL DEFAULT of 0, so SQLite/Postgres/InMemory fill it in on INSERT
    /// without our having to write a now-meaningless value; on UPDATE
    /// (conflict) the existing `col_hlc` value, if any, is simply left
    /// untouched (upsertSync only SETs the columns present in `values`).
    private static func writeAll(
        map: ColumnHLCMap,
        to rowStore: any RowStore,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws {
        guard !map.isEmpty else { return }
        for (columnName, packedHLC) in map.entries {
            let hlc = packedHLC.asHLC
            _ = try await rowStore.upsertSync(
                table: sideTable,
                values: [
                    "table_name":  .text(tableName),
                    "primary_key": .text(primaryKey.uuidString),
                    "column_name": .text(columnName),
                    "col_hlc_wire": .blob(Data(hlc.wireBytes))
                ],
                conflictColumns: ["table_name", "primary_key", "column_name"]
            )
        }
    }

    // MARK: - Clear

    /// Delete all per-column HLC entries for a given (table, row) pair.
    ///
    /// Called when a row is hard-deleted: the column HLC side-table entries
    /// are no longer needed once the tombstone HLC is persisted in
    /// `_ck_sync_meta` / `_fed_sync_meta` (the row-grain side table guards
    /// against stale resurrects). Leaving stale column entries wastes space
    /// and could confuse a future re-insert under fieldLevelLWW.
    ///
    /// - Parameters:
    ///   - storage: PersistenceKit storage instance.
    ///   - sideTable: Name of the side table.
    ///   - tableName: Application table name.
    ///   - primaryKey: Row UUID.
    public static func clearAll(
        from storage: any Storage,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws {
        try await clearAll(from: storage.rowStore, sideTable: sideTable,
                            tableName: tableName, primaryKey: primaryKey)
    }

    /// Transactional variant of `clearAll(from:sideTable:tableName:primaryKey:)`.
    ///
    /// N1 fix: the `.fieldLevelLWW` tombstone arm in `ApplyInbound` clears the
    /// column-HLC side table in the SAME transaction as the row hard-delete and
    /// the tombstone-HLC write, so a crash between the three writes cannot leave
    /// stale column-HLC entries pointing at a row that no longer exists (or vice
    /// versa — a deleted-but-still-column-HLC-tagged row confusing a future
    /// re-insert under fieldLevelLWW).
    public static func clearAll(
        from transaction: any StorageTransaction,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws {
        try await clearAll(from: transaction.rowStore, sideTable: sideTable,
                            tableName: tableName, primaryKey: primaryKey)
    }

    /// Shared implementation — see the `writeAll` private overload above for
    /// the same rationale.
    private static func clearAll(
        from rowStore: any RowStore,
        sideTable: String,
        tableName: String,
        primaryKey: UUID
    ) async throws {
        _ = try await rowStore.delete(
            table: sideTable,
            where: .and([
                .eq(Column(table: sideTable, name: "table_name"), .text(tableName)),
                .eq(Column(table: sideTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
    }
}
