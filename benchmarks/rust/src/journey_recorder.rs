//! journey_recorder.rs — session recorder that accumulates journey steps and
//! exposes the computed metrics and a plain-text report block. Twin of Swift
//! `JourneyRecorder.swift`.
//!
//! The recorder is intended to be used from a single serial context (one
//! journey per run). Each event appended converts the reply text to a token
//! estimate via `lme_estimate_tokens` (ceiling-4 of UTF-8 byte count) before
//! storing the step — callers never pass raw token counts.
//!
//! The plain-text report block format is intentionally stable: the key names
//! and order match the Swift twin so that the two legs produce identical block
//! text for identical inputs.

use crate::journey_metrics::{compute_journey_metrics, JourneyMetrics, JourneyStep};
use crate::longmemeval_token_efficiency::lme_estimate_tokens;

// ─────────────────────────────────────────────────────────────────────────────
// Recorder
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates step events during a live journey and surfaces the computed
/// metrics once the journey is complete.
///
/// # Example
/// ```ignore
/// let mut recorder = JourneyRecorder::new();
/// recorder.append("store", "some reply text", false, false);
/// recorder.append("recall", "answer text", true, true);
/// let metrics = recorder.metrics();
/// println!("{}", recorder.report_block());
/// ```
#[derive(Debug, Default)]
pub struct JourneyRecorder {
    steps: Vec<JourneyStep>,
}

impl JourneyRecorder {
    /// Creates a new empty recorder.
    pub fn new() -> Self {
        Self { steps: Vec::new() }
    }

    /// Records one journey step. `reply_text` is the full text of the tool
    /// reply for this step; its token count is computed by `lme_estimate_tokens`
    /// (ceiling integer division of UTF-8 byte count by 4).
    ///
    /// * `verb` — the ARIA verb used in this step (e.g. "store", "recall").
    /// * `reply_text` — full text of the tool reply. Token count is derived here.
    /// * `hydrated_full_content` — true when the reply carried full body content.
    /// * `terminal` — true when this is the final answer step.
    pub fn append(&mut self, verb: &str, reply_text: &str,
                  hydrated_full_content: bool, terminal: bool) {
        let tokens = lme_estimate_tokens(reply_text) as i64;
        self.steps.push(JourneyStep {
            verb: verb.to_string(),
            payload_tokens: tokens,
            hydrated_full_content,
            terminal,
        });
    }

    /// Returns an immutable reference to the accumulated steps.
    pub fn current_steps(&self) -> &[JourneyStep] {
        &self.steps
    }

    /// Computes the four journey metrics from the accumulated steps. Safe to
    /// call at any point in the journey; calling after the terminal step
    /// produces the final metrics.
    pub fn metrics(&self) -> JourneyMetrics {
        compute_journey_metrics(&self.steps)
    }

    /// Renders a plain-text report block listing all four metrics. The key
    /// names and order are stable and match the Swift twin.
    ///
    /// Format:
    /// ```text
    /// hops: N
    /// token_turn_integral: N
    /// pre_terminal_full_tokens: N
    /// total_payload_tokens: N
    /// ```
    pub fn report_block(&self) -> String {
        let m = self.metrics();
        format!(
            "hops: {}\ntoken_turn_integral: {}\npre_terminal_full_tokens: {}\ntotal_payload_tokens: {}",
            m.hops, m.token_turn_integral, m.pre_terminal_full_content_tokens, m.total_payload_tokens
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// The token estimate for "Hello" (5 UTF-8 bytes) is ceil(5/4) = 2.
    #[test]
    fn append_converts_text_to_token_estimate() {
        let mut r = JourneyRecorder::new();
        r.append("store", "Hello", false, false);
        assert_eq!(r.current_steps()[0].payload_tokens, 2); // ceil(5/4) = 2
    }

    #[test]
    fn empty_recorder_metrics_are_zero() {
        let r = JourneyRecorder::new();
        let m = r.metrics();
        assert_eq!(m.hops, 0);
        assert_eq!(m.token_turn_integral, 0);
        assert_eq!(m.pre_terminal_full_content_tokens, 0);
        assert_eq!(m.total_payload_tokens, 0);
    }

    #[test]
    fn report_block_format_matches_swift_twin() {
        // "ABCD" = 4 bytes → 1 token. "EFGH" = 4 bytes → 1 token.
        // After two appends:
        //   hops = 2
        //   integral: cumulative 1 then 2 → 1+2=3
        //   preTerminal: step 0 is hydrated && !terminal → 1
        //   total: 2
        let mut r = JourneyRecorder::new();
        r.append("store", "ABCD", true, false);
        r.append("recall", "EFGH", false, true);
        let block = r.report_block();
        assert_eq!(
            block,
            "hops: 2\ntoken_turn_integral: 3\npre_terminal_full_tokens: 1\ntotal_payload_tokens: 2"
        );
    }

    #[test]
    fn fixture_reply_texts_match_expected_block() {
        // Fixture texts chosen so token counts are exact and round-trip
        // to the same values on both legs.
        //
        // "StoredItem" = 10 bytes → ceil(10/4) = 3 tokens
        // "RecallReply" = 11 bytes → ceil(11/4) = 3 tokens
        //
        // hops=2, integral=3+(3+3)=9, preTerminal=0 (neither hydrated),
        // total=6
        let mut r = JourneyRecorder::new();
        r.append("store", "StoredItem", false, false);
        r.append("recall", "RecallReply", false, true);
        let m = r.metrics();
        assert_eq!(m.hops, 2);
        assert_eq!(m.token_turn_integral, 9);
        assert_eq!(m.pre_terminal_full_content_tokens, 0);
        assert_eq!(m.total_payload_tokens, 6);
    }
}
