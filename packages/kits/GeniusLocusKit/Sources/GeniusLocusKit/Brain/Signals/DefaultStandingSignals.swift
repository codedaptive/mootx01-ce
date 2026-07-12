import Foundation
import LocusKit
import VectorKit

/// Registration helper for the ten standing signals — architecture
/// spec §11.2 plus the contradiction scout (signal 10, the hunter's
/// background half).
///
/// Calling `registerDefaultStandingSignals(in:now:)` registers all
/// ten default signal specs against the addressed estate's scheduler
/// at their architecture-spec cadences. The returned dictionary maps
/// each signal's stable name to its freshly-minted `SignalID` so the
/// application can subscribe, inspect, or unregister selectively.
///
/// Order of registration is fixed and stable: the dictionary's keys
/// are the signal-name constants from each signal file. The scheduler
/// itself orders dispatch by `SignalID.rawValue`, so registration
/// order is a property of this helper rather than of the scheduler.
///
/// Signal 7 (TemporalCausalitySignal) was added 2026-06-04 per
/// DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04.md, superseding the
/// weekly cadence in cookbook §6.4. It is registered using
/// `defaultSpec()` (diagnostic no-op); production callers wire a live
/// fold closure via `TemporalCausalitySignal.spec(foldCycle:)`.
///
/// Signal 8 (DistillationSignal) was wired in DG5. Production callers
/// supply a `distillationCycle` closure that runs the per-item
/// distillation sweep and returns the count of factoids produced.
///
/// Signal 9 (TrainingSignal) was wired per ADR-018 F1. Production
/// callers supply a `trainingCycle` closure that invokes
/// `TrainingDaemon.runOnce` against the estate's audit log, matrix
/// tier, and calibration registry. The daemon's own threshold gate
/// (DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21) handles the
/// dormant/active decision; the signal fires the daemon unconditionally
/// and the gate short-circuits below the threshold.
public extension GeniusLocusKit {

    /// Names of the ten standing signals, in the order they are
    /// registered by `registerDefaultStandingSignals`. Exposed as a
    /// stable array so tests and diagnostics can assert against the
    /// vocabulary without hard-coding string literals.
    static var defaultStandingSignalNames: [String] {
        [
            DreamingSignal.signalName,
            MaintenanceSignal.signalName,
            VectorSimilaritySignal.signalName,
            ContradictionScoutSignal.signalName,
            DecaySweepSignal.signalName,
            ByReferenceValiditySignal.signalName,
            EndOfDayTournamentSignal.signalName,
            TemporalCausalitySignal.signalName,
            DistillationSignal.signalName,
            TrainingSignal.signalName,
        ]
    }

    /// Register every architecture-spec §11.2 standing signal against
    /// the addressed estate's scheduler at its default cadence.
    ///
    /// - Parameters:
    ///   - handle: the estate to register against. Must be an open
    ///     handle in `handles`.
    ///   - vectorStore: the estate's `VectorStore`, passed to
    ///     `VectorSimilaritySignal.spec(vectorStore:modelID:)` so the
    ///     signal can query real row embeddings on each fire.
    ///   - dreamingCycle: the daemon cycle closure forwarded to
    ///     `DreamingSignal.spec(daemonCycle:)`. The caller constructs a
    ///     `DreamingDaemon` (NeuronKit) with production adapters and wraps
    ///     `daemon.triggerDreamingCycle(now:).proposalsEmitted.count` here.
    ///     The daemon writes proposals via `EstateDreamingSink`; the closure
    ///     returns only the count so the scheduler records activity without
    ///     re-dispatching already-persisted frames (single-write invariant).
    ///     Defaults to a no-op that returns zero — correct for test
    ///     registration where no live daemon is available.
    ///   - distillationCycle: async closure forwarded to
    ///     `DistillationSignal.spec(distillationCycle:)`. The caller wraps
    ///     the per-item distillation sweep (`kit.distillItemsSweep`) with
    ///     the estate handle and a NeuronKit-backed `distillFn` closure here.
    ///     Defaults to a no-op that returns zero factoids — correct for
    ///     test registration where no live distillation engine is available.
    ///   - trainingCycle: async closure forwarded to
    ///     `TrainingSignal.spec(trainingCycle:)`. The caller wraps
    ///     `TrainingDaemon.runOnce` with the estate's audit log, matrix
    ///     tier, and calibration registry here. The daemon's threshold
    ///     gate decides whether to enrich on each invocation; below the
    ///     threshold the daemon is dormant and no matrix work runs.
    ///     Defaults to a no-op that returns an empty detail string —
    ///     correct for test registration where no live daemon is available.
    ///   - huntCycle: async closure forwarded to
    ///     `ContradictionScoutSignal.spec(huntCycle:)`. The caller wraps
    ///     `kit.huntContradictions` with the estate handle and model ID;
    ///     the hunt persists proposed contradicts tunnels itself and the
    ///     closure returns (proposed, borderline) counts. Defaults to a
    ///     no-op returning zeros — correct for test registration where no
    ///     live hunter is wired.
    ///   - modelID: the embedding model whose stored vectors are scanned
    ///     by the vector-similarity signal. Default `"minilm-v6"`.
    ///   - now: the deterministic clock — flowed through to the
    ///     scheduler's registration so interval triggers schedule
    ///     their first run relative to a known time.
    /// - Returns: a name → SignalID map, one entry per signal.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is
    ///   not in the registry.
    @discardableResult
    func registerDefaultStandingSignals(
        in handle: EstateHandle,
        vectorStore: VectorStore,
        dreamingCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        distillationCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        trainingCycle: @escaping @Sendable (Date) async throws -> String = { _ in "" },
        huntCycle: @escaping @Sendable (Date) async throws -> (proposed: Int, borderline: Int)
            = { _ in (0, 0) },
        modelID: String = "minilm-v6",
        now: Date
    ) async throws -> [String: SignalID] {
        let specs: [SignalSpec] = [
            DreamingSignal.spec(daemonCycle: dreamingCycle),
            MaintenanceSignal.defaultSpec(),
            VectorSimilaritySignal.spec(vectorStore: vectorStore, modelID: modelID),
            // Contradiction scout — the hunter's background half. The caller
            // wraps kit.huntContradictions with the estate's handle/model;
            // the no-op default is appropriate for tests without a wired
            // hunter (same convention as dreaming/distillation/training).
            ContradictionScoutSignal.spec(huntCycle: huntCycle),
            DecaySweepSignal.defaultSpec(),
            ByReferenceValiditySignal.defaultSpec(),
            EndOfDayTournamentSignal.defaultSpec(),
            // TemporalCausalitySignal registered with its diagnostic no-op
            // spec. Production callers replace this with
            // TemporalCausalitySignal.spec(foldCycle:) to wire a live fold
            // closure. The default is appropriate here because
            // registerDefaultStandingSignals cannot supply estate-specific
            // context (audit log, mutable MatrixTier) without breaking the
            // method's generic signature.
            TemporalCausalitySignal.defaultSpec(),
            // DistillationSignal wired with the injected distillationCycle closure
            // per architecture spec §11.2, signal 8 (DG5). The caller supplies
            // a closure that runs the per-item distillation sweep; the default
            // no-op (returns 0) is appropriate for tests without a live sweep engine.
            DistillationSignal.spec(distillationCycle: distillationCycle),
            // TrainingSignal wired with the injected trainingCycle closure per
            // ADR-018 F1. The caller wraps TrainingDaemon.runOnce against the
            // estate's audit log, matrix tier, and calibration registry. The
            // daemon's threshold gate (DECISION_TRAINING_DAEMON_THRESHOLD_2026-05-21)
            // decides whether to actually enrich on each hourly fire; the signal
            // invokes runOnce unconditionally. The default no-op is appropriate
            // for tests without a live daemon instance.
            TrainingSignal.spec(trainingCycle: trainingCycle),
        ]
        var registered: [String: SignalID] = [:]
        for spec in specs {
            let id = try await registerStandingSignal(spec, in: handle, now: now)
            registered[spec.name] = id
        }
        return registered
    }
}
