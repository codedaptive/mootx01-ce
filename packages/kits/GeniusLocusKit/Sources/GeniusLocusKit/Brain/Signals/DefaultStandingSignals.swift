import Foundation
import LocusKit
import SynapseKit

/// Registration helper for the thirteen standing signals — architecture
/// spec §11.2 plus the contradiction scout (signal 10, the hunter's
/// background half), consolidation sweep (signal 11), the
/// anomaly-flag sweep (signal 12, P3a), and the span-encode drain
/// (signal 13, ENCODER_RERANK_CONTRACT §10 — replaces adornment pass),
/// and the harness-gated distilled-fact drain (signal 14).
/// Signal 8's slot (the stored-distillation sweep) is empty: the distilled
/// rendering is computed inline at read time, so nothing sweeps for it.
///
/// Calling `registerDefaultStandingSignals(in:now:)` registers all
/// thirteen default signal specs against the addressed estate's scheduler
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
/// hourly temporal-matrix scheduling, superseding the
/// weekly cadence in cookbook §6.4. It is registered using
/// `defaultSpec()` (diagnostic no-op); production callers wire a live
/// fold closure via `TemporalCausalitySignal.spec(foldCycle:)`.
///
/// Signal 9 (TrainingSignal) was wired. Production
/// callers supply a `trainingCycle` closure that invokes
/// `TrainingDaemon.runOnce` against the estate's audit log, matrix
/// tier, and calibration registry. The daemon's own threshold gate
/// handles the
/// dormant/active decision; the signal fires the daemon unconditionally
/// and the gate short-circuits below the threshold.
///
/// Signal 12 (AnomalySweepSignal) was wired in P3a. Production callers
/// supply an `anomalyCycle` closure that wraps
/// `kit.anomalyFlagSweep(handle:now:)` and returns the count of
/// drawers whose `isAnomalous` bit changed.
///
/// Signal 13 (SpanEncodeSignal) replaces the former AdornmentPassSignal.
/// Production callers supply a `spanEncodeCycle` closure that wraps
/// `kit.runSpanEncodeBatch(handle:encoder:store:now:)` with the estate,
/// encoder, and vector store; the drain encodes unindexed drawers into
/// int8 span vectors (contract §3) and sets bit 27 (spanIndexed) on success.
public extension GeniusLocusKit {

    /// Names of the thirteen standing signals, in the order they are
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
            TrainingSignal.signalName,
            ConsolidationSignal.signalName,
            AnomalySweepSignal.signalName,
            SpanEncodeSignal.signalName,
            FactExtractionSignal.signalName,
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
    ///   - anomalyCycle: async closure forwarded to
    ///     `AnomalySweepSignal.spec(anomalyCycle:)`. The caller wraps
    ///     `kit.anomalyFlagSweep(handle:now:)` with the estate handle here;
    ///     the sweep sets/clears bit 26 and the closure returns the count of
    ///     changed drawers. Defaults to a no-op returning zero — correct for
    ///     test registration where no live sweep is wired.
    ///   - spanEncodeCycle: async closure forwarded to
    ///     `SpanEncodeSignal.spec(spanEncodeCycle:)`. The caller wraps
    ///     `kit.runSpanEncodeBatch(handle:encoder:store:now:)` with the estate
    ///     handle, the session's active `SpanEncoder`, and the estate's
    ///     `VectorStore` here; the drain encodes drawers with bit 27 clear into
    ///     int8 span rows and sets bit 27 (spanIndexed, contract §5) on success.
    ///     Defaults to a no-op returning zero — correct for test registration
    ///     where no live encoder is wired.
    ///   - factExtractionCycle: async closure forwarded to
    ///     `FactExtractionSignal.spec(factExtractionCycle:)`. It runs one
    ///     bounded batch under the active extractor recipe. The default is
    ///     inert while the feature remains in harness qualification.
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
        trainingCycle: @escaping @Sendable (Date) async throws -> String = { _ in "" },
        huntCycle: @escaping @Sendable (Date) async throws -> (proposed: Int, borderline: Int)
            = { _ in (0, 0) },
        anomalyCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        spanEncodeCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        factExtractionCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        modelID: String = "minilm-v6",
        now: Date
    ) async throws -> [String: SignalID] {
        let specs: [SignalSpec] = [
            DreamingSignal.spec(daemonCycle: dreamingCycle),
            MaintenanceSignal.defaultSpec(),
            // The estate's Corpus (when registered) enables the signal's
            // chunk-keyed corpus lane — the only vector-row population
            // production estates hold. Without it, the signal scans only
            // drawer-keyed `modelID` rows and finds nothing on a real
            // install.
            VectorSimilaritySignal.spec(
                vectorStore: vectorStore, modelID: modelID,
                corpus: corpusKits[handle]),
            // Contradiction scout — the hunter's background half. The caller
            // wraps kit.huntContradictions with the estate's handle/model;
            // the no-op default is appropriate for tests without a wired
            // hunter (same convention as dreaming/training).
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
            // TrainingSignal wired with the injected trainingCycle closure per
            // brain-layer governor ownership. The caller wraps TrainingDaemon.runOnce against the
            // estate's audit log, matrix tier, and calibration registry. The
            // daemon's threshold gate
            // decides whether to actually enrich on each hourly fire; the signal
            // invokes runOnce unconditionally. The default no-op is appropriate
            // for tests without a live daemon instance.
            TrainingSignal.spec(trainingCycle: trainingCycle),
            // ConsolidationSignal (Wave-2 D9): daily maintenance-window fire
            // running one bounded consolidation sweep. Registered here as the
            // diagnostic-only defaultSpec — the live cycle needs the estate
            // handle + distillFn, which this generic registration cannot
            // supply; production callers re-register with
            // ConsolidationSignal.spec(consolidationCycle:) at daemon wiring
            // (the same pattern TemporalCausalitySignal documents above).
            ConsolidationSignal.defaultSpec(),
            // AnomalySweepSignal (P3a, signal 12): hourly room-cohesion
            // sweep that sets/clears bit 26 (isAnomalous) based on
            // char-3-shingle Jaccard z-scores. The caller wraps
            // kit.anomalyFlagSweep with the estate handle; the default
            // no-op is appropriate for test registration where no live
            // sweep is available.
            AnomalySweepSignal.spec(anomalyCycle: anomalyCycle),
            // SpanEncodeSignal (ENCODER_RERANK_CONTRACT §10, signal 13):
            // REM-ALPHA (30 s) drain that encodes drawers with bit 27 clear
            // into int8 span vectors (vectors_v6) and sets bit 27 (spanIndexed)
            // on success. Replaces the hourly AdornmentPassSignal. The caller
            // wraps kit.runSpanEncodeBatch(handle:encoder:store:now:);
            // the default no-op is appropriate for test registration where
            // no live encoder is wired.
            SpanEncodeSignal.spec(spanEncodeCycle: spanEncodeCycle),
            // Signal 14: bounded fact extraction over bit-28 debt. The host
            // closure calls runFactExtractionBatch only after explicit recipe
            // activation; otherwise the default is a diagnostic no-op.
            FactExtractionSignal.spec(factExtractionCycle: factExtractionCycle),
        ]
        var registered: [String: SignalID] = [:]
        for spec in specs {
            let id = try await registerStandingSignal(spec, in: handle, now: now)
            registered[spec.name] = id
        }
        return registered
    }
}
