//! Tests for `FloatDiscriminationSignal` and `float_nearest_per_signal_with_discrimination`.
//! Rust twin of `DiscriminationSignalTests.swift`.
//! Mission: MISSION_11X_RECALL_GAP_01 Stream D — Item 3 (saturation-aware
//! discrimination signal, CorpusKit measurement half).
//!
//! Coverage:
//!   §1  Dark outcomes — `float_nearest_per_signal_with_discrimination` yields
//!       `None` discrimination for every non-`Hits` outcome variant.
//!   §2  Saturated fixture — uniform provider → all cosines ≈ 1.0
//!       → `relative_spread` < 0.10 (discount would engage in coordinator).
//!   §3  Contrastive fixture — directional one-hot provider → clear winner
//!       at cosine 1.0, distractors at cosine 0.0 → `relative_spread` ≥ 0.15.
//!   §4  Single-hit outcome → `relative_spread` = 0.0 (max == min).
//!   §5  GLK factor formula — `min(1.0, mean_spread / 0.15)` mapping.
//!
//! INTELLECTUS LOCK: all tests hold GLOBAL_LOCK to prevent telemetry
//! cross-contamination with concurrently-running telemetry test suites.

use corpus_kit::{Corpus, EmbeddingModelConfig, FloatLaneOutcome};
use engram_lib::Engram;
use intellectus_lib::Intellectus;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use std::sync::{Arc, Mutex, OnceLock};
use synapsekit::{EmbeddingProvider, SynapseKitError};
use uuid::Uuid;

// ── Process-wide serialisation lock ──────────────────────────────────────────
//
// Shared with other test files (corpus_tests.rs, corpuskit_telemetry_tests.rs)
// via each file's own OnceLock binding. They each bind to the same process-wide
// address at runtime because Rust test binaries link all #[test] fns together.

static GLOBAL_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn global_lock() -> std::sync::MutexGuard<'static, ()> {
    let mutex = GLOBAL_LOCK.get_or_init(|| Mutex::new(()));
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poison) => poison.into_inner(),
    }
}

// ── Corpus helpers ────────────────────────────────────────────────────────────

const NOW_MS: i64 = 1_700_000_000_000;

fn new_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// One-hot 384-d directional provider: the FNV-1a hash of the text's UTF-8
/// bytes picks the axis, so distinct texts map to orthogonal directions
/// (cosine ≈ 0.0) and identical texts to the same direction (cosine 1.0).
/// Mirrors Swift `DirectionalEmbeddingProvider` in DiscriminationSignalTests.
struct DirectionalProvider;
impl EmbeddingProvider for DirectionalProvider {
    fn model_id(&self) -> &str { "test-directional-v1" }
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

/// Uniform provider: every text returns the same direction vector, so every
/// cosine similarity is 1.0. Mirrors Swift `UniformEmbeddingProvider`.
struct UniformProvider;
impl EmbeddingProvider for UniformProvider {
    fn model_id(&self) -> &str { "test-uniform-v1" }
    fn model_version(&self) -> &str { "1.0.0" }
    fn embed(&self, _text: &str) -> Result<Engram, SynapseKitError> { Ok(Engram::ZERO) }
    fn embed_float(&self, _text: &str) -> Result<Vec<f32>, SynapseKitError> {
        Ok(vec![1.0_f32; 384])
    }
}

/// `CandleNL` is the pass-through slot for a host-supplied, non-trainable
/// provider, which is exactly what a planted test provider is.
fn open_corpus(provider: Box<dyn EmbeddingProvider>) -> Corpus {
    Corpus::open(new_storage(), EmbeddingModelConfig::CandleNL { provider })
        .expect("Corpus::open must succeed with a host provider")
}

// ── §1: Dark outcomes → None discrimination ───────────────────────────────────

/// Empty query (limit = 0) → EmptyQuery outcome → discrimination is None.
#[test]
fn dark_empty_query_yields_none_discrimination() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = open_corpus(Box::new(DirectionalProvider));
    corpus.ingest("some content here", "doc1", NOW_MS).unwrap();

    let results = corpus.float_nearest_per_signal_with_discrimination("some content", 0);
    let (_, outcome, disc) = results.into_iter().next().expect("at least one slot");
    assert!(
        matches!(outcome, FloatLaneOutcome::EmptyQuery),
        "limit=0 must yield EmptyQuery; got {outcome:?}"
    );
    assert!(
        disc.is_none(),
        "EmptyQuery must yield None discrimination; got {disc:?}"
    );
}

/// No ingest on a float-capable corpus → UnavailableNoFloatRows → discrimination is None.
#[test]
fn dark_no_float_rows_yields_none_discrimination() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    // The provider CAN embed float, but no rows are stored → NoFloatRows.
    let corpus = open_corpus(Box::new(UniformProvider));
    let results = corpus.float_nearest_per_signal_with_discrimination("any query", 5);
    let (_, outcome, disc) = results.into_iter().next().expect("at least one slot");
    assert!(
        matches!(outcome, FloatLaneOutcome::UnavailableNoFloatRows),
        "empty corpus must yield UnavailableNoFloatRows; got {outcome:?}"
    );
    assert!(
        disc.is_none(),
        "UnavailableNoFloatRows must yield None discrimination; got {disc:?}"
    );
}

// ── §2: Saturated fixture ─────────────────────────────────────────────────────

/// Uniform model: all docs return the same direction vector → all cosines 1.0
/// → relative_spread = (1.0 - 1.0) / 1.0 = 0.0 < 0.10 (saturated regime).
#[test]
fn saturated_fixture_yields_low_spread() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = open_corpus(Box::new(UniformProvider));
    corpus.ingest("document one text",   "d1", NOW_MS).unwrap();
    corpus.ingest("document two text",   "d2", NOW_MS).unwrap();
    corpus.ingest("document three text", "d3", NOW_MS).unwrap();
    corpus.ingest("document four text",  "d4", NOW_MS).unwrap();

    let results = corpus.float_nearest_per_signal_with_discrimination("any query text", 4);
    let (_, outcome, disc) = results.into_iter().next().expect("at least one slot");

    assert!(
        matches!(outcome, FloatLaneOutcome::Hits(_)),
        "uniform corpus with ingest must yield Hits; got {outcome:?}"
    );
    let signal = disc.expect("saturated fixture must yield Some(FloatDiscriminationSignal)");
    assert!(
        signal.relative_spread < 0.10,
        "saturated fixture must produce spread < 0.10; got {}",
        signal.relative_spread
    );
}

// ── §3: Contrastive fixture ───────────────────────────────────────────────────

/// Directional model: query text == winner text → cosine 1.0 for winner.
/// Distractor texts differ → orthogonal one-hot slots → cosine 0.0.
/// Spread = (1.0 - 0.0) / 1.0 = 1.0 ≥ 0.15 (contrastive regime, no discount).
#[test]
fn contrastive_fixture_yields_high_spread() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = open_corpus(Box::new(DirectionalProvider));
    corpus.ingest("alpha alpha alpha", "winner",      NOW_MS).unwrap();
    corpus.ingest("omega omega omega", "distractor1", NOW_MS).unwrap();
    corpus.ingest("delta delta delta", "distractor2", NOW_MS).unwrap();
    corpus.ingest("sigma sigma sigma", "distractor3", NOW_MS).unwrap();

    // Query text identical to winner → same token sum → cosine 1.0 for winner.
    let results =
        corpus.float_nearest_per_signal_with_discrimination("alpha alpha alpha", 4);
    let (_, outcome, disc) = results.into_iter().next().expect("at least one slot");

    assert!(
        matches!(outcome, FloatLaneOutcome::Hits(_)),
        "directional corpus with ingest must yield Hits; got {outcome:?}"
    );
    let signal = disc.expect("contrastive fixture must yield Some(FloatDiscriminationSignal)");
    assert!(
        signal.relative_spread >= 0.15,
        "contrastive fixture must produce spread ≥ 0.15; got {}",
        signal.relative_spread
    );
}

// ── §4: Single-hit outcome ────────────────────────────────────────────────────

/// With `limit = 1`, the Hits list contains exactly one entry: max == min →
/// relative_spread = 0.0.
#[test]
fn single_hit_yields_zero_spread() {
    let _guard = global_lock();
    Intellectus::set_enabled(false);

    let corpus = open_corpus(Box::new(DirectionalProvider));
    corpus.ingest("alpha alpha alpha", "doc1", NOW_MS).unwrap();
    corpus.ingest("omega omega omega", "doc2", NOW_MS).unwrap();

    // Request exactly 1 result → single-element Hits list.
    let results =
        corpus.float_nearest_per_signal_with_discrimination("alpha alpha alpha", 1);
    let (_, outcome, disc) = results.into_iter().next().expect("at least one slot");

    match outcome {
        FloatLaneOutcome::Hits(ref hits) => {
            assert_eq!(hits.len(), 1, "limit=1 must yield exactly 1 hit");
        }
        _ => panic!("expected Hits for single-hit test; got {outcome:?}"),
    }

    let signal = disc.expect("single-hit must yield Some(FloatDiscriminationSignal)");
    assert_eq!(
        signal.relative_spread, 0.0,
        "single hit: max == min, spread must be 0.0; got {}",
        signal.relative_spread
    );
    assert_eq!(signal.hit_count, 1);
}

// ── §5: GLK coordinator factor formula ────────────────────────────────────────
//
// The coordinator computes: dense_discrimination_factor = (mean_spread / 0.15).min(1.0)
// These tests verify the formula in isolation — no estate or coordinator needed.
// Mirrors Swift §9.

fn glk_factor(spreads: &[f32]) -> f32 {
    let saturation_threshold: f32 = 0.15;
    if spreads.is_empty() {
        return 1.0;
    }
    let mean_spread = spreads.iter().sum::<f32>() / spreads.len() as f32;
    (mean_spread / saturation_threshold).min(1.0)
}

/// Saturated: spread 0.05 → factor ≈ 0.333 (discount engages).
#[test]
fn glk_factor_saturated_spread_0_05() {
    let f = glk_factor(&[0.05]);
    // 0.05 / 0.15 = 0.333...
    assert!(
        (f - 0.05 / 0.15).abs() < 0.002,
        "spread 0.05 must yield factor ≈ 0.333; got {f}"
    );
    assert!(f < 1.0, "factor must be < 1.0 for saturated spread");
}

/// Maximum discount: spread 0.0 → factor = 0.0.
#[test]
fn glk_factor_zero_spread_maximum_discount() {
    let f = glk_factor(&[0.0]);
    assert_eq!(f, 0.0, "spread 0.0 must yield factor = 0.0; got {f}");
}

/// Contrastive: spread 0.43 → factor = 1.0 (no discount).
#[test]
fn glk_factor_contrastive_spread_no_discount() {
    let f = glk_factor(&[0.43]);
    assert_eq!(f, 1.0, "contrastive spread 0.43 must yield factor = 1.0; got {f}");
}

/// Exactly at threshold: spread 0.15 → factor = 1.0.
#[test]
fn glk_factor_at_threshold_no_discount() {
    let f = glk_factor(&[0.15]);
    assert!(
        (f - 1.0).abs() < 0.001,
        "spread 0.15 must yield factor = 1.0; got {f}"
    );
}

/// No .hits signals → empty spreads → factor = 1.0.
#[test]
fn glk_factor_empty_spreads_no_discount() {
    let f = glk_factor(&[]);
    assert_eq!(f, 1.0, "empty spreads must yield factor = 1.0; got {f}");
}

/// Multi-signal: one saturated + one contrastive → mean above threshold → factor = 1.0.
#[test]
fn glk_factor_mixed_signals_mean_above_threshold() {
    // mean([0.05, 0.43]) = 0.24 → above 0.15 → factor = 1.0
    let f = glk_factor(&[0.05, 0.43]);
    assert_eq!(
        f, 1.0,
        "mean 0.24 > threshold 0.15 must not discount; got {f}"
    );
}

/// Multi-signal: both saturated → discount engages.
#[test]
fn glk_factor_both_saturated_discount_engages() {
    // mean([0.04, 0.06]) = 0.05 → factor ≈ 0.333
    let f = glk_factor(&[0.04, 0.06]);
    let expected = (0.05_f32 / 0.15).min(1.0);
    assert!(
        (f - expected).abs() < 0.002,
        "mean 0.05 must yield factor ≈ {expected}; got {f}"
    );
    assert!(f < 1.0, "both signals saturated must produce discount");
}
