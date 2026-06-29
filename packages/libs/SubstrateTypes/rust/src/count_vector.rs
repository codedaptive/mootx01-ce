// count_vector.rs
//
// Count-vector over the 256-bit fingerprint space, the stored object
// for the bundle algebra. Mirror of
// Sources/SubstrateTypes/CountVector256.swift; see
// DECISION_BUNDLE_ALGEBRA_AND_ERASURE_2026-05-20.md and the scope in
// docs/analysis/bundle_algebra/SCOPE_MAJORITY_VOTE_TREE_FOLD_2026-05-20.md.
//
// For a set of member fingerprints, the count-vector holds, for each
// of the 256 bit positions, how many members have that bit set
// (counts[j] = c_j) together with the member count n. The normalized
// profile p_j = c_j / n is the probability a random member lights bit
// j, equivalently bit j's Bernoulli parameter.
//
// The count-vector composes losslessly up a node tree: counts add and
// n adds, and a parent's count-vector equals the direct accumulation
// of every leaf under it, exactly, regardless of fold order. Majority-
// vote does not compose, so the stored object is the count-vector and
// the majority-vote engram is a read-time threshold of 2*c_j > n. The
// existing OR-reduce is the degenerate case of this fold, saturating
// each count at one.

use crate::fingerprint256::Fingerprint256;
use std::ops::Add;

/// Count-vector `(c, n)` over the 256-bit fingerprint space.
///
/// `counts[j]` is the number of accumulated members whose bit j is
/// set; `n` is the member count. The all-zero value is the fold
/// identity. Counts are `u32`; `accumulate` and `merge` use
/// `wrapping_add`, so a count wraps rather than panics on overflow.
/// In practice 4.3 billion members per vector exceeds any realistic
/// node subtree size, so wrap is not expected.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CountVector256 {
    // Serde's built-in [T; N] impls only cover N ≤ 32. Use
    // serde_big_array::BigArray for the 256-wide field to match
    // Swift Codable's `counts: [UInt32]` (which encodes as a
    // JSON array of 256 numbers). The wire format is identical;
    // serde-big-array only fills in the missing trait impl.
    #[cfg_attr(feature = "serde-support", serde(with = "serde_big_array::BigArray"))]
    counts: [u32; 256],
    n: u32,
}

impl CountVector256 {
    /// The empty count-vector: all counts zero, n zero. Identity of
    /// the fold and merge.
    pub fn zero() -> Self {
        CountVector256 { counts: [0u32; 256], n: 0 }
    }

    /// Construct from explicit counts and member count. Used for
    /// decoding a stored vector and for tests; normal construction is
    /// by `accumulate` or `merge`.
    pub fn from_parts(counts: [u32; 256], n: u32) -> Self {
        CountVector256 { counts, n }
    }

    /// Per-bit set counts, exactly 256 entries.
    pub fn counts(&self) -> &[u32; 256] {
        &self.counts
    }

    /// Member count.
    pub fn n(&self) -> u32 {
        self.n
    }

    /// Fold one fingerprint in: raise each set bit's count by one and
    /// raise n by one. The leaf step of the fold.
    pub fn accumulate(&mut self, fingerprint: &Fingerprint256) {
        for block_index in 0..4 {
            let mut word = fingerprint.block(block_index);
            let base = block_index * 64;
            while word != 0 {
                let bit = word.trailing_zeros() as usize;
                self.counts[base + bit] = self.counts[base + bit].wrapping_add(1);
                word &= word - 1; // clear lowest set bit
            }
        }
        self.n = self.n.wrapping_add(1);
    }

    /// Merge another count-vector in: add counts elementwise, add n.
    /// Commutative and associative, so a node's children fold in any
    /// order to the same result, equal to direct accumulation of every
    /// leaf under the node.
    pub fn merge(&mut self, other: &CountVector256) {
        for j in 0..256 {
            self.counts[j] = self.counts[j].wrapping_add(other.counts[j]);
        }
        self.n = self.n.wrapping_add(other.n);
    }

    /// The majority-vote engram. Bit j is set if and only if a strict
    /// majority of members have it set, `2 * c_j > n`. The strict
    /// inequality matches the proof's indicator `1[c_j/n > 0.5]`: an
    /// exact tie at half does not set the bit. This tie convention is
    /// part of the contract and is identical across every backend and
    /// across the Swift and Rust ports. An empty vector yields the
    /// zero fingerprint.
    pub fn majority_vote(&self) -> Fingerprint256 {
        let threshold = self.n as u64;
        let mut blocks = [0u64; 4];
        for j in 0..256 {
            if (self.counts[j] as u64) * 2 > threshold {
                blocks[j / 64] |= 1u64 << (j % 64);
            }
        }
        Fingerprint256::new(blocks[0], blocks[1], blocks[2], blocks[3])
    }

    /// The normalized profile p_j = c_j / n, 256 values in [0, 1]. An
    /// empty vector yields all zeros. Not stored; recomputed when the
    /// Bernoulli or KL-drift views need it.
    pub fn profile(&self) -> Vec<f32> {
        if self.n == 0 {
            return vec![0.0f32; 256];
        }
        let denom = self.n as f32;
        self.counts.iter().map(|&c| c as f32 / denom).collect()
    }

    /// Accumulate a slice of fingerprints into one count-vector. The
    /// reference fold the kernel layer's `count_fold_256` dispatches
    /// to; performance backends may compute the same result with a
    /// vectorized vertical counter, gated against this reference.
    pub fn fold(fingerprints: &[Fingerprint256]) -> CountVector256 {
        let mut cv = CountVector256::zero();
        for fp in fingerprints {
            cv.accumulate(fp);
        }
        cv
    }
}

impl Add for CountVector256 {
    type Output = CountVector256;
    /// `a + b` is the elementwise count sum with n summed.
    fn add(self, rhs: CountVector256) -> CountVector256 {
        let mut result = self;
        result.merge(&rhs);
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fingerprints(seed: u64, count: usize) -> Vec<Fingerprint256> {
        let mut state = seed.wrapping_add(0x9E3779B97F4A7C15);
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        (0..count)
            .map(|_| Fingerprint256::new(next(), next(), next(), next()))
            .collect()
    }

    fn with_bits(bits: &[usize]) -> Fingerprint256 {
        let mut blocks = [0u64; 4];
        for &b in bits {
            blocks[b / 64] |= 1u64 << (b % 64);
        }
        Fingerprint256::new(blocks[0], blocks[1], blocks[2], blocks[3])
    }

    #[test]
    fn accumulate_counts_set_bits() {
        let mut cv = CountVector256::zero();
        cv.accumulate(&with_bits(&[0, 64, 255]));
        assert_eq!(cv.n(), 1);
        assert_eq!(cv.counts()[0], 1);
        assert_eq!(cv.counts()[64], 1);
        assert_eq!(cv.counts()[255], 1);
        assert_eq!(cv.counts()[1], 0);
        assert_eq!(cv.counts().iter().sum::<u32>(), 3);
    }

    #[test]
    fn empty_vector_is_identity() {
        let empty = CountVector256::zero();
        assert_eq!(empty.n(), 0);
        assert_eq!(empty.majority_vote(), Fingerprint256::ZERO);
        assert_eq!(empty.profile(), vec![0.0f32; 256]);
    }

    #[test]
    fn tree_fold_equals_direct_accumulation() {
        let all = fingerprints(42, 300);
        let direct = CountVector256::fold(&all);
        let g1 = CountVector256::fold(&all[0..137]);
        let g2 = CountVector256::fold(&all[137..255]);
        let g3 = CountVector256::fold(&all[255..300]);
        let merged = g1 + g2 + g3;
        assert_eq!(merged, direct);
        assert_eq!(merged.n(), 300);
    }

    #[test]
    fn merge_is_commutative_and_associative() {
        let a = CountVector256::fold(&fingerprints(1, 50));
        let b = CountVector256::fold(&fingerprints(2, 70));
        let c = CountVector256::fold(&fingerprints(3, 90));
        assert_eq!(a.clone() + b.clone(), b.clone() + a.clone());
        assert_eq!((a.clone() + b.clone()) + c.clone(), a.clone() + (b.clone() + c.clone()));
    }

    #[test]
    fn majority_vote_strict_threshold() {
        // bit 0: 3 of 4 (majority -> set); bit 1: 2 of 4 (tie -> clear);
        // bit 2: 1 of 4 (minority -> clear).
        let members = vec![
            with_bits(&[0, 1, 2]),
            with_bits(&[0, 1]),
            with_bits(&[0]),
            with_bits(&[]),
        ];
        let cv = CountVector256::fold(&members);
        assert_eq!(cv.n(), 4);
        assert_eq!(cv.counts()[0], 3);
        assert_eq!(cv.counts()[1], 2);
        assert_eq!(cv.counts()[2], 1);
        let mv = cv.majority_vote();
        assert!(mv.bit(0), "strict majority sets the bit");
        assert!(!mv.bit(1), "exact tie does not set the bit");
        assert!(!mv.bit(2), "minority does not set the bit");
    }

    #[test]
    fn profile_is_count_over_n() {
        let members = vec![
            with_bits(&[10]),
            with_bits(&[10]),
            with_bits(&[10]),
            with_bits(&[]),
            with_bits(&[]),
        ];
        let cv = CountVector256::fold(&members);
        let p = cv.profile();
        assert!((p[10] - 0.6).abs() < 1e-6);
        assert!((p[11] - 0.0).abs() < 1e-6);
    }
}
