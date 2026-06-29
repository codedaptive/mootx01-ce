// FloatSimHashPlanes.swift
//
// Materialized ±1 hyperplane set for the float-input SimHash projection — the
// float analog of `HyperplaneFamily` (which carries the bitmap SimHash's
// planes as data). 256 hyperplanes, each of length `dim`. The sign of plane
// `k` at coordinate `i` is +1 when bit `k*dim + i` of `signBits` is set, −1
// otherwise (row-major: hyperplane outer, coordinate inner — matching the
// SplitMix64 draw order `FloatSimHash.project` consumes).
//
// This type lives in SubstrateTypes (the lowest layer) so both consumers reach
// it without a layering inversion: `SubstrateKernel.floatSimHashProject`
// APPLIES it (pure signed-sum-and-sign, no RNG), and `SubstrateML.FloatSimHash`
// GENERATES it from a seed. Separating generation (SubstrateML, where the
// SplitMix64 RNG lives) from application (SubstrateKernel, the dispatch layer)
// mirrors how the bitmap `simhashCompute(subhashes:families:)` already takes
// its planes as data. See SUBSTRATEKERNEL_SPEC § 5.4.
//
// The planes are seed-immutable, so callers materialize them once per
// (seed, dim) and reuse them across every projection under that seed.
//
// Rust port: packages/libs/SubstrateTypes/rust/src/float_simhash_planes.rs

/// A materialized ±1 hyperplane set for `SubstrateKernel.floatSimHashProject`.
///
/// `signBits` packs `256 * dim` bits into `ceil(256 * dim / 64)` words,
/// row-major by `(hyperplane k, coordinate i)` with bit index `k * dim + i`:
/// a set bit means plane sign `+1`, a clear bit means `−1`.
///
/// Thread-safety: value type, fully `Sendable`.
public struct FloatSimHashPlanes: Sendable, Equatable {
    /// Dimensionality of each hyperplane (must equal the projected vector's
    /// length). There are always 256 hyperplanes (one per output bit).
    public let dim: Int

    /// Packed sign bits — `ceil(256 * dim / 64)` words. Bit `k * dim + i` set
    /// ⟹ plane `k` has sign `+1` at coordinate `i`; clear ⟹ `−1`.
    public let signBits: [UInt64]

    public init(dim: Int, signBits: [UInt64]) {
        self.dim = dim
        self.signBits = signBits
    }
}
