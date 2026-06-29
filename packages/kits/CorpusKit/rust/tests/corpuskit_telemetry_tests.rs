//! CorpusKit telemetry integration tests — CORPUSKIT_REPORT_001.
//!
//! Mirrors the Swift suite in
//! Tests/CorpusKitTests/CorpusKitTelemetryTests.swift.
//! Section numbers correspond to the Swift suites:
//!
//!   §1 Disabled gate: no metric emitted when monitoring is OFF.
//!   §2 Enabled gate: metrics emitted when monitoring is ON.
//!   §3 Metric shapes: names, tags, and values match the corpuskit.* spec.
//!   §4 Conformance: result count, chunk ids, chunk text, and fused score match with monitoring on and off.
//!
//! Notes on global state isolation:
//!   BundleStore::insert and recall() call Intellectus via the report! macro,
//!   which uses the process-wide Intellectus singleton (enabled flag + installed
//!   sink). Rust integration tests run in parallel by default.
//!
//!   All tests that touch the singleton (toggle enabled flag, install a
//!   capturing sink, or call functions that emit) MUST acquire GLOBAL_LOCK
//!   for their entire duration. This prevents interleaving between concurrent
//!   tests that would corrupt exact-count assertions.
//!
//!   Pattern mirrors packages/kits/VectorKit/rust/tests/vectorkit_telemetry_tests.rs.
//!
//!   Lock poisoning: if a prior test panicked while holding the lock,
//!   `lock()` returns a PoisonError. We recover with `into_inner()` so
//!   subsequent tests can still run. Each test restores the global state
//!   to disabled + NoOpSink before releasing, limiting cross-test
//!   contamination to the single panicking test.

use std::sync::{Arc, Mutex, OnceLock};

use corpus_kit::{
    recall, default_keyword_tokens, BundleStore, Chunk, HybridRecallConfiguration, InvertedIndexStore,
};
use engram_lib::Engram;
use intellectus_lib::{Intellectus, NoOpSink, StatSample, StatsSink};
use persistence_kit::{inmemory::InMemoryStorage, Storage};
use rusqlite::Connection;
use std::collections::BTreeMap;
use substrate_types::hlc::HLC;
use uuid::Uuid;
use vectorkit::VectorStore;

// Process-wide serialisation lock for tests in this file. All tests in
// this file acquire this lock for their entire duration. This static is
// local to this test binary; the other files named above (bundle_store_tests.rs,
// hybrid_recall_tests.rs, corpus_tests.rs) each define their own GLOBAL_LOCK
// static per Rust per-file test binary linking.
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
        CapturingSink {
            samples: Mutex::new(Vec::new()),
        }
    }

    /// Count samples whose name starts with `prefix`.
    fn count_prefix(&self, prefix: &str) -> usize {
        self.samples
            .lock()
            .unwrap()
            .iter()
            .filter(|s| {
                if let StatSample::Metric { name, .. } = s {
                    name.starts_with(prefix)
                } else {
                    false
                }
            })
            .count()
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

// ---- Helpers: fresh stores ----

fn make_fresh_bundle_store() -> BundleStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    BundleStore::open(storage).expect("open bundle store")
}

fn make_fresh_vector_store() -> VectorStore {
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
    VectorStore::open(storage).expect("open vector store")
}

/// Build three deterministic chunks and return them along with the ids.
/// Uses Chunk::derive_id for content-addressed, deterministic UUIDs so
/// the same chunk_id is produced across calls with the same arguments.
fn make_three_chunks() -> Vec<Chunk> {
    let texts = ["alpha document", "beta document", "gamma document"];
    texts
        .iter()
        .enumerate()
        .map(|(i, text)| {
            let id = Chunk::derive_id("src-tel", i * 10, text);
            let hlc = HLC {
                physical_time: i as i64,
                logical_count: 0,
                node_id: 1,
            };
            Chunk::new(id, "src-tel", i * 10, text.len(), *text, hlc, BTreeMap::new())
        })
        .collect()
}

/// A fixed deterministic probe engram.
fn test_probe() -> Engram {
    Engram::new(0, 0, 0, 0)
}

// ---- §1 Disabled gate ----

/// BundleStore::insert must not emit any corpuskit.* metrics when monitoring
/// is disabled.
#[test]
fn insert_no_metric_when_disabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let store = make_fresh_bundle_store();
    let chunks = make_three_chunks();
    store.insert(&chunks).expect("insert must succeed");

    assert_eq!(
        sink.count_prefix("corpuskit."),
        0,
        "insert must not emit corpuskit.* when monitoring is disabled"
    );

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

/// recall must not emit any corpuskit.* metrics when monitoring is disabled.
#[test]
fn recall_no_metric_when_disabled() {
    let _guard = global_lock();

    // Build the stores and populate them with monitoring OFF.
    Intellectus::set_enabled(false);
    let bundle_store = make_fresh_bundle_store();
    let vector_store = make_fresh_vector_store();
    let chunks = make_three_chunks();
    bundle_store.insert(&chunks).expect("insert");
    let engrams = [
        Engram::new(0x1, 0, 0, 0),
        Engram::new(0x3, 0, 0, 0),
        Engram::new(0x7, 0, 0, 0),
    ];
    for (chunk, eng) in chunks.iter().zip(engrams.iter()) {
        vector_store
            .add_vector(&chunk.id.to_string(), eng, "test-model", "1.0", 0)
            .expect("add_vector");
    }
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    for chunk in &chunks {
        let tokens = default_keyword_tokens(chunk.text.as_str());
        inverted_index.index(&chunk.id.to_string(), &tokens, "").expect("index chunk");
    }

    // Now install the sink and keep monitoring disabled.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(false);

    let _ = recall(
        &test_probe(),
        "alpha",
        "test-model",
        3,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall must succeed");

    assert_eq!(
        sink.count_prefix("corpuskit."),
        0,
        "recall must not emit corpuskit.* when monitoring is disabled"
    );

    // Restore defaults.
    Intellectus::install(Arc::new(NoOpSink));
}

// ---- §2 Enabled gate ----

/// BundleStore::insert must emit exactly two corpuskit.* metrics when
/// monitoring is enabled: corpuskit.ingest.latency_ms and
/// corpuskit.ingest.chunk_count.
#[test]
fn insert_emits_two_metrics_when_enabled() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_bundle_store();
    let chunks = make_three_chunks();
    store.insert(&chunks).expect("insert must succeed");

    let ck_count = sink.count_prefix("corpuskit.");
    assert_eq!(
        ck_count,
        2,
        "insert must emit exactly 2 corpuskit.* metrics (latency_ms + chunk_count); got {}",
        ck_count
    );

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// recall must emit exactly four corpuskit.* metrics when monitoring is
/// enabled: latency_ms, vector_result_count, keyword_result_count, result_count.
#[test]
fn recall_emits_four_metrics_when_enabled() {
    let _guard = global_lock();

    // Build stores with monitoring OFF so the insert emissions don't
    // contaminate the recall count.
    Intellectus::set_enabled(false);
    let bundle_store = make_fresh_bundle_store();
    let vector_store = make_fresh_vector_store();
    let chunks = make_three_chunks();
    bundle_store.insert(&chunks).expect("insert");
    let engrams = [
        Engram::new(0x1, 0, 0, 0),
        Engram::new(0x3, 0, 0, 0),
        Engram::new(0x7, 0, 0, 0),
    ];
    for (chunk, eng) in chunks.iter().zip(engrams.iter()) {
        vector_store
            .add_vector(&chunk.id.to_string(), eng, "test-model", "1.0", 0)
            .expect("add_vector");
    }
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    for chunk in &chunks {
        let tokens = default_keyword_tokens(chunk.text.as_str());
        inverted_index.index(&chunk.id.to_string(), &tokens, "").expect("index chunk");
    }

    // Enable monitoring + capturing sink for the recall call.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let _ = recall(
        &test_probe(),
        "alpha",
        "test-model",
        3,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall must succeed");

    let ck_count = sink.count_prefix("corpuskit.");
    assert_eq!(
        ck_count,
        4,
        "recall must emit exactly 4 corpuskit.* metrics; got {}",
        ck_count
    );

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ---- §3 Metric shapes ----

/// BundleStore::insert emits corpuskit.ingest.latency_ms (>= 0) and
/// corpuskit.ingest.chunk_count (== len of batch) with correct tags.
#[test]
fn insert_metric_shapes() {
    let _guard = global_lock();
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let store = make_fresh_bundle_store();
    let chunks = make_three_chunks();
    let expected_count = chunks.len() as f64;
    store.insert(&chunks).expect("insert must succeed");

    let samples = sink.all_samples();
    let ck_samples: Vec<&StatSample> = samples
        .iter()
        .filter(|s| {
            if let StatSample::Metric { name, .. } = s {
                name.starts_with("corpuskit.")
            } else {
                false
            }
        })
        .collect();

    assert_eq!(
        ck_samples.len(),
        2,
        "insert must emit 2 corpuskit.* metrics; got {}",
        ck_samples.len()
    );

    // First metric: latency_ms.
    if let Some(StatSample::Metric { name, value, tags, .. }) = ck_samples.first().copied() {
        assert_eq!(name, "corpuskit.ingest.latency_ms");
        assert!(*value >= 0.0, "latency_ms must be >= 0; got {}", value);
        assert_eq!(
            tags.get("kit").map(|s| s.as_str()),
            Some("CorpusKit"),
            "latency_ms must carry kit=CorpusKit tag"
        );
    } else {
        panic!("expected Metric at index 0; got {:?}", ck_samples.first());
    }

    // Second metric: chunk_count.
    if let Some(StatSample::Metric { name, value, tags, .. }) = ck_samples.get(1).copied() {
        assert_eq!(name, "corpuskit.ingest.chunk_count");
        assert_eq!(
            *value, expected_count,
            "chunk_count must equal batch size ({}); got {}",
            expected_count, value
        );
        assert_eq!(
            tags.get("kit").map(|s| s.as_str()),
            Some("CorpusKit"),
            "chunk_count must carry kit=CorpusKit tag"
        );
    } else {
        panic!("expected Metric at index 1; got {:?}", ck_samples.get(1));
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// recall emits four corpuskit.* metrics in order with correct names,
/// values, and tags.
#[test]
fn recall_metric_shapes() {
    let _guard = global_lock();

    // Build stores with monitoring OFF.
    Intellectus::set_enabled(false);
    let bundle_store = make_fresh_bundle_store();
    let vector_store = make_fresh_vector_store();
    let chunks = make_three_chunks();
    bundle_store.insert(&chunks).expect("insert");
    let engrams = [
        Engram::new(0x1, 0, 0, 0),
        Engram::new(0x3, 0, 0, 0),
        Engram::new(0x7, 0, 0, 0),
    ];
    for (chunk, eng) in chunks.iter().zip(engrams.iter()) {
        vector_store
            .add_vector(&chunk.id.to_string(), eng, "test-model", "1.0", 0)
            .expect("add_vector");
    }
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    for chunk in &chunks {
        let tokens = default_keyword_tokens(chunk.text.as_str());
        inverted_index.index(&chunk.id.to_string(), &tokens, "").expect("index chunk");
    }

    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let results = recall(
        &test_probe(),
        "alpha",
        "test-model",
        3,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall must succeed");

    let expected_result_count = results.len() as f64;

    let ck_samples: Vec<StatSample> = sink
        .all_samples()
        .into_iter()
        .filter(|s| {
            if let StatSample::Metric { name, .. } = s {
                name.starts_with("corpuskit.")
            } else {
                false
            }
        })
        .collect();

    assert_eq!(
        ck_samples.len(),
        4,
        "recall must emit 4 corpuskit.* metrics; got {}",
        ck_samples.len()
    );

    // Metric 0: latency_ms.
    if let Some(StatSample::Metric { name, value, tags, .. }) = ck_samples.get(0) {
        assert_eq!(name, "corpuskit.recall.latency_ms");
        assert!(*value >= 0.0, "latency_ms must be >= 0; got {}", value);
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("CorpusKit"));
        assert_eq!(
            tags.get("model_id").map(|s| s.as_str()),
            Some("test-model")
        );
    } else {
        panic!("expected Metric at index 0");
    }

    // Metric 1: vector_result_count.
    if let Some(StatSample::Metric { name, value, tags, .. }) = ck_samples.get(1) {
        assert_eq!(name, "corpuskit.recall.vector_result_count");
        assert!(
            *value >= 0.0,
            "vector_result_count must be >= 0; got {}",
            value
        );
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("CorpusKit"));
        assert_eq!(
            tags.get("model_id").map(|s| s.as_str()),
            Some("test-model")
        );
    } else {
        panic!("expected Metric at index 1");
    }

    // Metric 2: keyword_result_count.
    if let Some(StatSample::Metric { name, value, tags, .. }) = ck_samples.get(2) {
        assert_eq!(name, "corpuskit.recall.keyword_result_count");
        assert!(
            *value >= 0.0,
            "keyword_result_count must be >= 0; got {}",
            value
        );
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("CorpusKit"));
    } else {
        panic!("expected Metric at index 2");
    }

    // Metric 3: result_count.
    if let Some(StatSample::Metric { name, value, tags, .. }) = ck_samples.get(3) {
        assert_eq!(name, "corpuskit.recall.result_count");
        assert_eq!(
            *value, expected_result_count,
            "result_count must equal results.len(); got {}",
            value
        );
        assert_eq!(tags.get("kit").map(|s| s.as_str()), Some("CorpusKit"));
        assert_eq!(
            tags.get("model_id").map(|s| s.as_str()),
            Some("test-model")
        );
    } else {
        panic!("expected Metric at index 3");
    }

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

// ---- §4 Conformance gate ----

/// recall results are byte-identical with monitoring disabled and enabled.
/// Uses a single shared store populated once so chunk IDs are identical
/// across both recall calls.
#[test]
fn recall_results_unchanged_by_telemetry() {
    let _guard = global_lock();

    // Build a single shared store with monitoring OFF.
    Intellectus::set_enabled(false);
    let bundle_store = make_fresh_bundle_store();
    let vector_store = make_fresh_vector_store();
    let chunks = make_three_chunks();
    bundle_store.insert(&chunks).expect("insert");
    let engrams = [
        Engram::new(0x1, 0, 0, 0),
        Engram::new(0x3, 0, 0, 0),
        Engram::new(0x7, 0, 0, 0),
    ];
    for (chunk, eng) in chunks.iter().zip(engrams.iter()) {
        vector_store
            .add_vector(&chunk.id.to_string(), eng, "test-model", "1.0", 0)
            .expect("add_vector");
    }
    // Build keyword index once; used for both recall calls (off + on).
    let inverted_index = InvertedIndexStore::open(Connection::open_in_memory().expect("conn"))
        .expect("open inverted index");
    for chunk in &chunks {
        let tokens = default_keyword_tokens(chunk.text.as_str());
        inverted_index.index(&chunk.id.to_string(), &tokens, "").expect("index chunk");
    }

    // Recall 1: monitoring OFF.
    let results_off = recall(
        &test_probe(),
        "alpha",
        "test-model",
        3,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall off");

    // Recall 2: monitoring ON. Same store, same query.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);

    let results_on = recall(
        &test_probe(),
        "alpha",
        "test-model",
        3,
        &vector_store,
        &inverted_index,
        &bundle_store,
        HybridRecallConfiguration::default(),
    )
    .expect("recall on");

    // Results must be identical.
    assert_eq!(
        results_off.len(),
        results_on.len(),
        "recall must return same count with monitoring off and on"
    );
    for i in 0..results_off.len() {
        assert_eq!(
            results_off[i].chunk.id, results_on[i].chunk.id,
            "result[{}].chunk.id must match",
            i
        );
        assert_eq!(
            results_off[i].chunk.text, results_on[i].chunk.text,
            "result[{}].chunk.text must match",
            i
        );
        assert_eq!(
            results_off[i].score, results_on[i].score,
            "result[{}].score must match",
            i
        );
    }

    // Monitoring was on: at least four corpuskit.* metrics must have been emitted.
    assert!(
        sink.count_prefix("corpuskit.") >= 4,
        "at least 4 corpuskit.* metrics must be emitted when monitoring is enabled"
    );

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}

/// insert + get round-trip returns the same chunk count and content regardless of monitoring state.
#[test]
fn insert_get_round_trip_unchanged_by_telemetry() {
    let _guard = global_lock();

    let chunks = make_three_chunks();
    let target_id = chunks[0].id;

    // With monitoring OFF.
    Intellectus::set_enabled(false);
    let store_off = make_fresh_bundle_store();
    store_off.insert(&chunks).expect("insert off");
    let fetched_off = store_off
        .get(target_id, None)
        .expect("get off")
        .expect("must exist");

    // With monitoring ON.
    let sink = Arc::new(CapturingSink::new());
    Intellectus::install(sink.clone());
    Intellectus::set_enabled(true);
    let store_on = make_fresh_bundle_store();
    store_on.insert(&chunks).expect("insert on");
    let fetched_on = store_on
        .get(target_id, None)
        .expect("get on")
        .expect("must exist");

    // Chunk content must match.
    assert_eq!(fetched_off.id, fetched_on.id);
    assert_eq!(fetched_off.text, fetched_on.text);
    assert_eq!(fetched_off.source_id, fetched_on.source_id);
    assert_eq!(fetched_off.start_offset, fetched_on.start_offset);

    // Some corpuskit.* metrics must have been emitted (monitoring was on).
    assert!(
        sink.count_prefix("corpuskit.") > 0,
        "at least one corpuskit.* metric must be emitted when monitoring is enabled"
    );

    // Restore defaults.
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(NoOpSink));
}
