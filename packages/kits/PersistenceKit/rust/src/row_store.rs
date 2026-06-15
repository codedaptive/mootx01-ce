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
}
