// brain/signals/default_set.rs — registration helper for the six v1
// standing signals. Mirrors `DefaultStandingSignals.swift`.
//
// The Rust port returns the specs as a Vec; the conformance gate
// inspects the names and cadences against the Swift reference. There
// is no `GeniusLocusKit` actor in the Rust scaffold, so the helper
// hands the specs to the caller (the conformance test) which then
// registers them against a `SerialLaneScheduler` instance directly.

use crate::brain::scheduler::api::SignalSpec;
use crate::brain::signals::{
    ByReferenceValiditySignal, DecaySweepSignal, DreamingSignal, EndOfDayTournamentSignal,
    MaintenanceSignal, VectorSimilaritySignal,
};

/// Stable names of the six v1 standing signals, in registration
/// order. Mirrors Swift's `GeniusLocusKit.defaultStandingSignalNames`.
pub fn default_standing_signal_names() -> [&'static str; 6] {
    [
        DreamingSignal::SIGNAL_NAME,
        MaintenanceSignal::SIGNAL_NAME,
        VectorSimilaritySignal::SIGNAL_NAME,
        DecaySweepSignal::SIGNAL_NAME,
        ByReferenceValiditySignal::SIGNAL_NAME,
        EndOfDayTournamentSignal::SIGNAL_NAME,
    ]
}

/// Build a fresh set of default specs in registration order. Each
/// call mints new `Arc<dyn Fn>` closures so the conformance gate can
/// register them against multiple scheduler instances independently.
pub fn default_standing_signal_specs() -> Vec<SignalSpec> {
    vec![
        DreamingSignal::default_spec(),
        MaintenanceSignal::default_spec(),
        VectorSimilaritySignal::default_spec(),
        DecaySweepSignal::default_spec(),
        ByReferenceValiditySignal::default_spec(),
        EndOfDayTournamentSignal::default_spec(),
    ]
}
