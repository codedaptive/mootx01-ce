// SQLiteDatasetStore.swift
//
// SQLite conformance for DatasetStore (MX-TAB-1).
//
// Design notes:
//
//   TABLE DDL: dataset columns are emitted using `SQLiteSchema.nativeType` —
//   the same type mapping used for LocusKit schema tables. No explicit
//   COLLATE clause is added to TEXT columns; SQLite's BINARY collation (the
//   default) is intentionally preserved for byte-order TEXT ordering parity
//   with the Rust SQLite backend.
//
//   IDENTIFIER VALIDATION: all user-supplied column names pass
//   `validateDatasetColumnIdentifier` (from PersistenceKit core) before any
//   DDL or DML is built. The validation call site in createDataset happens
//   BEFORE the connection is touched; an invalid name never reaches the SQL
//   engine. The existing `validateSQLIdentifier` in SQLiteStorage would also
//   catch it at the INSERT level, but the early validation gives callers a
//   cleaner `invalidIdentifier` error rather than a backend error.
//
//   PK COLUMN RECOVERY: appendRows recovers the declared PK column via
//   `PRAGMA table_info` to pre-sort rows before bulk insert. PRAGMA table_info
//   returns one row per column; column index 5 (`pk`) is non-zero for PK
//   columns. Using PRAGMA (rather than caching the schema in a metadata table)
//   keeps the implementation simple and stateless.
//
//   TRANSACTION SEAM: appendRows uses `beginTransactionDirect` /
//   `commitTransactionDirect` on the actor — the GLK_BATCH1 pattern. This
//   runs on the actor thread without crossing actor boundaries.
//
//   COLUMN STATS QUERY: a single SELECT with COUNT, COUNT(DISTINCT …), MIN,
//   MAX, and a CASE-based null count. REAL column MIN/MAX returns
//   SQLITE_FLOAT → `TypedValue.float(Double)` — never Float32 — satisfying
//   the cross-leg f64 wire rule.

import Foundation
import SQLCipher
import PersistenceKit

// MARK: - SQLiteDatasetStore

/// SQLite conformance for `DatasetStore`.
///
/// Holds a reference to `SQLiteBackend` (the actor that serializes all SQLite
/// operations) and to `SQLiteRowStore` for the `beginTransaction` /
/// `commitTransaction` GLK_BATCH1 seam.
final class SQLiteDatasetStore: DatasetStore, Sendable {
    let backend: SQLiteBackend

    init(backend: SQLiteBackend) {
        self.backend = backend
    }

    // MARK: - createDataset

    func createDataset(
        id: UUID,
        schema: DatasetSchema,
        indexes: [DatasetIndexDeclaration]
    ) async throws {
        // Validate ALL user-supplied column names before touching the connection.
        // Rejection fails the whole operation; no sanitize-and-continue path.
        for col in schema.columns {
            try validateDatasetColumnIdentifier(col.name)
        }
        for idx in indexes {
            try validateDatasetColumnIdentifier(idx.column)
        }
        try await backend.createDatasetTable(id: id, schema: schema, indexes: indexes)
    }

    // MARK: - appendRows

    func appendRows(id: UUID, rows: [[String: TypedValue]]) async throws {
        guard !rows.isEmpty else { return }
        // Validate column names from the first row (all rows in a dataset share
        // the same column shape, declared at createDataset time).
        if let first = rows.first {
            for key in first.keys {
                try validateDatasetColumnIdentifier(key)
            }
        }
        try await backend.appendDatasetRows(id: id, rows: rows)
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
        // Delegate to the existing SQLiteBackend.queryRows path, which handles
        // predicate compilation, identifier validation, and column projection.
        // `tableSchema: nil` causes `readColumn` to infer types from SQLite
        // affinity (INTEGER→.int, REAL→.float(Double), TEXT→.text, BLOB→.blob).
        return try await backend.queryRows(
            table: tableName,
            where: predicate,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            tableSchema: nil,
            columns: columns
        )
    }

    // MARK: - columnStats

    func columnStats(id: UUID, column: String) async throws -> ColumnStats {
        // Validate user-supplied column name before it enters any SQL.
        try validateDatasetColumnIdentifier(column)
        return try await backend.datasetColumnStats(id: id, column: column)
    }

    // MARK: - dropDataset

    func dropDataset(id: UUID) async throws {
        try await backend.dropDatasetTable(id: id)
    }
}

// MARK: - SQLiteBackend extensions for dataset operations

extension SQLiteBackend {

    // MARK: createDatasetTable

    /// Create the backing table for a dataset and any declared secondary indexes.
    ///
    /// Uses `CREATE TABLE IF NOT EXISTS` — idempotent across repeated calls.
    /// TEXT columns carry no explicit COLLATE clause: SQLite's BINARY collation
    /// (the default) is intentionally preserved for byte-order parity with the
    /// Rust leg.
    func createDatasetTable(
        id: UUID,
        schema: DatasetSchema,
        indexes: [DatasetIndexDeclaration]
    ) throws {
        let tableName = datasetTableName(id)

        // Build CREATE TABLE DDL from the DatasetSchema column declarations.
        // Reuses SQLiteSchema.nativeType for the type mapping so dataset columns
        // follow the same column-affinity rules as LocusKit schema tables.
        var parts: [String] = []
        for col in schema.columns {
            var line = "\"\(col.name)\" \(SQLiteSchema.nativeType(col.type))"
            if !col.nullable { line += " NOT NULL" }
            if let dv = col.defaultValue {
                line += " DEFAULT \(SQLiteSchema.literalSQL(dv))"
            }
            parts.append(line)
        }
        if let pk = schema.primaryKeyColumn {
            // Single-column PK constraint — composite PK is out of scope (spec §1).
            parts.append("PRIMARY KEY (\"\(pk)\")")
        }
        let createSQL = "CREATE TABLE IF NOT EXISTS \"\(tableName)\" (\n  "
            + parts.joined(separator: ",\n  ") + "\n)"
        try connection.exec(createSQL)

        // Declare secondary indexes. Index names use the `dsi_<hex>_<col>` scheme;
        // the names are generated and never user-supplied so no quoting is needed.
        for idx in indexes {
            let unique = idx.unique ? "UNIQUE " : ""
            let idxName = datasetIndexName(id, column: idx.column)
            let idxSQL = "CREATE \(unique)INDEX IF NOT EXISTS \"\(idxName)\" "
                + "ON \"\(tableName)\" (\"\(idx.column)\")"
            try connection.exec(idxSQL)
        }
    }

    // MARK: appendDatasetRows

    /// Bulk-insert rows into the dataset table, optionally pre-sorted by PK.
    ///
    /// The PK column is recovered via `PRAGMA table_info` — a lightweight
    /// read-only query that returns one row per column (column index 5, `pk`,
    /// is non-zero for the PK column). Using PRAGMA avoids storing schema
    /// metadata separately and keeps `appendDatasetRows` stateless.
    ///
    /// All inserts land in one `BEGIN IMMEDIATE` transaction using the actor's
    /// `beginTransactionDirect` / `commitTransactionDirect` methods (GLK_BATCH1
    /// pattern). The actor serializes all SQLite operations so no contention
    /// with other inserts is possible.
    func appendDatasetRows(id: UUID, rows: [[String: TypedValue]]) throws {
        guard !rows.isEmpty else { return }
        let tableName = datasetTableName(id)

        // Recover PK column via PRAGMA table_info for pre-sort.
        let pkColumn = try pkColumnForDatasetTable(tableName)

        // Pre-sort ascending by PK value when a PK column was declared.
        // Sorting before bulk-insert gives rowid values that track key order,
        // improving range-scan locality on the primary key.
        var sortedRows = rows
        if let pk = pkColumn {
            sortedRows.sort { a, b in
                compareTypedValuesForSort(a[pk] ?? .null, b[pk] ?? .null)
            }
        }

        // Single transaction, one INSERT per row using the existing insertRow
        // path (which runs identifier validation, encryption seam, and observer
        // notification internally).
        try beginTransactionDirect()
        do {
            for row in sortedRows {
                try insertRow(table: tableName, values: row)
            }
            try commitTransactionDirect()
        } catch {
            try? rollbackTransactionDirect()
            throw error
        }
    }

    // MARK: datasetColumnStats

    /// Compute per-column aggregate statistics for a dataset column.
    ///
    /// A single SQL query returns all five aggregates: COUNT, COUNT(DISTINCT),
    /// NULL count, MIN, and MAX. The CASE-based null count is exact even when
    /// the dataset is empty (returns 0, 0, 0, NULL, NULL).
    ///
    /// REAL column MIN/MAX returns SQLITE_FLOAT → `TypedValue.float(Double)`,
    /// satisfying the f64-only cross-leg wire rule. NULL MIN/MAX (no non-null
    /// rows) maps to `TypedValue.null`.
    func datasetColumnStats(id: UUID, column: String) throws -> ColumnStats {
        let tableName = datasetTableName(id)
        // Build the aggregate query.
        // COUNT("col") counts non-null values; COUNT(*) counts all rows.
        // Null count = total - non-null.
        // MIN/MAX return NULL when there are no non-null rows — decoded below.
        let sql = """
        SELECT
            COUNT("\(column)"),
            COUNT(DISTINCT "\(column)"),
            COUNT(*) - COUNT("\(column)"),
            MIN("\(column)"),
            MAX("\(column)")
        FROM "\(tableName)"
        """
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        guard try stmt.step() else {
            // No rows — should not happen for a well-formed SELECT, but be safe.
            return ColumnStats(count: 0, distinctCount: 0, nullCount: 0, min: .null, max: .null)
        }
        let count = stmt.columnInt64(0)
        let distinctCount = stmt.columnInt64(1)
        let nullCount = stmt.columnInt64(2)
        // MIN/MAX: read without a schema type hint so the affinity returned by
        // SQLite drives the TypedValue case. REAL → .float(Double) (f64).
        let minVal = readAggregateValue(stmt: stmt, index: 3)
        let maxVal = readAggregateValue(stmt: stmt, index: 4)
        return ColumnStats(
            count: count,
            distinctCount: distinctCount,
            nullCount: nullCount,
            min: minVal,
            max: maxVal
        )
    }

    // MARK: dropDatasetTable

    /// Drop the dataset backing table (DROP TABLE IF EXISTS — idempotent).
    func dropDatasetTable(id: UUID) throws {
        let tableName = datasetTableName(id)
        try connection.exec("DROP TABLE IF EXISTS \"\(tableName)\"")
    }

    // MARK: - Private helpers

    /// Recover the primary-key column name for a dataset table via PRAGMA
    /// table_info. Returns nil when the table has no explicit PK (rowid
    /// synthetic key).
    ///
    /// PRAGMA table_info columns: cid(0), name(1), type(2), notnull(3),
    /// dflt_value(4), pk(5). The `pk` field is 0 for non-PK columns and
    /// >= 1 for PK columns (the index within a composite PK). Since dataset
    /// PKs are always single-column (spec §1 Non-goals), we return the first
    /// column with pk > 0.
    private func pkColumnForDatasetTable(_ tableName: String) throws -> String? {
        let stmt = try connection.prepare("PRAGMA table_info(\"\(tableName)\")")
        defer { stmt.finalize() }
        while try stmt.step() {
            let pkIndex = stmt.columnInt64(5)
            if pkIndex > 0 {
                return stmt.columnText(1)
            }
        }
        return nil
    }

    /// Read one aggregate result value from a statement column without a
    /// schema type hint.
    ///
    /// Uses SQLite's reported column affinity (SQLITE_INTEGER, SQLITE_FLOAT,
    /// SQLITE_TEXT, SQLITE_BLOB, SQLITE_NULL) to determine the TypedValue case.
    /// REAL columns return `.float(Double)` — f64, never f32 — satisfying the
    /// cross-leg wire rule for columnStats min/max.
    private func readAggregateValue(stmt: SQLiteStatement, index: Int32) -> TypedValue {
        let sqliteType = stmt.columnType(index)
        switch sqliteType {
        case SQLITE_NULL:    return .null
        case SQLITE_INTEGER: return .int(stmt.columnInt64(index))
        case SQLITE_FLOAT:   return .float(stmt.columnDouble(index))
        case SQLITE_TEXT:    return .text(stmt.columnText(index) ?? "")
        case SQLITE_BLOB:    return .blob(stmt.columnBlob(index) ?? Data())
        default:             return .null
        }
    }
}

// MARK: - TypedValue sort comparison (SQLite-module private)

/// Compare two TypedValues for ascending sort order used in `appendRows`
/// PK pre-sort. Returns true when `a` should sort before `b`.
///
/// Comparison follows the same affinity rules as SQLite ORDER BY:
/// NULL sorts first (before non-null), then numeric, then text, then blob.
/// Homogeneous comparisons use natural ordering; heterogeneous pairs fall back
/// to null-first ordering. This function is a local helper only for the PK
/// pre-sort; it does not need to match SQLite's full cross-affinity ordering.
private func compareTypedValuesForSort(_ a: TypedValue, _ b: TypedValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return false
    case (.null, _):     return true   // NULL sorts first
    case (_, .null):     return false
    case (.int(let x), .int(let y)):         return x < y
    case (.float(let x), .float(let y)):     return x < y
    case (.int(let x), .float(let y)):       return Double(x) < y
    case (.float(let x), .int(let y)):       return x < Double(y)
    // UTF-8 byte order, NOT Swift String `<` (Unicode-canonical): matches the
    // BINARY collation the backend itself applies, and the Rust leg's `String <`.
    case (.text(let x), .text(let y)):       return x.utf8.lexicographicallyPrecedes(y.utf8)
    case (.uuid(let x), .uuid(let y)):       return x.uuidString < y.uuidString
    case (.timestamp(let x), .timestamp(let y)): return x < y
    default: return false
    }
}
