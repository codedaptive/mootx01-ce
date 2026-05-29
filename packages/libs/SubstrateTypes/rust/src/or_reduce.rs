// or_reduce.rs
//
// OR-reduction over Fingerprint256 collections per cookbook § 8.5.
//
// OR-reduction is the substrate's universal aggregation primitive.
// It is commutative, associative, and idempotent, which makes it
// ideal for:
//
//   1. Temporal compression (detail → hour → day, cookbook § 8.14)
//   2. Paired-estate shared-context aggregation (case study 1)
//   3. Tier contribution at federation boundaries (cookbook § 12.3)
//   4. Moment-summary fingerprints across noun types (§ 8.7)
//   5. Cross-replica conflict-free merge (CRDT semantics, § 5)
//
// The idempotence property is the privacy mechanism: an
// aggregation of many fingerprints loses attribution (you cannot
// tell which contributor set which bit) while preserving
// structural pattern (bits set in many contributors stay set).

use crate::fingerprint256::Fingerprint256;

/// OR-reduction over a fingerprint iterator. Returns
/// `Fingerprint256::ZERO` for empty input (the identity).
///
/// Phase 2 (decision 2026-05-28 §6.2): delegates to the
/// `Fingerprint256::reduce4` combinator. Bit-identical to the
/// inline four-block fold it replaces.
#[inline]
pub fn reduce<I>(fingerprints: I) -> Fingerprint256
where
    I: IntoIterator<Item = Fingerprint256>,
{
    Fingerprint256::reduce4(fingerprints, |x, y| x | y)
}

// Phase 2 deletion: `or_reduce::merge`. Streaming callers now do
// `accumulator = accumulator.zip4(incoming, |x, y| x | y)`. No
// call sites in the repository depended on the in-place form.

/// OR-reduction restricted to specific blocks (bitmask from
/// `hamming::*BLOCK*` constants). Blocks NOT in `blocks_mask`
/// carry over from `defaults` (typically `Fingerprint256::ZERO`).
pub fn reduce_blocks<I>(
    fingerprints: I,
    blocks_mask: u8,
    defaults: Fingerprint256,
) -> Fingerprint256
where
    I: IntoIterator<Item = Fingerprint256>,
{
    use crate::hamming::{BLOCK_0, BLOCK_1, BLOCK_2, BLOCK_3};

    let full = reduce(fingerprints);
    Fingerprint256::new(
        if blocks_mask & BLOCK_0 != 0 { full.block0 } else { defaults.block0 },
        if blocks_mask & BLOCK_1 != 0 { full.block1 } else { defaults.block1 },
        if blocks_mask & BLOCK_2 != 0 { full.block2 } else { defaults.block2 },
        if blocks_mask & BLOCK_3 != 0 { full.block3 } else { defaults.block3 },
    )
}

// Algebraic properties (informally verified by tests below)
//
// commutative:  OR(a, b) == OR(b, a)
// associative: OR(OR(a, b), c) == OR(a, OR(b, c))
// idempotent:  OR(a, a) == a
//
// These three together make OR-reduction the natural CRDT join
// operator for fingerprint G-Sets. Replicas can merge contribution
// sets in any order, with any duplicate ordering, and converge to
// the same aggregate.

// Use sites (cross-reference)
//
//   cookbook § 8.14   compress_to_hourly (12 detail buckets → 1 hour)
//   cookbook § 12.3   generate_contribution (N row fingerprints → 1 tier)
//   cookbook § 11.5   recall_current_posture (recent samples → posture)
//   cookbook § 11.15  recall_moment_summary (active rows → moment fp)
//   cookbook § 5.4    sync convergence (commutative join over G-Sets)

#[cfg(test)]
mod tests {
    use super::*;

    fn fp(a: u64, b: u64, c: u64, d: u64) -> Fingerprint256 {
        Fingerprint256::new(a, b, c, d)
    }

    #[test]
    fn empty_reduces_to_zero() {
        let empty: Vec<Fingerprint256> = vec![];
        assert_eq!(reduce(empty), Fingerprint256::ZERO);
    }

    #[test]
    fn commutative() {
        let a = fp(0x1, 0x2, 0x4, 0x8);
        let b = fp(0x10, 0x20, 0x40, 0x80);
        let ab = reduce(vec![a, b]);
        let ba = reduce(vec![b, a]);
        assert_eq!(ab, ba);
    }

    #[test]
    fn associative() {
        let a = fp(0x1, 0x2, 0x4, 0x8);
        let b = fp(0x10, 0x20, 0x40, 0x80);
        let c = fp(0x100, 0x200, 0x400, 0x800);
        let lhs = reduce(vec![reduce(vec![a, b]), c]);
        let rhs = reduce(vec![a, reduce(vec![b, c])]);
        assert_eq!(lhs, rhs);
    }

    #[test]
    fn idempotent() {
        let a = fp(0xDEAD, 0xBEEF, 0xCAFE, 0xBABE);
        let aa = reduce(vec![a, a]);
        assert_eq!(a, aa);
    }
}
