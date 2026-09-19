// JourneyRecorder.swift — session recorder that accumulates journey steps and
// exposes the computed metrics and a plain-text report block. Twin of
// `journey_recorder.rs`.
//
// The recorder is NOT thread-safe. It is intended to be used from a single
// serial context (one journey per run). Each event appended converts the
// reply text to a token estimate via lmeEstimateTokens (ceiling-4 of UTF-8
// byte count) before storing the step — callers never pass raw token counts.
//
// The plain-text report block format is intentionally stable: the key names
// and order must match the Rust twin so that the two legs produce identical
// block text for identical inputs.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Recorder
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates step events during a live journey and surfaces the computed
/// metrics once the journey is complete.
///
/// Usage:
/// ```swift
/// var recorder = JourneyRecorder()
/// recorder.append(verb: "store", replyText: "...", hydratedFullContent: false, terminal: false)
/// recorder.append(verb: "recall", replyText: "...", hydratedFullContent: true, terminal: true)
/// let metrics = recorder.metrics()
/// print(recorder.reportBlock())
/// ```
public struct JourneyRecorder: Sendable {
    private var steps: [JourneyStep] = []

    public init() {}

    /// Records one journey step. `replyText` is the full text of the tool
    /// reply for this step; its token count is computed by `lmeEstimateTokens`
    /// (ceiling integer division of UTF-8 byte count by 4).
    ///
    /// - Parameters:
    ///   - verb: The ARIA verb used in this step (e.g. "store", "recall").
    ///   - replyText: Full text of the tool reply. Token count is derived here.
    ///   - hydratedFullContent: True when the reply carried full body content.
    ///   - terminal: True when this is the final answer step.
    public mutating func append(verb: String, replyText: String,
                                hydratedFullContent: Bool, terminal: Bool) {
        let tokens = lmeEstimateTokens(replyText)
        steps.append(JourneyStep(verb: verb, payloadTokens: tokens,
                                 hydratedFullContent: hydratedFullContent,
                                 terminal: terminal))
    }

    /// Returns the current steps as a read-only snapshot (for inspection or
    /// serialisation; does not expose the mutable internal state).
    public func currentSteps() -> [JourneyStep] { steps }

    /// Computes the four journey metrics from the accumulated steps.
    /// Safe to call at any point in the journey; calling after the terminal
    /// step produces the final metrics.
    public func metrics() -> JourneyMetrics {
        computeJourneyMetrics(steps: steps)
    }

    /// Renders a plain-text report block listing all four metrics. The key
    /// names and order are stable and match the Rust twin — test output that
    /// differs between legs indicates a naming or ordering divergence.
    ///
    /// Format:
    /// ```
    /// hops: <N>
    /// token_turn_integral: <N>
    /// pre_terminal_full_tokens: <N>
    /// total_payload_tokens: <N>
    /// ```
    public func reportBlock() -> String {
        let m = metrics()
        return """
        hops: \(m.hops)
        token_turn_integral: \(m.tokenTurnIntegral)
        pre_terminal_full_tokens: \(m.preTerminalFullContentTokens)
        total_payload_tokens: \(m.totalPayloadTokens)
        """
    }
}
