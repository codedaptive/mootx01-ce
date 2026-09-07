// recall_hybrid_shape_parity.rs
//
// Rust pins for the lane columns a Hybrid or CorpusOnly hit carries, and for
// the lane roster of the Hybrid path. Parity peer of Swift
// RecallHybridShapeTests; the two files pin the same values.
//
// Contract (GENIUSLOCUSKIT_SPEC 3.5.0): under every scoring, a hit returned by
// Hybrid or CorpusOnly recall carries PER-SIGNAL lane columns. `locus` is the
// locus ramp `(frontier_k - rank) / frontier_k` when the locus lane supplied
// the hit, `bm25` is the BM25 score when the BM25 lane supplied it, `vector` is
// the Hamming similarity `(256 - distance) / 256` when the vector lane supplied
// it, and each column is 0 where its lane did not supply the hit. `final_score`
// is the fused or merged score and the ranking reads it alone. The Hybrid path
// fuses the locus, BM25 and vector lanes and no other: a drawer only a tunnel
// would reach is not a Hybrid candidate.
//
// Tests:
//  1. hybrid_rrf_hits_carry_per_signal_columns: four drawers, two with the
//     query word, two in the vector store. Under Hybrid `Rrf` the hit every
//     lane supplied, the hits two lanes supplied and the locus-only hit each
//     carry their lanes' own scores and 0 elsewhere.
//  2. hybrid_raw_hits_carry_per_signal_columns: the same estate under `Raw`.
//  3. corpus_only_rrf_hits_carry_per_signal_columns: the same estate under
//     CorpusOnly `Rrf`: `locus` is 0 on every hit, the BM25-only and
//     vector-only hits carry one column, the locus-only drawer is absent.
//  4. hybrid_rrf_does_not_supply_graph_only_candidates: a drawer outside the
//     locus frontier reached only by a tunnel from the newest drawer is absent
//     from Hybrid `Rrf` hits and lane ranks; the UnionBest graph lane reaches
//     it (control), so the fixture is real.

use std::collections::HashMap;
use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath, RecallFallbackPolicy,
    RecallHit, RecallOrigin,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use locus_kit::frames::{CaptureFrame, TunnelCaptureFrame};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use synapsekit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_100;
/// `min(max(limit * 4, 64), 256)` for every limit at or below 16.
const FRONTIER_K: usize = 64;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn open_one(suffix: &str) -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new(&format!("owner-shape-{suffix}")), 0, 100)
        .expect("open estate");
    (coord, handle)
}

fn capture_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "shape-room",
        LatticeAnchor::udc("000"),
        "shape-tests",
        "test-model-v1",
    )
}

/// Recall frame matching all currently-believed rows.
fn active_frame() -> RecallFrame {
    let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
    frame.hydration_level = HydrationLevel::Structured;
    frame
}

fn request(mode: GLKRecallMode, scoring: GLKRecallScoring, limit: usize, query: Option<&str>) -> GLKRecallRequest {
    let req = GLKRecallRequest::new(
        active_frame(),
        mode,
        scoring,
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

/// A bag-of-tokens direction: every token adds a cosine ridge keyed on its
/// id, so two texts that share a token share part of their direction and the
/// Hamming lane ranks the text sharing the query word nearer than one that
/// shares none. The same closure as the Swift twin's `miniLM` inference. (A
/// direction that varies in two dimensions alone never flips a +-1 SimHash
/// plane, so token count alone cannot separate drawers.)
fn minilm_bag_config() -> EmbeddingModelConfig {
    EmbeddingModelConfig::MiniLM {
        inference: Box::new(|tokens: &[i32]| {
            let mut v = vec![0.0_f32; 384];
            for tok in tokens {
                let key = (tok.rem_euclid(251) + 1) as f32;
                for (j, slot) in v.iter_mut().enumerate() {
                    *slot += (key * (j as f32 + 1.0) * 0.1).cos();
                }
            }
            Ok(v)
        }),
    }
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(
        CorpusContentEngine::standalone_on(storage, vec![minilm_bag_config()])
            .expect("engine open"),
    )
}

fn make_vector_store() -> Arc<VectorStore> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
}

/// The lane oracles for the four-drawer estate, read from the corpus and the
/// vector store directly so the pins do not depend on the coordinator.
struct LaneOracle {
    /// BM25 score by drawer id for the query, from `bm25_top_k_by_source`.
    bm25: HashMap<String, f32>,
    /// Hamming similarity `(256 - distance) / 256` by drawer id for the query
    /// engram, from `find_nearest`.
    vector: HashMap<String, f32>,
}

/// Four drawers, oldest first:
///   ids[0] "doc0 queryword alpha": query word, in the vector store (three lanes)
///   ids[1] "doc1 queryword beta beta beta beta": query word, not in the store
///          (locus + BM25); longer, so BM25 ranks it below ids[0]
///   ids[2] "doc2 gamma delta":     no query word, in the store (locus + vector);
///          it shares no token with the query, so it sits further from the
///          query than ids[0], which shares the query word
///   ids[3] "doc3 epsilon zeta":    no query word, not in the store (locus only)
/// The locus lane ranks newest first, so ids[3] has locus rank 0. No lane
/// holds a tie, so every rank the RRF pins read is fixed.
fn four_drawer_estate() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle, Vec<String>, String, LaneOracle) {
    let (mut coord, h) = open_one("four");
    let corpus = make_corpus();
    let vector_store = make_vector_store();
    let query = "queryword".to_string();
    let contents = ["doc0 queryword alpha", "doc1 queryword beta beta beta beta", "doc2 gamma delta", "doc3 epsilon zeta"];
    let in_store = [0usize, 2];
    let mut ids = Vec::with_capacity(contents.len());
    for (i, content) in contents.iter().enumerate() {
        let drawer = coord
            .capture(&h, capture_frame(content), NOW + i as i64)
            .expect("capture");
        corpus.ingest(content, &drawer.id, NOW).expect("ingest");
        if in_store.contains(&i) {
            let engram = corpus.embed(content).expect("embed");
            vector_store
                .add_vector(&drawer.id, &engram, &corpus.model_id(), "1", NOW)
                .expect("add_vector");
        }
        ids.push(drawer.id);
    }

    let bm25: HashMap<String, f32> = corpus
        .bm25_top_k_by_source(&query, FRONTIER_K)
        .into_iter()
        .collect();
    let probe = corpus.embed(&query).expect("embed query");
    let vector: HashMap<String, f32> = vector_store
        .find_nearest(&probe, &corpus.model_id(), FRONTIER_K)
        .expect("find_nearest")
        .into_iter()
        .map(|m| (m.item_id, (256 - m.distance.clamp(0, 256)) as f32 / 256.0))
        .collect();
    let mut bm25_ids: Vec<&str> = bm25.keys().map(|k| k.as_str()).collect();
    bm25_ids.sort_unstable();
    let mut want_bm25: Vec<&str> = vec![ids[0].as_str(), ids[1].as_str()];
    want_bm25.sort_unstable();
    assert_eq!(bm25_ids, want_bm25, "BM25 matches the two query-word drawers");
    let mut vector_ids: Vec<&str> = vector.keys().map(|k| k.as_str()).collect();
    vector_ids.sort_unstable();
    let mut want_vector: Vec<&str> = vec![ids[0].as_str(), ids[2].as_str()];
    want_vector.sort_unstable();
    assert_eq!(vector_ids, want_vector, "the vector store holds two drawers");
    assert!(bm25[&ids[0]] > bm25[&ids[1]], "the shorter query-word drawer leads BM25 (no tie): {:?}", bm25);
    assert!(vector[&ids[0]] > vector[&ids[2]], "the drawer sharing the query word is nearer the query (no tie): {:?}", vector);

    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h, ids, query, LaneOracle { bm25, vector })
}

/// The columns a Hybrid hit for `hit.id` must carry: the locus ramp at its
/// locus rank, the BM25 oracle or 0, the Hamming oracle or 0.
fn expect_hybrid_columns(hit: &RecallHit, locus_rank: usize, oracle: &LaneOracle, label: &str) {
    let want_locus = ramp(locus_rank);
    let want_bm25 = oracle.bm25.get(&hit.id).copied().unwrap_or(0.0);
    let want_vector = oracle.vector.get(&hit.id).copied().unwrap_or(0.0);
    assert!(
        (hit.score.locus - want_locus).abs() < 1e-6,
        "{label}: locus is the ramp {want_locus}, got {}",
        hit.score.locus
    );
    assert!(
        (hit.score.bm25 - want_bm25).abs() < 1e-6,
        "{label}: bm25 is the BM25 lane score {want_bm25}, got {}",
        hit.score.bm25
    );
    assert!(
        (hit.score.vector - want_vector).abs() < 1e-6,
        "{label}: vector is the Hamming similarity {want_vector}, got {}",
        hit.score.vector
    );
    assert!(hit.sources.contains(&RecallEvidencePath::LocusBitmap), "{label}: the locus lane supplied it");
    assert_eq!(
        hit.sources.contains(&RecallEvidencePath::CorpusBm25),
        want_bm25 > 0.0,
        "{label}: BM25 provenance matches the column"
    );
    assert_eq!(
        hit.sources.contains(&RecallEvidencePath::VectorHamming),
        want_vector > 0.0,
        "{label}: vector provenance matches the column"
    );
    assert!(!hit.sources.contains(&RecallEvidencePath::LocusGraph), "{label}: Hybrid has no graph lane");
}

fn by_id(hits: &[RecallHit]) -> HashMap<&str, &RecallHit> {
    hits.iter().map(|h| (h.id.as_str(), h)).collect()
}

// ---------------------------------------------------------------------------
// 1. Hybrid Rrf
// ---------------------------------------------------------------------------

/// Twin of Swift `hybridRrfHitsCarryPerSignalColumns`.
#[test]
fn hybrid_rrf_hits_carry_per_signal_columns() {
    let (coord, h, ids, query, oracle) = four_drawer_estate();

    let result = coord
        .recall_scored(&h, request(GLKRecallMode::Hybrid, GLKRecallScoring::Rrf, 10, Some(&query)), NOW + 10)
        .expect("hybrid rrf recall");

    assert_eq!(result.hits.len(), 4, "every drawer is a locus candidate");
    let hits = by_id(&result.hits);
    let three = hits.get(ids[0].as_str()).expect("the three-lane drawer surfaces");
    let locus_bm25 = hits.get(ids[1].as_str()).expect("the locus + BM25 drawer surfaces");
    let locus_vector = hits.get(ids[2].as_str()).expect("the locus + vector drawer surfaces");
    let locus_only = hits.get(ids[3].as_str()).expect("the locus-only drawer surfaces");
    expect_hybrid_columns(three, 3, &oracle, "three lanes");
    expect_hybrid_columns(locus_bm25, 2, &oracle, "locus + BM25");
    expect_hybrid_columns(locus_vector, 1, &oracle, "locus + vector");
    expect_hybrid_columns(locus_only, 0, &oracle, "locus only");

    // The three-lane drawer holds the reciprocal-rank sum of its three ranks
    // (first in BM25 and vector, fourth in locus) and leads.
    let want_final: f32 = 1.0 / (60.0 + 4.0) + 1.0 / (60.0 + 1.0) + 1.0 / (60.0 + 1.0);
    assert!(
        (three.score.final_score - want_final).abs() < 1e-6,
        "three lanes: final is the RRF sum {want_final}, got {}",
        three.score.final_score
    );
    assert_eq!(result.hits[0].id, ids[0], "the three-lane drawer leads under RRF");
    // A column never equals the fused final by construction: the ramp is at
    // least 0.95 here and an RRF sum at most 3/61.
    for hit in &result.hits {
        assert_ne!(hit.score.locus, hit.score.final_score, "{}: locus is not the fused final", hit.id);
    }
}

// ---------------------------------------------------------------------------
// 2. Hybrid Raw
// ---------------------------------------------------------------------------

/// Twin of Swift `hybridRawHitsCarryPerSignalColumns`.
#[test]
fn hybrid_raw_hits_carry_per_signal_columns() {
    let (coord, h, ids, query, oracle) = four_drawer_estate();

    let result = coord
        .recall_scored(&h, request(GLKRecallMode::Hybrid, GLKRecallScoring::Raw, 10, Some(&query)), NOW + 10)
        .expect("hybrid raw recall");

    let got: Vec<&str> = result.hits.iter().map(|hit| hit.id.as_str()).collect();
    let want: Vec<&str> = ids.iter().rev().map(|id| id.as_str()).collect();
    assert_eq!(got, want, "Raw is the locus order, newest first");
    for (rank, hit) in result.hits.iter().enumerate() {
        expect_hybrid_columns(hit, rank, &oracle, &format!("raw rank {rank}"));
        assert!(
            (hit.score.final_score - ramp(rank)).abs() < 1e-6,
            "raw rank {rank}: final is the locus ramp {}, got {}",
            ramp(rank),
            hit.score.final_score
        );
    }
}

// ---------------------------------------------------------------------------
// 3. CorpusOnly Rrf
// ---------------------------------------------------------------------------

/// Twin of Swift `corpusOnlyRrfHitsCarryPerSignalColumns`.
#[test]
fn corpus_only_rrf_hits_carry_per_signal_columns() {
    let (coord, h, ids, query, oracle) = four_drawer_estate();

    let result = coord
        .recall_scored(&h, request(GLKRecallMode::CorpusOnly, GLKRecallScoring::Rrf, 10, Some(&query)), NOW + 10)
        .expect("corpusOnly rrf recall");

    let mut got: Vec<&str> = result.hits.iter().map(|hit| hit.id.as_str()).collect();
    got.sort_unstable();
    let mut want: Vec<&str> = vec![ids[0].as_str(), ids[1].as_str(), ids[2].as_str()];
    want.sort_unstable();
    assert_eq!(got, want, "the BM25 and vector lanes supply three drawers; the locus-only drawer is absent");
    let hits = by_id(&result.hits);
    for id in [&ids[0], &ids[1], &ids[2]] {
        let hit = hits.get(id.as_str()).expect("hit surfaces");
        let want_bm25 = oracle.bm25.get(id).copied().unwrap_or(0.0);
        let want_vector = oracle.vector.get(id).copied().unwrap_or(0.0);
        assert_eq!(hit.score.locus, 0.0, "{id}: CorpusOnly has no locus lane");
        assert!(
            (hit.score.bm25 - want_bm25).abs() < 1e-6,
            "{id}: bm25 is the BM25 lane score {want_bm25}, got {}",
            hit.score.bm25
        );
        assert!(
            (hit.score.vector - want_vector).abs() < 1e-6,
            "{id}: vector is the Hamming similarity {want_vector}, got {}",
            hit.score.vector
        );
        assert_eq!(
            hit.sources.contains(&RecallEvidencePath::CorpusBm25),
            want_bm25 > 0.0,
            "{id}: BM25 provenance matches the column"
        );
        assert_eq!(
            hit.sources.contains(&RecallEvidencePath::VectorHamming),
            want_vector > 0.0,
            "{id}: vector provenance matches the column"
        );
    }
    // The BM25-only and vector-only hits carry exactly one column, and it is
    // the lane score, never the reciprocal-rank final.
    let bm25_only = hits.get(ids[1].as_str()).unwrap();
    assert!(bm25_only.score.vector == 0.0 && bm25_only.score.bm25 > 0.0, "BM25-only: one column");
    assert_ne!(bm25_only.score.bm25, bm25_only.score.final_score, "BM25-only: the column is not the fused final");
    let vector_only = hits.get(ids[2].as_str()).unwrap();
    assert!(vector_only.score.bm25 == 0.0 && vector_only.score.vector > 0.0, "vector-only: one column");
    assert_ne!(vector_only.score.vector, vector_only.score.final_score, "vector-only: the column is not the fused final");
    // The two-lane drawer holds the reciprocal-rank sum of its two first ranks.
    let two = hits.get(ids[0].as_str()).unwrap();
    let want_final: f32 = 1.0 / (60.0 + 1.0) + 1.0 / (60.0 + 1.0);
    assert!(
        (two.score.final_score - want_final).abs() < 1e-6,
        "two lanes: final is the RRF sum {want_final}, got {}",
        two.score.final_score
    );
}

// ---------------------------------------------------------------------------
// 4. Hybrid has no graph lane
// ---------------------------------------------------------------------------

/// Twin of Swift `hybridRrfDoesNotSupplyGraphOnlyCandidates`.
///
/// Sixty-five drawers, so at the default frontier of 64 the oldest drawer
/// falls outside the locus window. A tunnel from the newest drawer reaches it.
/// The corpus holds the newest drawer only, so the BM25 lane never supplies
/// the target either: only a graph lane would. Hybrid `Rrf` returns no such
/// hit and records no graph rank; UnionBest, which has the graph lane, records
/// the target at graph rank 1 (the fixture control).
#[test]
fn hybrid_rrf_does_not_supply_graph_only_candidates() {
    let (mut coord, h) = open_one("graph");
    let corpus = make_corpus();
    let query = "queryword";

    // Content strings sort the same way as capture time under the stable
    // locus sort (filed_at DESC, then content DESC): "zz" leads and "0"
    // trails, the Swift twin's tiebreak.
    let target = coord
        .capture(&h, capture_frame("0 tunnel target"), NOW)
        .expect("capture target");
    for i in 1..FRONTIER_K {
        coord
            .capture(&h, capture_frame(&format!("doc{i} filler")), NOW + i as i64)
            .expect("capture filler");
    }
    let newest_content = "zz newest queryword";
    let newest = coord
        .capture(&h, capture_frame(newest_content), NOW + FRONTIER_K as i64)
        .expect("capture newest");
    corpus.ingest(newest_content, &newest.id, NOW).expect("ingest newest");
    coord.register_corpus(&h, corpus);

    let estate = coord.estate_for(&h).expect("estate");
    let mut tunnel = TunnelCaptureFrame::new(
        "shape-room", "shape-room", "shape-room", "shape-room", "shape-graph-link", "shape-tests",
    );
    tunnel.source_drawer_id = Some(newest.id.clone());
    tunnel.target_drawer_id = Some(target.id.clone());
    estate
        .capture_tunnel(tunnel, NOW + FRONTIER_K as i64 + 1)
        .expect("capture tunnel");

    let hybrid = coord
        .recall_scored(
            &h,
            request(GLKRecallMode::Hybrid, GLKRecallScoring::Rrf, 10, Some(query)),
            NOW + FRONTIER_K as i64 + 2,
        )
        .expect("hybrid rrf recall");
    assert!(!hybrid.hits.is_empty(), "the Hybrid recall returns the locus and BM25 candidates");
    assert_eq!(hybrid.hits[0].id, newest.id, "the newest drawer leads: locus rank 1 and BM25 rank 1");
    assert!(
        !hybrid.hits.iter().any(|hit| hit.id == target.id),
        "Hybrid has no graph lane, so the tunnel target outside the locus frontier is absent"
    );
    assert!(
        hybrid.lane_ranks.get(&target.id).is_none(),
        "no Hybrid lane ranked the target (got {:?})",
        hybrid.lane_ranks.get(&target.id)
    );
    assert!(
        !hybrid.hits.iter().any(|hit| hit.sources.contains(&RecallEvidencePath::LocusGraph)),
        "no Hybrid hit carries LocusGraph"
    );
    let newest_ranks = hybrid.lane_ranks.get(&newest.id).expect("the newest drawer is ranked");
    assert_eq!(newest_ranks.get("locus"), Some(&1), "the newest drawer is locus rank 1 (got {newest_ranks:?})");
    assert_eq!(newest_ranks.get("bm25"), Some(&1), "the newest drawer is BM25 rank 1 (got {newest_ranks:?})");
    assert!(newest_ranks.get("graph").is_none(), "Hybrid records no graph rank (got {newest_ranks:?})");

    // Control: the UnionBest graph lane reaches the target through the tunnel,
    // so the fixture really does put it one tunnel away.
    let union = coord
        .recall_scored(
            &h,
            request(GLKRecallMode::UnionBest, GLKRecallScoring::Rrf, 10, Some(query)),
            NOW + FRONTIER_K as i64 + 3,
        )
        .expect("unionBest rrf recall");
    let target_ranks = union.lane_ranks.get(&target.id).expect("UnionBest ranks the target through the graph lane");
    assert_eq!(target_ranks.get("graph"), Some(&1), "UnionBest records the target at graph rank 1 (got {target_ranks:?})");
    assert!(target_ranks.get("locus").is_none(), "the target sits outside the 64-wide locus frontier");
}
