// recall_union_best_raw_reporting_parity.rs
//
// Rust pins for the score columns a unionBest hit reports under `Raw` and
// `Rrf`. Parity peer of Swift RecallUnionBestRawReportingTests.
//
// Swift builds one candidate buffer, min-max normalises every column at step 6
// and, for `.raw` and `.rrf`, scores each candidate from the normalised
// `buffer.final` (the max over the per-lane finals). Step 11 reports the
// normalised columns and that score on every hit. The Rust rrf/raw branch must
// report the same values.
//
// Tests:
//  1. raw_and_rrf_report_normalised_locus_and_final_on_text_free_estate: three
//     drawers, no query text: locus 1.0 / 0.5 / 0.0 and final 1.0 / 0.5 / 0.0
//     (newest / middle / oldest) under both scorings, and the two result sets
//     are byte-identical. An un-normalised locus ramp reads 1.0 / 0.984 / 0.969
//     at frontier_k 64, and a reciprocal-rank final reads about 0.016.
//  2. raw_and_rrf_report_the_same_normalised_columns_on_text_query: six
//     drawers with a corpus and a vector store, a query that lights the BM25,
//     Hamming and dense lanes: `Raw` and `Rrf` return the same ids in the same
//     order with the same score vectors, every reported column is in [0, 1],
//     and the top final is exactly 1.0. A lane sum exceeds 1.0 and a
//     reciprocal-rank fusion differs from the sum.

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, RecallFallbackPolicy,
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one(suffix: &str) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(&format!("owner-raw-reporting-{suffix}")), 0, 100)
        .expect("open estate");
    (coord, handle)
}

fn capture_frame(content: &str, room: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("000"),
        "raw-reporting-tests",
        "test-model-v1",
    )
}

/// Recall frame matching all currently-believed rows.
fn active_frame() -> RecallFrame {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Structured;
    frame
}

/// UnionBest request under the given scoring, optional query text.
fn union_best_request(scoring: GLKRecallScoring, query: Option<&str>) -> GLKRecallRequest {
    let req = GLKRecallRequest::new(
        active_frame(),
        GLKRecallMode::UnionBest,
        scoring,
        20,
        RecallFallbackPolicy::AllowDegraded,
        RecallOrigin::Internal,
    );
    match query {
        Some(q) => req.with_query_text(q),
        None => req,
    }
}

/// One-hot-ish direction keyed on token count, the same inference the
/// anti-similar fixture uses, so the dense lane orders the drawers without ties.
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

/// Six drawers with a corpus and a vector store. Drawer i carries the shared
/// query word and i + 1 filler words, so BM25, Hamming and dense all rank the
/// drawers and the lanes disagree on the order.
fn text_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle, String) {
    let (mut coord, h) = open_one("text");
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![minilm_monotonic_config()])
            .expect("engine open"),
    );
    let vector_store = make_vector_store();
    for i in 0..TEXT_DRAWER_COUNT {
        let filler = vec!["word"; i + 1].join(" ");
        let content = format!("doc{i} queryword {filler}");
        let drawer = coord
            .capture(&h, capture_frame(&content, "raw-reporting-room"), NOW + i as i64)
            .expect("capture");
        corpus.ingest(&content, &drawer.id, NOW).expect("ingest");
        let engram = corpus.embed(&content).expect("embed");
        vector_store
            .add_vector(&drawer.id, &engram, &corpus.model_id(), "1", NOW)
            .expect("add_vector");
    }
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h, "queryword".to_string())
}

fn columns(result: &GLKRecallResult) -> Vec<(String, [f32; 5])> {
    result
        .hits
        .iter()
        .map(|h| {
            (
                h.id.clone(),
                [h.score.locus, h.score.bm25, h.score.vector, h.score.dense, h.score.final_score],
            )
        })
        .collect()
}

// ---------------------------------------------------------------------------
// 1. Text-free three-drawer estate: locus and final read 1.0 / 0.5 / 0.0
// ---------------------------------------------------------------------------

/// Twin of Swift `rawAndRrfReportNormalisedLocusAndFinalOnTextFreeEstate`.
#[test]
fn raw_and_rrf_report_normalised_locus_and_final_on_text_free_estate() {
    let (coord, h) = open_one("text-free");

    // Content strings sort the same way as capture time (content DESC is the
    // final tiebreak of the stable locus sort), so the slice order is fixed.
    let oldest = coord
        .capture(&h, capture_frame("report-1-oldest", "raw-reporting-room"), NOW)
        .expect("capture oldest");
    let middle = coord
        .capture(&h, capture_frame("report-2-middle", "raw-reporting-room"), NOW + 1)
        .expect("capture middle");
    let newest = coord
        .capture(&h, capture_frame("report-3-newest", "raw-reporting-room"), NOW + 2)
        .expect("capture newest");

    let raw = coord
        .recall_scored(&h, union_best_request(GLKRecallScoring::Raw, None), NOW + 3)
        .expect("raw recall");
    let rrf = coord
        .recall_scored(&h, union_best_request(GLKRecallScoring::Rrf, None), NOW + 3)
        .expect("rrf recall");

    for (label, result) in [("raw", &raw), ("rrf", &rrf)] {
        assert_eq!(result.hits.len(), 3, "{label}: all three drawers must surface");
        let hit = |id: &str| result.hits.iter().find(|h| h.id == id).expect("hit present");
        for (name, id, want) in [("newest", &newest.id, 1.0_f32), ("middle", &middle.id, 0.5), ("oldest", &oldest.id, 0.0)] {
            let locus = hit(id).score.locus;
            let final_score = hit(id).score.final_score;
            assert!((locus - want).abs() < 1e-4, "{label} {name}: locus got {locus}, want {want}");
            assert!((final_score - want).abs() < 1e-4, "{label} {name}: final got {final_score}, want {want}");
        }
    }
    assert_eq!(columns(&raw), columns(&rrf), "rrf on unionBest is the raw path: same hits, same columns");
    assert!(
        rrf.degraded_stages.iter().any(|s| s == "unionBest.rrf"),
        "rrf on unionBest records its fallback (got {:?})",
        rrf.degraded_stages
    );
}

// ---------------------------------------------------------------------------
// 2. Text query: raw equals rrf, every column normalised, top final 1.0
// ---------------------------------------------------------------------------

/// Twin of Swift `rawAndRrfReportTheSameNormalisedColumnsOnTextQuery`.
#[test]
fn raw_and_rrf_report_the_same_normalised_columns_on_text_query() {
    let (coord, h, query) = text_estate();

    let raw = coord
        .recall_scored(&h, union_best_request(GLKRecallScoring::Raw, Some(&query)), NOW + 10)
        .expect("raw recall");
    let rrf = coord
        .recall_scored(&h, union_best_request(GLKRecallScoring::Rrf, Some(&query)), NOW + 10)
        .expect("rrf recall");

    assert_eq!(raw.hits.len(), TEXT_DRAWER_COUNT, "every drawer matches the query");
    assert!(
        raw.hits.iter().any(|h| h.score.bm25 > 0.0),
        "the BM25 lane must contribute a column (got {:?})",
        columns(&raw)
    );
    assert_eq!(columns(&raw), columns(&rrf), "rrf on unionBest is the raw path: same ids, order and columns");

    let mut top_final = f32::MIN;
    for hit in &raw.hits {
        for (name, v) in [
            ("locus", hit.score.locus),
            ("bm25", hit.score.bm25),
            ("vector", hit.score.vector),
            ("dense", hit.score.dense),
            ("final", hit.score.final_score),
        ] {
            assert!((0.0..=1.0).contains(&v), "{}: {name} column {v} is outside [0, 1]", hit.id);
        }
        top_final = top_final.max(hit.score.final_score);
    }
    assert!((top_final - 1.0).abs() < 1e-6, "the normalised final column peaks at exactly 1.0 (got {top_final})");
}
