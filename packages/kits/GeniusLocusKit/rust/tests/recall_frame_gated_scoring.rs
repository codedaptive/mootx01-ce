// recall_frame_gated_scoring.rs
//
// Rust regression tests for RD-01: frame-filtering must gate scoring/tiebreak
// content, not just the final hit set.
//
// Mirrors the Swift RecallFrameGatedScoringTests. The Rust coordinator path
// (recall_scored_multi_lane) contains the same oracle: before the fix,
// `locus_content_by_id` was populated by an unframed get_drawers call, so
// restricted/secret drawers' content entered the BM25/vector content-sort
// tiebreak. After the fix, the population call uses get_drawers_matching_frame,
// so frame-excluded content never enters the tiebreak map.
//
// Test A (drop): restricted drawer absent from default-frame recall.
// Test B (multi-drop): multiple restricted drawers all absent; admissible all present.
// Test C (content-oracle invariance): two estates with identical admissible content
//         but different restricted decoy content must produce identical recall results.
// Test D (frame override): explicit SensitivityAtMost(.Restricted) surfaces the
//         restricted drawer, proving the exclusion is frame-driven (RD-01 §F2).

use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{GLKRecallMode, GLKRecallRequest, GLKRecallScoring};
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::CaptureFrame;
use locus_kit::drawer_operational::CaptureChannel;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_001;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one(owner_suffix: &str) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(&format!("owner-{owner_suffix}")), 0, 100)
        .expect("open");
    (coord, handle)
}

/// Normal-sensitivity capture frame (default: .Normal).
fn admissible_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "frame-gated-scoring",
        LatticeAnchor::udc("000"),
        "rd-01-tests",
        "test-model-v1",
    )
}

/// Restricted-sensitivity capture frame. The default recall frame applies
/// SensitivityAtMost(Elevated), so this drawer is excluded from all recall
/// results unless the caller explicitly widens the ceiling.
fn restricted_frame(content: &str) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "frame-gated-scoring",
        LatticeAnchor::udc("001"),
        "rd-01-tests",
        "test-model-v1",
    );
    f.sensitivity = AdjectiveSensitivity::Restricted;
    f
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    let config =
        EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("corpus open"),
    )
}

/// Default-frame corpusOnly request (BitmapEvaluator injects SensitivityAtMost(Elevated)).
/// Uses Full hydration to exercise the content-sort tiebreak path (RD-01 §F2).
fn default_request(query: &str, limit: usize) -> GLKRecallRequest {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    GLKRecallRequest::new(frame)
        .with_mode(GLKRecallMode::CorpusOnly)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text(query)
        .with_limit(limit)
}

/// Override-frame request that explicitly includes .Restricted sensitivity.
fn restricted_override_request(query: &str) -> GLKRecallRequest {
    let frame = RecallFrame::new(vec![Filter::Unconfirmed, Filter::SensitivityAtMost(AdjectiveSensitivity::Restricted)]);
    GLKRecallRequest::new(frame)
        .with_mode(GLKRecallMode::CorpusOnly)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text(query)
        .with_limit(50)
}

// ---------------------------------------------------------------------------
// A. Restricted drawer absent from default recall
// ---------------------------------------------------------------------------

#[test]
fn a_restricted_drawer_absent_from_default_recall() {
    let (mut coord, h) = open_one("a");
    let corpus = make_corpus();

    let admissible = coord
        .capture(&h, admissible_frame("oracle probe canary admissible content"), NOW)
        .expect("capture admissible");
    corpus.ingest(&admissible.content, &admissible.id, NOW).expect("ingest admissible");

    let restricted = coord
        .capture(&h, restricted_frame("oracle probe canary restricted content"), NOW + 1)
        .expect("capture restricted");
    corpus.ingest(&restricted.content, &restricted.id, NOW + 1).expect("ingest restricted");

    coord.register_corpus(&h, corpus);

    let result = coord
        .recall_scored(&h, default_request("oracle probe canary", 50), NOW + 2)
        .expect("recall");

    assert!(
        !result.hits.iter().any(|hh| hh.id == restricted.id),
        "restricted drawer MUST be absent from default-frame recall; got hits: {:?}",
        result.hits.iter().map(|hh| &hh.id).collect::<Vec<_>>()
    );
    assert!(
        result.hits.iter().any(|hh| hh.id == admissible.id),
        "admissible drawer MUST surface in recall; hits: {:?}",
        result.hits.iter().map(|hh| &hh.id).collect::<Vec<_>>()
    );
}

// ---------------------------------------------------------------------------
// B. Multiple restricted drawers — none surfaces, all admissible drawers present
// ---------------------------------------------------------------------------

#[test]
fn b_multiple_restricted_drawers_never_surface() {
    let (mut coord, h) = open_one("b");
    let corpus = make_corpus();

    let admissible_contents = [
        "oracle probe canary alpha",
        "oracle probe canary beta",
        "oracle probe canary gamma",
    ];
    let mut admissible_ids: Vec<String> = Vec::new();
    for (i, c) in admissible_contents.iter().enumerate() {
        let d = coord
            .capture(&h, admissible_frame(c), NOW + i as i64)
            .expect("capture admissible");
        corpus.ingest(&d.content, &d.id, NOW + i as i64).expect("ingest");
        admissible_ids.push(d.id.clone());
    }

    let restricted_contents = [
        "oracle probe canary rho",
        "oracle probe canary sigma",
        "oracle probe canary tau",
    ];
    let mut restricted_ids: Vec<String> = Vec::new();
    for (i, c) in restricted_contents.iter().enumerate() {
        let d = coord
            .capture(&h, restricted_frame(c), NOW + 10 + i as i64)
            .expect("capture restricted");
        corpus.ingest(&d.content, &d.id, NOW + 10 + i as i64).expect("ingest");
        restricted_ids.push(d.id.clone());
    }

    coord.register_corpus(&h, corpus);

    let result = coord
        .recall_scored(&h, default_request("oracle probe canary", 50), NOW + 20)
        .expect("recall");

    let leaked: Vec<_> = result.hits.iter().filter(|hh| restricted_ids.contains(&hh.id)).collect();
    assert!(
        leaked.is_empty(),
        "no restricted drawer must appear in recall results; leaked ids: {:?}",
        leaked.iter().map(|hh| &hh.id).collect::<Vec<_>>()
    );

    for id in &admissible_ids {
        assert!(
            result.hits.iter().any(|hh| &hh.id == id),
            "admissible drawer {id} must surface in recall"
        );
    }
}

// ---------------------------------------------------------------------------
// C. Content-oracle invariance: restricted decoy content must not influence
//    admissible ordering or count (RD-01 §F2 — Rust content-sort tiebreak).
//
// Two separate estates with identical admissible drawers but different restricted
// decoy content. Both decoys match the query so they appear in BM25 results. A
// large limit (10 >> 4 total candidates) prevents the pre-truncation slot-stealing
// pre-existing oracle, so this test purely isolates the content-sort tiebreak path:
// if the decoy's content were admitted to locus_content_by_id (the bug), its
// tiebreak key could change the pre-fusion BM25 ranks of admissible items, altering
// which admissible content appears in which position. After the fix, only
// frame-admissible content enters locus_content_by_id, so decoy content cannot
// influence admissible ranking or count.
// ---------------------------------------------------------------------------

#[test]
fn c_restricted_decoy_content_does_not_influence_admissible_ordering() {
    let shared_contents = [
        "oracle canary alpha fact",
        "oracle canary beta fact",
        "oracle canary gamma fact",
    ];

    // --- Estate A: restricted decoy with content IDENTICAL to the first
    // admissible drawer ("oracle canary alpha fact"). In the BUGGY code, this
    // decoy's content enters locus_content_by_id via the unframed get_drawers
    // call, giving da and the decoy the same tiebreak key. The stable sort then
    // orders them by original BM25 return position (determined by ID comparison)
    // rather than by content, potentially flipping their relative ranks compared
    // to the fixed path. ---
    let (mut coord_a, h_a) = open_one("oracle-c-a");
    let corpus_a = make_corpus();

    for (i, c) in shared_contents.iter().enumerate() {
        let d = coord_a.capture(&h_a, admissible_frame(c), NOW + i as i64).expect("capture");
        corpus_a.ingest(&d.content, &d.id, NOW + i as i64).expect("ingest");
    }
    // Decoy A: identical to the first admissible drawer — maximum tiebreak collision.
    let decoy_a = coord_a
        .capture(&h_a, restricted_frame("oracle canary alpha fact"), NOW + 10)
        .expect("capture decoy a");
    corpus_a.ingest(&decoy_a.content, &decoy_a.id, NOW + 10).expect("ingest decoy a");
    coord_a.register_corpus(&h_a, corpus_a);

    // Use limit=10 >> 4 total candidates so pre-truncation slot-stealing cannot
    // fire. Any ordering difference between estates is purely from tiebreak changes.
    let result_a = coord_a
        .recall_scored(&h_a, default_request("oracle canary", 10), NOW + 20)
        .expect("recall a");
    let contents_a: Vec<String> = result_a.hits.iter()
        .filter_map(|hh| hh.drawer.as_ref().map(|d| d.content.clone()))
        .collect();

    // --- Estate B: restricted decoy with different content ("oracle canary
    // zeta fact") — still matches the query so it appears in BM25 results, but
    // its content key differs from estate A, yielding a different tiebreak
    // position if the bug were present. ---
    let (mut coord_b, h_b) = open_one("oracle-c-b");
    let corpus_b = make_corpus();

    for (i, c) in shared_contents.iter().enumerate() {
        let d = coord_b.capture(&h_b, admissible_frame(c), NOW + i as i64).expect("capture");
        corpus_b.ingest(&d.content, &d.id, NOW + i as i64).expect("ingest");
    }
    // Decoy B: different content — same query match, different tiebreak key.
    let decoy_b = coord_b
        .capture(&h_b, restricted_frame("oracle canary zeta fact"), NOW + 10)
        .expect("capture decoy b");
    corpus_b.ingest(&decoy_b.content, &decoy_b.id, NOW + 10).expect("ingest decoy b");
    coord_b.register_corpus(&h_b, corpus_b);

    let result_b = coord_b
        .recall_scored(&h_b, default_request("oracle canary", 10), NOW + 20)
        .expect("recall b");
    let contents_b: Vec<String> = result_b.hits.iter()
        .filter_map(|hh| hh.drawer.as_ref().map(|d| d.content.clone()))
        .collect();

    // Same count: both estates must return all 3 admissible drawers. The decoy
    // is restricted and must not appear in either result.
    assert_eq!(
        contents_a.len(), contents_b.len(),
        "count must be invariant to restricted decoy content; A={}, B={}",
        contents_a.len(), contents_b.len()
    );
    assert_eq!(
        contents_a.len(), 3,
        "all 3 admissible drawers must be present; got: {:?}",
        contents_a
    );

    // Same content in same order: changing the restricted decoy's content must
    // not alter which admissible drawers are returned or their ordering.
    assert_eq!(
        contents_a, contents_b,
        "admissible hit order must be invariant to restricted decoy content; A={:?}, B={:?}",
        contents_a, contents_b
    );
}

// ---------------------------------------------------------------------------
// D. Frame override proves sensitivity ceiling is frame-driven, not hardcoded
// ---------------------------------------------------------------------------

#[test]
fn d_sensitivity_frame_override_surfaces_restricted_drawer() {
    let (mut coord, h) = open_one("d");
    let corpus = make_corpus();

    let restricted = coord
        .capture(&h, restricted_frame("oracle probe canary restricted override"), NOW)
        .expect("capture restricted");
    corpus.ingest(&restricted.content, &restricted.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    // Default frame excludes restricted.
    let default_result = coord
        .recall_scored(&h, default_request("oracle probe canary", 50), NOW + 1)
        .expect("default recall");
    assert!(
        !default_result.hits.iter().any(|hh| hh.id == restricted.id),
        "restricted drawer must be absent under default frame"
    );

    // Override: explicitly include up to .Restricted sensitivity.
    let override_result = coord
        .recall_scored(&h, restricted_override_request("oracle probe canary"), NOW + 2)
        .expect("override recall");
    assert!(
        override_result.hits.iter().any(|hh| hh.id == restricted.id),
        "restricted drawer MUST surface when frame ceiling includes Restricted (proves frame-driven, not hardcoded); hits: {:?}",
        override_result.hits.iter().map(|hh| &hh.id).collect::<Vec<_>>()
    );
}
