// DreamingPolicy.swift
//
// The dreaming daemon's four discovery parameters (NEURONKIT_SPEC
// § 3.1) plus the manifest persistence seam.
//
// The spec says the discovery parameters are "substrate-resident in
// manifest" and configured via `registerDreamingPolicy()`. There is no
// GLK estate verb that reads or writes the manifest from a NeuronKit
// caller today (B-1: NeuronKit reaches the substrate only through estate
// verbs, and the verb surface exposes no manifest accessor). So policy
// persistence flows through the `DreamingPolicyStore` seam: the daemon
// loads and saves through this protocol, and the production adapter
// binds it to the estate manifest when GLK exposes manifest access. Tests
// inject an in-memory store and assert the round-trip.

import Foundation

/// The dreaming daemon's discovery parameters.
///
/// Defaults are the spec defaults (NEURONKIT_SPEC § 3.1): a candidate
/// association must clear `minConfidence` and have been observed at least
/// `minAttempts` times before it is proposed, and the reward signal is
/// thresholded at `minSuccessRate`.
public struct DreamingPolicy: Sendable, Equatable, Codable {

    /// Reward threshold above which a derived reward counts as a
    /// positive (success) signal in the contrastive score. Spec default
    /// 0.6. With the v1 single-source reward (`RecallTraceItem.used`
    /// mapped to 1.0 / 0.0) a used row (1.0) clears this and an unused
    /// row (0.0) does not.
    public var minSuccessRate: Float

    /// Minimum contrastive confidence a candidate must reach before the
    /// daemon proposes it. Spec default 0.7.
    public var minConfidence: Float

    /// Minimum number of co-occurrences a candidate must accumulate
    /// before it is eligible to be proposed. Spec default 3.
    public var minAttempts: Int

    /// Tick cadence in milliseconds. Spec default 30_000 (30s). The
    /// daemon fires a cycle once this interval has elapsed since the last
    /// tick (conformance C-1 allows ±10%).
    public var tickIntervalMs: Int

    /// Designated initializer. Parameter defaults are the spec defaults.
    public init(
        minSuccessRate: Float = 0.6,
        minConfidence: Float = 0.7,
        minAttempts: Int = 3,
        tickIntervalMs: Int = 30_000
    ) {
        self.minSuccessRate = minSuccessRate
        self.minConfidence = minConfidence
        self.minAttempts = minAttempts
        self.tickIntervalMs = tickIntervalMs
    }

    /// Spec-default policy (0.6 / 0.7 / 3 / 30_000).
    public static let `default` = DreamingPolicy()
}

/// Persistence seam for the dreaming policy ("substrate-resident in
/// manifest", NEURONKIT_SPEC § 3.1).
///
/// The daemon never touches the manifest directly (B-1). It loads and
/// saves the policy through this protocol. The production adapter binds
/// these methods to the estate manifest once GLK exposes a manifest
/// accessor on the verb surface; until then the seam is satisfied by an
/// in-memory store (tests) or whatever the host wires.
public protocol DreamingPolicyStore: Sendable {

    /// Load the persisted policy, or `nil` if none has been saved (the
    /// daemon then falls back to `DreamingPolicy.default`).
    func loadPolicy() async throws -> DreamingPolicy?

    /// Persist the policy. Subsequent `loadPolicy()` calls return it.
    func savePolicy(_ policy: DreamingPolicy) async throws
}

/// In-memory `DreamingPolicyStore` for tests and for hosts that do not
/// persist policy across process restarts. Actor-isolated so concurrent
/// load/save from the daemon actor and a host are race-free.
public actor InMemoryDreamingPolicyStore: DreamingPolicyStore {

    private var stored: DreamingPolicy?

    /// Create an empty store, or seed it with an initial policy.
    public init(_ initial: DreamingPolicy? = nil) {
        self.stored = initial
    }

    public func loadPolicy() async throws -> DreamingPolicy? { stored }

    public func savePolicy(_ policy: DreamingPolicy) async throws {
        stored = policy
    }
}
