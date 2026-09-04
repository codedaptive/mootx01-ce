//! VectorRecordKey — the multi-vector primary key.
//!
//! Parallel to Swift `VectorRecordKey`. The three-tuple
//! `(item_id, vector_index, model_id)` uniquely identifies a row in the
//! `vectors` table. `vector_index` is 0 for single-vector models and
//! counts token position for multi-vector models (ColBERT, late interaction).
//!
//! `model_version` travels with the key to avoid gratuitous re-fetches —
//! callers that already know the version don't need an extra lookup.
//!
//! Ordering: lexicographic over `(item_id, vector_index, model_id,
//! model_version)`, consistent with the universal tie-break rule
//! (retrieval algorithms reference §0.3): smaller id wins.

use std::cmp::Ordering;

/// Three-tuple multi-vector primary key plus the model version for
/// convenience. Parallel to Swift `VectorRecordKey`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct VectorRecordKey {
    pub item_id: String,
    /// Token / slice index within a multi-vector item. 0 for
    /// single-vector representations (dense, SPLADE).
    pub vector_index: u32,
    pub model_id: String,
    pub model_version: String,
}

impl VectorRecordKey {
    pub fn new(
        item_id: impl Into<String>,
        vector_index: u32,
        model_id: impl Into<String>,
        model_version: impl Into<String>,
    ) -> Self {
        VectorRecordKey {
            item_id: item_id.into(),
            vector_index,
            model_id: model_id.into(),
            model_version: model_version.into(),
        }
    }
}

impl Ord for VectorRecordKey {
    fn cmp(&self, other: &Self) -> Ordering {
        self.item_id
            .cmp(&other.item_id)
            .then(self.vector_index.cmp(&other.vector_index))
            .then(self.model_id.cmp(&other.model_id))
            .then(self.model_version.cmp(&other.model_version))
    }
}

impl PartialOrd for VectorRecordKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_equal_when_all_fields_match() {
        let a = VectorRecordKey::new("item-1", 0, "model-a", "1.0");
        let b = VectorRecordKey::new("item-1", 0, "model-a", "1.0");
        assert_eq!(a, b);
    }

    #[test]
    fn ordering_is_lexicographic_item_id_first() {
        let a = VectorRecordKey::new("alpha", 0, "m", "1");
        let b = VectorRecordKey::new("beta", 0, "m", "1");
        assert!(a < b);
    }

    #[test]
    fn ordering_tiebreaks_by_vector_index() {
        let a = VectorRecordKey::new("item", 0, "m", "1");
        let b = VectorRecordKey::new("item", 1, "m", "1");
        assert!(a < b);
    }
}
