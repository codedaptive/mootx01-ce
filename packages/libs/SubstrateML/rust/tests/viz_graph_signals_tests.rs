// viz_graph_signals_tests.rs
//
// Integration tests for the VizGraph telemetry emit wired into
// substrate-ml's five graph-analytic algorithms.
//
// Mirrors Swift VizGraphSignalsTests.swift exactly:
//   §1 CommunityDetection
//   §2 EigenvalueCentrality
//   §3 NMF
//   §4 AnomalyDetection (rolling_z_score + rolling_modified_z_score)
//   §5 MatrixDecay
//
// All tests that touch Intellectus hold a process-wide mutex
// (GLOBAL_LOCK) to prevent cross-test singleton pollution.
// Rust integration tests run in multiple threads by default;
// the mutex serialises access to the shared Intellectus state.

use std::sync::{Arc, Mutex, OnceLock};
use std::collections::HashMap;

use intellectus_lib::{Intellectus, StatSample, StatsSink};
use substrate_ml::community_detection::CommunityDetection;
use substrate_ml::eigenvalue_centrality::EigenvalueCentrality;
use substrate_ml::nmf::NMFAlternatingLeastSquares;
use substrate_ml::anomaly::AnomalyDetection;
use substrate_ml::decay::{DecayingMatrix, apply as decay_apply};
use substrate_ml::viz_graph_signals::VizGraphSignals;

// MARK: - Process-wide mutex (mirrors Swift GlobalTestLock)

/// Process-wide Mutex for Intellectus singleton isolation.
/// All tests that toggle Intellectus state must hold this guard.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> &'static Mutex<()> {
    GLOBAL_LOCK.get_or_init(|| Mutex::new(()))
}

// MARK: - Capturing sink

/// Records every received StatSample. Thread-safe via Mutex.
struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        Self { samples: Mutex::new(Vec::new()) }
    }

    fn count(&self) -> usize {
        self.samples.lock().unwrap().len()
    }

    fn first(&self) -> Option<StatSample> {
        self.samples.lock().unwrap().first().cloned()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

unsafe impl Send for CapturingSink {}
unsafe impl Sync for CapturingSink {}

// MARK: - §1 CommunityDetection

fn triangle_adj() -> Vec<Vec<(usize, f64)>> {
    vec![
        vec![(1, 1.0), (2, 1.0)],
        vec![(0, 1.0), (2, 1.0)],
        vec![(0, 1.0), (1, 1.0)],
    ]
}

#[test]
fn community_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let _ = CommunityDetection::detect(&triangle_adj(), 10, "test-estate", 1.0);

    assert_eq!(sink.count(), 0,
        "CommunityDetection::detect must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn community_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let _ = CommunityDetection::detect(&triangle_adj(), 10, "my-estate", 1.0);

    assert_eq!(sink.count(), 1,
        "CommunityDetection::detect must emit exactly one sample when enabled");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::COMMUNITY_ASSIGNMENT);
        assert!(value >= 1.0, "community count must be >= 1");
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some("my-estate"));
        assert_eq!(tags.get("node_count").map(|s| s.as_str()), Some("3"));
        assert!(tags.contains_key("community_count"));
        assert_eq!(ts, 1.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn community_conformance_result_identical() {
    let _guard = global_lock().lock().unwrap();
    Intellectus::set_enabled(false);
    let result_off = CommunityDetection::detect(&triangle_adj(), 10, "", 0.0);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);
    let result_on = CommunityDetection::detect(&triangle_adj(), 10, "", 0.0);

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));

    assert_eq!(result_off, result_on,
        "CommunityDetection result must be bit-identical regardless of monitoring state");
}

// MARK: - §1b CommunityDetection::detect_full
//
// Mirrors the Swift detectFull telemetry boundary tests in
// CommunityDetectionTests.swift: detect_full emits exactly ONE
// community.assignment signal at the outer boundary regardless of how
// many aggregation levels run internally (the per-level cores are
// non-emitting).

/// V1 star-of-pairs fixture: 4 tunnel-bonded pairs (w = 1.0), node 0
/// lattice-star-bonded to one member of each other pair (w = 0.2). At
/// resolution 0.05 detect_full runs level 0 plus at least one
/// aggregation level and collapses to a single community.
fn star_of_pairs_adj() -> Vec<Vec<(usize, f64)>> {
    let edges: [(usize, usize, f64); 7] = [
        (0, 1, 1.0), (2, 3, 1.0), (4, 5, 1.0), (6, 7, 1.0),
        (0, 2, 0.2), (0, 4, 0.2), (0, 6, 0.2),
    ];
    let mut adj = vec![Vec::new(); 8];
    for &(a, b, w) in &edges {
        adj[a].push((b, w));
        adj[b].push((a, w));
    }
    adj
}

#[test]
fn detect_full_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let _ = CommunityDetection::detect_full(&star_of_pairs_adj(), 10, 20, 0.05, "e", 1.0);

    assert_eq!(sink.count(), 0,
        "CommunityDetection::detect_full must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn detect_full_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let result = CommunityDetection::detect_full(
        &star_of_pairs_adj(), 10, 20, 0.05, "full-estate", 9.0);

    assert_eq!(sink.count(), 1,
        "detect_full must emit exactly one sample at the outer boundary, \
         even when multiple aggregation levels run internally");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::COMMUNITY_ASSIGNMENT);
        let community_count = {
            let mut seen = std::collections::HashSet::new();
            for &label in &result { seen.insert(label); }
            seen.len()
        };
        assert_eq!(value, community_count as f64);
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some("full-estate"));
        assert_eq!(tags.get("node_count").map(|s| s.as_str()), Some("8"));
        assert_eq!(tags.get("community_count").map(|s| s.as_str()), Some("1"));
        assert_eq!(ts, 9.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn detect_full_conformance_result_identical() {
    let _guard = global_lock().lock().unwrap();
    Intellectus::set_enabled(false);
    let result_off = CommunityDetection::detect_full(&star_of_pairs_adj(), 10, 20, 0.05, "", 0.0);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);
    let result_on = CommunityDetection::detect_full(&star_of_pairs_adj(), 10, 20, 0.05, "", 0.0);

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));

    assert_eq!(result_off, result_on,
        "detect_full result must be bit-identical regardless of monitoring state");
}

// MARK: - §2 EigenvalueCentrality

fn star_adj() -> Vec<Vec<(usize, f64)>> {
    vec![
        vec![(1, 1.0), (2, 1.0), (3, 1.0)],
        vec![(0, 1.0)],
        vec![(0, 1.0)],
        vec![(0, 1.0)],
    ]
}

#[test]
fn centrality_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let _ = EigenvalueCentrality::compute(&star_adj(), 100, 1e-6, "e", 2.0);

    assert_eq!(sink.count(), 0,
        "EigenvalueCentrality::compute must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn centrality_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let _ = EigenvalueCentrality::compute(&star_adj(), 100, 1e-6, "my-estate", 2.0);

    assert_eq!(sink.count(), 1,
        "EigenvalueCentrality::compute must emit exactly one sample when enabled");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::CENTRALITY_SCORE);
        assert_eq!(value, 1.0, "completion indicator must be 1.0");
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some("my-estate"));
        assert_eq!(tags.get("node_count").map(|s| s.as_str()), Some("4"));
        assert!(tags.contains_key("iterations_to_convergence"));
        assert_eq!(ts, 2.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn centrality_conformance_result_identical() {
    let _guard = global_lock().lock().unwrap();
    Intellectus::set_enabled(false);
    let result_off = EigenvalueCentrality::compute(&star_adj(), 100, 1e-6, "", 0.0);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);
    let result_on = EigenvalueCentrality::compute(&star_adj(), 100, 1e-6, "", 0.0);

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));

    assert_eq!(result_off.len(), result_on.len());
    for (a, b) in result_off.iter().zip(result_on.iter()) {
        assert_eq!(a, b, "centrality scores must be bit-identical");
    }
}

// MARK: - §3 NMF

fn small_v() -> Vec<Vec<f32>> {
    vec![
        vec![1.0, 2.0, 3.0, 4.0],
        vec![5.0, 6.0, 7.0, 8.0],
        vec![9.0, 10.0, 11.0, 12.0],
    ]
}

#[test]
fn nmf_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let _ = NMFAlternatingLeastSquares::factorize(
        &small_v(), 2, 100, 1e-4, 0xDEADBEEFCAFEBABE, "e", 3.0);

    assert_eq!(sink.count(), 0,
        "NMFAlternatingLeastSquares::factorize must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn nmf_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let _ = NMFAlternatingLeastSquares::factorize(
        &small_v(), 2, 100, 1e-4, 0xDEADBEEFCAFEBABE, "nmf-estate", 3.0);

    assert_eq!(sink.count(), 1,
        "NMFAlternatingLeastSquares::factorize must emit exactly one sample when enabled");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::NMF_FACTOR);
        assert!(value >= 0.0, "reconstruction error must be non-negative");
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some("nmf-estate"));
        assert_eq!(tags.get("rows").map(|s| s.as_str()), Some("3"));
        assert_eq!(tags.get("cols").map(|s| s.as_str()), Some("4"));
        assert_eq!(tags.get("rank").map(|s| s.as_str()), Some("2"));
        assert_eq!(ts, 3.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn nmf_conformance_result_identical() {
    let _guard = global_lock().lock().unwrap();
    let seed = 0xDEADBEEFCAFEBABE_u64;

    Intellectus::set_enabled(false);
    let result_off = NMFAlternatingLeastSquares::factorize(
        &small_v(), 2, 100, 1e-4, seed, "", 0.0);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);
    let result_on = NMFAlternatingLeastSquares::factorize(
        &small_v(), 2, 100, 1e-4, seed, "", 0.0);

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));

    assert_eq!(result_off.final_error, result_on.final_error,
        "NMF final_error must be bit-identical regardless of monitoring state");
    assert_eq!(result_off.iterations, result_on.iterations,
        "NMF iterations must be identical regardless of monitoring state");
}

// MARK: - §4 AnomalyDetection

fn test_window() -> Vec<f32> {
    vec![1.0, 2.0, 3.0, 4.0, 5.0]
}

const TEST_CURRENT: f32 = 10.0;

#[test]
fn anomaly_z_score_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let _ = AnomalyDetection::rolling_z_score(&test_window(), TEST_CURRENT, "e", 4.0);

    assert_eq!(sink.count(), 0,
        "rolling_z_score must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn anomaly_z_score_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let score = AnomalyDetection::rolling_z_score(
        &test_window(), TEST_CURRENT, "anomaly-estate", 4.0);

    assert_eq!(sink.count(), 1,
        "rolling_z_score must emit exactly one sample when enabled");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::ANOMALY_FLAG);
        assert!((value - (score.abs() as f64)).abs() < 1e-10,
            "emitted value must equal abs(z-score)");
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some("anomaly-estate"));
        assert_eq!(tags.get("method").map(|s| s.as_str()), Some("z_score"));
        assert_eq!(tags.get("window_size").map(|s| s.as_str()), Some("5"));
        assert_eq!(ts, 4.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn anomaly_modified_z_score_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let _ = AnomalyDetection::rolling_modified_z_score(
        &test_window(), TEST_CURRENT, "e", 5.0);

    assert_eq!(sink.count(), 0,
        "rolling_modified_z_score must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn anomaly_modified_z_score_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let score = AnomalyDetection::rolling_modified_z_score(
        &test_window(), TEST_CURRENT, "mod-estate", 5.0);

    assert_eq!(sink.count(), 1,
        "rolling_modified_z_score must emit exactly one sample when enabled");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::ANOMALY_FLAG);
        assert!((value - (score.abs() as f64)).abs() < 1e-10,
            "emitted value must equal abs(modified z-score)");
        assert_eq!(tags.get("method").map(|s| s.as_str()), Some("modified_z_score"));
        assert_eq!(tags.get("window_size").map(|s| s.as_str()), Some("5"));
        assert_eq!(ts, 5.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn anomaly_z_score_conformance() {
    let _guard = global_lock().lock().unwrap();
    Intellectus::set_enabled(false);
    let score_off = AnomalyDetection::rolling_z_score(&test_window(), TEST_CURRENT, "", 0.0);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);
    let score_on = AnomalyDetection::rolling_z_score(&test_window(), TEST_CURRENT, "", 0.0);

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));

    assert_eq!(score_off, score_on,
        "rolling_z_score result must be bit-identical regardless of monitoring state");
}

// MARK: - §5 MatrixDecay

#[test]
fn decay_no_sample_when_disabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(false);

    let mut m = DecayingMatrix::new(3, 3, 86400.0, 0);
    m.set(0, 0, 1.0);
    decay_apply(&mut m, 86400, "e", 6.0);

    assert_eq!(sink.count(), 0,
        "MatrixDecay::apply must not emit when monitoring is disabled");

    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn decay_one_sample_when_enabled() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let mut m = DecayingMatrix::new(3, 4, 86400.0, 0);
    m.set(0, 0, 1.0);
    decay_apply(&mut m, 86400, "decay-estate", 6.0);

    assert_eq!(sink.count(), 1,
        "MatrixDecay::apply must emit exactly one sample when enabled");

    if let Some(StatSample::Metric { name, value, tags, ts }) = sink.first() {
        assert_eq!(name, VizGraphSignals::EDGE_DECAYED_WEIGHT);
        // Exactly one half-life elapsed → factor = 0.5.
        assert!((value - 0.5).abs() < 1e-9, "factor for exactly one half-life must be 0.5");
        assert_eq!(tags.get("estate").map(|s| s.as_str()), Some("decay-estate"));
        assert_eq!(tags.get("matrix_rows").map(|s| s.as_str()), Some("3"));
        assert_eq!(tags.get("matrix_cols").map(|s| s.as_str()), Some("4"));
        assert_eq!(tags.get("elapsed_seconds").map(|s| s.as_str()), Some("86400"));
        assert_eq!(ts, 6.0);
    } else {
        panic!("expected Metric sample");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn decay_noop_emits_factor_one() {
    let _guard = global_lock().lock().unwrap();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let mut m = DecayingMatrix::new(2, 2, 86400.0, 100);
    // nowSeconds == lastDecayTimeSeconds → no-op path.
    decay_apply(&mut m, 100, "no-op-estate", 7.0);

    assert_eq!(sink.count(), 1,
        "no-op decay must still emit one sample so the Topology view knows a check ran");

    if let Some(StatSample::Metric { name, value, tags, .. }) = sink.first() {
        assert_eq!(name, VizGraphSignals::EDGE_DECAYED_WEIGHT);
        assert_eq!(value, 1.0, "no-op decay must emit factor 1.0");
        assert_eq!(tags.get("elapsed_seconds").map(|s| s.as_str()), Some("0"));
    } else {
        panic!("expected Metric sample for no-op decay");
    }

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));
}

#[test]
fn decay_conformance_matrix_values_identical() {
    let _guard = global_lock().lock().unwrap();

    Intellectus::set_enabled(false);
    let mut mat_off = DecayingMatrix::new(3, 3, 86400.0, 0);
    mat_off.set(1, 1, 4.0);
    decay_apply(&mut mat_off, 86400, "", 0.0);

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(Arc::clone(&sink) as Arc<dyn StatsSink>);
    Intellectus::set_enabled(true);
    let mut mat_on = DecayingMatrix::new(3, 3, 86400.0, 0);
    mat_on.set(1, 1, 4.0);
    decay_apply(&mut mat_on, 86400, "", 0.0);

    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink));

    assert_eq!(mat_off.values, mat_on.values,
        "DecayingMatrix values must be bit-identical regardless of monitoring state");
}
