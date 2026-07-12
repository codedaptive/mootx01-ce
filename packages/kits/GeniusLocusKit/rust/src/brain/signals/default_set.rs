// brain/signals/default_set.rs — registration helper for the ten
// standing signals. Mirrors `DefaultStandingSignals.swift`.
//
// Signal history:
//   Signals 1–6  GLK-05: original six v1 signals.
//   Signal 7     ADR-018 F1 / 2026-06-20: TemporalCausalitySignal (hourly
//                T-population fold per DECISION_MATRIXT_HOURLY_CADENCE_2026-06-04).
//   Signal 8     DG2 / 2026-06-19: DistillationSignal (hourly distillation sweep).
//   Signal 9     ADR-018 F1 / 2026-06-20: TrainingSignal (hourly training daemon,
//                previously orphaned — zero production callers before this wire).
//   Signal 10    Contradiction hunter / 2026-07-12: ContradictionScoutSignal
//                (hourly content-conflict pass; the hunter's background half).
//
// The VectorSimilaritySignal spec is parameterized on a VectorStore (to query
// real row embeddings on each fire). Signals 7–9 use their `default_spec()`
// no-op variants here because the helper cannot supply estate-specific context
// (audit log, mutable MatrixTier, daemon instance) without breaking its
// generic signature. Production callers that want live closures register the
// signals individually via `SerialLaneScheduler::register` with the
// appropriate `spec(…)` factory.
//
// The Rust port returns the specs as a Vec; the conformance gate inspects the
// names and cadences against the Swift reference. There is no `GeniusLocusKit`
// actor in the Rust scaffold, so the helper hands the specs to the caller
// (the conformance test) which then registers them against a
// `SerialLaneScheduler` instance directly.

use std::sync::Arc;
use vectorkit::VectorStore;

use crate::brain::scheduler::api::SignalSpec;
use crate::brain::signals::{
    ByReferenceValiditySignal, ContradictionScoutSignal, DecaySweepSignal, DistillationSignal,
    DreamingSignal, EndOfDayTournamentSignal, MaintenanceSignal, TemporalCausalitySignal,
    TrainingSignal, VectorSimilaritySignal,
};

/// Stable names of the ten standing signals, in registration
/// order. Mirrors Swift's `GeniusLocusKit.defaultStandingSignalNames`.
pub fn default_standing_signal_names() -> [&'static str; 10] {
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
    ]
}

/// Build a fresh set of default specs in registration order.
///
/// `vector_store` and `model_id` are forwarded to
/// `VectorSimilaritySignal::spec` so the signal can query real row
/// embeddings on each five-minute fire.
///
/// Signals 7–9 (TemporalCausalitySignal, DistillationSignal,
/// TrainingSignal) use their `default_spec()` no-op variants because
/// this helper cannot supply estate-specific closures (fold cycle,
/// distillation cycle, training daemon) without breaking its generic
/// signature. Production callers wire live closures via the individual
/// `spec(…)` factories.
///
/// Each call mints new `Arc<dyn Fn>` closures so the conformance gate
/// can register them against multiple scheduler instances independently.
pub fn default_standing_signal_specs(
    vector_store: Arc<VectorStore>,
    model_id: impl Into<String>,
) -> Vec<SignalSpec> {
    vec![
        // No-op daemon cycle: returns zero proposals. Callers that have a live
        // DreamingDaemon should pass a real closure via DreamingSignal::spec.
        DreamingSignal::spec(Arc::new(|| vec![])),
        MaintenanceSignal::default_spec(),
        VectorSimilaritySignal::spec(
            vector_store,
            model_id.into(),
            VectorSimilaritySignal::DEFAULT_PROXIMITY_THRESHOLD,
        ),
        // Signal 10: ContradictionScoutSignal registered with its no-op
        // spec — the generic helper cannot supply the estate-specific hunt
        // closure. Production callers wire a live hunt via
        // ContradictionScoutSignal::spec(hunt_cycle) around
        // EstateCoordinator::hunt_contradictions.
        ContradictionScoutSignal::default_spec(),
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
        // Signal 9: TrainingSignal registered with its diagnostic no-op spec
        // per ADR-018 F1. Production callers wire a live training_cycle closure
        // via TrainingSignal::spec(training_cycle) to invoke
        // TrainingDaemon::run_once against the estate's audit log, matrix tier,
        // and calibration registry. The daemon's threshold gate handles the
        // dormant/active decision; below the threshold the gate short-circuits
        // and no matrix work occurs.
        TrainingSignal::default_spec(),
    ]
}
