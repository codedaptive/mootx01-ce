// recall_shape_matrix_steer_parity.rs
//
// Parity tests for 6b-modifiers-matrix-steer: the five matrix/graph/preference
// columns (fieldFit, coOccurrence, temporal, graph, preference) are now
// RecallShape-steerable in the unionBest MatrixAware weighted-column score, with
// the same signed semantics as the retrieval lanes (1.0 neutral, 0 excludes,
// <0 suppresses). Mirrors Swift RecallShapeMatrixSteerTests.swift.
//
//   (a) fieldFit weight 0 zeroes the fieldFit column's effect on the fused score.
//   (b) fieldFit weight < 0 SUBTRACTS the column — strictly lower than weight 0.
//   (c) a temporal-up shape ranks the temporally-relevant drawer no lower than a
//       temporal-down shape — temporal steering is live.
//   (d) with a constant GraphCache (0.8) / PreferenceStore (0.9) registered, the
//       graph / preference columns are LIVE: excluding them (weight 0) changes a
//       fused final, and graph weight < 0 subtracts strictly below weight 0 —
//       mirroring Swift RecallShapeMatrixSteerTests (a)/(b)/(c). This closes the
//       ADR-011 D-4 parity violation (Rust no longer hardcodes the columns dark).
//   (e) nil shape == an explicit all-ones shape over EVERY steerable key is
//       BYTE-IDENTICAL (back-compat).
//
// A MatrixTier rebuilt from the captured drawers' own audit log plus a seeded
// temporal prior makes fieldFit / coOccurrence / temporal non-zero, exactly as the
// Swift test builds the tier via MatrixTier.rebuild(from: auditLog).

use std::collections::HashMap;
use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::matrix::{MatrixTier, MatrixValueCoord};
use genius_locus_kit::audit::UnifiedAuditValue;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, GraphCache,
    PreferenceStore, RecallShape,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000;

/// Constant graph cache — every drawer gets the same score, so the column is
/// measured-uniform (normalize → 0.5 every slot) and its steered contribution
/// moves every fused final by the same deterministic amount. Mirrors Swift
/// `ConstantGraphCache` in RecallShapeMatrixSteerTests.
struct ConstantGraphCache {
    score: f32,
}
impl GraphCache for ConstantGraphCache {
    fn graph_score(&self, _drawer_id: &str) -> f32 {
        self.score
    }
}

/// Constant preference store — same constant-column rationale as the graph cache.
/// Mirrors Swift `ConstantPreferenceStore`.
struct ConstantPreferenceStore {
    score: f32,
}
impl PreferenceStore for ConstantPreferenceStore {
    fn preference_score(&self, _drawer_id: &str) -> f32 {
        self.score
    }
}

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str, channel: CaptureChannel) -> CaptureFrame {
    CaptureFrame::new(
        content,
        channel,
        "matrix-steer-tests",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

/// Open an estate with two drawers captured on distinct channels (so their
/// operational bitmaps differ and a temporal prior is seedable). Returns
/// (coord, handle, d1_id, d2_id).
fn two_drawer_estate() -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    String,
    String,
) {
    let (coord, h) = open_one();
    let d1 = coord
        .capture(&h, cap_frame("matrix steer alpha content", CaptureChannel::Typed), NOW)
        .expect("capture d1");
    let d2 = coord
        .capture(&h, cap_frame("matrix steer beta content", CaptureChannel::Voiced), NOW + 1)
        .expect("capture d2");
    (coord, h, d1.id, d2.id)
}

/// Rebuild a MatrixTier from the estate's audit log and seed a strong temporal
/// prior between the two drawers (mirrors Swift seedMatrixTier). Returns whether
/// the prior was actually seeded (distinguishable bitmaps).
fn seed_matrix_tier(
    coord: &mut EstateCoordinator,
    h: &genius_locus_kit::handle::EstateHandle,
    d1: &str,
    d2: &str,
) -> bool {
    coord.feed_audit_log(h).expect("feed_audit_log");
    let log = coord.audit_log(h).expect("audit_log");
    let mut tier = MatrixTier::full_rebuild(&log, &std::collections::HashMap::new());
    let drawers = coord.all_drawers(h).unwrap_or_default();
    let d1_op = drawers.iter().find(|d| d.id == d1).map(|d| d.operational_bitmap as u64).unwrap_or(0);
    let d2_op = drawers.iter().find(|d| d.id == d2).map(|d| d.operational_bitmap as u64).unwrap_or(0);
    let mut seeded = false;
    if d1_op != 0 && d2_op != 0 && d1_op != d2_op {
        let src = MatrixValueCoord::new("operational", UnifiedAuditValue::Bitmap(d1_op));
        let tgt = MatrixValueCoord::new("operational", UnifiedAuditValue::Bitmap(d2_op));
        tier.apply_temporal_event(src, tgt, 2, 1000);
        seeded = true;
    }
    coord.register_matrix_tier(h, tier);
    seeded
}

fn matrix_req(shape: Option<RecallShape>) -> GLKRecallRequest {
    let mut req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_limit(10);
    if let Some(s) = shape {
        req = req.with_recall_shape(s);
    }
    req
}

fn shape(weights: &[(&str, f32)]) -> RecallShape {
    let mut m = HashMap::new();
    for (k, v) in weights {
        m.insert((*k).to_string(), *v);
    }
    RecallShape::new(m, None)
}

fn finals(result: &GLKRecallResult) -> HashMap<String, f32> {
    result.hits.iter().map(|h| (h.id.clone(), h.score.final_score)).collect()
}

// MARK: - (a) fieldFit weight 0 zeroes the fieldFit column's effect

/// With a seeded MatrixTier making the fieldFit column non-zero, excluding the
/// fieldFit column (weight 0) must change at least one fused final relative to the
/// neutral (nil) recall — the column contributed mass that exclusion removes.
#[test]
fn field_fit_weight_zero_excludes_column() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    seed_matrix_tier(&mut coord, &h, &d1, &d2);

    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let excluded = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("fieldFit", 0.0)]))), NOW + 11)
        .expect("excluded");

    let neutral_finals = finals(&neutral);
    let changed = excluded.hits.iter().any(|hit| {
        neutral_finals.get(&hit.id).map_or(false, |b| *b != hit.score.final_score)
    });
    assert!(
        changed,
        "excluding the fieldFit column (w=0) must change at least one fused final"
    );
}

// MARK: - (b) fieldFit weight < 0 subtracts — strictly lower than weight 0

/// Demotion vs exclusion are distinct: fieldFit weight `-1` SUBTRACTS the column
/// mass while weight `0` merely drops it. For every drawer present in both
/// results, the suppressed (w<0) fused final must be at/below the excluded (w=0)
/// final, and at least one strictly below — the subtracted column mass is the gap.
#[test]
fn field_fit_negative_weight_subtracts() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    seed_matrix_tier(&mut coord, &h, &d1, &d2);

    let excluded = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("fieldFit", 0.0)]))), NOW + 10)
        .expect("excluded");
    let suppressed = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("fieldFit", -1.0)]))), NOW + 11)
        .expect("suppressed");

    let excluded_finals = finals(&excluded);
    let mut saw_strictly_lower = false;
    for hit in &suppressed.hits {
        if let Some(zero_final) = excluded_finals.get(&hit.id) {
            assert!(
                hit.score.final_score <= zero_final + 1e-6,
                "suppressed fieldFit final must not exceed the excluded final; {}: w<0={} w0={}",
                hit.id, hit.score.final_score, zero_final
            );
            if hit.score.final_score < zero_final - 1e-6 {
                saw_strictly_lower = true;
            }
        }
    }
    assert!(
        saw_strictly_lower,
        "fieldFit w=-1 must subtract mass — at least one drawer strictly below the w=0 final"
    );
}

// MARK: - (c) temporal steering is live (up >= down)

/// A temporal-up shape (temporal=2) must rank the temporally-relevant drawer no
/// lower than a temporal-down shape (temporal=0), and must change its fused final.
/// When the environment cannot seed a distinguishable prior the columns are 0 and
/// the orders coincide — still valid, asserted by the non-empty guard.
#[test]
fn temporal_up_ranks_relevant_no_lower() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    let seeded = seed_matrix_tier(&mut coord, &h, &d1, &d2);

    let up = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("temporal", 2.0)]))), NOW + 10)
        .expect("up");
    let down = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("temporal", 0.0)]))), NOW + 11)
        .expect("down");

    assert!(
        !up.hits.is_empty() && !down.hits.is_empty(),
        "both temporal-steered recalls must return hits"
    );

    if seeded {
        let up_rank = up.hits.iter().position(|hit| hit.id == d2);
        let down_rank = down.hits.iter().position(|hit| hit.id == d2);
        if let (Some(u), Some(d)) = (up_rank, down_rank) {
            assert!(
                u <= d,
                "temporal-up must rank the temporally-relevant drawer no lower than temporal-down; up={u} down={d}"
            );
        }
        let up_final = up.hits.iter().find(|hit| hit.id == d2).map(|hit| hit.score.final_score);
        let down_final = down.hits.iter().find(|hit| hit.id == d2).map(|hit| hit.score.final_score);
        if let (Some(uf), Some(df)) = (up_final, down_final) {
            assert!(
                uf != df,
                "temporal steering must change the relevant drawer's fused final; up={uf} down={df}"
            );
        }
    }
}

// MARK: - (d) graph / preference columns are LIVE with a registered cache

/// With a constant GraphCache(0.8) registered, excluding the graph column
/// (weight 0) must change at least one fused final relative to the neutral (nil)
/// recall — the live column contributed mass that exclusion removes. Mirrors
/// Swift RecallShapeMatrixSteerTests.graphWeightZeroExcludesColumn. This is the
/// proof the Rust column is no longer hardcoded dark (ADR-011 D-4).
#[test]
fn graph_weight_zero_excludes_live_column() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    seed_matrix_tier(&mut coord, &h, &d1, &d2);
    coord.register_graph_cache(&h, Arc::new(ConstantGraphCache { score: 0.8 }));

    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let excluded = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("graph", 0.0)]))), NOW + 11)
        .expect("excluded");

    let neutral_finals = finals(&neutral);
    let changed = excluded.hits.iter().any(|hit| {
        neutral_finals.get(&hit.id).map_or(false, |b| *b != hit.score.final_score)
    });
    assert!(
        changed,
        "excluding the live graph column (w=0) must change at least one fused final"
    );
}

/// With a constant PreferenceStore(0.9) registered, excluding the preference
/// column (weight 0) must change at least one fused final. Mirrors Swift
/// RecallShapeMatrixSteerTests.preferenceWeightZeroExcludesColumn.
#[test]
fn preference_weight_zero_excludes_live_column() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    seed_matrix_tier(&mut coord, &h, &d1, &d2);
    coord.register_preference_store(&h, Arc::new(ConstantPreferenceStore { score: 0.9 }));

    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let excluded = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("preference", 0.0)]))), NOW + 11)
        .expect("excluded");

    let neutral_finals = finals(&neutral);
    let changed = excluded.hits.iter().any(|hit| {
        neutral_finals.get(&hit.id).map_or(false, |b| *b != hit.score.final_score)
    });
    assert!(
        changed,
        "excluding the live preference column (w=0) must change at least one fused final"
    );
}

/// Demotion vs exclusion are distinct: with a constant graph column, weight `-1`
/// SUBTRACTS the column mass while weight `0` merely drops it. For every drawer
/// present in both results, the suppressed (w<0) fused final must be at/below the
/// excluded (w=0) final, and at least one strictly below. Mirrors Swift
/// RecallShapeMatrixSteerTests.graphNegativeWeightSubtracts.
#[test]
fn graph_negative_weight_subtracts_live_column() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    seed_matrix_tier(&mut coord, &h, &d1, &d2);
    coord.register_graph_cache(&h, Arc::new(ConstantGraphCache { score: 0.8 }));

    let excluded = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("graph", 0.0)]))), NOW + 10)
        .expect("excluded");
    let suppressed = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("graph", -1.0)]))), NOW + 11)
        .expect("suppressed");

    let excluded_finals = finals(&excluded);
    let mut saw_strictly_lower = false;
    for hit in &suppressed.hits {
        if let Some(zero_final) = excluded_finals.get(&hit.id) {
            assert!(
                hit.score.final_score <= zero_final + 1e-6,
                "suppressed graph final must not exceed the excluded final; {}: w<0={} w0={}",
                hit.id, hit.score.final_score, zero_final
            );
            if hit.score.final_score < zero_final - 1e-6 {
                saw_strictly_lower = true;
            }
        }
    }
    assert!(
        saw_strictly_lower,
        "graph w=-1 must subtract mass — at least one drawer strictly below the w=0 final"
    );
}

// MARK: - (e) nil shape == all-ones shape, byte-identical (back-compat)

/// nil shape and an explicit all-ones shape over EVERY steerable key (retrieval +
/// matrix/graph/preference) must produce BYTE-IDENTICAL unionBest output — ids,
/// order, and fused finals — with the matrix tier registered (the live columns
/// non-zero). The production back-compat contract for 6b-modifiers-matrix-steer.
#[test]
fn nil_shape_equals_all_ones_across_all_columns() {
    let (mut coord, h, d1, d2) = two_drawer_estate();
    seed_matrix_tier(&mut coord, &h, &d1, &d2);
    // Register the graph / preference caches too so EVERY steerable column is live,
    // mirroring Swift RecallShapeMatrixSteerTests.nilShapeEqualsAllOnesAcrossAllColumns.
    coord.register_graph_cache(&h, Arc::new(ConstantGraphCache { score: 0.8 }));
    coord.register_preference_store(&h, Arc::new(ConstantPreferenceStore { score: 0.9 }));

    let ones = shape(&[
        ("locus", 1.0), ("bm25", 1.0), ("hamming", 1.0), ("dense", 1.0),
        ("fieldFit", 1.0), ("coOccurrence", 1.0), ("temporal", 1.0),
        ("graph", 1.0), ("preference", 1.0),
    ]);

    let nil_result = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("nil");
    let ones_result = coord.recall_scored(&h, matrix_req(Some(ones)), NOW + 11).expect("ones");

    assert_eq!(
        nil_result.hits.iter().map(|hit| hit.id.clone()).collect::<Vec<_>>(),
        ones_result.hits.iter().map(|hit| hit.id.clone()).collect::<Vec<_>>(),
        "all-ones shape must produce the same unionBest id order as nil shape"
    );
    for (a, b) in nil_result.hits.iter().zip(ones_result.hits.iter()) {
        assert_eq!(a.id, b.id);
        assert_eq!(
            a.score.final_score, b.score.final_score,
            "fused final must be byte-identical at all-ones; {}: nil={} ones={}",
            a.id, a.score.final_score, b.score.final_score
        );
        assert_eq!(a.score.temporal, b.score.temporal, "temporal byte-identical; {}", a.id);
        assert_eq!(a.score.co_occurrence, b.score.co_occurrence, "coOccurrence byte-identical; {}", a.id);
        assert_eq!(a.score.field_fit, b.score.field_fit, "fieldFit byte-identical; {}", a.id);
        assert_eq!(a.score.graph, b.score.graph, "graph byte-identical; {}", a.id);
        assert_eq!(a.score.preference, b.score.preference, "preference byte-identical; {}", a.id);
        // CROSS-PORT CONFORMANCE (ADR-011 D-4): a constant cache (0.8 graph,
        // 0.9 preference) gives every candidate the same column value, so it is
        // measured-uniform and normalizes to exactly 0.5 — the SAME value Swift's
        // RecallShapeMatrixSteerTests produces over the same fixture. Pinning the
        // value here proves the columns are LIVE and agree cross-port, not merely
        // self-consistent within Rust.
        assert_eq!(a.score.graph, 0.5, "graph column must normalize to 0.5 (constant-uniform); {}", a.id);
        assert_eq!(a.score.preference, 0.5, "preference column must normalize to 0.5 (constant-uniform); {}", a.id);
    }
}
