//! Tests for `sub_span_scoring` — transient sub-span max-cosine scoring.
//! Rust twin of Swift `SubSpanScoringTests.swift`.
//! Mission: MISSION_11X_RECALL_GAP_01 Stream E — Item 1.
//!
//! Coverage:
//!   §1  `sub_span_ranges` — deterministic segmentation unit tests.
//!         Verifies UTF-8 byte-offset calculation, window/stride arithmetic,
//!         and overlap stitching. Cross-port contract: must produce bit-identical
//!         ranges as Swift `subSpanRanges` for the same inputs.
//!   §2  `cosine_similarity` — inline L2-normalized dot product unit tests.
//!         Covers identical, orthogonal, opposite, and zero vectors.
//!   §3  `score()` — empty-input fast-path guard.
//!         Empty query or empty candidateIDs → empty map without hitting the
//!         source or provider.
//!   §4  `score()` — provider without a float lane (embed_float returns Err).
//!         Verifies silent degradation: empty map returned, no panic.
//!   §5  Sub-span rescue fixture (the 1.0.x scenario).
//!         A saturated corpus where whole-doc cosine fails to separate but
//!         sub-span max-cosine ranks the true answer first. Uses
//!         `FirstTokenRoutingProvider` and `MapContentSource`.
//!   §6a `CorpusContentEngine::score_sub_spans` delegation.
//!         Verifies the engine wires source + provider and returns scored results.
//!   §6b `Corpus::score_sub_spans` — chunk-based path.
//!         Verifies the corpus path produces non-empty results.

use corpus_kit::{
    content_digest, sub_span_scoring, CorpusContentChangeBatch, CorpusContentConfiguration,
    CorpusContentEngine, CorpusContentId, CorpusContentRecord, CorpusContentSource,
    CorpusContentStore, CorpusDocumentStore, CorpusKitError, CorpusIndexUnitPolicy, CorpusOperatingMode,
    EmbeddingModelConfig, NamedInferenceFn,
};
use corpus_kit::Corpus;
use engram_lib::Engram;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use std::collections::HashMap;
use std::sync::Arc;
use uuid::Uuid;
use vectorkit::{EmbeddingProvider, VectorKitError};

// ── Constants ─────────────────────────────────────────────────────────────────

const NOW_MS: i64 = 1_700_000_000_000;

// ── Mock providers ────────────────────────────────────────────────────────────

/// Routes `embed_float` by text prefix.
///
/// "target…" → vec_A = [1.0, 0.0] (the "query direction").
/// Anything else → vec_B = [0.0, 1.0] (orthogonal).
///
/// Cosine(vec_A, vec_A) = 1.0 → normalized (1+1)/2 = 1.0.
/// Cosine(vec_A, vec_B) = 0.0 → normalized (0+1)/2 = 0.5.
///
/// Mirrors Swift `FirstTokenRoutingProvider`.
struct FirstTokenRoutingProvider;

impl EmbeddingProvider for FirstTokenRoutingProvider {
    fn model_id(&self) -> &str {
        "test-first-token-routing-v1"
    }

    fn model_version(&self) -> &str {
        "1.0.0"
    }

    fn embed(&self, _text: &str) -> Result<Engram, VectorKitError> {
        // Not called by sub_span_scoring::score — stub satisfies trait.
        Err(VectorKitError::EmbeddingFailed(
            "FirstTokenRoutingProvider: embed() not needed for sub-span tests".into(),
        ))
    }

    fn embed_float(&self, text: &str) -> Result<Vec<f32>, VectorKitError> {
        if text.is_empty() {
            return Ok(vec![]);
        }
        // Route: texts starting with "target" → vec_A, others → vec_B.
        if text.starts_with("target") {
            Ok(vec![1.0, 0.0])
        } else {
            Ok(vec![0.0, 1.0])
        }
    }
}

/// Float-lane opt-out: `embed_float` uses the default throwing implementation.
/// Used in §4 to verify that `score()` returns an empty map on opt-out.
///
/// Mirrors Swift `ThrowingFloatProvider`.
struct ThrowingFloatProvider;

impl EmbeddingProvider for ThrowingFloatProvider {
    fn model_id(&self) -> &str {
        "test-throwing-float-v1"
    }

    fn model_version(&self) -> &str {
        "1.0.0"
    }

    fn embed(&self, _text: &str) -> Result<Engram, VectorKitError> {
        Err(VectorKitError::EmbeddingFailed(
            "ThrowingFloatProvider: embed() not used".into(),
        ))
    }

    // embed_float falls back to the default opt-out impl which returns Err.
}

// ── Mock content source ───────────────────────────────────────────────────────

/// In-memory `CorpusContentSource` backed by a `HashMap`.
///
/// Implements only the minimum surface needed for `sub_span_scoring::score()`.
/// Does NOT override `records_for()` — exercises the N-serial default
/// implementation that GLK's LocusKit-backed adapter also relies on.
///
/// Mirrors Swift `MapContentSource`.
struct MapContentSource {
    records: HashMap<String, CorpusContentRecord>,
}

impl MapContentSource {
    fn new(pairs: Vec<(&str, &str)>) -> Self {
        let records = pairs
            .into_iter()
            .map(|(id, text)| {
                (
                    id.to_string(),
                    CorpusContentRecord {
                        id: id.to_string(),
                        revision: 1,
                        digest: content_digest(text),
                        text: text.to_string(),
                        dense_composition_text: None,
                    },
                )
            })
            .collect();
        Self { records }
    }

    fn with_record(mut self, record: CorpusContentRecord) -> Self {
        self.records.insert(record.id.clone(), record);
        self
    }
}

impl CorpusContentSource for MapContentSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        Ok(self.records.get(id).cloned())
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        Ok(CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let mut ids: Vec<String> = self.records.keys().cloned().collect();
        ids.sort();
        Ok(ids)
    }
}

// ── Storage helpers ───────────────────────────────────────────────────────────

fn in_memory_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

fn make_engine(
    inference: NamedInferenceFn,
) -> (CorpusContentEngine, Arc<CorpusDocumentStore>) {
    let storage = in_memory_storage();
    let config =
        CorpusContentConfiguration::new(CorpusOperatingMode::Standalone, CorpusIndexUnitPolicy::WholeContent)
            .unwrap();
    storage
        .migrate(&corpus_kit::standalone_declaration(false))
        .expect("migrate standalone profile");
    let store = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
    let engine = CorpusContentEngine::open(
        Arc::clone(&storage),
        config,
        Arc::clone(&store) as Arc<dyn CorpusContentSource>,
        vec![EmbeddingModelConfig::MiniLM { inference }],
    )
    .expect("open engine");
    (engine, store)
}

/// One-hot 384-d directional inference: token sums map to distinct directions.
/// Mirrors Swift `directionalModel()` and `directional_inference()` in
/// `discrimination_signal_tests.rs`.
fn directional_inference() -> NamedInferenceFn {
    Box::new(|tokens: &[i32]| {
        let mut v = vec![0.0_f32; 384];
        let sum: i32 = tokens.iter().fold(0i32, |a, t| a.wrapping_add(*t));
        let slot = ((sum % 384 + 384) % 384) as usize;
        v[slot] = 1.0;
        Ok(v)
    })
}

// ── §1: sub_span_ranges — deterministic segmentation ─────────────────────────

#[test]
fn sub_span_ranges_empty_text_yields_empty() {
    let ranges = sub_span_scoring::sub_span_ranges("", 32, 8);
    assert!(ranges.is_empty(), "empty text must produce no ranges");
}

#[test]
fn sub_span_ranges_punctuation_only_yields_empty() {
    let ranges = sub_span_scoring::sub_span_ranges("   .,!?---   ", 4, 0);
    assert!(ranges.is_empty(), "punctuation-only text must produce no ranges");
}

#[test]
fn sub_span_ranges_single_token_yields_one_range() {
    let ranges = sub_span_scoring::sub_span_ranges("hello", 4, 0);
    assert_eq!(ranges.len(), 1, "single token must produce one range");
    assert_eq!(ranges[0], (0, 5), "'hello' = 5 bytes; range must be (0, 5)");
}

#[test]
fn sub_span_ranges_two_tokens_inside_window_yields_single_range() {
    let text = "hello world";
    let ranges = sub_span_scoring::sub_span_ranges(text, 4, 0);
    assert_eq!(ranges.len(), 1, "two tokens in a 4-token window must be one range");
    assert_eq!(ranges[0].0, 0, "range start must be 0");
    // "hello world" = 11 bytes; span covers all of it.
    assert_eq!(ranges[0].1, 11, "span length must cover 'hello world' = 11 bytes");
}

#[test]
fn sub_span_ranges_eight_tokens_window4_overlap0_yields_two_ranges() {
    // "n1 n2 n3 n4 t1 t2 t3 t4" — 8 tokens; window=4, stride=4 → 2 spans.
    // Byte layout (all ASCII):
    //   "n1"(0-1) " "(2) "n2"(3-4) " "(5) "n3"(6-7) " "(8) "n4"(9-10) " "(11)
    //   "t1"(12-13) " "(14) "t2"(15-16) " "(17) "t3"(18-19) " "(20) "t4"(21-22)
    let text = "n1 n2 n3 n4 t1 t2 t3 t4";
    let ranges = sub_span_scoring::sub_span_ranges(text, 4, 0);
    assert_eq!(ranges.len(), 2, "8 tokens with window=4 overlap=0 must produce 2 ranges");
    // Window 0: "n1 n2 n3 n4" — bytes [0, 11).
    assert_eq!(ranges[0], (0, 11), "window 0 must start at 0, length 11");
    let span0 = &text.as_bytes()[ranges[0].0..ranges[0].0 + ranges[0].1];
    assert_eq!(std::str::from_utf8(span0).unwrap(), "n1 n2 n3 n4");
    // Window 1: "t1 t2 t3 t4" — bytes [12, 23).
    assert_eq!(ranges[1], (12, 11), "window 1 must start at 12, length 11");
    let span1 = &text.as_bytes()[ranges[1].0..ranges[1].0 + ranges[1].1];
    assert_eq!(std::str::from_utf8(span1).unwrap(), "t1 t2 t3 t4");
}

#[test]
fn sub_span_ranges_overlap_stitches_adjacent_windows() {
    // "a b c d e f" — 6 tokens, window=4, overlap=2, stride=2.
    //   Window 0: tokens[0..3] = "a b c d"
    //   Window 1: tokens[2..5] = "c d e f"
    let text = "a b c d e f";
    let ranges = sub_span_scoring::sub_span_ranges(text, 4, 2);
    assert_eq!(ranges.len(), 2, "6 tokens with window=4 overlap=2 must produce 2 ranges");
    let span0 = extract_span(text, ranges[0]);
    let span1 = extract_span(text, ranges[1]);
    assert_eq!(span0, "a b c d", "window 0 must cover 'a b c d'; got '{span0}'");
    assert_eq!(span1, "c d e f", "window 1 must cover 'c d e f'; got '{span1}'");
}

#[test]
fn sub_span_ranges_window_larger_than_tokens_yields_single_span() {
    let text = "alpha beta gamma"; // 3 tokens
    let ranges = sub_span_scoring::sub_span_ranges(text, 32, 8);
    assert_eq!(ranges.len(), 1, "3 tokens in a 32-token window must produce 1 range");
    let span = extract_span(text, ranges[0]);
    assert_eq!(span, "alpha beta gamma");
}

#[test]
fn sub_span_ranges_ascii_digits_are_token_characters() {
    // "h2o co2" — two tokens: "h2o" and "co2" (digits are in-token).
    let text = "h2o co2";
    let ranges = sub_span_scoring::sub_span_ranges(text, 4, 0);
    assert_eq!(ranges.len(), 1, "'h2o' and 'co2' are single tokens; both fit in window=4");
    let span = extract_span(text, ranges[0]);
    assert_eq!(span, "h2o co2");
}

fn extract_span(text: &str, (start, length): (usize, usize)) -> String {
    let bytes = text.as_bytes();
    std::str::from_utf8(&bytes[start..start + length])
        .unwrap()
        .to_string()
}

// ── §2: cosine_similarity — inline dot-product unit tests ────────────────────

#[test]
fn cosine_identical_unit_vectors_yields_one() {
    let a: Vec<f32> = vec![1.0, 0.0, 0.0];
    let b: Vec<f32> = vec![1.0, 0.0, 0.0];
    let c = sub_span_scoring::cosine_similarity(&a, &b);
    assert!((c - 1.0).abs() < 0.0001, "identical vectors must yield cosine 1.0; got {c}");
}

#[test]
fn cosine_orthogonal_unit_vectors_yields_zero() {
    let a: Vec<f32> = vec![1.0, 0.0];
    let b: Vec<f32> = vec![0.0, 1.0];
    let c = sub_span_scoring::cosine_similarity(&a, &b);
    assert!(c.abs() < 0.0001, "orthogonal vectors must yield cosine 0.0; got {c}");
}

#[test]
fn cosine_opposite_unit_vectors_yields_negative_one() {
    let a: Vec<f32> = vec![1.0, 0.0];
    let b: Vec<f32> = vec![-1.0, 0.0];
    let c = sub_span_scoring::cosine_similarity(&a, &b);
    assert!((c + 1.0).abs() < 0.0001, "opposite vectors must yield cosine -1.0; got {c}");
}

#[test]
fn cosine_non_unit_same_direction_yields_one() {
    let a: Vec<f32> = vec![2.0, 0.0];
    let b: Vec<f32> = vec![5.0, 0.0];
    let c = sub_span_scoring::cosine_similarity(&a, &b);
    assert!((c - 1.0).abs() < 0.0001, "scaled same-direction vectors must yield cosine 1.0; got {c}");
}

#[test]
fn cosine_zero_vector_yields_safe_zero() {
    let a: Vec<f32> = vec![1.0, 0.0];
    let z: Vec<f32> = vec![0.0, 0.0];
    let c = sub_span_scoring::cosine_similarity(&a, &z);
    assert_eq!(c, 0.0, "zero-norm vector must yield cosine 0.0 (safe fallback); got {c}");
}

#[test]
fn cosine_empty_vectors_yield_zero() {
    let c = sub_span_scoring::cosine_similarity(&[], &[]);
    assert_eq!(c, 0.0, "empty vectors must yield cosine 0.0; got {c}");
}

#[test]
fn cosine_mismatched_length_yields_zero() {
    let a: Vec<f32> = vec![1.0, 0.0];
    let b: Vec<f32> = vec![1.0, 0.0, 0.0];
    let c = sub_span_scoring::cosine_similarity(&a, &b);
    assert_eq!(c, 0.0, "mismatched-length vectors must yield cosine 0.0; got {c}");
}

// ── §3: score() — empty-input fast-path ──────────────────────────────────────

#[test]
fn score_empty_query_yields_empty_map() {
    let provider = ThrowingFloatProvider;
    let source = MapContentSource::new(vec![("a", "hello world")]);
    let result = sub_span_scoring::score("", &["a"], &source, &provider, 4, 0);
    assert!(result.is_empty(), "empty query must return empty map without calling provider");
}

#[test]
fn score_empty_candidate_ids_yields_empty_map() {
    let provider = ThrowingFloatProvider;
    let source = MapContentSource::new(vec![("a", "hello world")]);
    let result = sub_span_scoring::score("hello", &[], &source, &provider, 4, 0);
    assert!(result.is_empty(), "empty candidateIDs must return empty map without calling source");
}

// ── §4: score() — provider without float lane ─────────────────────────────────

#[test]
fn score_throwing_provider_yields_empty_map() {
    let provider = ThrowingFloatProvider;
    let source = MapContentSource::new(vec![
        ("doc1", "this is a document"),
        ("doc2", "another document here"),
    ]);
    let result = sub_span_scoring::score(
        "document",
        &["doc1", "doc2"],
        &source,
        &provider,
        4,
        0,
    );
    assert!(result.is_empty(), "provider without float lane must return empty map; got {result:?}");
}

// ── §5: Sub-span rescue fixture ───────────────────────────────────────────────

/// The 1.0.x scenario: whole-doc cosine fails to separate the true answer
/// from distractors, but sub-span max-cosine ranks it first.
///
/// Fixture design mirrors Swift §5 in SubSpanScoringTests:
///   - Provider: `FirstTokenRoutingProvider`
///     • text starting with "target" → vec_A = [1.0, 0.0]
///     • other text → vec_B = [0.0, 1.0]
///   - Query: "target" → vec_A
///   - True answer: "noise noise noise noise target target target target"
///     • window=4, overlap=0: window 1 = "target target target target" → vec_A
///     → max-cosine = 1.0
///   - Distractor: "noise noise noise noise noise noise noise noise"
///     → all windows → vec_B → max-cosine = cosine(A,B)=0 → norm 0.5
#[test]
fn score_sub_span_rescue_ranks_true_answer_first() {
    let provider = FirstTokenRoutingProvider;
    let source = MapContentSource::new(vec![
        (
            "true_answer",
            "noise noise noise noise target target target target",
        ),
        (
            "distractor1",
            "noise noise noise noise noise noise noise noise",
        ),
        (
            "distractor2",
            "noise noise noise noise noise noise noise noise",
        ),
    ]);

    let results = sub_span_scoring::score(
        "target",
        &["true_answer", "distractor1", "distractor2"],
        &source,
        &provider,
        4, // window=4
        0, // overlap=0
    );

    // All three must appear in the map.
    let true_score = *results.get("true_answer").expect("true_answer must be scored");
    let dist_score1 = *results.get("distractor1").expect("distractor1 must be scored");
    let dist_score2 = *results.get("distractor2").expect("distractor2 must be scored");

    // True answer must outscore distractors.
    assert!(
        true_score > dist_score1,
        "true_answer ({true_score}) must outscore distractor1 ({dist_score1})"
    );
    assert!(
        true_score > dist_score2,
        "true_answer ({true_score}) must outscore distractor2 ({dist_score2})"
    );

    // Exact score assertions: true_answer = 1.0, distractors = 0.5.
    assert!(
        (true_score - 1.0).abs() < 0.001,
        "true_answer sub-span cosine must normalize to 1.0; got {true_score}"
    );
    assert!(
        (dist_score1 - 0.5).abs() < 0.001,
        "distractor1 cosine 0.0 must normalize to 0.5; got {dist_score1}"
    );
}

#[test]
fn score_absent_candidate_is_omitted() {
    let provider = FirstTokenRoutingProvider;
    let source = MapContentSource::new(vec![("present", "target target")]);
    let results = sub_span_scoring::score(
        "target",
        &["present", "absent_id"],
        &source,
        &provider,
        4,
        0,
    );
    assert!(results.contains_key("present"), "present candidate must be scored");
    assert!(
        !results.contains_key("absent_id"),
        "absent candidate must be omitted (implicit 0.0)"
    );
}

#[test]
fn score_uses_effective_dense_text() {
    // Record whose `text` is "noise content" (→ vec_B) but
    // `dense_composition_text` is "target enrichment" (→ vec_A).
    // Sub-span scoring uses `effective_dense_text()` = "target enrichment",
    // so the score must be 1.0 (cosine vec_A, vec_A normalized).
    let record = CorpusContentRecord {
        id: "dual_text".to_string(),
        revision: 1,
        digest: content_digest("noise content"),
        text: "noise content".to_string(),
        dense_composition_text: Some("target enrichment".to_string()),
    };
    let source = MapContentSource::new(vec![]).with_record(record);
    let provider = FirstTokenRoutingProvider;

    let results = sub_span_scoring::score(
        "target",
        &["dual_text"],
        &source,
        &provider,
        4,
        0,
    );
    let score = *results.get("dual_text").expect("dual_text must be scored");
    assert!(
        (score - 1.0).abs() < 0.001,
        "effective_dense_text must be used; expected score 1.0, got {score}"
    );
}

// ── §6a: CorpusContentEngine::score_sub_spans delegation ─────────────────────

/// Verifies that `CorpusContentEngine::score_sub_spans` delegates correctly:
/// wires `self.source` (CorpusDocumentStore) and `slots[0]` provider (the
/// directional inference model) to `sub_span_scoring::score`. Uses
/// `directional_inference()` which maps token-sum to one-hot 384-d, so
/// "alpha alpha alpha" (query ≡ doc1) scores higher than "omega omega omega"
/// (doc2, orthogonal direction).
#[test]
fn engine_score_sub_spans_returns_scored_results() {
    let (engine, store) = make_engine(directional_inference());
    store.put("alpha alpha alpha", "doc1", NOW_MS).unwrap();
    store.put("omega omega omega", "doc2", NOW_MS).unwrap();

    // score_sub_spans does NOT require index_content — it resolves records
    // directly via the source, mirroring the Swift test.
    let results = engine.score_sub_spans("alpha alpha alpha", &["doc1", "doc2"]);

    assert!(!results.is_empty(), "score_sub_spans must return scored results for content in source");

    let score1 = *results.get("doc1").unwrap_or(&0.0);
    let score2 = *results.get("doc2").unwrap_or(&0.0);
    assert!(
        score1 > score2,
        "doc1 (matching direction) must outscore doc2; doc1={score1}, doc2={score2}"
    );
}

#[test]
fn engine_score_sub_spans_absent_candidate_omitted() {
    let (engine, store) = make_engine(directional_inference());
    store.put("alpha alpha alpha", "present", NOW_MS).unwrap();

    let results = engine.score_sub_spans("alpha alpha alpha", &["present", "nonexistent"]);

    assert!(results.contains_key("present"), "present candidate must be scored");
    assert!(
        !results.contains_key("nonexistent"),
        "absent candidate must be omitted"
    );
}

// ── §6b: Corpus::score_sub_spans — chunk-based path ─────────────────────────

/// Verifies that `Corpus::score_sub_spans` uses the BundleStore chunk path
/// and returns non-empty results for ingested content. Uses `directional_inference()`.
#[test]
fn corpus_score_sub_spans_chunk_path_returns_results() {
    let storage = in_memory_storage();
    let corpus = Corpus::open(
        Arc::clone(&storage),
        EmbeddingModelConfig::MiniLM {
            inference: directional_inference(),
        },
    )
    .expect("Corpus::open must succeed");

    // Use the SAME text as the query for source1 so the token-sum hash
    // lands on the same one-hot slot. directional_inference maps token sums
    // to slots, so a 3-alpha source and a 3-alpha query share a slot → cosine 1.0.
    corpus
        .ingest("alpha alpha alpha", "source1", NOW_MS)
        .unwrap();
    corpus
        .ingest("omega omega omega", "source2", NOW_MS)
        .unwrap();

    let results = corpus.score_sub_spans("alpha alpha alpha", &["source1", "source2"]);

    assert!(!results.is_empty(), "score_sub_spans must return results for ingested sources");

    let score1 = *results.get("source1").unwrap_or(&0.0);
    let score2 = *results.get("source2").unwrap_or(&0.0);
    assert!(
        score1 > score2,
        "source1 (matching direction) must outscore source2; s1={score1}, s2={score2}"
    );
}
