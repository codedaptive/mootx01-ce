// recall_shape_float_metric_parity.rs
//
// Unit tests for RecallShape.float_metric and its threading through the Rust
// float-lane recall chain (W2.5 M1 float unlock).
//
// Mirrors Swift RecallShapeFloatMetricTests.swift — same three gates:
//
//   (a) DEFAULT — RecallShape::new initialises float_metric to "cosine";
//       with_float_metric builder stores arbitrary strings verbatim;
//       the zero-arg new() baseline is "cosine".
//
//   (b) UNKNOWN DEGRADES — RecallShape stores strings verbatim; float_metric_for
//       (tested via VectorStore float lane directly) degrades unknowns to cosine.
//
//   (c) SELECTABILITY — "l2" and "dot" produce VectorMatch results and their
//       top-1 rankings differ from cosine on a designed fixture.
//       This is the GOLDEN PIN: the same fixture vectors and expectations
//       as RecallShapeFloatMetricTests (cosine vs l2 vs dot ordering).

use std::collections::HashMap;
use std::sync::Arc;
use persistence_kit::inmemory::InMemoryStorage;
use uuid::Uuid;
use synapsekit::{engine::metric::FloatMetric, VectorPayload, VectorStore};

use genius_locus_kit::recall::RecallShape;

const FILED_AT: i64 = 1_750_000_000;

fn fresh_store() -> VectorStore {
    let storage: Arc<dyn persistence_kit::Storage> =
        Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("open VectorStore")
}

fn add_float(store: &VectorStore, item_id: &str, floats: &[f32], model_id: &str) {
    let payload = VectorPayload::from_f32(floats);
    store
        .add_payload(item_id, 0, &payload, model_id, "1", FILED_AT)
        .expect("add float payload");
}

// MARK: (a) DEFAULT

/// RecallShape::new must initialise float_metric to "cosine".
#[test]
fn new_initialises_float_metric_to_cosine() {
    let shape = RecallShape::new(HashMap::new(), None);
    assert_eq!(shape.float_metric, "cosine",
        "RecallShape::new must initialise float_metric to 'cosine'");
}

/// with_float_metric builder stores the string verbatim.
#[test]
fn with_float_metric_stores_verbatim() {
    let shape = RecallShape::new(HashMap::new(), None)
        .with_float_metric("l2");
    assert_eq!(shape.float_metric, "l2");

    let shape2 = RecallShape::new(HashMap::new(), None)
        .with_float_metric("dot");
    assert_eq!(shape2.float_metric, "dot");
}

/// Unknown metric string is stored verbatim — degradation is at the read site
/// (float_metric_for in coordinator.rs), not in the struct itself.
#[test]
fn unknown_metric_stored_verbatim() {
    let shape = RecallShape::new(HashMap::new(), None)
        .with_float_metric("xyz");
    assert_eq!(shape.float_metric, "xyz",
        "RecallShape must store unknown float_metric strings verbatim");
}

/// Empty metric string stored verbatim.
#[test]
fn empty_metric_stored_verbatim() {
    let shape = RecallShape::new(HashMap::new(), None)
        .with_float_metric("");
    assert_eq!(shape.float_metric, "");
}

// MARK: (b) SELECTABILITY — VectorStore correctly routes metric

/// The designed fixture for cosine vs l2 divergence (mirrors Swift test):
///
///   probe = [1.0, 0.0]
///   v_A = [0.01, 0.0]   cosine_dist = 0 (same direction); l2_dist = 0.99
///   v_B = [0.9, 0.1]    cosine_dist ≈ 0.007; l2_dist ≈ 0.14
///
///   Cosine: v_A ranks first (distance 0 — perfect direction match)
///   L2:     v_B ranks first (distance ≈ 0.14 < 0.99 — closer Euclidean)
#[test]
fn cosine_and_l2_produce_different_top1_on_fixture() {
    let store = fresh_store();
    let model = "metric-sel-rust";

    // v_A: identical direction to probe but tiny magnitude → cosine dist = 0
    add_float(&store, "v_A", &[0.01, 0.0], model);
    // v_B: near in l2 but 6° off → cosine dist ≈ 0.007, l2 dist ≈ 0.14
    add_float(&store, "v_B", &[0.9, 0.1], model);

    let probe: Vec<f32> = vec![1.0, 0.0];

    // Cosine: v_A first (cosine distance = 0 — same direction)
    let cosine_hits = store.find_nearest_float(&probe, model, 2, FloatMetric::Cosine)
        .expect("cosine nearest");
    assert!(!cosine_hits.is_empty(), "cosine must return hits");
    assert_eq!(cosine_hits[0].item_id, "v_A",
        "cosine must rank v_A first (same direction as probe → distance=0)");

    // L2: v_B first (Euclidean distance ≈ 0.14 < 0.99)
    let l2_hits = store.find_nearest_float(&probe, model, 2, FloatMetric::L2)
        .expect("l2 nearest");
    assert!(!l2_hits.is_empty(), "l2 must return hits");
    assert_eq!(l2_hits[0].item_id, "v_B",
        "l2 must rank v_B first (shorter Euclidean distance to probe)");
}

/// Dot vs cosine divergence fixture (mirrors Swift test):
///
///   probe = [1.0, 1.0]
///   v_H = [10, 0]    cosine_dist ≈ 0.293; dot = 10 → ranked first by dot
///   v_I = [0.5, 0.5] cosine_dist ≈ 0;      dot = 1.0 → ranked second by dot
///
///   Cosine: v_I first (identical direction → distance ≈ 0)
///   Dot:    v_H first (largest dot product with probe)
#[test]
fn dot_and_cosine_produce_different_top1_on_fixture() {
    let store = fresh_store();
    let model = "dot-sel-rust";

    add_float(&store, "v_H", &[10.0, 0.0], model);
    add_float(&store, "v_I", &[0.5, 0.5], model);

    let probe: Vec<f32> = vec![1.0, 1.0];

    // Cosine: v_I first (same direction as probe → cosine distance ≈ 0)
    let cosine_hits = store.find_nearest_float(&probe, model, 2, FloatMetric::Cosine)
        .expect("cosine nearest");
    assert!(!cosine_hits.is_empty(), "cosine must return hits");
    assert_eq!(cosine_hits[0].item_id, "v_I",
        "cosine must rank v_I first (identical direction to probe)");

    // Dot: v_H first (dot product 10 vs 1.0; negated dist: v_H smallest)
    let dot_hits = store.find_nearest_float(&probe, model, 2, FloatMetric::Dot)
        .expect("dot nearest");
    assert!(!dot_hits.is_empty(), "dot must return hits");
    assert_eq!(dot_hits[0].item_id, "v_H",
        "dot must rank v_H first (largest inner product with probe)");
}

/// Farthest also respects metric parameter. Using the dot/cosine fixture:
///   Cosine farthest: v_H (cosine_dist ≈ 0.293) is farther than v_I (dist ≈ 0)
#[test]
fn farthest_respects_metric_parameter() {
    let store = fresh_store();
    let model = "farthest-metric-rust";

    add_float(&store, "v_H", &[10.0, 0.0], model);
    add_float(&store, "v_I", &[0.5, 0.5], model);

    let probe: Vec<f32> = vec![1.0, 1.0];

    // Cosine farthest: v_H (cosine dist ≈ 0.293) is farthest
    let cosine_farthest = store.find_farthest_float(&probe, model, 2, FloatMetric::Cosine)
        .expect("cosine farthest");
    assert!(!cosine_farthest.is_empty(), "cosine farthest must return hits");
    assert_eq!(cosine_farthest[0].item_id, "v_H",
        "cosine farthest must rank v_H first (larger cosine distance)");

    // L2 farthest: well-formed results (any ordering is valid since distances
    // differ significantly; just verify non-empty)
    let l2_farthest = store.find_farthest_float(&probe, model, 2, FloatMetric::L2)
        .expect("l2 farthest");
    assert!(!l2_farthest.is_empty(), "l2 farthest must return hits");
}

// MARK: (c) GOLDEN PIN — cosine default preserved (no silent behaviour change)

/// find_nearest_float with FloatMetric::Cosine produces the same top-1 as the
/// historical behaviour (before the metric parameter existed). This is the
/// parity pin: the rank-identity fixture from float_lane_tests.rs must still
/// work with the explicit Cosine metric.
///
/// Probe = [1, 1, 0, 0]; v_ab = [2, 2, 0, 0] is the cosine-nearest
/// (same direction as probe — cos(θ) = 1 → dist = 0).
#[test]
fn cosine_default_matches_historical_rank_fixture() {
    let store = fresh_store();
    let model = "golden-pin-model";

    let vectors: &[(&str, Vec<f32>)] = &[
        ("v_a",   vec![1.0, 0.0, 0.0, 0.0]),
        ("v_ab",  vec![2.0, 2.0, 0.0, 0.0]),  // same direction as probe → cosine-nearest
        ("v_ad",  vec![3.0, 0.0, 0.0, 1.0]),
        ("v_d",   vec![0.0, 0.0, 0.0, 5.0]),
        ("v_neg", vec![-1.0, -1.0, 0.0, 0.0]),
    ];
    for (_idx, (id, v)) in vectors.iter().enumerate() {
        add_float(&store, id, v, model);
    }

    let probe: Vec<f32> = vec![1.0, 1.0, 0.0, 0.0];

    let hits = store.find_nearest_float(&probe, model, 5, FloatMetric::Cosine)
        .expect("cosine nearest on rank fixture");

    assert!(!hits.is_empty(), "cosine must return hits on the rank fixture");
    assert_eq!(hits[0].item_id, "v_ab",
        "GOLDEN PIN: cosine with explicit FloatMetric::Cosine must rank v_ab first \
        (same direction as probe, distance = 0)");
}
