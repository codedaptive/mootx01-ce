// brain/signals/mod.rs — Rust mirror of the six v1 standing signals.
//
// Mission GLK-05. Each signal is a thin factory that produces a
// `SignalSpec` carrying the same name, cadence, and emit semantics as
// its Swift counterpart. The conformance gate in
// `tests/standing_signals_parity.rs` feeds shared vectors through both
// ports and asserts the emission classes match.
//
// What the Rust port does NOT do: open a real QueueKit substrate or
// LocusKit recall surface. The Rust mirror's signal bodies emit the
// same demonstrative proposals/associations/diagnostics the Swift port
// emits, so the conformance gate checks the surface vocabulary and
// drain ordering — not the substrate-level work the bodies will do
// when the Brain layer's verb bodies land.

pub mod dreaming;
pub mod maintenance;
pub mod vector_similarity;
pub mod decay_sweep;
pub mod by_reference_validity;
pub mod end_of_day_tournament;
pub mod default_set;

pub use dreaming::DreamingSignal;
pub use maintenance::MaintenanceSignal;
pub use vector_similarity::VectorSimilaritySignal;
pub use decay_sweep::DecaySweepSignal;
pub use by_reference_validity::ByReferenceValiditySignal;
pub use end_of_day_tournament::EndOfDayTournamentSignal;
pub use default_set::{default_standing_signal_names, default_standing_signal_specs};
