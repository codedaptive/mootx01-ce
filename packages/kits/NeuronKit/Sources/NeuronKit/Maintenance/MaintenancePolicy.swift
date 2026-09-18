// MaintenancePolicy.swift
//
// The maintenance daemon's health-scan parameters (NEURONKIT_SPEC
// § 3.2) plus the manifest persistence seam.
//
// The spec says the discovery / health parameters are
// "substrate-resident in manifest" and configured at registration
// time. There is no GLK estate verb that reads or writes the manifest
// from a NeuronKit caller today (B-1: NeuronKit reaches the substrate
// only through estate verbs, and the verb surface exposes no manifest
// accessor). So policy persistence flows through the
// `MaintenancePolicyStore` seam: the daemon loads and saves through
// this protocol, and the production adapter binds it to the estate
// manifest when GLK exposes manifest access. Tests inject an in-memory
// store and assert the round-trip. This mirrors `DreamingPolicy` +
// `DreamingPolicyStore` exactly.

import Foundation

/// The maintenance daemon's health-scan parameters.
///
/// Defaults are the spec defaults (NEURONKIT_SPEC § 3.2 schedule and
/// thresholds): how often the daemon ticks, how often it re-verifies
/// the audit chain, the decay / tombstone age windows, and the drift
/// threshold that gates byReference-drift proposals.
///
/// Codable is synthesized, so a persisted manifest that carries keys this
/// struct no longer declares (for example a retired threshold) decodes
/// cleanly: unknown keys are ignored, never an error.
public struct MaintenancePolicy: Sendable, Equatable, Codable {

    /// Tick cadence in milliseconds. Spec default 300_000 (5 minutes,
    /// § 3.2 schedule). The daemon fires a maintenance cycle once this
    /// interval has elapsed since the last tick. The first pump always
    /// fires (no prior tick).
    public var tickIntervalMs: Int

    /// How often the audit chain is re-verified, in milliseconds. Spec
    /// default 300_000 (5 minutes). The spec § 3.5 event cadence
    /// ("every 1000 audit writes") is an event trigger the future
    /// production adapter supplies when it observes audit-write counts;
    /// the timer cadence is what the daemon itself owns. Verifying the
    /// full chain on every tick would be wasteful, so audit checking
    /// has its own (possibly slower) interval tracked independently of
    /// the scan tick.
    public var auditCheckIntervalMs: Int

    /// Age past which an active drawer is a decay candidate, in
    /// seconds. Spec default 2_592_000 (30 days). A drawer whose age
    /// relative to `now` exceeds this window is proposed as a
    /// decay/mutate candidate (the human confirms the actual decay;
    /// the daemon never mutates).
    public var decayWindowSeconds: Double

    /// Grace period past which a tombstoned (withdrawn) drawer is an
    /// expunge candidate, in seconds. Spec default 604_800 (7 days).
    /// A drawer tombstoned longer ago than this grace window is
    /// proposed for expunge confirmation.
    public var tombstoneGraceSeconds: Double

    /// LearnedReference source-drift threshold (fraction). Spec default
    /// 0.25 — when a learned reference's source content has drifted by
    /// at least this fraction, the reference may no longer be valid and
    /// a byReference-drift proposal is emitted for confirmation.
    public var byReferenceDriftThreshold: Float

    /// Designated initializer. Parameter defaults are the spec defaults
    /// (NEURONKIT_SPEC § 3.2).
    public init(
        tickIntervalMs: Int = 300_000,
        auditCheckIntervalMs: Int = 300_000,
        decayWindowSeconds: Double = 2_592_000,
        tombstoneGraceSeconds: Double = 604_800,
        byReferenceDriftThreshold: Float = 0.25
    ) {
        self.tickIntervalMs = tickIntervalMs
        self.auditCheckIntervalMs = auditCheckIntervalMs
        self.decayWindowSeconds = decayWindowSeconds
        self.tombstoneGraceSeconds = tombstoneGraceSeconds
        self.byReferenceDriftThreshold = byReferenceDriftThreshold
    }

    /// Spec-default policy (300_000 / 300_000 / 30d / 7d / 0.25).
    public static let `default` = MaintenancePolicy()
}

/// Persistence seam for the maintenance policy ("substrate-resident in
/// manifest", NEURONKIT_SPEC § 3.2).
///
/// The daemon never touches the manifest directly (B-1). It loads and
/// saves the policy through this protocol. The production adapter binds
/// these methods to the estate manifest once GLK exposes a manifest
/// accessor on the verb surface; until then the seam is satisfied by an
/// in-memory store (tests) or whatever the host wires.
public protocol MaintenancePolicyStore: Sendable {

    /// Load the persisted policy, or `nil` if none has been saved (the
    /// daemon then falls back to `MaintenancePolicy.default`).
    func loadPolicy() async throws -> MaintenancePolicy?

    /// Persist the policy. Subsequent `loadPolicy()` calls return it.
    func savePolicy(_ policy: MaintenancePolicy) async throws

    /// Load the persisted daemon cycle state, or `nil` if none has been saved
    /// (the daemon then starts from its in-memory defaults). Loaded once on
    /// `loadPersistedPolicy()` so a restart continues from the prior run's
    /// idempotency/cycle memory.
    func loadDaemonState() async throws -> MaintenanceDaemonState?

    /// Persist the daemon cycle state. The daemon calls this after each cycle.
    /// The default implementation is a no-op (in-memory only, lost on restart);
    /// the manifest-backed store overrides it to persist across restarts.
    func saveDaemonState(_ state: MaintenanceDaemonState) async throws
}

public extension MaintenancePolicyStore {
    /// Default: no daemon state persisted (returns nil, start fresh each run).
    func loadDaemonState() async throws -> MaintenanceDaemonState? { nil }
    /// Default: discard — production hosts override to persist across restarts.
    func saveDaemonState(_ state: MaintenanceDaemonState) async throws {}
}

/// The maintenance daemon's actor-local cycle state, captured for persistence
/// so a restart continues from where the prior run left off instead of
/// repeating suppressed proposals or resetting its counters.
///
/// - `lastTickAt`: the timer-path cadence baseline.
/// - `lastAuditCheckAt`: the last time the audit-integrity check ran.
/// - `proposedKeys`: maintenance proposal keys already emitted (never repeated).
///   Stored as a SORTED array so the serialized manifest value is byte-stable.
/// - `cycleCount`: number of cycles run.
/// - `lastPerformanceHealthAt`: when the daily timing-derivation health duty last
///   ran. Nil = never run. Used by the 24 h gate inside `runCycle` (A7).
///   `decodeIfPresent` keeps older persisted states loading cleanly when this
///   field is absent from the manifest.
/// - `performanceHealthWatermarkMs`: HLC physical-time watermark (epoch ms) for
///   the audit-log page cursor. 0 = start from the beginning of the log (first
///   run, or a reset). Advances to the last event's physical time after each
///   successful health duty run. `decodeIfPresent ?? 0` for backward
///   compatibility with states serialized before A7 landed.
public struct MaintenanceDaemonState: Sendable, Equatable, Codable {
    public var lastTickAt: Date?
    public var lastAuditCheckAt: Date?
    public var proposedKeys: [String]
    public var cycleCount: Int
    /// When the daily timing-derivation health duty last ran. Nil = never run.
    public var lastPerformanceHealthAt: Date?
    /// HLC physical-time watermark for the audit-log page cursor, epoch ms.
    /// 0 = start from the beginning (first run or reset).
    public var performanceHealthWatermarkMs: Int64

    public init(
        lastTickAt: Date?,
        lastAuditCheckAt: Date?,
        proposedKeys: [String],
        cycleCount: Int,
        lastPerformanceHealthAt: Date? = nil,
        performanceHealthWatermarkMs: Int64 = 0
    ) {
        self.lastTickAt = lastTickAt
        self.lastAuditCheckAt = lastAuditCheckAt
        self.proposedKeys = proposedKeys
        self.cycleCount = cycleCount
        self.lastPerformanceHealthAt = lastPerformanceHealthAt
        self.performanceHealthWatermarkMs = performanceHealthWatermarkMs
    }

    // MARK: - Codable (custom decoder for backward compatibility)

    private enum CodingKeys: String, CodingKey {
        case lastTickAt, lastAuditCheckAt, proposedKeys, cycleCount
        case lastPerformanceHealthAt, performanceHealthWatermarkMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastTickAt = try c.decodeIfPresent(Date.self, forKey: .lastTickAt)
        lastAuditCheckAt = try c.decodeIfPresent(Date.self, forKey: .lastAuditCheckAt)
        proposedKeys = try c.decode([String].self, forKey: .proposedKeys)
        cycleCount = try c.decode(Int.self, forKey: .cycleCount)
        // A7 fields: absent in states serialized before A7 landed — default to nil / 0.
        lastPerformanceHealthAt = try c.decodeIfPresent(Date.self, forKey: .lastPerformanceHealthAt)
        performanceHealthWatermarkMs = try c.decodeIfPresent(Int64.self, forKey: .performanceHealthWatermarkMs) ?? 0
    }
}

/// In-memory `MaintenancePolicyStore` for tests and for hosts that do
/// not persist policy across process restarts. Actor-isolated so
/// concurrent load/save from the daemon actor and a host are race-free.
public actor InMemoryMaintenancePolicyStore: MaintenancePolicyStore {

    private var stored: MaintenancePolicy?

    /// Create an empty store, or seed it with an initial policy.
    public init(_ initial: MaintenancePolicy? = nil) {
        self.stored = initial
    }

    public func loadPolicy() async throws -> MaintenancePolicy? { stored }

    public func savePolicy(_ policy: MaintenancePolicy) async throws {
        stored = policy
    }
}
