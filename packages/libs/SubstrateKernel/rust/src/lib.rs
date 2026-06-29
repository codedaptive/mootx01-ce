//! substrate-kernel — Layer 2 of the three-package SubstrateLib split
//! per DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.
//!
//! Hardware-dispatched fast paths. `ScalarKernel` (in this crate's
//! `kernel` module) is the oracle; all other kernels must produce
//! bit-identical output for the same inputs (conformance-gated).
//!
//! Currently hosts:
//!   - `kernel` — the SubstrateKernel trait + ScalarKernel and the
//!     PortableKernel dispatch entry point
//!   - `kernel_simd` — portable SIMD fast paths (nightly feature-gated)
//!   - `kernel_avx512` — AVX-512 VPOPCNTQ Hamming-NN backend (x86_64
//!     only; DARK path — not selected by `for_current_platform()`
//!     pending MatrixSprint perf proof; see P11-VAL-015)
//!   - `bit_field`, `hamming_nn`, `sha256`, `hkdf`, `float_vec_ops` —
//!     hot-path primitives relocated here from substrate-lib (2026-05-29)
//!
//! Hardware-specific kernels for NEON / BNNS / Metal live in
//! substrate-lib's Swift port (PortableKernel-*.swift); the Rust port
//! relies on portable SIMD plus the scalar fallback for the live path.
//! The AVX-512 backend (`kernel_avx512`) is built for x86_64 but held
//! dark until MatrixSprint validates it on real AVX-512 hardware.

#![allow(dead_code)]
#![allow(clippy::needless_return)]
#![allow(clippy::too_many_arguments)]
#![cfg_attr(feature = "simd-nightly", feature(portable_simd))]

pub mod kernel;
#[cfg(feature = "simd-nightly")]
pub mod kernel_simd;
// AVX-512 VPOPCNTQ Hamming-NN backend — x86_64 only, DARK path.
// Built and wired into the dispatch table but NOT selected by
// `PortableKernel::for_current_platform()`. Gate-enable pending
// MatrixSprint perf proof on real AVX-512 VPOPCNTDQ hardware.
// See P11-VAL-015 and `kernel_avx512.rs` module-level doc comment.
#[cfg(target_arch = "x86_64")]
pub mod kernel_avx512;

// Relocated 2026-05-29 (four-package split addendum): the hot-path
// bit/hash primitives moved here from substrate-lib.
pub mod bit_field;
pub mod hamming_nn;
pub mod sha256;
// RFC 5869 HKDF-SHA256, built over sha256::hash. Added PAR-4-GL1 for the
// grant scope-key derivation conformance gate (Swift↔Rust byte-identical).
pub mod hkdf;
// Scalar float-vector ops (L2 norm, L2 normalise, dot, cosine).
// Swift mirror: FloatVecOps.swift. These are the canonical IEEE-754
// scalar implementations — higher crates call these, never reimplements inline.
pub mod float_vec_ops;

pub use kernel::*;

pub const VERSION: &str = "1.0.0-skeleton";
