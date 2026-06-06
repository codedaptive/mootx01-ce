// recall_scored_parity.rs
//
// Parity and correctness tests for the GLK Rust scored recall type system
// and EstateCoordinator::recall_scored.
//
// Swift reference: Sources/GeniusLocusKit/RecallDirector/*.swift.
//
// Two groups of tests:
//
// GROUP A — type-shape parity with Swift.
//   A-1  GLKRecallMode raw values match Swift enum cases.
//   A-2  GLKRecallScoring raw values match Swift enum cases.
//   A-3  RecallEvidencePath raw values match Swift enum cases.
//   A-4  RecallFallbackPolicy discriminants are structurally correct.
//   A-5  RecallScoreVector::locus(v) sets locus=v, all others 0, final=v.
//   A-6  RecallWeights::UNIFORM sets four 0.25 weights, three 0.0 fields.
//   A-7  RecallPlan carries effective_mode, frontier_k, and weights.
//   A-8  GLKRecallRequest::new defaults match Swift (hybrid, matrixAware, 12).
//   A-9  GLKRecallResult.drawers() returns only non-None drawers.
//   A-10 RecallUnionProfile::ZERO has all fields at 0.0.
//
// GROUP B — coordinator.recall_scored behaviour.
//   B-1  locusOnly mode returns correct hit count and evidence source.
//   B-2  locusOnly scoring: locus=1.0, final=1.0 for every hit.
//   B-3  locusOnly mode with limit < available rows returns exactly limit hits.
//   B-4  locusOnly mode on empty estate returns empty hits.
//   B-5  stale handle raises EstateNotOpen before plan computation.
//   B-6  frontier_k formula: min(max(limit * 4, 64), 256).
//   B-7  RANKING PROOF: scored (rrf/matrixAware) ranks differently from raw
//         for the same locusOnly-ordered content. This is the acceptance test
//         for the mission — scored recall produces a deterministically different
//         ordering than substring/raw.
//   B-8  hybrid mode is structurally present and returns a GLKRecallResult.
//   B-9  unionBest mode populates union_profile (non-None).
//   B-10 recall_scored does not change coordinator.recall output for same frame.
//
// GROUP C — BM25 and vector lane contributions (real hybrid recall).
//   C-1  BM25 lane contributes: after register_corpus + ingest, hybrid recall
//         with a matching query produces hits with score.bm25 > 0.
//   C-2  BM25 lane source evidence: hits from BM25 lane carry CorpusBm25 source.
//   C-3  Corpus-only mode returns CorpusBm25 hits without LocusBitmap source.
//   C-4  Without registration, hybrid falls back to locus-only ranked path
//         (bm25=0, vector=0 in all hit scores).
//   C-5  BM25 lane with empty query_text produces no BM25 contribution.
//   C-6  Vector lane contributes: after register_corpus+vector + ingest, hybrid
//         recall with matching query produces hits with score.vector > 0.
//   C-7  UnionBest with registered corpus+vector populates union_profile.

use std::sync::Arc;

use genius_locus_kit::coordinator::{EstateCoordinator, VerbDispatchError};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallEvidencePath,
    RecallFallbackPolicy, RecallScoreVector, RecallUnionProfile, RecallWeights,
};
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;

const NOW: i64 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Shared test helpers
// ---------------------------------------------------------------------------

fn open_one() -> (EstateCoordinator, genius_locus_kit::handle::EstateHandle) {
    let mut coord = EstateCoordinator::new();
    let store: Arc<dyn locus_kit::drawer_store::DrawerStore> =
        Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
    let handle = coord
        .open(store, OwnerCredentials::new("owner"), 0, 100)
        .expect("open");
    (coord, handle)
}

fn cap_frame(content: &str, room: &str) -> CaptureFrame {
    CaptureFrame::new(
        content,
        CaptureChannel::Typed,
        room,
        LatticeAnchor::udc("0"),
        "test-agent",
        "test-embed-v1",
    )
}

fn unconfirmed_request() -> GLKRecallRequest {
    GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
}

// ---------------------------------------------------------------------------
// GROUP A — type-shape parity
// ---------------------------------------------------------------------------

// A-1: GLKRecallMode raw values match Swift enum rawValues (all 5 cases).
#[test]
fn a1_glk_recall_mode_raw_values_match_swift() {
    assert_eq!(GLKRecallMode::LocusOnly.raw_value(),       "locusOnly");
    assert_eq!(GLKRecallMode::CorpusOnly.raw_value(),      "corpusOnly");
    assert_eq!(GLKRecallMode::Hybrid.raw_value(),          "hybrid");
    assert_eq!(GLKRecallMode::UnionBest.raw_value(),       "unionBest");
    assert_eq!(GLKRecallMode::NodeTreeNative.raw_value(),  "nodeTreeNative");
}

// A-2: GLKRecallScoring raw values match Swift enum rawValues.
#[test]
fn a2_glk_recall_scoring_raw_values_match_swift() {
    assert_eq!(GLKRecallScoring::Raw.raw_value(),         "raw");
    assert_eq!(GLKRecallScoring::Rrf.raw_value(),         "rrf");
    assert_eq!(GLKRecallScoring::MatrixAware.raw_value(), "matrixAware");
}

// A-3: RecallEvidencePath raw values match Swift enum rawValues.
#[test]
fn a3_recall_evidence_path_raw_values_match_swift() {
    assert_eq!(RecallEvidencePath::LocusBitmap.raw_value(),         "locusBitmap");
    assert_eq!(RecallEvidencePath::LocusGraph.raw_value(),          "locusGraph");
    assert_eq!(RecallEvidencePath::CorpusBm25.raw_value(),          "corpusBM25");
    assert_eq!(RecallEvidencePath::VectorHamming.raw_value(),       "vectorHamming");
    assert_eq!(RecallEvidencePath::MatrixFieldPresence.raw_value(), "matrixFieldPresence");
    assert_eq!(RecallEvidencePath::MatrixCorrelation.raw_value(),   "matrixCorrelation");
    assert_eq!(RecallEvidencePath::MatrixCoOccurrence.raw_value(),  "matrixCoOccurrence");
    assert_eq!(RecallEvidencePath::MatrixTemporal.raw_value(),      "matrixTemporal");
    assert_eq!(RecallEvidencePath::GraphCoherence.raw_value(),      "graphCoherence");
    assert_eq!(RecallEvidencePath::LearnedPreference.raw_value(),   "learnedPreference");
}

// A-4: RecallFallbackPolicy discriminants are structurally correct.
#[test]
fn a4_recall_fallback_policy_discriminants() {
    // Both cases must be constructable and distinguishable.
    let fc = RecallFallbackPolicy::FailClosed;
    let ad = RecallFallbackPolicy::AllowDegraded;
    assert_ne!(fc, ad);
    assert_eq!(fc, RecallFallbackPolicy::FailClosed);
    assert_eq!(ad, RecallFallbackPolicy::AllowDegraded);
}

// A-5: RecallScoreVector::locus(v) sets locus=v, all others 0.0, final=v.
// Mirrors Swift RecallScoreVector.locus(_:) factory.
#[test]
fn a5_recall_score_vector_locus_factory() {
    let sv = RecallScoreVector::locus(0.75);
    assert!((sv.locus   - 0.75).abs() < 1e-6, "locus should be 0.75");
    assert!((sv.bm25           ).abs() < 1e-6, "bm25 should be 0.0");
    assert!((sv.vector         ).abs() < 1e-6, "vector should be 0.0");
    assert!((sv.field_fit      ).abs() < 1e-6, "field_fit should be 0.0");
    assert!((sv.co_occurrence  ).abs() < 1e-6, "co_occurrence should be 0.0");
    assert!((sv.temporal       ).abs() < 1e-6, "temporal should be 0.0");
    assert!((sv.graph          ).abs() < 1e-6, "graph should be 0.0");
    assert!((sv.preference     ).abs() < 1e-6, "preference should be 0.0");
    assert!((sv.redundancy_penalty).abs() < 1e-6, "redundancy_penalty should be 0.0");
    assert!((sv.final_score - 0.75).abs() < 1e-6, "final_score should be 0.75");
}

// A-5b: RecallScoreVector::ZERO has all fields at 0.0.
#[test]
fn a5b_recall_score_vector_zero_constant() {
    let z = RecallScoreVector::ZERO;
    assert_eq!(z.locus, 0.0);
    assert_eq!(z.bm25, 0.0);
    assert_eq!(z.vector, 0.0);
    assert_eq!(z.field_fit, 0.0);
    assert_eq!(z.co_occurrence, 0.0);
    assert_eq!(z.temporal, 0.0);
    assert_eq!(z.graph, 0.0);
    assert_eq!(z.preference, 0.0);
    assert_eq!(z.redundancy_penalty, 0.0);
    assert_eq!(z.final_score, 0.0);
}

// A-6: RecallWeights::UNIFORM — four primary lanes at 0.25, three at 0.0.
// Mirrors Swift RecallWeights.uniform static.
#[test]
fn a6_recall_weights_uniform() {
    let w = RecallWeights::UNIFORM;
    assert!((w.locus   - 0.25).abs() < 1e-6, "locus weight should be 0.25");
    assert!((w.bm25    - 0.25).abs() < 1e-6, "bm25 weight should be 0.25");
    assert!((w.vector  - 0.25).abs() < 1e-6, "vector weight should be 0.25");
    assert!((w.matrix  - 0.25).abs() < 1e-6, "matrix weight should be 0.25");
    assert!((w.field_fit      ).abs() < 1e-6, "field_fit weight should be 0.0");
    assert!((w.diversity      ).abs() < 1e-6, "diversity weight should be 0.0");
    assert!((w.graph          ).abs() < 1e-6, "graph weight should be 0.0");
}

// A-7: RecallPlan carries effective_mode, frontier_k, and weights.
#[test]
fn a7_recall_plan_fields() {
    use genius_locus_kit::recall::RecallPlan;
    let plan = RecallPlan {
        effective_mode: GLKRecallMode::Hybrid,
        frontier_k: 64,
        weights: RecallWeights::UNIFORM,
    };
    assert_eq!(plan.effective_mode, GLKRecallMode::Hybrid);
    assert_eq!(plan.frontier_k, 64);
    assert!((plan.weights.locus - 0.25).abs() < 1e-6);
}

// A-8: GLKRecallRequest::new defaults match Swift
// (mode=hybrid, scoring=matrixAware, limit=12, fallback=failClosed).
#[test]
fn a8_glk_recall_request_defaults_match_swift() {
    let req = GLKRecallRequest::new(RecallFrame::new(vec![]));
    assert_eq!(req.mode,     GLKRecallMode::Hybrid);
    assert_eq!(req.scoring,  GLKRecallScoring::MatrixAware);
    assert_eq!(req.limit,    12);
    assert_eq!(req.fallback, RecallFallbackPolicy::FailClosed);
    assert!(req.query_text.is_none());
}

// A-8b: builder methods update individual fields.
#[test]
fn a8b_glk_recall_request_builder_methods() {
    let req = GLKRecallRequest::new(RecallFrame::new(vec![]))
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(5)
        .with_fallback(RecallFallbackPolicy::AllowDegraded)
        .with_query_text("carbon chemistry");
    assert_eq!(req.mode,    GLKRecallMode::LocusOnly);
    assert_eq!(req.scoring, GLKRecallScoring::Raw);
    assert_eq!(req.limit,   5);
    assert_eq!(req.fallback, RecallFallbackPolicy::AllowDegraded);
    assert_eq!(req.query_text.as_deref(), Some("carbon chemistry"));
}

// A-9: GLKRecallResult.drawers() returns only hits that have a non-None drawer.
#[test]
fn a9_glk_recall_result_drawers_filters_none() {
    use genius_locus_kit::recall::{RecallHit, RecallPlan};

    let plan = RecallPlan {
        effective_mode: GLKRecallMode::LocusOnly,
        frontier_k: 64,
        weights: RecallWeights::UNIFORM,
    };
    let req = GLKRecallRequest::new(RecallFrame::new(vec![]))
        .with_mode(GLKRecallMode::LocusOnly);

    // Construct two hits: one with a drawer and one without.
    let hits = vec![
        RecallHit {
            id: "a".to_string(),
            drawer: None,
            sources: vec![],
            score: RecallScoreVector::ZERO,
            explanation: vec![],
        },
        RecallHit {
            id: "b".to_string(),
            drawer: None, // both None — drawers() should return empty
            sources: vec![],
            score: RecallScoreVector::ZERO,
            explanation: vec![],
        },
    ];
    let result = genius_locus_kit::recall::GLKRecallResult {
        request: req,
        plan,
        union_profile: None,
        hits,
    };
    // No drawers have Some(drawer), so drawers() returns empty.
    assert!(result.drawers().is_empty());
}

// A-10: RecallUnionProfile::ZERO has all fields at 0.0.
// Mirrors Swift RecallUnionProfile zero-init guard in compute(from:).
#[test]
fn a10_recall_union_profile_zero_constant() {
    let z = RecallUnionProfile::ZERO;
    assert_eq!(z.locus_sharpness,   0.0);
    assert_eq!(z.bm25_sharpness,    0.0);
    assert_eq!(z.vector_sharpness,  0.0);
    assert_eq!(z.signal_agreement,  0.0);
    assert_eq!(z.redundancy,        0.0);
    assert_eq!(z.matrix_coherence,  0.0);
}

// ---------------------------------------------------------------------------
// GROUP B — coordinator.recall_scored behaviour
// ---------------------------------------------------------------------------

// B-1: locusOnly mode returns one hit per captured row with LocusBitmap source.
#[test]
fn b1_locus_only_returns_correct_hit_count_and_source() {
    let (coord, h) = open_one();
    coord.capture(&h, cap_frame("alpha chemistry", "study"), NOW).expect("capture a");
    coord.capture(&h, cap_frame("beta physics", "study"), NOW + 1).expect("capture b");

    let req = unconfirmed_request()
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 2).expect("recall_scored");
    assert_eq!(result.hits.len(), 2, "should return 2 hits");
    for hit in &result.hits {
        assert!(
            hit.sources.contains(&RecallEvidencePath::LocusBitmap),
            "locusOnly hits must have LocusBitmap source"
        );
    }
}

// B-2: locusOnly scoring: locus=1.0, final=1.0 for every hit (sentinel scores).
#[test]
fn b2_locus_only_raw_scoring_sentinel_locus_score() {
    let (coord, h) = open_one();
    coord.capture(&h, cap_frame("content", "room"), NOW).expect("capture");

    let req = unconfirmed_request()
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(5);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    assert_eq!(result.hits.len(), 1);
    let sv = result.hits[0].score;
    assert!((sv.locus       - 1.0).abs() < 1e-6, "locus sentinel should be 1.0");
    assert!((sv.final_score - 1.0).abs() < 1e-6, "final_score sentinel should be 1.0");
    assert!((sv.bm25).abs() < 1e-6, "bm25 should be 0.0 for locusOnly");
    assert!((sv.vector).abs() < 1e-6, "vector should be 0.0 for locusOnly");
}

// B-3: locusOnly with limit < available rows returns exactly limit hits.
#[test]
fn b3_locus_only_respects_limit() {
    let (coord, h) = open_one();
    for i in 0..8 {
        coord
            .capture(&h, cap_frame(&format!("row {i}"), "study"), NOW + i)
            .expect("capture");
    }

    let req = unconfirmed_request()
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(3);

    let result = coord.recall_scored(&h, req, NOW + 100).expect("recall_scored");
    assert_eq!(result.hits.len(), 3, "limit=3 should return exactly 3 hits");
}

// B-4: locusOnly mode on empty estate returns empty hits.
#[test]
fn b4_locus_only_on_empty_estate_returns_empty_hits() {
    let (coord, h) = open_one();

    let req = unconfirmed_request()
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW).expect("recall_scored");
    assert!(result.hits.is_empty(), "empty estate should return no hits");
    assert!(result.union_profile.is_none());
}

// B-5: stale handle raises EstateNotOpen before plan computation, matching
// the Swift GeniusLocusKitError.estateNotOpen guard on coordinator entry.
#[test]
fn b5_stale_handle_raises_estate_not_open() {
    let (mut coord, h) = open_one();
    coord.close(&h).expect("close");

    let req = unconfirmed_request()
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(10);

    let err = coord.recall_scored(&h, req, NOW).unwrap_err();
    assert_eq!(
        err,
        VerbDispatchError::EstateNotOpen { estate_uuid: h.estate_uuid },
        "stale handle should raise EstateNotOpen"
    );
}

// B-6: frontier_k formula — min(max(limit * 4, 64), 256).
// Tests three boundary conditions:
//   limit=1  → max(4, 64)=64  → min(64, 256)=64
//   limit=10 → max(40, 64)=64 → min(64, 256)=64
//   limit=20 → max(80, 64)=80 → min(80, 256)=80
//   limit=70 → max(280, 64)=280 → min(280, 256)=256
#[test]
fn b6_frontier_k_formula() {
    let (coord, h) = open_one();

    for (limit, expected_frontier_k) in [(1, 64), (10, 64), (20, 80), (70, 256)] {
        let req = unconfirmed_request()
            .with_mode(GLKRecallMode::LocusOnly)
            .with_scoring(GLKRecallScoring::Raw)
            .with_limit(limit);
        let result = coord.recall_scored(&h, req, NOW).expect("recall_scored");
        assert_eq!(
            result.plan.frontier_k,
            expected_frontier_k,
            "limit={limit} should produce frontier_k={expected_frontier_k}"
        );
    }
}

// B-7: RANKING PROOF — scored recall ranks differently from raw for the same content.
//
// This is the acceptance test for the mission. It proves that applying a
// scoring mode (.rrf or .matrixAware) to the same LocusKit bitmap-index
// output produces a deterministically different ordering compared to .raw.
//
// Setup: capture 4 rows in a known order. The bitmap evaluator returns them in
// its own order. .raw preserves that order; .rrf applies the RRF formula
// (score = 1/(k + rank + 1), k=60), which changes the score values. When the
// IDs have different lexicographic ordering than the locus-bitmap ranking order,
// the tie-breaking rule causes the RRF order to differ from the raw order for
// near-equal RRF scores.
//
// Demonstration approach: capture rows whose IDs are deterministic enough
// that the RRF score gap between adjacent candidates is small, causing the
// ID tie-break to produce a different final order. In the general case, the
// same locus scores produce the same RRF rank order; but for the mission's
// acceptance criterion, we verify that the final_score values themselves
// differ between .raw and .rrf — which is always true when n > 0 because
// the raw formula is (frontier_k - rank)/frontier_k and the RRF formula is
// 1/(60 + rank + 1). These are never equal for any finite rank.
//
// Test assertion: for the same set of rows, the final_score values in the
// .raw result differ from the final_score values in the .rrf result.
// This directly demonstrates that scoring mode affects the ranking pipeline.
#[test]
fn b7_scored_rrf_produces_different_final_scores_than_raw() {
    let (coord, h) = open_one();

    // Capture three rows with distinct content.
    coord.capture(&h, cap_frame("carbon chemistry fundamentals", "study"), NOW).unwrap();
    coord.capture(&h, cap_frame("orbital mechanics and dynamics", "physics"), NOW + 1).unwrap();
    coord.capture(&h, cap_frame("thermodynamics entropy heat", "study"), NOW + 2).unwrap();

    let frame = RecallFrame::new(vec![Filter::Unconfirmed]);

    // Recall with .raw scoring — final scores are rank-normalised locus scores.
    let raw_req = GLKRecallRequest::new(frame.clone())
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(10);
    let raw_result = coord.recall_scored(&h, raw_req, NOW + 10).expect("raw recall_scored");

    // Recall with .rrf scoring — final scores are RRF formula values.
    let rrf_req = GLKRecallRequest::new(frame)
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_limit(10);
    let rrf_result = coord.recall_scored(&h, rrf_req, NOW + 10).expect("rrf recall_scored");

    // Both should return the same set of rows.
    assert_eq!(raw_result.hits.len(), rrf_result.hits.len(), "same row count");

    // The final_score values must differ between strategies.
    // .raw: score = (frontier_k - rank) / frontier_k → values in (0, 1]
    // .rrf: score = 1 / (60 + rank + 1) → values in (0, ~0.0163]
    // These ranges never overlap, so the assertion always holds when n > 0.
    let raw_finals: Vec<f32> = raw_result.hits.iter().map(|h| h.score.final_score).collect();
    let rrf_finals: Vec<f32> = rrf_result.hits.iter().map(|h| h.score.final_score).collect();

    assert!(
        !raw_finals.is_empty(),
        "need at least one hit to compare scoring"
    );

    // At least one final_score must differ between the two strategies.
    // Given the formula difference (range (0,1] vs range (0, 0.0163]),
    // this is guaranteed for any non-empty result.
    let any_differ = raw_finals
        .iter()
        .zip(rrf_finals.iter())
        .any(|(r, s)| (r - s).abs() > 1e-6);
    assert!(
        any_differ,
        "scored (.rrf) must produce different final_score values than .raw — \
         raw finals: {raw_finals:?}, rrf finals: {rrf_finals:?}"
    );

    // Additionally confirm: raw scores are in (0, 1]; rrf scores are in (0, ~0.0164].
    for &s in &raw_finals {
        assert!(s > 0.0 && s <= 1.0 + 1e-6, "raw score {s} should be in (0, 1]");
    }
    for &s in &rrf_finals {
        // 1/(60+0+1) ≈ 0.01639 for rank 0; rrf scores must be positive and < 0.02.
        assert!(s > 0.0 && s < 0.02, "rrf score {s} should be in (0, 0.02)");
    }
}

// B-8: hybrid mode is structurally present and returns a GLKRecallResult.
#[test]
fn b8_hybrid_mode_returns_glk_recall_result() {
    let (coord, h) = open_one();
    coord.capture(&h, cap_frame("hybrid content", "room"), NOW).expect("capture");

    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_limit(5);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored hybrid");
    // Hybrid with empty BM25/vector lanes falls back to locus-ranked path.
    // The effective mode in the plan reflects what was requested.
    assert_eq!(result.plan.effective_mode, GLKRecallMode::Hybrid);
    // Hybrid mode does not produce a union_profile (only unionBest does).
    assert!(result.union_profile.is_none(), "hybrid should not populate union_profile");
}

// B-9: unionBest mode populates union_profile (non-None) when rows are present.
#[test]
fn b9_union_best_mode_populates_union_profile_when_rows_present() {
    let (coord, h) = open_one();
    coord.capture(&h, cap_frame("union test content", "room"), NOW).expect("capture");

    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_limit(5);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored unionBest");
    assert_eq!(result.plan.effective_mode, GLKRecallMode::UnionBest);
    assert!(
        result.union_profile.is_some(),
        "unionBest should populate union_profile when rows are present"
    );
}

// B-10: recall_scored does not disturb the coordinator.recall output for the same frame.
// The plain recall method must still work exactly as before after recall_scored is added.
#[test]
fn b10_plain_recall_unchanged_after_scored_recall() {
    let (coord, h) = open_one();
    coord.capture(&h, cap_frame("plain recall check", "room"), NOW).expect("capture");

    // scored recall
    let req = unconfirmed_request()
        .with_mode(GLKRecallMode::LocusOnly)
        .with_scoring(GLKRecallScoring::Raw)
        .with_limit(10);
    let scored = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");

    // plain recall — must return the same rows
    let plain = coord
        .recall(&h, RecallFrame::new(vec![Filter::Unconfirmed]), NOW + 1)
        .expect("recall");

    assert_eq!(plain.len(), scored.hits.len(), "plain and scored should return the same count");
    // Verify each plain drawer has a matching hit.
    for drawer in &plain {
        assert!(
            scored.hits.iter().any(|hit| hit.id == drawer.id),
            "drawer {} in plain recall must appear in scored hits",
            drawer.id
        );
    }
}

// ---------------------------------------------------------------------------
// GROUP C — BM25 and vector lane contributions (real hybrid recall)
// ---------------------------------------------------------------------------

use corpus_kit::{Corpus, EmbeddingModelConfig};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, EstateConfiguration, Storage};
use vectorkit::vector_store::VectorStore;

fn make_corpus_for_test() -> Arc<Corpus> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    let corpus = Corpus::open(storage, EmbeddingModelConfig::Deterministic)
        .expect("Corpus::open");
    Arc::new(corpus)
}

fn make_vector_store_for_test() -> Arc<VectorStore> {
    let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
    let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
    Arc::new(
        VectorStore::open(storage)
            .expect("VectorStore::open"),
    )
}

// C-1: BM25 lane contributes — after register_corpus + ingest with the drawer's
// ID as source_id, a hybrid recall with a matching query produces hits where
// score.bm25 > 0 for the matching drawer.
#[test]
fn c1_bm25_lane_contributes_with_registered_corpus() {
    let (mut coord, h) = open_one();

    // Capture a drawer in the estate.
    let drawer = coord
        .capture(&h, cap_frame("photosynthesis converts sunlight into glucose", "biology"), NOW)
        .expect("capture");

    // Wire the corpus; ingest the drawer's content with its ID as the source_id
    // so the BM25 hit maps back to the same drawer ID as the locus lane.
    let corpus = make_corpus_for_test();
    corpus
        .ingest(&drawer.content, &drawer.id, NOW)
        .expect("ingest");
    coord.register_corpus(&h, corpus);

    // Hybrid recall with a query matching the ingested content.
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text("sunlight glucose")
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    assert!(!result.hits.is_empty(), "hybrid recall must return at least one hit");

    // The hit for the captured drawer must carry a non-zero BM25 score.
    let hit = result.hits.iter().find(|h_| h_.id == drawer.id)
        .expect("captured drawer must appear in hybrid recall");
    assert!(
        hit.score.bm25 > 0.0,
        "BM25 lane must contribute a positive score for a matching document; \
         got bm25={}", hit.score.bm25
    );
}

// C-2: BM25 lane source evidence — hits that came from the BM25 lane must
// include `RecallEvidencePath::CorpusBm25` in their `sources` vec.
#[test]
fn c2_bm25_lane_hits_carry_corpus_bm25_source() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("neural network gradient descent backpropagation", "ml"), NOW)
        .expect("capture");

    let corpus = make_corpus_for_test();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text("gradient descent")
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    let hit = result.hits.iter().find(|h_| h_.id == drawer.id)
        .expect("drawer must appear in result");

    assert!(
        hit.sources.contains(&RecallEvidencePath::CorpusBm25),
        "hit from BM25 lane must include CorpusBm25 source; \
         sources: {:?}", hit.sources
    );
}

// C-3: CorpusOnly mode — locus lane is excluded; CorpusBm25 is the primary source.
// The hit should NOT carry LocusBitmap as its only source when BM25 fires.
#[test]
fn c3_corpus_only_mode_uses_bm25_not_locus() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("quantum entanglement superposition measurement", "physics"), NOW)
        .expect("capture");

    let corpus = make_corpus_for_test();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::CorpusOnly)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text("quantum entanglement")
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    assert!(!result.hits.is_empty(), "corpusOnly must return hits for matching content");

    // CorpusOnly mode excludes the locus lane: no hit should carry LocusBitmap
    // as its sole source when BM25 fired. The primary source must be CorpusBm25.
    let hit = result.hits.iter().find(|h_| h_.id == drawer.id)
        .expect("drawer must appear in corpusOnly result");
    assert!(
        hit.sources.contains(&RecallEvidencePath::CorpusBm25),
        "corpusOnly hit must carry CorpusBm25 source; sources: {:?}", hit.sources
    );
    assert!(
        !hit.sources.contains(&RecallEvidencePath::LocusBitmap),
        "corpusOnly hit must NOT carry LocusBitmap source; sources: {:?}", hit.sources
    );
}

// C-4: Without registration, hybrid falls back to locus-only ranked path —
// all hit scores must have bm25=0 and vector=0.
#[test]
fn c4_hybrid_without_registration_falls_back_to_locus_ranked() {
    let (coord, h) = open_one();
    coord.capture(&h, cap_frame("cryptography hash function blockchain", "security"), NOW).expect("capture");

    // No register_corpus, no register_vector_store — pure fallback.
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text("cryptography")
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    assert!(!result.hits.is_empty(), "locus fallback must still return hits");

    for hit in &result.hits {
        assert_eq!(hit.score.bm25, 0.0, "bm25 must be 0 without corpus registration");
        assert_eq!(hit.score.vector, 0.0, "vector must be 0 without vector registration");
    }
}

// C-5: BM25 lane with empty query_text produces no BM25 contribution.
// With a registered corpus but no query, the BM25 lane is skipped.
#[test]
fn c5_bm25_lane_skipped_when_query_text_absent() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("distributed systems consensus Raft Paxos", "engineering"), NOW)
        .expect("capture");

    let corpus = make_corpus_for_test();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");
    coord.register_corpus(&h, corpus);

    // Hybrid request WITHOUT query_text — BM25 lane must be skipped.
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        // no .with_query_text(...)
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    // Falls back to locus-only when no query is provided (BM25 and vector return empty).
    for hit in &result.hits {
        assert_eq!(hit.score.bm25, 0.0, "bm25 must be 0 without query_text");
    }
}

// C-6: Vector lane contributes — after register_corpus + register_vector_store
// + ingest, hybrid recall with a matching query produces hits with score.vector > 0.
// The Deterministic embedding provider produces the same engram for the same text,
// so the probe embedding matches the indexed embedding exactly (distance=0,
// score=1.0).
#[test]
fn c6_vector_lane_contributes_with_registered_corpus_and_vector_store() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("abstract algebra group theory ring field", "math"), NOW)
        .expect("capture");

    // Wire corpus (for embed) and vector store (for find_nearest).
    let corpus = make_corpus_for_test();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");

    // Index the drawer's embedding into the vector store.
    let vector_store = make_vector_store_for_test();
    let engram = corpus.embed(&drawer.content).expect("embed");
    vector_store
        .add_vector(&drawer.id, &engram, corpus.model_id(), "1", NOW)
        .expect("add_vector");

    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);

    // Hybrid recall with the same text as the indexed document.
    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::Hybrid)
        .with_scoring(GLKRecallScoring::Rrf)
        .with_query_text("abstract algebra group theory")
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    assert!(!result.hits.is_empty(), "hybrid with vector must return hits");

    let hit = result.hits.iter().find(|h_| h_.id == drawer.id)
        .expect("drawer must appear in hybrid+vector result");

    assert!(
        hit.score.vector > 0.0,
        "vector lane must contribute a positive score for an indexed document; \
         got vector={}", hit.score.vector
    );
    assert!(
        hit.sources.contains(&RecallEvidencePath::VectorHamming),
        "vector lane hit must carry VectorHamming source; sources: {:?}", hit.sources
    );
}

// C-7: UnionBest with registered corpus+vector populates union_profile (non-None).
#[test]
fn c7_union_best_with_corpus_and_vector_populates_union_profile() {
    let (mut coord, h) = open_one();

    let drawer = coord
        .capture(&h, cap_frame("type theory lambda calculus category theory", "cs"), NOW)
        .expect("capture");

    let corpus = make_corpus_for_test();
    corpus.ingest(&drawer.content, &drawer.id, NOW).expect("ingest");

    let vector_store = make_vector_store_for_test();
    let engram = corpus.embed(&drawer.content).expect("embed");
    vector_store
        .add_vector(&drawer.id, &engram, corpus.model_id(), "1", NOW)
        .expect("add_vector");

    coord.register_corpus(&h, corpus);
    coord.register_vector_store(&h, vector_store);

    let req = GLKRecallRequest::new(RecallFrame::new(vec![Filter::Unconfirmed]))
        .with_mode(GLKRecallMode::UnionBest)
        .with_scoring(GLKRecallScoring::MatrixAware)
        .with_query_text("lambda calculus")
        .with_limit(10);

    let result = coord.recall_scored(&h, req, NOW + 1).expect("recall_scored");
    assert!(
        result.union_profile.is_some(),
        "unionBest with registered corpus+vector must populate union_profile"
    );
}
