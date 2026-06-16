//! Integration tests for `Corpus` — the unified RAG entry point.
//!
//! Mirrors the Swift `CorpusTests` suite. Uses `InMemoryStorage` for the
//! storage backend and `EmbeddingModelConfig::Deterministic` for the
//! provider (no model bundle required). Confirms that the Rust port
//! behaves identically to the Swift port on shared test vectors.
//!
//! INTELLECTUS LOCK: All tests that call corpus.ingest, corpus.recall, or
//! corpus.remove hold GLOBAL_LOCK for their entire duration. Corpus.ingest
//! internally calls BundleStore.insert (which emits corpuskit.ingest.*
//! metrics) and VectorStore.add_vector (which emits vectorkit.* metrics)
//! when monitoring is enabled. Concurrent telemetry tests that have a
//! capturing sink installed would see spurious emissions without the lock.

use corpus_kit::{Corpus, EmbeddingModelConfig, FloatLaneOutcome};
use intellectus_lib::Intellectus;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use uuid::Uuid;

// Process-wide serialisation lock shared with corpuskit_telemetry_tests.rs,
// bundle_store_tests.rs, and hybrid_recall_tests.rs. All tests that call
// Corpus methods hold this lock for their entire duration.
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

// MARK: - Round-trip

#[test]
fn round_trip_ingest_and_recall() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let text = "Swift is a powerful programming language developed by Apple. \
                It supports concurrency through actors and async/await semantics.";
    corpus
        .ingest(text, "doc-swift", NOW_MILLIS)
        .expect("ingest must succeed");

    let results = corpus
        .recall("programming language", 5, NOW_MILLIS)
        .expect("recall must succeed");

    assert!(!results.is_empty(), "recall must return at least one result");
    assert!(
        results.iter().all(|r| !r.chunk.text.is_empty()),
        "all results must have non-empty text"
    );
}

#[test]
fn recall_empty_corpus_returns_empty() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let results = corpus
        .recall("anything", 10, NOW_MILLIS)
        .expect("recall on empty corpus must not error");
    assert!(results.is_empty());
}

#[test]
fn recall_limit_zero_returns_empty() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus.ingest("hello world", "doc-1", NOW_MILLIS).unwrap();
    let results = corpus.recall("hello", 0, NOW_MILLIS).unwrap();
    assert!(results.is_empty());
}

// MARK: - Multi-source and remove

#[test]
fn multi_source_remove_excludes_removed_source() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let text_a = "Cryptography is the practice of securing communication using \
                  mathematical algorithms and secret keys for authentication.";
    let text_b = "Machine learning enables computers to learn from data without \
                  explicit programming, using neural network architectures.";

    corpus.ingest(text_a, "source-crypto", NOW_MILLIS).unwrap();
    corpus.ingest(text_b, "source-ml", NOW_MILLIS).unwrap();
    corpus.remove("source-crypto").expect("remove must succeed");

    let crypto_results = corpus
        .recall("cryptography authentication", 10, NOW_MILLIS)
        .unwrap();
    assert!(
        crypto_results
            .iter()
            .all(|r| r.chunk.source_id != "source-crypto"),
        "removed source must not appear in recall"
    );
}

#[test]
fn remove_nonexistent_source_is_noop() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus
        .remove("never-ingested")
        .expect("remove of nonexistent source must not error");
}

// MARK: - Count

#[test]
fn count_initially_zero() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    assert_eq!(corpus.count().unwrap(), 0);
}

#[test]
fn count_increases_after_ingest() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus.ingest("First document text.", "doc-1", NOW_MILLIS).unwrap();
    assert!(corpus.count().unwrap() >= 1);
}

#[test]
fn count_unchanged_after_remove() {
    // BundleStore is append-only: count does not decrease on remove.
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus
        .ingest("Some content for removal test.", "src-x", NOW_MILLIS)
        .unwrap();
    let before = corpus.count().unwrap();
    corpus.remove("src-x").unwrap();
    let after = corpus.count().unwrap();
    assert_eq!(after, before, "count must not decrease after remove (BundleStore is append-only)");
}

// MARK: - Deduplication

#[test]
fn dedup_reingest_is_idempotent() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let text = "Idempotent deduplication test — unique wording for this fixture.";
    corpus.ingest(text, "doc-dedup", NOW_MILLIS).unwrap();
    let count_after_first = corpus.count().unwrap();
    corpus.ingest(text, "doc-dedup", NOW_MILLIS).unwrap();
    let count_after_second = corpus.count().unwrap();
    assert_eq!(
        count_after_first, count_after_second,
        "re-ingesting same text must be idempotent (content-addressed chunks)"
    );
}

// MARK: - Rust / Swift parity on chunk ids

/// Shared test vector from BundleStoreTests / ChunkTests (cross-language
/// ground truth). The Swift port asserts the same UUID.
#[test]
fn chunk_id_parity_with_swift() {
    use corpus_kit::Chunk;
    let id =
        Chunk::derive_id("doc-A", 0, "hello world");
    assert_eq!(
        id.to_string().to_lowercase(),
        "e12ecb90-0ba9-588d-8d83-c0266f6aa2d5",
        "chunk id must match the Swift RFC 4122 v5 ground truth"
    );
}

// MARK: - FloatLaneOutcome — observable degradation contract
//
// Mirrors Swift FloatLaneOutcomeTests §1–§4.
// Every test holds GLOBAL_LOCK to prevent interleaving with
// telemetry-capturing tests.

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
/// Run float_nearest with monitoring off, then on; results must be identical.
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

impl vectorkit::EmbeddingProvider for ThrowingFloatProvider {
    fn model_id(&self) -> &str { "test-throwing-float-v1" }
    fn model_version(&self) -> &str { "1.0.0" }

    fn embed(&self, _text: &str) -> Result<engram_lib::Engram, vectorkit::VectorKitError> {
        // Return the zero engram — satisfies the contract for empty/non-empty inputs.
        Ok(engram_lib::Engram::ZERO)
    }

    fn embed_float(&self, _text: &str) -> Result<Vec<f32>, vectorkit::VectorKitError> {
        // Always opt out — this provider has no float lane.
        Err(vectorkit::VectorKitError::EmbeddingFailed(
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

// MARK: - Named model cases (B2-5: Rust embedding parity)
//
// The named EmbeddingModelConfig cases (MiniLM/MPNet/EmbeddingGemma)
// carry a host-supplied inference closure, exactly like Swift. These
// tests use a fake inference closure (a model bundle is never bundled)
// to prove the facade wires the named providers correctly: ingest +
// recall succeed, and the float lane is AVAILABLE (unlike Deterministic,
// whose provider opts out of the float lane).

/// Fake inference: a fixed-dimension vector derived from the token
/// count. Stands in for a real model pass — the kit owns tokenization
/// and projection, the host owns this closure.
fn fake_inference(dim: usize) -> corpus_kit::NamedInferenceFn {
    Box::new(move |tokens: &[i32]| {
        let base = (tokens.len() as f32).max(1.0);
        Ok((0..dim).map(|d| ((d as f32 + 1.0) / base).sin()).collect())
    })
}

fn make_corpus_minilm() -> Corpus {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Corpus::open(
        storage,
        EmbeddingModelConfig::MiniLM { inference: fake_inference(384) },
    )
    .expect("Corpus::open must succeed with MiniLM config")
}

#[test]
fn named_minilm_round_trip_ingest_and_recall() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus_minilm();
    corpus
        .ingest(
            "Swift and Rust both ship from one substrate with shared test vectors.",
            "doc-parity",
            NOW_MILLIS,
        )
        .expect("ingest must succeed under a named provider");
    let results = corpus
        .recall("shared substrate", 5, NOW_MILLIS)
        .expect("recall must succeed");
    assert!(!results.is_empty(), "named-provider recall must return results");
}

#[test]
fn named_minilm_float_lane_is_available() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus_minilm();
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

#[test]
fn named_providers_construct_for_all_three_models() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    for cfg in [
        EmbeddingModelConfig::MiniLM { inference: fake_inference(384) },
        EmbeddingModelConfig::MPNet { inference: fake_inference(768) },
        EmbeddingModelConfig::EmbeddingGemma { inference: fake_inference(768) },
    ] {
        let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
        let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
        let corpus = Corpus::open(storage, cfg).expect("named config must open");
        corpus.ingest("content", "src", NOW_MILLIS).expect("ingest must succeed");
        assert_eq!(corpus.count().expect("count must succeed"), 1);
    }
}
