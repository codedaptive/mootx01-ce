//! LocusKit-specific marshaling adapters between i64 bitmap-coded
//! values and the substrate's canonical Fingerprint256 width.
//!
//! Rust parity of `Fingerprint256Adapters.swift` in the Swift port.
//!
//! Routing convention. The substrate's math primitives live in
//! `substrate_lib` at Fingerprint256 width (cookbook §1.2 P1-P12;
//! SUBSTRATE_MATHEMATICS §4). LocusKit stores per-row bitmaps as
//! i64 columns (adjective, operational, provenance). To route a
//! per-column bit operation through a substrate_lib primitive —
//! XOR via `bitwise::difference`, OR via `or_reduce::reduce`, AND
//! via `bitwise::intersect`, popcount via `kernel` — the column
//! packs into block 0 of a Fingerprint256 with blocks 1–3 reserved
//! zero.
//!
//! These adapters are NOT math primitives. They are type
//! conversions for the column-as-block-0 packing convention. The
//! math is owned by `substrate_lib`; this module owns only the
//! carrier shape. No proof, no platform optimization, and no
//! conformance gate apply to a pack-and-unpack.
//!
//! Semantic note on block 0. Cookbook §3.2 assigns block 0 the
//! Bitmap-LSH SimHash output (a 64-bit signed projection over the
//! 192-bit row bitmap). When LocusKit packs a single i64 column
//! into block 0 for the purpose of routing a per-column bit op,
//! block 0 is being used as a generic 64-bit lane within the
//! carrier — NOT as a SimHash output. The math is correct (OR,
//! XOR, AND, popcount on 256 bits are well-defined for any
//! partition into blocks); only the SimHash-semantic
//! interpretation is contextual. Callers must not mix this
//! packing with code that reads block 0 as a Bitmap-LSH SimHash
//! output.

// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_types::fingerprint256::Fingerprint256;

/// Pack a single i64 bitmap column into block 0 of a
/// `Fingerprint256` with blocks 1–3 zero. The packing is a
/// type-shape convention for routing per-column bit math through
/// substrate_lib primitives at canonical width.
///
/// Bit-equivalent to Swift's `Fingerprint256(int64Column:)`.
#[inline]
pub fn fingerprint_from_column(value: i64) -> Fingerprint256 {
    Fingerprint256::new(value as u64, 0, 0, 0)
}

/// Unpack block 0 of a `Fingerprint256` back to an i64 bitmap
/// column. Inverse of [`fingerprint_from_column`]. Blocks 1–3
/// are ignored.
///
/// Bit-equivalent to Swift's `Fingerprint256.int64Column`.
#[inline]
pub fn column_from_fingerprint(fp: &Fingerprint256) -> i64 {
    fp.block0 as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_preserves_value() {
        for v in [0_i64, 1, -1, i64::MAX, i64::MIN, 0x1234_5678_9abc_def0_i64] {
            assert_eq!(column_from_fingerprint(&fingerprint_from_column(v)), v);
        }
    }

    #[test]
    fn fingerprint_blocks_1_to_3_are_zero() {
        let fp = fingerprint_from_column(0x1234_i64);
        assert_eq!(fp.block1, 0);
        assert_eq!(fp.block2, 0);
        assert_eq!(fp.block3, 0);
    }
}
