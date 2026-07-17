// ColumnHLCStore.swift
//
// Stateless CRUD namespace for the `_*_sync_meta_cols` per-column HLC
// side tables used by the `fieldLevelLWW` conflict policy.
//
// SCHEMA:
//   table_name  TEXT NOT NULL   — application table name
//   primary_key TEXT NOT NULL   — row UUID as TEXT
//   column_name TEXT NOT NULL   — application column name
//   col_hlc     INT  NOT NULL   — packed HLC (Int64, same layout as _ck_sync_meta.sync_hlc)
//   PRIMARY KEY (table_name, primary_key, column_name)
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
    /// Returns all (column_name, col_hlc) rows matching the given
    /// `tableName` and `primaryKey`, decoded into a ColumnHLCMap.
    /// Returns an empty map if no entries exist (first write, or the
    /// row has never been written under fieldLevelLWW).
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
                case .int(let colHLC) = row["col_hlc"]
            else { continue }
            let hlc = HLC(packed: UInt64(bitPattern: colHLC))
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
        guard !map.isEmpty else { return }
        for (columnName, packedHLC) in map.entries {
            let hlc = packedHLC.asHLC
            _ = try await storage.rowStore.upsertSync(
                table: sideTable,
                values: [
                    "table_name":  .text(tableName),
                    "primary_key": .text(primaryKey.uuidString),
                    "column_name": .text(columnName),
                    "col_hlc":     .int(Int64(bitPattern: hlc.packed))
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
        _ = try await storage.rowStore.delete(
            table: sideTable,
            where: .and([
                .eq(Column(table: sideTable, name: "table_name"), .text(tableName)),
                .eq(Column(table: sideTable, name: "primary_key"), .text(primaryKey.uuidString))
            ])
        )
    }
}
