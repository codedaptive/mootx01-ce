// recall_shape_signed_weight_parity.rs
//
// Parity tests for the 6b-modifiers-core RecallShape signed-weight fusion ENGINE,
// mirroring Swift RecallShapeSignedWeightTests.swift.
//
// RecallShape makes the coordinator's RRF fusion STEERABLE by signed per-lane
// weights without changing the fusion algorithm. On the hybrid lane
// (locus + bm25 + hamming) these tests prove:
//
//   (a) nil-shape back-compat — an absent shape (or an all-1.0 shape) is
//       byte-identical to the unweighted fusion.
//   (b) exclusion — a lane weighted 0 drops that lane's votes entirely.
//   (c) suppression — a lane weighted < 0 DEMOTES a candidate it ranks high.
//   (d) leave-one-out — nulling one signal removes only that signal's votes.
//   (e) frontierK override — the shape can widen/narrow the pool, clamped.
//
// Exclusion (w=0) and suppression (w<0) are DISTINCT and tested separately.
// Anti-similarity (true farthest-K) is decomposed to 6b-modifiers-antisim and is
// NOT exercised here.

use std::collections::HashMap;
use std::sync::Arc;

use corpus_kit::{CorpusContentEngine, EmbeddingModelConfig};
use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath, RecallShape,
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

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        "recall-shape-tests",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

fn make_corpus() -> Arc<CorpusContentEngine> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(CorpusContentEngine::standalone_on(storage, vec![EmbeddingModelConfig::Deterministic]).expect("Corpus::open"))
}

fn make_vector_store() -> Arc<VectorStore> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
}

/// Open an estate with three captured drawers wired to a deterministic corpus +
/// vector store, so the bm25 and hamming lanes produce real candidates. Returns
/// the coordinator, handle, and the drawer ids in capture order.
fn estate_with_drawers(
    contents: &[&str],
) -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Vec<String>,
) {
    let (mut coord, h) = open_one();
    let corpus = make_corpus();
    let vector_store = make_vector_store();
    let mut ids = Vec::new();
    for content in contents {
        let drawer = coord.capture(&h, cap_frame(content), NOW).expect("capture");
        corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
        let engram = corpus.embed(&drawer.content).expect("embed");
        vector_store
            .add_vector(&drawer.id, &engram, &corpus.model_id(), "1", NOW)
            .expect("add_vector");
        ids.push(drawer.id);
    }
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h, ids)
}

fn hybrid_req(query: &str, shape: Option<RecallShape>) -> GLKRecallRequest {
    let mut req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text(query)
        .with_limit(10);
    if let Some(s) = shape {
        req = req.with_recall_shape(s);
    }
    req
}

const CONTENTS: [&str; 3] = [
    "apple mango banana fruit recall test content",
    "mango orange grapefruit citrus recall basket",
    "recall stochastic gradient descent optimizer notes",
];

// (a) nil-shape back-compat: a nil shape and an explicit all-1.0 shape produce
//     byte-identical fused output.
#[test]
fn nil_shape_equals_all_ones_shape() {
    let (coord, h, _) = estate_with_drawers(&CONTENTS);

    let nil_result = coord
        .recall_scored(&h, hybrid_req("mango fruit recall", None), NOW + 1)
        .expect("recall nil");
    let mut weights = HashMap::new();
    weights.insert("locus".to_string(), 1.0);
    weights.insert("bm25".to_string(), 1.0);
    weights.insert("hamming".to_string(), 1.0);
    let ones = RecallShape::new(weights, None);
    let ones_result = coord
        .recall_scored(&h, hybrid_req("mango fruit recall", Some(ones)), NOW + 1)
        .expect("recall ones");

    let nil_ids: Vec<_> = nil_result.hits.iter().map(|x| x.id.clone()).collect();
    let ones_ids: Vec<_> = ones_result.hits.iter().map(|x| x.id.clone()).collect();
    assert_eq!(nil_ids, ones_ids, "all-1.0 shape must match nil shape order");
    for (a, b) in nil_result.hits.iter().zip(ones_result.hits.iter()) {
        assert_eq!(a.id, b.id);
        assert_eq!(
            a.score.final_score, b.score.final_score,
            "fused final must be byte-identical at weight 1.0 for {}",
            a.id
        );
    }
}

// (b) exclusion: weight 0 drops the excluded lane's votes. With bm25 excluded,
//     every surviving hit must still be reachable via locus or hamming.
#[test]
fn weight_zero_excludes_lane() {
    let (coord, h, _) = estate_with_drawers(&CONTENTS);

    let full = coord
        .recall_scored(&h, hybrid_req("mango fruit recall", None), NOW + 1)
        .expect("recall full");
    let mut w = HashMap::new();
    w.insert("bm25".to_string(), 0.0);
    let excluded = coord
        .recall_scored(
            &h,
            hybrid_req("mango fruit recall", Some(RecallShape::new(w, None))),
            NOW + 1,
        )
        .expect("recall excluded");

    for hit in &excluded.hits {
        let non_bm25 = hit.sources.contains(&RecallEvidencePath::LocusBitmap)
            || hit.sources.contains(&RecallEvidencePath::VectorHamming);
        assert!(
            non_bm25,
            "with bm25 excluded, every surviving hit must have a non-bm25 source; {} sources={:?}",
            hit.id, hit.sources
        );
    }

    let full_by_id: HashMap<_, _> = full
        .hits
        .iter()
        .map(|x| (x.id.clone(), x.score.final_score))
        .collect();
    let saw_change = excluded
        .hits
        .iter()
        .any(|hit| matches!(full_by_id.get(&hit.id), Some(before) if *before != hit.score.final_score));
    assert!(
        saw_change || excluded.hits.len() != full.hits.len(),
        "excluding the bm25 lane must change the fused scores or the surviving set"
    );
}

// (c) suppression: a negative weight DEMOTES a candidate the lane ranks high.
#[test]
fn negative_weight_suppresses_lane() {
    let (coord, h, ids) = estate_with_drawers(&CONTENTS);
    let query = "apple mango banana fruit";

    let neutral = coord
        .recall_scored(&h, hybrid_req(query, None), NOW + 1)
        .expect("recall neutral");
    let mut w = HashMap::new();
    w.insert("bm25".to_string(), -1.0);
    let suppressed = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(w, None))), NOW + 1)
        .expect("recall suppressed");

    let target = &ids[0];
    let neutral_rank = neutral.hits.iter().position(|x| &x.id == target);
    let suppressed_rank = suppressed.hits.iter().position(|x| &x.id == target);
    if let (Some(n), Some(s)) = (neutral_rank, suppressed_rank) {
        assert!(
            s >= n,
            "suppressing bm25 must not improve the bm25-favoured drawer's rank; neutral={n} suppressed={s}"
        );
    }
    let neutral_final = neutral.hits.iter().find(|x| &x.id == target).map(|x| x.score.final_score);
    let suppressed_final = suppressed.hits.iter().find(|x| &x.id == target).map(|x| x.score.final_score);
    if let (Some(nf), Some(sf)) = (neutral_final, suppressed_final) {
        assert!(
            sf < nf,
            "negative bm25 weight must lower the bm25-favoured drawer's fused final; neutral={nf} suppressed={sf}"
        );
    }
}

// Distinctness: exclusion (w=0) and suppression (w<0) of the same lane must not
// produce identical output.
#[test]
fn exclusion_and_suppression_differ() {
    let (coord, h, _) = estate_with_drawers(&CONTENTS);
    let query = "apple mango banana fruit";

    let mut w0 = HashMap::new();
    w0.insert("bm25".to_string(), 0.0);
    let excluded = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(w0, None))), NOW + 1)
        .expect("recall excluded");
    let mut wn = HashMap::new();
    wn.insert("bm25".to_string(), -1.0);
    let suppressed = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(wn, None))), NOW + 1)
        .expect("recall suppressed");

    let ex_ids: Vec<_> = excluded.hits.iter().map(|x| x.id.clone()).collect();
    let sup_ids: Vec<_> = suppressed.hits.iter().map(|x| x.id.clone()).collect();
    let same_order = ex_ids == sup_ids;
    let same_scores = excluded
        .hits
        .iter()
        .zip(suppressed.hits.iter())
        .all(|(a, b)| a.id == b.id && a.score.final_score == b.score.final_score);
    assert!(
        !(same_order && same_scores),
        "exclusion and suppression of the same lane must differ; ex={ex_ids:?} sup={sup_ids:?}"
    );
}

// (d) leave-one-out: nulling one signal removes only that signal's votes, and the
//     fusion stays deterministic.
#[test]
fn leave_one_out_nulls_single_signal() {
    let (coord, h, _) = estate_with_drawers(&CONTENTS);
    let query = "mango fruit recall";

    let mut w = HashMap::new();
    w.insert("hamming".to_string(), 0.0);
    let a = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(w.clone(), None))), NOW + 1)
        .expect("recall a");
    let b = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(w, None))), NOW + 1)
        .expect("recall b");

    let a_ids: Vec<_> = a.hits.iter().map(|x| x.id.clone()).collect();
    let b_ids: Vec<_> = b.hits.iter().map(|x| x.id.clone()).collect();
    assert_eq!(a_ids, b_ids, "leave-one-out fusion must be deterministic");
    for (x, y) in a.hits.iter().zip(b.hits.iter()) {
        assert_eq!(x.score.final_score, y.score.final_score, "finals must be deterministic");
    }
    for hit in &a.hits {
        let non_hamming = hit.sources.contains(&RecallEvidencePath::LocusBitmap)
            || hit.sources.contains(&RecallEvidencePath::CorpusBm25);
        assert!(
            non_hamming,
            "with hamming nulled, no surviving hit may rely on hamming alone; {} sources={:?}",
            hit.id, hit.sources
        );
    }
}

// (e) frontierK override: applied verbatim within the envelope, clamped outside.
#[test]
fn frontier_k_override_applied_and_clamped() {
    let (coord, h, _) = estate_with_drawers(&CONTENTS);
    let query = "mango fruit recall";

    // Default (limit 10): computed frontier_k = min(max(40, 64), 256) = 64.
    let def = coord
        .recall_scored(&h, hybrid_req(query, None), NOW + 1)
        .expect("recall default");
    assert_eq!(def.plan.frontier_k, 64, "default frontier_k for limit 10 is 64");

    let wide = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(HashMap::new(), Some(200)))), NOW + 1)
        .expect("recall wide");
    assert_eq!(wide.plan.frontier_k, 200, "frontier_k override 200 must be applied");

    let clamped_high = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(HashMap::new(), Some(10_000)))), NOW + 1)
        .expect("recall clamped high");
    assert_eq!(clamped_high.plan.frontier_k, 256, "override above ceiling clamps to 256");

    let clamped_low = coord
        .recall_scored(&h, hybrid_req(query, Some(RecallShape::new(HashMap::new(), Some(1)))), NOW + 1)
        .expect("recall clamped low");
    assert_eq!(clamped_low.plan.frontier_k, 64, "override below floor clamps to 64");
}

// RecallShape unit behaviour: weight() defaults to 1.0; effective_frontier_k clamps.
#[test]
fn recall_shape_accessors() {
    let mut w = HashMap::new();
    w.insert("bm25".to_string(), -2.0);
    w.insert("locus".to_string(), 0.0);
    let shape = RecallShape::new(w, Some(5_000));
    assert_eq!(shape.weight("bm25"), -2.0);
    assert_eq!(shape.weight("locus"), 0.0);
    assert_eq!(shape.weight("hamming"), 1.0, "absent lane key defaults to 1.0");
    assert_eq!(shape.weight("dense:minilm-v6"), 1.0, "absent dense key defaults to 1.0");
    assert_eq!(shape.effective_frontier_k(64), 256, "5000 clamps to ceiling 256");
    assert_eq!(
        RecallShape::new(HashMap::new(), None).effective_frontier_k(128),
        128,
        "None override returns the engine default unchanged"
    );
    assert_eq!(
        RecallShape::new(HashMap::new(), Some(10)).effective_frontier_k(128),
        64,
        "10 clamps up to floor 64"
    );
}
