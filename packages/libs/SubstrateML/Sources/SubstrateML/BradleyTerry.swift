// BradleyTerry.swift
//
// Bradley-Terry online preference learning per cookbook § 8.12.
//
// The Bradley-Terry model assigns each item a "strength" parameter
// w_i such that the probability that item i beats item j in a
// pairwise comparison is:
//
//   P(i beats j) = w_i / (w_i + w_j)
//
// The substrate uses BT to score ranking-relevant candidates over
// the long tail of RecallTrace feedback. Every time a CognitionKit
// primitive surfaces a candidate set and the user/agent selects
// one, the "used" candidate beats every "ignored" candidate in
// that decision instance. BT consumes those preferences online
// and produces a vector W_ranking[i] that weights how heavily the
// substrate trusts row i for future similar queries.
//
// CONSTITUTIONAL: W_ranking is a learned ranking signal, NOT a
// truth signal. It does not change which rows exist or what their
// fields say; it changes the ORDER in which candidates surface.
// Decay (cookbook § 6.8) prevents W_ranking from becoming
// dominated by ancient preferences.

import Foundation
import SubstrateTypes

/// One preference observation from a RecallTrace. The `winner`
/// was selected by the user/agent; the `losers` were surfaced in
/// the same candidate set but ignored.
public struct PreferenceObservation: Sendable {
    public let winnerID: UUID
    public let losers: [UUID]
    public let weight: Double          // typically 1.0 per RecallTrace

    public init(winnerID: UUID, losers: [UUID], weight: Double = 1.0) {
        self.winnerID = winnerID
        self.losers = losers
        self.weight = weight
    }
}

/// Online Bradley-Terry estimator. Maintains the strength vector
/// `w[i]` indexed by row ID. Updates via stochastic gradient
/// ascent on the BT log-likelihood per observation.
///
/// For numerical stability we parameterize in log-space:
///   theta[i] = log(w[i])
///   P(i beats j) = sigmoid(theta[i] - theta[j])
///   gradient (winner i over loser j) = (1 - sigmoid(theta_i - theta_j))
///   update: theta_i += learningRate * grad
///           theta_j -= learningRate * grad
public struct BradleyTerryEstimator: Sendable {

    /// Log-strength per row ID. Default 0.0 ⇒ strength 1.0.
    private(set) public var theta: [UUID: Double]

    /// Learning rate. Cookbook § 8.12.3 recommends 0.05 for the
    /// substrate's expected feedback rate (~10-100 obs/day).
    public let learningRate: Double

    /// L2 regularization coefficient. Pulls theta toward 0
    /// (uniform strength) for rows seen few times. Prevents
    /// overfitting to sparse early data.
    public let l2: Double

    public init(learningRate: Double = 0.05, l2: Double = 0.001,
                theta: [UUID: Double] = [:]) {
        precondition(learningRate > 0, "learning rate must be positive")
        precondition(l2 >= 0, "L2 must be non-negative")
        self.learningRate = learningRate
        self.l2 = l2
        self.theta = theta
    }

    /// Apply a single preference observation. Updates theta for
    /// the winner and all losers; cost is O(|losers|).
    public mutating func observe(_ obs: PreferenceObservation) {
        // Accumulate winner updates across all losers before
        // writing back, so multi-loser observations sum the
        // gradient contributions rather than overwriting only the
        // last loser's. Each per-loser gradient is computed against
        // the running `winnerNew` value to match the cookbook's
        // sequential update semantics. The Rust mirror uses the
        // same construction.
        let winnerTheta = theta[obs.winnerID] ?? 0.0
        var winnerNew = winnerTheta
        for loserID in obs.losers {
            let loserTheta = theta[loserID] ?? 0.0
            let pWinnerBeatsLoser = sigmoid(winnerNew - loserTheta)
            let grad = obs.weight * (1.0 - pWinnerBeatsLoser)
            winnerNew = winnerNew
                + learningRate * grad
                - learningRate * l2 * winnerNew
            let newLoser = loserTheta
                - learningRate * grad
                - learningRate * l2 * loserTheta
            theta[loserID] = newLoser
        }
        theta[obs.winnerID] = winnerNew
    }

    /// Apply a batch of observations in order. Cost is O(sum
    /// |losers|).
    public mutating func observeBatch(_ observations: [PreferenceObservation]) {
        for obs in observations {
            observe(obs)
        }
    }

    /// Read the current strength `w[i] = exp(theta[i])`.
    /// Stronger ⇒ surfaces higher in future ranked recalls.
    public func strength(of rowID: UUID) -> Double {
        let t = theta[rowID] ?? 0.0
        return exp(t)
    }

    /// Probability that row `a` would beat row `b` in a pairwise
    /// preference, per the current model.
    public func probability(_ a: UUID, beats b: UUID) -> Double {
        let ta = theta[a] ?? 0.0
        let tb = theta[b] ?? 0.0
        return sigmoid(ta - tb)
    }
}

private func sigmoid(_ x: Double) -> Double {
    return 1.0 / (1.0 + exp(-x))
}

// MARK: - Coupling to RecallTrace (cookbook § 11.18 + § 18.2)
//
// Every CognitionKit primitive emits a RecallTrace at completion
// with:
//
//   trace.query           — the query that produced the candidates
//   trace.candidates      — ordered list surfaced to user/agent
//   trace.usedRowID       — what they actually selected (nil if abandoned)
//   trace.timestamp       — HLC at the time of decision
//
// The dreaming daemon (§ 15) batches RecallTraces and feeds them
// to BradleyTerryEstimator.observeBatch. The resulting W_ranking
// is written back to the row's calibration field (§ 6.6). Future
// recalls multiply candidate similarity by `strength(rowID)` to
// produce ranked output.
//
// The cookbook § 11.18 specifies that traces where usedRowID is
// nil produce NO preference observation (no signal). Traces where
// the user explicitly clicked "none of these match" produce a
// negative observation for ALL candidates (all lose to a
// notional "absent" item with theta = 0). The reference here
// does not implement the "absent" case; the dreaming daemon
// handles it before calling observe().

// MARK: - Properties
//
//   convergence:    stochastic gradient ascent with diminishing
//                   updates (via L2 regularization) converges to
//                   the MAP estimate of the BT posterior.
//   determinism:    given the same observation sequence, two
//                   estimators produce bit-identical theta.
//   bounded:        L2 keeps theta in [-1/l2 * ln(N), 1/l2 * ln(N)]
//                   roughly; strength never blows up.
//   warm-restart:   serializing theta and reloading reproduces
//                   exactly the same future behavior.
