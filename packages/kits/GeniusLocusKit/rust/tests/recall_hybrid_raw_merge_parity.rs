// recall_hybrid_raw_merge_parity.rs
//
// Rust pins for the hit order and `final_score` a Hybrid or CorpusOnly recall
// reports under `Raw`. Parity peer of Swift RecallHybridRawMergeTests.
//
// Swift recallHybrid `.raw` performs no fusion: it merges the locus list, then
// the BM25 list, then the vector list, in that order, dedups by id and takes
// `prefix(limit)`. Each hit's `final` is the score of the list it entered from,
// so a hit the locus lane supplied carries the locus ramp `(frontier_k - rank)
// / frontier_k`. recallCorpusOnly `.raw` is the same merge over BM25 then
// vector. The Rust Raw arm must produce the same order and the same finals.
//
// Tests:
//  1. hybrid_raw_returns_the_locus_order_on_text_free_estate: three drawers,
//     no corpus: capture-time DESC order with final 1.0 / 0.984375 / 0.96875
//     at frontier_k 64. A control: the no-corpus locus-ranked fallback already
//     agrees.
//  2. hybrid_raw_returns_the_locus_order_and_ramp_on_text_estate: six drawers
//     with a corpus and a vector store, a query every drawer matches: the
//     Hybrid `Raw` order is the locus order (newest first) and every final is
//     the locus ramp. A lane sum reads above 1.0 and orders by BM25 strength.
//  3. corpus_only_raw_returns_the_bm25_order_on_text_estate: the same estate
//     under CorpusOnly `Raw`: finals are non-increasing and each equals the
//     hit's BM25 column. A lane sum adds the Hamming similarity to every final.

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath, RecallFallbackPolicy,
    RecallOrigin,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use synapsekit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_100;
const TEXT_DRAWER_COUNT: usize = 6;
/// `min(max(limit * 4, 64), 256)` for every limit at or below 16.
const FRONTIER_K: usize = 64;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one(suffix: &str) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(&format!("owner-raw-merge-{suffix}")), 0, 100)
        .expect("open estate");
    (coord, handle)
}

fn capture_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "raw-merge-room",
        LatticeAnchor::udc("000"),
        "raw-merge-tests",
        "test-model-v1",
    )
}

/// Recall frame matching all currently-believed rows.
fn active_frame() -> RecallFrame {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Structured;
    frame
}

/// Raw request under the given mode and limit, optional query text.
fn raw_request(mode: GLKRecallMode, limit: usize, query: Option<&str>) -> GLKRecallRequest {
    let req = GLKRecallRequest::new(
        active_frame(),
        mode,
        GLKRecallScoring::Raw,
        limit,
        RecallFallbackPolicy::AllowDegraded,
        RecallOrigin::Internal,
    );
    match query {
        Some(q) => req.with_query_text(q),
        None => req,
    }
}

/// The locus ramp for a zero-based rank at the default frontier.
fn ramp(rank: usize) -> f32 {
    (FRONTIER_K - rank) as f32 / FRONTIER_K as f32
}

/// One-hot-ish direction keyed on token count, the same inference the
/// raw-reporting fixture uses, so the dense lane orders the drawers without ties.
fn minilm_monotonic_config() -> EmbeddingModelConfig {
    EmbeddingModelConfig::MiniLM {
        inference: Box::new(|tokens: &[i32]| {
            let theta = tokens.len() as f32 * 0.018;
            let mut v = vec![0.0_f32; 384];
            v[0] = theta.cos();
            v[1] = theta.sin();
            Ok(v)
        }),
    }
}

fn make_vector_store() -> Arc<VectorStore> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
}

/// Six drawers with a corpus and a vector store, oldest first. Drawer i
/// carries the shared query word and i + 1 filler words, so BM25 ranks the
/// shorter (older) drawers first, the opposite of the locus order. Content
/// strings sort the same way as capture time, the Swift twin's tiebreak.
fn text_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle, Vec<String>, String) {
    let (mut coord, h) = open_one("text");
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![minilm_monotonic_config()])
            .expect("engine open"),
    );
    let vector_store = make_vector_store();
    let mut ids = Vec::with_capacity(TEXT_DRAWER_COUNT);
    for i in 0..TEXT_DRAWER_COUNT {
        let filler = vec!["word"; i + 1].join(" ");
        let content = format!("doc{i} queryword {filler}");
        let drawer = coord
            .capture(&h, capture_frame(&content), NOW + i as i64)
            .expect("capture");
        corpus.ingest(&content, &drawer.id, NOW).expect("ingest");
        let engram = corpus.embed(&content).expect("embed");
        vector_store
            .add_vector(&drawer.id, &engram, &corpus.model_id(), "1", NOW)
            .expect("add_vector");
        ids.push(drawer.id);
    }
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h, ids, "queryword".to_string())
}

// ---------------------------------------------------------------------------
// 1. Text-free control: the locus order and ramp
// ---------------------------------------------------------------------------

/// Twin of Swift `hybridRawReturnsTheLocusOrderOnTextFreeEstate`.
#[test]
fn hybrid_raw_returns_the_locus_order_on_text_free_estate() {
    let (coord, h) = open_one("text-free");
    let oldest = coord.capture(&h, capture_frame("merge-1-oldest"), NOW).expect("capture oldest");
    let middle = coord.capture(&h, capture_frame("merge-2-middle"), NOW + 1).expect("capture middle");
    let newest = coord.capture(&h, capture_frame("merge-3-newest"), NOW + 2).expect("capture newest");

    let result = coord
        .recall_scored(&h, raw_request(GLKRecallMode::Hybrid, 10, None), NOW + 3)
        .expect("hybrid raw recall");

    let got: Vec<&str> = result.hits.iter().map(|hit| hit.id.as_str()).collect();
    assert_eq!(
        got,
        vec![newest.id.as_str(), middle.id.as_str(), oldest.id.as_str()],
        "hybrid Raw is the locus order, newest first"
    );
    for (rank, hit) in result.hits.iter().enumerate() {
        assert!(
            (hit.score.final_score - ramp(rank)).abs() < 1e-6,
            "rank {rank}: final got {}, want {}",
            hit.score.final_score,
            ramp(rank)
        );
    }
}

// ---------------------------------------------------------------------------
// 2. Text estate: Hybrid Raw is the locus list first
// ---------------------------------------------------------------------------

/// Twin of Swift `hybridRawReturnsTheLocusOrderAndRampOnTextEstate`.
#[test]
fn hybrid_raw_returns_the_locus_order_and_ramp_on_text_estate() {
    let (coord, h, ids, query) = text_estate();

    let result = coord
        .recall_scored(&h, raw_request(GLKRecallMode::Hybrid, 10, Some(&query)), NOW + 10)
        .expect("hybrid raw recall");

    let want_order: Vec<&str> = ids.iter().rev().map(|id| id.as_str()).collect();
    let got: Vec<&str> = result.hits.iter().map(|hit| hit.id.as_str()).collect();
    assert_eq!(got, want_order, "hybrid Raw merges the locus list first, so the order is newest first");
    assert!(
        result.hits.iter().any(|hit| hit.sources.contains(&RecallEvidencePath::CorpusBm25)),
        "the BM25 lane must have run (sources {:?})",
        result.hits.iter().map(|hit| hit.sources.clone()).collect::<Vec<_>>()
    );
    for (rank, hit) in result.hits.iter().enumerate() {
        assert!(
            (hit.score.final_score - ramp(rank)).abs() < 1e-6,
            "rank {rank}: final is the locus ramp {}, got {}",
            ramp(rank),
            hit.score.final_score
        );
        assert!(hit.score.final_score <= 1.0, "a merged final never exceeds the lane score (got {})", hit.score.final_score);
    }

    // The limit truncates the merged list, never re-sorts it.
    let three = coord
        .recall_scored(&h, raw_request(GLKRecallMode::Hybrid, 3, Some(&query)), NOW + 11)
        .expect("hybrid raw recall, limit 3");
    let got_three: Vec<&str> = three.hits.iter().map(|hit| hit.id.as_str()).collect();
    assert_eq!(got_three, want_order[..3].to_vec(), "limit 3 keeps the three newest");
}

// ---------------------------------------------------------------------------
// 3. Text estate: CorpusOnly Raw is the BM25 list first
// ---------------------------------------------------------------------------

/// Twin of Swift `corpusOnlyRawReturnsTheBm25OrderOnTextEstate`.
#[test]
fn corpus_only_raw_returns_the_bm25_order_on_text_estate() {
    let (coord, h, ids, query) = text_estate();

    let result = coord
        .recall_scored(&h, raw_request(GLKRecallMode::CorpusOnly, 10, Some(&query)), NOW + 10)
        .expect("corpusOnly raw recall");

    assert_eq!(result.hits.len(), TEXT_DRAWER_COUNT, "every drawer matches the query");
    let mut got_ids: Vec<&str> = result.hits.iter().map(|hit| hit.id.as_str()).collect();
    got_ids.sort_unstable();
    let mut want_ids: Vec<&str> = ids.iter().map(|id| id.as_str()).collect();
    want_ids.sort_unstable();
    assert_eq!(got_ids, want_ids, "the same six drawers surface");
    let mut previous = f32::MAX;
    for hit in &result.hits {
        assert!(
            hit.sources.contains(&RecallEvidencePath::CorpusBm25),
            "{}: a BM25 hit (sources {:?})",
            hit.id,
            hit.sources
        );
        assert!(hit.score.final_score > 0.0, "{}: a BM25 score is positive (got {})", hit.id, hit.score.final_score);
        assert!(
            (hit.score.final_score - hit.score.bm25).abs() < 1e-6,
            "{}: final is the BM25 lane score {}, got {}",
            hit.id,
            hit.score.bm25,
            hit.score.final_score
        );
        assert!(hit.score.final_score <= previous, "{}: BM25 order is non-increasing", hit.id);
        previous = hit.score.final_score;
    }
    // BM25 prefers the shorter drawers, so the oldest drawer leads.
    assert_eq!(result.hits[0].id, ids[0], "the shortest drawer ranks first under BM25");
}
