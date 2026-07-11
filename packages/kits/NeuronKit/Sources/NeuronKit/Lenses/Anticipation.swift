import SubstrateML
import SubstrateTypes

// Anticipation — the learned action→outcome model (SPEC § 7.4, Lens 4
// Prediction). Given observed action→outcome events, learn which actions
// reliably reach a desired target outcome, ranked by the Wilson lower bound so
// a few lucky successes don't outrank a well-evidenced action. "To reach Y, you
// tend to do X." Surfaces SubstrateML's ActionOutcomeMatrix + Wilson bound; owns
// no math (I-17). Pure and total (I-18, B-8).

/// One observed action→outcome event. `success` records whether the action
/// achieved its intended result on that occasion.
public struct ActionObservation: Sendable, Equatable, Codable {
    public let action: UInt8
    public let outcome: UInt8
    public let success: Bool
    public init(action: UInt8, outcome: UInt8, success: Bool) {
        self.action = action
        self.outcome = outcome
        self.success = success
    }
}

/// One predicted action for a target outcome: its Wilson-lower-bound success
/// rate (the ranking key) and the total observations behind it.
public struct ActionPrediction: Sendable, Equatable, Codable {
    public let action: UInt8
    public let successRate: Float      // Wilson lower bound, ranked descending
    public let count: UInt32
    public init(action: UInt8, successRate: Float, count: UInt32) {
        self.action = action
        self.successRate = successRate
        self.count = count
    }
}

extension NeuronKit {
    /// Rank the actions that reach `targetOutcome`, learned from `observations`,
    /// by Wilson lower bound (descending) — returning the top `k` actions seen
    /// at least `minObservations` times. Events are category-keyed, so HLC
    /// ordering is irrelevant: every observation is recorded at `HLC.zero`
    /// (recency is a separate concern — theme weather). No observations or
    /// `k <= 0` ⇒ empty (C-16).
    public static func anticipate(observations: [ActionObservation], targetOutcome: UInt8,
                                  k: Int, minObservations: UInt32) -> [ActionPrediction] {
        guard !observations.isEmpty, k > 0 else { return [] }

        // Shape the events into the gated matrix. HLC is irrelevant here, so
        // every observation lands at zero (I-17: the matrix owns the math).
        var matrix = SubstrateML.ActionOutcomeMatrix()
        for o in observations {
            // action/outcome are the 6-bit bitmap categories (o07/o08): the
            // matrix key traps on anything ≥ 64. This is a public Codable
            // surface, so decoded bytes span the full UInt8 range — skip
            // out-of-range observations rather than let them abort the process.
            // No valid caller (closed CognitionKit enums) is affected.
            guard o.action < 64, o.outcome < 64 else { continue }
            matrix.observe(action: o.action, outcome: o.outcome, success: o.success, at: HLC.zero)
        }

        // Read the cells for the target outcome, keeping those seen at least
        // minObservations times. successRate carries the Wilson lower bound —
        // the same conservative signal the ranking uses (INTERFACE § 2). The
        // matrix computes the bound per cell (I-17); the lens does not.
        let candidates = matrix.cells.compactMap {
            (key, cell) -> ActionPrediction? in
            guard key.outcomeCategory == targetOutcome,
                  cell.totalCount >= minObservations else { return nil }
            return ActionPrediction(action: key.actionKind,
                                    successRate: cell.wilsonLowerBound,
                                    count: cell.totalCount)
        }

        // Rank by Wilson lower bound descending; ties by count descending, then
        // action ascending (the primitive's documented tie-break — C-17). Cap
        // to k.
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.successRate != rhs.successRate { return lhs.successRate > rhs.successRate }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.action < rhs.action
        }
        return Array(ranked.prefix(k))
    }
}
