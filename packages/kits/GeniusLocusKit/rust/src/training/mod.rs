// training/mod.rs — Rust mirror of the GeniusLocusKit training daemon.
//
// Mission GLK-07. Parity-gated against the Swift reference under
// `GeniusLocusKit/Sources/GeniusLocusKit/Training/`. Same shape, same
// semantics, same numeric outputs against shared test vectors.
//
// References:
//   the training transition threshold  manifest-set,
//                                                  transition-count
//                                                  gate, default 500.
//   Engineering cookbook §11 / §15                 enrichment pipeline
//                                                  and daemon schedule.
//
// Conformance gate: parity tests live in `tests/training_parity.rs`
// and assert that the threshold decision, the enrichment-pass shape,
// and the daemon's tick output match the Swift reference for the
// same inputs.

pub mod daemon;
pub mod gate;
pub mod pipeline;

pub use daemon::{TrainingDaemon, TrainingDaemonReport, TrainingDaemonTick};
pub use gate::{TrainingThresholdDecision, TrainingThresholdGate};
pub use pipeline::{EnrichmentPassResult, EnrichmentPipeline};
