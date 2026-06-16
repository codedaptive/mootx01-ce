//! DenseHit — per-lane dense search result carrier.
//!
//! Parallel to Swift `DenseHit`. Carries the raw per-lane distance upward
//! without pre-fusing — this is the fix for VectorMatch/RecallHit
//! discarding the raw score (Kong Cond-4). Dense-first selection and the
//! fusion layer consume `raw_distance` directly.
//!
//! Ordering: `raw_distance` ascending (smaller = closer), with `key`
//! ascending as the universal tie-break (retrieval algorithms reference
//! §0.3: smaller id wins).

use crate::engine::key::VectorRecordKey;
use crate::engine::metric::DenseMetric;
use std::cmp::Ordering;

/// Canonical lane-tag enum. Downstream lanes (SPLADE, ColBERT, fusion)
/// use this to identify which retrieval lane contributed a score.
/// Canonical definition lives in CorpusKit's `SparseTypes`; re-exported
/// here for callers that only depend on VectorKit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum LaneTag {
    /// 256-bit Hamming lane.
    BinaryDense,
    /// Float32 / int8 cosine/L2/dot lane.
    FloatDense,
    /// SPLADE sparse impact lane.
    Sparse,
    /// Late-interaction (e.g., ColBERT MaxSim) lane.
    LateInteraction,
}

/// Result carrier for a single dense lane hit.
///
/// `raw_distance` is always an integer because the binary path is
/// integer-only (Hamming popcount) and float distances are quantised
/// to `i32` before being stored here so downstream fusion sees a
/// uniform type. Float-lane callers use the typed accessor
/// `float_distance()` to recover the f32.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DenseHit {
    pub key: VectorRecordKey,
    /// Raw per-lane distance. For binary lanes: Hamming popcount (0–256).
    /// For float lanes: distance × 10_000 truncated to i32.
    pub raw_distance: i32,
    pub metric: DenseMetric,
}

impl DenseHit {
    /// The Hamming distance for Binary metrics. Returns `None` if
    /// the metric is not binary.
    pub fn hamming_distance(&self) -> Option<u32> {
        if self.metric.is_binary() {
            Some(self.raw_distance as u32)
        } else {
            None
        }
    }

    /// The float distance for Float metrics. Returns `None` if the
    /// metric is not float.
    pub fn float_distance(&self) -> Option<f32> {
        if self.metric.is_float() {
            Some(self.raw_distance as f32 / 10_000.0)
        } else {
            None
        }
    }
}

impl Ord for DenseHit {
    fn cmp(&self, other: &Self) -> Ordering {
        // Primary: raw_distance ascending (smaller = closer).
        // Tiebreak: key ascending (universal tie-break rule §0.3).
        self.raw_distance
            .cmp(&other.raw_distance)
            .then(self.key.cmp(&other.key))
    }
}

impl PartialOrd for DenseHit {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::metric::DenseMetric;

    fn key(item_id: &str) -> VectorRecordKey {
        VectorRecordKey::new(item_id, 0, "m", "1")
    }

    #[test]
    fn hamming_distance_returns_some_for_binary() {
        let hit = DenseHit { key: key("a"), raw_distance: 7, metric: DenseMetric::HAMMING };
        assert_eq!(hit.hamming_distance(), Some(7));
        assert_eq!(hit.float_distance(), None);
    }

    #[test]
    fn float_distance_returns_some_for_float() {
        // 15000 raw → 1.5 f32
        let hit = DenseHit { key: key("a"), raw_distance: 15_000, metric: DenseMetric::COSINE };
        assert_eq!(hit.float_distance(), Some(1.5_f32));
        assert_eq!(hit.hamming_distance(), None);
    }

    #[test]
    fn ordering_by_raw_distance_ascending() {
        let near = DenseHit { key: key("b"), raw_distance: 1, metric: DenseMetric::HAMMING };
        let far  = DenseHit { key: key("a"), raw_distance: 9, metric: DenseMetric::HAMMING };
        assert!(near < far);
    }

    #[test]
    fn equal_distance_tiebreak_by_key_ascending() {
        let lhs = DenseHit { key: key("x"), raw_distance: 5, metric: DenseMetric::HAMMING };
        let rhs = DenseHit { key: key("y"), raw_distance: 5, metric: DenseMetric::HAMMING };
        // "x" < "y" → lhs < rhs
        assert!(lhs < rhs);
    }
}
