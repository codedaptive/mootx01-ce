//! The span rerank stage inside the UnionBest lane (Encoder Rerank Program,
//! contract sheet §8) on a 200-drawer in-memory estate with a corpus. Mirrors
//! Swift SpanRerankStageTests.swift:
//!
//!   (a) `no_encoder` == today's `no_vector` order (the order before any encoder
//!       existed) while an encoder is registered whose stage WOULD reorder the
//!       head. Failure mode: the stage leaks into the ablation (no_encoder then
//!       equals the balanced order instead).
//!   (b) balanced runs the stage: the drawer the fake encoder scores rises to
//!       the top, carries its span bounds on the hit, and its `score:` explain
//!       line carries the `span:<index>:<cosine>` token. `no_vector` with an
//!       encoder registered runs the stage too (it only names the default
//!       vector budget), so it equals balanced.
//!   (c) the default fusion (None shape) equals `no_vector` before any encoder.
//!   (d) an encoder failure leaves the lexical order standing and names the
//!       stage on degraded_stages.

use std::collections::HashMap;
use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, RecallFallbackPolicy,
    RecallOrigin, RecallShape,
};
use genius_locus_kit::span_rerank::{
    SpanRerankEncoding, SpanRerankError, SpanRerankHit, SpanRerankVector, SpanVectorReading,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::RecallFrame;
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;

/// A query encoder that returns a fixed unit vector (dim 4) so the stage's
/// cosines are decided entirely by the fake span rows below.
struct FixedEncoder;
impl SpanRerankEncoding for FixedEncoder {
    fn model_id(&self) -> &str { "minilm-l6-v2-w60" }
    fn encode_query(&self, _text: &str) -> Result<Vec<f32>, SpanRerankError> { Ok(vec![1.0, 0.0, 0.0, 0.0]) }
}

struct ThrowingEncoder;
impl SpanRerankEncoding for ThrowingEncoder {
    fn model_id(&self) -> &str { "minilm-l6-v2-w60" }
    fn encode_query(&self, _text: &str) -> Result<Vec<f32>, SpanRerankError> {
        Err(SpanRerankError("model unavailable".to_string()))
    }
}

/// Span rows for exactly one drawer: one span whose cosine against the fixed
/// query is 100 × 0.005 = 0.5. Every other drawer has no rows.
struct OneDrawerRows {
    item_id: String,
}
impl SpanVectorReading for OneDrawerRows {
    fn span_vectors(
        &self,
        item_ids: &[String],
        _model_id: &str,
    ) -> Result<HashMap<String, Vec<SpanRerankVector>>, SpanRerankError> {
        let mut out = HashMap::new();
        if item_ids.contains(&self.item_id) {
            out.insert(
                self.item_id.clone(),
                vec![SpanRerankVector { index: 2, int8: vec![100, 0, 0, 0], scale: 0.005, start_word: 60, end_word: 120 }],
            );
        }
        Ok(out)
    }
}

/// 200 drawers. Every fourth drawer carries the query terms (`ledger`,
/// `reconciled`, `clerk`) at differing document lengths so BM25 returns 50
/// candidates with distinct scores; the rest are lexical noise. A term that
/// appears in EVERY document has an IDF that quantises to a zero impact and
/// produces no BM25 hit at all, so the query terms must stay rare.
fn open_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).expect("open");
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic]).expect("corpus"),
    );
    for i in 0..200usize {
        let padding: Vec<String> = (0..(i % 9 + 1)).map(|p| format!("filler{}", p + i)).collect();
        let content = if i % 4 == 0 {
            format!("ledger note {i} {} reconciled by clerk {}", padding.join(" "), i % 13)
        } else {
            format!("invoice archive {i} {} filed by assistant {}", padding.join(" "), i % 11)
        };
        let frame = CaptureFrame::new(
            &content, CaptureChannel::Typed, "span-stage-tests", LatticeAnchor::udc("0"), "test-agent", "test-embed-v1",
        );
        let drawer = coord.capture(&h, frame, NOW + i as i64).expect("capture");
        corpus.ingest(&content, &drawer.id, NOW).expect("ingest");
    }
    coord.register_corpus(&h, corpus);
    (coord, h)
}

fn request(shape: Option<RecallShape>) -> GLKRecallRequest {
    let mut req = GLKRecallRequest::new(
        RecallFrame::new(vec![]),
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        20,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    )
    .with_query_text("ledger reconciled clerk");
    if let Some(s) = shape {
        req = req.with_recall_shape(s);
    }
    req
}

fn ids(r: &GLKRecallResult) -> Vec<String> {
    r.hits.iter().map(|h| h.id.clone()).collect()
}

#[test]
fn no_encoder_is_the_unreranked_order_and_balanced_runs_the_stage() {
    let (mut coord, h) = open_estate();

    // The lexical order the stage would rerank: the tenth hit of the unreranked
    // result is the drawer the fake encoder lifts.
    let before = coord.recall_scored(&h, request(RecallShape::preset("no_encoder")), NOW + 1000).expect("before");
    assert!(before.hits.len() >= 20, "got {}", before.hits.len());
    // The sixth hit is a lexical candidate inside the encoder head (rank <= 30
    // in the BM25 lane), so the stage has it to rerank.
    let sixth = &before.hits[5];
    let target = sixth.id.clone();
    assert!(sixth.sources.contains(&genius_locus_kit::recall::RecallEvidencePath::CorpusBm25), "sources {:?}", sixth.sources);
    let bm25_rank = before.lane_ranks.get(&target).and_then(|m| m.get("bm25")).copied().expect("bm25 rank");
    assert!(bm25_rank > 1 && bm25_rank <= 30, "bm25 rank {bm25_rank}");
    assert!(before.hits.iter().all(|hit| hit.span_hit.is_none()));
    // (c) with no encoder registered, no_encoder, no_vector and the None shape
    // are one order: the vector column is out by default.
    let no_vector_before = coord.recall_scored(&h, request(RecallShape::preset("no_vector")), NOW + 1000).expect("nv before");
    let default_before = coord.recall_scored(&h, request(None), NOW + 1000).expect("default before");
    assert_eq!(ids(&no_vector_before), ids(&before));
    assert_eq!(ids(&default_before), ids(&before));

    coord.register_span_rerank(&h, Arc::new(FixedEncoder), Arc::new(OneDrawerRows { item_id: target.clone() }), 30);

    let balanced = coord.recall_scored(&h, request(None), NOW + 1001).expect("balanced");
    let no_encoder = coord.recall_scored(&h, request(RecallShape::preset("no_encoder")), NOW + 1002).expect("no_encoder");
    let no_vector = coord.recall_scored(&h, request(RecallShape::preset("no_vector")), NOW + 1003).expect("no_vector");

    // (a) the ablation skips the stage: identical to the order before the
    // encoder existed (today's no_vector order).
    assert_eq!(ids(&no_encoder), ids(&before));
    assert!(no_encoder.hits.iter().all(|hit| hit.span_hit.is_none()));
    assert!(!no_encoder.degraded_stages.iter().any(|s| s == "spanRerank"));
    // no_vector only names the default budget; with an encoder it runs the
    // stage like balanced does.
    assert_eq!(ids(&no_vector), ids(&balanced));

    // (b) balanced ran the stage: the only span-bearing drawer leads, with its
    // bounds on the hit and the token on the explain line.
    assert_eq!(balanced.hits[0].id, target);
    assert_eq!(
        balanced.hits[0].span_hit,
        Some(SpanRerankHit { item_id: target.clone(), best_span_index: 2, best_span_start: 60, best_span_end: 120, cosine: 0.5 })
    );
    let score_line = balanced.hits[0]
        .explanation
        .iter()
        .find(|l| l.starts_with("score: "))
        .expect("score line");
    assert!(score_line.ends_with(" span:2:0.500"), "got {score_line}");
    assert!(balanced.hits[1..].iter().all(|hit| hit.span_hit.is_none()));
    assert_ne!(ids(&balanced), ids(&no_encoder));
}

#[test]
fn encoder_failure_leaves_the_lexical_order_standing_and_names_the_stage() {
    let (mut coord, h) = open_estate();
    let before = coord.recall_scored(&h, request(None), NOW + 2000).expect("before");
    coord.register_span_rerank(&h, Arc::new(ThrowingEncoder), Arc::new(OneDrawerRows { item_id: "none".to_string() }), 30);
    let after = coord.recall_scored(&h, request(None), NOW + 2001).expect("after");
    assert_eq!(ids(&after), ids(&before));
    assert!(after.degraded_stages.iter().any(|s| s == "spanRerank"), "got {:?}", after.degraded_stages);
}
