// matrix/mod.rs — Rust mirror of the matrix tier.
//
// Mission GLK-06. Parity-gated against the Swift reference under
// `GeniusLocusKit/Sources/GeniusLocusKit/Matrix/`. Same shape, same
// semantics, same numeric outputs against shared test vectors.
//
// Cookbook references (engineering cookbook v0.36):
//   §6.1  F: field-presence dense count
//   §6.2  C: derived correlation F / N_rows
//   §6.3  O: sparse co-occurrence
//   §6.4  T: sparse temporal causality, log-spaced lag
//   §6.6  LLM calibration curves (20 buckets)
//   §6.8  Lazy multiplicative decay
//   §6.9  NMF latent factors (multiplicative ALS)
//
// Substrate mathematics §8 names the same family and defines the
// invariants the conformance harness asserts.

pub mod calibration;
#[allow(clippy::module_inception)]
// matrix module inside matrix/ is intentional — the matrix.rs file defines MatrixTier, the module's primary type
pub mod matrix;
pub mod nmf;
pub mod persistence;

pub use calibration::{
    MatrixCalibrationBucket, MatrixCalibrationCurve, MatrixCalibrationOutcome,
    MatrixCalibrationRegistry,
};
pub use matrix::{
    MatrixCoOccurKey, MatrixFieldCell, MatrixTemporalKey, MatrixTier, MatrixValueCoord,
};
pub use nmf::{MatrixNMF, MatrixNMFFactorization};
pub use persistence::{
    MatrixPersistenceBackend, MatrixPersistenceError, MatrixPersistenceMode, MatrixSnapshot,
};
