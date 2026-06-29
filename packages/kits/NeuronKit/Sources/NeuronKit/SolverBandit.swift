// SolverBandit.swift
//
// Thompson-Sampling Beta multi-arm bandit for the dreaming trigger mode
// (NEURONKIT_SPEC § 3.4, mission NK-BANDIT).
//
// Three arms: .timer, .event, .hybrid — one per DreamingTriggerMode case.
// Each arm has a Beta(α, β) posterior seeded at (1, 1) (uniform prior).
// select(seed:) samples θ ~ Beta(α_i, β_i) for each arm and returns the
// arm with the highest sample. observe(arm:reward:) updates the arm's
// posterior with one Bernoulli observation.
//
// Substrate-resident state: the bandit is serialisable (Codable) so the
// ResidentDaemon can persist and restore it across restarts (the spec's
// "substrate-resident state, survives restart" requirement — persistence
// is the caller's responsibility; the bandit is a value type).
//
// Determinism: select takes an explicit seed so callers that want
// reproducible selection (tests, migration benchmarks) can supply one.
// Production callers pass a seed derived from the caller-supplied `now`
// timestamp (the same pattern as SpreadingActivation's walk seed).
//
// Beta sampling: delegates to SubstrateML.Sampling.sampleBeta, which uses
// the Marsaglia-Tsang Gamma ratio method with the same SplitMix64 PRNG
// threaded by inout reference. I-25: one implementation per substrate
// atomic; NeuronKit never reimplements what the substrate already owns.

import Foundation
import SubstrateML

// MARK: - Public API

/// Thompson-Sampling Beta multi-arm bandit for the dreaming trigger mode
/// (NEURONKIT_SPEC § 3.4).
///
/// Three arms correspond to `DreamingTriggerMode` cases. Each arm maintains
/// a Beta(α, β) posterior; the bandit selects an arm by drawing a sample from
/// each posterior and returning the arm with the highest sample. It learns
/// the optimal trigger mode per estate from observed dreaming-cycle reward.
public struct SolverBandit: Sendable, Codable, Equatable {

    /// One bandit arm, associated with a `DreamingTriggerMode`.
    ///
    /// `alpha` and `beta` are the Beta distribution parameters: alpha counts
    /// successes + 1, beta counts failures + 1. Both start at 1 (uniform prior).
    public struct Arm: Sendable, Codable, Equatable {

        /// The trigger mode this arm represents.
        public let mode: DreamingTriggerMode

        /// Beta parameter: successes + 1. Starts at 1 (uniform prior).
        public var alpha: Double

        /// Beta parameter: failures + 1. Starts at 1 (uniform prior).
        public var beta: Double

        /// Create an arm with an explicit prior. Defaults to the uniform prior (1, 1).
        public init(mode: DreamingTriggerMode, alpha: Double = 1, beta: Double = 1) {
            self.mode = mode
            self.alpha = alpha
            self.beta = beta
        }
    }

    /// One arm per `DreamingTriggerMode` case, in `allCases` order (stable).
    public private(set) var arms: [Arm]

    /// Construct a bandit with a uniform prior (α=1, β=1) on all arms.
    public init() {
        arms = DreamingTriggerMode.allCases.map { Arm(mode: $0) }
    }

    /// Validates that a decoded bandit has exactly one arm per
    /// `DreamingTriggerMode` case. A malformed persisted JSON (wrong arm
    /// count or missing modes) falls back to a fresh uniform-prior bandit
    /// rather than crashing or entering a permanently broken state.
    /// Mirrors the Rust `SolverBandit::validate()` fallback.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Arm].self, forKey: .arms)
        let expected = DreamingTriggerMode.allCases.count
        // Guard: persisted state must have one arm per trigger-mode case.
        // A missing or extra arm (truncated JSON, schema mismatch) produces
        // undefined select() behaviour; reset to a uniform prior instead.
        if decoded.count == expected {
            arms = decoded
        } else {
            arms = DreamingTriggerMode.allCases.map { Arm(mode: $0) }
        }
    }

    /// Select the trigger mode for the next cycle using Thompson Sampling.
    ///
    /// Draws θ_i ~ Beta(alpha_i, beta_i) for each arm; returns the arm with
    /// the highest sample. Ties break on stable arm order (ascending allCases
    /// index). `seed` is explicit for determinism — never calls arc4random
    /// or any non-deterministic source internally.
    public func select(seed: UInt64) -> DreamingTriggerMode {
        // Guard against a malformed (zero-arm) bandit — fall through to the
        // default mode rather than crashing on arms[0] below.
        guard !arms.isEmpty else { return DreamingTriggerMode.allCases[0] }
        var rng = SplitMix64(seed: seed)
        var bestSample = -Double.infinity
        var bestMode = arms[0].mode
        for arm in arms {
            let sample = Sampling.sampleBeta(alpha: arm.alpha, beta: arm.beta, rng: &rng)
            if sample > bestSample {
                bestSample = sample
                bestMode = arm.mode
            }
        }
        return bestMode
    }

    /// Observe one cycle outcome and update the arm's Beta posterior.
    ///
    /// `reward` is in `[0, 1]`. A Bernoulli threshold of 0.5 determines
    /// success: reward >= 0.5 increments alpha (success), reward < 0.5
    /// increments beta (failure).
    public mutating func observe(arm mode: DreamingTriggerMode, reward: Double) {
        guard let idx = arms.firstIndex(where: { $0.mode == mode }) else { return }
        if reward >= 0.5 {
            arms[idx].alpha += 1
        } else {
            arms[idx].beta += 1
        }
    }
}

