//! substrate-kernel — Layer 2 of the three-package SubstrateLib split
//! per DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.
//!
//! Hardware-dispatched fast paths. The scalar reference (in
//! substrate-lib) is the oracle; this crate's kernels must be
//! bit-identical to it on every input (conformance-gated).
//!
//! Currently hosts:
//!   - `kernel` — the SubstrateKernel trait + ScalarKernel, BlasKernel,
//!     and the dispatch entry point
//!   - `kernel_simd` — portable SIMD fast paths
//!
//! Hardware-specific kernels for NEON / BNNS / Metal live in
//! substrate-lib's Swift port (PortableKernel-*.swift); the Rust port
//! relies on portable SIMD plus the scalar fallback.

#![allow(dead_code)]
#![allow(clippy::needless_return)]
#![allow(clippy::too_many_arguments)]
#![cfg_attr(feature = "simd-nightly", feature(portable_simd))]

pub mod kernel;
#[cfg(feature = "simd-nightly")]
pub mod kernel_simd;

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
