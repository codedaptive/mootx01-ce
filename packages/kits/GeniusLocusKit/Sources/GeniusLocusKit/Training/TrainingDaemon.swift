// TrainingDaemon.swift
//
// Mission GLK-07 — The training daemon.
//
// The training daemon enriches captured content and trains the GLK-06
// matrices, but only once the estate crosses the transition-count
// threshold defined by DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21.
// Below the threshold the daemon is dormant — every tick still
// surfaces a diagnostic emission, but no enrichment work runs and no
// matrix cells move.
//
// Composition. The daemon is a Sendable engine — not an actor —
// because its only mutable state is the high-water mark, and the
// daemon is run from inside the GLK-04 scheduler's per-estate actor.
// The scheduler already serialises every tick against one estate
// (DECISION_STANDING_SIGNAL_SCHEDULER_2026-05-21); adding an actor
// here would double-isolate without buying anything.
//
// Registration. A consumer wires the daemon into the scheduler by
// authoring a `SignalSpec` whose `emit` closure invokes
// `runOnce(...)` against the consumer-owned matrix tier and
// calibration registry, and yields a diagnostic emission so the
// signal report carries the daemon's heartbeat. The training daemon
// type itself does not couple to the scheduler API — see the
// scheduler-registration test in `TrainingDaemonTests` for the
// canonical wiring shape.
//
// Determinism. `runOnce` takes the matrices `inout` and the audit
// log by value; no `Date()` calls; the watermark is held inside the
// daemon. Two daemons fed the same inputs produce the same outputs,
// which is what the Rust conformance harness asserts.

import Foundation
import OSLog
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

// MARK: - Tick report

/// One tick's outcome. The daemon's diagnostic emission carries a
/// summary derived from this report, and the test harness asserts
/// against it directly.
public struct TrainingDaemonTick: Sendable, Equatable, Codable {
    /// The gate's verdict at the start of the tick. Carries both the
    /// transition count and the configured threshold so callers can
    /// surface progress toward activation.
    public let decision: TrainingThresholdDecision

    /// What the enrichment pass did. `EnrichmentPassResult.empty`
    /// when the gate was closed.
    public let passResult: EnrichmentPassResult

    /// Captured for diagnostic logging — the watermark the daemon
    /// will use on the next tick. Equals `passResult.highWaterMark`
    /// when the gate was open; carries the prior watermark unchanged
    /// when it was closed.
    public let watermarkAfter: HLC

    public init(decision: TrainingThresholdDecision,
                passResult: EnrichmentPassResult,
                watermarkAfter: HLC) {
        self.decision = decision
        self.passResult = passResult
        self.watermarkAfter = watermarkAfter
    }
}

/// Manual `Codable` for `TrainingThresholdDecision` so
/// `TrainingDaemonTick` is wholly Codable. Kept here (not on the gate
/// file) so the gate type stays minimal; the conformance gate only
/// needs the Codable shape from the tick report onward.
extension TrainingThresholdDecision: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, transitionCount, threshold
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let state = try c.decode(String.self, forKey: .state)
        let n = try c.decode(Int.self, forKey: .transitionCount)
        let t = try c.decode(Int.self, forKey: .threshold)
        switch state {
        case "active":
            self = .active(transitionCount: n, threshold: t)
        default:
            self = .dormant(transitionCount: n, threshold: t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dormant(let n, let t):
            try c.encode("dormant", forKey: .state)
            try c.encode(n, forKey: .transitionCount)
            try c.encode(t, forKey: .threshold)
        case .active(let n, let t):
            try c.encode("active", forKey: .state)
            try c.encode(n, forKey: .transitionCount)
            try c.encode(t, forKey: .threshold)
        }
    }
}

// MARK: - Diagnostic report shape

/// Convenience for consumers building the daemon's per-tick
/// diagnostic emission. Keeps the title / detail format consistent
/// across estates so log scrapers can rely on a single shape.
public struct TrainingDaemonReport: Sendable, Equatable, Codable {
    public let estateUUID: UUID
    public let tick: TrainingDaemonTick

    public init(estateUUID: UUID, tick: TrainingDaemonTick) {
        self.estateUUID = estateUUID
        self.tick = tick
    }

    public var diagnosticTitle: String {
        tick.decision.isActive
            ? "training.daemon.active"
            : "training.daemon.dormant"
    }

    public var diagnosticDetail: String {
        "estate=\(estateUUID.uuidString.lowercased()) " +
        "transitions=\(tick.decision.transitionCount)/" +
        "\(tick.decision.threshold) " +
        "considered=\(tick.passResult.transitionsConsidered) " +
        "f=\(tick.passResult.fCellsTouched) " +
        "o=\(tick.passResult.oKeysTouched)"
    }
}

// MARK: - Daemon

/// The training daemon engine. Final class so the high-water mark is
/// shared across ticks without copying; `@unchecked Sendable` because
/// the only mutation point (`watermark`) is serialised by the GLK-04
/// scheduler's per-estate actor that owns the registered signal.
public final class TrainingDaemon: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "com.mootx01.kit",
        category: "TrainingDaemon")

    /// The admission gate. Manifest-set at construction; reused across
    /// every tick. Immutable so two daemons sharing the same gate
    /// value stay in sync.
    public let gate: TrainingThresholdGate

    /// The enrichment pipeline. Stateless — held here so callers do
    /// not have to mint a pipeline per tick.
    public let pipeline: EnrichmentPipeline

    /// Highest HLC the daemon has consumed across ticks. Advanced
    /// only when the gate is open and the pipeline actually folds
    /// entries; a closed-gate tick leaves the watermark unchanged so
    /// the moment the threshold is crossed the daemon picks up the
    /// full backlog from `.zero`.
    private var watermark: HLC = .zero

    /// Construct a daemon. The pipeline argument is exposed so tests
    /// can inject a custom pipeline; production code uses the default.
    public init(
        gate: TrainingThresholdGate = TrainingThresholdGate(),
        pipeline: EnrichmentPipeline = EnrichmentPipeline()
    ) {
        self.gate = gate
        self.pipeline = pipeline
    }

    /// Reset the watermark to `.zero`. Used by callers that want the
    /// next tick to re-scan the full audit log — for example after a
    /// matrix snapshot is restored from disk and the daemon should
    /// fold any post-snapshot tail. Exposed as a single entry-point so
    /// the watermark is never mutated externally.
    public func resetWatermark() {
        watermark = .zero
    }

    // MARK: - Tick

    /// Run one daemon pass over `log`. The decision and pass result
    /// are returned together; the diagnostic emission shape is left
    /// to the caller because the scheduler signal layer is what
    /// surfaces the emission (and a future MCP exporter may want a
    /// different wire shape than the Codable struct here).
    public func runOnce(
        log: UnifiedAuditLog,
        tier: inout MatrixTier,
        calibration: inout MatrixCalibrationRegistry
    ) async -> TrainingDaemonTick {
        let count = TrainingThresholdGate.transitionCount(in: log)
        let decision = gate.decide(transitionCount: count)
        guard decision.isActive else {
            // Dormant tick. No enrichment work. Watermark untouched
            // so the next tick that finds the gate open will fold in
            // the full backlog.
            Self.logger.debug("training daemon dormant: \(count)/\(self.gate.transitionThreshold)")
            return TrainingDaemonTick(
                decision: decision,
                passResult: .empty,
                watermarkAfter: watermark)
        }
        let pass = pipeline.run(
            log: log,
            tier: &tier,
            calibration: &calibration,
            highWaterMark: watermark)
        watermark = pass.highWaterMark
        Self.logger.debug("training daemon active: folded \(pass.transitionsConsidered) entries")
        return TrainingDaemonTick(
            decision: decision,
            passResult: pass,
            watermarkAfter: watermark)
    }
}
