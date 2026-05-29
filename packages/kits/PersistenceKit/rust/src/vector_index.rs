//! VectorIndex trait: vector storage and k-NN search.

use crate::error::StorageResult;
use crate::predicate::StoragePredicate;
use crate::types::{RowKey, TypedValue};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DistanceMetric {
    Cosine,
    L2,
    Dot,
}

#[derive(Debug, Clone, Copy)]
pub enum IndexParameters {
    Flat,
    Ivf { lists: usize },
    Hnsw { m: usize, ef_construction: usize },
}

#[derive(Debug, Clone, Copy)]
pub enum SearchParameters {
    Flat,
    Ivf { probes: usize },
    Hnsw { ef_search: usize },
}

#[derive(Debug, Clone)]
pub struct VectorSearchResult {
    pub key: RowKey,
    pub distance: f32,
    pub metadata: BTreeMap<String, TypedValue>,
}

pub trait VectorIndex: Send + Sync {
    fn add(
        &self,
        key: RowKey,
        vector: &[f32],
        metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()>;

    fn update(
        &self,
        key: RowKey,
        vector: &[f32],
        metadata: BTreeMap<String, TypedValue>,
    ) -> StorageResult<()>;

    fn delete(&self, key: RowKey) -> StorageResult<()>;

    fn knn(
        &self,
        query: &[f32],
        k: usize,
        metric: DistanceMetric,
        filter: Option<&StoragePredicate>,
        search_parameters: Option<SearchParameters>,
    ) -> StorageResult<Vec<VectorSearchResult>>;

    fn reindex(&self, parameters: IndexParameters) -> StorageResult<()>;

    fn count(&self) -> StorageResult<usize>;
}
