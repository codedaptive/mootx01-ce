import Foundation
import LocusKit
import SynapseKit

/// Registration helper for the standing signals — architecture
/// spec §11.2 plus the contradiction scout (signal 10, the hunter's
/// background half), consolidation sweep (signal 11), the
/// anomaly-flag sweep (signal 12, P3a), the span-encode drain
/// (signal 13, ENCODER_RERANK_CONTRACT §10), the harness-gated
/// distilled-fact drain (signal 14), and the contradiction sweep
/// (tiered conflict-tunnel proposals).
/// Signal 8's slot (the stored-distillation sweep) is empty: the distilled
/// rendering is computed inline at read time, so nothing sweeps for it.
///
/// Calling `registerDefaultStandingSignals(in:now:)` registers the six
/// always-on signal specs (`defaultStandingSignalNames`) against the
/// addressed estate's scheduler at their architecture-spec cadences. The
/// eight preference-gated signals (`preferenceGatedStandingSignalNames`:
/// consolidation sweep, contradiction sweep, the maintenance family —
/// maintenance-daemon, decay-sweep, by-reference-validity — and the
/// adaptive-recall trio — temporal-causality-fold, training-daemon,
/// end-of-day-tournament) register only when the caller passes a live cycle closure — the host
/// reads the estate's `.consolidation` / `.contradictionSweep` /
/// `.maintenance` / `.adaptiveRecall` preference and passes nil when it is
/// `.off`, so an opted-out estate carries no such signal at all.
/// The returned dictionary maps
/// each signal's stable name to its freshly-minted `SignalID` so the
/// application can subscribe, inspect, or unregister selectively.
///
/// Order of registration is fixed and stable: the dictionary's keys
/// are the signal-name constants from each signal file. The scheduler
/// itself orders dispatch by `SignalID.rawValue`, so registration
/// order is a property of this helper rather than of the scheduler.
///
/// Signal 7 (TemporalCausalitySignal, hourly T-population fold),
/// signal 9 (TrainingSignal, hourly training-daemon tick) and the daily
/// EndOfDayTournamentSignal are the adaptive-recall trio. The host wraps
/// `kit.runTemporalCausalityFold`, `kit.runTrainingTick` and
/// `kit.endOfDayTournament` and passes them only while the estate's
/// `.adaptiveRecall` preference is not `.off`. The daemon's own threshold
/// gate handles the dormant/active decision; the signal fires the daemon
/// unconditionally and the gate short-circuits below the threshold.
///
/// Signal 12 (AnomalySweepSignal) was wired in P3a. Production callers
/// supply an `anomalyCycle` closure that wraps
/// `kit.anomalyFlagSweep(handle:now:)` and returns the count of
/// drawers whose `isAnomalous` bit changed.
///
/// Signal 13 (SpanEncodeSignal): production callers supply a `spanEncodeCycle`
/// closure that wraps
/// `kit.runSpanEncodeBatch(handle:encoder:store:now:)` with the estate,
/// encoder, and vector store; the drain encodes unindexed drawers into
/// int8 span vectors (contract §3) and sets bit 27 (spanIndexed) on success.
public extension GeniusLocusKit {

    /// Names of the six always-on standing signals, in the order they
    /// are registered by `registerDefaultStandingSignals`. Exposed as a
    /// stable array so tests and diagnostics can assert against the
    /// vocabulary without hard-coding string literals. The eight
    /// preference-gated signals are listed separately in
    /// `preferenceGatedStandingSignalNames` so this count stays exact for
    /// an estate that has opted out of any of them.
    static var defaultStandingSignalNames: [String] {
        [
            DreamingSignal.signalName,
            VectorSimilaritySignal.signalName,
            ContradictionScoutSignal.signalName,
            AnomalySweepSignal.signalName,
            SpanEncodeSignal.signalName,
            FactExtractionSignal.signalName,
        ]
    }

    /// Names of the eight preference-gated standing signals that
    /// `registerDefaultStandingSignals` registers only when handed a live
    /// cycle closure: the consolidation sweep (estate preference
    /// `.consolidation`), the contradiction sweep (`.contradictionSweep`),
    /// the maintenance family — maintenance-daemon, decay-sweep and
    /// by-reference-validity — which share the `.maintenance` preference
    /// and each drive one category of the NeuronKit maintenance engine,
    /// and the adaptive-recall trio — temporal-causality-fold,
    /// training-daemon and end-of-day-tournament — which share the
    /// `.adaptiveRecall` preference: the first two keep the matrix tier
    /// learning from the audit log, the third folds the day's recall traces
    /// into `recall_ratings`.
    static var preferenceGatedStandingSignalNames: [String] {
        [
            ConsolidationSignal.signalName,
            ContradictionSweepSignal.signalName,
            MaintenanceSignal.signalName,
            DecaySweepSignal.signalName,
            ByReferenceValiditySignal.signalName,
            TemporalCausalitySignal.signalName,
            TrainingSignal.signalName,
            EndOfDayTournamentSignal.signalName,
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
    ///   - consolidationCycle: optional async closure forwarded to
    ///     `ConsolidationSignal.spec(consolidationCycle:)`. The host wraps
    ///     `kit.consolidationSweepReport(handle:distillFn:now:)` with the
    ///     estate handle and `GeniusLocusKit.consolidationDistillFn`, and
    ///     passes it only when the estate's `.consolidation` preference is
    ///     not `.off`. nil (the default) registers no consolidation signal.
    ///   - contradictionSweepCycle: optional async closure forwarded to
    ///     `ContradictionSweepSignal.spec(sweepCycle:)`. The host wraps
    ///     `kit.proposeConflictTunnels(in:now:)` with the estate handle and
    ///     passes it only when the estate's `.contradictionSweep` preference
    ///     is not `.off`. nil (the default) registers no contradiction-sweep
    ///     signal.
    ///   - maintenanceCycle: optional async closure forwarded to
    ///     `MaintenanceSignal.spec(maintenanceCycle:)`. The host wraps the
    ///     governor's `MaintenanceDaemon.triggerMaintenanceCycle(now:categories:
    ///     [.tombstone])` and returns `tombstoneCandidates`; passed only when
    ///     the estate's `.maintenance` preference is not `.off`. nil (the
    ///     default) registers no maintenance-daemon signal.
    ///   - decayCycle: optional async closure forwarded to
    ///     `DecaySweepSignal.spec(decayCycle:)` — the same call with
    ///     `[.decay]`, returning `decayCandidates`. Same gate as above.
    ///   - byReferenceCycle: optional async closure forwarded to
    ///     `ByReferenceValiditySignal.spec(byReferenceCycle:)` — the same
    ///     call with `[.byReference]`, returning `byReferenceDrifts`. Same
    ///     gate as above.
    ///   - foldCycle: optional async closure forwarded to
    ///     `TemporalCausalitySignal.spec(foldCycle:)`. The host wraps
    ///     `kit.runTemporalCausalityFold(_:now:)` and passes it only when
    ///     the estate's `.adaptiveRecall` preference is not `.off`. nil (the
    ///     default) registers no temporal-causality-fold signal.
    ///   - trainingCycle: optional async closure forwarded to
    ///     `TrainingSignal.spec(trainingCycle:)`. The host wraps
    ///     `kit.runTrainingTick(_:now:)`, which runs `TrainingDaemon.runOnce`
    ///     over the estate's audit log, matrix tier and calibration registry;
    ///     the daemon's threshold gate decides whether to enrich on each
    ///     invocation. Same `.adaptiveRecall` gate as `foldCycle`. nil (the
    ///     default) registers no training-daemon signal.
    ///   - tournamentCycle: optional async closure forwarded to
    ///     `EndOfDayTournamentSignal.spec(tournamentCycle:)`. The host wraps
    ///     `kit.endOfDayTournament(_:now:)`, which folds the day's recall
    ///     traces into `recall_ratings` rows and returns the report. Same
    ///     `.adaptiveRecall` gate as `foldCycle`. nil (the default) registers
    ///     no end-of-day-tournament signal.
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
        huntCycle: @escaping @Sendable (Date) async throws -> (proposed: Int, borderline: Int)
            = { _ in (0, 0) },
        anomalyCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        spanEncodeCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        factExtractionCycle: @escaping @Sendable (Date) async throws -> Int = { _ in 0 },
        consolidationCycle: (@Sendable (Date) async throws -> ConsolidationSweepReport)? = nil,
        contradictionSweepCycle: (@Sendable (Date) async throws -> ConflictTunnelProposalReport)? = nil,
        maintenanceCycle: (@Sendable (Date) async throws -> Int)? = nil,
        decayCycle: (@Sendable (Date) async throws -> Int)? = nil,
        byReferenceCycle: (@Sendable (Date) async throws -> Int)? = nil,
        foldCycle: (@Sendable (Date) async throws -> Void)? = nil,
        trainingCycle: (@Sendable (Date) async throws -> String)? = nil,
        tournamentCycle: (@Sendable (Date) async throws -> TournamentReport)? = nil,
        modelID: String = "minilm-v6",
        now: Date
    ) async throws -> [String: SignalID] {
        var specs: [SignalSpec] = [
            DreamingSignal.spec(daemonCycle: dreamingCycle),
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
        ]
        // ConsolidationSignal (signal 11): daily maintenance-window fire
        // running one bounded consolidation sweep. Preference-gated: the
        // host passes a live cycle (kit.consolidationSweepReport with the
        // estate handle and distill function) only when the estate's
        // `.consolidation` preference is not `.off`; with no cycle the
        // signal is not registered, so an opted-out estate never
        // schedules it.
        if let consolidationCycle {
            specs.append(ConsolidationSignal.spec(consolidationCycle: consolidationCycle))
        }
        specs.append(contentsOf: [
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
            // on success. The caller
            // wraps kit.runSpanEncodeBatch(handle:encoder:store:now:);
            // the default no-op is appropriate for test registration where
            // no live encoder is wired.
            SpanEncodeSignal.spec(spanEncodeCycle: spanEncodeCycle),
            // Signal 14: bounded fact extraction over bit-28 debt. The host
            // closure calls runFactExtractionBatch only after explicit recipe
            // activation; otherwise the default is a diagnostic no-op.
            FactExtractionSignal.spec(factExtractionCycle: factExtractionCycle),
        ])
        // ContradictionSweepSignal: hourly tiered conflict-tunnel proposer.
        // Preference-gated like consolidation: the host passes a live cycle
        // (kit.proposeConflictTunnels with the estate handle) only when the
        // `.contradictionSweep` preference is not `.off`; with no cycle
        // nothing is registered.
        if let contradictionSweepCycle {
            specs.append(ContradictionSweepSignal.spec(sweepCycle: contradictionSweepCycle))
        }
        // Maintenance family: each signal runs one category of the NeuronKit
        // maintenance engine on its own cadence (tombstone hourly, decay
        // daily, by-reference weekly). Preference-gated on `.maintenance`:
        // the host passes live cycles over the governor's daemon only when
        // the preference is not `.off`; with no cycle nothing is registered.
        if let maintenanceCycle {
            specs.append(MaintenanceSignal.spec(maintenanceCycle: maintenanceCycle))
        }
        if let decayCycle {
            specs.append(DecaySweepSignal.spec(decayCycle: decayCycle))
        }
        if let byReferenceCycle {
            specs.append(ByReferenceValiditySignal.spec(byReferenceCycle: byReferenceCycle))
        }
        // Adaptive-recall trio: the hourly T-population fold (signal 7) and
        // the hourly training-daemon tick (signal 9) keep the matrix tier
        // learning from the audit log; the daily end-of-day tournament folds
        // the day's recall traces into recall_ratings. Preference-gated on
        // `.adaptiveRecall`: the host passes live cycles over
        // kit.runTemporalCausalityFold / kit.runTrainingTick /
        // kit.endOfDayTournament only when the preference is not `.off`;
        // with no cycle nothing is registered.
        if let foldCycle {
            specs.append(TemporalCausalitySignal.spec(foldCycle: foldCycle))
        }
        if let trainingCycle {
            specs.append(TrainingSignal.spec(trainingCycle: trainingCycle))
        }
        if let tournamentCycle {
            specs.append(EndOfDayTournamentSignal.spec(tournamentCycle: tournamentCycle))
        }
        var registered: [String: SignalID] = [:]
        for spec in specs {
            let id = try await registerStandingSignal(spec, in: handle, now: now)
            registered[spec.name] = id
        }
        return registered
    }
}
