//! Generalized Reciprocal Rank Fusion (RRF) over an arbitrary set of
//! per-lane ranked inputs.
//!
//! Lane E — fusion. Consumes Lane F types (`LaneTag`, `FusedHit`) and
//! produces a deterministic merged result list. Does NOT depend on any
//! specific lane's implementation — vector, BM25, MaxSim, and any
//! future lane all plug in as a ranked `[(item_id, rank)]` list tagged
//! with a `LaneTag`.
//!
//! Formula (arch spec §5.2):
//!   `fused_score(item) = Σ_lane weights[lane] · 1 / (rrf_k + rank_lane(item))`
//! where rank is 1-based (rank 1 = best hit).
//!
//! Sort order: `fused_score` DESC, then `item_id` ASC (universal
//! tie-break, retrieval algorithms reference §0.3 — smaller id wins).
//!
//! Default weights that match `HybridRecallConfiguration`:
//!   `vector_weight = 0.6`, `keyword_weight = 0.4`, `rrf_k = 60.0`
//! These are parameters — any caller may supply different values.
//!
//! Swift twin: `CorpusKit/Sources/CorpusKit/Engine/Fusion.swift`

use std::collections::HashMap;

use super::sparse_types::{FusedHit, LaneTag};

// MARK: - fuse (primary — ranked lists)

/// Fuse per-lane ranked lists into a sorted `Vec<FusedHit>`.
///
/// # Parameters
/// - `ranked_lists`: For each lane, an ordered slice of
///   `(item_id, rank)` pairs. `rank` is 1-based (rank 1 = best
///   position). Duplicate item IDs within the same lane are
///   automatically deduplicated: only the first (best-rank) occurrence
///   is kept. This prevents double-counting RRF contributions from the
///   same item appearing twice in a lane.
/// - `lane_scores`: Optional per-lane raw-score map used to populate
///   `FusedHit.per_lane`. If `None`, no per-lane breakdown is stored.
///   Entries present in `ranked_lists` but absent from `lane_scores`
///   for that lane produce no `per_lane` entry; the fused score is
///   still computed from rank.
/// - `weights`: Weight per lane. Lanes absent from `weights` default
///   to zero contribution. Weights do not need to sum to 1.
/// - `rrf_k`: The RRF smoothing constant. Must be > 0 (Cormack et al.
///   recommend 60). Panics if `rrf_k <= 0`.
///
/// # Returns
/// `Vec<FusedHit>` sorted by `fused_score` DESC, then `item_id` ASC.
pub fn fuse(
    ranked_lists: &HashMap<LaneTag, Vec<(String, usize)>>,
    lane_scores: Option<&HashMap<LaneTag, HashMap<String, f32>>>,
    weights: &HashMap<LaneTag, f32>,
    rrf_k: f32,
) -> Vec<FusedHit> {
    // rrf_k must be positive: rrf_k + rank is the denominator of the RRF
    // term. rrf_k <= 0 with rank = 0 produces division-by-zero or NaN;
    // rrf_k < 0 with small rank inverts the ranking. Valid domain: rrf_k > 0.
    assert!(rrf_k > 0.0, "rrf_k must be > 0 (received {}); valid domain is rrf_k > 0", rrf_k);

    // Accumulate fused scores and per-lane raw scores keyed by item_id.
    let mut fused_scores: HashMap<String, f32> = HashMap::new();
    let mut per_lane_by_item: HashMap<String, HashMap<LaneTag, f32>> = HashMap::new();

    for (lane, ranked_list) in ranked_lists {
        let weight = weights.get(lane).copied().unwrap_or(0.0);
        let raw_scores = lane_scores.and_then(|ls| ls.get(lane));

        // Deduplicate per lane: keep only the first (best-rank) occurrence
        // of each item_id. A duplicate would double-count the RRF contribution
        // for that item within this lane, violating the RRF formula which
        // sums exactly one term per (lane, item) pair (arch spec §5.2).
        let mut seen_in_lane: std::collections::HashSet<&str> = std::collections::HashSet::new();

        for (item_id, rank) in ranked_list {
            // Skip duplicate item_ids: only the first (best-rank) occurrence
            // contributes one RRF term per lane per item.
            if !seen_in_lane.insert(item_id.as_str()) {
                continue;
            }

            // RRF term: weight · 1/(rrf_k + rank), rank is 1-based.
            // rrf_k prevents overweighting of rank-1 results (the
            // smoothing constant from Cormack et al. 2009).
            let rrf_term = weight / (rrf_k + *rank as f32);
            *fused_scores.entry(item_id.clone()).or_insert(0.0) += rrf_term;

            // Copy raw lane score into the per-lane breakdown if the
            // caller supplied one. Absence is fine — fused score is
            // always computed from rank.
            if let Some(raw_score) = raw_scores.and_then(|rs| rs.get(item_id.as_str())) {
                per_lane_by_item
                    .entry(item_id.clone())
                    .or_default()
                    .insert(*lane, *raw_score);
            }
        }
    }

    // Build the result vector from accumulated scores.
    let mut hits: Vec<FusedHit> = fused_scores
        .into_iter()
        .map(|(item_id, score)| {
            let per_lane = per_lane_by_item.remove(&item_id).unwrap_or_default();
            FusedHit::with_lanes(item_id, score, per_lane)
        })
        .collect();

    // Sort: fused_score DESC, item_id ASC on exact ties.
    // The item_id tie-break is the universal rule from retrieval
    // algorithms reference §0.3: "smaller id wins." This matches the
    // existing HybridRecall tie-break on UUID strings.
    hits.sort_by(|a, b| {
        b.fused_score
            .partial_cmp(&a.fused_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.item_id.cmp(&b.item_id))
    });

    hits
}

// MARK: - fuse_scored (convenience — scored lists)

/// Fuse per-lane score lists (highest score = rank 1) into `Vec<FusedHit>`.
///
/// A convenience wrapper for callers that have per-lane scores and a
/// pre-sorted order rather than pre-computed ranks. The position within
/// each lane's slice (0-based index) becomes the 1-based rank. Callers
/// are responsible for sorting their slices before passing (score
/// descending, item_id ascending on ties). Duplicate item_ids within
/// the same lane are deduplicated via the primary `fuse` function.
///
/// # Parameters
/// - `scored_lists`: For each lane, a score-sorted slice of
///   `(item_id, score)` pairs where higher score is better and index 0
///   corresponds to rank 1.
/// - `weights`: Weight per lane.
/// - `rrf_k`: RRF smoothing constant. Must be > 0.
///
/// # Returns
/// `Vec<FusedHit>` sorted by `fused_score` DESC, then `item_id` ASC.
pub fn fuse_scored(
    scored_lists: &HashMap<LaneTag, Vec<(String, f32)>>,
    weights: &HashMap<LaneTag, f32>,
    rrf_k: f32,
) -> Vec<FusedHit> {
    let mut ranked_lists: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
    let mut lane_scores: HashMap<LaneTag, HashMap<String, f32>> = HashMap::new();

    for (lane, scored_list) in scored_lists {
        let mut ranked: Vec<(String, usize)> = Vec::with_capacity(scored_list.len());
        let mut raw_scores: HashMap<String, f32> = HashMap::with_capacity(scored_list.len());

        for (idx, (item_id, score)) in scored_list.iter().enumerate() {
            // Position 0 in the slice = rank 1.
            ranked.push((item_id.clone(), idx + 1));
            raw_scores.insert(item_id.clone(), *score);
        }

        ranked_lists.insert(*lane, ranked);
        lane_scores.insert(*lane, raw_scores);
    }

    fuse(&ranked_lists, Some(&lane_scores), weights, rrf_k)
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn make_weights(v: f32, k: f32) -> HashMap<LaneTag, f32> {
        let mut m = HashMap::new();
        m.insert(LaneTag::BinaryDense, v);
        m.insert(LaneTag::Sparse, k);
        m
    }

    // ── fuse_scored: single lane ──────────────────────────────────────

    #[test]
    fn single_lane_score_order_preserved() {
        // One lane with three items already sorted. Fusion of a single
        // lane should preserve the input order (score DESC → rank 1,2,3
        // → higher rrf contribution to earlier items).
        let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
        scored.insert(
            LaneTag::Sparse,
            vec![
                ("item-a".to_string(), 3.0),
                ("item-b".to_string(), 2.0),
                ("item-c".to_string(), 1.0),
            ],
        );
        let weights = {
            let mut m = HashMap::new();
            m.insert(LaneTag::Sparse, 1.0_f32);
            m
        };
        let hits = fuse_scored(&scored, &weights, 60.0);
        assert_eq!(hits.len(), 3);
        // item-a had rank 1 → highest RRF → should be first.
        assert_eq!(hits[0].item_id, "item-a");
        assert_eq!(hits[1].item_id, "item-b");
        assert_eq!(hits[2].item_id, "item-c");
    }

    // ── fuse_scored: two lanes ────────────────────────────────────────

    #[test]
    fn two_lane_fusion_merges_hits() {
        // item-a is rank 1 in vector lane only.
        // item-b is rank 1 in keyword lane only.
        // item-c appears in both at rank 2 — should score highest.
        let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
        scored.insert(
            LaneTag::BinaryDense,
            vec![
                ("item-a".to_string(), 10.0),
                ("item-c".to_string(), 5.0),
            ],
        );
        scored.insert(
            LaneTag::Sparse,
            vec![
                ("item-b".to_string(), 8.0),
                ("item-c".to_string(), 4.0),
            ],
        );
        let weights = make_weights(0.6, 0.4);
        let hits = fuse_scored(&scored, &weights, 60.0);

        // item-c is in both lanes at rank 2, so it accumulates from both.
        // item-a is rank 1 in vector (0.6/61 ≈ 0.009836).
        // item-b is rank 1 in keyword (0.4/61 ≈ 0.006557).
        // item-c: 0.6/62 + 0.4/62 = 1.0/62 ≈ 0.016129 — highest.
        let top_id = &hits[0].item_id;
        assert_eq!(top_id, "item-c", "item-c accumulates from both lanes");
        assert_eq!(hits.len(), 3);
    }

    // ── tie-break ─────────────────────────────────────────────────────

    #[test]
    fn tie_break_by_item_id_ascending() {
        // Two items with identical fused scores — tie-break is item_id ASC.
        let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
        scored.insert(
            LaneTag::Sparse,
            vec![
                ("zzz-item".to_string(), 1.0),
                ("aaa-item".to_string(), 1.0),
            ],
        );
        // Identical scores → identical ranks (1 and 2) but different
        // items. To produce a true tie we need both at rank 1 — use two
        // separate lanes each with the same single item at rank 1.
        // Simpler: use fuse() directly with identical fused scores.
        let mut ranked: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
        ranked.insert(
            LaneTag::Sparse,
            vec![("zzz-item".to_string(), 1), ("aaa-item".to_string(), 1)],
        );
        let weights = {
            let mut m = HashMap::new();
            m.insert(LaneTag::Sparse, 1.0_f32);
            m
        };
        let hits = fuse(&ranked, None, &weights, 60.0);
        assert_eq!(hits.len(), 2);
        // Both have identical fused scores (weight/62); tie-break = item_id ASC.
        assert_eq!(hits[0].item_id, "aaa-item");
        assert_eq!(hits[1].item_id, "zzz-item");
    }

    // ── per_lane breakdown ────────────────────────────────────────────

    #[test]
    fn per_lane_scores_populated() {
        let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
        scored.insert(
            LaneTag::BinaryDense,
            vec![("item-x".to_string(), 7.0)],
        );
        scored.insert(
            LaneTag::Sparse,
            vec![("item-x".to_string(), 3.5)],
        );
        let weights = make_weights(0.6, 0.4);
        let hits = fuse_scored(&scored, &weights, 60.0);
        assert_eq!(hits.len(), 1);
        let h = &hits[0];
        assert_eq!(h.item_id, "item-x");
        let vd = h.per_lane.get(&LaneTag::BinaryDense).copied().unwrap_or(0.0);
        let sp = h.per_lane.get(&LaneTag::Sparse).copied().unwrap_or(0.0);
        assert!((vd - 7.0).abs() < 1e-5, "binary dense raw score");
        assert!((sp - 3.5).abs() < 1e-5, "sparse raw score");
    }

    // ── empty inputs ──────────────────────────────────────────────────

    #[test]
    fn empty_lanes_returns_empty() {
        let ranked: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
        let weights: HashMap<LaneTag, f32> = HashMap::new();
        let hits = fuse(&ranked, None, &weights, 60.0);
        assert!(hits.is_empty());
    }

    #[test]
    fn zero_weight_lane_contributes_no_score() {
        // A lane with weight 0 still appears in per_lane but adds
        // nothing to the fused score, so a zero-weight-only corpus
        // returns items with fused_score == 0.
        let mut ranked: HashMap<LaneTag, Vec<(String, usize)>> = HashMap::new();
        ranked.insert(LaneTag::Sparse, vec![("item-z".to_string(), 1)]);
        let weights = {
            let mut m = HashMap::new();
            m.insert(LaneTag::Sparse, 0.0_f32);
            m
        };
        let hits = fuse(&ranked, None, &weights, 60.0);
        assert_eq!(hits.len(), 1);
        assert!((hits[0].fused_score).abs() < 1e-10);
    }

    // ── rrf_k parameter ───────────────────────────────────────────────

    #[test]
    fn rrf_k_zero_amplifies_rank1() {
        // rrf_k = 0: score = weight/rank. rank-1 item is weight times
        // more relevant than rank-2. With rrf_k=60 (default) the
        // difference is smaller. Verifies the parameter flows through.
        let mut scored: HashMap<LaneTag, Vec<(String, f32)>> = HashMap::new();
        scored.insert(
            LaneTag::Sparse,
            vec![("a".to_string(), 2.0), ("b".to_string(), 1.0)],
        );
        let weights = {
            let mut m = HashMap::new();
            m.insert(LaneTag::Sparse, 1.0_f32);
            m
        };
        let hits_large_k = fuse_scored(&scored, &weights, 60.0);
        let hits_small_k = fuse_scored(&scored, &weights, 0.01);

        // In both cases item "a" (rank 1) should beat item "b" (rank 2).
        assert_eq!(hits_large_k[0].item_id, "a");
        assert_eq!(hits_small_k[0].item_id, "a");

        // The ratio score_a/score_b should be larger for small rrf_k
        // because rank-1 dominates more.
        let ratio_large = hits_large_k[0].fused_score / hits_large_k[1].fused_score;
        let ratio_small = hits_small_k[0].fused_score / hits_small_k[1].fused_score;
        assert!(ratio_small > ratio_large, "smaller rrf_k amplifies rank-1 advantage");
    }
}
