// recall_union_profile_seed_parity.rs
//
// Rust pins for the `RecallUnionProfile` a UnionBest + MatrixAware recall
// returns. Parity peer of Swift RecallUnionProfileSeedTests.
//
// Swift recallUnionBest step 7 computes the profile from the step 6
// normalised buffer, and the profile's redundancy and matrixCoherence read
// the top 16 candidates by `buffer.final`, the max over the per-lane hit
// finals (locus ramp, graph 0.5, BM25 score, Hamming similarity, dense cosine
// plus consensus boost). On a buffer of more than 16 candidates whose top 16
// by `final` differs from its top 16 by locus, the profile differs from one
// seeded with the locus column alone. The Rust matrixAware branch must seed
// its `final` column the same way.
//
// Tests:
//  1. matrix_aware_profile_on_text_free_estate: three drawers, no query text:
//     the locus-only profile (sharpness of the 1.0 / 0.5 / 0.0 column,
//     agreement 1.0, redundancy 1.0, coherence 0). A control: with the locus
//     lane alone `final` equals the locus column in both ports.
//  2. matrix_aware_profile_reads_the_lane_max_final_on_text_estate: twenty
//     drawers with a corpus; sixteen carry the query word and a few filler
//     words, four carry no query word and a long body. The newest drawer is a
//     query drawer, the next four newest are the quiet drawers, so the top 16
//     by locus holds every quiet drawer while the top 16 by `final` (the dense
//     cosine, 0.99 or 1.00 for every query drawer, above every quiet ramp)
//     holds the sixteen query drawers only. Every query drawer carries the
//     same three source bits, so the redundancy over that top 16 is exactly
//     1.0; a locus-seeded `final` keeps the four quiet drawers (two bits) in
//     the top 16 and reports 0.8667 (six plus sixty-six full pairs plus
//     forty-eight cross pairs at two thirds, over one hundred twenty).

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use engram_lib::Engram;
use synapsekit::{EmbeddingProvider, SynapseKitError};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
    RecallUnionProfile,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_100;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one(suffix: &str) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(&format!("owner-profile-seed-{suffix}")), 0, 100)
        .expect("open estate");
    (coord, handle)
}

fn capture_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "profile-seed-room",
        LatticeAnchor::udc("000"),
        "profile-seed-tests",
        "test-model-v1",
    )
}

/// Recall frame matching all currently-believed rows.
fn active_frame() -> RecallFrame {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Structured;
    frame
}

/// UnionBest + MatrixAware request, limit 5, optional query text.
fn matrix_aware_request(query: Option<&str>) -> GLKRecallRequest {
    let req = GLKRecallRequest::new(
        active_frame(),
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        5,
        RecallFallbackPolicy::AllowDegraded,
        RecallOrigin::Internal,
    );
    match query {
        Some(q) => req.with_query_text(q),
        None => req,
    }
}

/// One-hot-ish direction keyed on word count so the dense lane orders the
/// drawers without ties. Word count is a close proxy for token count for
/// the simple test sentences used here. Replaces the removed
/// `EmbeddingModelConfig::MiniLM { inference: }` case.
struct MonotonicProvider;

impl EmbeddingProvider for MonotonicProvider {
    fn model_id(&self) -> &str {
        "test-monotonic-v1"
    }
    fn model_version(&self) -> &str {
        "1.0.0"
    }
    fn embed(&self, _text: &str) -> Result<Engram, SynapseKitError> {
        Ok(Engram::ZERO)
    }
    fn embed_float(&self, text: &str) -> Result<Vec<f32>, SynapseKitError> {
        let word_count = text.split_whitespace().count();
        let theta = word_count as f32 * 0.018;
        let mut v = vec![0.0_f32; 384];
        v[0] = theta.cos();
        v[1] = theta.sin();
        Ok(v)
    }
}

fn minilm_monotonic_config() -> EmbeddingModelConfig {
    EmbeddingModelConfig::CandleNL { provider: Box::new(MonotonicProvider) }
}

/// The twenty drawer bodies, oldest first. Twin of the Swift `textEstateContents`.
fn text_estate_contents() -> Vec<String> {
    let mut bodies = Vec::with_capacity(20);
    for i in 0..15 {
        let filler = vec!["word"; i % 3 + 1].join(" ");
        bodies.push(format!("doc{i:02} queryword {filler}"));
    }
    let long_filler = vec!["filler"; 80].join(" ");
    for j in 15..19 {
        bodies.push(format!("quiet{j} {long_filler}"));
    }
    bodies.push("zdoc19 queryword word".to_string());
    bodies
}

/// Twenty drawers with a corpus and no vector store, captured oldest first in
/// this order: query drawers doc00 to doc14, quiet drawers quiet15 to quiet18,
/// then the newest query drawer zdoc19. A query drawer is its name,
/// "queryword" and one to three filler words, so its dense cosine to the
/// one-word query quantises to 0.99 or 1.00. A quiet drawer is its name and
/// eighty filler words, so it is absent from the BM25 lane and its dense
/// cosine is far from the query. The locus ramp at frontier_k 64 is 1.0 for
/// zdoc19, then 0.984375, 0.96875, 0.953125 and 0.9375 for the quiet drawers,
/// so the top 16 by locus holds all four quiet drawers while the top 16 by
/// `final` holds the sixteen query drawers and none of them.
fn text_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle, String) {
    let (mut coord, h) = open_one("text");
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![minilm_monotonic_config()])
            .expect("engine open"),
    );
    for (i, content) in text_estate_contents().iter().enumerate() {
        let drawer = coord
            .capture(&h, capture_frame(content), NOW + i as i64)
            .expect("capture");
        corpus.ingest(content, &drawer.id, NOW + i as i64).expect("ingest");
    }
    coord.register_corpus(&h, corpus);
    (coord, h, "queryword".to_string())
}

fn describe(p: &RecallUnionProfile) -> String {
    format!(
        "locus={} bm25={} vector={} agreement={} redundancy={} coherence={}",
        p.locus_sharpness, p.bm25_sharpness, p.vector_sharpness, p.signal_agreement, p.redundancy, p.matrix_coherence
    )
}

// ---------------------------------------------------------------------------
// 1. Text-free control
// ---------------------------------------------------------------------------

/// Twin of Swift `matrixAwareProfileOnTextFreeEstate`.
#[test]
fn matrix_aware_profile_on_text_free_estate() {
    let (coord, h) = open_one("text-free");
    coord.capture(&h, capture_frame("seed-1-oldest"), NOW).expect("capture oldest");
    coord.capture(&h, capture_frame("seed-2-middle"), NOW + 1).expect("capture middle");
    coord.capture(&h, capture_frame("seed-3-newest"), NOW + 2).expect("capture newest");

    let result = coord
        .recall_scored(&h, matrix_aware_request(None), NOW + 3)
        .expect("matrixAware recall");
    let profile = result.union_profile.expect("unionBest returns a profile");
    let d = describe(&profile);

    // Population standard deviation of the normalised locus column 1.0 / 0.5 / 0.0.
    let want_sharpness = ((2.0_f64 / 3.0).sqrt() * 0.5) as f32;
    assert!((profile.locus_sharpness - want_sharpness).abs() < 1e-5, "{d}");
    assert_eq!(profile.bm25_sharpness, 0.0, "{d}");
    assert_eq!(profile.vector_sharpness, 0.0, "{d}");
    assert!((profile.signal_agreement - 1.0).abs() < 1e-6, "one lane supplied every candidate: {d}");
    assert!((profile.redundancy - 1.0).abs() < 1e-6, "every candidate shares the one source mask: {d}");
    assert_eq!(profile.matrix_coherence, 0.0, "no matrix tier: {d}");
}

// ---------------------------------------------------------------------------
// 2. Text estate: the top 16 by final differs from the top 16 by locus
// ---------------------------------------------------------------------------

/// Twin of Swift `matrixAwareProfileReadsTheLaneMaxFinalOnTextEstate`.
#[test]
fn matrix_aware_profile_reads_the_lane_max_final_on_text_estate() {
    let (coord, h, query) = text_estate();

    let result = coord
        .recall_scored(&h, matrix_aware_request(Some(&query)), NOW + 100)
        .expect("matrixAware recall");
    let profile = result.union_profile.expect("unionBest returns a profile");
    let d = describe(&profile);

    assert!(!result.hits.is_empty(), "the recall returns hits");
    // Three supply lanes (locus, bm25, dense) with the whole-record lane;
    // sixteen candidates carry all three bits and four carry two:
    // (16 * 3 + 4 * 2) / (20 * 3). Without it, two lanes: (16 * 2 + 4) / (20 * 2).
    assert!((profile.signal_agreement - 56.0 / 60.0).abs() < 1e-5, "{d}");
    // The top 16 by `final` is the sixteen query drawers, one source mask.
    assert!((profile.redundancy - 1.0).abs() < 1e-6, "{d}");
    // Locus column: twenty ramp values, normalised to i / 19; population
    // standard deviation of that column.
    let want_locus_sharpness = ((20.0_f64 * 20.0 - 1.0) / 12.0).sqrt() as f32 / 19.0;
    assert!((profile.locus_sharpness - want_locus_sharpness).abs() < 1e-5, "{d}");
    // BM25 column: sixteen scores and four zeros, normalised; the value the
    // Swift build produced, pinned in both ports.
    assert!((profile.bm25_sharpness - 0.38824).abs() < 2e-3, "{d}");
    assert_eq!(profile.vector_sharpness, 0.0, "no vector store: {d}");
    assert_eq!(profile.matrix_coherence, 0.0, "no matrix tier: {d}");
}
