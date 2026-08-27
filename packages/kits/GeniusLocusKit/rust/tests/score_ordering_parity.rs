// score_ordering_parity.rs
//
// Cross-port parity test for the Score-Transparent Ordering contract
// (DECISION_SCORE_TRANSPARENT_ORDERING_2026-08-24, ADR status: ACCEPTED).
//
// Reads ONE shared fixture at:
//   Tests/Conformance/score_ordering_fixture.json
//
// The Swift twin is:
//   Tests/GeniusLocusKitTests/ScoreOrderingTests.swift (test #5 — crossPortFixtureSubjectOrderMatches)
//
// Both ports assert that the expected_subject_order in the fixture matches the
// actual recall output order. The fixture pins two items where "high-relevance"
// has higher query-term frequency than "low-relevance"; BM25 must rank it first.
// This gate fails if score ordering is dropped or score fields are zeroed.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallOrigin,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};

const NOW: i64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Fixture types
// ---------------------------------------------------------------------------

#[derive(serde::Deserialize)]
struct FixtureItem {
    content: String,
    subject: String,
}

#[derive(serde::Deserialize)]
struct Fixture {
    query: String,
    items: Vec<FixtureItem>,
    expected_subject_order: Vec<String>,
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner-score-ordering-parity"), 0, 100)
        .expect("open estate");
    (coord, handle)
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic])
            .expect("CorpusContentEngine::standalone_on"),
    )
}

fn cap_frame_with_subject(content: &str, subject: &str) -> CaptureFrame {
    let mut f = CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "score-ordering-parity",
        LatticeAnchor::udc("0"),
        "score-ordering-parity-tests",
        "test-model-v1",
    );
    f.subject = Some(subject.to_string());
    f
}

fn load_fixture() -> Fixture {
    // CARGO_MANIFEST_DIR is the absolute path to the GeniusLocusKit/rust/ directory.
    // The fixture lives two levels up under Tests/Conformance/.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture_path = manifest_dir
        .join("../Tests/Conformance/score_ordering_fixture.json");
    let raw = std::fs::read_to_string(&fixture_path).unwrap_or_else(|e| {
        panic!(
            "cannot read score_ordering_fixture.json at {}: {}",
            fixture_path.display(),
            e
        )
    });
    serde_json::from_str::<Fixture>(&raw).expect("fixture JSON must parse")
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

/// Cross-port ordering fixture: reads Tests/Conformance/score_ordering_fixture.json
/// and verifies that the Rust coordinator returns hits in the expected subject order.
///
/// Both items are ingested into a BM25 corpus so the scoring path has real signal.
/// "high-relevance" repeats query terms more than "low-relevance"; BM25 must rank
/// it first, giving the expected order [high-relevance, low-relevance].
///
/// Mirrors Swift ScoreOrderingTests.crossPortFixtureSubjectOrderMatches.
#[test]
fn cross_port_fixture_subject_order_matches() {
    let fixture = load_fixture();

    let (mut coord, h) = open_estate();
    let corpus = make_corpus();

    // Capture each item and ingest it into the corpus using the drawer ID as
    // source_id — this is the same join key the recall path uses to map BM25
    // hits back to locus drawers.
    let mut drawer_ids: HashMap<String, String> = HashMap::new(); // subject → drawer_id
    for (idx, item) in fixture.items.iter().enumerate() {
        let frame = cap_frame_with_subject(&item.content, &item.subject);
        // Stagger capture timestamps so drawer store ordering is deterministic.
        let ts = NOW + idx as i64;
        let drawer = coord.capture(&h, frame, ts).expect("capture");
        corpus
            .ingest(&item.content, &drawer.id, ts)
            .expect("corpus ingest");
        drawer_ids.insert(item.subject.clone(), drawer.id.clone());
    }

    coord.register_corpus(&h, corpus);

    // Recall with the fixture query using unionBest+rrf — the same mode
    // used in the Swift twin, where BM25+vector scores are fused into a
    // final score that determines presentation order.
    let req = GLKRecallRequest::new(
        RecallFrame::new(vec![Filter::Unconfirmed]),
        GLKRecallMode::UnionBest,
        GLKRecallScoring::Rrf,
        20,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    )
    .with_query_text(&fixture.query);

    let result = coord
        .recall_scored(&h, req, NOW + 100)
        .expect("recall_scored");

    // Extract subjects in result order.
    let result_subjects: Vec<String> = result
        .hits
        .iter()
        .filter_map(|hit| {
            hit.drawer
                .as_ref()
                .and_then(|d| d.subject.clone())
        })
        .collect();

    // Every fixture item must appear in the results.
    for expected in &fixture.expected_subject_order {
        assert!(
            result_subjects.contains(expected),
            "expected subject '{}' missing from results; got {:?}",
            expected,
            result_subjects
        );
    }

    // The relative order of fixture items in the result must match the fixture.
    // Filter result_subjects to only those in the fixture, preserving result order.
    let filtered: Vec<String> = result_subjects
        .iter()
        .filter(|s| fixture.expected_subject_order.contains(s))
        .cloned()
        .collect();

    assert_eq!(
        filtered,
        fixture.expected_subject_order,
        "expected subject order {:?}, got {:?}",
        fixture.expected_subject_order,
        filtered
    );
}
