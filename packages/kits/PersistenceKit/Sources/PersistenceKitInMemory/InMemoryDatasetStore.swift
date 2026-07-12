// InMemoryDatasetStore.swift
//
// In-memory conformance for DatasetStore (MX-TAB-1).
//
// Design notes:
//
//   TABLE STORAGE: dataset tables are stored in `InMemoryState.tables` under
//   their `ds_<uuid-no-hyphens>` names, alongside LocusKit schema tables.
//   A `TableDeclaration` is constructed from the `DatasetSchema` on creation:
//   `primaryKey` = [primaryKeyColumn] when declared, `[]` otherwise; no
//   uniqueConstraints, no generatedColumns, appendOnly = false.
//
//   COLUMN STATS: computed by a linear scan over all in-memory rows for the
//   given column, computing count, distinctCount, nullCount, min, max in Swift.
//   TypedValue Equatable conformance drives distinct-count via a Set; ordering
//   uses `compareTypedValuesForSort` (the same helper used for SQLite PK pre-sort).
//
//   ORDERING / COLLATION: all text comparison paths use UTF-8 byte order —
//   matching SQLite BINARY collation and the Rust leg's `String::cmp`
//   (byte-lexicographic). Surfaces covered:
//     • `compareTypedValuesForSort`: PK pre-sort, columnStats min/max
//     • `TypedValueComparator.compare`: `queryRows` orderBy (InMemoryStorage
//       line ~434) and predicate lt/lte/gt/gte (PredicateEvaluator)
//   MX-TAB-Q1 RESOLVED 2026-07-12: the pre-existing `TypedValueComparator`
//   text arm (Swift String `<`, Unicode-canonical) was changed to
//   `utf8.lexicographicallyPrecedes` / `utf8.elementsEqual` for strict
//   byte-order semantics across every RowStore ordering and comparison surface.
//   Cross-backend parity is verified by DatasetStoreTests `binaryCollation_*`.
//
//   COLUMN VALIDATION: every user-supplied column name passes
//   `validateDatasetColumnIdentifier` before any table mutation. Same rule
//   as the SQLite backend — one shared seam in PersistenceKit core.
//
//   NO BOOL STORED PROPERTIES: this file stores no Bool properties on any
//   entity — consistent with the schema-invariants rule.

import Foundation
import PersistenceKit

// MARK: - InMemoryDatasetStore

/// In-memory conformance for `DatasetStore`.
///
/// Holds a reference to `InMemoryStateActor` (the actor that serialises all
/// in-memory state mutations). Used in tests and rapid-iteration environments;
/// not persisted across process runs. Mirrors the Swift API surface of
/// `SQLiteDatasetStore`.
final class InMemoryDatasetStore: DatasetStore, Sendable {
    let stateActor: InMemoryStateActor

    init(stateActor: InMemoryStateActor) {
        self.stateActor = stateActor
    }

    // MARK: - createDataset

    func createDataset(
        id: UUID,
        schema: DatasetSchema,
        indexes: [DatasetIndexDeclaration]
    ) async throws {
        // Validate all user-supplied column names before touching state.
        for col in schema.columns {
            try validateDatasetColumnIdentifier(col.name)
        }
        for idx in indexes {
            try validateDatasetColumnIdentifier(idx.column)
        }
        // `indexes` are advisory in the in-memory backend: there is no physical
        // index structure. They are recorded in the table declaration's
        // `uniqueConstraints` when `unique == true` so that the existing unique-
        // constraint check in InMemoryRowStore fires on duplicate inserts.
        // Non-unique indexes are silently ignored (no physical access-path benefit
        // in-memory). This mirrors the InMemory treatment of IndexDeclarations in
        // the schema migration path (applyOperation(.addIndex …) → break).
        let uniqueConstraints: [[String]] = indexes
            .filter { $0.unique }
            .map { [$0.column] }
        let pk: [String] = schema.primaryKeyColumn.map { [$0] } ?? []
        let decl = TableDeclaration(
            name: datasetTableName(id),
            columns: schema.columns,
            primaryKey: pk,
            uniqueConstraints: uniqueConstraints,
            generatedColumns: [],
            appendOnly: false
        )
        await stateActor.createDatasetTable(decl)
    }

    // MARK: - appendRows

    func appendRows(id: UUID, rows: [[String: TypedValue]]) async throws {
        guard !rows.isEmpty else { return }
        // Validate EVERY row's keys before any mutation — the spec's
        // "rejection fails the whole operation" applies to the batch as a
        // unit, so a bad key in row N must not depend on later insert-time
        // validation to be caught.
        for row in rows {
            for key in row.keys {
                try validateDatasetColumnIdentifier(key)
            }
        }
        // Recover the declared PK column from the stored table declaration for
        // pre-sort. This matches the SQLite backend's PRAGMA table_info path —
        // both ensure rowid/internal-key assignment tracks ascending PK order.
        let tableName = datasetTableName(id)
        let pkColumn = await stateActor.pkColumnForDatasetTable(tableName)

        var sortedRows = rows
        if let pk = pkColumn {
            sortedRows.sort { a, b in
                compareTypedValuesForSort(a[pk] ?? .null, b[pk] ?? .null)
            }
        }
        // Single-transaction discipline (spec §1: appendRows is one
        // transaction): mirror InMemoryStorage.transaction()'s seam —
        // buffer notifications, snapshot, insert all rows, then commit; a
        // mid-batch throw (e.g. unique-index violation) rolls back to the
        // snapshot so no partial batch is ever visible.
        await stateActor.beginNotificationBuffering()
        let snapshot = await stateActor.snapshot()
        do {
            for row in sortedRows {
                _ = try await stateActor.insertRow(table: tableName, values: row)
            }
            await stateActor.commitNotifications()
        } catch {
            await stateActor.rollback(to: snapshot)
            throw error
        }
    }

    // MARK: - queryRows

    func queryRows(
        id: UUID,
        predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        let tableName = datasetTableName(id)
        return try await stateActor.queryRows(
            table: tableName,
            where: predicate,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            columns: columns
        )
    }

    // MARK: - columnStats

    func columnStats(id: UUID, column: String) async throws -> ColumnStats {
        try validateDatasetColumnIdentifier(column)
        return try await stateActor.datasetColumnStats(
            tableName: datasetTableName(id),
            column: column
        )
    }

    // MARK: - dropDataset

    func dropDataset(id: UUID) async throws {
        await stateActor.dropDatasetTable(datasetTableName(id))
    }
}

// MARK: - InMemoryStateActor extensions for dataset operations

extension InMemoryStateActor {

    // MARK: createDatasetTable

    /// Register a new dataset backing table in the in-memory state.
    ///
    /// Idempotent: if the table already exists (same name), the call is a
    /// no-op — matching `CREATE TABLE IF NOT EXISTS` SQLite semantics. This
    /// prevents a double-`createDataset` call from wiping existing rows.
    func createDatasetTable(_ decl: TableDeclaration) {
        if state.tables[decl.name] == nil {
            state.tables[decl.name] = InMemoryTable(declaration: decl)
        }
    }

    // MARK: pkColumnForDatasetTable

    /// Return the declared primary-key column name for a dataset table, or nil
    /// when the table has no explicit PK (uses the synthetic UUID rowkey).
    ///
    /// Reads `TableDeclaration.primaryKey` — the same information that the
    /// SQLite backend recovers via `PRAGMA table_info`. Returns the first
    /// element when the PK list is non-empty (spec: dataset PKs are always
    /// single-column).
    func pkColumnForDatasetTable(_ tableName: String) -> String? {
        guard let t = state.tables[tableName] else { return nil }
        return t.declaration.primaryKey.first
    }

    // MARK: datasetColumnStats

    /// Compute per-column aggregate statistics for an in-memory dataset table.
    ///
    /// Linear scan over all rows. `distinctCount` is computed via a Set of
    /// `TypedValue`s (which has `Equatable` and `Hashable` conformance).
    /// `min` and `max` use `compareTypedValuesForSort` — the same ordering
    /// helper as PK pre-sort. `TypedValue.null` values are skipped from all
    /// aggregate computations (matching SQL COUNT / MIN / MAX behaviour).
    func datasetColumnStats(tableName: String, column: String) throws -> ColumnStats {
        guard let t = state.tables[tableName] else {
            throw StorageError.invalidQuery(detail: "columnStats: table \(tableName) not found")
        }
        var count: Int64 = 0
        var nullCount: Int64 = 0
        var seen: Set<TypedValue> = []
        var minVal: TypedValue = .null
        var maxVal: TypedValue = .null

        for row in t.rows.values {
            let v = row[column] ?? .null
            if case .null = v {
                nullCount += 1
            } else {
                count += 1
                seen.insert(v)
                // Update min
                if case .null = minVal {
                    minVal = v
                } else if compareTypedValuesForSort(v, minVal) {
                    minVal = v
                }
                // Update max
                if case .null = maxVal {
                    maxVal = v
                } else if compareTypedValuesForSort(maxVal, v) {
                    maxVal = v
                }
            }
        }
        return ColumnStats(
            count: count,
            distinctCount: Int64(seen.count),
            nullCount: nullCount,
            min: minVal,
            max: maxVal
        )
    }

    // MARK: dropDatasetTable

    /// Remove a dataset backing table from the in-memory state.
    ///
    /// No-op when the table does not exist — matching `DROP TABLE IF EXISTS`
    /// SQLite semantics.
    func dropDatasetTable(_ tableName: String) {
        state.tables.removeValue(forKey: tableName)
    }
}

// MARK: - TypedValue sort comparison (in-memory module private)

/// Compare two TypedValues for ascending sort order used in `appendRows`
/// PK pre-sort and `columnStats` min/max. Returns true when `a` should
/// sort before `b`.
///
/// NULL sorts first (before non-null). Homogeneous numeric comparisons use
/// natural ordering; cross-type numeric pairs cross-cast. Text compares by
/// UTF-8 byte order — matching SQLite BINARY collation and the Rust leg's
/// `String <` — per the spec's collation lock (cross-leg parity must be
/// decidable). Unhandled cross-type pairs return false (stable, equal-rank).
///
/// This function is module-private. It is intentionally named the same as
/// the identically-typed function in PersistenceKitSQLite — both exist in
/// separate modules and are used for the same PK-pre-sort purpose, so
/// keeping them in sync is deliberate.
func compareTypedValuesForSort(_ a: TypedValue, _ b: TypedValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return false
    case (.null, _):     return true
    case (_, .null):     return false
    case (.int(let x), .int(let y)):         return x < y
    case (.float(let x), .float(let y)):     return x < y
    case (.int(let x), .float(let y)):       return Double(x) < y
    case (.float(let x), .int(let y)):       return x < Double(y)
    // UTF-8 byte order, NOT Swift String `<` (Unicode-canonical): SQLite's
    // BINARY collation and Rust's `String <` both compare bytes; all legs
    // and backends must agree for parity to be decidable.
    case (.text(let x), .text(let y)):       return x.utf8.lexicographicallyPrecedes(y.utf8)
    case (.uuid(let x), .uuid(let y)):       return x.uuidString < y.uuidString
    case (.timestamp(let x), .timestamp(let y)): return x < y
    default: return false
    }
}
