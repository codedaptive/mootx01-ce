// RecallDiscrimination.swift
//
// A pure, scale-independent helper that classifies how well a ranked recall
// result distinguishes its top hit from the rest of the list.
//
// This is a CONFIDENCE HEURISTIC, not a ranking signal. It is computed from
// the scores the recall tools ALREADY have and is appended to the tool result
// so the calling AI can interpret low-discrimination results correctly (treat
// as effectively unranked, prefer lexical modes) rather than acting on noise.
//
// The metric is intentionally lightweight: one relative gap ratio from rank-1
// to rank-2, and a spread ratio from rank-1 to the last result. Both are
// relative (divided by max(|s0|, EPS)) so the classification is
// score-scale-agnostic — it applies whether scores are in [0, 1] or [0, 1000].
//
// Parity contract: Swift and Rust must produce identical DiscriminationLevel
// for the same score vector. The thresholds are named constants here and
// mirrored verbatim in `recall_discrimination.rs`. Any threshold change must
// be applied to both ports simultaneously.

import Foundation

/// How well a ranked recall result separates its top hit from the rest.
public enum DiscriminationLevel: Sendable, Equatable {
    /// Fewer than two results — nothing to compare.
    case single
    /// Top result is clearly separated from the second (topGap >= HIGH_MARGIN).
    case high
    /// Partial separation — some evidence of a best hit.
    case medium
    /// Top results are within epsilon — the list is effectively unranked.
    case low
    /// Query had distinctive tokens (numbers or proper nouns) but no candidate
    /// contained any of them — the recall set is a confident non-match.
    case notFound
}

/// Compute the discrimination level for an ordered score list.
///
/// - Parameter scores: Scores in descending order (highest first). The list
///   must already be sorted; this function does NOT sort.
///
/// Thresholds (heuristic defaults — tune with a real estate; do NOT rank with
/// these values):
///   - `LOW_MARGIN`  = 0.05 — relative gap between rank-1 and rank-2 at which
///     the top result is indistinguishable from rank-2.
///   - `LOW_SPREAD`  = 0.15 — relative gap between rank-1 and the last result
///     at which the entire list is effectively flat.
///   - `HIGH_MARGIN` = 0.25 — relative gap at which rank-1 is clearly the
///     best match.
///   - `EPS`         = 1e-9 — prevents division by zero on all-zero score lists.
public enum RecallDiscrimination {

    // MARK: - Threshold constants (mirrored in recall_discrimination.rs)

    /// Minimum relative gap (rank-1 vs rank-2) for a "not low" classification.
    static let LOW_MARGIN: Double = 0.05
    /// Minimum relative spread (rank-1 vs last) for a "not low" classification.
    static let LOW_SPREAD: Double = 0.15
    /// Minimum relative gap (rank-1 vs rank-2) for a "high" classification.
    static let HIGH_MARGIN: Double = 0.25
    /// Epsilon prevents division by zero on all-zero score vectors.
    static let EPS: Double = 1e-9

    // MARK: - Public API

    /// Classify the discrimination level of an ordered score list.
    public static func classify(_ scores: [Double]) -> DiscriminationLevel {
        guard scores.count >= 2 else { return .single }

        let s0 = scores[0]
        let s1 = scores[1]
        let sLast = scores[scores.count - 1]

        // Denominator: magnitude of the top score, floored at EPS so a
        // zero-top-score list still produces well-defined ratios (all ratios
        // become 0 / EPS ≈ 0 → "low").
        let denom = max(abs(s0), EPS)
        let topGap = (s0 - s1) / denom
        let spread = (s0 - sLast) / denom

        if topGap >= HIGH_MARGIN {
            return .high
        }
        if topGap < LOW_MARGIN && spread < LOW_SPREAD {
            return .low
        }
        return .medium
    }

    // MARK: - Result line

    /// The AI-facing discrimination line to append to a ranked recall result.
    ///
    /// The wording is intentionally factual and action-oriented so the calling
    /// AI knows what to do, not just what the level is.
    public static func resultLine(for level: DiscriminationLevel) -> String {
        switch level {
        case .single:
            return "discrimination: n/a — single/zero results."
        case .high:
            return "discrimination: high — clear top result."
        case .medium:
            return "discrimination: medium — partial separation."
        case .low:
            // For small corpora the semantic/associative modes (conceptual
            // shaped-recall, partial_cue) produce near-flat scores until the
            // embedding encoder (v1.1) lands — this is expected, not an error.
            // Direct the AI toward lexical/precise modes when it needs ranking
            // that it can trust on small estates.
            return "discrimination: low — top results are within epsilon; treat as effectively unranked. "
                + "Prefer moot_recall_precise / moot_memory_search (ordering: byRelevanceDesc) for "
                + "precision, or widen the query."
        case .notFound:
            // The query carried distinctive tokens (numbers or capitalised words)
            // that are reliable identity markers — yet zero candidates matched
            // any of them. Returning a ranked list here would be fabrication.
            // Direct the AI to try a different query or confirm the content exists.
            return "discrimination: not_found — query contains distinctive tokens but no stored memory "
                + "matches them. The content may not exist in this estate. "
                + "Try moot_memory_search to confirm, or rephrase the query."
        }
    }
}
