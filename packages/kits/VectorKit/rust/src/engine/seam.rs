//! DenseIndex — seam protocol for dense vector indexes.
//!
//! Parallel to Swift `DenseIndex` protocol. Concrete implementations
//! (brute-force, MIH, native ANN) plug in here. The protocol is the
//! single seam point so that future lanes can swap the index without
//! touching search callers.
//!
//! `IndexKind` is an advisory tag; callers may use it to choose between
//! index implementations at startup.

use crate::engine::hit::DenseHit;
use crate::engine::key::VectorRecordKey;
use crate::engine::metric::DenseMetric;
use crate::engine::payload::VectorPayload;
use crate::error::VectorKitError;

/// Advisory index kind tag. Callers may use this to select an
/// implementation at startup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IndexKind {
    /// Linear brute-force scan. Always correct; the float lane's exact
    /// production path and the reference oracle for other indexes.
    BruteForce,
    /// Multi-index hashing for 256-bit binary vectors.
    Mih,
}

/// Ranking direction for a float-lane search. Parallel to Swift
/// `SearchDirection` (DenseIndex.swift).
///
/// The float index ranks by cosine distance (`1 − cosineSimilarity`),
/// "nearer first" meaning smaller distance / larger similarity. Anti-
/// similarity retrieval ("find things UNLIKE this", mission
/// 6b-modifiers-antisim) wants the opposite end of the SAME ranking: the
/// most DISSIMILAR vectors — bottom-K by cosine similarity, i.e. top-K by
/// cosine distance.
///
///   - `Nearest`  — most similar first (smallest cosine distance). The
///     default; reproduces the pre-antisim ordering byte-for-byte.
///   - `Farthest` — most dissimilar first (largest cosine distance). NOT a
///     negated nearest-list (the farthest items are not in the nearest
///     top-K), so the index orders by the opposite end. No new distance
///     math — the same cosine, the opposite sort.
///
/// Tie-break stays `item_id` ascending in BOTH directions (§0.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SearchDirection {
    /// Most similar first (smallest cosine distance). Default behaviour.
    Nearest,
    /// Most dissimilar first (largest cosine distance). Anti-similarity.
    Farthest,
}

/// Filter applied during search to restrict results to a subset of
/// the indexed vectors. `None` fields are unconstrained.
#[derive(Debug, Clone, Default)]
pub struct MetadataFilter {
    /// If `Some`, only include vectors whose `model_id` matches.
    pub model_id: Option<String>,
    /// If `Some`, only include vectors whose `model_version` matches.
    pub model_version: Option<String>,
}

impl MetadataFilter {
    /// Returns `true` if `key` satisfies all constraints in the filter.
    pub fn accepts(&self, key: &VectorRecordKey) -> bool {
        if let Some(ref mid) = self.model_id {
            if &key.model_id != mid {
                return false;
            }
        }
        if let Some(ref ver) = self.model_version {
            if &key.model_version != ver {
                return false;
            }
        }
        true
    }
}

/// Seam trait for dense vector indexes. Parallel to Swift `DenseIndex`
/// protocol.
///
/// All methods take the probe as a `VectorPayload` so that the
/// implementation can dispatch on `kind` without the caller needing to
/// know whether the index is binary or float.
pub trait DenseIndex: Send + Sync {
    /// The kind of index this implementation is.
    fn kind(&self) -> IndexKind;

    /// Build or rebuild the index from the given vectors and keys.
    /// The slices must have the same length.
    fn build(
        &mut self,
        vectors: &[VectorPayload],
        keys: &[VectorRecordKey],
    ) -> Result<(), VectorKitError>;

    /// Search for the `k` nearest neighbours of `probe`.
    fn search(
        &self,
        probe: &VectorPayload,
        metric: DenseMetric,
        k: usize,
        filter: Option<&MetadataFilter>,
    ) -> Result<Vec<DenseHit>, VectorKitError>;

    /// Incrementally add a single vector. May require a rebuild call
    /// before the added vector appears in search results (implementation
    /// dependent).
    fn add(
        &mut self,
        key: VectorRecordKey,
        vector: VectorPayload,
    ) -> Result<(), VectorKitError>;

    /// Mark a key as deleted. The implementation may defer compaction.
    fn remove(&mut self, key: &VectorRecordKey) -> Result<(), VectorKitError>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::key::VectorRecordKey;

    fn key(item_id: &str, model_id: &str) -> VectorRecordKey {
        VectorRecordKey::new(item_id, 0, model_id, "1")
    }

    #[test]
    fn metadata_filter_no_constraints_accepts_any_key() {
        let f = MetadataFilter::default();
        assert!(f.accepts(&key("item-1", "model-a")));
    }

    #[test]
    fn metadata_filter_model_id_constraint() {
        let f = MetadataFilter {
            model_id: Some("model-a".to_string()),
            model_version: None,
        };
        assert!(f.accepts(&key("item-1", "model-a")));
        assert!(!f.accepts(&key("item-1", "model-b")));
    }

    #[test]
    fn metadata_filter_combined_constraints() {
        let f = MetadataFilter {
            model_id: Some("model-a".to_string()),
            model_version: Some("1".to_string()),
        };
        assert!(f.accepts(&key("item-1", "model-a")));
        // model_version mismatch via a key with a different version
        let k = VectorRecordKey::new("item-1", 0, "model-a", "2");
        assert!(!f.accepts(&k));
    }
}
