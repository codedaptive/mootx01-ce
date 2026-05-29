// hamming.rs
//
// Hamming distance over Fingerprint256 per cookbook § 8.2.
//
// Hamming distance is the substrate's primary structural-
// similarity primitive. For two 256-bit fingerprints A and B,
// the distance is the number of bit positions where they differ.
// Implemented as XOR followed by popcount, summed across blocks.
//
// Per-block Hamming answers a more targeted question: limiting
// the distance to specific blocks (the `blocks` parameter) gives
// distance over just the bitmap aspect, just the lattice aspect,
// or any subset. This is what `recall_partial_match` (cookbook
// § 11.10) exploits.

use crate::fingerprint256::Fingerprint256;

/// Block-selection mask. Bit `n` set ⇒ include block `n` in the
/// distance computation. ALL_BLOCKS includes all four.
pub const BLOCK_0: u8 = 0b0001;
pub const BLOCK_1: u8 = 0b0010;
pub const BLOCK_2: u8 = 0b0100;
pub const BLOCK_3: u8 = 0b1000;
pub const ALL_BLOCKS: u8 = 0b1111;

/// Hamming distance between two 256-bit fingerprints. Default
/// uses all four blocks (full 256-bit distance). Restrict via the
/// `blocks` bitmask for per-aspect distance.
///
/// Returns an integer in [0, 64 * popcount(blocks)]. For the full
/// fingerprint that's [0, 256].
///
/// Phase 2 (decision 2026-05-28 §6.2): the full-blocks fast path
/// delegates to `a.zip4(b, ^).popcount()`. The per-block branch
/// is retained until the API hygiene phase replaces the bitmask
/// with a typed `BlockMask`.
#[inline]
pub fn distance(a: &Fingerprint256, b: &Fingerprint256, blocks: u8) -> u32 {
    // Full-blocks fast path — the common case.
    if blocks == ALL_BLOCKS {
        return a.zip4(b, |x, y| x ^ y).popcount();
    }
    let mut d: u32 = 0;
    if blocks & BLOCK_0 != 0 { d += (a.block0 ^ b.block0).count_ones(); }
    if blocks & BLOCK_1 != 0 { d += (a.block1 ^ b.block1).count_ones(); }
    if blocks & BLOCK_2 != 0 { d += (a.block2 ^ b.block2).count_ones(); }
    if blocks & BLOCK_3 != 0 { d += (a.block3 ^ b.block3).count_ones(); }
    d
}

/// Hamming similarity in [0.0, 1.0]. 1.0 = identical, 0.0 =
/// maximally distant. Defined as 1 - (distance / max).
pub fn similarity(a: &Fingerprint256, b: &Fingerprint256, blocks: u8) -> f64 {
    let max = 64 * (blocks.count_ones() as u32);
    if max == 0 { return 1.0; }
    1.0 - (distance(a, b, blocks) as f64) / (max as f64)
}

// Performance notes
//
// On modern x86_64 with AVX-512 + VPOPCNTQ, the natural
// implementation is four XORs + four popcounts per pair: ~5ns
// per pair. For top-K search over 1M rows the bottleneck is
// memory bandwidth (read 1M × 32 bytes = 32 MB); well within
// the cookbook § 17 budget at ~500 µs total.
//
// The NeuronKit Rust port wraps this in a kernel-layer trait
// (cookbook § 4.4) that selects AVX-512, AVX2, NEON, or scalar
// based on CPU detection. The scalar reference here is the
// authoritative source: every backend MUST produce the same
// integer output for every input pair.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_to_zero_is_zero() {
        let a = Fingerprint256::ZERO;
        let b = Fingerprint256::ZERO;
        assert_eq!(distance(&a, &b, ALL_BLOCKS), 0);
    }

    #[test]
    fn one_bit_difference() {
        let a = Fingerprint256::ZERO;
        let b = Fingerprint256::new(1, 0, 0, 0);
        assert_eq!(distance(&a, &b, ALL_BLOCKS), 1);
    }

    #[test]
    fn maximally_distant() {
        let a = Fingerprint256::ZERO;
        let b = Fingerprint256::new(u64::MAX, u64::MAX, u64::MAX, u64::MAX);
        assert_eq!(distance(&a, &b, ALL_BLOCKS), 256);
    }

    #[test]
    fn block_restricted_distance() {
        let a = Fingerprint256::ZERO;
        let b = Fingerprint256::new(u64::MAX, 0, 0, 0);
        assert_eq!(distance(&a, &b, BLOCK_0), 64);
        assert_eq!(distance(&a, &b, BLOCK_1), 0);
        assert_eq!(distance(&a, &b, BLOCK_0 | BLOCK_1), 64);
    }

    #[test]
    fn self_similarity_is_one() {
        let fp = Fingerprint256::new(0xCAFE, 0xBABE, 0xDEAD, 0xBEEF);
        assert_eq!(similarity(&fp, &fp, ALL_BLOCKS), 1.0);
    }
}
