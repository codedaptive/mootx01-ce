//! Engine types for VectorKit.
//!
//! Lane F: foundation types (hit, key, metric, payload, resident, seam) — the
//! shared types all parallel lanes depend on. A downstream lane that needs a new
//! field on any Lane F type files an FT-1 update to Lane F rather than adding it
//! locally.
//!
//! Lane A: binary brute-force index (the conformance oracle; MIH/Lane B is gated
//! against it) + `ResidentArrayStore` (the on-disk `.vec` sidecar).
//!
//! Lane B: `MIHIndex` — exact sub-linear Hamming k-NN via Multi-Index Hashing.
//! Gated against `BruteForceIndex` (Lane A oracle) in conformance tests.
//!
//! Lane C: float lane — `FloatBruteForceIndex` (exact brute-force for Float32),
//! the float lane's production path and oracle. Dense-embedding k-NN is a
//! VectorKit concern; persistence-kit owns no vector engine.

// Lane F — foundation types
pub mod hit;
pub mod key;
pub mod metric;
pub mod payload;
pub mod resident;
pub mod seam;

// Lane A — binary brute-force oracle + sidecar persistence
pub mod brute_force;
pub mod resident_store;

// Lane B — binary MIH (Multi-Index Hashing) sub-linear exact Hamming k-NN
pub mod mih;

// Lane C — float lane implementations
pub mod float_brute_force;

// Lane E1 — binary ColBERT MaxSim late interaction (Exact-A exhaustive scorer)
pub mod max_sim;

// Lane F re-exports
pub use hit::{DenseHit, LaneTag};
pub use key::VectorRecordKey;
pub use metric::{BinaryMetric, DenseMetric, FloatMetric};
pub use payload::{VectorKind, VectorPayload};
pub use resident::{ModelPartitionEntry, ResidentVectorArray};
pub use seam::{DenseIndex, IndexKind, MetadataFilter, SearchDirection};
// Lane A re-exports
pub use brute_force::BruteForceIndex;
pub use resident_store::ResidentArrayStore;
// Lane B re-exports
pub use mih::{MIHBandCount, MIHIndex};
// Lane C re-exports
pub use float_brute_force::FloatBruteForceIndex;
// Lane E1 re-exports
pub use max_sim::{MaxSimHit, MaxSimScorer};
