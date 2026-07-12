// brain/signals/mod.rs — Rust mirror of the standing signals.
//
// Mission GLK-05 (six v1 signals) + DG2 (DistillationSignal, signal 8)
// + ADR-018 F1 (TemporalCausalitySignal signal 7, TrainingSignal signal 9).
//
// Each signal is a thin factory that produces a `SignalSpec` carrying the
// same name, cadence, and emit semantics as its Swift counterpart. The
// conformance gate in `tests/standing_signals_parity.rs` feeds shared
// vectors through both ports and asserts the emission classes match.
//
// What the Rust port does NOT do: open a real QueueKit substrate or
// LocusKit recall surface. The Rust mirror's signal bodies emit the
// same demonstrative proposals/associations/diagnostics the Swift port
// emits, so the conformance gate checks the surface vocabulary and drain
// ordering. The `dreaming` signal is wired with a real daemon_cycle
// closure; other signals still emit demonstrative shapes for the
// conformance gate.

pub mod by_reference_validity;
pub mod contradiction_scout;
pub mod decay_sweep;
pub mod default_set;
pub mod distillation;
pub mod dreaming;
pub mod end_of_day_tournament;
pub mod maintenance;
pub mod temporal_causality;
pub mod training;
pub mod vector_similarity;

pub use by_reference_validity::ByReferenceValiditySignal;
pub use contradiction_scout::ContradictionScoutSignal;
pub use decay_sweep::DecaySweepSignal;
pub use default_set::{default_standing_signal_names, default_standing_signal_specs};
pub use distillation::DistillationSignal;
pub use dreaming::DreamingSignal;
pub use end_of_day_tournament::EndOfDayTournamentSignal;
pub use maintenance::MaintenanceSignal;
pub use temporal_causality::TemporalCausalitySignal;
pub use training::TrainingSignal;
pub use vector_similarity::VectorSimilaritySignal;
