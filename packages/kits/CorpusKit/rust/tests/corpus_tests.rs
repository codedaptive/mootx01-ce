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
//! metrics) and VectorStore.add_vector (which emits synapsekit.* metrics)
//! when monitoring is enabled. Concurrent telemetry tests that have a
//! capturing sink installed would see spurious emissions without the lock.

use corpus_kit::{Corpus, EmbeddingModelConfig};
use engram_lib::Engram;
use intellectus_lib::Intellectus;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use synapsekit::{EmbeddingProvider, SynapseKitError};
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
fn count_excludes_removed_source() {
    // count() reports live recall content only: removing the sole source drops it
    // to zero (chunk rows survive in the append-only store). Re-ingest reactivates.
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus
        .ingest("Some content for removal test.", "src-x", NOW_MILLIS)
        .unwrap();
    let before = corpus.count().unwrap();
    assert!(before >= 1);
    corpus.remove("src-x").unwrap();
    assert_eq!(corpus.count().unwrap(), 0, "removed source must not be counted");
    corpus
        .ingest("Some content for removal test.", "src-x", NOW_MILLIS)
        .unwrap();
    assert_eq!(corpus.count().unwrap(), before, "re-ingest reactivates the source");
}

// REGRESSION (Codex finding 2): a reindex after remove must NOT resurrect the
// removed source — reindex reads the append-only chunks table and must use ACTIVE
// chunks only (the auto-reindex daemon makes this a normal-operation hazard).
#[test]
fn reindex_does_not_resurrect_removed_source() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    let text_a = "Cryptography secures communication using mathematical algorithms and keys.";
    let text_b = "Machine learning trains neural networks on data without explicit rules.";
    corpus.ingest(text_a, "source-crypto", NOW_MILLIS).unwrap();
    corpus.ingest(text_b, "source-ml", NOW_MILLIS).unwrap();

    corpus.remove("source-crypto").expect("remove");
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let results = corpus
        .recall("cryptography authentication keys", 10, NOW_MILLIS)
        .unwrap();
    assert!(
        results.iter().all(|r| r.chunk.source_id != "source-crypto"),
        "reindex must not resurrect the removed source"
    );
    let ml = corpus
        .recall("neural network learning data", 10, NOW_MILLIS)
        .unwrap();
    assert!(
        ml.iter().any(|r| r.chunk.source_id == "source-ml"),
        "non-removed source must survive reindex"
    );
}

// REGRESSION (Codex finding 2, BATCH import path): sources arrive via
// ingest_batch (the drain path); the active-chunks fix must hold there too.
#[test]
fn batch_import_reindex_does_not_resurrect_removed_source() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus();
    corpus
        .ingest_batch(&[
            (
                "Cryptography secures communication using mathematical algorithms and keys."
                    .to_string(),
                "source-crypto".to_string(),
                NOW_MILLIS,
            ),
            (
                "Machine learning trains neural networks on data without explicit rules."
                    .to_string(),
                "source-ml".to_string(),
                NOW_MILLIS,
            ),
        ])
        .expect("ingest_batch");
    corpus.remove("source-crypto").expect("remove");
    corpus.reindex(NOW_MILLIS).expect("reindex");

    let results = corpus
        .recall("cryptography authentication keys", 10, NOW_MILLIS)
        .unwrap();
    assert!(
        results.iter().all(|r| r.chunk.source_id != "source-crypto"),
        "batch-imported removed source must not resurrect on reindex"
    );
    let ml = corpus
        .recall("neural network learning data", 10, NOW_MILLIS)
        .unwrap();
    assert!(
        ml.iter().any(|r| r.chunk.source_id == "source-ml"),
        "non-removed batch-imported source must survive reindex"
    );
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

// MARK: - CandleNL provider round-trip (B2-5: Rust embedding parity)
//
// `CandleNL` is the surviving host-supplied-EmbeddingProvider case after the
// audition losers (MiniLM/MPNet/EmbeddingGemma) were retired. These tests use
// a stub provider to prove the facade wires the provider correctly: ingest +
// recall succeed and the float lane is AVAILABLE.

/// Fixed-dimension vector derived from text length. Stands in for a real
/// model pass — the kit owns the pipeline, the host owns this provider.
struct FakeVectorProvider {
    dim: usize,
}

impl EmbeddingProvider for FakeVectorProvider {
    fn model_id(&self) -> &str { "test-fake-vector-v1" }
    fn model_version(&self) -> &str { "1.0.0" }
    fn embed(&self, _text: &str) -> Result<Engram, SynapseKitError> {
        Ok(Engram::ZERO)
    }
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        if text.is_empty() { return Ok(vec![]); }
        let base = (text.len() as f32).max(1.0);
        Ok((0..self.dim).map(|d| ((d as f32 + 1.0) / base).sin()).collect())
    }
}

fn make_corpus_candle_nl() -> Corpus {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Corpus::open(
        storage,
        EmbeddingModelConfig::CandleNL { provider: Box::new(FakeVectorProvider { dim: 384 }) },
    )
    .expect("Corpus::open must succeed with CandleNL config")
}

#[test]
fn candle_nl_round_trip_ingest_and_recall() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let corpus = make_corpus_candle_nl();
    corpus
        .ingest(
            "Swift and Rust both ship from one substrate with shared test vectors.",
            "doc-parity",
            NOW_MILLIS,
        )
        .expect("ingest must succeed under a CandleNL provider");
    let results = corpus
        .recall("shared substrate", 5, NOW_MILLIS)
        .expect("recall must succeed");
    assert!(!results.is_empty(), "CandleNL provider recall must return results");
}

// ── Farthest (anti-similarity, mission 6b-modifiers-antisim) ─────────────────

#[test]
fn candle_nl_provider_constructs_and_indexes_content() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Corpus::open(
        storage,
        EmbeddingModelConfig::CandleNL { provider: Box::new(FakeVectorProvider { dim: 384 }) },
    )
    .expect("CandleNL config must open");
    corpus.ingest("content", "src", NOW_MILLIS).expect("ingest must succeed");
    assert_eq!(corpus.count().expect("count must succeed"), 1);
}
