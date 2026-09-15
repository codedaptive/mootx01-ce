// union_best_mmr_parity.rs
//
// The Rust twin of Tests/GeniusLocusKitTests/UnionBestMMRShingleOnceTests.swift
// plus the shared cross-port fixture for the unionBest step 10 MMR stage
// (MMR-2). Both ports run the same greedy MMR after full hydration: λ from the
// adaptive weights, argmax of λ·score − (1−λ)·maxSim with the total-order
// tie-break, character-3-gram shingle Jaccard over sets built once per body,
// sourceMask Jaccard fallback, 2N working view and conditional 4N widening.
//
// Tests:
//   1. full_hydration_near_duplicate_order_is_pinned — the matrixAware order
//      over the nine Swift fixture bodies matches the order the Swift test pins
//      and is stable across two recalls.
//   2. set_overload_matches_string_overload_on_fixture_bodies — for every
//      fixture body pair the set overload step 10 uses equals the string
//      overload, and the near-duplicate cluster is far more similar than any
//      cross-cluster pair (otherwise the fixture could not move the order).
//   3. cross_port_fixture_content_order_matches — reads
//      Tests/Conformance/union_best_mmr_fixture.json (expected order produced
//      by the Swift build) and asserts it verbatim.

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
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use substrate_ml::shingle_similarity;
use synapsekit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_000;

/// Three near-duplicate bodies at the top of the relevance order (bodies 0 to
/// 2: the query itself plus one trailing word) and six diverse bodies that
/// carry the query terms in longer, different phrasing. The pool (9) is larger
/// than the 2N working view (4 at limit 2), so step 10 decides which
/// candidates enter the view. Byte-identical to the Swift fixture.
const BODIES: [&str; 9] = [
    "quarterly budget review meeting notes finance team",
    "quarterly budget review meeting notes finance team ok",
    "quarterly budget review meeting notes finance team yes",
    "finance team quarterly review: budget meeting notes and action items about vendor contracts",
    "meeting notes, finance team: quarterly budget review of travel policy and expense caps",
    "notes from the finance team budget review meeting each quarterly cycle for headcount plans",
    "quarterly finance team notes: budget review meeting covering software licences",
    "budget review meeting notes with the finance team about the quarterly forecast model",
    "team meeting notes quarterly budget review by finance on the new office lease",
];

const QUERY: &str = "quarterly budget review meeting notes finance team";

/// The order UnionBestMMRShingleOnceTests.swift pins for limit 2, `Full`,
/// MatrixAware under the default lane budget, which since the Encoder Rerank
/// Program leaves the whole-record vector column out of the fused score
/// (`RecallShape::default_weight`: `signal:vector` = 0). On this fixture that
/// budget scores every body by bm25 alone (the locus column is out of
/// text-query scoring since COL-1; the cold columns are absent), so bodies 1
/// and 2 (identical term frequencies and token length) tie exactly and their
/// bm25 lead over the diverse bodies exceeds the ρ-scaled shingle penalty for
/// the later view slots; the tie straddles the presentation cut, phase 2
/// widens to 4N, and ruling 1 returns the tie group whole: three hits for a
/// two-hit request. With the vector column in (`signal:vector` = 1.0) the
/// same recall returns [body 0, body 6]; the vector tie-break is gone, which
/// is the whole change. The pin still gates the shingle term through the
/// order inside the tie group: the MMR picks body 2 ("... yes", fewer shared
/// 3-grams with body 0) before body 1 ("... ok") and the stable presentation
/// sort keeps that order; a build with the similarity term zeroed returns
/// [body 0, body 1, body 2]. The admission gate proper is the cross-port
/// fixture below, where the near-duplicates stay out.
const PINNED_ORDER: [&str; 2] = [
    "quarterly budget review meeting notes finance team",
    "quarterly budget review meeting notes finance team yes",
];

#[derive(serde::Deserialize)]
struct Fixture {
    query: String,
    limit: usize,
    bodies: Vec<String>,
    expected_content_order: Vec<String>,
}

fn load_fixture() -> Fixture {
    // CARGO_MANIFEST_DIR is GeniusLocusKit/rust/; the fixture is shared with
    // the Swift twin under Tests/Conformance/.
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Conformance/union_best_mmr_fixture.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str::<Fixture>(&raw).expect("fixture JSON must parse")
}

fn make_storage() -> Arc<dyn Storage> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    Arc::new(InMemoryStorage::new(config))
}

/// Open an in-memory estate with every body captured, ingested into a shared
/// corpus, and added to a shared vector store keyed by drawer id, so the
/// locus, BM25, and Hamming lanes all supply candidates — the same wiring as
/// the Swift fixture estate.
fn open_fixture_estate(
    owner: &str,
    bodies: &[&str],
) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let h = coord
        .open(store, OwnerCredentials::new(owner), 0, 100)
        .expect("open estate");
    let corpus = Arc::new(
        CorpusContentEngine::standalone_on(make_storage(), vec![EmbeddingModelConfig::Deterministic])
            .expect("CorpusContentEngine::standalone_on"),
    );
    let vector_store = Arc::new(VectorStore::open(make_storage()).expect("VectorStore::open"));
    for (idx, body) in bodies.iter().enumerate() {
        let frame = CaptureFrame::new(
            *body,
            CaptureChannel::Typed,
            "mmr-shingle-once",
            LatticeAnchor::udc("000"),
            "mmr-shingle-once",
            "test-model-v1",
        );
        // Staggered capture instants keep the locus lane's byCaptureTimeDesc
        // order deterministic, as the other parity fixtures do.
        let ts = NOW + idx as i64;
        let drawer = coord.capture(&h, frame, ts).expect("capture");
        corpus.ingest(body, &drawer.id, ts).expect("corpus ingest");
        let engram = corpus.embed(body).expect("embed");
        vector_store
            .add_vector(&drawer.id, &engram, &corpus.model_id(), "1.0", ts)
            .expect("add_vector");
    }
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h)
}

/// A full-hydration unionBest MatrixAware request with no recall shape: the
/// pins run under the default lane budget (`signal:vector` = 0 since the
/// Encoder Rerank Program), the same budget the Swift twins use.
fn full_union_best_request(query: &str, limit: usize) -> GLKRecallRequest {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Full;
    GLKRecallRequest::new(
        frame,
        GLKRecallMode::UnionBest,
        GLKRecallScoring::MatrixAware,
        limit,
        RecallFallbackPolicy::FailClosed,
        RecallOrigin::Internal,
    )
    .with_query_text(query)
}

fn contents(result: &genius_locus_kit::recall::GLKRecallResult) -> Vec<String> {
    result
        .hits
        .iter()
        .map(|hit| hit.drawer.as_ref().map(|d| d.content.clone()).unwrap_or_default())
        .collect()
}

// MARK: - 1. Pinned order (Swift twin)

#[test]
fn full_hydration_near_duplicate_order_is_pinned() {
    let (coord, h) = open_fixture_estate("owner-mmr-shingle-once", &BODIES);
    let first = coord
        .recall_scored(&h, full_union_best_request(QUERY, 2), NOW + 100)
        .expect("recall 1");
    let second = coord
        .recall_scored(&h, full_union_best_request(QUERY, 2), NOW + 100)
        .expect("recall 2");
    let observed = contents(&first);
    assert!(
        observed.iter().all(|c| !c.is_empty()),
        "a Full recall must return bodies; got {observed:?}"
    );
    let expected: Vec<String> = PINNED_ORDER.iter().map(|s| s.to_string()).collect();
    assert_eq!(observed, expected, "matrixAware order moved");
    let first_ids: Vec<&String> = first.hits.iter().map(|hit| &hit.id).collect();
    let second_ids: Vec<&String> = second.hits.iter().map(|hit| &hit.id).collect();
    assert_eq!(first_ids, second_ids, "order must be stable across two identical recalls");
}

// MARK: - 2. Set overload equals string overload

#[test]
fn set_overload_matches_string_overload_on_fixture_bodies() {
    let sets: Vec<_> = BODIES.iter().map(|b| shingle_similarity::shingles(b)).collect();
    for i in 0..BODIES.len() {
        for j in 0..BODIES.len() {
            let via_strings = shingle_similarity::similarity(BODIES[i], BODIES[j]);
            let via_sets = shingle_similarity::similarity_sets(&sets[i], &sets[j]);
            assert_eq!(
                via_strings.to_bits(),
                via_sets.to_bits(),
                "pair ({i}, {j}): string overload {via_strings} != set overload {via_sets}"
            );
        }
    }
    // The near-duplicate cluster must be far more similar than any
    // cross-cluster pair, or the fixture could not move the MMR order.
    let in_cluster = shingle_similarity::similarity_sets(&sets[0], &sets[1]);
    let cross_cluster = (3..BODIES.len())
        .map(|k| shingle_similarity::similarity_sets(&sets[0], &sets[k]))
        .fold(0.0_f32, f32::max);
    assert!(
        in_cluster > 0.8 && cross_cluster < 0.6,
        "fixture cluster contrast lost: in {in_cluster} cross {cross_cluster}"
    );
}

// MARK: - 3. Shared cross-port fixture

#[test]
fn cross_port_fixture_content_order_matches() {
    let fixture = load_fixture();
    let bodies: Vec<&str> = fixture.bodies.iter().map(String::as_str).collect();
    let (coord, h) = open_fixture_estate("owner-mmr-cross-port", &bodies);
    let result = coord
        .recall_scored(&h, full_union_best_request(&fixture.query, fixture.limit), NOW + 100)
        .expect("recall_scored");
    let observed = contents(&result);
    assert_eq!(
        observed, fixture.expected_content_order,
        "cross-port fixture order moved (expected order produced by the Swift build)"
    );
}
