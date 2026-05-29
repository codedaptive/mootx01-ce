// lib.rs — GeniusLocus reference crate root.
//
// Maps every glref-rust-<name>.rs file in this directory to a
// public module of the corresponding snake_case name. Filenames
// keep the glref-rust- prefix for documentation cross-reference
// with the cookbook and the INDEX; the crate exposes them under
// clean module paths.
//
// The reference implementations are the scalar oracle every
// shipping implementation and platform-specific kernel must
// match bit-for-bit. See README.md and INDEX.md in this folder
// for the full mapping back to cookbook sections.

#![allow(dead_code)]
#![allow(clippy::needless_return)]
#![allow(clippy::too_many_arguments)]

// The `portable_simd` unstable feature is enabled crate-wide
// only when the `simd-nightly` Cargo feature is on (requires a
// nightly toolchain). Stable builds skip it; KernelKind::Simd
// still parses on the CLI but falls through to ScalarKernel.
// See DECISION_OR_REDUCE_BACKENDS_2026-05-17.md (Axis 1).
// Phase 6.9b: portable_simd nightly feature is enabled by
// substrate-kernel (where kernel_simd lives), not here.

// === §3 Fingerprint ===
// Phase 6 (decision 2026-05-28 §6.6): the type moved to
// `substrate-types`. Re-exported as a thin module bridge so the
// 20+ existing `use crate::fingerprint256::Fingerprint256` lines
// in this crate keep working unchanged. After the atomic swap
// this re-export goes away with the legacy package.
pub mod fingerprint256 {
    pub use substrate_types::fingerprint256::*;
}
// Phase 6.9a (decision 2026-05-28 §6): simhash moved to substrate-types.
pub mod simhash { pub use substrate_types::simhash::*; }

// Phase 6.9c (decision 2026-05-28 §6): float_simhash moved to substrate-ml.
pub mod float_simhash { pub use substrate_ml::float_simhash::*; }
// Phase 6.9a (decision 2026-05-28 §6): hyperplane moved to substrate-types.
pub mod hyperplane { pub use substrate_types::hyperplane::*; }
// Phase 6.9c (decision 2026-05-28 §6): feature_extractors moved to substrate-ml.
pub mod feature_extractors { pub use substrate_ml::feature_extractors::*; }

// === §4 Runtime layout ===
#[path = "glref-rust-bit_tensor.rs"]
pub mod bit_tensor;
#[path = "glref-rust-working_set.rs"]
pub mod working_set;
#[path = "glref-rust-sqlite_tail.rs"]
pub mod sqlite_tail;
// Phase 6.9b (decision 2026-05-28 §6): kernel moved to substrate-kernel.
pub mod kernel { pub use substrate_kernel::kernel::*; }
#[cfg(feature = "simd-nightly")]
// Phase 6.9b (decision 2026-05-28 §6): kernel_simd moved to substrate-kernel.
pub mod kernel_simd { pub use substrate_kernel::kernel_simd::*; }

// === §5 HLC (migrated to substrate-types per Phase 6.2) ===
pub mod hlc {
    pub use substrate_types::hlc::*;
}
#[path = "glref-rust-gset.rs"]
pub mod gset;

// === §6 Matrix tier ===
// Phase 6.7 (decision 2026-05-28 §6.6): matrix_f moved to substrate-types.
pub mod matrix_f {
    pub use substrate_types::matrix_f::*;
}
// Phase 6.7 (decision 2026-05-28 §6.6): matrix_c moved to substrate-types.
pub mod matrix_c {
    pub use substrate_types::matrix_c::*;
}
// Phase 6.7 (decision 2026-05-28 §6.6): matrix_o moved to substrate-types.
pub mod matrix_o {
    pub use substrate_types::matrix_o::*;
}
// Phase 6.7 (decision 2026-05-28 §6.6): matrix_t moved to substrate-types.
pub mod matrix_t {
    pub use substrate_types::matrix_t::*;
}
#[path = "glref-rust-action_outcome.rs"]
pub mod action_outcome;
// Phase 6.9c (decision 2026-05-28 §6): calibration moved to substrate-ml.
pub mod calibration { pub use substrate_ml::calibration::*; }
#[path = "glref-rust-decay.rs"]
pub mod decay;
// Phase 6.9c (decision 2026-05-28 §6): nmf moved to substrate-ml.
pub mod nmf { pub use substrate_ml::nmf::*; }

// === §7 Estate-as-graph ===
// Phase 6.9c (decision 2026-05-28 §6): eigenvalue_centrality moved to substrate-ml.
pub mod eigenvalue_centrality { pub use substrate_ml::eigenvalue_centrality::*; }
// Phase 6.9c (decision 2026-05-28 §6): community_detection moved to substrate-ml.
pub mod community_detection { pub use substrate_ml::community_detection::*; }
// Phase 6.9c (decision 2026-05-28 §6): random_walks moved to substrate-ml.
pub mod random_walks { pub use substrate_ml::random_walks::*; }

// === §8 Algorithms ===
// Phase 6.9a (decision 2026-05-28 §6): hamming moved to substrate-types.
pub mod hamming { pub use substrate_types::hamming::*; }
#[path = "glref-rust-hamming_nn.rs"]
pub mod hamming_nn;
// Phase 6.9c (decision 2026-05-28 §6): lattice_distance moved to substrate-ml.
pub mod lattice_distance { pub use substrate_ml::lattice_distance::*; }
// Phase 6.9c (decision 2026-05-28 §6): composite_distance moved to substrate-ml.
pub mod composite_distance { pub use substrate_ml::composite_distance::*; }
// Phase 6.9a (decision 2026-05-28 §6): or_reduce moved to substrate-types.
pub mod or_reduce { pub use substrate_types::or_reduce::*; }
// Phase 6.9a (decision 2026-05-28 §6): bitwise moved to substrate-types.
pub mod bitwise { pub use substrate_types::bitwise::*; }

#[path = "glref-rust-bit_field.rs"]
pub mod bit_field;

// Phase 6.9c (decision 2026-05-28 §6): fnv moved to substrate-types.
pub mod fnv { pub use substrate_types::fnv::*; }

#[path = "glref-rust-sha256.rs"]
pub mod sha256;

#[path = "glref-rust-audit_gate.rs"]
pub mod audit_gate;
// Phase 6.9c (decision 2026-05-28 §6): moment_summary moved to substrate-ml.
pub mod moment_summary { pub use substrate_ml::moment_summary::*; }
// Phase 6.9a (decision 2026-05-28 §6): count_vector moved to substrate-types.
pub mod count_vector { pub use substrate_types::count_vector::*; }
#[path = "glref-rust-partial_state_recall.rs"]
pub mod partial_state_recall;
// Phase 6.9c (decision 2026-05-28 §6): fft moved to substrate-ml.
pub mod fft { pub use substrate_ml::fft::*; }
// Phase 6.9c (decision 2026-05-28 §6): info_theory moved to substrate-ml.
pub mod info_theory { pub use substrate_ml::info_theory::*; }
// Phase 6.9c (decision 2026-05-28 §6): bradley_terry moved to substrate-ml.
pub mod bradley_terry { pub use substrate_ml::bradley_terry::*; }
// Phase 6.9c (decision 2026-05-28 §6): anomaly moved to substrate-ml.
pub mod anomaly { pub use substrate_ml::anomaly::*; }
// Phase 6.9c (decision 2026-05-28 §6): temporal_compression moved to substrate-ml.
pub mod temporal_compression { pub use substrate_ml::temporal_compression::*; }
#[path = "glref-rust-audit_log_fold.rs"]
pub mod audit_log_fold;

// === §9 Row-state automaton + §10 Verbs ===
#[path = "glref-rust-row_state.rs"]
pub mod row_state;
#[path = "glref-rust-verbs.rs"]
pub mod verbs;

// === §11 CognitionKit ===
#[path = "glref-rust-cognition_kit.rs"]
pub mod cognition_kit;

// === §12 Federation ===
#[path = "glref-rust-pairing.rs"]
pub mod pairing;
#[path = "glref-rust-tier_contribution.rs"]
pub mod tier_contribution;
#[path = "glref-rust-tier_query.rs"]
pub mod tier_query;
#[path = "glref-rust-dp_or_reduce.rs"]
pub mod dp_or_reduce;

// === §13 Cognition Bundle ===
#[path = "glref-rust-cognition_bundle.rs"]
pub mod cognition_bundle;

// === §14 ActuatorKit ===
#[path = "glref-rust-actuator.rs"]
pub mod actuator;

// === §15 Dreaming daemon ===
#[path = "glref-rust-dreaming.rs"]
pub mod dreaming;
