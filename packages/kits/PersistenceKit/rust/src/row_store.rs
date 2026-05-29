//! RowStore trait: typed row I/O.

use crate::error::StorageResult;
use crate::predicate::{OrderClause, StoragePredicate};
use crate::types::{RowHandle, StorageRow, TypedValue};
use std::collections::BTreeMap;

pub trait RowStore: Send + Sync {
    fn insert(
        &self,
        table: &str,
        values: BTreeMap<String, TypedValue>,
    ) -> StorageResult<RowHandle>;

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

    fn delete(
        &self,
        table: &str,
        predicate: &StoragePredicate,
    ) -> StorageResult<usize>;

    fn query(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
        order_by: &[OrderClause],
        limit: Option<usize>,
        offset: Option<usize>,
    ) -> StorageResult<Vec<StorageRow>>;

    fn count(
        &self,
        table: &str,
        predicate: Option<&StoragePredicate>,
    ) -> StorageResult<usize>;
}
