//! Recall discrimination / confidence metric.
//!
//! A pure, scale-independent helper that classifies how well a ranked recall
//! result distinguishes its top hit from the rest of the list.
//!
//! This is a CONFIDENCE HEURISTIC, not a ranking signal. It is computed from
//! the scores the recall tools ALREADY have and is appended to the tool result
//! so the calling AI can interpret low-discrimination results correctly (treat
//! as effectively unranked, prefer lexical modes) rather than acting on noise.
//!
//! ## Parity contract
//!
//! Swift and Rust must produce identical [`DiscriminationLevel`] for the same
//! score vector. The named threshold constants here are mirrored verbatim in
//! `RecallDiscrimination.swift`. Any threshold change must be applied to both
//! ports simultaneously.
//!
//! ## Algorithm (scale-independent)
//!
//! Given ordered scores s0 ≥ s1 ≥ … ≥ s_{n-1}:
//!   - n < 2                                    → `Single`
//!   - topGap = (s0 - s1) / max(|s0|, EPS)
//!   - spread  = (s0 - sLast) / max(|s0|, EPS)
//!   - `Low`    if topGap < LOW_MARGIN && spread < LOW_SPREAD
//!   - `High`   if topGap >= HIGH_MARGIN
//!   - else     `Medium`
//!
//! Thresholds are heuristic defaults — tune with real estate data; do NOT rank
//! with these values.

// ---------------------------------------------------------------------------
// Threshold constants (mirrored in RecallDiscrimination.swift)
// ---------------------------------------------------------------------------

/// Minimum relative gap (rank-1 vs rank-2) for a "not low" classification.
const LOW_MARGIN: f64 = 0.05;
/// Minimum relative spread (rank-1 vs last) for a "not low" classification.
const LOW_SPREAD: f64 = 0.15;
/// Minimum relative gap (rank-1 vs rank-2) for a "high" classification.
const HIGH_MARGIN: f64 = 0.25;
/// Epsilon prevents division by zero on all-zero score vectors.
const EPS: f64 = 1e-9;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// How well a ranked recall result separates its top hit from the rest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscriminationLevel {
    /// Fewer than two results — nothing to compare.
    Single,
    /// Top result is clearly separated from the second (topGap >= HIGH_MARGIN).
    High,
    /// Partial separation — some evidence of a best hit.
    Medium,
    /// Top results are within epsilon — the list is effectively unranked.
    Low,
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// Classify the discrimination level of an ordered score list.
///
/// `scores` must already be in descending order (highest first). This function
/// does NOT sort the input.
pub fn classify(scores: &[f64]) -> DiscriminationLevel {
    if scores.len() < 2 {
        return DiscriminationLevel::Single;
    }

    let s0 = scores[0];
    let s1 = scores[1];
    let s_last = scores[scores.len() - 1];

    // Denominator: magnitude of the top score, floored at EPS so a
    // zero-top-score list still produces well-defined ratios (all ratios
    // become 0 / EPS ≈ 0 → Low).
    let denom = s0.abs().max(EPS);
    let top_gap = (s0 - s1) / denom;
    let spread = (s0 - s_last) / denom;

    if top_gap >= HIGH_MARGIN {
        DiscriminationLevel::High
    } else if top_gap < LOW_MARGIN && spread < LOW_SPREAD {
        DiscriminationLevel::Low
    } else {
        DiscriminationLevel::Medium
    }
}

// ---------------------------------------------------------------------------
// Result line
// ---------------------------------------------------------------------------

/// The AI-facing discrimination line to append to a ranked recall result.
///
/// Wording is factual and action-oriented so the calling AI knows what to do,
/// not just what the level is.
pub fn result_line(level: DiscriminationLevel) -> &'static str {
    match level {
        DiscriminationLevel::Single => "discrimination: n/a — single/zero results.",
        DiscriminationLevel::High => "discrimination: high — clear top result.",
        DiscriminationLevel::Medium => "discrimination: medium — partial separation.",
        // For small corpora the semantic/associative modes (conceptual shaped-recall,
        // partial_cue) produce near-flat scores until the embedding encoder (v1.1)
        // lands — this is expected, not an error. Direct the AI toward lexical/precise
        // modes when it needs ranking it can trust on small estates.
        DiscriminationLevel::Low => {
            "discrimination: low — top results are within epsilon; treat as effectively unranked. \
             Prefer moot_recall_precise / moot_memory_search (ordering: byRelevanceDesc) for \
             precision, or widen the query."
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_or_zero_results_return_single() {
        assert_eq!(classify(&[]), DiscriminationLevel::Single);
        assert_eq!(classify(&[1.0]), DiscriminationLevel::Single);
    }

    #[test]
    fn clearly_separated_scores_return_high() {
        // topGap = (1.0 - 0.5) / 1.0 = 0.5 >= HIGH_MARGIN (0.25)
        assert_eq!(classify(&[1.0, 0.5, 0.3]), DiscriminationLevel::High);
    }

    #[test]
    fn near_flat_scores_return_low() {
        // topGap = (1.0 - 0.98) / 1.0 = 0.02 < LOW_MARGIN (0.05)
        // spread = (1.0 - 0.95) / 1.0 = 0.05 < LOW_SPREAD (0.15)
        assert_eq!(classify(&[1.0, 0.98, 0.97, 0.95]), DiscriminationLevel::Low);
    }

    #[test]
    fn medium_gap_returns_medium() {
        // topGap = (1.0 - 0.88) / 1.0 = 0.12  (>= LOW_MARGIN but < HIGH_MARGIN)
        assert_eq!(classify(&[1.0, 0.88, 0.50]), DiscriminationLevel::Medium);
    }

    #[test]
    fn all_zero_scores_return_low() {
        // denom = EPS, topGap ≈ 0 / EPS ≈ 0 < LOW_MARGIN, spread ≈ 0 → Low
        assert_eq!(classify(&[0.0, 0.0, 0.0]), DiscriminationLevel::Low);
    }

    #[test]
    fn two_items_high_gap_returns_high() {
        // topGap = (0.9 - 0.1) / 0.9 ≈ 0.89 >= HIGH_MARGIN
        assert_eq!(classify(&[0.9, 0.1]), DiscriminationLevel::High);
    }

    /// Parity: the same score vectors must produce the same level as Swift.
    /// This is a compile-time-verified cross-port contract: if you change a
    /// threshold here, update RecallDiscrimination.swift to match.
    #[test]
    fn parity_vectors_match_swift() {
        // Vector A: high separation → High
        assert_eq!(classify(&[1.0, 0.6]), DiscriminationLevel::High);
        // Vector B: flat spread, tiny gap → Low
        assert_eq!(classify(&[1.0, 0.99, 0.98, 0.97]), DiscriminationLevel::Low);
        // Vector C: medium separation → Medium
        assert_eq!(classify(&[1.0, 0.9, 0.4]), DiscriminationLevel::Medium);
    }
}
