import Foundation

// DegeneracyGuard.swift — the fail-loud degeneracy guard (SPEC §9).
//
// Before any recall/quality comparison is published, the tool probes each
// backend with ≥3 distinct queries and feeds the returned rankings here.
// The guard is a pure, deterministic scorer over already-fetched responses —
// no live server contact, no `Date()`, no side effects — so it is fully
// unit-testable and conformance-vector-ready for the Rust leg.
//
// A non-.healthy verdict REFUSES the comparison (caller exits non-zero and
// does NOT emit a published number).
//
// Thresholds default conservative: a false refusal costs a re-run; a false
// publish costs a wrong product decision. `invarianceThreshold` is the maximum
// mean pairwise divergence below which rankings are considered "the same".
// Below 0.05 on BOTH Jaccard + rank axes simultaneously is very conservative
// and matches the FINDINGS observation (divergence ≈ 0.0 across all pairs).

/// A verdict on whether a backend is being driven in a way that makes its
/// recall/quality numbers trustworthy.
extension DegeneracyGuard {
    enum Verdict: Sendable {
        /// Backend looks healthy — all invariance checks passed.
        case healthy
        /// Backend returned essentially the same ranking for every probe query
        /// regardless of the query content — the query-invariant frozen-ranking
        /// failure mode documented in FINDINGS-2026-06-07.
        case queryInvariant(diagnostic: String)
        /// Backend returned a "found N" count alongside a no-results/fallback
        /// hint — the results are likely a degraded fallback, not real recall.
        case degradedFallback(diagnostic: String)
        /// Confirmation round-trip contradicts the recall score (confirmedCount=0
        /// with recall ≈ 1.0) — the number cannot be trusted until the
        /// confirmation path is verified.
        case confirmationContradiction(diagnostic: String)

        /// A human-readable explanation of the verdict, suitable for stderr.
        var diagnostic: String {
            switch self {
            case .healthy:
                return "backend is healthy — rankings vary across probe queries"
            case .queryInvariant(let d):
                return d
            case .degradedFallback(let d):
                return d
            case .confirmationContradiction(let d):
                return d
            }
        }
    }
}

/// The fail-loud degeneracy guard.
///
/// Pure scorer: caller issues probes; guard receives already-fetched rankings.
/// No `Date()`, no randomness, no networking inside this type.
struct DegeneracyGuard: Sendable {

    /// Maximum mean pairwise divergence (Jaccard OR rank) below which two
    /// rankings are considered "the same". At 0.05 a backend must return
    /// meaningfully different result sets (>5% new or reordered items) for
    /// at least one probe pair before we call it healthy.
    var invarianceThreshold: Double = 0.05

    /// Minimum recall score above which a confirmed-count of 0 is considered
    /// a contradiction.
    var confirmationRecallFloor: Double = 0.5

    // MARK: - query-invariance check

    /// Classifies a set of probe rankings as `.queryInvariant` or `.healthy`.
    ///
    /// Algorithm: compute pairwise `jaccardDivergence` + `rankDivergence` over
    /// every pair of probe rankings. If ALL pairs have Jaccard divergence below
    /// `invarianceThreshold` AND rank divergence below `invarianceThreshold`,
    /// the backend is query-invariant (its ranking does not change regardless
    /// of the query). This is the exact signature of the 2026-06-07 false run.
    ///
    /// Fewer than 2 probes → `.healthy` (cannot detect invariance without
    /// at least one pair to compare).
    func classify(probeRankings: [[String]]) -> Verdict {
        guard probeRankings.count >= 2 else { return .healthy }

        // Compute ALL pairwise divergences.
        var maxJaccard: Double = 0
        var maxRank: Double = 0

        for i in 0..<probeRankings.count {
            for j in (i + 1)..<probeRankings.count {
                let a = probeRankings[i]
                let b = probeRankings[j]
                let j_div = jaccardDivergence(expected: Set(a), got: Set(b))
                let r_div = rankDivergence(expected: a, got: b)
                if j_div > maxJaccard { maxJaccard = j_div }
                if r_div > maxRank { maxRank = r_div }
            }
        }

        // If EVERY pair has near-zero divergence on BOTH axes the backend is
        // returning the same ranking regardless of the probe query.
        if maxJaccard < invarianceThreshold && maxRank < invarianceThreshold {
            let sample = probeRankings[0].prefix(4).joined(separator: ", ")
            return .queryInvariant(
                diagnostic: "backend returned the same ranking across "
                    + "\(probeRankings.count) distinct probe queries "
                    + "(max Jaccard divergence \(String(format: "%.4f", maxJaccard)), "
                    + "max rank divergence \(String(format: "%.4f", maxRank))). "
                    + "Frozen ranking sample (first 4): [\(sample)]. "
                    + "This matches the query-invariant failure mode in "
                    + "FINDINGS-2026-06-07. Refusing to publish recall numbers."
            )
        }
        return .healthy
    }

    // MARK: - degraded fallback check

    /// Returns `true` when the text blocks contain a "found N" count co-present
    /// with a no-results/fallback hint — the degraded/fallback path seen in
    /// FINDINGS where the server says it found items but the hint betrays that
    /// the result is a fallback, not real recall.
    ///
    /// Detection heuristic: any block contains a "found N" pattern (where N > 0)
    /// AND any block contains a no-results / fallback hint keyword.
    func checkFallback(textBlocks: [String]) -> Bool {
        let combined = textBlocks.joined(separator: "\n").lowercased()
        // Must contain a "found N" claim with N > 0.
        let foundPositive = containsFoundPositive(in: combined)
        if !foundPositive { return false }
        // Must ALSO contain a no-results or fallback hint — the contradiction.
        let fallbackHint = combined.contains("no results")
            || combined.contains("no result")
            || combined.contains("hint:")
            || combined.contains("fallback")
            || combined.contains("no match")
        return fallbackHint
    }

    // MARK: - confirmation-contradiction check

    /// Returns `true` when `confirmedCount` = 0 while `total` > 0 and `recall`
    /// is above `confirmationRecallFloor`. This is a confirmation round-trip
    /// defect pattern: the count says nothing was confirmed, but the
    /// recall says items are being found — a contradiction that makes the number
    /// untrustworthy until the confirmation path is verified.
    func checkConfirmation(confirmedCount: Int, total: Int, recall: Double) -> Bool {
        guard total > 0 else { return false }
        return confirmedCount == 0 && recall > confirmationRecallFloor
    }

    // MARK: - private helpers

    /// True when any line/block in the lowercased combined text contains
    /// "found N" with N > 0 (the mootx01 search result header format).
    private func containsFoundPositive(in text: String) -> Bool {
        // Pattern: "found <integer> memory" or "found <integer>" where integer > 0.
        // Simple line-by-line scan avoids a regex dependency.
        for line in text.components(separatedBy: .newlines) {
            let words = line.split(separator: " ")
            for (i, word) in words.enumerated() {
                if word == "found", i + 1 < words.count {
                    let next = String(words[i + 1])
                    if let n = Int(next), n > 0 { return true }
                }
            }
        }
        return false
    }
}
