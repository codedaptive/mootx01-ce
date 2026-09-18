// brain/signals/default_set.rs — registration helper for the standing
// signals: six always-on plus eight preference-gated (consolidation sweep,
// contradiction sweep, the maintenance family: maintenance-daemon,
// decay-sweep, by-reference-validity, and the adaptive-recall trio:
// temporal-causality-fold, training-daemon, end-of-day-tournament). Mirrors
// `DefaultStandingSignals.swift`.
//
// Signal history:
//   Signals 1–6  GLK-05: original six v1 signals.
//   Signal 7     brain-layer governor ownership / 2026-06-20: TemporalCausalitySignal (hourly
//                T-population fold).
//   Signal 8     Empty slot: the distilled rendering is computed inline at
//                read time (Encoder Rerank contract sheet §9), so no sweep
//                signal exists for it.
//   Signal 9     brain-layer governor ownership / 2026-06-20: TrainingSignal (hourly training daemon,
//                previously orphaned — zero production callers before this wire).
//   Signal 10    Contradiction hunter / 2026-07-12: ContradictionScoutSignal
//                (hourly content-conflict pass; the hunter's background half).
//   Signal 11    Consolidation sweep / 2026-07-30: ConsolidationSignal
//                (daily Wave-2 consolidation, D9 cadence class). Rust twin of
//                ConsolidationSignal.swift.
//   Signal 12    P3a / 2026-08-20: AnomalySweepSignal (hourly room-cohesion
//                anomaly-flag sweep, sets/clears bit 26 via z-score). Rust twin
//                of AnomalySweepSignal.swift.
//   Signal 13    ENCODER_RERANK_CONTRACT §10 / 2026-09-05: SpanEncodeSignal
//                (REM-ALPHA 30 s span-encode drain; writes int8 vectors to
//                vectors_v6, sets bit 27 spanIndexed). Rust twin of SpanEncodeSignal.swift.
//   Signal 14    Distilled Fact Extraction / 2026-09-08: bounded bit-28
//                extraction debt drain. Rust twin of FactExtractionSignal.swift.
//   Gated        ContradictionSweepSignal (hourly tiered conflict-tunnel
//                proposer). Registered, like signal 11, only when the host
//                passes a live cycle; the host reads the estate preference.
//
// The VectorSimilaritySignal spec is parameterized on a VectorStore (to query
// real row embeddings on each fire).
//
// The consolidation sweep (signal 11), the contradiction sweep, the
// maintenance family (signals 2, 5, 6) and the adaptive-recall trio
// (signals 7, 9 and the end-of-day tournament) are preference-gated: they have no `default_spec()`,
// and the helper pushes them only when handed a live closure. The host
// reads the estate's `consolidation` / `contradiction_sweep` /
// `maintenance` / `adaptive_recall` preference and passes `None` when it
// is `Off`, so an opted-out estate carries no such signal at all. Each
// maintenance-family signal runs one category of the NeuronKit maintenance
// engine (`MaintenanceDaemon::run_cycle_scoped`) on its own cadence; the
// adaptive-recall trio runs `EstateCoordinator::run_temporal_causality_fold`,
// `EstateCoordinator::run_training_tick` and
// `EstateCoordinator::end_of_day_tournament`.
//
// The Rust port returns the specs as a Vec; the conformance gate inspects the
// names and cadences against the Swift reference. There is no `GeniusLocusKit`
// actor in the Rust scaffold, so the helper hands the specs to the caller
// (the conformance test) which then registers them against a
// `SerialLaneScheduler` instance directly.

use std::sync::Arc;
use synapsekit::VectorStore;

use crate::brain::conflict_projection_sweep::ConflictTunnelProposalReport;
use crate::brain::consolidation_cycle::ConsolidationSweepReport;
use crate::brain::end_of_day_tournament::TournamentReport;
use crate::brain::scheduler::api::SignalSpec;
use crate::brain::signals::{
    AnomalySweepSignal, ByReferenceValiditySignal, ConsolidationSignal,
    ContradictionScoutSignal, ContradictionSweepSignal, DecaySweepSignal, DreamingSignal,
    EndOfDayTournamentSignal, FactExtractionSignal, MaintenanceSignal, SpanEncodeSignal, TemporalCausalitySignal,
    TrainingSignal, VectorSimilaritySignal,
};

/// Stable names of the six always-on standing signals, in registration
/// order. Mirrors Swift's `GeniusLocusKit.defaultStandingSignalNames`. The
/// eight preference-gated signals are listed separately in
/// `preference_gated_standing_signal_names` so this count stays exact for
/// an estate that has opted out of any of them.
pub fn default_standing_signal_names() -> [&'static str; 6] {
    [
        DreamingSignal::SIGNAL_NAME,
        VectorSimilaritySignal::SIGNAL_NAME,
        ContradictionScoutSignal::SIGNAL_NAME,
        AnomalySweepSignal::SIGNAL_NAME,
        SpanEncodeSignal::SIGNAL_NAME,
        FactExtractionSignal::SIGNAL_NAME,
    ]
}

/// Stable names of the eight preference-gated standing signals that
/// `default_standing_signal_specs` includes only when handed a live cycle
/// closure: the consolidation sweep (estate preference `consolidation`),
/// the contradiction sweep (`contradiction_sweep`), the maintenance
/// family — maintenance-daemon, decay-sweep, by-reference-validity — which
/// share the `maintenance` preference, and the adaptive-recall trio —
/// temporal-causality-fold, training-daemon, end-of-day-tournament — which
/// share the `adaptive_recall` preference. Mirrors Swift's
/// `GeniusLocusKit.preferenceGatedStandingSignalNames`.
pub fn preference_gated_standing_signal_names() -> [&'static str; 8] {
    [
        ConsolidationSignal::SIGNAL_NAME,
        ContradictionSweepSignal::SIGNAL_NAME,
        MaintenanceSignal::SIGNAL_NAME,
        DecaySweepSignal::SIGNAL_NAME,
        ByReferenceValiditySignal::SIGNAL_NAME,
        TemporalCausalitySignal::SIGNAL_NAME,
        TrainingSignal::SIGNAL_NAME,
        EndOfDayTournamentSignal::SIGNAL_NAME,
    ]
}

/// Build a fresh set of default specs in registration order.
///
/// `vector_store` and `model_id` are forwarded to
/// `VectorSimilaritySignal::spec` so the signal can query real row
/// embeddings on each five-minute fire.
///
/// `hunt_cycle`, `anomaly_cycle`, `span_encode_cycle`, and
/// `fact_extraction_cycle` are optional live closures for signals 10, 12, 13,
/// and 14 respectively. When `Some`, the live
/// `spec(…)` factory is used so the resident's real `EstateCoordinator`
/// methods are called on each fire. When `None`, the diagnostic-only
/// `default_spec()` is used (no-op, correct for test contexts and callers
/// that have not yet wired a live estate). This matches the Swift
/// `registerDefaultStandingSignals(huntCycle:anomalyCycle:spanEncodeCycle:)`
/// parameter pattern where all four default to the no-op closure.
///
/// `maintenance_cycle`, `decay_cycle` and `by_reference_cycle` are the
/// maintenance-family closures (one category of the NeuronKit maintenance
/// engine each, returning that category's candidate count). Gated together
/// on the `maintenance` preference: `Some` pushes the live `spec`, `None`
/// pushes nothing. Mirrors the Swift `maintenanceCycle:` / `decayCycle:` /
/// `byReferenceCycle:` optionals that default to nil.
///
/// `consolidation_cycle` and `contradiction_sweep_cycle` are the other two
/// preference-gated closures. `Some` pushes the live
/// `ConsolidationSignal::spec` / `ContradictionSweepSignal::spec`; `None`
/// pushes nothing, so neither signal exists on the scheduler. The host
/// passes `None` when the estate's `consolidation` / `contradiction_sweep`
/// preference is `Off`. Mirrors the Swift `consolidationCycle:` /
/// `contradictionSweepCycle:` optionals that default to nil.
///
/// `fold_cycle`, `training_cycle` and `tournament_cycle` are the
/// adaptive-recall trio: the hourly T-population fold (signal 7), the hourly
/// training-daemon tick (signal 9) and the daily end-of-day tournament
/// (`EstateCoordinator::end_of_day_tournament`, which folds the day's recall
/// traces into `recall_ratings`). Gated together on the `adaptive_recall`
/// preference: `Some` pushes the live `TemporalCausalitySignal::spec` /
/// `TrainingSignal::spec` / `EndOfDayTournamentSignal::spec`, `None` pushes
/// nothing. Mirrors the Swift `foldCycle:` / `trainingCycle:` /
/// `tournamentCycle:` optionals that default to nil.
///
/// Each call mints new `Arc<dyn Fn>` closures so the conformance gate
/// can register them against multiple scheduler instances independently.
pub fn default_standing_signal_specs(
    vector_store: Arc<VectorStore>,
    model_id: impl Into<String>,
    corpus: Option<Arc<corpus_kit::CorpusContentEngine>>,
    hunt_cycle: Option<Arc<dyn Fn() -> Result<(usize, usize), String> + Send + Sync>>,
    anomaly_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    span_encode_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    fact_extraction_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    consolidation_cycle: Option<
        Arc<dyn Fn() -> Result<ConsolidationSweepReport, String> + Send + Sync>,
    >,
    contradiction_sweep_cycle: Option<
        Arc<dyn Fn() -> Result<ConflictTunnelProposalReport, String> + Send + Sync>,
    >,
    maintenance_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    decay_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    by_reference_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    fold_cycle: Option<Arc<dyn Fn() -> Result<(), String> + Send + Sync>>,
    training_cycle: Option<Arc<dyn Fn() -> Result<String, String> + Send + Sync>>,
    tournament_cycle: Option<Arc<dyn Fn() -> Result<TournamentReport, String> + Send + Sync>>,
) -> Vec<SignalSpec> {
    // Signal 10: ContradictionScoutSignal. Use the live hunt closure when
    // provided; fall back to the diagnostic no-op. Mirrors Swift's default
    // `huntCycle: { _ in (0, 0) }` parameter in registerDefaultStandingSignals.
    //
    // The `dyn Fn` inside the Arc is not Sized, so we wrap it in a concrete
    // closure that calls the inner Arc — this gives spec<F> a concrete F: Sized.
    let scout_spec = match hunt_cycle {
        Some(f) => ContradictionScoutSignal::spec(Arc::new(move || f())),
        None => ContradictionScoutSignal::default_spec(),
    };
    // Signal 12: AnomalySweepSignal (P3a). Use the live anomaly closure when
    // provided; fall back to the diagnostic no-op. Mirrors Swift's default
    // `anomalyCycle: { _ in 0 }` parameter in registerDefaultStandingSignals.
    //
    // Same Sized-wrapping pattern as the hunt closure above.
    let anomaly_spec = match anomaly_cycle {
        Some(f) => AnomalySweepSignal::spec(Arc::new(move || f())),
        None => AnomalySweepSignal::default_spec(),
    };
    // Signal 13: SpanEncodeSignal (ENCODER_RERANK_CONTRACT §10). Use the live
    // span-encode closure when provided; fall back to the diagnostic no-op.
    // Mirrors Swift's default `spanEncodeCycle: { _ in 0 }` parameter in
    // registerDefaultStandingSignals. REM-ALPHA cadence (30 s).
    //
    // Same Sized-wrapping pattern as the hunt and anomaly closures above.
    let span_encode_spec = match span_encode_cycle {
        Some(f) => SpanEncodeSignal::spec(Arc::new(move || f())),
        None => SpanEncodeSignal::default_spec(),
    };
    let fact_extraction_spec = match fact_extraction_cycle {
        Some(f) => FactExtractionSignal::spec(Arc::new(move || f())),
        None => FactExtractionSignal::default_spec(),
    };
    let mut specs = vec![
        // No-op daemon cycle: returns zero proposals. Callers that have a live
        // DreamingDaemon should pass a real closure via DreamingSignal::spec.
        DreamingSignal::spec(Arc::new(|| vec![])),
        // The estate's Corpus (when registered) enables the signal's
        // chunk-keyed corpus lane — the only vector-row population
        // production estates hold. Without it, the signal scans only
        // drawer-keyed `model_id` rows and finds nothing on a real install.
        VectorSimilaritySignal::spec(
            vector_store,
            model_id.into(),
            VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
            VectorSimilaritySignal::DEFAULT_PROBE_LIMIT,
            corpus,
            None, // edge_checker: DB-level uniqueness (LocusKit v10) prevents
                  // duplicates; wire a checker for production frame-churn reduction.
        ),
        // Signal 10: ContradictionScoutSignal — live or no-op per hunt_cycle above.
        scout_spec,
    ];
    // Signal 11: ConsolidationSignal — daily maintenance-window fire running
    // one bounded consolidation sweep (EstateCoordinator::consolidation_sweep_report).
    // Preference-gated: pushed only when the host passes a live cycle; with
    // `None` the signal is not registered, so an opted-out estate never
    // schedules it. Same Sized-wrapping pattern as the closures above.
    if let Some(f) = consolidation_cycle {
        specs.push(ConsolidationSignal::spec(Arc::new(move || f())));
    }
    specs.extend([
        // Signal 12: AnomalySweepSignal (P3a) — live or no-op per anomaly_cycle above.
        anomaly_spec,
        // Signal 13: SpanEncodeSignal (ENCODER_RERANK_CONTRACT §10) — live or no-op
        // per span_encode_cycle above. REM-ALPHA (30 s) drain that encodes drawers
        // with bit 27 clear into int8 span rows (vectors_v6) and sets bit 27
        // (spanIndexed, contract §5) on success.
        span_encode_spec,
        // Signal 14: explicitly activated distilled-fact duty. Default
        // registration is inert; hosts with a runtime register the live spec.
        fact_extraction_spec,
    ]);
    // ContradictionSweepSignal: hourly tiered conflict-tunnel proposer
    // (EstateCoordinator::propose_conflict_tunnels). Preference-gated like
    // consolidation: pushed only when the host passes a live cycle.
    if let Some(f) = contradiction_sweep_cycle {
        specs.push(ContradictionSweepSignal::spec(Arc::new(move || f())));
    }
    // Maintenance family: each signal runs one category of the NeuronKit
    // maintenance engine on its own cadence (tombstone hourly, decay daily,
    // by-reference weekly). Preference-gated on `maintenance`: the host
    // passes live cycles over the governor's engine only when the preference
    // is not `Off`; with `None` nothing is registered.
    if let Some(f) = maintenance_cycle {
        specs.push(MaintenanceSignal::spec(Arc::new(move || f())));
    }
    if let Some(f) = decay_cycle {
        specs.push(DecaySweepSignal::spec(Arc::new(move || f())));
    }
    if let Some(f) = by_reference_cycle {
        specs.push(ByReferenceValiditySignal::spec(Arc::new(move || f())));
    }
    // Adaptive-recall trio: signal 7 (hourly T-population fold over the
    // audit tail, `EstateCoordinator::run_temporal_causality_fold`),
    // signal 9 (hourly training-daemon tick,
    // `EstateCoordinator::run_training_tick`; the daemon's threshold gate
    // keeps the tick dormant below the transition threshold) and the daily
    // end-of-day tournament (`EstateCoordinator::end_of_day_tournament`,
    // folding the day's recall traces into `recall_ratings`). Preference-
    // gated on `adaptive_recall`: pushed only when the resident passes a
    // live cycle; with `None` nothing is registered.
    if let Some(f) = fold_cycle {
        specs.push(TemporalCausalitySignal::spec(Arc::new(move || f())));
    }
    if let Some(f) = training_cycle {
        specs.push(TrainingSignal::spec(Arc::new(move || f())));
    }
    if let Some(f) = tournament_cycle {
        specs.push(EndOfDayTournamentSignal::spec(Arc::new(move || f())));
    }
    specs
}
