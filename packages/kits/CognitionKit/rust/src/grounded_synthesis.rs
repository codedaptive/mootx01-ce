//! GroundedSynthesis — the conscious recall recipe, Rust parity of the
//! Swift `GroundedSynthesis.run(...)`. Take a recall frame, recall over the
//! real GLK recall-verb boundary, rerank (NeuronKit RRF/MMR), and synthesize
//! the full recalled set into one `ContextDocument` for foundation-model
//! consumption.
//!
//! This is the cleanest end-to-end through-line in CognitionKit — it proves
//! `SubstrateML/GLK recall → NeuronKit reasoning → CognitionKit recipe` with
//! nothing faked, no COW branches, no proposal rail. Pure conscious recall +
//! synthesis. Now that the Rust GLK recall verb and NeuronKit
//! `rerank`/`synthesize` are real, the recipe RUNS in Rust, matching Swift.
//!
//! Boundary discipline (B-1/B-2): the recipe holds no substrate state. The
//! only substrate read is the GLK `recall` verb; `synthesize` is read-only
//! (NeuronKit C-9) over the rows already materialised.
//!
//! Error surface: the recipe returns `Result<_, RecipeRunError>` — the
//! capability gate fails as `RecipeRunError::Recipe(RecipeError)`, a recall
//! failure propagates as `RecipeRunError::Substrate(SubstrateError)`. This is
//! the Rust encoding of the Swift recipe's heterogeneous untyped `throws`
//! (`RecipeError` stays the closed, parity-gated guard set).

use std::collections::HashMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use intellectus_lib::{report, StatSample};
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
};
use locus_kit::filter::{Filter, HydrationLevel, RecallFrame};
use neuron_kit::{
    rerank, synthesize, ContextDocument, DrawerRow, DrawerRowMeta, RecallFrameTuning, RecallPage,
};

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeError, RecipeRunError, SubstrateError};

// MARK: - Telemetry constants and helpers

/// Stable metric name for recipe-run activity. Mirrors Swift
/// `CognitionKitMetrics.recipeRun`.
pub(crate) const METRIC_RECIPE_RUN: &str = "cognitionkit.recipe.run";

/// Emit a recipe-start metric. `ts` is caller-supplied epoch seconds (f64).
/// When monitoring is disabled, the report! macro argument is never evaluated:
/// off-path cost is a single atomic load + branch.
///
/// Emits cognitionkit.recipe.run with status "start".
#[inline(always)]
pub(crate) fn emit_recipe_start(recipe: &str, ts: f64) {
    // The report! macro short-circuits when Intellectus::is_enabled() is false.
    // The HashMap construction only occurs on the on-path.
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("recipe".to_string(), recipe.to_string());
        tags.insert("status".to_string(), "start".to_string());
        StatSample::metric(METRIC_RECIPE_RUN.to_string(), 1.0, tags, ts)
    });
}

/// Emit a recipe-complete metric. `step_count` is the number of discrete
/// items processed (recalled drawers or benchmarked plans). When monitoring
/// is disabled, zero cost.
///
/// Emits cognitionkit.recipe.run with status "complete" and step_count tag.
#[inline(always)]
pub(crate) fn emit_recipe_complete(recipe: &str, step_count: usize, ts: f64) {
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("recipe".to_string(), recipe.to_string());
        tags.insert("status".to_string(), "complete".to_string());
        tags.insert("step_count".to_string(), step_count.to_string());
        StatSample::metric(METRIC_RECIPE_RUN.to_string(), step_count as f64, tags, ts)
    });
}

/// Wide bound on each grounding lane's pool. The cue predicate (lane A)
/// and the scored search (lane B) both scope hard already; this bound only
/// guards pathological matches. 200 measured tolerable end-to-end (0.1 s
/// rerank after the shingle-cache fix); the user's `cap` bounds what feeds
/// synthesis, not this. Twin of Swift `GroundedSynthesis.groundingPoolBound`.
pub const GROUNDING_POOL_BOUND: usize = 200;

/// Recipe output: the synthesized, provenance-grounded context document and
/// the number of recalled drawers it was grounded on. Mirrors the Swift
/// `GroundedSynthesis.Output`.
#[derive(Debug, Clone, PartialEq)]
pub struct GroundedOutput {
    pub context: ContextDocument,
    pub drawer_count: usize,
}

/// Run GroundedSynthesis against the estate addressed by `handle`. Sequences
/// the GLK recall verb, NeuronKit `rerank`, and `synthesize`. `tuning`
/// defaults via `RecallFrameTuning::default()` (k=60, λ=0.7, page 50); `now`
/// is explicit per the Rust determinism convention.
///
/// `cue_terms` drives the lexical RRF lane: when non-empty, drawers are ranked
/// by distinct-cue-term-match count before synthesis. Empty = input-order
/// recency lane only (previous behaviour, bit-identical).
///
/// `cap` truncates the reranked result BEFORE synthesis so the synthesizer's
/// work is bounded by the user limit, not the pool size. None = no truncation
/// (previous behaviour). The cap is applied after reranking so the most
/// cue-relevant drawers survive, not the most recent.
///
/// `query` is the raw text for the SCORED second lane (BM25 + vector via the
/// GLK UnionBest/Raw request). The scored lane reaches relevant rows that
/// share NO cue terms with the question. None = lexical-only grounding.
pub fn run_grounded_synthesis(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    tuning: RecallFrameTuning,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
    cue_terms: &[String],
    cap: Option<usize>,
    query: Option<&str>,
) -> Result<GroundedOutput, RecipeRunError> {
    run_grounded_synthesis_impl(
        coord, handle, frame, tuning, now, node_names, cue_terms, cap, query, false,
    )
}

/// Variant for read surfaces that must enforce the provenance-sensitivity axis
/// in addition to the RecallFrame adjective-sensitivity gate.
pub fn run_grounded_synthesis_with_provenance_gate(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    tuning: RecallFrameTuning,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
    cue_terms: &[String],
    cap: Option<usize>,
    query: Option<&str>,
) -> Result<GroundedOutput, RecipeRunError> {
    run_grounded_synthesis_impl(
        coord, handle, frame, tuning, now, node_names, cue_terms, cap, query, true,
    )
}

fn run_grounded_synthesis_impl(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    tuning: RecallFrameTuning,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
    cue_terms: &[String],
    cap: Option<usize>,
    query: Option<&str>,
    exclude_provenance_sensitive: bool,
) -> Result<GroundedOutput, RecipeRunError> {
    // B-5: verify capabilities before any substrate touch. A capability gate
    // failure propagates as RecipeRunError::Recipe.
    verify_capabilities(
        &[
            NeuronKitCapability::HybridRecall,
            NeuronKitCapability::Synthesize,
        ],
        &shipped_capabilities(),
    )?;

    // Validate cap before the recipe begins work. Rust's `usize` prevents
    // negative values, so `Some(0)` is the only value that would produce a
    // silent empty synthesis set (`.take(0)` on the reranked pool). Zero
    // drawers fed into the synthesizer yield a vacuous context document;
    // treat it as a caller error consistent with the
    // `TooManyPlans`/`TooManyOriginEntries` guard pattern (reject before
    // any work begins). Mirrors Swift guard for `cap <= 0` where negative
    // values are also possible through the `Int?` public API.
    if let Some(0) = cap {
        return Err(RecipeRunError::Recipe(RecipeError::InvalidCap { value: 0 }));
    }

    // Emit recipe start AFTER the capability gate so we never fire a "start"
    // for an invocation that will immediately throw. `now` is the
    // caller-supplied timestamp — NEVER call a clock inside the engine
    // (Rust parity of Swift determinism convention).
    let start_ts = now as f64;
    emit_recipe_start("grounded_synthesis", start_ts);

    // 1. Recall over the single GLK recall-verb boundary (now real). A recall
    //    failure (e.g. a stale handle) propagates as RecipeRunError::Substrate.
    //
    //    Hydration is forced to Full: synthesis extracts patterns/themes from
    //    drawer BODIES, and per spec § 7.3 a Structured recall returns content
    //    as "" (blob loading is skipped). Synthesizing over structured rows
    //    would silently produce an empty-pattern context — same failure class
    //    as the Contradiction recipe. Mirrors the Swift GroundedSynthesis.
    let mut full_frame = frame;
    full_frame.hydration_level = HydrationLevel::Full;

    // GROUNDED POOL CONSTRUCTION — the recipe owns both lanes (twin of the
    // Swift recipe):
    //   Lane A (lexical): base frame + an OR of ContentMatches predicates
    //   over the cue terms, wide-bounded. Reaches rows that literally
    //   contain a distinctive question word.
    //   Lane B (scored): base frame WITHOUT the cue predicate, driven by
    //   the raw query through the GLK scored search (UnionBest/Raw,
    //   BM25 + vector — the lane PreciseRecall's coarse grab uses).
    //   Reaches relevant rows that share NO question words.
    // Union: scored hits FIRST in their relevance order, then lane-A
    // extras in frame (recency) order, deduplicated by id — the reranker's
    // semantic lane is input order, so this ordering is what makes it mean
    // relevance.
    let grounded = !cue_terms.is_empty();
    let mut lane_a_frame = full_frame.clone();
    let mut scored_rows: Option<Vec<locus_kit::drawer::Drawer>> = None;
    if grounded {
        let pool_bound = cap.unwrap_or(0).max(GROUNDING_POOL_BOUND);
        lane_a_frame.filter_chain.push(Filter::Any(
            cue_terms.iter().map(|t| Filter::ContentMatches(t.clone())).collect(),
        ));
        lane_a_frame.limit = Some(pool_bound);
        if let Some(q) = query {
            let mut lane_b_frame = full_frame.clone();
            lane_b_frame.limit = Some(pool_bound);
            let request = GLKRecallRequest {
                frame: lane_b_frame,
                mode: GLKRecallMode::UnionBest,
                scoring: GLKRecallScoring::Raw,
                limit: pool_bound,
                fallback: RecallFallbackPolicy::AllowDegraded,
                query_text: Some(q.to_string()),
                trace_limit: Some(cap.unwrap_or(tuning.page_size as usize)),
                origin: genius_locus_kit::recall::RecallOrigin::Internal,
                recall_shape: None,
            };
            let result = coord
                .recall_scored(handle, request, now)
                .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
            // SCORING-EVIDENCE GATE (twin of Swift hybridRecall): a lane-B
            // hit that arrived ONLY via the bitmap lane carries no relevance
            // rank — under AllowDegraded the scored request degrades to a
            // bitmap scan whose order is recency, and treating that order as
            // relevance would resurrect the recency-dominance failure. Only
            // hits bearing scoring evidence (BM25 / Hamming / dense cosine)
            // form the relevance lead block; bitmap-only hits are dropped —
            // anything lexically relevant among them arrives via lane A. A
            // hit whose drawer failed hydration is skipped for the same
            // reason as Swift: no body for the synthesizer or term lane.
            use genius_locus_kit::recall::RecallEvidencePath as Ev;
            scored_rows = Some(
                result
                    .hits
                    .into_iter()
                    .filter(|h| {
                        h.sources.iter().any(|s| {
                            matches!(s, Ev::CorpusBm25 | Ev::VectorHamming | Ev::VectorDense)
                        })
                    })
                    .filter_map(|h| h.drawer)
                    .collect(),
            );
        }
    }
    let lane_a = coord
        .recall(handle, lane_a_frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;
    let scored_lead_count = scored_rows.as_ref().map_or(0, |s| s.len());
    let mut drawers: Vec<locus_kit::drawer::Drawer> = match scored_rows {
        Some(scored) => {
            let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
            let mut union = Vec::with_capacity(scored.len() + lane_a.len());
            for d in scored {
                if seen.insert(d.id.clone()) {
                    union.push(d);
                }
            }
            for d in lane_a {
                if seen.insert(d.id.clone()) {
                    union.push(d);
                }
            }
            union
        }
        None => lane_a,
    };
    if exclude_provenance_sensitive {
        drawers.retain(|drawer| {
            !matches!(
                drawer.sensitivity(),
                locus_kit::provenance::Sensitivity::Restricted
                    | locus_kit::provenance::Sensitivity::Secret
            )
        });
    }

    // 2. Project to DrawerRow for rerank, and to per-id metadata for
    //    synthesis. Recalled rows are active, hence currently believed; the
    //    caller's recall frame governs which rows surface.
    let rows: Vec<DrawerRow> = drawers
        .iter()
        .map(|d| DrawerRow {
            id: d.id.clone(),
            content: d.content.clone(),
        })
        .collect();
    let meta_by_id: HashMap<String, DrawerRowMeta> = drawers
        .iter()
        .map(|d| {
            let (wing, room) = node_names
                .get(&d.parent_node_id)
                .cloned()
                .unwrap_or_default();
            (
                d.id.clone(),
                DrawerRowMeta {
                    parent_node_id: d.parent_node_id.clone(),
                    wing,
                    room,
                    is_currently_believed: true,
                },
            )
        })
        .collect();

    // RRF/MMR rerank with the cue-term lexical lane. When cue_terms is
    // non-empty the lexical rank is sorted by distinct-cue-term-match count
    // descending; when empty this is the previous input-order path, bit-identical.
    // Realign metadata to the reranked order so synthesize's index-matched
    // lookups stay correct.
    //
    // RECENCY-SHALL-NOT-DOMINATE invariant (twin of Swift hybridRecall,
    // which owns it there — the rust recipe composes the lanes itself, so
    // the invariant lives here): when cue terms exist but the semantic
    // lane carries no genuine relevance (no scored lane requested, or it
    // degraded to zero evidence-bearing hits), the fusion split must be
    // lexical-dominant — recency strictly a tie-break. The default 0.3/0.7
    // split is honest two-relevance-lane weighting ONLY when the lead
    // block is real (the recency lane's RRF spread grows with pool size
    // while the adjacent-rank lexical gap stays constant — the measured
    // trial-2 failure). rrf_k, mmr_lambda, and page_size always come from
    // the caller.
    let effective_tuning = if grounded && scored_lead_count == 0 {
        RecallFrameTuning {
            bm25_weight: 1.0,
            vector_weight: 0.0,
            ..tuning.clone()
        }
    } else {
        tuning.clone()
    };
    let reranked = rerank(&rows, &effective_tuning, cue_terms);

    // Apply cap BEFORE synthesis so the synthesizer's work is bounded by
    // the user limit, not the pool size. The cap is applied after reranking
    // so the most cue-relevant drawers survive, not the most recent.
    // None = no truncation (previous behaviour).
    let reranked = match cap {
        Some(n) => reranked.into_iter().take(n).collect::<Vec<_>>(),
        None => reranked,
    };

    let meta: Vec<DrawerRowMeta> = reranked
        .iter()
        .map(|r| meta_by_id.get(&r.id).cloned().unwrap_or_default())
        .collect();

    // 3. Synthesize over the (capped, reranked) set as one terminal page
    //    (read-only, C-9 — no estate write).
    let page = RecallPage {
        rows: reranked,
        page_index: 0,
        is_last: true,
    };
    let drawer_count = page.rows.len();
    // Cue-grounded: every ranked survivor must be VISIBLE in the document,
    // so key_insights scales to the synthesized set (trial 3 measured 30/35
    // misses with the answer ranked into the capped set but invisible behind
    // the historical 3-row excerpt). Digest mode keeps the 3-row bound.
    // Twin of the Swift recipe's maxKeyInsights threading.
    let max_key_insights = if cue_terms.is_empty() { 3 } else { drawer_count };
    let context = synthesize(&page, &meta, max_key_insights);

    // Emit recipe complete. drawer_count is finalised before the emit call so
    // the return value is identical whether monitoring is on or off (C-Det
    // conformance: no output dependency on telemetry path).
    emit_recipe_complete("grounded_synthesis", drawer_count, start_ts);

    Ok(GroundedOutput {
        context,
        drawer_count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::error::RecipeError;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering};
    use locus_kit::frames::CaptureFrame;

    const NOW: i64 = 1_700_000_000;

    /// Empty node-name map for tests — no display-name resolution needed.
    fn empty_names() -> std::collections::HashMap<String, (String, String)> {
        std::collections::HashMap::new()
    }

    fn coord_with_rows(contents: &[&str]) -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        for c in contents {
            let frame = CaptureFrame::new(
                *c,
                CaptureChannel::Typed,
                "study",
                LatticeAnchor::udc("0"),
                "alice",
                "test-v1",
            );
            coord.capture(&h, frame, NOW).unwrap();
        }
        (coord, h)
    }

    fn unconfirmed() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        // Structured on purpose: the recipe must OVERRIDE this to Full
        // internally (synthesis reads bodies). Exercises the override path.
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    // GS-1: the through-line RUNS — recall the captured rows over the real
    // GLK verb, rerank, and synthesize into a grounded document. drawer_count
    // equals the recalled set; the document is populated.
    #[test]
    fn gs1_recall_and_synthesize_runs() {
        let (coord, h) = coord_with_rows(&[
            "the cat sat on the mat",
            "a dog ran in the park",
            "cats and dogs are pets",
        ]);
        let out =
            run_grounded_synthesis(&coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW, &empty_names(), &[], None, None)
                .expect("run");
        assert_eq!(out.drawer_count, 3, "all recalled rows feed synthesis");
        assert!(
            !out.context.summary.is_empty(),
            "a grounded document is produced"
        );
        // Active recalled rows are currently believed ⇒ full success rate.
        assert_eq!(out.context.success_rate, 1.0);
    }

    // GS-2: an empty estate recalls nothing; synthesis still yields a
    // well-formed (empty) document — no special-casing, no panic.
    #[test]
    fn gs2_empty_estate_yields_empty_document() {
        let (coord, h) = coord_with_rows(&[]);
        let out =
            run_grounded_synthesis(&coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW, &empty_names(), &[], None, None)
                .expect("run");
        assert_eq!(out.drawer_count, 0);
        assert!(out.context.patterns.is_empty());
    }

    // GS-3: a host missing `synthesize` is rejected with MissingCapability
    // (parity of B-5). The test directly calls `verify_capabilities` rather
    // than running `run_grounded_synthesis` against an instrumented substrate,
    // so it confirms the error variant but does not prove ordering at the recipe
    // boundary.
    #[test]
    fn gs3_capability_gate_blocks_missing_capability() {
        // Directly exercise the gate the recipe runs first: a host offering
        // only hybridRecall cannot satisfy GroundedSynthesis.
        let err = verify_capabilities(
            &[
                NeuronKitCapability::HybridRecall,
                NeuronKitCapability::Synthesize,
            ],
            &[NeuronKitCapability::HybridRecall],
        )
        .unwrap_err();
        assert_eq!(
            err,
            RecipeError::MissingCapability(NeuronKitCapability::Synthesize)
        );
    }

    // GS-4: cap truncates post-rank — the most cue-relevant drawer survives,
    // not the most recent. Twin of Swift capTruncatesAfterRerank.
    #[test]
    fn gs4_cap_truncates_after_rerank() {
        // First captured (oldest): matches all three cue terms.
        // Second and third (newer): match none.
        // With cap=1 the oldest (most cue-relevant) drawer must feed synthesis.
        let (coord, h) = coord_with_rows(&[
            "daguerreotype vintage cameras photography collection", // oldest, 3 matches
            "modern digital exhibition display",                    // newer, 0 matches
            "contemporary art installation space",                  // newest, 0 matches
        ]);
        let cue_terms = vec![
            "daguerreotype".to_string(),
            "vintage".to_string(),
            "cameras".to_string(),
        ];
        let out = run_grounded_synthesis(
            &coord,
            &h,
            unconfirmed(),
            RecallFrameTuning::default(),
            NOW,
            &empty_names(),
            &cue_terms,
            Some(1),
            None,
        )
        .expect("run");

        // cap=1 → exactly one drawer feeds synthesis.
        assert_eq!(out.drawer_count, 1, "cap 1 must truncate to exactly 1 drawer");
        // The surviving drawer is the cue-matched one; its content appears in
        // key_insights (synthesize picks first-row excerpts in stream order).
        let insight = out.context.key_insights.first().cloned().unwrap_or_default();
        assert!(
            insight.contains("daguerreotype"),
            "the cue-relevant drawer must survive the cap; key_insights[0]={insight}"
        );
    }

    // GS-5: the scoring-evidence gate — the DEGRADED contract. This minimal
    // in-memory estate has no scoring providers, so every lane-B hit is
    // bitmap-only (its order is recency, not relevance) and the gate drops
    // them all. Hybrid grounding on such an estate must behave EXACTLY like
    // lexical-only grounding: same single term-matched drawer, term match
    // leading — a degraded scored lane must never smuggle recency ordering
    // in as relevance (the trial-2 failure mode). The LIVE-lane reach
    // guarantee (non-term rows admitted below term matches) is exercised
    // where scoring providers exist: the live product (benchmark trial 5).
    // Twin of Swift scoredLaneDegradedContractEqualsLexicalOnly.
    #[test]
    fn gs5_scored_lane_degraded_contract_equals_lexical_only() {
        let (coord, h) = coord_with_rows(&[
            "daguerreotype vintage cameras photography collection", // matches cue terms
            "modern digital exhibition display",                    // 0 term matches
            "contemporary art installation space",                  // 0 term matches
        ]);
        let cue_terms = vec![
            "daguerreotype".to_string(),
            "vintage".to_string(),
            "cameras".to_string(),
        ];

        let lexical_only = run_grounded_synthesis(
            &coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW,
            &empty_names(), &cue_terms, Some(20), None,
        )
        .expect("lexical-only run");
        let hybrid_degraded = run_grounded_synthesis(
            &coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW,
            &empty_names(), &cue_terms, Some(20),
            Some("daguerreotype vintage cameras"),
        )
        .expect("hybrid run on a no-provider estate");

        assert_eq!(
            hybrid_degraded.drawer_count, lexical_only.drawer_count,
            "a degraded scored lane must not change the pool"
        );
        assert_eq!(
            hybrid_degraded.drawer_count, 1,
            "only the term match feeds synthesis on a degraded estate"
        );
        let first = hybrid_degraded
            .context
            .key_insights
            .first()
            .cloned()
            .unwrap_or_default();
        assert!(
            first.contains("daguerreotype"),
            "the term match must lead; key_insights[0]={first}"
        );
    }

    // GS-6: C2 — zero cap is rejected at the public boundary with
    // `RecipeError::InvalidCap`. Rust's `usize` prevents negative values;
    // `Some(0)` is the problematic value that would otherwise silently produce
    // an empty synthesis set. Mirrors Swift `testZeroCapThrowsInvalidCap`.
    #[test]
    fn gs6_zero_cap_returns_invalid_cap_error() {
        let (coord, h) = coord_with_rows(&[
            "polar bear tracking in the arctic",
            "penguin migration patterns",
        ]);
        let err = run_grounded_synthesis(
            &coord,
            &h,
            unconfirmed(),
            RecallFrameTuning::default(),
            NOW,
            &empty_names(),
            &[],
            Some(0), // zero cap — must be rejected
            None,
        )
        .expect_err("cap=0 must return an error, not succeed");

        assert_eq!(
            err,
            RecipeRunError::Recipe(RecipeError::InvalidCap { value: 0 }),
            "zero cap must raise RecipeError::InvalidCap(value: 0); got: {err}"
        );
    }

    // GS-7: C2 — huge cap (usize::MAX) does not crash. Verifies that the
    // cap path handles values far beyond any realistic pool without overflow
    // or panic (Rust `.take(usize::MAX)` is safe — it returns however many
    // items exist). Twin of Swift `testHugeCapDoesNotCrash`.
    #[test]
    fn gs7_huge_cap_does_not_crash() {
        let (coord, h) = coord_with_rows(&[
            "solar flare event data",
            "coronal mass ejection impact",
        ]);
        let out = run_grounded_synthesis(
            &coord,
            &h,
            unconfirmed(),
            RecallFrameTuning::default(),
            NOW,
            &empty_names(),
            &[],
            Some(usize::MAX), // enormous cap — must not panic
            None,
        )
        .expect("huge cap must not crash");

        // All recalled rows feed synthesis — usize::MAX does not truncate.
        assert_eq!(out.drawer_count, 2, "huge cap must not truncate a small pool");
    }
}
