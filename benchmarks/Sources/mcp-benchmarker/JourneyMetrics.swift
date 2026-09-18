// JourneyMetrics.swift — pure integer metrics over an ordered sequence of
// journey steps. Twin of `journey_metrics.rs`.
//
// WHY THESE FOUR METRICS. Existing benchmarks report retrieval accuracy
// (recall@k, MRR). They do not report the cost of reaching a correct
// answer across multiple agent steps, even though that cost is what
// users experience. These four metrics capture it:
//
//   hops                         — how many tool calls did the agent make?
//   tokenTurnIntegral            — how many tokens were reprocessed across
//                                  all turns? (the context-growth tax)
//   preTerminalFullContentTokens — how many full-body tokens were fetched
//                                  before the final answer step? (the
//                                  unnecessary hydration cost)
//   totalPayloadTokens           — total token volume across all steps.
//
// TOKEN-TURN RESIDENCY INTEGRAL (definition). For a journey of N steps
// indexed 0..(N-1), the cumulative payload at step i is the sum of
// payloadTokens for steps 0..i. The integral is the sum of cumulative
// payloads over all steps:
//
//   integral = ∑_{i=0}^{N-1} (∑_{j=0}^{i} payloadTokens[j])
//
// Intuitively: if a model re-reads the full context each turn, this is
// proportional to the total tokens consumed across the session. It is
// strictly larger than totalPayloadTokens for any journey with more than
// one step, which makes it a useful proxy for context-growth cost.
//
// All arithmetic is integer. No floating point. The metric values are
// deterministic given the step sequence — same steps, same result.

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────

/// One recorded step in a multi-step agent journey.
public struct JourneyStep: Codable, Sendable, Equatable {
    /// The ARIA verb used in this step (e.g. "store", "recall").
    public let verb: String
    /// Token count of the reply text for this step, estimated via
    /// `lmeEstimateTokens` (ceiling-4 of UTF-8 byte count).
    public let payloadTokens: Int
    /// True when the agent retrieved full body content (as opposed to
    /// a summary or dense-only representation) in this step.
    public let hydratedFullContent: Bool
    /// True when this step is the final answer step of the journey.
    public let terminal: Bool

    public init(verb: String, payloadTokens: Int,
                hydratedFullContent: Bool, terminal: Bool) {
        self.verb = verb
        self.payloadTokens = payloadTokens
        self.hydratedFullContent = hydratedFullContent
        self.terminal = terminal
    }
}

/// Computed metrics for one completed journey.
public struct JourneyMetrics: Codable, Sendable, Equatable {
    /// Total number of steps in the journey.
    public let hops: Int

    /// TOKEN-TURN RESIDENCY INTEGRAL. Sum over steps i of the cumulative
    /// payloadTokens at step i. Models the context-growth tax: the larger
    /// this is relative to totalPayloadTokens, the more the context grew
    /// across turns compared to a single-shot answer.
    public let tokenTurnIntegral: Int

    /// Sum of payloadTokens for steps where hydratedFullContent is true
    /// AND the step is not the terminal step. Measures unnecessary body
    /// hydration cost — tokens fetched before the answer was ready.
    public let preTerminalFullContentTokens: Int

    /// Sum of all payloadTokens across every step in the journey.
    public let totalPayloadTokens: Int

    public init(hops: Int, tokenTurnIntegral: Int,
                preTerminalFullContentTokens: Int, totalPayloadTokens: Int) {
        self.hops = hops
        self.tokenTurnIntegral = tokenTurnIntegral
        self.preTerminalFullContentTokens = preTerminalFullContentTokens
        self.totalPayloadTokens = totalPayloadTokens
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Conformance vector wrapper (for the hand-written JSON test file)
// ─────────────────────────────────────────────────────────────────────────────

/// One test case in the conformance vector file.
struct JourneyMetricsCase: Codable, Sendable, Equatable {
    let description: String
    let steps: [JourneyStep]
    let expected: JourneyMetrics
}

/// Top-level conformance vector file layout.
struct JourneyMetricsVectors: Codable, Sendable, Equatable {
    let cases: [JourneyMetricsCase]
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure computation
// ─────────────────────────────────────────────────────────────────────────────

/// Computes the four journey metrics from an ordered step sequence.
///
/// The function is a pure mapping: same input → same output. There is no
/// floating point. All four outputs are derived from integer arithmetic
/// over `payloadTokens` and the two boolean fields.
///
/// Edge case: empty step sequence → all metrics are zero.
public func computeJourneyMetrics(steps: [JourneyStep]) -> JourneyMetrics {
    var cumulative = 0
    var integral = 0
    var preTerminalFull = 0
    var total = 0

    for step in steps {
        cumulative += step.payloadTokens
        integral += cumulative
        total += step.payloadTokens
        if step.hydratedFullContent && !step.terminal {
            preTerminalFull += step.payloadTokens
        }
    }

    return JourneyMetrics(
        hops: steps.count,
        tokenTurnIntegral: integral,
        preTerminalFullContentTokens: preTerminalFull,
        totalPayloadTokens: total
    )
}
