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
use locus_kit::filter::{HydrationLevel, RecallFrame};
use neuron_kit::{
    rerank, synthesize, ContextDocument, DrawerRow, DrawerRowMeta, RecallFrameTuning, RecallPage,
};

use crate::capability::{shipped_capabilities, verify_capabilities, NeuronKitCapability};
use crate::error::{RecipeRunError, SubstrateError};

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
pub fn run_grounded_synthesis(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    frame: RecallFrame,
    tuning: RecallFrameTuning,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
    cue_terms: &[String],
    cap: Option<usize>,
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
    let drawers = coord
        .recall(handle, full_frame, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

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
    // Lane weights are RECIPE-OWNED when a cue is present: grounding is this
    // recipe's contract, and the default 0.3/0.7 split lets the recency lane
    // override a one-step relevance difference whenever the pool is deep
    // (the recency lane's RRF spread grows with pool size while the
    // adjacent-rank lexical gap stays constant — measured as the trial-2
    // failure: off-topic recent drawers outranked the cue-matched older
    // one). With a cue, ordering must be lexical-dominant and recency
    // strictly a tie-break, which is exactly the 1.0/0.0 weighting (the
    // lexical sort already breaks ties by input order = recency). The
    // caller's rrf_k, mmr_lambda, and page_size still apply; only the lane
    // split is overridden. Twin of the Swift recipe's effectiveTuning.
    let effective_tuning = if cue_terms.is_empty() {
        tuning.clone()
    } else {
        RecallFrameTuning {
            bm25_weight: 1.0,
            vector_weight: 0.0,
            ..tuning.clone()
        }
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
    let context = synthesize(&page, &meta);

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
            run_grounded_synthesis(&coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW, &empty_names(), &[], None)
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
            run_grounded_synthesis(&coord, &h, unconfirmed(), RecallFrameTuning::default(), NOW, &empty_names(), &[], None)
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
}
