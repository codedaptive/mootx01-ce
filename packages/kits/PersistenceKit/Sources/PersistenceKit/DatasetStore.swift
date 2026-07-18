// DatasetStore.swift
//
// Typed row I/O for user-defined dataset tables (MX-TAB-1).
//
// Alongside RowStore and BlobStore this is the third shaped surface on
// Storage (MX-TABULAR spec §1). Each dataset owns one backend table whose
// name is `ds_<uuid-no-hyphens>`. The estate handle (belief lifecycle,
// bitmaps, provenance) is wired in LocusKit/MX-TAB-4; this file owns only
// the backend row surface.
//
// Key design decisions documented here so future agents do not re-derive them:
//
//   TABLE NAMING: `ds_` + UUID hex with hyphens stripped. The `ds_` prefix
//   satisfies the first-character letter rule; hex digits (a-f, 0-9) satisfy
//   subsequent-character rules. The identifier needs no quoting on any backend.
//   Names are generated internally — only column names are user-supplied and
//   require validation.
//
//   COLUMN IDENTIFIER VALIDATION: User-supplied column names (from
//   moot_file_dataset and CSV headers) become SQL identifiers in CREATE TABLE,
//   CREATE INDEX, SELECT, INSERT, and aggregate DDL/DML. Every column name
//   passes `validateDatasetColumnIdentifier` before any DDL or DML is built.
//   Rejected names fail the whole operation with `StorageError.invalidIdentifier`
//   — there is no sanitize-and-continue path.
//
//   COLLATION DISCIPLINE: TEXT column ordering (ORDER BY) and distinct-count
//   use byte order — SQLite BINARY collation (the default; never overridden by
//   dataset DDL), Postgres COLLATE "C" on dataset TEXT columns (MX-TAB-2, when
//   it lands). This locks parity between backends and across Swift/Rust legs so
//   the parity harness can verify identical results with non-ASCII fixture strings.
//   Locale-aware ordering is a v2 question. Tests MUST assert byte-order results
//   with non-ASCII fixture strings to make parity decidable (spec §Parity law).
//
//   PK PRE-SORT: appendRows pre-sorts by the declared primary-key column before
//   insertion so rowid assignment tracks key order. When no PK is declared the
//   backend synthetic key (SQLite rowid) is used and no pre-sort applies.
//
//   FLOAT DISCIPLINE: columnStats min/max for REAL columns returns
//   `TypedValue.float(Double)` (f64) — never f32 — enforcing the cross-leg wire
//   rule so Swift and Rust produce identical JSON text on the tool surface.
//
//   THROWING ACCESSOR SHAPE: `Storage.datasetStore` is `var … { get throws }`
//   (Swift) / `fn dataset_store(&self) -> StorageResult<Arc<dyn DatasetStore>>`
//   (Rust). A plain non-throwing var would require all conformers to provide a
//   value; the throwing shape lets the protocol-extension default throw
//   `featureGated("datasetStore")` so third-party Storage conformers keep
//   compiling without change.

import Foundation

// MARK: - DatasetSchema

/// Column declarations and optional primary-key designation for a dataset table.
///
/// Column names are user-supplied (from `moot_file_dataset` and CSV headers)
/// and become SQL identifiers in `CREATE TABLE` DDL. Every column name is
/// validated against `[A-Za-z_][A-Za-z0-9_]*` before any DDL is emitted.
/// Mirrors Rust's `DatasetSchema` in `dataset_store.rs`.
public struct DatasetSchema: Sendable {
    /// Declared columns. Each `ColumnDeclaration.name` is user-supplied and
    /// passes `validateDatasetColumnIdentifier` before DDL is built.
    public let columns: [ColumnDeclaration]

    /// Optional primary-key column name.
    ///
    /// When non-nil the named column carries a PRIMARY KEY constraint in the
    /// CREATE TABLE DDL, and `appendRows` pre-sorts rows ascending by this
    /// column's value before insertion so rowid assignment tracks key order.
    ///
    /// When nil the backend uses its synthetic key (SQLite rowid; Postgres
    /// `bigint generated always as identity`). `appendRows` inserts rows in
    /// call-site order without pre-sorting.
    public let primaryKeyColumn: String?

    public init(columns: [ColumnDeclaration], primaryKeyColumn: String? = nil) {
        self.columns = columns
        self.primaryKeyColumn = primaryKeyColumn
    }
}

// MARK: - DatasetIndexDeclaration

/// Single-column secondary index for a dataset table.
///
/// Composite indexes are out of scope for v1 (MX-TABULAR spec §1 Non-goals).
/// The index name is generated: `dsi_<uuid-no-hyphens>_<column>`.
/// The column name is user-supplied and validated before any DDL is emitted.
/// Mirrors Rust's `DatasetIndexDeclaration` in `dataset_store.rs`.
public struct DatasetIndexDeclaration: Sendable {
    /// Column to index. User-supplied; passes `validateDatasetColumnIdentifier`
    /// before any DDL is built.
    public let column: String

    /// Whether the index enforces uniqueness on the indexed column.
    public let unique: Bool

    public init(column: String, unique: Bool = false) {
        self.column = column
        self.unique = unique
    }
}

// MARK: - ColumnStats

/// Per-column aggregate statistics computed by the backend in SQL.
///
/// Floats for REAL columns use `TypedValue.float(Double)` (f64 only, never
/// f32) to guarantee identical JSON text on the tool surface across Swift and
/// Rust legs (MX-TABULAR Parity law §Float discipline).
///
/// `min` and `max` are `.null` when the column contains no non-null values
/// (empty dataset or fully-null column). Mirrors Rust's `ColumnStats` in
/// `dataset_store.rs`.
public struct ColumnStats: Sendable, Equatable {
    /// Count of non-null values (`COUNT("col")` in SQL).
    public let count: Int64

    /// Count of distinct non-null values (`COUNT(DISTINCT "col")` in SQL).
    public let distinctCount: Int64

    /// Count of null values (`COUNT(*) - COUNT("col")` in SQL).
    public let nullCount: Int64

    /// Minimum non-null value, or `.null` when no non-null values exist.
    public let min: TypedValue

    /// Maximum non-null value, or `.null` when no non-null values exist.
    public let max: TypedValue

    public init(
        count: Int64,
        distinctCount: Int64,
        nullCount: Int64,
        min: TypedValue,
        max: TypedValue
    ) {
        self.count = count
        self.distinctCount = distinctCount
        self.nullCount = nullCount
        self.min = min
        self.max = max
    }
}

// MARK: - DatasetStore protocol

/// Typed row I/O for user-defined dataset tables.
///
/// Sits alongside `RowStore` and `BlobStore` on the `Storage` protocol.
/// Each dataset owns one backing table (`ds_<uuid-no-hyphens>`); the estate
/// handle lives in LocusKit and is wired in MX-TAB-4. Column names are
/// user-supplied and always pass `validateDatasetColumnIdentifier` —
/// rejection fails the whole operation with `StorageError.invalidIdentifier`,
/// with no sanitize-and-continue path.
///
/// Reuses `StoragePredicate`, `OrderClause`, and `TypedValue` — no new
/// query language. Mirrors Rust's `DatasetStore` trait in `dataset_store.rs`.
public protocol DatasetStore: Sendable {

    /// Create the backing table for dataset `id` from `schema` and declare
    /// `indexes`.
    ///
    /// - Idempotent: `CREATE TABLE IF NOT EXISTS` semantics on backends that
    ///   support it (SQLite, InMemory). Calling twice on the same id is a no-op.
    /// - Every column name in `schema.columns` and every `indexes[n].column`
    ///   passes `validateDatasetColumnIdentifier` before any DDL; an invalid
    ///   name throws `StorageError.invalidIdentifier` and aborts the operation.
    func createDataset(
        id: UUID,
        schema: DatasetSchema,
        indexes: [DatasetIndexDeclaration]
    ) async throws

    /// Bulk-insert `rows` into the dataset backing table.
    ///
    /// - When `schema.primaryKeyColumn` was declared at `createDataset` time,
    ///   rows are pre-sorted ascending by that column before insertion so rowid
    ///   assignment tracks key order (performance optimization).
    /// - All rows land in a single transaction via the `RowStore`
    ///   `beginTransaction` / `commitTransaction` seam (GLK_BATCH1 pattern).
    /// - Column names in each row dict are user-supplied and validated before
    ///   any DML; an invalid name throws `StorageError.invalidIdentifier`.
    func appendRows(id: UUID, rows: [[String: TypedValue]]) async throws

    /// Column-projecting predicate query over dataset rows.
    ///
    /// Delegates to the backend's existing predicate and projection machinery —
    /// no new query language. `columns` is a projection list; `nil` returns
    /// all columns.
    ///
    /// TEXT ordering uses BINARY collation (byte order), which is SQLite's
    /// default. Dataset DDL never overrides collation. Tests assert byte-order
    /// results with non-ASCII fixture strings to make Swift/Rust parity decidable.
    func queryRows(
        id: UUID,
        predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow]

    /// Per-column aggregate statistics for the named column.
    ///
    /// Computed in SQL: `COUNT`, `COUNT(DISTINCT …)`, `MIN`, `MAX`, NULL count.
    /// Float values for REAL columns are `TypedValue.float(Double)` (f64 only)
    /// to guarantee identical JSON text across Swift and Rust legs.
    func columnStats(id: UUID, column: String) async throws -> ColumnStats

    /// Drop the dataset's backing table.
    ///
    /// Uses `DROP TABLE IF EXISTS` semantics — a no-op if the table does not
    /// exist. The caller is responsible for the estate handle tombstone
    /// (LocusKit / MX-TAB-4); this method touches only the backend table.
    func dropDataset(id: UUID) async throws
}

// MARK: - Column identifier validator (shared across all backends)

/// Validate a user-supplied dataset column name for use as a SQL identifier.
///
/// Column names arrive from `moot_file_dataset` and CSV headers and become
/// SQL identifiers in `CREATE TABLE`, `CREATE INDEX`, `SELECT`, `INSERT`, and
/// aggregate queries. Accepts only names matching `[A-Za-z_][A-Za-z0-9_]*` —
/// the safe subset that passes validation on any backend without quoting.
///
/// Throws `StorageError.invalidIdentifier` for any name outside the safe set.
/// There is no sanitize-and-continue path: an invalid name fails the whole
/// `createDataset` or `appendRows` operation.
///
/// Module-level free function in the PersistenceKit core target so all
/// backends (SQLite, InMemory, future Postgres) call one shared seam.
/// Mirrors the Rust `validate_sql_identifier` in `error.rs` and the existing
/// `validateSQLIdentifier` in `PersistenceKitSQLite` — identical rule.
public func validateDatasetColumnIdentifier(_ name: String) throws {
    guard !name.isEmpty else {
        throw StorageError.invalidIdentifier(name: name)
    }
    for (index, char) in name.unicodeScalars.enumerated() {
        let valid: Bool
        if index == 0 {
            // First character: letter or underscore only.
            valid = (char >= "A" && char <= "Z")
                || (char >= "a" && char <= "z")
                || char == "_"
        } else {
            // Subsequent characters: letter, digit, or underscore.
            valid = (char >= "A" && char <= "Z")
                || (char >= "a" && char <= "z")
                || (char >= "0" && char <= "9")
                || char == "_"
        }
        guard valid else {
            throw StorageError.invalidIdentifier(name: name)
        }
    }
}

// MARK: - Table-name helpers

/// Derive the backing table name for a dataset UUID.
///
/// Pattern: `ds_` + UUID hex digits with hyphens stripped. The `ds_` prefix
/// starts with a letter (satisfying the first-character rule); the remaining
/// 32 hex digits (a-f, 0-9) satisfy subsequent-character rules. The result
/// needs no quoting on any backend and passes `validateSQLIdentifier`.
///
/// Example:
///   `550e8400-e29b-41d4-a716-446655440000` → `ds_550e8400e29b41d4a716446655440000`
///
/// Table names are generated internally; column names are validated separately.
/// Mirrors Rust's `dataset_table_name` in `dataset_store.rs`.
public func datasetTableName(_ id: UUID) -> String {
    // Lower-case hex, hyphens removed; `ds_` prefix gives first-char letter.
    "ds_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

/// Derive the index name for a secondary index on a dataset column.
///
/// Pattern: `dsi_<uuid-no-hyphens>_<column>`. Both components are
/// alphanumeric/underscore — the result is a valid SQL identifier without
/// quoting. The column name MUST have already been validated before calling
/// this function.
///
/// Mirrors Rust's `dataset_index_name` in `dataset_store.rs`.
public func datasetIndexName(_ id: UUID, column: String) -> String {
    let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return "dsi_\(hex)_\(column)"
}
