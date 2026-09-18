//! WalkRecall — escalation-ladder recall recipe.
//!
//! Runs cheap-first stages and stops at the first stage that yields a
//! confident result. Parity of Swift `CognitionKit/WalkRecall.swift`.
//!
//! # Stage order (cascade study § 5, 2026-08-19)
//!
//! - Stage 1: ShapedRecall with the `"session_hybrid"` preset, pool 20.
//!   Cheap, recency-aware; covers the common "I just filed this" query class.
//! - Stage 2: `run_precise_recall` with `"hamming+text"` composition.
//!   Conservative choice covering both factual and paraphrase-leaning queries.
//!
//! # Stop criterion
//!
//! `topGap ≥ 0.25` — the HIGH_MARGIN threshold from `RecallDiscrimination`.
//! Replicated here as `STOP_THRESHOLD` to avoid importing AriaMcpKit. If
//! HIGH_MARGIN changes, update this constant.
//!
//! # Federation status
//!
//! Only the local scope is exercised (`TierAscendingQuery.computeLocal`
//! semantic). Peer/fleet/industry federation is PARKED per the three-features
//! ruling and must not be added without Bob's explicit per-feature approval.
//!
//! # Boundary discipline (B-1/B-2)
//!
//! This recipe holds no substrate state and owns no math. Its only substrate
//! touches are at most two sequential GLK recall calls (one per stage). It
//! SEQUENCES.

use genius_locus_kit::{EstateCoordinator, handle::EstateHandle};
use locus_kit::filter::Filter;
use std::collections::HashMap;

use crate::precise_recall::{run as run_precise_recall, PreciseMatch, DEFAULT_POOL as STAGE2_DEFAULT_POOL};
use crate::shaped_recall::{run as run_shaped, ShapedRecallOutput};

// MARK: - Stage configuration constants

/// Stage 1 preset — session_hybrid is the best keeper for common estate types:
/// recency-aware, low cost, covers the "I just filed this" query class well
/// (cascade study § 5).
pub const STAGE1_PRESET: &str = "session_hybrid";

/// Stage 1 candidate pool — 20 is the cascade study recommendation: large
/// enough for good recall on typical personal estates, small enough to stay
/// cheap. Stage 2 (PreciseRecall) uses its own default pool (30).
pub const STAGE1_POOL: usize = 20;

/// Stage 2 composition — "hamming+text" is the conservative choice (cascade
/// study § 5): covers both factual queries (hamming-dominant) and
/// paraphrase-leaning queries (text-dominant) without pre-judging a winner.
pub const STAGE2_COMPOSITION: &str = "hamming+text";

/// The stop threshold: `topGap` must reach this value for Stage 1 to be
/// considered confident. Matches `RecallDiscrimination.HIGH_MARGIN = 0.25`
/// (AriaMcpKit); replicated here so CognitionKit does not depend on AriaMcpKit.
/// If HIGH_MARGIN changes, update this constant.
pub const STOP_THRESHOLD: f64 = 0.25;

/// Division-by-zero guard matching `RecallDiscrimination.EPS`.
const EPS: f64 = 1e-9;

// MARK: - Output types

/// Which escalation stage produced the final result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WalkStage {
    /// Stage 1: ShapedRecall with the "session_hybrid" preset.
    Stage1SessionHybrid,
    /// Stage 2: PreciseRecall with "hamming+text" composition.
    Stage2PreciseHamming,
}

/// The outcome of a walk-recall run.
#[derive(Debug, Clone)]
pub struct WalkRecallOutcome {
    /// The matches, in the stage's rank order.
    pub matches: Vec<PreciseMatch>,
    /// Which stage produced the final result.
    pub stage: WalkStage,
    /// Whether the ladder stopped early (Stage 1 was confident) or
    /// escalated to Stage 2 (Stage 1 was not confident enough).
    pub stopped_early: bool,
}

// MARK: - Entry point

/// Run the walk-recall escalation ladder.
///
/// Stage 1 (ShapedRecall / session_hybrid, pool 20) runs first. If its
/// top-gap ≥ 0.25, the result is returned immediately (`stopped_early: true`).
/// Otherwise Stage 2 (PreciseRecall / hamming+text) runs and its result is
/// returned (`stopped_early: false`).
///
/// Mirrors Swift `WalkRecall.run(kit:handle:query:filter:limit:now:)`.
///
/// # Parameters
///
/// - `coord`:      the estate coordinator.
/// - `handle`:     the estate to recall against.
/// - `query`:      the search query text (drives BM25 + vector).
/// - `filter`:     the recall filter.
/// - `limit`:      how many ranked matches to return.
/// - `now`:        deterministic instant for telemetry (not used in ranking).
/// - `node_names`: optional pre-loaded node-name map (room display names).
pub fn run(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    filter: Filter,
    limit: usize,
    now: i64,
    node_names: &HashMap<String, (String, String)>,
) -> Result<WalkRecallOutcome, crate::error::RecipeRunError> {
    // MARK: Stage 1 — ShapedRecall with session_hybrid preset, pool stage1Pool.
    //
    // The pool is clamped to at least STAGE1_POOL (20) — the cascade study
    // recommendation — even when `limit` is smaller. The shaped_recall::run
    // signature takes `limit` as the return cap; we pass max(limit, STAGE1_POOL)
    // as the actual limit so the pool is at least 20 candidates wide.
    let stage1_limit = limit.max(STAGE1_POOL);
    let stage1_out: ShapedRecallOutput =
        run_shaped(coord, handle, query, STAGE1_PRESET, filter.clone(), stage1_limit, now, node_names, None)?;

    // Project Stage 1 ShapedRecallOutput (Vec<PreciseMatch>) to WalkMatch scores.
    // The tier-ascending protocol obligation (local scope) is satisfied: the
    // shaped_recall call already routed through the GLK verb surface (B-1).
    // Peer/fleet/industry federation is PARKED — three-features ruling;
    // do not add it without explicit per-feature approval.
    let stage1_scores: Vec<f64> = stage1_out.matches.iter().map(|m| m.score).collect();

    // MARK: Stop criterion — topGap ≥ STOP_THRESHOLD (0.25).
    if is_confident(&stage1_scores) {
        // Stage 1 is confident — take the top `limit` matches and return early.
        let matches = stage1_out.matches.into_iter().take(limit).collect();
        return Ok(WalkRecallOutcome {
            matches,
            stage: WalkStage::Stage1SessionHybrid,
            stopped_early: true,
        });
    }

    // MARK: Stage 2 — PreciseRecall with "hamming+text" composition.
    //
    // Stage 1 did not reach the confidence threshold. Escalate to the
    // precision re-ranker with the "hamming+text" composition (cascade
    // study § 5: covers factual + paraphrase-leaning queries).
    let stage2_matches = run_precise_recall(
        coord,
        handle,
        query,
        filter,
        limit,
        STAGE2_DEFAULT_POOL,
        Some(STAGE2_COMPOSITION),
        now,
        node_names,
    )?;

    Ok(WalkRecallOutcome {
        matches: stage2_matches,
        stage: WalkStage::Stage2PreciseHamming,
        stopped_early: false,
    })
}

// MARK: - Stop criterion helper

/// True when the score list meets the stop criterion (topGap ≥ STOP_THRESHOLD).
///
/// Mirrors Swift `WalkRecall.isConfident(_:)`:
///   topGap = (s0 - s1) / max(|s0|, eps)  ≥  STOP_THRESHOLD (0.25)
///
/// Edge cases (mirrors Swift):
///   - Empty list → NOT confident (escalate): Stage 1 finding nothing is a
///     signal to try harder, not to stop.
///   - Single item → confident (stop): nothing to disambiguate; Stage 2
///     cannot improve on a single-result list.
pub fn is_confident(scores: &[f64]) -> bool {
    if scores.is_empty() {
        // Empty list: Stage 1 found nothing — escalate to Stage 2.
        return false;
    }
    if scores.len() < 2 {
        // Single result: no disambiguation needed — stop.
        return true;
    }
    let s0 = scores[0];
    let s1 = scores[1];
    let denom = s0.abs().max(EPS);
    let top_gap = (s0 - s1) / denom;
    top_gap >= STOP_THRESHOLD
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    // CK-WR-RS-1: empty score list is not confident (escalate).
    #[test]
    fn stop_criterion_empty_is_not_confident() {
        assert!(!is_confident(&[]), "empty list must not be confident");
    }

    // CK-WR-RS-2: single score is confident (stop).
    #[test]
    fn stop_criterion_single_is_confident() {
        assert!(is_confident(&[0.8]), "single result must be confident");
        assert!(is_confident(&[0.0]), "single zero must be confident");
    }

    // CK-WR-RS-3: high topGap (≥ 0.25) → confident.
    #[test]
    fn stop_criterion_high_gap_is_confident() {
        // topGap = (0.9 - 0.6) / 0.9 ≈ 0.333 ≥ 0.25 → confident.
        assert!(is_confident(&[0.9, 0.6, 0.4]));
        // topGap exactly at threshold: (0.8 - 0.6) / 0.8 = 0.25 → confident.
        assert!(is_confident(&[0.8, 0.6]));
    }

    // CK-WR-RS-4: low topGap (below 0.25) → not confident (escalate).
    #[test]
    fn stop_criterion_low_gap_is_not_confident() {
        // topGap = (0.8 - 0.78) / 0.8 = 0.025 < 0.25 → not confident.
        assert!(!is_confident(&[0.8, 0.78, 0.76]));
        // All equal: topGap = 0 → not confident.
        assert!(!is_confident(&[0.5, 0.5, 0.5]));
    }

    // CK-WR-RS-5: parity check — thresholds match Swift constants.
    #[test]
    fn stop_threshold_matches_swift_high_margin() {
        // Swift RecallDiscrimination.HIGH_MARGIN = 0.25.
        assert_eq!(STOP_THRESHOLD, 0.25_f64);
        assert_eq!(EPS, 1e-9_f64);
    }
}
