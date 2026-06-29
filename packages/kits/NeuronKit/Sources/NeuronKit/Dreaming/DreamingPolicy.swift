// DreamingPolicy.swift
//
// The dreaming daemon's five discovery parameters (NEURONKIT_SPEC
// § 3.1) plus the manifest persistence seam.
//
// The spec says the discovery parameters are "substrate-resident in
// manifest" and configured via `registerDreamingPolicy()`. Policy
// persistence flows through the `DreamingPolicyStore` seam: the daemon
// loads and saves through this protocol. The production adapter
// `EstateManifestPolicyStore` binds it to the estate manifest via the
// GLK estate verb surface (B-1: NeuronKit reaches the substrate only
// through estate verbs). Tests inject an in-memory store and assert
// the round-trip.

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

    /// Minimum number of co-recall events a candidate pair must accumulate
    /// before it is eligible to be proposed. Spec default 3.
    public var minAttempts: Int

    /// Tick cadence in milliseconds. Spec default 30_000 (30s). The
    /// daemon fires a cycle once this interval has elapsed since the last
    /// tick (conformance C-1 allows ±10%). Used by `.timer` and `.hybrid`
    /// modes; ignored by `.event` mode.
    public var tickIntervalMs: Int

    /// Minimum pending dreaming-queue job count that triggers a cycle in
    /// `.event` and `.hybrid` modes. The host calls
    /// `pumpOnEvent(observationCount:now:)` with the estate's pending job
    /// count; a cycle fires when that count is at or above this threshold,
    /// indicating the estate has accumulated enough new recall activity to
    /// warrant dreaming. Spec default 1: any non-zero pending count
    /// triggers the event path. In `.timer` mode this field is unused;
    /// the timer fires on cadence regardless of queue depth.
    public var eventObservationThreshold: Int

    /// Designated initializer. Parameter defaults are the spec defaults.
    public init(
        minSuccessRate: Float = 0.6,
        minConfidence: Float = 0.7,
        minAttempts: Int = 3,
        tickIntervalMs: Int = 30_000,
        eventObservationThreshold: Int = 1
    ) {
        self.minSuccessRate = minSuccessRate
        self.minConfidence = minConfidence
        self.minAttempts = minAttempts
        self.tickIntervalMs = tickIntervalMs
        self.eventObservationThreshold = eventObservationThreshold
    }

    /// Spec-default policy (0.6 / 0.7 / 3 / 30_000 / 1).
    public static let `default` = DreamingPolicy()
}

/// The dreaming daemon's actor-local cycle state, captured for persistence
/// so a restart continues from where the prior run left off instead of
/// re-discovering and re-proposing (NEURONKIT_SPEC § 3; F6 / ADR-020).
///
/// All six fields are the daemon's mutable idempotency/cycle memory:
/// - `lastTickAt`: the timer-path cadence baseline.
/// - `proposedKeys`: candidate keys already proposed (never re-proposed). Stored
///   as a SORTED array so the serialized manifest value is byte-stable.
/// - `lastReindexVocab`: vocabulary size at the last basis retrain (−1 sentinel
///   before the first cycle establishes the baseline).
/// - `consolidated`: EWC++ consolidated confidence by candidate key.
/// - `cycleCount`: number of cycles run.
/// - `coRecallCounts`: per-pair co-recall event counts (NEURONKIT_SPEC § 12.4).
///   Keyed by the canonical pair key ("min|max" lexicographic order, same
///   format as `consolidated`). Bumped by T8 drain; consumed by T8 decide
///   for the `minAttempts` gate. Persisted here so counts survive restarts.
public struct DreamingDaemonState: Sendable, Equatable, Codable {
    public var lastTickAt: Date?
    public var proposedKeys: [String]
    public var lastReindexVocab: Int
    public var consolidated: [String: Float]
    public var cycleCount: Int
    /// Per-pair co-recall counts. Type is `Int` (64-bit on Apple Silicon,
    /// non-negative by convention) to match Rust's `u64` count semantics.
    /// A negative value would indicate a logic error in the caller (T8),
    /// not a representation issue.
    public var coRecallCounts: [String: Int]
    /// Wall-clock instant of the last REM-THETA (daily consolidation) cycle
    /// run. Nil = never run. Used by the REM dispatch table's THETA due-check
    /// to gate on the 24 h cadence (D5a). Persisted via F6/ADR-020 so the
    /// due-check survives daemon restarts — a stdio-only estate still consolidates
    /// on its next invocation (D5c). `decodeIfPresent` keeps older persisted
    /// states loading cleanly when this field is absent.
    public var lastThetaRunAt: Date?
    /// Wall-clock instant of the last REM-BETA (weekly prune) cycle run.
    /// Nil = never run. runBetaCycle (T12) is live. Persisted alongside
    /// THETA and OMEGA.
    public var lastBetaRunAt: Date?
    /// Wall-clock instant of the last REM-OMEGA (biweekly retire) cycle run.
    /// Nil = never run. runOmegaCycle (T13) is live. Persisted alongside
    /// THETA and BETA.
    public var lastOmegaRunAt: Date?

    public init(
        lastTickAt: Date?,
        proposedKeys: [String],
        lastReindexVocab: Int,
        consolidated: [String: Float],
        cycleCount: Int,
        coRecallCounts: [String: Int] = [:],
        lastThetaRunAt: Date? = nil,
        lastBetaRunAt: Date? = nil,
        lastOmegaRunAt: Date? = nil
    ) {
        self.lastTickAt = lastTickAt
        self.proposedKeys = proposedKeys
        self.lastReindexVocab = lastReindexVocab
        self.consolidated = consolidated
        self.cycleCount = cycleCount
        self.coRecallCounts = coRecallCounts
        self.lastThetaRunAt = lastThetaRunAt
        self.lastBetaRunAt = lastBetaRunAt
        self.lastOmegaRunAt = lastOmegaRunAt
    }

    /// Custom decoder for forward/backward compatibility: all optional/added
    /// fields use `decodeIfPresent` so older persisted states (before T11)
    /// still load cleanly. This pattern started with `coRecallCounts` (T7)
    /// and continues for each new field. The Rust port's `#[serde(default)]`
    /// achieves the same result.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lastTickAt = try c.decodeIfPresent(Date.self, forKey: .lastTickAt)
        self.proposedKeys = try c.decode([String].self, forKey: .proposedKeys)
        self.lastReindexVocab = try c.decode(Int.self, forKey: .lastReindexVocab)
        self.consolidated = try c.decode([String: Float].self, forKey: .consolidated)
        self.cycleCount = try c.decode(Int.self, forKey: .cycleCount)
        self.coRecallCounts = try c.decodeIfPresent([String: Int].self, forKey: .coRecallCounts) ?? [:]
        self.lastThetaRunAt = try c.decodeIfPresent(Date.self, forKey: .lastThetaRunAt)
        self.lastBetaRunAt = try c.decodeIfPresent(Date.self, forKey: .lastBetaRunAt)
        self.lastOmegaRunAt = try c.decodeIfPresent(Date.self, forKey: .lastOmegaRunAt)
    }
}

/// Persistence seam for the dreaming policy and bandit state
/// ("substrate-resident in manifest", NEURONKIT_SPEC § 3.1 + § 3.4).
///
/// The daemon never touches the manifest directly (B-1). It loads and
/// saves the policy and bandit through this protocol. The production adapter
/// binds these methods to the estate manifest once GLK exposes a manifest
/// accessor on the verb surface; until then the seam is satisfied by an
/// in-memory store (tests) or whatever the host wires.
///
/// The bandit methods have default no-op implementations so existing
/// conformers (e.g. `InMemoryDreamingPolicyStore`) need no changes.
public protocol DreamingPolicyStore: Sendable {

    /// Load the persisted policy, or `nil` if none has been saved (the
    /// daemon then falls back to `DreamingPolicy.default`).
    func loadPolicy() async throws -> DreamingPolicy?

    /// Persist the policy. Subsequent `loadPolicy()` calls return it.
    func savePolicy(_ policy: DreamingPolicy) async throws

    /// Load the persisted bandit state, or `nil` if none has been saved (the
    /// daemon then starts with a fresh uniform-prior bandit).
    func loadBandit() async throws -> SolverBandit?

    /// Persist the bandit state. The daemon calls this after each cycle.
    /// Persistence is the caller's responsibility per spec; the default
    /// implementation is a no-op (in-memory only, lost on restart).
    func saveBandit(_ bandit: SolverBandit) async throws

    /// Load the persisted daemon cycle state, or `nil` if none has been saved
    /// (the daemon then starts from its in-memory defaults). Loaded once on
    /// `loadPersistedPolicy()` so a restart continues from the prior run's
    /// idempotency/cycle memory (F6 / ADR-020).
    func loadDaemonState() async throws -> DreamingDaemonState?

    /// Persist the daemon cycle state. The daemon calls this after each cycle.
    /// The default implementation is a no-op (in-memory only, lost on restart);
    /// the manifest-backed store overrides it to persist across restarts.
    func saveDaemonState(_ state: DreamingDaemonState) async throws
}

public extension DreamingPolicyStore {
    /// Default: no bandit state persisted (returns nil, start fresh each run).
    func loadBandit() async throws -> SolverBandit? { nil }
    /// Default: discard — production hosts override to persist across restarts.
    func saveBandit(_ bandit: SolverBandit) async throws {}
    /// Default: no daemon state persisted (returns nil, start fresh each run).
    func loadDaemonState() async throws -> DreamingDaemonState? { nil }
    /// Default: discard — production hosts override to persist across restarts.
    func saveDaemonState(_ state: DreamingDaemonState) async throws {}
}

/// In-memory `DreamingPolicyStore` for tests and for hosts that do not
/// persist policy across process restarts. Actor-isolated so concurrent
/// load/save from the daemon actor and a host are race-free.
///
/// Stores policy, bandit state, and daemon cycle state in memory; all are
/// lost when the actor is deallocated. Production hosts override the protocol
/// to write to the estate manifest for cross-restart persistence (F6 / ADR-020).
/// This implementation stores daemon state so tests can exercise the full
/// save/load round-trip without a live estate.
public actor InMemoryDreamingPolicyStore: DreamingPolicyStore {

    private var stored: DreamingPolicy?
    private var storedBandit: SolverBandit?
    private var storedDaemonState: DreamingDaemonState?

    /// Create an empty store, or seed it with an initial policy.
    public init(_ initial: DreamingPolicy? = nil) {
        self.stored = initial
    }

    public func loadPolicy() async throws -> DreamingPolicy? { stored }

    public func savePolicy(_ policy: DreamingPolicy) async throws {
        stored = policy
    }

    public func loadBandit() async throws -> SolverBandit? { storedBandit }

    public func saveBandit(_ bandit: SolverBandit) async throws {
        storedBandit = bandit
    }

    /// Persist daemon cycle state in memory. The stored state is returned by
    /// subsequent `loadDaemonState()` calls so tests can verify the full
    /// save/load round-trip (T11 D5c, F6 / ADR-020).
    public func saveDaemonState(_ state: DreamingDaemonState) async throws {
        storedDaemonState = state
    }

    /// Return the previously saved daemon cycle state, or `nil` if none has
    /// been saved since this store was created.
    public func loadDaemonState() async throws -> DreamingDaemonState? {
        storedDaemonState
    }
}
