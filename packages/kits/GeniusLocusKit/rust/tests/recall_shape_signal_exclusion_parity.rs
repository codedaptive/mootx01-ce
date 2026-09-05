// recall_shape_signal_exclusion_parity.rs
//
// Behavioural parity tests for the `signal:*` column-budget keys (COL-1) in
// the UnionBest + MatrixAware weighted score. Mirrors Swift
// RecallShapeSignalExclusionTests.swift:
//
//   (a) `signal:graph` = 0 with a constant GraphCache changes fused finals
//       relative to neutral AND, for every shared drawer, reads at or above the
//       per-lane `graph` = 0 final (exclusion redistributes the graph budget;
//       per-lane zeroing only drops it); strictly above for at least one.
//   (b) `signal:agreement` = 0 reads strictly below neutral for every hit.
//   (c) None shape == a shape with every `signal:*` key at 1.0, byte-identical.
//   (d) the six ablation presets each set exactly one `signal:*` key at 0.

use std::collections::HashMap;
use std::sync::Arc;

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, GraphCache,
    RecallFallbackPolicy, RecallOrigin, RecallShape,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000;

struct ConstantGraphCache {
    score: f32,
}
impl GraphCache for ConstantGraphCache {
    fn graph_score(&self, _drawer_id: &str) -> f32 {
        self.score
    }
}

fn cap_frame(content: &str, channel: CaptureChannel) -> CaptureFrame {
    CaptureFrame::new(
        content,
        channel,
        "signal-exclusion-tests",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

fn two_drawer_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    coord
        .capture(&h, cap_frame("signal exclusion alpha content", CaptureChannel::Typed), NOW)
        .expect("capture d1");
    coord
        .capture(&h, cap_frame("signal exclusion beta content", CaptureChannel::Voiced), NOW + 1)
        .expect("capture d2");
    (coord, h)
}

fn matrix_req(shape: Option<RecallShape>) -> GLKRecallRequest {
    let mut req = GLKRecallRequest::new(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        10,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    );
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

const ALL_SIGNAL_KEYS: [&str; 8] = [
    RecallShape::SIGNAL_LOCUS,
    RecallShape::SIGNAL_BM25,
    RecallShape::SIGNAL_VECTOR,
    RecallShape::SIGNAL_FIELD_FIT,
    RecallShape::SIGNAL_MATRIX,
    RecallShape::SIGNAL_GRAPH,
    RecallShape::SIGNAL_PREFERENCE,
    RecallShape::SIGNAL_AGREEMENT,
];

#[test]
fn signal_graph_exclusion_redistributes_at_or_above_lane_zero() {
    let (mut coord, h) = two_drawer_estate();
    coord.register_graph_cache(&h, Arc::new(ConstantGraphCache { score: 0.8 }));

    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let lane_zero = coord
        .recall_scored(&h, matrix_req(Some(shape(&[("graph", 0.0)]))), NOW + 11)
        .expect("lane zero");
    let excluded = coord
        .recall_scored(&h, matrix_req(Some(shape(&[(RecallShape::SIGNAL_GRAPH, 0.0)]))), NOW + 12)
        .expect("excluded");

    let neutral_finals = finals(&neutral);
    let lane_zero_finals = finals(&lane_zero);
    assert!(!excluded.hits.is_empty());
    let mut changed = false;
    let mut strictly_above = false;
    for hit in &excluded.hits {
        if neutral_finals.get(&hit.id).map_or(false, |b| *b != hit.score.final_score) {
            changed = true;
        }
        if let Some(dropped) = lane_zero_finals.get(&hit.id) {
            assert!(
                hit.score.final_score >= *dropped,
                "redistributed exclusion must not read below per-lane zeroing for {}",
                hit.id
            );
            if hit.score.final_score > *dropped {
                strictly_above = true;
            }
        }
    }
    assert!(changed, "excluding the graph column must change a fused final");
    assert!(strictly_above, "redistribution must lift at least one included-column final");
}

#[test]
fn signal_agreement_exclusion_lowers_every_final() {
    let (coord, h) = two_drawer_estate();
    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let no_bonus = coord
        .recall_scored(&h, matrix_req(Some(shape(&[(RecallShape::SIGNAL_AGREEMENT, 0.0)]))), NOW + 11)
        .expect("no bonus");
    let neutral_finals = finals(&neutral);
    assert!(!no_bonus.hits.is_empty());
    for hit in &no_bonus.hits {
        let before = neutral_finals.get(&hit.id).expect("shared hit");
        assert!(hit.score.final_score < *before, "dropping the agreement bonus must lower {}", hit.id);
    }
}

#[test]
fn none_shape_equals_all_ones_signal_keys() {
    let (mut coord, h) = two_drawer_estate();
    coord.register_graph_cache(&h, Arc::new(ConstantGraphCache { score: 0.8 }));
    let ones: Vec<(&str, f32)> = ALL_SIGNAL_KEYS.iter().map(|k| (*k, 1.0)).collect();
    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let explicit = coord
        .recall_scored(&h, matrix_req(Some(shape(&ones))), NOW + 11)
        .expect("explicit");
    let ids_a: Vec<&str> = neutral.hits.iter().map(|x| x.id.as_str()).collect();
    let ids_b: Vec<&str> = explicit.hits.iter().map(|x| x.id.as_str()).collect();
    assert_eq!(ids_a, ids_b);
    let f_a: Vec<f32> = neutral.hits.iter().map(|x| x.score.final_score).collect();
    let f_b: Vec<f32> = explicit.hits.iter().map(|x| x.score.final_score).collect();
    assert_eq!(f_a, f_b);
}

#[test]
fn ablation_presets_set_one_signal_key_each() {
    let expected = [
        ("no_locus", RecallShape::SIGNAL_LOCUS),
        ("no_field_fit", RecallShape::SIGNAL_FIELD_FIT),
        ("no_matrix", RecallShape::SIGNAL_MATRIX),
        ("no_graph", RecallShape::SIGNAL_GRAPH),
        ("no_preference", RecallShape::SIGNAL_PREFERENCE),
        ("no_agreement", RecallShape::SIGNAL_AGREEMENT),
    ];
    for (name, key) in expected {
        let s = RecallShape::preset(name).unwrap_or_else(|| panic!("preset {name} must resolve"));
        let mut want = HashMap::new();
        want.insert(key.to_string(), 0.0f32);
        assert_eq!(s.lane_weights, want, "preset {name} must exclude exactly {key}");
        assert!(RecallShape::PRESET_NAMES.contains(&name));
        assert!(!RecallShape::preset_description(name).is_empty());
    }
}

// MARK: - (e) COL-1 Part C: empty-store columns are excluded automatically

/// On an estate with no MatrixTier, no GraphCache and no PreferenceStore the
/// five cold-path columns carry no measurement, so the coordinator excludes
/// fieldFit, matrix, graph and preference automatically and redistributes
/// their budget. Two assertions, both mutation controls against the pre-COL-1
/// order (zero columns kept their budget):
///   1. a None shape is BYTE-IDENTICAL to a shape that excludes exactly those
///      four columns explicitly (the automatic rule and the explicit rule are
///      the same arithmetic);
///   2. the top hit's final exceeds any value the pre-COL-1 order could
///      produce. The top hit is a locus-only candidate (no query text: bm25,
///      Hamming and dense lanes are dark; no caches: cold columns zero), so
///      pre-COL-1 its final was `weights.locus × 1.0 + agreement`, and
///      `RecallWeights::adaptive` caps locus at 0.3/1.2 = 0.25 while the
///      agreement bonus caps at 0.05: at most 0.30. With the four empty
///      columns' budget redistributed onto locus the same hit reads 0.42
///      (0.4237931 measured, identical on both ports).
#[test]
fn absent_columns_are_excluded_automatically() {
    let (coord, h) = two_drawer_estate();
    let neutral = coord.recall_scored(&h, matrix_req(None), NOW + 10).expect("neutral");
    let explicit = coord
        .recall_scored(
            &h,
            matrix_req(Some(shape(&[
                (RecallShape::SIGNAL_FIELD_FIT, 0.0),
                (RecallShape::SIGNAL_MATRIX, 0.0),
                (RecallShape::SIGNAL_GRAPH, 0.0),
                (RecallShape::SIGNAL_PREFERENCE, 0.0),
            ]))),
            NOW + 11,
        )
        .expect("explicit");
    let f_a: Vec<f32> = neutral.hits.iter().map(|x| x.score.final_score).collect();
    let f_b: Vec<f32> = explicit.hits.iter().map(|x| x.score.final_score).collect();
    assert!(!f_a.is_empty());
    assert_eq!(f_a, f_b, "automatic exclusion must equal explicit exclusion byte for byte");
    let top = f_a.iter().cloned().fold(f32::MIN, f32::max);
    assert!(
        top > 0.30,
        "top final must exceed the pre-COL-1 ceiling 0.25 + 0.05 (redistribution lifts it to ~0.42); got {top}"
    );
}

// MARK: - (f) COL-1 Part C: the locus column is excluded for text queries

/// The locus column is the candidate's rank in the frame's filedAt DESC slice.
/// With query text it measures recency, not relevance, so the coordinator
/// excludes it automatically: a None shape is byte-identical to an explicit
/// `signal:locus` = 0 shape. Without query text the recency rank is the
/// requested ordering and the column stays: None differs from the explicit
/// exclusion. The second half is the mutation control (pre-COL-1 the first
/// pair also differed).
#[test]
fn locus_column_is_excluded_for_text_queries_only() {
    let (coord, h) = two_drawer_estate();
    let text_req = |shape: Option<RecallShape>| {
        let mut r = GLKRecallRequest::new(
            RecallFrame::new(vec![]),
            GLKRecallMode::UnionBest,
            GLKRecallScoring::MatrixAware,
            10,
            RecallFallbackPolicy::FailClosed,
            RecallOrigin::Internal,
        )
        .with_query_text("alpha content");
        if let Some(s) = shape {
            r = r.with_recall_shape(s);
        }
        r
    };
    let a = coord.recall_scored(&h, text_req(None), NOW + 10).expect("text neutral");
    let b = coord
        .recall_scored(&h, text_req(Some(shape(&[(RecallShape::SIGNAL_LOCUS, 0.0)]))), NOW + 11)
        .expect("text explicit");
    let fa: Vec<f32> = a.hits.iter().map(|x| x.score.final_score).collect();
    let fb: Vec<f32> = b.hits.iter().map(|x| x.score.final_score).collect();
    assert!(!fa.is_empty());
    assert_eq!(fa, fb, "text query: automatic locus exclusion must equal explicit exclusion");

    let c = coord.recall_scored(&h, matrix_req(None), NOW + 12).expect("browse neutral");
    let d = coord
        .recall_scored(&h, matrix_req(Some(shape(&[(RecallShape::SIGNAL_LOCUS, 0.0)]))), NOW + 13)
        .expect("browse explicit");
    let fc: Vec<f32> = c.hits.iter().map(|x| x.score.final_score).collect();
    let fd: Vec<f32> = d.hits.iter().map(|x| x.score.final_score).collect();
    assert_ne!(fc, fd, "structured browse: the locus recency rank must stay in the score");
}
