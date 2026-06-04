// brain/signals/default_set.rs — registration helper for the six v1
// standing signals. Mirrors `DefaultStandingSignals.swift`.
//
// The VectorSimilaritySignal spec is now parameterized on a VectorStore
// (to query real row embeddings on each fire). All other five signals
// remain parameter-free. The Rust port returns the specs as a Vec; the
// conformance gate inspects the names and cadences against the Swift
// reference. There is no `GeniusLocusKit` actor in the Rust scaffold, so
// the helper hands the specs to the caller (the conformance test) which
// then registers them against a `SerialLaneScheduler` instance directly.

use std::sync::Arc;
use vectorkit::VectorStore;

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

/// Build a fresh set of default specs in registration order.
///
/// `vector_store` and `model_id` are forwarded to
/// `VectorSimilaritySignal::spec` so the signal can query real row
/// embeddings on each five-minute fire.
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
        DecaySweepSignal::default_spec(),
        ByReferenceValiditySignal::default_spec(),
        EndOfDayTournamentSignal::default_spec(),
    ]
}
