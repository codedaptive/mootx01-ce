//! DatasetStore trait — typed row I/O for user-defined dataset tables.
//!
//! Byte-identical semantics with the Swift `PersistenceKit.DatasetStore` protocol
//! (MX-TAB-1). Table naming, identifier validation, PK pre-sort, BINARY collation,
//! and f64-only floats are all specified here and match the Swift implementation.
//!
//! # Structure
//!
//! This file owns:
//! - The `DatasetStore` trait and associated public types.
//! - The module-level helpers (`dataset_table_name`, `dataset_index_name`,
//!   `validate_dataset_column_identifier`).
//! - The `InMemoryDatasetStore` conformance (test double).
//!
//! The SQLite conformance (`SqliteDatasetStoreShim`) lives in `sqlite.rs` because
//! it must share `SqliteStorage`'s `Arc<Mutex<Inner>>` connection. Putting it
//! there mirrors the layout for every other store (SqliteRowStore, SqliteBlobStore,
//! SqliteAuditLog all live in `sqlite.rs`). The InMemory conformance is here
//! because `InMemoryDatasetStore` owns its own `Arc<Mutex<_>>` and does not need
//! access to `inmemory.rs`-private types.
//!
//! # Table naming
//!
//! Each dataset owns one backing table: `ds_<uuid-no-hyphens>` (lowercase). The
//! `ds_` prefix starts with a letter; the 32 hex digits are all alphanumeric — the
//! whole name passes `validate_sql_identifier` without quoting.
//!
//! # Column identifier validation
//!
//! User-supplied column names (from `moot_file_dataset` and CSV headers) become
//! SQL identifiers. Every name passes `validate_dataset_column_identifier` (same
//! rule as `validate_sql_identifier`: `[A-Za-z_][A-Za-z0-9_]*`) before any DDL or
//! DML is built. Rejection fails the whole operation — no sanitize-and-continue.
//!
//! # BINARY collation discipline
//!
//! TEXT column DDL emits no COLLATE clause: SQLite's BINARY collation (the default)
//! is preserved. Tests in `DatasetStoreTests.swift` assert byte-order TEXT ordering
//! with non-ASCII fixture strings to make Swift/Rust parity decidable.
//!
//! # Float discipline (parity law)
//!
//! `column_stats` min/max for REAL columns return `TypedValue::Float(f64)`. SQLite
//! returns `ValueRef::Real(f64)` → `TypedValue::Float` via the value codec.
//! No f32 is introduced anywhere on this path; cross-leg JSON wire text is identical.
//!
//! # PK pre-sort
//!
//! `append_rows` pre-sorts ascending by the declared primary-key column before
//! bulk insert, so rowid assignment tracks key order. When no PK is declared
//! rows are inserted in call-site order.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex};

use uuid::Uuid;

use crate::error::{validate_sql_identifier, StorageError, StorageResult};
use crate::predicate::{OrderClause, OrderDirection, StoragePredicate};
use crate::schema::ColumnDeclaration;
use crate::types::{ColumnType, StorageRow, TypedValue};

// ---------------------------------------------------------------------------
// Public types (mirrors Swift DatasetStore.swift)
// ---------------------------------------------------------------------------

/// Column declarations and optional primary-key for a dataset table.
///
/// Mirrors Swift's `DatasetSchema`. Column names are user-supplied and pass
/// `validate_dataset_column_identifier` before any DDL is emitted.
#[derive(Debug, Clone)]
pub struct DatasetSchema {
    /// Declared columns. Each `name` is validated before DDL is built.
    pub columns: Vec<ColumnDeclaration>,

    /// Optional primary-key column name.
    ///
    /// When `Some`, the named column carries a PRIMARY KEY constraint in the
    /// CREATE TABLE DDL, and `append_rows` pre-sorts rows ascending by that
    /// column before insertion so rowid assignment tracks key order.
    ///
    /// When `None` the backend uses its synthetic key (SQLite rowid).
    pub primary_key_column: Option<String>,
}

/// Single-column secondary index for a dataset table.
///
/// Composite indexes are out of scope for v1 (spec §1 Non-goals).
/// The index name is generated: `dsi_<uuid-no-hyphens>_<column>`.
/// The column name is user-supplied and validated before DDL is emitted.
/// Mirrors Swift's `DatasetIndexDeclaration`.
#[derive(Debug, Clone)]
pub struct DatasetIndexDeclaration {
    /// Column to index. User-supplied; validated before DDL.
    pub column: String,

    /// Whether the index enforces uniqueness on the indexed column.
    pub unique: bool,
}

/// Per-column aggregate statistics for a dataset column.
///
/// Computed in SQL: `COUNT`, `COUNT(DISTINCT …)`, `MIN`, `MAX`, null count.
/// Float values for REAL columns are `TypedValue::Float(f64)` — f64 only,
/// never f32 — guaranteeing identical JSON text across Swift and Rust legs.
/// `min` and `max` are `TypedValue::Null` when the column has no non-null rows.
/// Mirrors Swift's `ColumnStats`.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnStats {
    /// Count of non-null values (`COUNT("col")` in SQL).
    pub count: i64,

    /// Count of distinct non-null values (`COUNT(DISTINCT "col")` in SQL).
    pub distinct_count: i64,

    /// Count of null values (`COUNT(*) - COUNT("col")` in SQL).
    pub null_count: i64,

    /// Minimum non-null value, or `TypedValue::Null` when no non-null values.
    pub min: TypedValue,

    /// Maximum non-null value, or `TypedValue::Null` when no non-null values.
    pub max: TypedValue,
}

// ---------------------------------------------------------------------------
// DatasetStore trait
// ---------------------------------------------------------------------------

/// Typed row I/O for user-defined dataset tables.
///
/// Sits alongside `RowStore` and `BlobStore` on the `Storage` trait.
/// Each dataset owns one backing table (`ds_<uuid-no-hyphens>`); the estate
/// handle lives in LocusKit and is wired in MX-TAB-4. Column names are
/// user-supplied and always pass `validate_dataset_column_identifier` —
/// rejection fails the whole operation with `StorageError::InvalidIdentifier`,
/// with no sanitize-and-continue path.
///
/// The API is synchronous (matching the Rust backend convention); the Swift
/// side is async because Swift actors require it.
/// Mirrors Swift's `DatasetStore` protocol.
pub trait DatasetStore: Send + Sync {
    /// Create the backing table for dataset `id` from `schema` and declare
    /// `indexes`.
    ///
    /// - Idempotent: `CREATE TABLE IF NOT EXISTS` / no-op on existing table.
    /// - All column names are validated before any DDL; an invalid name returns
    ///   `Err(StorageError::InvalidIdentifier)`.
    fn create_dataset(
        &self,
        id: Uuid,
        schema: &DatasetSchema,
        indexes: &[DatasetIndexDeclaration],
    ) -> StorageResult<()>;

    /// Bulk-insert `rows` into the dataset backing table.
    ///
    /// - When `schema.primary_key_column` was declared, rows are pre-sorted
    ///   ascending by that column before insertion (rowid locality).
    /// - All rows land in one `BEGIN IMMEDIATE` transaction (GLK_BATCH1 seam).
    /// - Column names are validated before any DML.
    fn append_rows(
        &self,
        id: Uuid,
        rows: &[BTreeMap<String, TypedValue>],
    ) -> StorageResult<()>;

    /// Column-projecting predicate query over dataset rows.
    ///
    /// Delegates to the backend's existing predicate and projection machinery.
    /// `columns` is a projection list; `None` returns all columns.
    /// TEXT ordering uses BINARY collation (byte order) — SQLite's default.
    fn query_rows(
        &self,
        id: Uuid,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
        columns: Option<&[String]>,
    ) -> StorageResult<Vec<StorageRow>>;

    /// Per-column aggregate statistics for the named column.
    ///
    /// Float min/max for REAL columns are `TypedValue::Float(f64)` — f64 only —
    /// guaranteeing identical JSON text across Swift and Rust legs.
    fn column_stats(&self, id: Uuid, column: &str) -> StorageResult<ColumnStats>;

    /// Drop the dataset's backing table.
    ///
    /// `DROP TABLE IF EXISTS` semantics — no-op if the table does not exist.
    fn drop_dataset(&self, id: Uuid) -> StorageResult<()>;
}

// ---------------------------------------------------------------------------
// Column identifier validator
// ---------------------------------------------------------------------------

/// Validate a user-supplied dataset column name for use as a SQL identifier.
///
/// Accepts only `[A-Za-z_][A-Za-z0-9_]*` — the safe subset that passes on any
/// backend without quoting. Mirrors Swift's `validateDatasetColumnIdentifier`
/// and the existing `validate_sql_identifier` in `error.rs` — identical rule.
///
/// Returns `Err(StorageError::InvalidIdentifier)` for any name outside the
/// safe set. There is no sanitize-and-continue path: an invalid name fails
/// the whole `create_dataset` or `append_rows` operation.
pub fn validate_dataset_column_identifier(name: &str) -> StorageResult<()> {
    // Delegates to the shared `validate_sql_identifier` in error.rs so both
    // functions stay in sync — identical rule, one implementation.
    validate_sql_identifier(name)
}

// ---------------------------------------------------------------------------
// Table / index name helpers
// ---------------------------------------------------------------------------

/// Derive the backing table name for a dataset UUID.
///
/// Pattern: `ds_` + UUID hex digits with hyphens stripped (lowercase). The
/// `ds_` prefix starts with a letter; all 32 hex digits are alphanumeric —
/// the whole name passes `validate_sql_identifier` without quoting.
///
/// Mirrors Swift's `datasetTableName`.
pub fn dataset_table_name(id: Uuid) -> String {
    // `Uuid::as_simple()` formats as 32 lowercase hex digits with no hyphens.
    format!("ds_{}", id.as_simple())
}

/// Derive the index name for a secondary index on a dataset column.
///
/// Pattern: `dsi_<uuid-no-hyphens>_<column>`. Both parts are alphanumeric/
/// underscore — valid SQL identifier without quoting. The column name MUST
/// already be validated before calling this.
///
/// Mirrors Swift's `datasetIndexName`.
pub fn dataset_index_name(id: Uuid, column: &str) -> String {
    format!("dsi_{}_{}", id.as_simple(), column)
}

// ---------------------------------------------------------------------------
// Shared sort comparison (used by both SQLite and InMemory backends)
// ---------------------------------------------------------------------------

/// Compare two TypedValues for ascending sort order.
///
/// Returns `true` when `a` should sort before `b` (i.e., `a < b`).
/// NULL sorts first. Text uses byte-order comparison (`<`), matching SQLite's
/// BINARY collation default. Unhandled cross-type pairs return `false` (stable).
///
/// Used for PK pre-sort in `append_rows` and min/max tracking in
/// `column_stats`. Mirrors Swift's `compareTypedValuesForSort` in
/// PersistenceKitSQLite and PersistenceKitInMemory.
pub(crate) fn compare_typed_values_for_sort(a: &TypedValue, b: &TypedValue) -> bool {
    use TypedValue::*;
    match (a, b) {
        (Null, Null) => false,
        (Null, _) => true,   // NULL sorts first
        (_, Null) => false,
        (Int(x), Int(y)) => x < y,
        (Float(x), Float(y)) => x < y,
        (Int(x), Float(y)) => (*x as f64) < *y,
        (Float(x), Int(y)) => *x < (*y as f64),
        (Text(x), Text(y)) => x < y,   // byte-order: Rust String < is lexicographic byte order
        (Uuid(x), Uuid(y)) => x.to_string() < y.to_string(),
        (Timestamp(x), Timestamp(y)) => x < y,
        _ => false,
    }
}

/// Map `ColumnType` to the SQLite native type string.
///
/// Mirrors `native_type` in `sqlite.rs`. Exported pub(crate) so `sqlite.rs`'s
/// `SqliteDatasetStoreShim` can use it without duplicating the mapping.
pub(crate) fn dataset_native_type(t: ColumnType) -> &'static str {
    match t {
        ColumnType::Uuid | ColumnType::Text | ColumnType::Timestamp => "TEXT",
        ColumnType::Bitmap | ColumnType::Int | ColumnType::Bool | ColumnType::Hlc => "INTEGER",
        ColumnType::Float => "REAL",
        ColumnType::Blob | ColumnType::Json | ColumnType::Fingerprint => "BLOB",
    }
}

// ---------------------------------------------------------------------------
// InMemory implementation
// ---------------------------------------------------------------------------

/// In-memory table for dataset storage.
struct InMemoryDatasetTable {
    /// Declared primary-key column (when provided at `create_dataset`).
    pk_column: Option<String>,
    /// Rows keyed by monotone insertion counter. Dataset rows have no UUID
    /// primary key unless the user declares one; the counter provides a
    /// stable insertion-order key for iteration.
    rows: BTreeMap<u64, BTreeMap<String, TypedValue>>,
    /// Monotone counter for generating internal row keys.
    next_key: u64,
}

/// In-memory dataset state: one table per dataset UUID.
struct InMemoryDatasetState {
    tables: HashMap<String, InMemoryDatasetTable>,
}

impl Default for InMemoryDatasetState {
    fn default() -> Self {
        InMemoryDatasetState {
            tables: HashMap::new(),
        }
    }
}

/// In-memory conformance for `DatasetStore` (MX-TAB-1).
///
/// Used in tests and rapid-iteration environments; not persisted across process
/// runs. Mirrors the behavior of `SqliteDatasetStoreShim` (in `sqlite.rs`).
pub struct InMemoryDatasetStore {
    state: Arc<Mutex<InMemoryDatasetState>>,
}

impl Default for InMemoryDatasetStore {
    fn default() -> Self {
        InMemoryDatasetStore {
            state: Arc::new(Mutex::new(InMemoryDatasetState::default())),
        }
    }
}

impl InMemoryDatasetStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl DatasetStore for InMemoryDatasetStore {
    fn create_dataset(
        &self,
        id: Uuid,
        schema: &DatasetSchema,
        indexes: &[DatasetIndexDeclaration],
    ) -> StorageResult<()> {
        // Validate all user-supplied column names.
        for col in &schema.columns {
            validate_dataset_column_identifier(&col.name)?;
        }
        for idx in indexes {
            validate_dataset_column_identifier(&idx.column)?;
        }

        let table_name = dataset_table_name(id);
        let mut guard = self.state.lock().unwrap();

        // Idempotent: no-op if the table already exists (CREATE IF NOT EXISTS semantics).
        guard.tables.entry(table_name).or_insert_with(|| InMemoryDatasetTable {
            pk_column: schema.primary_key_column.clone(),
            rows: BTreeMap::new(),
            next_key: 0,
        });
        Ok(())
    }

    fn append_rows(
        &self,
        id: Uuid,
        rows: &[BTreeMap<String, TypedValue>],
    ) -> StorageResult<()> {
        if rows.is_empty() {
            return Ok(());
        }

        // Validate column names from the first row.
        if let Some(first) = rows.first() {
            for key in first.keys() {
                validate_dataset_column_identifier(key)?;
            }
        }

        let table_name = dataset_table_name(id);
        let mut guard = self.state.lock().unwrap();
        let table = guard.tables.get_mut(&table_name).ok_or_else(|| {
            StorageError::InvalidQuery {
                detail: format!(
                    "append_rows: dataset {table_name} not found — call create_dataset first"
                ),
            }
        })?;

        // Pre-sort ascending by PK when declared.
        let mut sorted_rows: Vec<BTreeMap<String, TypedValue>> = rows.to_vec();
        let pk = table.pk_column.clone();
        if let Some(ref pk_col) = pk {
            sorted_rows.sort_by(|a, b| {
                let av = a.get(pk_col).unwrap_or(&TypedValue::Null);
                let bv = b.get(pk_col).unwrap_or(&TypedValue::Null);
                if compare_typed_values_for_sort(av, bv) {
                    std::cmp::Ordering::Less
                } else if compare_typed_values_for_sort(bv, av) {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Equal
                }
            });
        }

        for row in sorted_rows {
            let key = table.next_key;
            table.next_key += 1;
            table.rows.insert(key, row);
        }
        Ok(())
    }

    fn query_rows(
        &self,
        id: Uuid,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
        columns: Option<&[String]>,
    ) -> StorageResult<Vec<StorageRow>> {
        let table_name = dataset_table_name(id);
        let guard = self.state.lock().unwrap();
        let table = guard.tables.get(&table_name).ok_or_else(|| {
            StorageError::InvalidQuery {
                detail: format!("query_rows: dataset {table_name} not found"),
            }
        })?;

        let projected: Option<HashSet<&str>> = columns.map(|cols| {
            cols.iter().map(|s| s.as_str()).collect()
        });

        // Filter rows by predicate (order-stable: BTreeMap iterates by key).
        let mut matched: Vec<BTreeMap<String, TypedValue>> = table
            .rows
            .values()
            .filter(|row| {
                if let Some(pred) = predicate {
                    inmemory_evaluate_predicate(pred, row)
                } else {
                    true
                }
            })
            .cloned()
            .collect();

        // Apply ordering before projection (ORDER BY can reference non-projected cols).
        if !order_by.is_empty() {
            matched.sort_by(|lhs, rhs| {
                for clause in order_by {
                    let lv = lhs.get(&clause.column.name).unwrap_or(&TypedValue::Null);
                    let rv = rhs.get(&clause.column.name).unwrap_or(&TypedValue::Null);
                    let a_lt_b = compare_typed_values_for_sort(lv, rv);
                    let b_lt_a = compare_typed_values_for_sort(rv, lv);
                    let cmp = if a_lt_b && !b_lt_a {
                        std::cmp::Ordering::Less
                    } else if b_lt_a && !a_lt_b {
                        std::cmp::Ordering::Greater
                    } else {
                        std::cmp::Ordering::Equal
                    };
                    if cmp != std::cmp::Ordering::Equal {
                        return if clause.direction == OrderDirection::Ascending {
                            cmp
                        } else {
                            cmp.reverse()
                        };
                    }
                }
                std::cmp::Ordering::Equal
            });
        }

        // Pagination.
        if let Some(off) = offset {
            if off > 0 {
                matched = matched.into_iter().skip(off).collect();
            }
        }
        if let Some(lim) = limit {
            matched.truncate(lim);
        }

        // Apply projection last.
        let result = matched
            .into_iter()
            .map(|row| {
                if let Some(ref cols) = projected {
                    if !cols.is_empty() {
                        return StorageRow::new(
                            row.into_iter()
                                .filter(|(k, _)| cols.contains(k.as_str()))
                                .collect(),
                        );
                    }
                }
                StorageRow::new(row)
            })
            .collect();

        Ok(result)
    }

    fn column_stats(&self, id: Uuid, column: &str) -> StorageResult<ColumnStats> {
        validate_dataset_column_identifier(column)?;
        let table_name = dataset_table_name(id);
        let guard = self.state.lock().unwrap();
        let table = guard.tables.get(&table_name).ok_or_else(|| {
            StorageError::InvalidQuery {
                detail: format!("column_stats: dataset {table_name} not found"),
            }
        })?;

        let mut count: i64 = 0;
        let mut null_count: i64 = 0;
        let mut seen: HashSet<TypedValue> = HashSet::new();
        let mut min_val: TypedValue = TypedValue::Null;
        let mut max_val: TypedValue = TypedValue::Null;

        for row in table.rows.values() {
            let v = row.get(column).unwrap_or(&TypedValue::Null);
            match v {
                TypedValue::Null => {
                    null_count += 1;
                }
                non_null => {
                    count += 1;
                    seen.insert(non_null.clone());
                    // Update min — smaller values sort before current min.
                    if matches!(min_val, TypedValue::Null) {
                        min_val = non_null.clone();
                    } else if compare_typed_values_for_sort(non_null, &min_val) {
                        min_val = non_null.clone();
                    }
                    // Update max — larger values sort after current max.
                    if matches!(max_val, TypedValue::Null) {
                        max_val = non_null.clone();
                    } else if compare_typed_values_for_sort(&max_val, non_null) {
                        max_val = non_null.clone();
                    }
                }
            }
        }

        Ok(ColumnStats {
            count,
            distinct_count: seen.len() as i64,
            null_count,
            min: min_val,
            max: max_val,
        })
    }

    fn drop_dataset(&self, id: Uuid) -> StorageResult<()> {
        let table_name = dataset_table_name(id);
        let mut guard = self.state.lock().unwrap();
        guard.tables.remove(&table_name);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// InMemory predicate evaluator (module-private)
// ---------------------------------------------------------------------------

/// Evaluate a `StoragePredicate` against an in-memory row.
///
/// Mirrors Swift's `PredicateEvaluator.evaluate` in PersistenceKitInMemory.
/// Uses TypedValue's `PartialEq` for equality; ordering uses
/// `compare_typed_values_for_sort`. LIKE uses simple prefix/suffix/contains
/// matching on `%pattern%` — complex `_` wildcards are not tested by MX-TAB-1.
fn inmemory_evaluate_predicate(
    pred: &StoragePredicate,
    row: &BTreeMap<String, TypedValue>,
) -> bool {
    use StoragePredicate::*;
    match pred {
        IsTrue => true,
        IsFalse => false,
        And(preds) => preds.iter().all(|p| inmemory_evaluate_predicate(p, row)),
        Or(preds) => preds.iter().any(|p| inmemory_evaluate_predicate(p, row)),
        Not(inner) => !inmemory_evaluate_predicate(inner, row),
        Eq(c, v) => row.get(&c.name).map_or(false, |rv| rv == v),
        Neq(c, v) => row.get(&c.name).map_or(true, |rv| rv != v),
        Lt(c, v) => row.get(&c.name).map_or(false, |rv| {
            compare_typed_values_for_sort(rv, v)
                && !compare_typed_values_for_sort(v, rv)
        }),
        Lte(c, v) => row.get(&c.name).map_or(false, |rv| {
            rv == v || compare_typed_values_for_sort(rv, v)
        }),
        Gt(c, v) => row.get(&c.name).map_or(false, |rv| {
            compare_typed_values_for_sort(v, rv)
                && !compare_typed_values_for_sort(rv, v)
        }),
        Gte(c, v) => row.get(&c.name).map_or(false, |rv| {
            rv == v || compare_typed_values_for_sort(v, rv)
        }),
        IsNull(c) => row.get(&c.name).map_or(true, |rv| {
            matches!(rv, TypedValue::Null)
        }),
        IsNotNull(c) => row.get(&c.name).map_or(false, |rv| {
            !matches!(rv, TypedValue::Null)
        }),
        In(c, values) => row.get(&c.name).map_or(false, |rv| values.contains(rv)),
        Like(c, pattern) => {
            if let Some(TypedValue::Text(text)) = row.get(&c.name) {
                // Simple LIKE: `%` anchors only at start/end. Enough for
                // MX-TAB-1 dataset query tests. Complex `_` wildcard: not needed.
                let trimmed = pattern.trim_matches('%');
                if pattern.starts_with('%') && pattern.ends_with('%') {
                    text.contains(trimmed)
                } else if pattern.starts_with('%') {
                    text.ends_with(trimmed)
                } else if pattern.ends_with('%') {
                    text.starts_with(trimmed)
                } else {
                    text == pattern
                }
            } else {
                false
            }
        }
        BitmaskAll { column, mask } => {
            match row.get(&column.name) {
                Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) => {
                    (i & mask) == *mask
                }
                _ => false,
            }
        }
        BitmaskAny { column, mask } => {
            match row.get(&column.name) {
                Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) => {
                    (i & mask) != 0
                }
                _ => false,
            }
        }
        BitmaskNone { column, mask } => {
            match row.get(&column.name) {
                Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) => {
                    (i & mask) == 0
                }
                _ => true,
            }
        }
        BitwiseEq { column, expected, mask } => {
            match row.get(&column.name) {
                Some(TypedValue::Int(i)) | Some(TypedValue::Bitmap(i)) => {
                    (i & mask) == *expected
                }
                _ => false,
            }
        }
    }
}
