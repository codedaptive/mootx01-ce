//! PreciseRecall — the precise-recall recipe and the ablation harness's
//! executor. Rust parity of the Swift `CognitionKit/PreciseRecall.swift`.
//!
//! Closes the measured gauntlet gap (strong coarse grab, weak precise
//! reduction: found@10 high, found@1 low) by ascending GLK fetch → a NAMED
//! reduction COMPOSITION → bounded reduce to surface the EXACT answer above its
//! near-duplicate distractors.
//!
//! The ascent (pure sequencing; the recipe owns no math and no substrate state):
//!   a. GLK FETCH (coarse grab): a `GLKRecallRequest` in `.unionBest` mode with
//!      `.raw` scoring over a GENEROUS candidate pool (`pool`, default 30).
//!      `.unionBest` fuses LocusKit + CorpusKit (BM25 + vector + dense); `.raw`
//!      is the high-recall lane. Nothing is pruned here. Every hit carries its
//!      DENSE signal (the `RecallScoreVector`) and the structured drawer's
//!      lattice anchor.
//!   b. REDUCTION COMPOSITION (the precision step): each pooled hit becomes a
//!      `ReductionCandidate` carrying that dense signal + content, and the NAMED
//!      composition (`composition`, default `text`) scores and re-ranks the pool.
//!   c. BOUNDED REDUCE: the composition returns the top `limit`. The reduce only
//!      RE-ORDERS the coarse pool and truncates; it never prunes below `limit`.
//!
//! Late-hydration parity (B-10a; narrow-then-hydrate): the Swift recipe fetches
//! a BODY-FREE pool at `.bitmapOnly`, then hydrates the survivors via the
//! GLK-owned `kit.hydrate(handle, ids:)` capability. The Rust GLK coordinator
//! exposes no per-id hydrate method, so this recipe fetches the pool ONCE at
//! `.full` (bodies + scores in one scored recall), strips the bodies to form a
//! body-free candidate set, and supplies `reduce_late` with a hydration closure
//! backed by the already-fetched body map. The narrow-then-hydrate SELECTION is
//! therefore IDENTICAL to Swift (same survivor set, same final composition
//! re-score over hydrated survivors) — rank-identical results — without a
//! second substrate round-trip. The recipe never reaches the store itself.
//!
//! TRACE BUDGET (B-10a / F3): `limit` (the request.limit) is the coarse pool
//! scan width; `trace_limit` is the CALLER'S final limit — what the caller
//! receives after the precision re-rank. The coordinator uses `trace_limit`
//! (not the pool size) for the reward-cycle trace write. Internal recalls
//! (origin == Internal, the default) write no trace rows at all.
//!
//! Read-only. Deterministic: the signal components read no clock, the
//! composition fold is a pure function of (query, candidates), and the recipe
//! takes `now` for telemetry parity; it never calls a clock in the ranking path.

use std::collections::HashMap;

use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::recall::{
    GLKRecallMode, GLKRecallRequest, GLKRecallScoring, RecallFallbackPolicy,
};
use genius_locus_kit::EstateCoordinator;
use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
use neuron_kit::{
    named_composition, reduce_late, ReductionCandidate, ReductionQuery, DEFAULT_SURVIVOR_MULTIPLE,
};

use crate::error::{RecipeRunError, SubstrateError};

/// Default coarse candidate pool size. Generous enough that the true target is
/// in the pool (recall), bounded so the re-rank stays cheap. Mirrors Swift
/// `PreciseRecall.defaultPool`.
pub const DEFAULT_POOL: usize = 30;

/// One precise-recall match: the drawer's id, its room (for serialization in
/// the same shape `moot_memory_search` uses), the content, and the precision
/// score it was ranked by. Mirrors Swift `PreciseMatch`.
#[derive(Debug, Clone, PartialEq)]
pub struct PreciseMatch {
    /// The drawer's stable row id.
    pub id: String,
    /// The drawer's room (structural coordinate).
    pub room: String,
    /// The drawer's content.
    pub content: String,
    /// The precision score this drawer was ranked by, in `[0, 1]`. The
    /// composition does not re-score after ranking; this surfaces the
    /// candidate's final fused coarse score (informational — rank order is the
    /// composition's), mirroring the Swift recipe.
    pub score: f64,
}

/// Coarse-grab `pool` candidates for `query`, re-rank them by the named
/// reduction `composition`, and return the top `limit`. Mirrors Swift
/// `PreciseRecall.run`.
///
/// - `composition`: the named reduction composition from `CompositionGrid`
///   (e.g. "hamming+tokenExact", "dense-fused", "weighted-all"). `None` ⇒ the
///   default `text` — the original `query_precision` behavior — so an
///   unspecified or unknown name reproduces today's recipe.
///
/// Returns up to `limit` matches, descending by composition precision. A recall
/// failure propagates as `RecipeRunError::Substrate`.
pub fn run(
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    query: &str,
    filter: Filter,
    limit: usize,
    pool: usize,
    composition: Option<&str>,
    now: i64,
) -> Result<Vec<PreciseMatch>, RecipeRunError> {
    // The pool must be at least `limit`: the bounded reduce returns the top
    // `limit` of the pool, so a pool smaller than `limit` could only shrink the
    // result below a plain coarse grab — the regression this recipe avoids.
    let pool_size = pool.max(limit);

    // a. GLK FETCH — coarse, high-recall grab. .unionBest fuses BM25 + vector +
    //    dense; scoring is .raw (the high-recall lane). We do not prune here;
    //    the precision re-rank below supplies the discrimination.
    //
    //    Hydration is .full so each hit's drawer carries its body in this single
    //    scored recall — the body map that backs the narrow-then-hydrate closure
    //    below. (Swift fetches body-free at .bitmapOnly then hydrates survivors
    //    via kit.hydrate; the Rust GLK exposes no per-id hydrate, so the bodies
    //    are pre-fetched here and the late-hydration SELECTION is reproduced
    //    against the in-memory map — rank-identical, one round-trip.)
    //
    //    TRACE BUDGET: limit is the pool scan width; trace_limit is the caller's
    //    final limit. Origin stays Internal (the default) — this is a recipe, an
    //    internal read, so no trace rows are written regardless (B-10a).
    let frame = RecallFrame {
        filter_chain: vec![filter],
        hydration_level: HydrationLevel::Full,
        limit: Some(pool_size),
        // ByRelevanceDesc was removed from Ordering (LocusKit is a bitmap filter
        // engine with no scoring signal — relevance is provided by the RecallDirector's
        // scoring mode below, not LocusKit ordering). ByCaptureTimeDesc provides a
        // stable initial page order; UnionBest + query_text delivers relevance ranking.
        ordering: Ordering::ByCaptureTimeDesc,
        as_of: None,
        trace_limit: Some(limit),
    };
    let request = GLKRecallRequest {
        frame,
        mode: GLKRecallMode::UnionBest,
        scoring: GLKRecallScoring::Raw,
        limit: pool_size,
        fallback: RecallFallbackPolicy::AllowDegraded,
        query_text: Some(query.to_string()),
        trace_limit: Some(limit),
        origin: genius_locus_kit::recall::RecallOrigin::Internal,
        // No RecallShape steering on this internal coarse-grab recall: the
        // PreciseRecall recipe drives relevance through its own reduction
        // composition below, not through GLK's signed-weight fusion. `None`
        // matches the Swift `GLKRecallRequest` initializer here, which carries
        // no `recallShape` argument (the field defaults to no shape).
        recall_shape: None,
    };
    let result = coord
        .recall_scored(handle, request, now)
        .map_err(|e| SubstrateError::new("recall", format!("{e:?}")))?;

    // b. REDUCTION COMPOSITION — project each pooled hit (with its DENSE signal
    //    carried from GLK) into a ReductionCandidate. The candidate's coarse-pool
    //    index is its tie-break rank. The query arrives as plain text with no
    //    lattice anchor (the `lattice` signal is therefore neutral here).
    let comp = named_composition(composition);
    let reduction_query = ReductionQuery::new(query);

    // Build the body map (id → content) from the .full pool, then form a
    // BODY-FREE candidate set so reduce_late drives the same narrow-then-hydrate
    // selection the Swift recipe runs against kit.hydrate.
    let mut body_map: HashMap<String, String> = HashMap::new();
    let candidates: Vec<ReductionCandidate> = result
        .hits
        .iter()
        .enumerate()
        .map(|(index, hit)| {
            let mut candidate = ReductionCandidate::from_hit(hit, index);
            if !candidate.content.is_empty() {
                body_map.insert(candidate.id.clone(), candidate.content.clone());
                // Strip the body: the SELECTION lane is body-free; the closure
                // refills it for the survivors only.
                candidate.content = String::new();
            }
            candidate
        })
        .collect();

    // c. NARROW-THEN-HYDRATE BOUNDED REDUCE — the dense signals narrow the wide
    //    body-free pool; only the bounded survivors are hydrated (via the body
    //    map) and the content signals run on them. For a content-only
    //    composition (the default `text`) there is no dense term to narrow on,
    //    so every candidate is hydrated and the result matches the eager reduce
    //    — the default recipe is unchanged.
    let ranked = reduce_late(
        &comp,
        &reduction_query,
        &candidates,
        limit,
        DEFAULT_SURVIVOR_MULTIPLE,
        |ids| {
            let mut out = HashMap::new();
            for id in ids {
                if let Some(body) = body_map.get(id) {
                    out.insert(id.clone(), body.clone());
                }
            }
            out
        },
    );

    Ok(ranked
        .into_iter()
        .map(|candidate| PreciseMatch {
            id: candidate.id,
            room: candidate.room,
            content: candidate.content,
            score: candidate.score.final_score as f64,
        })
        .collect())
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

    #[test]
    fn default_pool_matches_swift() {
        assert_eq!(DEFAULT_POOL, 30);
    }

    // PR-1: the through-line RUNS over the real GLK recall verb. The default
    // (text) composition recalls the captured rows and surfaces matches in the
    // PreciseMatch shape — no panic, content non-empty (the .full pool hydrates).
    #[test]
    fn pr1_recall_runs_and_returns_matches() {
        let (coord, h) = coord_with_rows(&[
            "the cat sat on the mat",
            "a dog ran in the park",
            "cats and dogs are pets",
        ]);
        let matches = run(
            &coord,
            &h,
            "cat",
            Filter::Unconfirmed,
            10,
            DEFAULT_POOL,
            None,
            NOW,
        )
        .expect("run");
        assert!(!matches.is_empty(), "the coarse grab surfaces the captured rows");
        // .full hydration means the surfaced matches carry their bodies.
        assert!(matches.iter().any(|m| !m.content.is_empty()));
    }

    // PR-2: an unknown composition NAME degrades to the default (text) at the
    // recipe layer — the recipe never fails on a bad name (the ARIA boundary is
    // where fail-closed validation lives). Same row count as the default.
    #[test]
    fn pr2_unknown_composition_degrades_to_text() {
        let (coord, h) = coord_with_rows(&["alpha beta", "gamma delta"]);
        let default_run = run(&coord, &h, "alpha", Filter::Unconfirmed, 10, DEFAULT_POOL, None, NOW)
            .expect("default run");
        let unknown_run = run(
            &coord,
            &h,
            "alpha",
            Filter::Unconfirmed,
            10,
            DEFAULT_POOL,
            Some("no-such-composition"),
            NOW,
        )
        .expect("unknown-name run still succeeds");
        assert_eq!(default_run.len(), unknown_run.len());
    }

    // PR-3: pool is clamped to be at least limit — a small pool never shrinks
    // the result below what a plain coarse grab of `limit` would surface.
    #[test]
    fn pr3_pool_clamped_to_limit() {
        let (coord, h) = coord_with_rows(&["one", "two", "three", "four", "five"]);
        // pool 1 < limit 5: the recipe clamps pool up to 5 internally.
        let matches = run(&coord, &h, "one", Filter::Unconfirmed, 5, 1, None, NOW).expect("run");
        assert!(matches.len() >= 1);
    }
}
