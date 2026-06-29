// fingerprint256.rs
//
// 256-bit epistemic fingerprint per
// docs/specs/GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_2026-05-16.md
// § 3.1.
//
// The fingerprint is the substrate's universal coordinate system
// for STRUCTURAL similarity, distinct from the lattice anchor
// (which is the universal coordinate system for TOPIC similarity).
// Hamming distance over fingerprints is the cognition tier's
// primary structural-similarity primitive.
//
// Four 64-bit blocks, each a SimHash over a different aspect of
// the row:
//
//   block0 (bits 0..64)    Bitmap-LSH      § 3.2
//   block1 (bits 64..128)  Lattice-LSH     § 3.3
//   block2 (bits 128..192) Lineage+Temp    § 3.4
//   block3 (bits 192..256) Channel+Source  § 3.5
//
// Hamming distance over the full fingerprint is the sum of
// per-block Hamming distances. Per-block distance answers a more
// targeted similarity question (e.g. "same topic neighborhood"
// independent of temporal block).
//
// I-17 (cross-noun fingerprint compatibility): every noun type
// produces fingerprints in this same four-block structure under
// the same per-block hyperplane families. Missing fields fill
// with a deterministic null sub-hash so Hamming distance remains
// well-defined across pairs of noun types.

use std::convert::TryInto;

/// 256-bit row fingerprint, four 64-bit blocks.
///
/// `block0` carries Bitmap-LSH, `block1` Lattice-LSH, `block2`
/// Lineage+Temporal, `block3` Channel+Source. See cookbook § 3
/// for block-by-block construction rules.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Fingerprint256 {
    pub block0: u64,
    pub block1: u64,
    pub block2: u64,
    pub block3: u64,
}

impl Fingerprint256 {
    /// The all-zeros fingerprint. Used as the OR-reduce identity
    /// and as the null fingerprint for absent blocks.
    pub const ZERO: Fingerprint256 = Fingerprint256 {
        block0: 0,
        block1: 0,
        block2: 0,
        block3: 0,
    };

    pub const fn new(block0: u64, block1: u64, block2: u64, block3: u64) -> Self {
        Self { block0, block1, block2, block3 }
    }

    /// Bit-indexed access. `index` in 0..256. Bit 0 is the
    /// least-significant bit of `block0`.
    #[inline]
    pub fn bit(&self, index: usize) -> bool {
        assert!(index < 256, "fingerprint bit index out of range");
        let block = match index / 64 {
            0 => self.block0,
            1 => self.block1,
            2 => self.block2,
            _ => self.block3,
        };
        (block >> (index % 64)) & 1 == 1
    }

    /// Returns the `u64` for block `index` in 0..4.
    #[inline]
    pub fn block(&self, index: usize) -> u64 {
        match index {
            0 => self.block0,
            1 => self.block1,
            2 => self.block2,
            3 => self.block3,
            _ => panic!("fingerprint block index out of range"),
        }
    }

    /// Constructs a `Fingerprint256` from a 256-element bit slice.
    /// Bit `n` of input lands at index `n` of the fingerprint.
    pub fn from_bits(bits: &[bool]) -> Self {
        assert_eq!(bits.len(), 256, "fingerprint requires exactly 256 bits");
        let mut b = [0u64; 4];
        for (i, &bit) in bits.iter().enumerate() {
            if bit {
                b[i / 64] |= 1u64 << (i % 64);
            }
        }
        Self::new(b[0], b[1], b[2], b[3])
    }

    /// 32-byte little-endian wire encoding. Block 0 first, byte
    /// order within each block is little-endian.
    pub fn wire_bytes(&self) -> [u8; 32] {
        let mut out = [0u8; 32];
        for (i, &word) in [self.block0, self.block1, self.block2, self.block3]
            .iter()
            .enumerate()
        {
            out[i * 8..(i + 1) * 8].copy_from_slice(&word.to_le_bytes());
        }
        out
    }

    /// Inverse of `wire_bytes`. Returns error on incorrect length.
    pub fn from_wire_bytes(bytes: &[u8]) -> Result<Self, Fingerprint256Error> {
        if bytes.len() != 32 {
            return Err(Fingerprint256Error::InvalidWireLength(bytes.len()));
        }
        let word = |offset: usize| -> u64 {
            u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
        };
        Ok(Self::new(word(0), word(8), word(16), word(24)))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fingerprint256Error {
    InvalidWireLength(usize),
}

impl std::fmt::Display for Fingerprint256Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidWireLength(n) => {
                write!(f, "fingerprint wire length must be 32, got {n}")
            }
        }
    }
}

impl std::error::Error for Fingerprint256Error {}

// ─────────────────────────────────────────────────────────────────
// Phase 1 combinator layer
//
// Per DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6 Phase 1
// (Clojure convergent A; APL convergent A; Cursor convergent D; ML
// convergent D). The four-block unroll that appears in 7+ files is
// one expression in APL. These combinators express it once and let
// the higher-level reductions (Phase 2) collapse to one-liners.
//
// All operations are pure on the four `u64` blocks. No kernel
// dispatch; backends can override Phase-2-rewritten consumers if
// they need hardware acceleration.
//
// Conformance impact: zero. Output bit-identical to existing
// per-call unrolls.
// ─────────────────────────────────────────────────────────────────

impl Fingerprint256 {
    /// Apply a binary block operation pairwise across two
    /// fingerprints. The operator is invoked on each of the four
    /// `(self.blockN, other.blockN)` pairs.
    ///
    /// Used by Phase 2 to express intersect, difference, and the
    /// XOR step of Hamming distance as one-liners.
    #[inline]
    pub fn zip4<F: Fn(u64, u64) -> u64>(&self, other: &Self, op: F) -> Self {
        Self::new(
            op(self.block0, other.block0),
            op(self.block1, other.block1),
            op(self.block2, other.block2),
            op(self.block3, other.block3),
        )
    }

    /// Reduce a sequence of fingerprints with a binary block
    /// operator. The starting accumulator is `Fingerprint256::ZERO`,
    /// which is the identity for `|` and `^`. For operators whose
    /// identity is not zero (e.g. `&`), the caller is responsible
    /// for non-empty inputs.
    ///
    /// Replaces `or_reduce_256` in Phase 2.
    #[inline]
    pub fn reduce4<I, F>(iter: I, op: F) -> Self
    where
        I: IntoIterator<Item = Self>,
        F: Fn(u64, u64) -> u64,
    {
        iter.into_iter()
            .fold(Self::ZERO, |acc, x| acc.zip4(&x, &op))
    }

    /// Apply a unary block operation to each of the four blocks.
    #[inline]
    pub fn map4<F: Fn(u64) -> u64>(&self, op: F) -> Self {
        Self::new(
            op(self.block0),
            op(self.block1),
            op(self.block2),
            op(self.block3),
        )
    }

    /// Population count over all 256 bits.
    ///
    /// Replaces the inlined `count_ones` sum in `hamming` (after
    /// Phase 2's `a.zip4(b, |x, y| x ^ y).popcount()` rewrite).
    #[inline]
    pub fn popcount(&self) -> u32 {
        self.block0.count_ones()
            + self.block1.count_ones()
            + self.block2.count_ones()
            + self.block3.count_ones()
    }
}

// Batch siblings
//
// The grain ML inference and Cursor retrieval needs (decision doc
// Cursor convergent D + ML convergent D). Vectorize across rows
// rather than across blocks.

/// Pairwise `zip4` across two equal-length slices of fingerprints.
/// Returns `Vec::new()` when the slices differ in length
/// (caller-defensive; in debug builds this asserts).
#[inline]
pub fn zip4_batch<F: Fn(u64, u64) -> u64>(
    a: &[Fingerprint256],
    b: &[Fingerprint256],
    op: F,
) -> Vec<Fingerprint256> {
    debug_assert_eq!(
        a.len(),
        b.len(),
        "zip4_batch requires equal-length inputs"
    );
    if a.len() != b.len() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(a.len());
    for i in 0..a.len() {
        out.push(a[i].zip4(&b[i], &op));
    }
    out
}

/// `map4` across a slice of fingerprints.
#[inline]
pub fn map4_batch<F: Fn(u64) -> u64>(
    xs: &[Fingerprint256],
    op: F,
) -> Vec<Fingerprint256> {
    let mut out = Vec::with_capacity(xs.len());
    for x in xs {
        out.push(x.map4(&op));
    }
    out
}

// Test vectors (cookbook conformance § 18.2)
//
// Illustrative; the Swift conformance suite carries the canonical
// Tier-2 test vectors (Fingerprint256.swift test block).

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_wire_bytes_all_zero() {
        let wire = Fingerprint256::ZERO.wire_bytes();
        assert_eq!(wire, [0u8; 32]);
    }

    #[test]
    fn bit_zero_in_block_zero() {
        let fp = Fingerprint256::new(1, 0, 0, 0);
        assert!(fp.bit(0));
        assert!(!fp.bit(1));
    }

    #[test]
    fn bit_zero_in_block_one() {
        let fp = Fingerprint256::new(0, 1, 0, 0);
        assert!(fp.bit(64));
        assert!(!fp.bit(63));
    }

    #[test]
    fn round_trip_wire_bytes() {
        let fp = Fingerprint256::new(0xDEAD_BEEF, 0xCAFE_F00D, 0x1234, 0x5678);
        let wire = fp.wire_bytes();
        let back = Fingerprint256::from_wire_bytes(&wire).unwrap();
        assert_eq!(fp, back);
    }

    // ──────────────────────────────────────────────────────────
    // Phase 1 combinator tests
    // (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.1)
    // ──────────────────────────────────────────────────────────

    fn sample_a() -> Fingerprint256 {
        Fingerprint256::new(0xFF00, 0x0F00, 0x00FF, 0xF0F0)
    }

    fn sample_b() -> Fingerprint256 {
        Fingerprint256::new(0x0FF0, 0xFF00, 0x0FF0, 0x0F0F)
    }

    #[test]
    fn zip4_or_is_blockwise_or() {
        let a = sample_a();
        let b = sample_b();
        let r = a.zip4(&b, |x, y| x | y);
        assert_eq!(r.block0, a.block0 | b.block0);
        assert_eq!(r.block1, a.block1 | b.block1);
        assert_eq!(r.block2, a.block2 | b.block2);
        assert_eq!(r.block3, a.block3 | b.block3);
    }

    #[test]
    fn zip4_xor_is_blockwise_xor() {
        let a = sample_a();
        let b = sample_b();
        let r = a.zip4(&b, |x, y| x ^ y);
        assert_eq!(r.block0, a.block0 ^ b.block0);
        assert_eq!(r.block1, a.block1 ^ b.block1);
        assert_eq!(r.block2, a.block2 ^ b.block2);
        assert_eq!(r.block3, a.block3 ^ b.block3);
    }

    #[test]
    fn zip4_and_is_blockwise_and() {
        let a = sample_a();
        let b = sample_b();
        let r = a.zip4(&b, |x, y| x & y);
        assert_eq!(r.block0, a.block0 & b.block0);
        assert_eq!(r.block1, a.block1 & b.block1);
        assert_eq!(r.block2, a.block2 & b.block2);
        assert_eq!(r.block3, a.block3 & b.block3);
    }

    #[test]
    fn reduce4_or_empty_is_zero() {
        let r = Fingerprint256::reduce4(std::iter::empty(), |x, y| x | y);
        assert_eq!(r, Fingerprint256::ZERO);
    }

    #[test]
    fn reduce4_or_multiple_is_blockwise_or() {
        let a = sample_a();
        let b = sample_b();
        let c = Fingerprint256::new(1, 2, 4, 8);
        let r = Fingerprint256::reduce4(vec![a, b, c], |x, y| x | y);
        assert_eq!(r.block0, a.block0 | b.block0 | c.block0);
        assert_eq!(r.block1, a.block1 | b.block1 | c.block1);
        assert_eq!(r.block2, a.block2 | b.block2 | c.block2);
        assert_eq!(r.block3, a.block3 | b.block3 | c.block3);
    }

    #[test]
    fn map4_complement_inverts_all_blocks() {
        let a = sample_a();
        let r = a.map4(|x| !x);
        assert_eq!(r.block0, !a.block0);
        assert_eq!(r.block1, !a.block1);
        assert_eq!(r.block2, !a.block2);
        assert_eq!(r.block3, !a.block3);
    }

    #[test]
    fn popcount_zero_is_zero() {
        assert_eq!(Fingerprint256::ZERO.popcount(), 0);
    }

    #[test]
    fn popcount_all_ones_is_256() {
        let all_ones = Fingerprint256::new(u64::MAX, u64::MAX, u64::MAX, u64::MAX);
        assert_eq!(all_ones.popcount(), 256);
    }

    #[test]
    fn popcount_sums_across_blocks() {
        let a = sample_a();
        let expected = a.block0.count_ones()
            + a.block1.count_ones()
            + a.block2.count_ones()
            + a.block3.count_ones();
        assert_eq!(a.popcount(), expected);
    }

    #[test]
    fn hamming_via_zip4_popcount() {
        let a = sample_a();
        let b = sample_b();
        let via_combinators = a.zip4(&b, |x, y| x ^ y).popcount();
        let direct = (a.block0 ^ b.block0).count_ones()
            + (a.block1 ^ b.block1).count_ones()
            + (a.block2 ^ b.block2).count_ones()
            + (a.block3 ^ b.block3).count_ones();
        assert_eq!(via_combinators, direct);
    }

    #[test]
    fn zip4_batch_pairwise() {
        let a = sample_a();
        let b = sample_b();
        let out = zip4_batch(&[a, b], &[b, a], |x, y| x | y);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], a.zip4(&b, |x, y| x | y));
        assert_eq!(out[1], b.zip4(&a, |x, y| x | y));
    }

    #[test]
    fn map4_batch_per_element() {
        let a = sample_a();
        let b = sample_b();
        let out = map4_batch(&[a, b], |x| !x);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0], a.map4(|x| !x));
        assert_eq!(out[1], b.map4(|x| !x));
    }
}
