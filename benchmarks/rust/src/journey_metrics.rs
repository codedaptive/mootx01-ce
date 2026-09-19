//! journey_metrics.rs — pure integer metrics over an ordered sequence of
//! journey steps. Twin of Swift `JourneyMetrics.swift`.
//!
//! WHY THESE FOUR METRICS. Existing benchmarks report retrieval accuracy
//! (recall@k, MRR). They do not report the cost of reaching a correct
//! answer across multiple agent steps, even though that cost is what
//! users experience. These four metrics capture it:
//!
//!   hops                           — how many tool calls did the agent make?
//!   token_turn_integral            — how many tokens were reprocessed across
//!                                    all turns? (the context-growth tax)
//!   pre_terminal_full_content_tokens — how many full-body tokens were fetched
//!                                    before the final answer step? (the
//!                                    unnecessary hydration cost)
//!   total_payload_tokens           — total token volume across all steps.
//!
//! TOKEN-TURN RESIDENCY INTEGRAL (definition). For a journey of N steps
//! indexed 0..(N-1), the cumulative payload at step i is the sum of
//! payload_tokens for steps 0..i. The integral is the sum of cumulative
//! payloads over all steps:
//!
//!   integral = ∑_{i=0}^{N-1} (∑_{j=0}^{i} payload_tokens[j])
//!
//! Intuitively: if a model re-reads the full context each turn, this is
//! proportional to the total tokens consumed across the session. It is
//! strictly larger than total_payload_tokens for any journey with more
//! than one step, which makes it a useful proxy for context-growth cost.
//!
//! All arithmetic is integer (i64). No floating point. The metric values
//! are deterministic given the step sequence — same steps, same result.

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────

/// One recorded step in a multi-step agent journey.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JourneyStep {
    /// The ARIA verb used in this step (e.g. "store", "recall").
    pub verb: String,
    /// Token count of the reply text for this step, estimated via
    /// `lme_estimate_tokens` (ceiling-4 of UTF-8 byte count).
    pub payload_tokens: i64,
    /// True when the agent retrieved full body content in this step.
    pub hydrated_full_content: bool,
    /// True when this step is the final answer step of the journey.
    pub terminal: bool,
}

/// Computed metrics for one completed journey.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JourneyMetrics {
    /// Total number of steps in the journey.
    pub hops: i64,

    /// TOKEN-TURN RESIDENCY INTEGRAL. Sum over steps i of the cumulative
    /// payload_tokens at step i. Models the context-growth tax: the larger
    /// this is relative to total_payload_tokens, the more the context grew
    /// across turns compared to a single-shot answer.
    pub token_turn_integral: i64,

    /// Sum of payload_tokens for steps where hydrated_full_content is true
    /// AND the step is not the terminal step. Measures unnecessary body
    /// hydration cost — tokens fetched before the answer was ready.
    pub pre_terminal_full_content_tokens: i64,

    /// Sum of all payload_tokens across every step in the journey.
    pub total_payload_tokens: i64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Conformance vector wrapper
// ─────────────────────────────────────────────────────────────────────────────

/// One test case in the conformance vector file.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JourneyMetricsCase {
    pub description: String,
    pub steps: Vec<JourneyStep>,
    pub expected: JourneyMetrics,
}

/// Top-level conformance vector file layout.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct JourneyMetricsVectors {
    pub cases: Vec<JourneyMetricsCase>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure computation
// ─────────────────────────────────────────────────────────────────────────────

/// Computes the four journey metrics from an ordered step sequence.
///
/// The function is a pure mapping: same input → same output. All four
/// outputs are derived from integer arithmetic over `payload_tokens` and
/// the two boolean fields.
///
/// Edge case: empty step sequence → all metrics are zero.
pub fn compute_journey_metrics(steps: &[JourneyStep]) -> JourneyMetrics {
    let mut cumulative: i64 = 0;
    let mut integral: i64 = 0;
    let mut pre_terminal_full: i64 = 0;
    let mut total: i64 = 0;

    for step in steps {
        cumulative += step.payload_tokens;
        integral += cumulative;
        total += step.payload_tokens;
        if step.hydrated_full_content && !step.terminal {
            pre_terminal_full += step.payload_tokens;
        }
    }

    JourneyMetrics {
        hops: steps.len() as i64,
        token_turn_integral: integral,
        pre_terminal_full_content_tokens: pre_terminal_full,
        total_payload_tokens: total,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_journey_is_all_zeros() {
        let m = compute_journey_metrics(&[]);
        assert_eq!(m.hops, 0);
        assert_eq!(m.token_turn_integral, 0);
        assert_eq!(m.pre_terminal_full_content_tokens, 0);
        assert_eq!(m.total_payload_tokens, 0);
    }

    #[test]
    fn single_terminal_step() {
        let steps = vec![JourneyStep {
            verb: "recall".into(),
            payload_tokens: 20,
            hydrated_full_content: false,
            terminal: true,
        }];
        let m = compute_journey_metrics(&steps);
        assert_eq!(m.hops, 1);
        assert_eq!(m.token_turn_integral, 20);
        assert_eq!(m.pre_terminal_full_content_tokens, 0);
        assert_eq!(m.total_payload_tokens, 20);
    }

    #[test]
    fn three_step_mixed() {
        // step 0: store, 10 tokens, not hydrated, not terminal
        // step 1: recall, 40 tokens, hydrated, not terminal
        // step 2: recall, 5 tokens, not hydrated, terminal
        let steps = vec![
            JourneyStep { verb: "store".into(), payload_tokens: 10,
                          hydrated_full_content: false, terminal: false },
            JourneyStep { verb: "recall".into(), payload_tokens: 40,
                          hydrated_full_content: true, terminal: false },
            JourneyStep { verb: "recall".into(), payload_tokens: 5,
                          hydrated_full_content: false, terminal: true },
        ];
        let m = compute_journey_metrics(&steps);
        assert_eq!(m.hops, 3);
        // integral: cumulative at 0=10, at 1=50, at 2=55 → 10+50+55=115
        assert_eq!(m.token_turn_integral, 115);
        // only step 1 is hydrated && !terminal
        assert_eq!(m.pre_terminal_full_content_tokens, 40);
        assert_eq!(m.total_payload_tokens, 55);
    }

    #[test]
    fn integral_exceeds_total_for_multi_step() {
        // For any journey with more than one step the integral must be
        // strictly greater than the total (because the earlier steps' tokens
        // are counted again in every later step's cumulative).
        let steps = vec![
            JourneyStep { verb: "store".into(), payload_tokens: 10,
                          hydrated_full_content: false, terminal: false },
            JourneyStep { verb: "recall".into(), payload_tokens: 5,
                          hydrated_full_content: false, terminal: true },
        ];
        let m = compute_journey_metrics(&steps);
        assert!(m.token_turn_integral > m.total_payload_tokens);
        // integral: cumulative at 0=10, at 1=15 → 25; total=15
        assert_eq!(m.token_turn_integral, 25);
        assert_eq!(m.total_payload_tokens, 15);
    }
}
