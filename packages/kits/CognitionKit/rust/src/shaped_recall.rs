//! ShapedRecall — a SINGLE parameterized recall recipe driven by a named
//! RecallShape preset. Rust parity of the Swift `CognitionKit/ShapedRecall.swift`.
//!
//! Rather than ~20 near-identical recipes (one per shape), ShapedRecall takes a
//! preset NAME, resolves it to the GLK `RecallShape` signed-weight vector via
//! `RecallShape::preset`, and runs the estate recall verb through GLK in
//! `.unionBest` / `.matrixAware` with that shape applied. The preset steers WHICH
//! lanes vote and how hard (forward / exclude / suppress / invert) and how deep
//! the candidate frontier runs; the engine math is unchanged (a preset is a
//! weight vector over the existing fusion, never new substrate math).
//!
//! Boundary discipline (B-1/B-2): the recipe holds no substrate state and owns no
//! math. Its only substrate touch is the single GLK `recall_scored` verb. It
//! SEQUENCES — resolve a name to a shape, run one recall, project the hits.
//!
//! The four ARIA filtering adjectives compose ORTHOGONALLY: the preset RANKS, the
//! adjective FILTERS (via the LocusKit filter chain). The recipe takes the filter
//! separately and never folds it into the shape.
//!
//! Determinism: a preset resolves to a pure value (no clock); the recipe takes
//! `now` only for telemetry parity and never reads a clock in the ranking path.

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy, RecallShape,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};

use crate::error::{RecipeRunError, SubstrateError};
use crate::precise_recall::PreciseMatch;
use crate::session_hybrid_fusion;

/// The output of a shaped recall: the ranked matches (sharing the `PreciseMatch`
/// shape with `precise_recall` so the ARIA surface serializes both identically)
/// and the preset name actually applied. Mirrors Swift `ShapedRecall.Output`.
#[derive(Debug, Clone, PartialEq)]
pub struct ShapedRecallOutput {
    /// Up to `limit` matches, in the fused rank order the shaped recall produced.
    pub matches: Vec<PreciseMatch>,
    /// The preset name that was applied. Echoes the requested preset, or
    /// `"balanced"` when an unknown name degraded to unsteered recall.
    pub applied_preset: String,
}

/// Recall `query` with the named RecallShape `preset` applied, returning up to
/// `limit` matches in fused rank order. Mirrors Swift `ShapedRecall.run`.
///
/// - `preset`: a name from `RecallShape::PRESET_NAMES`. `"balanced"` and any
///   unknown name resolve to a `None` shape — unsteered recall, byte-identical to
///   today's `.unionBest`. Callers that need strict validation (the ARIA tool
///   surface) check `PRESET_NAMES` at the boundary; the recipe degrades to
///   balanced, mirroring `precise_recall`'s composition contract.
/// - `filter`: the orthogonal ADJECTIVE constraint (filters; does not rank).
///
/// A recall failure propagates as `RecipeRunError::Substrate`.
pub fn run(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    preset: &str,
    filter: Filter,
    limit: usize,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<ShapedRecallOutput, RecipeRunError> {
    // Resolve the preset NAME to its signed-weight shape. `None` means
    // "balanced / unsteered" (the name "balanced", or an unknown name): the recall
    // runs with no shape, byte-identical to today's `.unionBest`. The applied
    // echo reports "balanced" in that case so the caller sees which shape ran.
    let shape: Option<RecallShape> = RecallShape::preset(preset);
    let applied_preset = if RecallShape::PRESET_NAMES.contains(&preset) {
        preset.to_string()
    } else {
        "balanced".to_string()
    };

    // SESSION_HYBRID: run the shaped recall first (using the bm25/dense/temporal
    // weight vector), then apply SessionHybridFusion temporal-window + speaker-
    // aware boosts as a secondary sort key.
    //
    // Parity note: the Rust port lacks the NeuronKit hybridRecall scored_lane
    // parameter available in Swift. The Rust session_hybrid path instead runs the
    // standard shaped GLK recall (which applies the preset's lane weights) and then
    // applies SessionHybridFusion on the output — preserving OUTPUT parity (same
    // re-ranking semantics) without widening the Rust hybrid_recall signature.
    if preset == "session_hybrid" {
        return run_session_hybrid(
            coord,
            handle,
            query,
            shape,
            filter,
            limit,
            now,
            node_names,
        );
    }

    // Run the estate recall verb through GLK in `.unionBest` / `.matrixAware` —
    // the only mode that activates the full weighted column set (locus, bm25,
    // hamming, dense, fieldFit, coOccurrence, temporal, graph, preference) the
    // preset roster steers. `.full` hydration so each hit carries its body for the
    // projection. The shape passes through unchanged; when `None`, fusion is
    // uniform.
    let frame = RecallFrame {
        filter_chain: vec![filter],
        hydration_level: HydrationLevel::Full,
        limit: Some(limit),
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let request = GLKRecallRequest {
        frame,
        mode: GLKRecallMode::UnionBest,
        scoring: GLKRecallScoring::MatrixAware,
        limit,
        fallback: RecallFallbackPolicy::AllowDegraded,
        query_text: Some(query.to_string()),
        trace_limit: None,
        // Internal origin (the default): a recipe is an internal read, so no
        // recall-trace rows are written (B-10a).
        origin: genius_locus_kit::recall::RecallOrigin::Internal,
        recall_shape: shape,
    };
    let result = coord
        .recall_scored(handle, request, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // Project each hit into a PreciseMatch, preserving the shaped fusion's rank
    // order. `score.final_score` is the fused score the shape produced.
    let matches: Vec<PreciseMatch> = result
        .hits
        .iter()
        .map(|hit| {
            let (room, content) = match &hit.drawer {
                Some(d) => {
                    let (_wing, room) = node_names
                        .get(&d.parent_node_id)
                        .cloned()
                        .unwrap_or_default();
                    (room, d.content.clone())
                }
                None => (String::new(), String::new()),
            };
            PreciseMatch {
                id: hit.id.clone(),
                room,
                content,
                score: hit.score.final_score as f64,
            }
        })
        .collect();

    Ok(ShapedRecallOutput {
        matches,
        applied_preset,
    })
}

/// Session-hybrid recall: shaped GLK recall (bm25/dense/temporal weights) followed
/// by SessionHybridFusion temporal-window + speaker-aware boosts.
///
/// Separated from `run()` to keep the main path readable; same public contract
/// (`ShapedRecallOutput`, no new public surface).
#[allow(clippy::too_many_arguments)]
fn run_session_hybrid(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    shape: Option<RecallShape>,
    filter: Filter,
    limit: usize,
    now: i64,
    node_names: &std::collections::HashMap<String, (String, String)>,
) -> Result<ShapedRecallOutput, RecipeRunError> {
    // Run the shaped GLK recall. We fetch more candidates than `limit` so the
    // fusion post-processing has a complete ranked pool to reorder. The pool
    // is capped at 3× limit minimum 50 — enough for a meaningful re-rank pass.
    let pool_size = (limit * 3).max(50);
    let frame = RecallFrame {
        filter_chain: vec![filter.clone()],
        hydration_level: HydrationLevel::Full,
        limit: Some(pool_size),
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: None,
    };
    let request = GLKRecallRequest {
        frame,
        mode: GLKRecallMode::UnionBest,
        scoring: GLKRecallScoring::MatrixAware,
        limit: pool_size,
        fallback: RecallFallbackPolicy::AllowDegraded,
        query_text: Some(query.to_string()),
        trace_limit: None,
        origin: genius_locus_kit::recall::RecallOrigin::Internal,
        recall_shape: shape,
    };
    let result = coord
        .recall_scored(handle, request, now)
        .map_err(|e| SubstrateError::new("recall_session_hybrid", format!("{e:?}")))?;

    // Extract hydrated Drawers from the hits. Non-hydrated hits (None drawer)
    // are dropped — fusion needs the drawer body for provenance decode.
    let drawers: Vec<locus_kit::drawer::Drawer> = result
        .hits
        .into_iter()
        .filter_map(|hit| hit.drawer)
        .collect();

    // Apply temporal-window + speaker-aware boosts as a secondary sort key.
    let boosted = session_hybrid_fusion::boost(drawers, &filter, query, limit);

    // Project to PreciseMatch.
    let matches: Vec<PreciseMatch> = boosted
        .into_iter()
        .map(|(drawer, score)| {
            let (_wing, room) = node_names
                .get(&drawer.parent_node_id)
                .cloned()
                .unwrap_or_default();
            PreciseMatch {
                id: drawer.id,
                room,
                content: drawer.content,
                score,
            }
        })
        .collect();

    Ok(ShapedRecallOutput {
        matches,
        applied_preset: "session_hybrid".to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::frames::CaptureFrame;

    const NOW: i64 = 1_700_000_000;

    /// Empty node-name map for tests — no display-name resolution needed.
    fn empty_names() -> std::collections::HashMap<String, (String, String)> {
        std::collections::HashMap::new()
    }

    fn coord_with_rows(contents: &[&str]) -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let store: Arc<dyn DrawerStore> = Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        for c in contents {
            let frame = CaptureFrame::new(
                *c,
                CaptureChannel::Typed,
                "history",
                LatticeAnchor::udc("94"),
                "alice",
                "test-v1",
            );
            coord.capture(&h, frame, NOW).unwrap();
        }
        (coord, h)
    }

    // SR-1: a known preset runs over the real GLK recall verb and returns matches
    // in the PreciseMatch shape; the applied preset echoes the request.
    #[test]
    fn sr1_known_preset_runs_and_echoes() {
        let (coord, h) = coord_with_rows(&[
            "the cat sat on the mat",
            "a dog ran in the park",
            "cats and dogs are pets",
        ]);
        let out = run(&coord, &h, "cat", "precise", Filter::CurrentlyBelieve, 10, NOW, &empty_names())
            .expect("run");
        assert_eq!(out.applied_preset, "precise");
        assert!(!out.matches.is_empty(), "the shaped recall surfaces rows");
        // .full hydration means the surfaced matches carry their bodies.
        assert!(out.matches.iter().any(|m| !m.content.is_empty()));
    }

    // SR-2: an unknown preset NAME degrades to balanced at the recipe layer — the
    // recipe never fails on a bad name (the ARIA boundary is where fail-closed
    // validation lives). The applied preset reports "balanced".
    #[test]
    fn sr2_unknown_preset_degrades_to_balanced() {
        let (coord, h) = coord_with_rows(&["alpha beta", "gamma delta"]);
        let out = run(
            &coord,
            &h,
            "alpha",
            "no-such-preset",
            Filter::CurrentlyBelieve,
            10,
            NOW,
            &empty_names(),
        )
        .expect("unknown-name run still succeeds");
        assert_eq!(out.applied_preset, "balanced");
    }

    // SR-3: the balanced preset is unsteered — same applied echo, runs clean.
    #[test]
    fn sr3_balanced_runs_unsteered() {
        let (coord, h) = coord_with_rows(&["one two three", "four five six"]);
        let out = run(&coord, &h, "one", "balanced", Filter::CurrentlyBelieve, 5, NOW, &empty_names())
            .expect("run");
        assert_eq!(out.applied_preset, "balanced");
    }

    // SR-4: every roster preset resolves and runs without panic over a real
    // estate — proves no preset names a lane the engine cannot honour.
    #[test]
    fn sr4_every_preset_runs() {
        let (coord, h) = coord_with_rows(&["alpha", "beta", "gamma"]);
        for name in RecallShape::PRESET_NAMES {
            let out = run(&coord, &h, "alpha", name, Filter::CurrentlyBelieve, 5, NOW, &empty_names())
                .unwrap_or_else(|e| panic!("preset {name} failed: {e:?}"));
            let expected = if RecallShape::PRESET_NAMES.contains(&name) {
                name
            } else {
                "balanced"
            };
            assert_eq!(out.applied_preset, expected);
        }
    }
}
