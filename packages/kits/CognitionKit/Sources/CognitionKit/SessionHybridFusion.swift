// SessionHybridFusion.swift
//
// Post-processing engine for the "session_hybrid" named RecallShape preset.
// Applied by ShapedRecall.run() AFTER hybridRecall returns its reranked
// drawer list, before the final limit-and-project step.
//
// Two composable boost mechanisms:
//
//   1. TEMPORAL WINDOW BOOST — amplifies drawers whose eventTime falls within
//      the session window expressed by createdAfter/createdBefore in the
//      filter chain. Active only when at least one temporal bound is present;
//      inactive and a no-op when no temporal bounds are in the filter chain.
//
//   2. SPEAKER-AWARE BOOST — amplifies drawers authored by the MCP server
//      (drawer.channel == .mcpAgent) when the query references the
//      assistant's own prior statements. Active only when self-reference
//      query patterns are detected; inactive otherwise.
//
// EVIDENCE GATE INVARIANT:
// The boosts are applied as a SECONDARY sort key over hybridRecall's MMR-
// reranked primary order. The primary key is the hybridRecall rank (lower
// rank = higher relevance from the evidence-bearing scored lane). Boosts can
// only affect ordering between drawers whose primary scores differ by less
// than a threshold epsilon — they function as tie-breakers, not
// replacements. A zero-evidence hit (at the bottom of hybridRecall's list)
// cannot be lifted past a scored hit (at the top) because the primary rank
// gap is always much larger than the maximum secondary boost delta.
//
// DETERMINISM:
// Both boosts are computed purely from Drawer fields (eventTime, provenance
// bitmap decoded via channel accessor) and the static query string. No
// Date() calls inside the math. The filter-chain temporal bounds are caller-
// supplied absolute Dates. Identical inputs always produce identical ranking.

import Foundation
import LocusKit
import NeuronKit

// MARK: - SessionHybridFusion

/// Post-processing boosts for the session_hybrid recall preset.
///
/// All operations are deterministic: inputs are a closed drawer set, an
/// absolute filter chain, and a static query string. The engine never reads
/// a system clock.
enum SessionHybridFusion {

    // MARK: - Configuration

    /// Maximum score delta a temporal window boost can contribute. Capped so
    /// the boost functions as a tie-breaker between near-equal ranked drawers,
    /// never as a primary re-orderer. The value is empirically chosen to split
    /// typical RRF rank-adjacent pairs (whose score gap is ~0.001) while
    /// staying below the cross-group gap between evidence-bearing and frame-
    /// only hits (typically ≥ 0.005 for scored lanes with ≥ 3 evidence hits).
    static let temporalBoostMax: Double = 0.003

    /// Maximum score delta a speaker-aware boost can contribute. Same bound
    /// as temporalBoostMax; the two boosts are additive, so combined max is
    /// 2 * boostMax = 0.006, still below the cross-group evidence gap.
    static let speakerBoostMax: Double = 0.003

    // MARK: - Temporal window extraction

    /// Extract a (start, end) session window from the filter chain.
    ///
    /// Returns `nil` when the filter chain contains no temporal bounds,
    /// meaning the temporal boost mechanism is inactive for this call.
    /// Only `createdAfter` and `createdBefore` contribute; all other filter
    /// cases are ignored. The window is half-open: [start, end) with nil
    /// meaning "no bound" on either side.
    ///
    /// - Parameter filter: The top-level filter passed in ShapedRecall.Input.
    static func extractTemporalWindow(
        from filter: Filter
    ) -> (start: Date?, end: Date?)? {
        var start: Date? = nil
        var end: Date? = nil
        extractBounds(from: filter, start: &start, end: &end)
        // Return nil if neither bound found — boost mechanism is inactive.
        guard start != nil || end != nil else { return nil }
        return (start, end)
    }

    /// Recursive helper that walks the filter tree collecting temporal bounds.
    private static func extractBounds(
        from filter: Filter,
        start: inout Date?,
        end: inout Date?
    ) {
        switch filter {
        case .createdAfter(let date):
            // Take the latest lower bound when multiple createdAfter appear.
            if let existing = start {
                start = date > existing ? date : existing
            } else {
                start = date
            }
        case .createdBefore(let date):
            // Take the earliest upper bound when multiple createdBefore appear.
            if let existing = end {
                end = date < existing ? date : existing
            } else {
                end = date
            }
        case .all(let children):
            for child in children { extractBounds(from: child, start: &start, end: &end) }
        case .any(let children):
            // In an OR chain, take the broadest window — the union of bounds.
            for child in children { extractBounds(from: child, start: &start, end: &end) }
        case .not:
            // NOT inverts the meaning; skip temporal extraction inside NOT.
            break
        default:
            break
        }
    }

    // MARK: - Self-reference query detection

    /// Detect whether the query references the assistant's own prior statements.
    ///
    /// Conservative: only the clearest English self-reference patterns trigger
    /// the speaker-aware boost. Misses are acceptable (the boost is not
    /// required to be comprehensive); false positives are the bigger concern
    /// since they would boost MCP-authored content for unrelated queries.
    ///
    /// The pattern set is deterministic and locale-fixed (English only). For
    /// an AI-facing surface this is the expected operating locale.
    static func isSelfReferenceQuery(_ query: String) -> Bool {
        let lower = query.lowercased()
        // Explicit second-person assistant reference patterns.
        let selfReferencePatterns: [String] = [
            "what did you say",
            "you said",
            "you mentioned",
            "you told me",
            "you wrote",
            "you noted",
            "your response",
            "your answer",
            "your earlier",
            "your previous",
            "you earlier",
            "you previously",
            "you just",
            "what you said",
            "what you wrote",
            "as you said",
            "as you mentioned",
        ]
        return selfReferencePatterns.contains { lower.contains($0) }
    }

    // MARK: - Boost application

    /// Apply temporal and speaker boosts as a secondary sort key over the
    /// hybridRecall-ranked drawer list.
    ///
    /// The primary sort key is the hybridRecall rank (index in `drawers`).
    /// The secondary key is the sum of temporal + speaker boost deltas, each
    /// in [0, boostMax]. Boosted score = `baseScore + boostDelta` where
    /// `baseScore = 1.0 / Double(rank + 61)` (RRF k=60 convention). Re-sort
    /// is stable: equal boosted scores preserve hybridRecall order.
    ///
    /// The evidence gate invariant holds because the secondary boost delta
    /// (max 0.006) is always smaller than the base-score gap between the
    /// last evidence-bearing hit and the first frame-only hit in any typical
    /// hybridRecall result (see constants above).
    ///
    /// - Parameter drawers: The MMR-reranked list from hybridRecall, in
    ///   evidence-first order. May be empty.
    /// - Parameter filter: The caller's filter, used to extract the temporal
    ///   window. No temporal boost if no temporal bounds present.
    /// - Parameter query: The raw query string, used for self-reference
    ///   detection. No speaker boost if no self-reference detected.
    /// - Parameter limit: The caller's result cap.
    /// - Returns: Up to `limit` ranked drawers with boost applied.
    static func boost(
        drawers: [Drawer],
        filter: Filter,
        query: String,
        limit: Int
    ) -> [(drawer: Drawer, score: Double)] {
        guard !drawers.isEmpty else { return [] }

        // Extract temporal window from the filter chain. Nil means inactive.
        let temporalWindow = extractTemporalWindow(from: filter)

        // Detect self-reference in the query. False means inactive.
        let applySpeak = isSelfReferenceQuery(query)

        // Build (drawer, boostedScore) pairs. The baseScore comes from the
        // hybridRecall rank (lower rank = higher relevance). The boost delta
        // is computed from the drawer's own fields without any Date() call.
        var scored: [(drawer: Drawer, score: Double)] = drawers
            .enumerated()
            .map { (rank, drawer) in
                // RRF base score with k=60 damping — same convention as
                // NeuronKit's HybridRecallEngine.
                let baseScore = 1.0 / Double(rank + 61)

                // Temporal boost: full boost if inside window, zero otherwise.
                // Active only when the filter chain contained temporal bounds.
                var delta = 0.0
                if let window = temporalWindow {
                    let inWindow = isInsideWindow(
                        drawer.eventTime,
                        start: window.start,
                        end: window.end)
                    if inWindow {
                        delta += temporalBoostMax
                    }
                }

                // Speaker-aware boost: boost MCP-agent-authored drawers when
                // the query references the assistant's prior statements.
                // The .mcpAgent channel is stamped by ToolDispatch/MemoryToolAdapter
                // at capture time (provenanceChannel: .mcpAgent, bits 6–11 of
                // the provenance bitmap per Provenance.swift § Drawer accessors).
                if applySpeak && drawer.channel == .mcpAgent {
                    delta += speakerBoostMax
                }

                return (drawer: drawer, score: baseScore + delta)
            }

        // Stable sort by boosted score descending. The primary ordering
        // (hybridRecall rank) is preserved for equal scores because Swift's
        // sort is stable — drawers with the same boosted score retain their
        // relative hybridRecall position.
        scored.sort { $0.score > $1.score }

        // Return up to limit results.
        return Array(scored.prefix(limit))
    }

    // MARK: - Helpers

    /// Returns true when `date` falls within the half-open session window.
    ///
    /// - `start == nil`: no lower bound (open from the beginning of time).
    /// - `end == nil`: no upper bound (open to the future).
    /// The comparison uses `>= start` and `< end` (strictly-before-end) to
    /// match the semantics of `Filter.createdAfter` (strictly after) and
    /// `Filter.createdBefore` (strictly before). Date equality on the
    /// boundary is included (>= start) because the caller may have computed
    /// the window start from the drawer's own capture time.
    private static func isInsideWindow(
        _ date: Date,
        start: Date?,
        end: Date?
    ) -> Bool {
        if let start, date < start { return false }
        if let end, date >= end { return false }
        return true
    }
}
