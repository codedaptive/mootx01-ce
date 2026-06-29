//! Materialized ±1 hyperplane set for the float-input SimHash projection — the
//! float analog of `HyperplaneFamily` (which carries the bitmap SimHash's
//! planes as data). 256 hyperplanes, each of length `dim`. The sign of plane
//! `k` at coordinate `i` is +1 when bit `k*dim + i` of `sign_bits` is set, −1
//! otherwise (row-major: hyperplane outer, coordinate inner — matching the
//! SplitMix64 draw order `FloatSimHash::project` consumes).
//!
//! Lives in SubstrateTypes (the lowest layer) so both consumers reach it
//! without a layering inversion: `SubstrateKernel::float_simhash_project`
//! APPLIES it (pure signed-sum-and-sign, no RNG), and `SubstrateML::FloatSimHash`
//! GENERATES it from a seed. Separating generation (SubstrateML, where the
//! SplitMix64 RNG lives) from application (SubstrateKernel, the dispatch layer)
//! mirrors how the bitmap `simhash_block(..., family)` already takes its planes
//! as data. See SUBSTRATEKERNEL_SPEC § 5.4.
//!
//! Swift port: packages/libs/SubstrateTypes/Sources/SubstrateTypes/FloatSimHashPlanes.swift

/// A materialized ±1 hyperplane set for `SubstrateKernel::float_simhash_project`.
///
/// `sign_bits` packs `256 * dim` bits into `ceil(256 * dim / 64)` words,
/// row-major by `(hyperplane k, coordinate i)` with bit index `k * dim + i`:
/// a set bit means plane sign `+1`, a clear bit means `−1`.
#[derive(Debug, Clone, PartialEq)]
pub struct FloatSimHashPlanes {
    /// Dimensionality of each hyperplane (must equal the projected vector's
    /// length). There are always 256 hyperplanes (one per output bit).
    pub dim: usize,
    /// Packed sign bits — `ceil(256 * dim / 64)` words. Bit `k * dim + i` set
    /// ⟹ plane `k` has sign `+1` at coordinate `i`; clear ⟹ `−1`.
    pub sign_bits: Vec<u64>,
}

impl FloatSimHashPlanes {
    pub fn new(dim: usize, sign_bits: Vec<u64>) -> Self {
        FloatSimHashPlanes { dim, sign_bits }
    }
}
