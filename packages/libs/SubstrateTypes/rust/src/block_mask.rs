// block_mask.rs
//
// Typed block-selection mask for Fingerprint256 Hamming distance.
// Mirrors Swift BlockMask (OptionSet) from Sources/SubstrateTypes/BlockMask.swift.
//
// The four blocks correspond to the cookbook §3 factorization:
//
//   block0 — Bitmap-LSH       (§3.2)
//   block1 — Lattice-LSH      (§3.3)
//   block2 — Lineage+Temporal (§3.4)
//   block3 — Channel+Source   (§3.5)
//
// The existing raw u8 constants in hamming.rs (BLOCK_0..BLOCK_3,
// ALL_BLOCKS) remain unchanged for callers that still use the
// bitmask API directly. BlockMask is the typed face of the same
// u8 bit-pattern: `BlockMask::ALL.bits()` is identical to the
// hamming::ALL_BLOCKS constant (0b1111).

/// Typed block-selection bitmask for Fingerprint256 Hamming
/// distance. Bit n set ⇒ include block n in the computation.
///
/// Transparent newtype over u8. Named constants mirror the Swift
/// OptionSet cases 1:1:
///   Swift `.block0`  → `BlockMask::BLOCK0` (raw 0b0001)
///   Swift `.block1`  → `BlockMask::BLOCK1` (raw 0b0010)
///   Swift `.block2`  → `BlockMask::BLOCK2` (raw 0b0100)
///   Swift `.block3`  → `BlockMask::BLOCK3` (raw 0b1000)
///   Swift `.all`     → `BlockMask::ALL`    (raw 0b1111)
///   Swift `.none`    → `BlockMask::NONE`   (raw 0b0000)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[repr(transparent)]
pub struct BlockMask(pub u8);

impl BlockMask {
    pub const BLOCK0: BlockMask = BlockMask(0b0001);
    pub const BLOCK1: BlockMask = BlockMask(0b0010);
    pub const BLOCK2: BlockMask = BlockMask(0b0100);
    pub const BLOCK3: BlockMask = BlockMask(0b1000);

    /// All four blocks selected — the common case.
    pub const ALL: BlockMask = BlockMask(0b1111);

    /// No blocks selected — distance over this returns 0.
    pub const NONE: BlockMask = BlockMask(0b0000);

    /// Return the underlying u8 bit-pattern for direct use with
    /// `hamming::distance` / `hamming::similarity`.
    #[inline]
    pub fn bits(self) -> u8 {
        self.0
    }

    /// Number of blocks selected (0..=4). Mirrors Swift
    /// `BlockMask.blockCount` (`rawValue.nonzeroBitCount`).
    #[inline]
    pub fn block_count(self) -> u32 {
        self.0.count_ones()
    }

    /// True when the mask selects every block in `other` (superset
    /// or equal). Mirrors Swift OptionSet `contains`.
    #[inline]
    pub fn contains(self, other: BlockMask) -> bool {
        (self.0 & other.0) == other.0
    }

    /// Union: select blocks from both masks. Mirrors Swift `union`.
    #[inline]
    pub fn union(self, other: BlockMask) -> BlockMask {
        BlockMask(self.0 | other.0)
    }

    /// Intersection: keep only blocks selected in both masks.
    #[inline]
    pub fn intersection(self, other: BlockMask) -> BlockMask {
        BlockMask(self.0 & other.0)
    }

    /// True when no blocks are selected.
    #[inline]
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

impl std::ops::BitOr for BlockMask {
    type Output = BlockMask;
    #[inline]
    fn bitor(self, rhs: BlockMask) -> BlockMask {
        BlockMask(self.0 | rhs.0)
    }
}

impl std::ops::BitAnd for BlockMask {
    type Output = BlockMask;
    #[inline]
    fn bitand(self, rhs: BlockMask) -> BlockMask {
        BlockMask(self.0 & rhs.0)
    }
}

impl std::ops::BitOrAssign for BlockMask {
    #[inline]
    fn bitor_assign(&mut self, rhs: BlockMask) {
        self.0 |= rhs.0;
    }
}

impl std::ops::BitAndAssign for BlockMask {
    #[inline]
    fn bitand_assign(&mut self, rhs: BlockMask) {
        self.0 &= rhs.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_values_match_hamming_constants() {
        // BlockMask bit-patterns must be identical to the raw u8
        // constants in hamming.rs — both encode the same block mask.
        assert_eq!(BlockMask::BLOCK0.bits(), 0b0001);
        assert_eq!(BlockMask::BLOCK1.bits(), 0b0010);
        assert_eq!(BlockMask::BLOCK2.bits(), 0b0100);
        assert_eq!(BlockMask::BLOCK3.bits(), 0b1000);
        assert_eq!(BlockMask::ALL.bits(),    0b1111);
        assert_eq!(BlockMask::NONE.bits(),   0b0000);
    }

    #[test]
    fn block_count_correct() {
        assert_eq!(BlockMask::NONE.block_count(),  0);
        assert_eq!(BlockMask::BLOCK0.block_count(), 1);
        assert_eq!(BlockMask::ALL.block_count(),   4);
        assert_eq!((BlockMask::BLOCK0 | BlockMask::BLOCK2).block_count(), 2);
    }

    #[test]
    fn is_empty_semantics() {
        assert!(BlockMask::NONE.is_empty());
        assert!(!BlockMask::ALL.is_empty());
        assert!(!BlockMask::BLOCK0.is_empty());
    }

    #[test]
    fn contains_semantics() {
        let two_blocks = BlockMask::BLOCK0 | BlockMask::BLOCK1;
        assert!(BlockMask::ALL.contains(two_blocks));
        assert!(two_blocks.contains(BlockMask::BLOCK0));
        assert!(!BlockMask::BLOCK0.contains(BlockMask::BLOCK1));
    }

    #[test]
    fn union_and_intersection() {
        let a = BlockMask::BLOCK0 | BlockMask::BLOCK1;
        let b = BlockMask::BLOCK1 | BlockMask::BLOCK2;
        let expected_union = BlockMask::BLOCK0 | BlockMask::BLOCK1 | BlockMask::BLOCK2;
        assert_eq!(a.union(b), expected_union);
        assert_eq!(a.intersection(b), BlockMask::BLOCK1);
    }

    #[test]
    fn default_is_none() {
        // Default derives to 0 (NONE) — no accidental block selection.
        assert_eq!(BlockMask::default(), BlockMask::NONE);
    }

    #[test]
    fn bitor_assign_accumulates() {
        let mut m = BlockMask::NONE;
        m |= BlockMask::BLOCK0;
        m |= BlockMask::BLOCK3;
        assert_eq!(m, BlockMask::BLOCK0 | BlockMask::BLOCK3);
    }

    #[test]
    fn passes_to_hamming_distance() {
        // BlockMask::bits() is a drop-in for the raw u8 hamming API:
        // same bit pattern, same computation.
        use crate::hamming;
        use crate::fingerprint256::Fingerprint256;
        let a = Fingerprint256::ZERO;
        let b = Fingerprint256::new(u64::MAX, 0, 0, 0);
        // Block0 only: 64 differing bits.
        assert_eq!(hamming::distance(&a, &b, BlockMask::BLOCK0.bits()), 64);
        // Block1 only: 0 differing bits (block1 is identical for this pair).
        assert_eq!(hamming::distance(&a, &b, BlockMask::BLOCK1.bits()), 0);
        // All blocks: 64 (only block0 differs).
        assert_eq!(hamming::distance(&a, &b, BlockMask::ALL.bits()), 64);
    }
}
