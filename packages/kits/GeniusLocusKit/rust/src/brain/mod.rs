// brain/mod.rs — Rust mirror of the GeniusLocusKit Brain layer.
//
// Mission GLK-04. Parity-gated against the Swift reference under
// `GeniusLocusKit/Sources/GeniusLocusKit/Brain/`. The conformance
// shape is the four-emission-class contract (architecture spec
// §11.1), the SignalEmission classTag vocabulary, and the single
// serial-lane drain ordering. The shared vectors live in
// `tests/scheduler_parity.rs` and the Swift counterparts are
// asserted in `StandingSignalSchedulerTests.swift`.
//
// What this scaffold does NOT do: open a real Rust QueueKit. The
// Rust port of QueueKit does not exist (the decision
// `DECISION_STANDING_SIGNAL_SCHEDULER_2026-05-21` defines QueueKit
// as a Swift kit consumed by GeniusLocusKit Swift only). The Rust
// mirror's serial lane is an in-process FIFO with the same drain
// guarantee — exactly one drainer per estate, jobs applied in
// submission order. Parity is on the surface vocabulary and drain
// ordering semantics, not the storage substrate.

pub mod cluster_status;
pub mod distillation_cycle;
pub mod event_lag_pairs;
pub mod scheduler;
pub mod signals;
