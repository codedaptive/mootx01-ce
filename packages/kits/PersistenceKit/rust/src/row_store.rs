//! RowStore trait: typed row I/O.

use crate::error::StorageResult;
use crate::predicate::{OrderClause, StoragePredicate};
use crate::types::{RowHandle, StorageRow, TypedValue};
use std::collections::BTreeMap;

pub trait RowStore: Send + Sync {
    fn insert(&self, table: &str, values: BTreeMap<String, TypedValue>)
        -> StorageResult<RowHandle>;

    fn upsert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        conflict_columns: &[String],
    ) -> StorageResult<RowHandle>;

    fn update(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize>;

    fn delete(&self, table: &str, predicate: &StoragePredicate) -> StorageResult<usize>;

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>>;

    /// Column-projected query: identical to [`query`](Self::query) but only the
    /// columns named in `columns` appear in each returned [`StorageRow`].
    ///
    /// This is the storage-layer hook for the recall no-blob path: a
    /// `.structured` recall projects away the `content` column so the decoded
    /// drawer carries `content == ""` (LocusKit spec § 7.3) without paying the
    /// blob I/O. It is the Rust parity of the Swift column-projection recall
    /// query.
    ///
    /// The default delegates to [`query`](Self::query) and then drops every
    /// column not in `columns` — correct for any backend, but it still reads
    /// the full row from storage. Backends that can push the projection into
    /// the engine (SQLite, PostgreSQL: `SELECT col1, col2, …`) override this so
    /// the omitted column is never read off disk. An empty `columns` slice is
    /// treated as "no projection" and returns full rows, matching `query`.
    fn query_projected(
        &self,
        table: &str,
        columns: &[&str],
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>> {
        let rows = self.query(table, predicate, order_by, limit, offset)?;
        if columns.is_empty() {
            return Ok(rows);
        }
        Ok(rows
            .into_iter()
            .map(|row| {
                let mut kept: BTreeMap<String, TypedValue> = BTreeMap::new();
                for &c in columns {
                    if let Some(v) = row.get(c) {
                        kept.insert(c.to_string(), v.clone());
                    }
                }
                StorageRow::new(kept)
            })
            .collect())
    }

    fn count(&self, table: &str, predicate: Option<&StoragePredicate>) -> StorageResult<usize>;

    /// Column-projected variant of [`query_skip_corrupt`](Self::query_skip_corrupt).
    ///
    /// Identical semantics to `query_skip_corrupt` — rows with
    /// `StorageError::CorruptStoredValue` on any column are skipped and logged;
    /// other errors abort — but only the columns named in `columns` are returned
    /// in each row, matching the projection contract of
    /// [`query_projected`](Self::query_projected).
    ///
    /// An empty `columns` slice is treated as "no projection" and returns full
    /// rows (matching `query_projected`'s convention), skipping corrupt rows.
    ///
    /// The default implementation delegates to `query_projected` and wraps a
    /// single top-level `CorruptStoredValue` error as `(vec![], 1)`.
    /// Backends that can implement row-level skipping at the cursor (SQLite)
    /// override this for correct per-row skip-and-log behaviour.
    fn query_projected_skip_corrupt(
        &self,
        table: &str,
        columns: &[&str],
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<(Vec<StorageRow>, usize)> {
        match self.query_projected(table, columns, predicate, order_by, limit, offset) {
            Ok(rows) => Ok((rows, 0)),
            Err(crate::error::StorageError::CorruptStoredValue { table: t, column: c, stored_text: s }) => {
                eprintln!(
                    "[persistence_kit] WARNING: query_projected_skip_corrupt fallback: at least \
                     one corrupt row in '{}' (column='{}' stored_text='{}'). Backend does not \
                     support row-level skipping; returning empty result.",
                    t, c, s
                );
                Ok((vec![], 1))
            }
            Err(other) => Err(other),
        }
    }

    /// Corpus scan that skips rows with a corrupt stored value rather than
    /// failing the entire scan.
    ///
    /// ## When to use
    ///
    /// Use this method for **best-effort corpus scans** (e.g. `all_drawers`,
    /// `drawers_in_wing`) where a single corrupt row must not brick the entire
    /// estate. One bad timestamp or UUID should cause that row to be logged and
    /// skipped, not abort the whole query. For **point lookups** (single-row
    /// fetches by primary key) use [`query`](Self::query), which is strict: a
    /// corrupt value in a point-lookup row is an unambiguous data-integrity
    /// failure and the caller must know about it.
    ///
    /// ## Contract
    ///
    /// - Returns `(clean_rows, skipped_count)`.
    /// - Rows that decode without error appear in `clean_rows`.
    /// - Rows that fail with `StorageError::CorruptStoredValue` are counted in
    ///   `skipped_count` and written to stderr as a warning (the log line names
    ///   the table, column, and stored text so the bad value can be identified).
    /// - Any **other** error (SQL engine failure, connectivity, locking) is
    ///   re-raised as `Err(…)` — those are systemic failures, not data problems.
    ///
    /// ## Default implementation
    ///
    /// Calls [`query`](Self::query) and wraps any `CorruptStoredValue` as
    /// `(vec![], 1)`. Backends that can implement row-level skipping in the
    /// engine loop (SQLite's rusqlite row iterator) override this to avoid
    /// aborting the cursor on a corrupt row.
    fn query_skip_corrupt(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<(Vec<StorageRow>, usize)> {
        // Default: call strict query; promote CorruptStoredValue to a skip.
        match self.query(table, predicate, order_by, limit, offset) {
            Ok(rows) => Ok((rows, 0)),
            Err(crate::error::StorageError::CorruptStoredValue { table: t, column: c, stored_text: s }) => {
                eprintln!(
                    "[persistence_kit] WARNING: query_skip_corrupt fallback: at least one \
                     corrupt row in '{}' (column='{}' stored_text='{}'). Backend does not \
                     support row-level skipping; returning empty result.",
                    t, c, s
                );
                Ok((vec![], 1))
            }
            Err(other) => Err(other),
        }
    }
}
