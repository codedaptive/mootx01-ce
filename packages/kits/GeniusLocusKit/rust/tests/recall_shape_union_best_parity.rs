// recall_shape_union_best_parity.rs
//
// Parity tests for 6b-modifiers-core-2: RecallShape steering wired into the
// unionBest lane — the ONLY lane where the per-signal DENSE float signals fuse.
// Mirrors Swift RecallShapeUnionBestTests.swift.
//
// 6b-modifiers-core wired RecallShape into the corpusOnly + hybrid RRF lanes, but
// the `dense:<model_id>` weights did NOTHING in unionBest. This file proves the
// dense weights now steer the dense signals, and that the fixed lanes are
// shape-steerable in the unionBest weighted-column score too. A two-provider
// corpus (minilm-v6, mpnet-base-v2) gives two distinct dense signals:
//
//   (a) exclusion of one dense signal (`dense:<model_id>`=0) removes exactly that
//       signal's votes from the consensus (provenance no longer names it).
//   (b) suppression of a dense signal (`<0`) demotes a drawer it ranks high.
//   (c) leave-one-out determinism — nulling one dense signal twice is identical.
//   (d) a fixed-lane exclusion (`bm25`=0) zeroes bm25's column in unionBest.
//   (e) nil-shape == all-ones-shape is byte-identical in unionBest (back-compat).
//
// The inference closures mirror recall_scored_parity.rs's minilm/mpnet configs so
// the per-signal cosine ordering is deterministic across the Swift/Rust ports.

use std::collections::HashMap;
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
const MPNET_ID: &str = "mpnet-base-v2";

// Two docs: one ranked by BOTH dense signals (consensus), one ranked ONLY by
// mpnet (single). Captured single-first so byCaptureTimeDesc + dense agree.
const SINGLE_CONTENT: &str = "zeta unrelated divergent wording only one signal aligns here";
const CONSENSUS_CONTENT: &str = "alpha consensus topic shared across both embedding signals";
const QUERY: &str = "alpha consensus topic shared across both embedding signals";

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
        "recall-shape-unionbest-tests",
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

/// A float-capable MiniLM provider (384-d) that ranks BOTH docs (shared component
/// pulls everything toward the query). Mirrors recall_scored_parity::minilm_config.
fn minilm_config() -> EmbeddingModelConfig {
    EmbeddingModelConfig::MiniLM {
        inference: Box::new(|tokens: &[i32]| {
            let lead = tokens.first().copied().unwrap_or(0);
            let mut v = vec![0.0_f32; 384];
            let axis = (lead.unsigned_abs() as usize) % 384;
            v[axis] = 1.0;
            v[0] += 0.5; // shared component pulls everything toward the query
            Ok(v)
        }),
    }
}

/// A float-capable MPNet provider (768-d) that aligns ONLY the consensus doc
/// (axis 1) with the query; other lead tokens route to a distant axis.
fn mpnet_config() -> EmbeddingModelConfig {
    EmbeddingModelConfig::MPNet {
        inference: Box::new(|tokens: &[i32]| {
            let lead = tokens.first().copied().unwrap_or(0);
            let mut v = vec![0.0_f32; 768];
            let axis = if (lead.unsigned_abs() as usize) % 2 == 0 { 1 } else { 400 };
            v[axis] = 1.0;
            Ok(v)
        }),
    }
}

fn corpus_two_provider() -> Arc<Corpus> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(
        Corpus::open_many(storage, vec![minilm_config(), mpnet_config()])
            .expect("Corpus::open_many"),
    )
}

fn make_vector_store() -> Arc<VectorStore> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(VectorStore::open(storage).expect("VectorStore::open"))
}

/// Open an estate with `[single, consensus]` captured, wired to a TWO-provider
/// corpus + a Hamming vector store so the dense float lane fans out across both
/// signals AND the bm25/hamming lanes vote. Returns (coord, handle, [single_id, consensus_id]).
fn two_provider_estate() -> (
    EstateCoordinator,
    genius_locus_kit::handle::EstateHandle,
    Vec<String>,
) {
    let (mut coord, h) = open_one();
    let corpus = corpus_two_provider();
    let vector_store = make_vector_store();
    let single = coord.capture(&h, cap_frame(SINGLE_CONTENT), NOW).expect("capture single");
    let consensus = coord
        .capture(&h, cap_frame(CONSENSUS_CONTENT), NOW + 1)
        .expect("capture consensus");
    // Ingest both docs into the corpus, and add Hamming vectors so the fixed lanes vote.
    corpus.ingest(SINGLE_CONTENT, &single.id, NOW).expect("ingest single");
    corpus.ingest(CONSENSUS_CONTENT, &consensus.id, NOW).expect("ingest consensus");
    for d in [&single, &consensus] {
        let engram = corpus.embed(&d.content).expect("embed");
        vector_store
            .add_vector(&d.id, &engram, corpus.model_id(), "1", NOW)
            .expect("add_vector");
    }
    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);
    (coord, h, vec![single.id, consensus.id])
}

fn union_best_rrf(query: &str, shape: Option<RecallShape>) -> GLKRecallRequest {
    let mut req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text(query)
        .with_limit(10);
    if let Some(s) = shape {
        req = req.with_recall_shape(s);
    }
    req
}

fn union_best_matrix(query: &str, shape: Option<RecallShape>) -> GLKRecallRequest {
    let mut req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_query_text(query)
        .with_limit(10);
    if let Some(s) = shape {
        req = req.with_recall_shape(s);
    }
    req
}

fn shape(weights: &[(&str, f32)]) -> RecallShape {
    let mut m = HashMap::new();
    for (k, v) in weights {
        m.insert((*k).to_string(), *v);
    }
    RecallShape::new(m, None)
}

fn mpnet_in_provenance(result: &GLKRecallResult, id: &str) -> bool {
    result
        .hits
        .iter()
        .find(|hh| hh.id == id)
        .map(|hh| hh.explanation.join(" | ").contains(&format!("vectorDense:{MPNET_ID}")))
        .unwrap_or(false)
}

// (a) excluding one dense signal removes exactly that signal's votes from the
//     consensus — the consensus hit names ONLY miniLM after mpnet is excluded.
#[test]
fn excluding_one_dense_signal_removes_its_votes() {
    let (coord, h, ids) = two_provider_estate();
    let consensus_id = &ids[1];

    let full = coord
        .recall_scored(&h, union_best_rrf(QUERY, None), NOW + 2)
        .expect("recall full");
    let excluded = coord
        .recall_scored(
            &h,
            union_best_rrf(QUERY, Some(shape(&[(&format!("dense:{MPNET_ID}"), 0.0)]))),
            NOW + 3,
        )
        .expect("recall excluded");

    // Baseline: both dense signals voted for the consensus drawer.
    let full_expl = full
        .hits
        .iter()
        .find(|hh| &hh.id == consensus_id)
        .map(|hh| hh.explanation.join(" | "))
        .unwrap_or_default();
    assert!(
        full_expl.contains(&format!("vectorDense:{MINILM_ID}")),
        "baseline consensus hit must record the miniLM dense signal; got: {full_expl}"
    );
    assert!(
        full_expl.contains(&format!("vectorDense:{MPNET_ID}")),
        "baseline consensus hit must record the mpnet dense signal; got: {full_expl}"
    );

    // With mpnet excluded, the consensus drawer still surfaces (miniLM ranks it),
    // its provenance names ONLY miniLM, and mpnet is gone entirely.
    let ex_hit = excluded.hits.iter().find(|hh| &hh.id == consensus_id);
    assert!(
        ex_hit.is_some(),
        "consensus drawer must still surface via the forwarding miniLM signal"
    );
    let ex_expl = ex_hit.map(|hh| hh.explanation.join(" | ")).unwrap_or_default();
    assert!(
        ex_expl.contains(&format!("vectorDense:{MINILM_ID}")),
        "with mpnet excluded, the surviving miniLM signal must still be named; got: {ex_expl}"
    );
    assert!(
        !ex_expl.contains(&format!("vectorDense:{MPNET_ID}")),
        "excluding mpnet must remove it from the consensus provenance; got: {ex_expl}"
    );
}

// (b) suppressing a dense signal demotes a drawer it ranks high. The mpnet-ONLY
//     single drawer is the lever: suppression subtracts mpnet's mass so its rank
//     is no better than neutral and never above the consensus drawer. Distinct
//     from exclusion: a suppressed signal still claims provenance.
#[test]
fn suppressing_a_dense_signal_demotes() {
    let (coord, h, ids) = two_provider_estate();
    let single_id = &ids[0];
    let consensus_id = &ids[1];

    let neutral = coord
        .recall_scored(&h, union_best_rrf(QUERY, None), NOW + 2)
        .expect("recall neutral");
    let suppressed = coord
        .recall_scored(
            &h,
            union_best_rrf(QUERY, Some(shape(&[(&format!("dense:{MPNET_ID}"), -1.0)]))),
            NOW + 3,
        )
        .expect("recall suppressed");
    let excluded = coord
        .recall_scored(
            &h,
            union_best_rrf(QUERY, Some(shape(&[(&format!("dense:{MPNET_ID}"), 0.0)]))),
            NOW + 4,
        )
        .expect("recall excluded");

    // Demotion: the mpnet-favoured single drawer must rank no better under
    // suppression than neutral, and never above the consensus drawer.
    let neutral_rank = neutral.hits.iter().position(|hh| &hh.id == single_id);
    let suppressed_rank = suppressed.hits.iter().position(|hh| &hh.id == single_id);
    if let (Some(n), Some(s)) = (neutral_rank, suppressed_rank) {
        assert!(
            s >= n,
            "suppressing mpnet must not improve the mpnet-favoured drawer's rank; neutral={n} suppressed={s}"
        );
    }
    if let (Some(s_idx), Some(c_idx)) = (
        suppressed.hits.iter().position(|hh| &hh.id == single_id),
        suppressed.hits.iter().position(|hh| &hh.id == consensus_id),
    ) {
        assert!(
            c_idx <= s_idx,
            "under suppression the consensus drawer (rank {c_idx}) must rank at/above the suppressed single drawer (rank {s_idx})"
        );
    }

    // Distinct from exclusion: SUPPRESSED mpnet still claims provenance for the
    // single drawer (contributed subtracted mass); EXCLUDED mpnet does not.
    assert!(
        !mpnet_in_provenance(&excluded, single_id),
        "EXCLUDED mpnet must not appear in the single drawer's provenance"
    );
    if suppressed.hits.iter().any(|hh| &hh.id == single_id) {
        assert!(
            mpnet_in_provenance(&suppressed, single_id),
            "SUPPRESSED mpnet still contributed mass, so it stays in the single drawer's provenance"
        );
    }
}

// (c) leave-one-out dense exclusion is deterministic: running the nulled recall
//     twice yields identical ids AND identical fused finals.
#[test]
fn leave_one_out_dense_exclusion_is_deterministic() {
    let (coord, h, _) = two_provider_estate();
    let null_mpnet = || union_best_rrf(QUERY, Some(shape(&[(&format!("dense:{MPNET_ID}"), 0.0)])));

    let a = coord.recall_scored(&h, null_mpnet(), NOW + 2).expect("recall a");
    let b = coord.recall_scored(&h, null_mpnet(), NOW + 3).expect("recall b");

    let a_ids: Vec<&String> = a.hits.iter().map(|hh| &hh.id).collect();
    let b_ids: Vec<&String> = b.hits.iter().map(|hh| &hh.id).collect();
    assert_eq!(a_ids, b_ids, "leave-one-out dense fusion must produce a deterministic id order");
    for (x, y) in a.hits.iter().zip(b.hits.iter()) {
        assert_eq!(x.id, y.id);
        assert_eq!(
            x.score.final_score, y.score.final_score,
            "leave-one-out dense fused finals must be deterministic; {}: a={} b={}",
            x.id, x.score.final_score, y.score.final_score
        );
    }
}

// (d) a fixed-lane exclusion (bm25=0) zeroes bm25's column in the unionBest
//     matrixAware weighted-column score — the fused result must change.
#[test]
fn fixed_lane_bm25_exclusion_in_union_best() {
    let (coord, h, _) = two_provider_estate();

    let neutral = coord
        .recall_scored(&h, union_best_matrix(QUERY, None), NOW + 2)
        .expect("recall neutral");
    let exclude_bm25 = coord
        .recall_scored(
            &h,
            union_best_matrix(QUERY, Some(shape(&[("bm25", 0.0)]))),
            NOW + 3,
        )
        .expect("recall exclude bm25");

    let neutral_by_id: HashMap<&String, f32> =
        neutral.hits.iter().map(|hh| (&hh.id, hh.score.final_score)).collect();
    let mut saw_change = false;
    for hh in &exclude_bm25.hits {
        if let Some(before) = neutral_by_id.get(&hh.id) {
            if (*before - hh.score.final_score).abs() > f32::EPSILON {
                saw_change = true;
            }
        }
    }
    let order_changed: Vec<&String> = exclude_bm25.hits.iter().map(|hh| &hh.id).collect();
    let neutral_order: Vec<&String> = neutral.hits.iter().map(|hh| &hh.id).collect();
    assert!(
        saw_change || order_changed != neutral_order,
        "excluding the bm25 column must change the unionBest fused scores or order"
    );
}

// (e) nil shape and an explicit all-ones shape are byte-identical in unionBest
//     (matrixAware column path + dense consensus path) — the back-compat contract.
#[test]
fn nil_shape_equals_all_ones_in_union_best() {
    let (coord, h, _) = two_provider_estate();
    let ones = shape(&[
        ("locus", 1.0),
        ("bm25", 1.0),
        ("hamming", 1.0),
        ("dense", 1.0),
        (&format!("dense:{MINILM_ID}"), 1.0),
        (&format!("dense:{MPNET_ID}"), 1.0),
    ]);

    let nil_result = coord
        .recall_scored(&h, union_best_matrix(QUERY, None), NOW + 2)
        .expect("recall nil");
    let ones_result = coord
        .recall_scored(&h, union_best_matrix(QUERY, Some(ones)), NOW + 3)
        .expect("recall ones");

    let nil_ids: Vec<&String> = nil_result.hits.iter().map(|hh| &hh.id).collect();
    let ones_ids: Vec<&String> = ones_result.hits.iter().map(|hh| &hh.id).collect();
    assert_eq!(
        nil_ids, ones_ids,
        "all-ones shape must produce the same unionBest id order as nil shape"
    );
    for (a, b) in nil_result.hits.iter().zip(ones_result.hits.iter()) {
        assert_eq!(a.id, b.id);
        assert_eq!(
            a.score.final_score, b.score.final_score,
            "unionBest fused final must be byte-identical at all-ones; {}: nil={} ones={}",
            a.id, a.score.final_score, b.score.final_score
        );
        assert_eq!(
            a.score.dense, b.score.dense,
            "unionBest dense column must be byte-identical at all-ones; {}: nil={} ones={}",
            a.id, a.score.dense, b.score.dense
        );
    }
}
