//! VectorKit telemetry integration tests — VECTORKIT_REPORT_001.
//!
//! Mirrors the Swift suite in
//! Tests/VectorKitTests/VectorKitTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate: no metric emitted when monitoring is OFF.
//!   §2 Enabled gate: metrics emitted when monitoring is ON.
//!   §3 Metric shapes: names, tags, and values match the vectorkit.* spec.
//!   §4 Conformance: results are byte-identical with monitoring on and off.
//!
//! Notes on global state isolation:
//!   VectorStore operations call Intellectus via the report! macro, which
//!   uses the process-wide Intellectus singleton (enabled flag + installed
//!   sink). Rust integration tests run in parallel by default.
//!
//!   All tests that touch the singleton (toggle enabled flag, install a
//!   capturing sink, or call VectorStore methods that emit) MUST acquire
//!   GLOBAL_LOCK for their entire duration. This prevents interleaving
//!   between concurrent tests that would corrupt exact-count assertions.
//!
//!   Pattern mirrors packages/libs/SubstrateKernel/rust/tests/kernel_telemetry_tests.rs.
//!
//!   Lock poisoning: if a prior test panicked while holding the lock,
//!   `lock()` returns a PoisonError. We recover with `into_inner()` so
//!   subsequent tests can still run. Each test restores the global state
//!   to disabled + NoOpSink before releasing, limiting cross-test
//!   contamination to the single panicking test.

use std::sync::{Arc, Mutex, OnceLock};

use engram_lib::Engram;
use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use uuid::Uuid;
use vectorkit::VectorStore;

// Process-wide serialisation lock for tests that manipulate the
// Intellectus global singleton (enabled flag + installed sink).
// All such tests hold this lock for their entire duration, ensuring
// that concurrent enabled/install races cannot cause spurious
// mismatches in the captured sample count.
static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// ---- Helper: capturing sink ----

/// Records every received StatSample. Thread-safe via Mutex.
struct CapturingSink {
    samples: Mutex<Vec<StatSample>>,
}

impl CapturingSink {
    fn new() -> Self {
        CapturingSink { samples: Mutex::new(Vec::new()) }
    }

    fn count(&self) -> usize {
        self.samples.lock().unwrap().len()
    }

    fn all_samples(&self) -> Vec<StatSample> {
        self.samples.lock().unwrap().clone()
    }
}

impl StatsSink for CapturingSink {
    fn receive(&self, sample: StatSample) {
        self.samples.lock().unwrap().push(sample);
    }
}

// ---- Helper: fresh store ----

/// Opens a fresh InMemory VectorStore for each test.
fn make_fresh_store() -> VectorStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("open must succeed on InMemory backend")
}

/// A fixed deterministic engram for tests.
fn test_engram() -> Engram {
    Engram::new(
        0xCAFE_BABE_DEAD_BEEFu64,
        0x0123_4567_89AB_CDEFu64,
        0xFFFF_0000_FFFF_0000u64,
        0x0000_FFFF_0000_FFFFu64,
    )
}

// ---- §1 Disabled gate ----

/// add_vector must not emit when monitoring is disabled.
#[test]
fn add_vector_no_metric_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let store = make_fresh_store();
    store.add_vector("d1", &test_engram(), "minilm", "1.0", 1_700_000_000)
        .expect("add_vector must succeed");

    assert_eq!(sink.count(), 0,
        "add_vector must not emit when monitoring is disabled");

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

/// find_nearest must not emit when monitoring is disabled.
#[test]
fn find_nearest_no_metric_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let store = make_fresh_store();
    store.add_vector("d1", &test_engram(), "minilm", "1.0", 1_700_000_000)
        .expect("add_vector must succeed");
    let _ = store.find_nearest(&test_engram(), "minilm", 5)
        .expect("find_nearest must succeed");

    assert_eq!(sink.count(), 0,
        "find_nearest must not emit when monitoring is disabled");

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

/// find_by_keyword must not emit when monitoring is disabled.
#[test]
fn find_by_keyword_no_metric_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let store = make_fresh_store();
    let _ = store.find_by_keyword("drawer", 10)
        .expect("find_by_keyword must succeed");

    assert_eq!(sink.count(), 0,
        "find_by_keyword must not emit when monitoring is disabled");

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

// ---- §2 Enabled gate ----

/// add_vector must emit exactly one metric when monitoring is enabled.
#[test]
fn add_vector_emits_one_metric_when_enabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    store.add_vector("d1", &test_engram(), "minilm", "1.0", 1_700_000_000)
        .expect("add_vector must succeed");

    assert_eq!(sink.count(), 1,
        "add_vector must emit exactly one metric; got {}", sink.count());

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// find_nearest must emit exactly two metrics (latency + result count)
/// when monitoring is enabled.
#[test]
fn find_nearest_emits_two_metrics_when_enabled() {
    let _guard = global_lock();

    // Insert the vector with monitoring off so the add_vector emit
    // does not contaminate the find_nearest metric count.
    Intellectus::set_enabled(false);
    let store = make_fresh_store();
    store.add_vector("d1", &test_engram(), "minilm", "1.0", 1_700_000_000)
        .expect("add_vector must succeed");

    // Now enable monitoring and run the search.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = store.find_nearest(&test_engram(), "minilm", 5)
        .expect("find_nearest must succeed");

    // Count only vectorkit.* metrics. Other kits lower in the dependency
    // chain (e.g. SubstrateKernel via EngramLib) may emit their own
    // metrics into this sink when monitoring is enabled; we assert only
    // on the VectorKit emissions.
    let vk_count = sink.all_samples().into_iter().filter(|s| {
        if let StatSample::Metric { name, .. } = s { name.starts_with("vectorkit.") } else { false }
    }).count();
    assert_eq!(vk_count, 2,
        "find_nearest must emit 2 vectorkit.* metrics (latency + result_count); got {}", vk_count);

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// find_by_keyword must emit exactly one metric when monitoring is enabled.
#[test]
fn find_by_keyword_emits_one_metric_when_enabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    let _ = store.find_by_keyword("drawer", 10)
        .expect("find_by_keyword must succeed");

    assert_eq!(sink.count(), 1,
        "find_by_keyword must emit exactly one metric; got {}", sink.count());

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ---- §3 Metric shapes ----

/// add_vector emits vectorkit.index.insert_latency_ms with correct shape.
#[test]
fn add_vector_insert_latency_metric_shape() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_store();
    store.add_vector("d1", &test_engram(), "minilm", "1.0", 1_700_000_000)
        .expect("add_vector must succeed");

    let samples = sink.all_samples();
    assert_eq!(samples.len(), 1, "expected 1 sample from add_vector");

    if let Some(StatSample::Metric { name, value, tags, .. }) = samples.first() {
        assert_eq!(name, "vectorkit.index.insert_latency_ms",
            "insert latency must be named vectorkit.index.insert_latency_ms");
        assert!(*value >= 0.0, "latency_ms must be non-negative; got {}", value);
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("VectorKit"),
            "insert latency must carry kit=VectorKit tag");
        assert_eq!(tags.get("model_id").map(|s| s.as_str()), Some("minilm"),
            "insert latency must carry model_id=minilm tag");
    } else {
        panic!("expected a Metric sample; got {:?}", samples.first());
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// find_nearest emits vectorkit.search.latency_ms and
/// vectorkit.search.result_count with correct shapes.
#[test]
fn find_nearest_metric_shapes() {
    let _guard = global_lock();

    // Insert with monitoring off to isolate the find_nearest metrics.
    Intellectus::set_enabled(false);
    let store = make_fresh_store();
    store.add_vector("d1", &test_engram(), "minilm", "1.0", 1_700_000_000)
        .expect("add_vector must succeed");

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = store.find_nearest(&test_engram(), "minilm", 5)
        .expect("find_nearest must succeed");

    // Filter to vectorkit.* metrics only. Lower-layer kits (e.g.
    // SubstrateKernel via EngramLib) may emit their own metrics into
    // this sink; we assert only on the VectorKit namespace.
    let vk_samples: Vec<StatSample> = sink.all_samples().into_iter().filter(|s| {
        if let StatSample::Metric { name, .. } = s { name.starts_with("vectorkit.") } else { false }
    }).collect();
    assert_eq!(vk_samples.len(), 2,
        "find_nearest must emit 2 vectorkit.* metrics; got {}", vk_samples.len());

    // First VectorKit metric: latency.
    if let Some(StatSample::Metric { name, value, tags, .. }) = vk_samples.get(0) {
        assert_eq!(name, "vectorkit.search.latency_ms");
        assert!(*value >= 0.0, "latency must be non-negative");
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("VectorKit"));
        assert_eq!(tags.get("model_id").map(|s| s.as_str()), Some("minilm"));
    } else {
        panic!("expected Metric at index 0; got {:?}", vk_samples.get(0));
    }

    // Second VectorKit metric: result count.
    if let Some(StatSample::Metric { name, value, tags, .. }) = vk_samples.get(1) {
        assert_eq!(name, "vectorkit.search.result_count");
        // One vector was inserted for "minilm", find_nearest returns 1.
        assert_eq!(*value, 1.0,
            "result_count must equal number of matches returned; got {}", value);
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("VectorKit"));
        assert_eq!(tags.get("model_id").map(|s| s.as_str()), Some("minilm"));
    } else {
        panic!("expected Metric at index 1; got {:?}", vk_samples.get(1));
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// find_by_keyword emits vectorkit.search.keyword_result_count with correct shape.
#[test]
fn find_by_keyword_metric_shape() {
    let _guard = global_lock();

    // Insert 3 drawers with monitoring off.
    Intellectus::set_enabled(false);
    let store = make_fresh_store();
    for i in 1u64..=3 {
        let engram = Engram::new(i, i * 2, i * 3, i * 4);
        store.add_vector(
            &format!("drawer-{}", i),
            &engram,
            "minilm",
            "1.0",
            1_700_000_000 + i as i64,
        ).expect("add_vector must succeed");
    }

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = store.find_by_keyword("drawer", 10)
        .expect("find_by_keyword must succeed");

    let samples = sink.all_samples();
    assert_eq!(samples.len(), 1, "find_by_keyword must emit 1 metric; got {}", samples.len());

    if let Some(StatSample::Metric { name, value, tags, .. }) = samples.first() {
        assert_eq!(name, "vectorkit.search.keyword_result_count");
        assert_eq!(*value, 3.0,
            "keyword_result_count must equal 3 (one per distinct drawer); got {}", value);
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("VectorKit"));
    } else {
        panic!("expected Metric; got {:?}", samples.first());
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ---- §4 Conformance gate ----

/// find_nearest results are byte-identical with monitoring disabled and enabled.
#[test]
fn find_nearest_results_unchanged_by_telemetry() {
    let _guard = global_lock();

    let probe = Engram::new(
        0xAAAA_AAAA_AAAA_AAAAu64,
        0xBBBB_BBBB_BBBB_BBBBu64,
        0xCCCC_CCCC_CCCC_CCCCu64,
        0xDDDD_DDDD_DDDD_DDDDu64,
    );
    let engrams: Vec<(&str, Engram)> = vec![
        ("d1", Engram::new(
            0xAAAA_AAAA_AAAA_AAAAu64,
            0xBBBB_BBBB_BBBB_BBBBu64,
            0xCCCC_CCCC_CCCC_CCCCu64,
            0xDDDD_DDDD_DDDD_DDDDu64,
        )),
        ("d2", Engram::new(
            0xFFFF_FFFF_FFFF_FFFFu64,
            0x0000_0000_0000_0000u64,
            0xFFFF_FFFF_FFFF_FFFFu64,
            0x0000_0000_0000_0000u64,
        )),
        ("d3", Engram::new(
            0x1234_5678_9ABC_DEF0u64,
            0xFEDC_BA98_7654_3210u64,
            0x0F0F_0F0F_0F0F_0F0Fu64,
            0xF0F0_F0F0_F0F0_F0F0u64,
        )),
    ];

    // Run with monitoring OFF.
    Intellectus::set_enabled(false);
    let store_off = make_fresh_store();
    for (id, eng) in &engrams {
        store_off.add_vector(id, eng, "m", "1", 1_700_000_000)
            .expect("add_vector must succeed");
    }
    let results_off = store_off.find_nearest(&probe, "m", 3)
        .expect("find_nearest must succeed");

    // Run with monitoring ON.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let store_on = make_fresh_store();
    for (id, eng) in &engrams {
        store_on.add_vector(id, eng, "m", "1", 1_700_000_000)
            .expect("add_vector must succeed");
    }
    let results_on = store_on.find_nearest(&probe, "m", 3)
        .expect("find_nearest must succeed");

    // Results must be identical.
    assert_eq!(results_off.len(), results_on.len(),
        "find_nearest must return same count with monitoring off and on");
    for i in 0..results_off.len() {
        assert_eq!(results_off[i].item_id, results_on[i].item_id,
            "result[{}].item_id must match", i);
        assert_eq!(results_off[i].distance, results_on[i].distance,
            "result[{}].distance must match", i);
    }

    // At least some metrics were emitted (monitoring was on).
    assert!(sink.count() > 0,
        "at least one metric must be emitted when monitoring is enabled");

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// add_vector + get_vector round-trip is byte-identical regardless of
/// monitoring state.
#[test]
fn add_vector_get_vector_round_trip_unchanged_by_telemetry() {
    let _guard = global_lock();
    let expected = test_engram();

    // With monitoring OFF.
    Intellectus::set_enabled(false);
    let store_off = make_fresh_store();
    store_off.add_vector("d1", &expected, "m", "1", 1_700_000_000)
        .expect("add_vector must succeed");
    let fetched_off = store_off.get_vector("d1", "m")
        .expect("get_vector must succeed")
        .expect("get_vector must return Some");

    // With monitoring ON.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let store_on = make_fresh_store();
    store_on.add_vector("d1", &expected, "m", "1", 1_700_000_000)
        .expect("add_vector must succeed");
    let fetched_on = store_on.get_vector("d1", "m")
        .expect("get_vector must succeed")
        .expect("get_vector must return Some");

    assert_eq!(fetched_off, expected, "get_vector must return exact engram with monitoring off");
    assert_eq!(fetched_on, expected, "get_vector must return exact engram with monitoring on");

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}
