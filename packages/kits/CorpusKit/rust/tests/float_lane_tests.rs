//! Whole-record dense float lane tests of the legacy `Corpus` surface:
//! `FloatLaneOutcome` variants, the forced store-error seam, telemetry
//! parity with monitoring off and on, and the farthest (anti-similar)
//! per-signal recall.

use corpus_kit::{Corpus, EmbeddingModelConfig, FloatLaneOutcome};
use engram_lib::Engram;
use intellectus_lib::Intellectus;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use synapsekit::{EmbeddingProvider, SynapseKitError};
use uuid::Uuid;

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

fn make_corpus() -> Corpus {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Corpus::open(storage, EmbeddingModelConfig::Deterministic)
        .expect("Corpus::open must succeed with InMemory storage")
}

const NOW_MILLIS: i64 = 1_000_000_000;

/// Fake host provider: a fixed-dimension vector derived from the text
/// length. Stands in for a real model pass — the kit owns the pipeline, the
/// host owns the provider.
struct FakeVectorProvider {
    dim: usize,
}
impl EmbeddingProvider for FakeVectorProvider {
    fn model_id(&self) -> &str { "test-fake-vector-v1" }
    fn model_version(&self) -> &str { "1.0.0" }
    fn embed(&self, _text: &str) -> Result<Engram, SynapseKitError> { Ok(Engram::ZERO) }
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        let base = (text.split_whitespace().count() as f32).max(1.0);
        Ok((0..self.dim).map(|d| ((d as f32 + 1.0) / base).sin()).collect())
    }
}

/// A corpus over one host-supplied float-capable provider. `CandleNL` is the
/// pass-through slot for a non-trainable provider.
fn make_corpus_host_provider() -> Corpus {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Corpus::open(
        storage,
        EmbeddingModelConfig::CandleNL { provider: Box::new(FakeVectorProvider { dim: 384 }) },
    )
    .expect("Corpus::open must succeed with a host provider")
}

/// §1-rust EmptyQuery: empty query string → EmptyQuery outcome, no telemetry.
#[test]
fn float_lane_outcome_empty_query_string() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let outcome = corpus.float_nearest("", 10);
    assert!(
        matches!(outcome, FloatLaneOutcome::EmptyQuery),
        "empty query must produce EmptyQuery outcome; got {:?}", outcome
    );
}

/// §1-rust EmptyQuery: limit 0 → EmptyQuery outcome.
#[test]
fn float_lane_outcome_zero_limit() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let outcome = corpus.float_nearest("something", 0);
    assert!(
        matches!(outcome, corpus_kit::FloatLaneOutcome::EmptyQuery),
        "limit=0 must produce EmptyQuery outcome; got {:?}", outcome
    );
}

/// §2-rust NoFloatRows: deterministic provider on an empty corpus has no float
/// rows stored → UnavailableNoFloatRows (not UnavailableProviderOptOut, because
/// the deterministic FloatSimHashEmbeddingProvider returns a valid probe).
#[test]
fn float_lane_outcome_no_float_rows_empty_corpus() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let outcome = corpus.float_nearest("dense float lane test", 10);
    assert!(
        matches!(outcome, FloatLaneOutcome::UnavailableNoFloatRows),
        "empty corpus must produce UnavailableNoFloatRows; got {:?}", outcome
    );
}

/// §3-rust Hits: after ingest, float_nearest must return Hits with ≥1 result.
/// The deterministic provider returns floats, so float rows ARE stored.
#[test]
fn float_lane_outcome_hits_after_ingest() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus
        .ingest(
            "The dense float lane produces cosine-ranked hits via pooled embeddings.",
            "doc-float-hits",
            NOW_MILLIS,
        )
        .expect("ingest must succeed");
    let outcome = corpus.float_nearest("float embeddings", 5);
    match outcome {
        FloatLaneOutcome::Hits(results) => {
            assert!(!results.is_empty(), ".Hits must contain at least one result");
            // Every similarity must be in the cosine range [-1, 1].
            for (id, sim) in &results {
                assert!(
                    *sim >= -1.0 && *sim <= 1.0,
                    "similarity must be in [-1, 1]; id={} sim={}", id, sim
                );
                assert!(!id.is_empty(), "item_id must be non-empty");
            }
        }
        _ => panic!("expected Hits after ingest"),
    }
}

/// §4-rust Conformance: telemetry must not alter result content or order.
/// Run float_nearest with monitoring off, then on; compares outcome variant,
/// hit count, and item IDs — similarity values are not compared.
#[test]
fn float_lane_outcome_identical_with_monitoring_off_and_on() {
    use intellectus_lib::{StatSample, StatsSink};
    use std::sync::{Arc, Mutex as StdMutex};

    // Shared capturing sink.
    #[derive(Default)]
    struct VecSink(StdMutex<Vec<StatSample>>);
    impl StatsSink for VecSink {
        fn receive(&self, s: StatSample) {
            self.0.lock().unwrap().push(s);
        }
    }

    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus
        .ingest(
            "Conformance: telemetry must not alter floatNearest results.",
            "doc-conformance-rust",
            NOW_MILLIS,
        )
        .expect("ingest must succeed");

    // Run with monitoring OFF.
    let outcome_off = corpus.float_nearest("telemetry results", 5);

    // Run with monitoring ON.
    let sink = Arc::new(VecSink::default());
    Intellectus::install(sink.clone() as Arc<dyn intellectus_lib::StatsSink>);
    Intellectus::set_enabled(true);
    let outcome_on = corpus.float_nearest("telemetry results", 5);
    Intellectus::set_enabled(false);
    Intellectus::install(Arc::new(intellectus_lib::NoOpSink) as Arc<dyn intellectus_lib::StatsSink>);

    // Both outcomes must have the same variant and same hit count.
    match (outcome_off, outcome_on) {
        (FloatLaneOutcome::Hits(off), FloatLaneOutcome::Hits(on)) => {
            assert_eq!(off.len(), on.len(),
                "hit count must be identical on/off; off={} on={}", off.len(), on.len());
            for (i, ((off_id, _), (on_id, _))) in off.iter().zip(on.iter()).enumerate() {
                assert_eq!(off_id, on_id,
                    "hit[{}].item_id must match; off={} on={}", i, off_id, on_id);
            }
        }
        (FloatLaneOutcome::UnavailableNoFloatRows,
         FloatLaneOutcome::UnavailableNoFloatRows) => {}
        (FloatLaneOutcome::UnavailableProviderOptOut,
         FloatLaneOutcome::UnavailableProviderOptOut) => {}
        (FloatLaneOutcome::EmptyQuery,
         FloatLaneOutcome::EmptyQuery) => {}
        (off, on) => panic!("outcome variant mismatch: off={:?} on={:?}", off, on),
    }

    // When monitoring was on, at least one metric must have been emitted.
    let count = sink.0.lock().unwrap().len();
    assert!(count > 0,
        "at least one metric must be emitted when monitoring is enabled; got 0");
}

// MARK: - §1-rust-force-test: provider opt-out forced via open_with_provider seam
//
// A ThrowingFloatProvider whose embed_float always errors is injected via the
// test-only Corpus::open_with_provider constructor. This makes the
// UnavailableProviderOptOut path force-testable without modifying production code.
// Mirrors Swift §1 (ThrowingFloatProvider + init(storage:provider:) seam).

struct ThrowingFloatProvider;

impl synapsekit::EmbeddingProvider for ThrowingFloatProvider {
    fn model_id(&self) -> &str { "test-throwing-float-v1" }
    fn model_version(&self) -> &str { "1.0.0" }

    fn embed(&self, _text: &str) -> Result<engram_lib::Engram, synapsekit::SynapseKitError> {
        // Return the zero engram — satisfies the contract for empty/non-empty inputs.
        Ok(engram_lib::Engram::ZERO)
    }

    fn embed_float(&self, _text: &str) -> Result<Vec<f32>, synapsekit::SynapseKitError> {
        // Always opt out — this provider has no float lane.
        Err(synapsekit::SynapseKitError::EmbeddingFailed(
            "ThrowingFloatProvider: embed_float is disabled (test-only opt-out)".to_string(),
        ))
    }
}

/// §1-rust-force: ThrowingFloatProvider forces UnavailableProviderOptOut + dark_provider counter.
#[test]
fn float_lane_outcome_provider_opt_out_forced() {
    use intellectus_lib::{StatSample, StatsSink};
    use std::sync::Arc as StdArc;

    #[derive(Default)]
    struct VecSink(std::sync::Mutex<Vec<StatSample>>);
    impl StatsSink for VecSink {
        fn receive(&self, s: StatSample) { self.0.lock().unwrap().push(s); }
    }
    fn count_metric(sink: &VecSink, name: &str) -> usize {
        sink.0.lock().unwrap().iter().filter(|s| {
            matches!(s, StatSample::Metric { name: n, .. } if n == name)
        }).count()
    }

    let _guard = global_lock();

    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));

    // Inject the throwing provider via the test seam.
    let corpus = Corpus::open_with_provider(storage, Box::new(ThrowingFloatProvider))
        .expect("open_with_provider must succeed");

    let sink = StdArc::new(VecSink::default());
    Intellectus::install(sink.clone() as StdArc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let outcome = corpus.float_nearest("provider opt-out force test", 5);

    Intellectus::set_enabled(false);
    Intellectus::install(StdArc::new(intellectus_lib::NoOpSink) as StdArc<dyn StatsSink>);

    assert!(
        matches!(outcome, FloatLaneOutcome::UnavailableProviderOptOut),
        "ThrowingFloatProvider must produce UnavailableProviderOptOut; got {:?}", outcome
    );
    // dark_provider counter must have moved exactly once.
    let dp = count_metric(&sink, "corpus.float_lane.dark_provider");
    assert_eq!(dp, 1,
        "corpus.float_lane.dark_provider must be emitted once; got {}", dp);
    // dark_no_rows must NOT move — provider threw before the store was reached.
    assert_eq!(count_metric(&sink, "corpus.float_lane.dark_no_rows"), 0,
        "dark_no_rows must be 0 when provider throws");
    assert_eq!(count_metric(&sink, "corpus.float_lane.store_error"), 0,
        "store_error must be 0 on opt-out path");
    assert_eq!(count_metric(&sink, "corpus.float_lane.hit"), 0,
        "hit counter must be 0 on opt-out path");
}

/// §1-rust-force monitoring off: dark_provider counter not emitted when monitoring disabled.
#[test]
fn float_lane_outcome_provider_opt_out_forced_monitoring_off() {
    use intellectus_lib::{StatSample, StatsSink};
    use std::sync::Arc as StdArc;

    #[derive(Default)]
    struct VecSink(std::sync::Mutex<Vec<StatSample>>);
    impl StatsSink for VecSink {
        fn receive(&self, s: StatSample) { self.0.lock().unwrap().push(s); }
    }

    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Corpus::open_with_provider(storage, Box::new(ThrowingFloatProvider))
        .expect("open_with_provider must succeed");

    let sink = StdArc::new(VecSink::default());
    Intellectus::install(sink.clone() as StdArc<dyn StatsSink>);

    let outcome = corpus.float_nearest("monitoring off test", 5);
    Intellectus::install(StdArc::new(intellectus_lib::NoOpSink) as StdArc<dyn StatsSink>);

    assert!(
        matches!(outcome, FloatLaneOutcome::UnavailableProviderOptOut),
        "outcome must still be UnavailableProviderOptOut with monitoring off"
    );
    let emitted = sink.0.lock().unwrap().len();
    assert_eq!(emitted, 0,
        "no metrics must be emitted when monitoring is disabled; got {}", emitted);
}

// MARK: - §6-rust: storeError force-test via forced_float_error hook
//
// The forced_float_error field (cfg(test) only) simulates a vector store failure
// from float_nearest. Mirrors Swift §6 force-test.

/// §6-rust-force: forced store error produces StoreError outcome + store_error counter.
#[test]
fn float_lane_outcome_store_error_forced() {
    use intellectus_lib::{StatSample, StatsSink};
    use std::sync::Arc as StdArc;

    #[derive(Default)]
    struct VecSink(std::sync::Mutex<Vec<StatSample>>);
    impl StatsSink for VecSink {
        fn receive(&self, s: StatSample) { self.0.lock().unwrap().push(s); }
    }
    fn count_metric(sink: &VecSink, name: &str) -> usize {
        sink.0.lock().unwrap().iter().filter(|s| {
            matches!(s, StatSample::Metric { name: n, .. } if n == name)
        }).count()
    }

    let _guard = global_lock();

    let corpus = make_corpus();
    // Install the forced error before the query.
    *corpus.forced_float_error.lock().unwrap() =
        Some("SyntheticStoreError: test-injected store failure".to_string());

    let sink = StdArc::new(VecSink::default());
    Intellectus::install(sink.clone() as StdArc<dyn StatsSink>);
    Intellectus::set_enabled(true);

    let outcome = corpus.float_nearest("store error force test", 5);

    Intellectus::set_enabled(false);
    Intellectus::install(StdArc::new(intellectus_lib::NoOpSink) as StdArc<dyn StatsSink>);

    // Must degrade to StoreError, not panic.
    assert!(
        matches!(outcome, FloatLaneOutcome::StoreError(_)),
        "forced hook must produce StoreError; got {:?}", outcome
    );
    // store_error counter must have moved exactly once.
    let ec = count_metric(&sink, "corpus.float_lane.store_error");
    assert_eq!(ec, 1,
        "corpus.float_lane.store_error must be emitted once; got {}", ec);
    // Dark and hit counters must NOT move.
    assert_eq!(count_metric(&sink, "corpus.float_lane.dark_provider"), 0);
    assert_eq!(count_metric(&sink, "corpus.float_lane.dark_no_rows"), 0);
    assert_eq!(count_metric(&sink, "corpus.float_lane.hit"), 0);
}

/// §6-rust-force monitoring off: store_error counter not emitted when monitoring disabled.
#[test]
fn float_lane_outcome_store_error_forced_monitoring_off() {
    use intellectus_lib::{StatSample, StatsSink};
    use std::sync::Arc as StdArc;

    #[derive(Default)]
    struct VecSink(std::sync::Mutex<Vec<StatSample>>);
    impl StatsSink for VecSink {
        fn receive(&self, s: StatSample) { self.0.lock().unwrap().push(s); }
    }

    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = make_corpus();
    *corpus.forced_float_error.lock().unwrap() =
        Some("SyntheticStoreError: monitoring off".to_string());

    let sink = StdArc::new(VecSink::default());
    Intellectus::install(sink.clone() as StdArc<dyn StatsSink>);

    let outcome = corpus.float_nearest("store error monitoring off", 5);
    Intellectus::install(StdArc::new(intellectus_lib::NoOpSink) as StdArc<dyn StatsSink>);

    assert!(
        matches!(outcome, FloatLaneOutcome::StoreError(_)),
        "outcome must still be StoreError with monitoring off"
    );
    let emitted = sink.0.lock().unwrap().len();
    assert_eq!(emitted, 0,
        "no metrics must be emitted when monitoring is disabled; got {}", emitted);
}

/// §6-rust-force hook consumed: forced error fires once only, second call is normal.
#[test]
fn float_lane_outcome_store_error_hook_consumed_on_first_call() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = make_corpus();
    corpus
        .ingest(
            "Hook consumed after first call test fixture for Rust",
            "hook-consume-rust",
            NOW_MILLIS,
        )
        .expect("ingest must succeed");

    *corpus.forced_float_error.lock().unwrap() =
        Some("consumed hook".to_string());

    // First call: hook fires → StoreError.
    let first = corpus.float_nearest("hook test", 5);
    assert!(
        matches!(first, FloatLaneOutcome::StoreError(_)),
        "first call must be StoreError; got {:?}", first
    );

    // Second call: hook consumed → normal path (Hits or UnavailableNoFloatRows).
    let second = corpus.float_nearest("hook test", 5);
    assert!(
        !matches!(second, FloatLaneOutcome::StoreError(_)),
        "hook must not fire twice; second call got StoreError again"
    );
}

#[test]
fn named_minilm_float_lane_is_available() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus_host_provider();
    corpus
        .ingest("dense semantic lane content for the float path", "doc-float", NOW_MILLIS)
        .expect("ingest must succeed");
    // Unlike Deterministic (which opts out of the float lane), a named
    // provider supplies embed_float, so the dense lane returns Hits or
    // (if no rows matched) a non-opt-out outcome — never
    // UnavailableProviderOptOut.
    let outcome = corpus.float_nearest("dense semantic lane", 5);
    assert!(
        !matches!(outcome, FloatLaneOutcome::UnavailableProviderOptOut),
        "named provider must expose the float lane; got {:?}",
        outcome
    );
}

/// A direction-discriminating provider: each text gets a ONE-HOT 384-d
/// direction chosen by the FNV-1a hash of its UTF-8 bytes mod 384, so distinct
/// texts get distinct, mostly-orthogonal directions. Mirrors the Swift
/// `DirectionalFloatProvider` so both ports steer the float lane identically.
struct DirectionalProvider;
impl EmbeddingProvider for DirectionalProvider {
    fn model_id(&self) -> &str { "test-directional-float-v1" }
    fn model_version(&self) -> &str { "1.0.0" }
    fn embed(&self, _text: &str) -> Result<Engram, SynapseKitError> { Ok(Engram::ZERO) }
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        let hash = text.bytes().fold(14_695_981_039_346_656_037u64, |acc, b| {
            (acc ^ u64::from(b)).wrapping_mul(1_099_511_628_211)
        });
        let mut v = vec![0.0_f32; 384];
        v[(hash % 384) as usize] = 1.0;
        Ok(v)
    }
}

fn make_directional_corpus() -> Corpus {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Corpus::open(
        storage,
        EmbeddingModelConfig::CandleNL { provider: Box::new(DirectionalProvider) },
    )
    .expect("Corpus::open must succeed with a host provider")
}

fn ids_of(outcome: &FloatLaneOutcome) -> Vec<String> {
    match outcome {
        FloatLaneOutcome::Hits(v) => v.iter().map(|(id, _)| id.clone()).collect(),
        _ => vec![],
    }
}

#[test]
fn float_farthest_per_signal_ranks_dissimilar_first() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_directional_corpus();
    corpus.ingest("alpha alpha alpha", "src-alpha", NOW_MILLIS).expect("ingest");
    corpus
        .ingest("omega omega omega different words", "src-omega", NOW_MILLIS)
        .expect("ingest");

    let nearest = corpus.float_nearest_per_signal("alpha alpha alpha", 5);
    let farthest = corpus.float_farthest_per_signal("alpha alpha alpha", 5);

    let near_ids = ids_of(&nearest[0].1);
    let far_ids = ids_of(&farthest[0].1);
    assert_eq!(near_ids.len(), 2, "nearest must surface both sources");
    assert_eq!(far_ids.len(), 2, "farthest must surface both sources");
    // The query direction matches src-alpha → nearest first; farthest must
    // place src-alpha LAST and the dissimilar src-omega FIRST.
    assert_eq!(near_ids.first().map(|s| s.as_str()), Some("src-alpha"));
    assert_eq!(far_ids.first().map(|s| s.as_str()), Some("src-omega"));
    assert_eq!(far_ids.last().map(|s| s.as_str()), Some("src-alpha"));
}

#[test]
fn float_farthest_per_signal_empty_query_yields_empty_per_signal() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_directional_corpus();
    let zero = corpus.float_farthest_per_signal("x", 0);
    let empty = corpus.float_farthest_per_signal("", 5);
    assert!(zero.iter().all(|(_, o)| matches!(o, FloatLaneOutcome::EmptyQuery)));
    assert!(empty.iter().all(|(_, o)| matches!(o, FloatLaneOutcome::EmptyQuery)));
}

#[test]
fn float_nearest_per_signal_unchanged_by_interleaved_farthest() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_directional_corpus();
    corpus.ingest("alpha alpha alpha", "src-alpha", NOW_MILLIS).expect("ingest");
    corpus
        .ingest("omega omega omega different", "src-omega", NOW_MILLIS)
        .expect("ingest");

    let near1 = corpus.float_nearest_per_signal("alpha alpha alpha", 5);
    let _ = corpus.float_farthest_per_signal("alpha alpha alpha", 5);
    let near2 = corpus.float_nearest_per_signal("alpha alpha alpha", 5);
    assert_eq!(ids_of(&near1[0].1), ids_of(&near2[0].1));
}
