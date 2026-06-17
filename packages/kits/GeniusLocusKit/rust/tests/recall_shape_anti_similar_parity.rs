// recall_shape_anti_similar_parity.rs
//
// Parity tests for 6b-modifiers-antisim: RecallShape.anti_similar_lanes wired
// into the unionBest dense lane. Mirrors Swift RecallShapeAntiSimilarTests.swift.
//
// Anti-similarity (FARTHEST objective) changes WHICH candidates the dense store
// returns (the most dissimilar), then forwards them into the same RRF/consensus
// fold. Observable design — dense PROVENANCE under frontierK truncation:
//
//   The dense lane retrieves only its top `frontier_k` sources (pinned to the
//   floor 64). With a corpus LARGER than 64, nearest keeps the most-similar
//   sources and DROPS the most-dissimilar tail; farthest keeps the most-
//   dissimilar sources. A tail drawer carries `vectorDense:<model_id>`
//   provenance ONLY when its lane is anti-similar — a signal a reweighting
//   (which never changes WHICH sources are retrieved) cannot produce.
//
//   (a) an anti-similar lane surfaces the most-dissimilar drawer.
//   (b) DISTINCTNESS: anti-similar+positive (the dissimilar drawer GAINS dense
//       provenance) vs nearest+negative weight (it does NOT — never retrieved).
//   (c) anti-similar composes with a signed weight.
//   (d) back-compat: nil vs empty anti_similar_lanes is byte-identical.
//
// MONOTONIC cosine spread: a drawer's direction is [cos θ, sin θ, 0…] with θ
// proportional to its token COUNT, so "most dissimilar" is unambiguous (no
// cosine ties). Mirrors the Swift fixture so both ports drop the same tail.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use corpus_kit::{Corpus, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallResult, GLKRecallScoring, RecallShape,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use vectorkit::vector_store::VectorStore;

const NOW: i64 = 1_700_000_000;
const MINILM_ID: &str = "minilm-v6";
const DRAWER_COUNT: usize = 80;
/// Dense pool depth pinned to the engine floor so the top-K truncation bites.
const PINNED_FRONTIER_K: usize = 64;

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 200)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "recall-shape-antisim-tests",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

/// MONOTONIC cosine spread keyed on token COUNT: direction [cos θ, sin θ, 0…]
/// with θ = count × 0.018 rad. The query (fewest tokens) is closest; a drawer's
/// dissimilarity grows with its token count. Mirrors the Swift inference.
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

/// Open a SINGLE-provider estate with `DRAWER_COUNT` drawers (drawer i has i+1
/// filler words → distinct token count → monotonic dissimilarity). Returns
/// (coord, handle, ids index-aligned, query word).
fn large_estate() -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Vec<String>,
    String,
) {
    let (mut coord, h) = open_one();
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Arc::new(
        Corpus::open(storage, minilm_monotonic_config()).expect("Corpus::open"),
    );
    let vector_store = make_vector_store();

    let mut ids: Vec<String> = Vec::with_capacity(DRAWER_COUNT);
    for i in 0..DRAWER_COUNT {
        let filler = vec!["word"; i + 1].join(" ");
        let content = format!("doc{i} {filler}");
        let drawer = coord
            .capture(&h, cap_frame(&content), NOW + i as i64)
            .expect("capture");
        corpus.ingest(&content, &drawer.id, NOW).expect("ingest");
        let engram = corpus.embed(&content).expect("embed");
        vector_store
            .add_vector(&drawer.id, &engram, corpus.model_id(), "1", NOW)
            .expect("add_vector");
        ids.push(drawer.id);
    }
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h, ids, "queryword".to_string())
}

/// A unionBest RRF request with `frontier_k` pinned to the floor (so the dense
/// truncation is observable) plus optional weights / anti-similar lanes.
fn union_best_rrf(
    query: &str,
    lane_weights: &[(&str, f32)],
    anti_similar: &[&str],
) -> GLKRecallRequest {
    let mut m = HashMap::new();
    for (k, v) in lane_weights {
        m.insert((*k).to_string(), *v);
    }
    let anti: HashSet<String> = anti_similar.iter().map(|s| s.to_string()).collect();
    let shape = RecallShape::new(m, Some(PINNED_FRONTIER_K)).with_anti_similar_lanes(anti);
    GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text(query)
        .with_limit(DRAWER_COUNT)
        .with_recall_shape(shape)
}

fn has_dense_provenance(result: &GLKRecallResult, id: &str) -> bool {
    result
        .hits
        .iter()
        .find(|hh| hh.id == id)
        .map(|hh| hh.explanation.join(" | ").contains(&format!("vectorDense:{MINILM_ID}")))
        .unwrap_or(false)
}

/// The highest-index drawer present in the result WITHOUT dense provenance under
/// nearest — a most-dissimilar tail drawer that the dense top-K dropped.
fn nearest_dropped_drawer(result: &GLKRecallResult, ids: &[String]) -> Option<String> {
    for id in ids.iter().rev() {
        if result.hits.iter().any(|hh| &hh.id == id) && !has_dense_provenance(result, id) {
            return Some(id.clone());
        }
    }
    None
}

// (a) an anti-similar lane surfaces dissimilar drawers in unionBest.
#[test]
fn anti_similar_lane_surfaces_dissimilar() {
    let (coord, h, ids, query) = large_estate();
    let dense_key = format!("dense:{MINILM_ID}");

    let nearest = coord
        .recall_scored(&h, union_best_rrf(&query, &[], &[]), NOW + 1000)
        .expect("recall nearest");
    let dropped = nearest_dropped_drawer(&nearest, &ids)
        .expect("test setup: corpus must exceed frontier_k so a dissimilar tail is dropped");
    assert!(!has_dense_provenance(&nearest, &dropped));

    let anti = coord
        .recall_scored(&h, union_best_rrf(&query, &[], &[&dense_key]), NOW + 1001)
        .expect("recall anti-similar");
    assert!(
        has_dense_provenance(&anti, &dropped),
        "anti-similar dense lane must surface the dissimilar drawer that nearest dropped"
    );
}

// (b) DISTINCTNESS — anti-similar+positive differs from nearest+negative weight.
#[test]
fn anti_similar_distinct_from_negative_weight() {
    let (coord, h, ids, query) = large_estate();
    let dense_key = format!("dense:{MINILM_ID}");

    let baseline = coord
        .recall_scored(&h, union_best_rrf(&query, &[], &[]), NOW + 1000)
        .expect("recall baseline");
    let dropped = nearest_dropped_drawer(&baseline, &ids)
        .expect("test setup: a dissimilar tail drawer must be dropped");

    // anti-similar + positive (forward the dissimilar).
    let anti = coord
        .recall_scored(
            &h,
            union_best_rrf(&query, &[(&dense_key, 1.0)], &[&dense_key]),
            NOW + 1001,
        )
        .expect("recall anti");
    // nearest + negative (demote the similar) — NOT anti-similar.
    let neg = coord
        .recall_scored(&h, union_best_rrf(&query, &[(&dense_key, -1.0)], &[]), NOW + 1002)
        .expect("recall neg");

    assert!(
        has_dense_provenance(&anti, &dropped),
        "anti-similar path must give the dissimilar drawer dense provenance (forwards the farthest)"
    );
    assert!(
        !has_dense_provenance(&neg, &dropped),
        "negative-weight path must NOT give the dissimilar drawer dense provenance (never retrieved)"
    );
}

// (c) anti-similar composes with a signed weight: same farthest retrieval, w>0
//     and w<0 both target the dissimilar drawer.
#[test]
fn anti_similar_composes_with_weight() {
    let (coord, h, ids, query) = large_estate();
    let dense_key = format!("dense:{MINILM_ID}");

    let baseline = coord
        .recall_scored(&h, union_best_rrf(&query, &[], &[]), NOW + 1000)
        .expect("recall baseline");
    let dropped = nearest_dropped_drawer(&baseline, &ids)
        .expect("test setup: a dissimilar tail drawer must be dropped");

    let forward = coord
        .recall_scored(
            &h,
            union_best_rrf(&query, &[(&dense_key, 1.0)], &[&dense_key]),
            NOW + 1001,
        )
        .expect("recall forward");
    let suppress = coord
        .recall_scored(
            &h,
            union_best_rrf(&query, &[(&dense_key, -1.0)], &[&dense_key]),
            NOW + 1002,
        )
        .expect("recall suppress");

    assert!(
        has_dense_provenance(&forward, &dropped),
        "anti-similar+forward must give the dissimilar drawer dense provenance"
    );
    assert!(
        has_dense_provenance(&suppress, &dropped),
        "anti-similar+suppress still contributed (negative) mass to the dissimilar drawer"
    );
}

// (d) back-compat — nil shape and empty anti_similar_lanes are byte-identical.
#[test]
fn empty_anti_similar_equals_nil() {
    let (coord, h, _ids, query) = large_estate();

    // Both use the engine default frontier_k (no override) → whole corpus in the
    // dense pool → pure back-compat comparison, no truncation.
    let nil_req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text(&query)
        .with_limit(DRAWER_COUNT);
    let empty_req = nil_req
        .clone()
        .with_recall_shape(RecallShape::new(HashMap::new(), None).with_anti_similar_lanes(HashSet::new()));

    let nil_result = coord.recall_scored(&h, nil_req, NOW + 1000).expect("recall nil");
    let empty_result = coord.recall_scored(&h, empty_req, NOW + 1001).expect("recall empty");

    let nil_ids: Vec<&String> = nil_result.hits.iter().map(|hh| &hh.id).collect();
    let empty_ids: Vec<&String> = empty_result.hits.iter().map(|hh| &hh.id).collect();
    assert_eq!(
        nil_ids, empty_ids,
        "empty anti_similar_lanes must produce the same unionBest id order as nil shape"
    );
    for (a, b) in nil_result.hits.iter().zip(empty_result.hits.iter()) {
        assert_eq!(a.id, b.id);
        assert_eq!(
            a.score.final_score, b.score.final_score,
            "unionBest fused final must be byte-identical for {}",
            a.id
        );
        assert_eq!(
            a.score.dense, b.score.dense,
            "unionBest dense column must be byte-identical for {}",
            a.id
        );
    }
}
