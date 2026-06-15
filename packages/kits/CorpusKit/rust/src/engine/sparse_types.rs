//! Sparse lane types — canonical definitions.
//!
//! Parallel to Swift `SparseTypes.swift` in CorpusKit.
//!
//! - `LaneTag` — canonical enum identifying the retrieval lane that
//!   produced a score. Re-exported from VectorKit's engine::hit so
//!   that the types are physically identical; this module is the
//!   documentation-canonical home.
//! - `ImpactPosting` — one row in a SPLADE impact list. Integer-only
//!   on the query path (quantised `i32`), never float.
//! - `SparseHit` — consumer-facing normalised score (f32).
//! - `FusedHit` — result carrier after cross-lane fusion, carrying
//!   the fused score and the per-lane breakdown.
//!
//! A downstream lane that needs a new field on any of these types
//! files an FT-1 update to this file rather than adding it locally.

use std::collections::HashMap;

// Canonical `LaneTag` definition lives in vectorkit::engine::hit.
// Re-export from there so the Swift/Rust type systems share the same
// set of variants.
pub use vectorkit::engine::hit::LaneTag;

/// One row in a SPLADE-style impact list.
///
/// `impact` is a quantised integer — never f32 on the query path.
/// The integer-only contract is required by the binary/integer
/// conformance gate (four-way: Swift scalar, Swift Metal, Rust scalar,
/// Rust BLAS/NEON).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImpactPosting {
    pub item_id: String,
    /// Quantised impact score. Larger = stronger signal.
    pub impact: i32,
}

impl ImpactPosting {
    pub fn new(item_id: impl Into<String>, impact: i32) -> Self {
        ImpactPosting {
            item_id: item_id.into(),
            impact,
        }
    }
}

/// Consumer-facing sparse hit: item ID + normalised impact score.
///
/// `impact` is an `f32` here (post-normalisation, for presentation
/// to fusion or to the caller). The raw integer lives in
/// `ImpactPosting` on the critical path.
#[derive(Debug, Clone, PartialEq)]
pub struct SparseHit {
    pub item_id: String,
    pub impact: f32,
}

impl SparseHit {
    pub fn new(item_id: impl Into<String>, impact: f32) -> Self {
        SparseHit {
            item_id: item_id.into(),
            impact,
        }
    }
}

/// Fused hit produced by cross-lane fusion (RRF or learned combiner).
///
/// `fused_score` is the combined score; `per_lane` carries the
/// individual lane contributions for explainability and ablation.
/// Lanes absent from `per_lane` contributed a score of zero.
///
/// The `per_lane` map uses `LaneTag` as key so the fusion layer can
/// index directly without string matching.
#[derive(Debug, Clone, PartialEq)]
pub struct FusedHit {
    pub item_id: String,
    pub fused_score: f32,
    /// Per-lane score breakdown. Empty map means all lanes contributed
    /// through the fused_score but the breakdown was not requested.
    pub per_lane: HashMap<LaneTag, f32>,
}

impl FusedHit {
    /// Construct with an empty per-lane breakdown.
    pub fn new(item_id: impl Into<String>, fused_score: f32) -> Self {
        FusedHit {
            item_id: item_id.into(),
            fused_score,
            per_lane: HashMap::new(),
        }
    }

    /// Construct with an explicit per-lane breakdown.
    pub fn with_lanes(
        item_id: impl Into<String>,
        fused_score: f32,
        per_lane: HashMap<LaneTag, f32>,
    ) -> Self {
        FusedHit {
            item_id: item_id.into(),
            fused_score,
            per_lane,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn impact_posting_round_trips() {
        let p = ImpactPosting::new("item-1", 42);
        assert_eq!(p.item_id, "item-1");
        assert_eq!(p.impact, 42);
    }

    #[test]
    fn sparse_hit_round_trips() {
        let h = SparseHit::new("item-2", 0.75);
        assert_eq!(h.item_id, "item-2");
        assert!((h.impact - 0.75).abs() < 1e-6);
    }

    #[test]
    fn fused_hit_empty_per_lane() {
        let h = FusedHit::new("item-3", 1.25);
        assert_eq!(h.item_id, "item-3");
        assert!((h.fused_score - 1.25).abs() < 1e-6);
        assert!(h.per_lane.is_empty());
    }

    #[test]
    fn fused_hit_with_lanes() {
        let mut lanes = HashMap::new();
        lanes.insert(LaneTag::BinaryDense, 0.6);
        lanes.insert(LaneTag::Sparse, 0.4);
        let h = FusedHit::with_lanes("item-4", 1.0, lanes);
        assert_eq!(h.per_lane.len(), 2);
        assert!((h.per_lane[&LaneTag::BinaryDense] - 0.6).abs() < 1e-6);
    }

    #[test]
    fn lane_tag_variants_exist() {
        // Verify the re-export covers all expected variants.
        let _tags = [
            LaneTag::BinaryDense,
            LaneTag::FloatDense,
            LaneTag::Sparse,
            LaneTag::LateInteraction,
        ];
    }
}
