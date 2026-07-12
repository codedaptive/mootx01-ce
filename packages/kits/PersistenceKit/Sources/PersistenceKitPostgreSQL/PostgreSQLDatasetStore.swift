// PostgreSQLDatasetStore.swift
//
// PostgreSQL conformance for DatasetStore (MX-TAB-2).
//
// Design notes (indexed for future agents):
//
//   TEXT COLLATION: every TEXT column in a dataset table is declared with
//   COLLATE "C" in CREATE TABLE DDL. This locks byte-order TEXT ordering for
//   ORDER BY and COUNT(DISTINCT) to match SQLite's BINARY collation default
//   and the Rust InMemory leg's String < comparison. Tests assert parity with
//   non-ASCII fixture strings ("Z" / "a" / "É") so parity is decidable.
//
//   SYNTHETIC PRIMARY KEY: when DatasetSchema.primaryKeyColumn is nil, the
//   table receives a hidden column `__ds_pk BIGINT GENERATED ALWAYS AS IDENTITY`
//   that carries the PRIMARY KEY constraint. This column is never exposed in
//   queryRows results — the SELECT column list is built from the cached schema
//   (user columns only). When a PK column is declared, no hidden column is
//   added; the named column carries PRIMARY KEY.
//
//   SCHEMA CACHE: DatasetSchema is stored in PostgreSQLBackend.datasetSchemas
//   (actor-isolated, keyed by table name) when createDatasetTable succeeds.
//   queryDatasetRows and datasetColumnStats look it up to know column types for
//   row decoding. If the cache is missing (process restart without re-calling
//   createDataset), a clear error is thrown — production would add an
//   information_schema introspection fallback.
//
//   IDENTIFIER VALIDATION: every user-supplied column name passes
//   validateDatasetColumnIdentifier (PersistenceKit core) before any DDL or
//   DML is built. ORDER BY / projection columns also pass validatePSQLIdentifier
//   (this module's seam). Rejection fails the whole operation — no
//   sanitize-and-continue path.
//
//   PK PRE-SORT: appendRows pre-sorts rows ascending by the declared PK column
//   before the transaction INSERT so rowid assignment tracks key order.
//   Same comparison logic as SQLiteDatasetStore (compareTypedValuesForSort).
//
//   TRANSACTION SEAM: appendDatasetRows acquires ONE connection from the pool,
//   runs BEGIN / INSERT... / COMMIT on it, then releases. ROLLBACK is issued
//   on any error. This is the GLK_BATCH1 pattern adapted for the pool model.
//
//   ROW DECODING: queryDatasetRows uses decodeRow (PostgreSQLConnection.swift)
//   with the cached ColumnDeclaration list. decodeCell is module-internal
//   (not private) so datasetColumnStats can call it for aggregate MIN/MAX
//   decoding without duplicating the type-switch logic.

import Foundation
import PersistenceKit
@preconcurrency import PostgresNIO
import Logging

// MARK: - PostgreSQLDatasetStore

/// PostgreSQL conformance for `DatasetStore` (MX-TAB-2).
///
/// Holds a reference to `PostgreSQLBackend` (the actor that owns the connection
/// pool, the application schema declaration, and the dataset schema cache).
/// Created by `PostgreSQLStorage.datasetStore`. Connection acquisition is
/// per-operation (not held open between calls) using the pool checkout/release
/// pattern established by `PostgreSQLBlobStore` and `PostgreSQLAuditLog`.
///
/// Mirrors `SQLiteDatasetStore` (PersistenceKitSQLite) and the Rust
/// `PgDatasetStore` (postgres.rs). All three produce byte-identical semantics:
/// same DDL shapes, same collation locking, same PK pre-sort, same f64 wire rule.
final class PostgreSQLDatasetStore: DatasetStore, Sendable {
    let backend: PostgreSQLBackend

    init(backend: PostgreSQLBackend) {
        self.backend = backend
    }

    // MARK: createDataset

    func createDataset(
        id: UUID,
        schema: DatasetSchema,
        indexes: [DatasetIndexDeclaration]
    ) async throws {
        // Validate all user-supplied column names BEFORE touching the connection.
        // Rejection fails the whole operation — no sanitize-and-continue path.
        for col in schema.columns {
            try validateDatasetColumnIdentifier(col.name)
        }
        for idx in indexes {
            try validateDatasetColumnIdentifier(idx.column)
        }
        try await backend.createDatasetTable(id: id, schema: schema, indexes: indexes)
    }

    // MARK: appendRows

    func appendRows(id: UUID, rows: [[String: TypedValue]]) async throws {
        guard !rows.isEmpty else { return }
        // Validate column names from the first row — all rows in a dataset share
        // the same column shape (declared at createDataset time).
        if let first = rows.first {
            for key in first.keys {
                try validateDatasetColumnIdentifier(key)
            }
        }
        try await backend.appendDatasetRows(id: id, rows: rows)
    }

    // MARK: queryRows

    func queryRows(
        id: UUID,
        predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        // Validate user-supplied projection column names before any SQL is built.
        if let cols = columns {
            for c in cols { try validateDatasetColumnIdentifier(c) }
        }
        // ORDER BY column names are validated inside renderDatasetPredicate via
        // validatePSQLIdentifier (SECFIX-WS2-PK F7).
        return try await backend.queryDatasetRows(
            id: id,
            predicate: predicate,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            columns: columns
        )
    }

    // MARK: columnStats

    func columnStats(id: UUID, column: String) async throws -> ColumnStats {
        // Validate user-supplied column name before it enters any SQL.
        try validateDatasetColumnIdentifier(column)
        return try await backend.datasetColumnStats(id: id, column: column)
    }

    // MARK: dropDataset

    func dropDataset(id: UUID) async throws {
        try await backend.dropDatasetTable(id: id)
    }
}

// MARK: - PostgreSQLBackend extensions for dataset operations

extension PostgreSQLBackend {

    // MARK: createDatasetTable

    /// Create the backing table for a dataset and any declared secondary indexes.
    ///
    /// DDL shape — no declared PK (`schema.primaryKeyColumn == nil`):
    /// ```sql
    /// CREATE TABLE IF NOT EXISTS "ds_<hex>" (
    ///   "__ds_pk" BIGINT GENERATED ALWAYS AS IDENTITY,
    ///   "col1" TEXT COLLATE "C" NOT NULL,
    ///   "col2" DOUBLE PRECISION,
    ///   PRIMARY KEY ("__ds_pk")
    /// )
    /// ```
    ///
    /// DDL shape — declared PK "rank":
    /// ```sql
    /// CREATE TABLE IF NOT EXISTS "ds_<hex>" (
    ///   "rank" BIGINT NOT NULL,
    ///   "name" TEXT COLLATE "C",
    ///   PRIMARY KEY ("rank")
    /// )
    /// ```
    ///
    /// TEXT columns carry `COLLATE "C"` to lock byte-order ordering so ORDER BY
    /// produces identical results to SQLite's BINARY collation default and the
    /// Rust InMemory leg's byte-order String comparison.
    ///
    /// Stores the schema in `datasetSchemas` after successful DDL so subsequent
    /// queries can decode row values with the correct column types.
    func createDatasetTable(
        id: UUID,
        schema: DatasetSchema,
        indexes: [DatasetIndexDeclaration]
    ) async throws {
        let tableName = datasetTableName(id)
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }

        // Build CREATE TABLE DDL.
        var parts: [String] = []

        // When no explicit PK column is declared, add a hidden identity column.
        // `__ds_pk` is never included in SELECT column lists (the explicit
        // projection from `schema.columns` excludes it). INSERT statements
        // also omit it, so Postgres assigns sequence values automatically.
        let hasDeclaredPK = schema.primaryKeyColumn != nil
        if !hasDeclaredPK {
            parts.append("\"__ds_pk\" BIGINT GENERATED ALWAYS AS IDENTITY")
        }

        // User-declared columns. TEXT gets COLLATE "C" for collation lock.
        for col in schema.columns {
            var line = "\"\(col.name)\" \(datasetPGTypeSQL(col.type))"
            if !col.nullable { line += " NOT NULL" }
            if let dv = col.defaultValue {
                line += " DEFAULT \(PostgreSQLSchemaEmitter.literalSQL(dv))"
            }
            parts.append(line)
        }

        // PRIMARY KEY constraint.
        if let pk = schema.primaryKeyColumn {
            parts.append("PRIMARY KEY (\"\(pk)\")")
        } else {
            parts.append("PRIMARY KEY (\"__ds_pk\")")
        }

        let createSQL = "CREATE TABLE IF NOT EXISTS \"\(tableName)\" (\n  "
            + parts.joined(separator: ",\n  ") + "\n)"
        try await conn.executeSimple(createSQL, logger: logger)

        // Secondary indexes. Names are generated (`dsi_<hex>_<col>`) — never
        // user-supplied — so no additional identifier quoting is required.
        for idx in indexes {
            let unique = idx.unique ? "UNIQUE " : ""
            let idxName = datasetIndexName(id, column: idx.column)
            let idxSQL = "CREATE \(unique)INDEX IF NOT EXISTS \"\(idxName)\" "
                + "ON \"\(tableName)\" (\"\(idx.column)\")"
            try await conn.executeSimple(idxSQL, logger: logger)
        }

        // Cache the schema for subsequent queryDatasetRows / datasetColumnStats.
        // Actor isolation serializes this write with all other accesses.
        datasetSchemas[tableName] = schema
    }

    // MARK: appendDatasetRows

    /// Bulk-insert rows into the dataset table in a single transaction.
    ///
    /// Pre-sorts rows ascending by the declared PK column (when one exists)
    /// before the transaction so the identity-sequence assignment tracks key
    /// order. When no PK is declared, rows are inserted in call-site order.
    ///
    /// Acquires one connection, runs BEGIN / INSERT... / COMMIT. On error,
    /// issues ROLLBACK before releasing the connection. Both success and error
    /// paths release the connection before returning (structured release).
    func appendDatasetRows(id: UUID, rows: [[String: TypedValue]]) async throws {
        guard !rows.isEmpty else { return }
        let tableName = datasetTableName(id)
        guard let schema = datasetSchemas[tableName] else {
            throw StorageError.backendError(
                underlying: "appendDatasetRows: schema for \(tableName) not cached — "
                    + "call createDataset before appendRows"
            )
        }

        // Pre-sort ascending by PK column when one was declared.
        var sortedRows = rows
        if let pk = schema.primaryKeyColumn {
            sortedRows.sort { a, b in
                compareTypedValuesForSort(a[pk] ?? .null, b[pk] ?? .null)
            }
        }

        // Structured acquire-BEGIN-INSERT...-COMMIT-release.
        // ROLLBACK issued on any error before the structured release.
        let conn = try await pool.acquire()
        do {
            try await conn.executeSimple("BEGIN", logger: logger)
            for row in sortedRows {
                try await pgDatasetInsertRow(conn, table: tableName, row: row, logger: logger)
            }
            try await conn.executeSimple("COMMIT", logger: logger)
            await pool.release(conn)
        } catch {
            // Best-effort rollback. If ROLLBACK itself errors, surface the
            // original error (not the rollback error).
            try? await conn.executeSimple("ROLLBACK", logger: logger)
            await pool.release(conn)
            throw error
        }
    }

    // MARK: queryDatasetRows

    /// Column-projecting predicate query over dataset rows.
    ///
    /// Builds an explicit SELECT column list from the cached schema (never
    /// includes `__ds_pk`). Applies predicate (parameterized via
    /// PostgreSQLPredicateCompiler) and ORDER BY (column names validated via
    /// validatePSQLIdentifier). Decodes each row using the schema's
    /// ColumnDeclaration types via `decodeRow` (PostgreSQLConnection.swift).
    func queryDatasetRows(
        id: UUID,
        predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        let tableName = datasetTableName(id)
        guard let schema = datasetSchemas[tableName] else {
            throw StorageError.backendError(
                underlying: "queryDatasetRows: schema for \(tableName) not cached"
            )
        }

        // Build the projection column list from the cached schema.
        // When columns is nil or empty, project all schema columns (never __ds_pk).
        let projectedCols: [ColumnDeclaration]
        if let requested = columns, !requested.isEmpty {
            let requestedSet = Set(requested)
            projectedCols = schema.columns.filter { requestedSet.contains($0.name) }
        } else {
            projectedCols = schema.columns
        }

        let colSelect = projectedCols.map { "\"\($0.name)\"" }.joined(separator: ", ")
        var sql = "SELECT \(colSelect) FROM \"\(tableName)\""
        var bindings: [TypedValue] = []

        if let pred = predicate {
            // renderDatasetPredicate validates all predicate column names
            // through PostgreSQLPredicateCompiler (SECFIX-WS2-PK F7 seam).
            let whereSQL = try renderDatasetPredicate(pred, startIndex: 1, bindings: &bindings)
            sql += " WHERE \(whereSQL)"
        }

        if !orderBy.isEmpty {
            // Validate ORDER BY column names before interpolating into SQL
            // (SECFIX-WS2-PK F7).
            let parts = try orderBy.map { clause -> String in
                try validatePSQLIdentifier(clause.column.name)
                let dir = clause.direction == .ascending ? "ASC" : "DESC"
                // No COLLATE needed: TEXT columns carry COLLATE "C" in their
                // column definition, so ORDER BY inherits the column collation.
                return "\"\(clause.column.name)\" \(dir)"
            }
            sql += " ORDER BY " + parts.joined(separator: ", ")
        }

        if let lim = limit { sql += " LIMIT \(lim)" }
        if let off = offset { sql += " OFFSET \(off)" }

        let conn = try await pool.acquire()
        // Structured release mirrors PostgreSQLBlobStore.withConnection (#55).
        do {
            let pgRows = try await conn.executeParameterized(
                sql, bindings: bindings, logger: logger
            )
            var out: [StorageRow] = []
            for try await row in pgRows {
                // decodeRow (PostgreSQLConnection.swift) maps column names to
                // TypedValues using the declared ColumnType — correct for TEXT,
                // DOUBLE PRECISION, UUID, TIMESTAMPTZ, etc.
                let decoded = decodeRow(row, columns: projectedCols)
                out.append(StorageRow(values: decoded))
            }
            await pool.release(conn)
            return out
        } catch {
            await pool.release(conn)
            throw error
        }
    }

    // MARK: datasetColumnStats

    /// Per-column aggregate statistics: COUNT, COUNT(DISTINCT), NULL count,
    /// MIN, MAX — computed in one SQL round-trip.
    ///
    /// MIN/MAX values are decoded using the column's declared ColumnType
    /// (from the cached schema) via `decodeCell` (PostgreSQLConnection.swift),
    /// so DOUBLE PRECISION columns return `TypedValue.float(Double)` — f64
    /// only — satisfying the cross-leg f64 wire rule. NULL MIN/MAX (empty or
    /// all-null dataset) maps to `TypedValue.null`.
    func datasetColumnStats(id: UUID, column: String) async throws -> ColumnStats {
        let tableName = datasetTableName(id)
        guard let schema = datasetSchemas[tableName] else {
            throw StorageError.backendError(
                underlying: "datasetColumnStats: schema for \(tableName) not cached"
            )
        }
        guard let colDecl = schema.columns.first(where: { $0.name == column }) else {
            throw StorageError.backendError(
                underlying: "datasetColumnStats: column \"\(column)\" not found in schema "
                    + "for \(tableName)"
            )
        }

        // Single SELECT — five aggregates in one round-trip.
        // Aliased so decoding can use random-access by name.
        let sql = """
        SELECT
            COUNT("\(column)") AS cnt,
            COUNT(DISTINCT "\(column)") AS dcnt,
            COUNT(*) - COUNT("\(column)") AS ncnt,
            MIN("\(column)") AS min_val,
            MAX("\(column)") AS max_val
        FROM "\(tableName)"
        """

        let conn = try await pool.acquire()
        do {
            let pgRows = try await conn.executeParameterized(
                sql, bindings: [], logger: logger
            )
            for try await row in pgRows {
                let access = row.makeRandomAccess()
                let count = (try? access["cnt"].decode(Int64.self, context: .default)) ?? 0
                let distinctCount = (try? access["dcnt"].decode(Int64.self, context: .default)) ?? 0
                let nullCount = (try? access["ncnt"].decode(Int64.self, context: .default)) ?? 0
                // MIN/MAX: decoded using the column's declared ColumnType so
                // DOUBLE PRECISION → TypedValue.float(Double) (f64 wire rule).
                // NULL (empty column or all-null rows) → TypedValue.null.
                let minVal = decodeCell(access["min_val"], type: colDecl.type)
                let maxVal = decodeCell(access["max_val"], type: colDecl.type)
                await pool.release(conn)
                return ColumnStats(
                    count: count,
                    distinctCount: distinctCount,
                    nullCount: nullCount,
                    min: minVal,
                    max: maxVal
                )
            }
            await pool.release(conn)
            // No rows returned — should not happen for a well-formed SELECT,
            // but return safe defaults rather than crashing.
            return ColumnStats(count: 0, distinctCount: 0, nullCount: 0, min: .null, max: .null)
        } catch {
            await pool.release(conn)
            throw error
        }
    }

    // MARK: dropDatasetTable

    /// Drop the dataset backing table (DROP TABLE IF EXISTS — idempotent).
    /// Removes the cached schema so a subsequent `createDataset` starts clean.
    func dropDatasetTable(id: UUID) async throws {
        let tableName = datasetTableName(id)
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }
        try await conn.executeSimple(
            "DROP TABLE IF EXISTS \"\(tableName)\"", logger: logger
        )
        datasetSchemas.removeValue(forKey: tableName)
    }
}

// MARK: - Dataset-specific PostgreSQL type mapping

/// Map `ColumnType` to a PostgreSQL DDL type fragment for dataset table columns.
///
/// TEXT columns carry `COLLATE "C"` — the key Postgres-specific addition versus
/// `PostgreSQLSchemaEmitter.typeSQL`. This locks byte-order TEXT ordering to
/// match SQLite's BINARY collation default so ORDER BY on TEXT columns produces
/// identical results across backends. All other types follow the same mapping
/// as `PostgreSQLSchemaEmitter.typeSQL`.
///
/// Module-level free function in `PersistenceKitPostgreSQL` (not a case on
/// `PostgreSQLSchemaEmitter`) to keep the dataset-specific divergence isolated
/// and visible to future agents. The divergence: collation lock on TEXT.
func datasetPGTypeSQL(_ t: ColumnType) -> String {
    switch t {
    // TEXT with COLLATE "C" — byte-order parity with SQLite BINARY collation.
    case .text:        return "TEXT COLLATE \"C\""
    // All other types identical to PostgreSQLSchemaEmitter.typeSQL.
    case .uuid:        return "UUID"
    case .bitmap, .int: return "BIGINT"
    case .timestamp:   return "TIMESTAMPTZ"
    case .float:       return "DOUBLE PRECISION"
    case .bool:        return "BOOLEAN"
    case .blob:        return "BYTEA"
    case .json:        return "JSONB"
    case .hlc:         return "BIGINT"
    case .fingerprint: return "BYTEA"
    }
}

// MARK: - Predicate rendering helper (dataset store — module private)

/// Render a `StoragePredicate` to a parameterized PostgreSQL WHERE clause,
/// appending bound values to `bindings` with `$startIndex`-based numbering.
///
/// Delegates to `PostgreSQLPredicateCompiler.compile` which validates all
/// predicate column names via `validatePSQLIdentifier` (SECFIX-WS2-PK F7
/// seam). Renumbers `$N` placeholders starting at `startIndex`. Mirrors the
/// private `renderPredicate` in `PostgreSQLRowStore`; copied here so the blast
/// radius stays within `PostgreSQLDatasetStore.swift` without exposing a
/// module-internal API from `PostgreSQLRowStore`.
private func renderDatasetPredicate(
    _ p: StoragePredicate,
    startIndex: Int,
    bindings: inout [TypedValue]
) throws -> String {
    let compiled = try PostgreSQLPredicateCompiler.compile(p)
    bindings.append(contentsOf: compiled.bindings)
    guard startIndex != 1 else { return compiled.sql }
    var sql = compiled.sql
    // Renumber in reverse so $10 is rewritten before $1 (avoids clobbering).
    for i in (1...compiled.bindings.count).reversed() {
        sql = sql.replacingOccurrences(of: "$\(i)", with: "$\(i + startIndex - 1)")
    }
    return sql
}

// MARK: - Row insert helper

/// Insert one row into a dataset table using a parameterized INSERT.
///
/// Column names are sorted (stable iteration order) for prepared-statement
/// cache reuse across rows with the same schema. Does NOT apply at-rest
/// encryption — dataset rows carry no `_content` / `_keyID` columns.
///
/// Validates each column name via `validatePSQLIdentifier` before
/// interpolating into the INSERT column list (SECFIX-WS2-PK F9 seam).
///
/// Free function (not an actor extension method) so `appendDatasetRows` can
/// call it without capturing `self` inside a closure.
private func pgDatasetInsertRow(
    _ conn: PostgresConnection,
    table: String,
    row: [String: TypedValue],
    logger: Logger
) async throws {
    guard !row.isEmpty else { return }
    let cols = row.keys.sorted()
    for c in cols { try validatePSQLIdentifier(c) }
    let colList = cols.map { "\"\($0)\"" }.joined(separator: ", ")
    let placeholders = (1...cols.count).map { "$\($0)" }.joined(separator: ", ")
    let sql = "INSERT INTO \"\(table)\" (\(colList)) VALUES (\(placeholders))"
    let bindings = cols.map { row[$0]! }
    // `executeParameterized` is defined in PostgreSQLConnection.swift;
    // the result (empty row sequence for INSERT) is discarded with `_`.
    _ = try await conn.executeParameterized(sql, bindings: bindings, logger: logger)
}

// MARK: - TypedValue ascending sort comparison (mirrors SQLiteDatasetStore)

/// Compare two `TypedValue`s for ascending sort order used in `appendRows`
/// PK pre-sort.
///
/// Returns `true` when `a` should sort before `b`. NULL sorts first.
/// Text uses UTF-8 byte order (matches SQLite BINARY collation and the Rust
/// InMemory leg's `String <`). Mirrors `compareTypedValuesForSort` in
/// `PersistenceKitSQLite` and `PersistenceKitInMemory` — identical rule,
/// separate module-level seam.
private func compareTypedValuesForSort(_ a: TypedValue, _ b: TypedValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return false
    case (.null, _):     return true   // NULL sorts first
    case (_, .null):     return false
    case (.int(let x), .int(let y)):         return x < y
    case (.float(let x), .float(let y)):     return x < y
    case (.int(let x), .float(let y)):       return Double(x) < y
    case (.float(let x), .int(let y)):       return x < Double(y)
    // UTF-8 byte order — matches SQLite BINARY collation and Rust String <.
    case (.text(let x), .text(let y)):       return x.utf8.lexicographicallyPrecedes(y.utf8)
    case (.uuid(let x), .uuid(let y)):       return x.uuidString < y.uuidString
    case (.timestamp(let x), .timestamp(let y)): return x < y
    default: return false
    }
}
