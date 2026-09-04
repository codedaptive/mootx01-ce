// brain/signals/default_set.rs — registration helper for the thirteen
// standing signals. Mirrors `DefaultStandingSignals.swift`.
//
// Signal history:
//   Signals 1–6  GLK-05: original six v1 signals.
//   Signal 7     brain-layer governor ownership  / 2026-06-20: TemporalCausalitySignal (hourly
//                T-population fold).
//   Signal 8     DG2 / 2026-06-19: DistillationSignal (hourly distillation sweep).
//   Signal 9     brain-layer governor ownership  / 2026-06-20: TrainingSignal (hourly training daemon,
//                previously orphaned — zero production callers before this wire).
//   Signal 10    Contradiction hunter / 2026-07-12: ContradictionScoutSignal
//                (hourly content-conflict pass; the hunter's background half).
//   Signal 11    Consolidation sweep / 2026-07-30: ConsolidationSignal
//                (daily Wave-2 consolidation, D9 cadence class). Rust twin of
//                ConsolidationSignal.swift.
//   Signal 12    P3a / 2026-08-20: AnomalySweepSignal (hourly room-cohesion
//                anomaly-flag sweep, sets/clears bit 26 via z-score). Rust twin
//                of AnomalySweepSignal.swift.
//   Signal 13    GENIUSLOCUSKIT_SPEC 2.0.0 § 16 / 2026-08-23: AdornmentPassSignal
//                (hourly dream-time minting pass, writes StoredAdornment rows for
//                (drawer, active-minter) pairs; pair-model — batch_size counts
//                PAIRS, per-pair failure isolation, never disables a minter).
//                Rust twin of AdornmentPassSignal.swift.
//
// The VectorSimilaritySignal spec is parameterized on a VectorStore (to query
// real row embeddings on each fire). Signals 7–12 use their `default_spec()`
// no-op variants here because the helper cannot supply estate-specific context
// (audit log, mutable MatrixTier, daemon instance, consolidation cycle, estate
// handle for anomaly sweep) without breaking its generic signature. Production
// callers that want live closures register the signals individually via
// `SerialLaneScheduler::register` with the appropriate `spec(…)` factory.
//
// The Rust port returns the specs as a Vec; the conformance gate inspects the
// names and cadences against the Swift reference. There is no `GeniusLocusKit`
// actor in the Rust scaffold, so the helper hands the specs to the caller
// (the conformance test) which then registers them against a
// `SerialLaneScheduler` instance directly.

use std::sync::Arc;
use synapsekit::VectorStore;

use crate::brain::scheduler::api::SignalSpec;
use crate::brain::signals::{
    AdornmentPassSignal, AnomalySweepSignal, ByReferenceValiditySignal, ConsolidationSignal,
    ContradictionScoutSignal, DecaySweepSignal, DistillationSignal, DreamingSignal,
    EndOfDayTournamentSignal, MaintenanceSignal, TemporalCausalitySignal, TrainingSignal,
    VectorSimilaritySignal,
};

/// Stable names of the thirteen standing signals, in registration
/// order. Mirrors Swift's `GeniusLocusKit.defaultStandingSignalNames`.
pub fn default_standing_signal_names() -> [&'static str; 13] {
    [
        DreamingSignal::SIGNAL_NAME,
        MaintenanceSignal::SIGNAL_NAME,
        VectorSimilaritySignal::SIGNAL_NAME,
        ContradictionScoutSignal::SIGNAL_NAME,
        DecaySweepSignal::SIGNAL_NAME,
        ByReferenceValiditySignal::SIGNAL_NAME,
        EndOfDayTournamentSignal::SIGNAL_NAME,
        TemporalCausalitySignal::SIGNAL_NAME,
        DistillationSignal::SIGNAL_NAME,
        TrainingSignal::SIGNAL_NAME,
        ConsolidationSignal::SIGNAL_NAME,
        AnomalySweepSignal::SIGNAL_NAME,
        AdornmentPassSignal::SIGNAL_NAME,
    ]
}

/// Build a fresh set of default specs in registration order.
///
/// `vector_store` and `model_id` are forwarded to
/// `VectorSimilaritySignal::spec` so the signal can query real row
/// embeddings on each five-minute fire.
///
/// `hunt_cycle`, `anomaly_cycle`, and `adornment_cycle` are optional live
/// closures for signals 10, 12, and 13 respectively. When `Some`, the live
/// `spec(…)` factory is used so the resident's real `EstateCoordinator`
/// methods are called on each fire. When `None`, the diagnostic-only
/// `default_spec()` is used (no-op, correct for test contexts and callers
/// that have not yet wired a live estate). This matches the Swift
/// `registerDefaultStandingSignals(huntCycle:anomalyCycle:adornmentCycle:)`
/// parameter pattern where all three default to the no-op closure.
///
/// Signals 7–9 and 11 (TemporalCausalitySignal, DistillationSignal,
/// TrainingSignal, ConsolidationSignal) retain their `default_spec()` no-op
/// variants in this helper — their estate-specific closures require additional
/// context (MatrixTier, audit log, distillation engine) that this generic
/// helper cannot supply. Production callers wire those via the individual
/// `spec(…)` factories if needed.
///
/// Each call mints new `Arc<dyn Fn>` closures so the conformance gate
/// can register them against multiple scheduler instances independently.
pub fn default_standing_signal_specs(
    vector_store: Arc<VectorStore>,
    model_id: impl Into<String>,
    corpus: Option<Arc<corpus_kit::CorpusContentEngine>>,
    hunt_cycle: Option<Arc<dyn Fn() -> Result<(usize, usize), String> + Send + Sync>>,
    anomaly_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
    adornment_cycle: Option<Arc<dyn Fn() -> Result<i64, String> + Send + Sync>>,
) -> Vec<SignalSpec> {
    // Signal 10: ContradictionScoutSignal. Use the live hunt closure when
    // provided; fall back to the diagnostic no-op. Mirrors Swift's default
    // `huntCycle: { _ in (0, 0) }` parameter in registerDefaultStandingSignals.
    //
    // The `dyn Fn` inside the Arc is not Sized, so we wrap it in a concrete
    // closure that calls the inner Arc — this gives spec<F> a concrete F: Sized.
    let scout_spec = match hunt_cycle {
        Some(f) => {
            ContradictionScoutSignal::spec(Arc::new(move || f()))
        }
        None => ContradictionScoutSignal::default_spec(),
    };
    // Signal 12: AnomalySweepSignal (P3a). Use the live anomaly closure when
    // provided; fall back to the diagnostic no-op. Mirrors Swift's default
    // `anomalyCycle: { _ in 0 }` parameter in registerDefaultStandingSignals.
    //
    // Same Sized-wrapping pattern as the hunt closure above.
    let anomaly_spec = match anomaly_cycle {
        Some(f) => {
            AnomalySweepSignal::spec(Arc::new(move || f()))
        }
        None => AnomalySweepSignal::default_spec(),
    };
    // Signal 13: AdornmentPassSignal (SPEC_ADORNMENT §4). Use the live
    // adornment closure when provided; fall back to the diagnostic no-op.
    // Mirrors Swift's default `adornmentCycle: { _ in 0 }` parameter in
    // registerDefaultStandingSignals.
    //
    // Same Sized-wrapping pattern as the hunt and anomaly closures above.
    let adornment_spec = match adornment_cycle {
        Some(f) => AdornmentPassSignal::spec(Arc::new(move || f())),
        None => AdornmentPassSignal::default_spec(),
    };
    vec![
        // No-op daemon cycle: returns zero proposals. Callers that have a live
        // DreamingDaemon should pass a real closure via DreamingSignal::spec.
        DreamingSignal::spec(Arc::new(|| vec![])),
        MaintenanceSignal::default_spec(),
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
        DecaySweepSignal::default_spec(),
        ByReferenceValiditySignal::default_spec(),
        EndOfDayTournamentSignal::default_spec(),
        // Signal 7: TemporalCausalitySignal registered with its diagnostic
        // no-op spec. Production callers wire a live fold closure via
        // TemporalCausalitySignal::spec(fold_cycle) to run the hourly
        // T-population pass against the estate's MatrixTier and audit log.
        TemporalCausalitySignal::default_spec(),
        // Signal 8: DistillationSignal registered with its diagnostic no-op
        // spec. Production callers wire a live distillation_cycle closure via
        // DistillationSignal::spec(distillation_cycle) to run the per-item
        // distillation sweep on each hourly fire.
        DistillationSignal::default_spec(),
        // Signal 9: TrainingSignal registered with its diagnostic no-op spec.
        // Production callers wire a live training_cycle closure
        // via TrainingSignal::spec(training_cycle) to invoke
        // TrainingDaemon::run_once against the estate's audit log, matrix tier,
        // and calibration registry. The daemon's threshold gate handles the
        // dormant/active decision; below the threshold the gate short-circuits
        // and no matrix work occurs.
        TrainingSignal::default_spec(),
        // Signal 11: ConsolidationSignal registered with its diagnostic no-op
        // spec. Production callers wire a live consolidation_cycle closure via
        // ConsolidationSignal::spec(consolidation_cycle) to invoke
        // EstateCoordinator::consolidation_sweep_report on each daily fire
        // (Wave-2 D9 cadence).
        ConsolidationSignal::default_spec(),
        // Signal 12: AnomalySweepSignal (P3a) — live or no-op per anomaly_cycle above.
        anomaly_spec,
        // Signal 13: AdornmentPassSignal (SPEC_ADORNMENT §4) — live or no-op per
        // adornment_cycle above. Hourly dream-time minting pass over
        // (drawer, active-minter) pairs: per-pair failure isolation, writes
        // StoredAdornment rows via LocusKit; batch counts pairs.
        adornment_spec,
    ]
}
