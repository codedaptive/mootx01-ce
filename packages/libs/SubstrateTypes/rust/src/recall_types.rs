// recall_types.rs
//
// Canonical Rust recall vocabulary — mirrors Swift RecallTypes.swift
// from Sources/SubstrateTypes/RecallTypes.swift.
//
// Bob overrode the prior "Swift-only" asymmetry decision (see the
// SWIFT/RUST ASYMMETRY comment in RecallTypes.swift) with a
// force-full-mirror ruling (PAR-1A + PAR-3A-ST, 2026-06-05).
//
// These four types now have canonical Rust equivalents here in
// substrate-types. A separate Wave-2 track reconciles
// RecallScoreLite / RecallResultLite in SubstrateML's tier_query.rs
// to consume these canonical types instead of re-declaring them.
// DO NOT modify SubstrateML in this file.
//
// Type mapping (Swift → Rust):
//   RecallScore        → RecallScore        (rowId: RowId, score: f32)
//   DistanceBreakdown  → DistanceBreakdown  (four f32 contributions)
//   RecallResult       → RecallResult       (rows, breakdown, ci, name)
//   RowProjection      → RowProjection      (rowId, hlc, fp, lattice,
//                                            bitmaps, row_state)
//
// RowId in Rust is u128 (mirrors Swift UUID). Float32 maps to f32.
// The bitmaps tuple uses u64 (mirrors Swift UInt64 components).

use crate::fingerprint256::Fingerprint256;
use crate::hlc::HLC;
use crate::lattice_anchor::LatticeAnchor;
use crate::row::RowId;

/// A single (RowId, score) pair from a recall primitive.
///
/// The score's meaning is per-primitive: cosine for vector recall,
/// Hamming-distance (inverted) for fingerprint recall, BM25 for
/// text recall. Composition primitives (RRF, MMR) normalize across
/// scoring scales.
///
/// Mirrors Swift `RecallScore` (rowId: RowId, score: Float32).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RecallScore {
    pub row_id: RowId,
    /// Per-primitive score value in a normalized [0, 1] range after
    /// composition. Raw primitive scores may exceed 1.0 (e.g. BM25);
    /// normalization is the caller's responsibility.
    pub score: f32,
}

impl RecallScore {
    pub fn new(row_id: RowId, score: f32) -> Self {
        Self { row_id, score }
    }
}

/// Per-component distance contributions for a recall result.
///
/// Each contribution is in [0, 1] after normalization. Used to
/// surface "why this row matched" to downstream consumers and to
/// drive Reciprocal Rank Fusion weights.
///
/// Mirrors Swift `DistanceBreakdown` (lattice, fingerprint, temporal,
/// bitmap contributions as Float32).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DistanceBreakdown {
    /// Lattice (UDC tree) contribution in [0, 1].
    pub lattice_contribution: f32,
    /// Fingerprint (Hamming) contribution in [0, 1].
    pub fingerprint_contribution: f32,
    /// Temporal (HLC distance) contribution in [0, 1].
    pub temporal_contribution: f32,
    /// Bitmap predicate contribution in [0, 1].
    pub bitmap_contribution: f32,
}

impl DistanceBreakdown {
    /// All-zero breakdown — the default when no component attribution
    /// is available. Mirrors Swift `DistanceBreakdown()` default init.
    pub const ZERO: DistanceBreakdown = DistanceBreakdown {
        lattice_contribution: 0.0,
        fingerprint_contribution: 0.0,
        temporal_contribution: 0.0,
        bitmap_contribution: 0.0,
    };

    pub fn new(lattice: f32, fingerprint: f32, temporal: f32, bitmap: f32) -> Self {
        Self {
            lattice_contribution: lattice,
            fingerprint_contribution: fingerprint,
            temporal_contribution: temporal,
            bitmap_contribution: bitmap,
        }
    }
}

impl Default for DistanceBreakdown {
    fn default() -> Self {
        Self::ZERO
    }
}

/// A ranked recall result.
///
/// Carries the ranked list of (RowId, score) pairs, an optional
/// per-component distance breakdown, an optional confidence interval,
/// and the primitive's name for composition tracking.
///
/// Mirrors Swift `RecallResult` (rows, breakdown, confidenceInterval,
/// primitiveName).
#[derive(Debug, Clone)]
pub struct RecallResult {
    /// Rows in descending score order.
    pub rows: Vec<RecallScore>,
    /// Per-component attribution. Defaults to all-zero when the
    /// primitive does not supply attribution.
    pub breakdown: DistanceBreakdown,
    /// Optional [lower, upper] confidence interval on the scores.
    /// Mirrors Swift `(lower: Float32, upper: Float32)?`.
    pub confidence_interval: Option<(f32, f32)>,
    /// Name of the recall primitive that produced this result. Used
    /// by RRF / MMR composition to track provenance.
    pub primitive_name: String,
}

impl RecallResult {
    pub fn new(
        rows: Vec<RecallScore>,
        breakdown: DistanceBreakdown,
        confidence_interval: Option<(f32, f32)>,
        primitive_name: impl Into<String>,
    ) -> Self {
        Self {
            rows,
            breakdown,
            confidence_interval,
            primitive_name: primitive_name.into(),
        }
    }

    /// Convenience constructor with default (zero) breakdown and no
    /// confidence interval.
    pub fn simple(rows: Vec<RecallScore>, primitive_name: impl Into<String>) -> Self {
        Self::new(rows, DistanceBreakdown::ZERO, None, primitive_name)
    }
}

/// Minimal projection of a substrate row consumed by recall
/// primitives.
///
/// Deliberately omits the verbatim content blob (rung 1) and
/// structured metadata (rung 2 beyond bitmaps). Primitives operate
/// on the structural fingerprint and bitmap predicates; verbatim
/// content is fetched separately after ranking is settled.
///
/// Mirrors Swift `RowProjection` (rowId, captureHLC, fingerprint,
/// lattice, bitmaps: (UInt64, UInt64, UInt64), rowState: UInt8).
#[derive(Debug, Clone)]
pub struct RowProjection {
    pub row_id: RowId,
    pub capture_hlc: HLC,
    pub fingerprint: Fingerprint256,
    pub lattice: LatticeAnchor,
    /// Three bitmap columns as raw u64 (adjective, operational,
    /// provenance). Mirrors Swift's tuple
    /// `(adjective: UInt64, operational: UInt64, provenance: UInt64)`.
    pub bitmaps: (u64, u64, u64),
    /// Raw row state discriminant (RowState::active = 0, etc.).
    /// Using u8 mirrors the Swift `rowState: UInt8` field directly
    /// rather than requiring a RowState import into this type.
    pub row_state: u8,
}

impl RowProjection {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        row_id: RowId,
        capture_hlc: HLC,
        fingerprint: Fingerprint256,
        lattice: LatticeAnchor,
        bitmaps: (u64, u64, u64),
        row_state: u8,
    ) -> Self {
        Self { row_id, capture_hlc, fingerprint, lattice, bitmaps, row_state }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::row::RowId;
    use crate::fingerprint256::Fingerprint256;
    use crate::hlc::HLC;
    use crate::lattice_anchor::LatticeAnchor;

    // --- RecallScore ---

    #[test]
    fn recall_score_fields() {
        let rs = RecallScore::new(RowId(42), 0.75);
        assert_eq!(rs.row_id, RowId(42));
        assert!((rs.score - 0.75).abs() < 1e-7);
    }

    #[test]
    fn recall_score_equality() {
        let a = RecallScore::new(RowId(1), 0.5);
        let b = RecallScore::new(RowId(1), 0.5);
        assert_eq!(a, b);
        let c = RecallScore::new(RowId(2), 0.5);
        assert_ne!(a, c);
    }

    // --- DistanceBreakdown ---

    #[test]
    fn distance_breakdown_zero_constant() {
        let z = DistanceBreakdown::ZERO;
        assert_eq!(z.lattice_contribution, 0.0);
        assert_eq!(z.fingerprint_contribution, 0.0);
        assert_eq!(z.temporal_contribution, 0.0);
        assert_eq!(z.bitmap_contribution, 0.0);
    }

    #[test]
    fn distance_breakdown_new() {
        let db = DistanceBreakdown::new(0.1, 0.2, 0.3, 0.4);
        assert!((db.lattice_contribution     - 0.1).abs() < 1e-7);
        assert!((db.fingerprint_contribution - 0.2).abs() < 1e-7);
        assert!((db.temporal_contribution    - 0.3).abs() < 1e-7);
        assert!((db.bitmap_contribution      - 0.4).abs() < 1e-7);
    }

    #[test]
    fn distance_breakdown_default_is_zero() {
        let d: DistanceBreakdown = Default::default();
        assert_eq!(d, DistanceBreakdown::ZERO);
    }

    // --- RecallResult ---

    #[test]
    fn recall_result_rows_empty() {
        let rr = RecallResult::simple(vec![], "hamming");
        assert!(rr.rows.is_empty());
        assert_eq!(rr.primitive_name, "hamming");
        assert!(rr.confidence_interval.is_none());
        assert_eq!(rr.breakdown, DistanceBreakdown::ZERO);
    }

    #[test]
    fn recall_result_with_breakdown_and_ci() {
        let rows = vec![
            RecallScore::new(RowId(1), 0.9),
            RecallScore::new(RowId(2), 0.7),
        ];
        let bd = DistanceBreakdown::new(0.25, 0.50, 0.15, 0.10);
        let rr = RecallResult::new(rows, bd, Some((0.6, 1.0)), "hybrid");
        assert_eq!(rr.rows.len(), 2);
        assert_eq!(rr.primitive_name, "hybrid");
        let ci = rr.confidence_interval.unwrap();
        assert!((ci.0 - 0.6).abs() < 1e-7);
        assert!((ci.1 - 1.0).abs() < 1e-7);
        assert!((rr.breakdown.fingerprint_contribution - 0.50).abs() < 1e-7);
    }

    // --- RowProjection ---

    #[test]
    fn row_projection_fields() {
        let hlc = HLC::new(1_000_000, 0, 1);
        let fp  = Fingerprint256::ZERO;
        let lat = LatticeAnchor::udc("632.5");
        let rp  = RowProjection::new(
            RowId(99),
            hlc,
            fp,
            lat.clone(),
            (0xAA, 0xBB, 0xCC),
            0, // RowState::active
        );
        assert_eq!(rp.row_id, RowId(99));
        assert_eq!(rp.capture_hlc, hlc);
        assert_eq!(rp.fingerprint, fp);
        assert_eq!(rp.lattice, lat);
        assert_eq!(rp.bitmaps, (0xAA, 0xBB, 0xCC));
        assert_eq!(rp.row_state, 0);
    }
}
