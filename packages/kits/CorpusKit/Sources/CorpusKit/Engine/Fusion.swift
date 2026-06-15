// Fusion.swift
//
// Generalized Reciprocal Rank Fusion (RRF) over an arbitrary set of
// per-lane ranked inputs.
//
// Lane E — fusion. Consumes Lane F types (LaneTag, FusedHit) and
// produces a deterministic merged result list. Does NOT depend on
// any specific lane's implementation — vector, BM25, MaxSim, and
// any future lane all plug in as a ranked [(itemID, rank)] list
// tagged with a LaneTag.
//
// Formula (arch spec §5.2):
//   fusedScore(item) = Σ_lane weights[lane] · 1 / (rrfK + rank_lane(item))
// where rank is 1-based (rank 1 = best hit).
//
// Sort order: fusedScore DESC, then itemID ASC (universal tie-break,
// retrieval algorithms reference §0.3 — smaller id wins).
//
// Default weights that match HybridRecall's documented configuration:
//   vectorWeight = 0.6, keywordWeight = 0.4, rrfK = 60
// These are parameters — any caller may supply different values.
//
// Thread-safety: all state is local to the static function; the
// function is fully reentrant and Sendable-safe.
//
// Rust twin: CorpusKit/rust/src/engine/fusion.rs

import Foundation

// MARK: - Fusion

/// Generalized Reciprocal Rank Fusion engine.
///
/// Fuses an arbitrary set of per-lane ranked lists into a single
/// `[FusedHit]` using weighted RRF. Each lane contributes through
/// its weight and the RRF reciprocal of each item's rank in that lane.
/// Items not present in a lane receive no contribution from it.
///
/// The `perLane` field on each `FusedHit` carries the raw input score
/// supplied by the caller for each lane that produced a hit for that
/// item. This lets consumers (dense-first selection, recipe layers)
/// read precomputed per-lane signals without recomputing them.
///
/// Determinism: the fused score computation is pure Float arithmetic
/// over the input ranks and weights. The output sort is
/// (fusedScore DESC, itemID ASC) — total order, reproducible for any
/// fixed input.
public enum Fusion {

    // MARK: - Rank-list overload (primary)

    /// Fuse per-lane ranked lists into a sorted `[FusedHit]`.
    ///
    /// - Parameters:
    ///   - rankedLists: For each lane, an ordered array of
    ///     `(itemID, rank)` pairs. `rank` is 1-based (rank 1 = best
    ///     position). Typically constructed as `(itemID, index + 1)`
    ///     from a pre-sorted result array. Duplicate itemIDs within
    ///     the same lane are automatically deduplicated: only the first
    ///     (best-rank) occurrence is kept. This prevents double-counting
    ///     RRF contributions from the same item appearing twice in a lane.
    ///   - laneScores: Optional per-lane raw-score map used to populate
    ///     `FusedHit.perLane`. Keys that appear in `rankedLists` but
    ///     not in `laneScores` for a given lane produce no `perLane`
    ///     entry for that (item, lane) pair. The fused score is always
    ///     computed from rank regardless of whether a raw score is
    ///     present. Defaults to an empty map (no perLane breakdown).
    ///   - weights: Weight per lane. Lanes absent from `weights` default
    ///     to zero contribution. Weights do not need to sum to 1.
    ///   - rrfK: The RRF smoothing constant. Must be > 0. Cormack et al.
    ///     recommend 60; that value matches `HybridRecallConfiguration.rrfK`.
    /// - Returns: `[FusedHit]` sorted by fusedScore descending, then
    ///   itemID ascending on exact ties.
    public static func fuse(
        rankedLists: [LaneTag: [(itemID: String, rank: Int)]],
        laneScores: [LaneTag: [String: Float]] = [:],
        weights: [LaneTag: Float],
        rrfK: Float = 60
    ) -> [FusedHit] {
        // rrfK must be positive: rrfK + rank is the denominator of the RRF
        // term. rrfK ≤ 0 with rank = 0 would produce division-by-zero or NaN;
        // rrfK < 0 with small rank inverts the ranking. Valid domain: rrfK > 0.
        precondition(rrfK > 0, "rrfK must be > 0 (received \(rrfK)); valid domain is rrfK > 0")

        // Accumulate fused scores keyed by itemID.
        // Separate dictionary for per-lane raw scores to keep the inner
        // loop tight; perLane is populated inside the same pass.
        var fusedScores: [String: Float] = [:]
        var perLaneByItem: [String: [LaneTag: Float]] = [:]

        for (lane, rankedList) in rankedLists {
            let weight = weights[lane] ?? 0
            let rawScores = laneScores[lane]

            // Deduplicate per lane: keep only the first (best-rank) occurrence
            // of each itemID. A duplicate would double-count the RRF contribution
            // for that item within this lane, violating the RRF formula which
            // sums exactly one term per (lane, item) pair (arch spec §5.2).
            var seenInLane: Set<String> = []

            for (itemID, rank) in rankedList {
                // Skip duplicate itemIDs: only the first (best-rank) occurrence
                // contributes one RRF term per lane per item.
                guard seenInLane.insert(itemID).inserted else { continue }

                // RRF term: weight · 1/(rrfK + rank), rank is 1-based.
                // rrfK prevents overweighting of rank-1 results (the
                // smoothing constant from Cormack et al. 2009).
                let rrfTerm = weight / (rrfK + Float(rank))
                fusedScores[itemID, default: 0] += rrfTerm

                // Copy raw lane score into the per-lane breakdown if
                // the caller supplied one. Absence is fine — the fused
                // score is still computed from rank.
                if let rawScore = rawScores?[itemID] {
                    perLaneByItem[itemID, default: [:]][lane] = rawScore
                }
            }
        }

        // Build the result array from the accumulated scores.
        var hits = fusedScores.map { (itemID, score) -> FusedHit in
            FusedHit(
                itemID: itemID,
                fusedScore: score,
                perLane: perLaneByItem[itemID] ?? [:]
            )
        }

        // Sort: fusedScore DESC, itemID ASC on exact ties.
        // The itemID tie-break is the universal rule from retrieval
        // algorithms reference §0.3: "smaller id wins." This matches
        // the existing HybridRecall tie-break on UUID.uuidString.
        hits.sort {
            if $0.fusedScore != $1.fusedScore {
                return $0.fusedScore > $1.fusedScore
            }
            return $0.itemID < $1.itemID
        }

        return hits
    }

    // MARK: - Scored-list overload (convenience)

    /// Fuse per-lane score lists (highest score = rank 1) into `[FusedHit]`.
    ///
    /// A convenience overload for callers that have per-lane scores and
    /// a pre-sorted order rather than pre-computed ranks. The position
    /// within each lane's array (0-based index) becomes the 1-based rank.
    /// The provided order is used as-is — callers are responsible for
    /// sorting their lists before passing (score descending, itemID
    /// ascending on ties, to match the universal tie-break rule).
    /// Duplicate itemIDs within the same lane are deduplicated: the
    /// first occurrence (best rank) is kept, same as the primary overload.
    ///
    /// - Parameters:
    ///   - scoredLists: For each lane, a score-sorted array of
    ///     `(itemID, score)` pairs where higher score is better and
    ///     index 0 corresponds to rank 1.
    ///   - weights: Weight per lane.
    ///   - rrfK: RRF smoothing constant. Must be > 0 (default 60).
    /// - Returns: `[FusedHit]` sorted by fusedScore DESC, itemID ASC.
    public static func fuse(
        scoredLists: [LaneTag: [(itemID: String, score: Float)]],
        weights: [LaneTag: Float],
        rrfK: Float = 60
    ) -> [FusedHit] {
        var rankedLists: [LaneTag: [(itemID: String, rank: Int)]] = [:]
        var laneScores: [LaneTag: [String: Float]] = [:]

        for (lane, scoredList) in scoredLists {
            var ranked: [(itemID: String, rank: Int)] = []
            ranked.reserveCapacity(scoredList.count)
            var rawScores: [String: Float] = [:]
            rawScores.reserveCapacity(scoredList.count)

            for (idx, entry) in scoredList.enumerated() {
                // Position 0 in the array = rank 1.
                ranked.append((itemID: entry.itemID, rank: idx + 1))
                rawScores[entry.itemID] = entry.score
            }

            rankedLists[lane] = ranked
            laneScores[lane] = rawScores
        }

        return fuse(
            rankedLists: rankedLists,
            laneScores: laneScores,
            weights: weights,
            rrfK: rrfK
        )
    }
}
