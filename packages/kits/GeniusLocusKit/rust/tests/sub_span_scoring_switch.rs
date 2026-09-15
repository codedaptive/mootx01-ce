// sub_span_scoring_switch.rs
//
// The unionBest step 5.8 sub-span refinement runs only when the request
// says so: `GLKRecallRequest.sub_span_scoring` is `Off` unless the caller
// turns it on. Rust twin of Tests/GeniusLocusKitTests/SubSpanScoringSwitchTests.swift;
// both read Tests/Conformance/sub_span_scoring_switch_fixture.json.
//
// Tests:
//   1. off_leaves_the_dense_column_untouched — fixture bodies, switch off:
//      the control body (never ingested) reports dense 0, no hit carries the
//      `subSpan:budget` token and there is no `subSpan.budget` stage.
//   2. on_applies_the_blend — fixture bodies, switch on: every ingested
//      body's hit reports dense above 0, the control body (captured, not in
//      the corpus) stays at 0.
//   3. off_never_reaches_the_engine — 20 ingested records of 16,000 scalars
//      (the pool union_best_budget_stages.rs uses to exhaust the 1,024-window
//      budget), switch off: no `subSpan.budget` stage and no `subSpan:budget`
//      token, which the engine would have recorded had it been called.

use std::path::PathBuf;
use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, GLKSubSpanScoring,
    RecallFallbackPolicy, RecallOrigin,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use serde::Deserialize;

const NOW: i64 = 1_700_000_000;

#[derive(Deserialize)]
struct Fixture {
    query: String,
    limit: usize,
    ingested_bodies: Vec<String>,
    control_body: String,
}

fn load_fixture() -> Fixture {
    // CARGO_MANIFEST_DIR is GeniusLocusKit/rust/; the fixture is shared with
    // the Swift twin under Tests/Conformance/.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Conformance/sub_span_scoring_switch_fixture.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str::<Fixture>(&raw).expect("fixture JSON must parse")
}

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// The Swift twin's `longBody`: a body of about `scalars` scalars that opens
/// with the query terms and continues with sixteen-word filler, so the
/// sub-span budget sees a long record while the BM25 posting lists stay small.
fn long_body(query: &str, index: usize, scalars: usize) -> String {
    const FILLER: [&str; 16] = [
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
        "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    ];
    let mut body = format!("{query} item {index}");
    let mut word = 0usize;
    while body.chars().count() < scalars {
        body.push(' ');
        body.push_str(FILLER[word % FILLER.len()]);
        word += 1;
    }
    body
}

/// An estate with every body captured and the first `ingested` of them also
/// in a standalone corpus registered on the estate. The deterministic model
/// gives the corpus a hashed float lane, so sub-span windows can be scored
/// without a real encoder. No vector store is registered; the whole-record
/// float lane over the corpus fills the dense column for ingested bodies, and
/// a body outside the corpus stays at 0.
fn open_estate(
    bodies: &[String],
    ingested: usize,
) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord
        .open(store, OwnerCredentials::new("sub-span-switch"), 0, 100)
        .expect("open estate");
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
            .expect("CorpusContentEngine::standalone_on"),
    );
    for (i, text) in bodies.iter().enumerate() {
        let frame = CaptureFrame::new(
            text, CaptureChannel::Typed, "sub-span-switch", LatticeAnchor::udc("000"),
            "sub-span-switch", "test-model-v1");
        let ts = NOW + i as i64;
        let drawer = coord.capture(&h, frame, ts).expect("capture");
        if i < ingested {
            corpus.ingest(text, &drawer.id, ts).expect("corpus ingest");
        }
    }
    coord.register_corpus(&h, corpus);
    (coord, h)
}

fn request(query: &str, limit: usize, sub_span_scoring: GLKSubSpanScoring) -> GLKRecallRequest {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    GLKRecallRequest::new(
        frame, GLKRecallMode::UnionBest, GLKRecallScoring::MatrixAware, limit,
        RecallFallbackPolicy::FailClosed, RecallOrigin::Internal,
    )
    .with_query_text(query)
    .with_sub_span_scoring(sub_span_scoring)
}

fn content(hit: &genius_locus_kit::recall::RecallHit) -> String {
    hit.drawer.as_ref().map(|d| d.content.clone()).unwrap_or_default()
}

#[test]
fn off_leaves_the_dense_column_untouched() {
    let fixture = load_fixture();
    let mut bodies = fixture.ingested_bodies.clone();
    bodies.push(fixture.control_body.clone());
    let (coord, h) = open_estate(&bodies, fixture.ingested_bodies.len());
    let result = coord
        .recall_scored(&h, request(&fixture.query, fixture.limit, GLKSubSpanScoring::Off), NOW + 1_000)
        .expect("recall_scored");
    assert_eq!(result.hits.len(), bodies.len(), "the locus lane supplies every body at limit {}", fixture.limit);
    for hit in result.hits.iter().filter(|hit| content(hit) == fixture.control_body) {
        assert_eq!(hit.score.dense, 0.0,
            "switch off: the control body has no corpus record and no blend runs, dense stays 0; got {}", hit.score.dense);
    }
    let flagged = result.hits.iter().filter(|hit| {
        hit.explanation.iter().any(|line| line.starts_with("score:") && line.contains(" subSpan:budget"))
    }).count();
    assert_eq!(flagged, 0, "switch off: no hit carries the sub-span budget token");
    assert!(!result.degraded_stages.iter().any(|s| s == "subSpan.budget"),
        "the engine was not called, so no budget stage; stages: {:?}", result.degraded_stages);
}

#[test]
fn on_applies_the_blend() {
    let fixture = load_fixture();
    let mut bodies = fixture.ingested_bodies.clone();
    bodies.push(fixture.control_body.clone());
    let (coord, h) = open_estate(&bodies, fixture.ingested_bodies.len());
    let result = coord
        .recall_scored(&h, request(&fixture.query, fixture.limit, GLKSubSpanScoring::On), NOW + 1_000)
        .expect("recall_scored");
    assert_eq!(result.hits.len(), bodies.len(), "the locus lane supplies every body at limit {}", fixture.limit);
    for hit in &result.hits {
        let body = content(hit);
        if fixture.ingested_bodies.contains(&body) {
            assert!(hit.score.dense > 0.0,
                "switch on: the sub-span max-cosine raised the dense column; got 0 for {body}");
        } else {
            assert_eq!(body, fixture.control_body, "unexpected hit {body}");
            assert_eq!(hit.score.dense, 0.0,
                "the control body has no corpus record, so the blend leaves it at 0; got {}", hit.score.dense);
        }
    }
}

#[test]
fn off_never_reaches_the_engine() {
    let fixture = load_fixture();
    let count = 20usize;
    let bodies: Vec<String> = (0..count).map(|i| long_body(&fixture.query, i, 16_000)).collect();
    let (coord, h) = open_estate(&bodies, count);
    let result = coord
        .recall_scored(&h, request(&fixture.query, count, GLKSubSpanScoring::Off), NOW + 1_000)
        .expect("recall_scored");
    assert!(!result.hits.is_empty());
    assert!(!result.degraded_stages.iter().any(|s| s == "subSpan.budget"),
        "switch off: 1,700-odd windows were never offered to the budget; stages: {:?}", result.degraded_stages);
    let flagged = result.hits.iter().filter(|hit| {
        hit.explanation.iter().any(|line| line.starts_with("score:") && line.contains(" subSpan:budget"))
    }).count();
    assert_eq!(flagged, 0, "no hit carries the budget token when the step does not run");
}
