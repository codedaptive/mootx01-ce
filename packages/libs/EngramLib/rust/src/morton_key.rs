//! The chest placement key (ADR-026, LocusKit spec § 12): the Morton
//! (Z-order) interleave of two bit orderings of a 256-bit fingerprint.
//! Twin of Swift `MortonKey.swift`; the vectors in `engram_lib_tests.rs`
//! pin both ports to the same words.
//!
//! WHY two orderings: sorting fingerprints as one integer is a
//! one-dimensional order over a 256-dimensional Hamming space; two
//! fingerprints that differ in one high bit sort far apart however alike
//! the rest of them is. Interleaving a second, permuted ordering bit for
//! bit means a pair of similar fingerprints lands far apart only when BOTH
//! orderings put a differing bit high, which the permutation makes
//! unlikely.
//!
//! WHY Morton and not Hilbert: the same two orderings under a Hilbert curve
//! give slightly better locality at slightly more code. Nothing above this
//! module reads the key's bits, so the swap is confined here if it is ever
//! measured to matter. Do not add a third ordering.

/// A 512-bit placement key, eight words, most significant word first. The
/// derived `Ord` on the array is lexicographic by word, so it is the
/// numeric order of the 512-bit value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct MortonKey {
    pub words: [u64; 8],
}

impl MortonKey {
    /// The key as 128 lowercase hex characters, most significant word first:
    /// the form a chest node is named by (LocusKit spec § 12). Fixed width
    /// and lowercase so string order equals key order, which is what lets a
    /// room's chests be sorted by name.
    pub fn hex(&self) -> String {
        self.words.iter().map(|w| format!("{w:016x}")).collect()
    }

    /// The key a `hex` name denotes; `None` unless it is exactly 128 hex
    /// characters (either case).
    pub fn from_hex(hex: &str) -> Option<MortonKey> {
        if hex.len() != 128 || !hex.is_ascii() {
            return None;
        }
        let mut words = [0u64; 8];
        for (i, word) in words.iter_mut().enumerate() {
            *word = u64::from_str_radix(&hex[i * 16..(i + 1) * 16], 16).ok()?;
        }
        Some(MortonKey { words })
    }
}

/// One chest's key range after a deal: every key in `low..=high` belongs to
/// it, and `count` keys were dealt into it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyRange<K> {
    pub low: K,
    pub high: K,
    pub count: usize,
}

pub mod chest_placement {
    use super::{KeyRange, MortonKey};
    use substrate_types::fingerprint256::Fingerprint256;

    /// A chest at or above this many drawers owes its room a re-bin.
    pub const CAPACITY: usize = 500;
    /// A re-bin deals chests to this size.
    pub const FILL: usize = 250;

    /// Ordering B's bit for ordering A's bit `i`: an affine bijection on
    /// 0..256 (97 is odd, so coprime with 256). Pinned by the vectors;
    /// changing it re-bins every estate.
    #[inline]
    pub fn permutation(i: usize) -> usize {
        (i.wrapping_mul(97).wrapping_add(41)) & 255
    }

    /// Bit `i` of the fingerprint, where bit 0 is the most significant bit
    /// of `block0` and bit 255 the least significant bit of `block3`.
    #[inline]
    fn bit(f: &Fingerprint256, i: usize) -> u64 {
        let block = match i >> 6 {
            0 => f.block0,
            1 => f.block1,
            2 => f.block2,
            _ => f.block3,
        };
        (block >> (63 - (i & 63))) & 1
    }

    /// The placement key: key bit 2i is fingerprint bit i, key bit 2i+1 is
    /// fingerprint bit `permutation(i)`, bit 0 most significant.
    pub fn key(fingerprint: &Fingerprint256) -> MortonKey {
        let mut words = [0u64; 8];
        for i in 0..256 {
            let a = bit(fingerprint, i);
            let b = bit(fingerprint, permutation(i));
            let (pa, pb) = (2 * i, 2 * i + 1);
            words[pa >> 6] |= a << (63 - (pa & 63));
            words[pb >> 6] |= b << (63 - (pb & 63));
        }
        MortonKey { words }
    }

    /// Deal keys already in ascending order into chests of `fill`: the
    /// ranges of consecutive runs, the last one shorter. Empty input, no
    /// ranges.
    pub fn deal<K: Copy>(sorted_keys: &[K], fill: usize) -> Vec<KeyRange<K>> {
        assert!(fill > 0, "fill must be positive");
        sorted_keys
            .chunks(fill)
            .map(|chunk| KeyRange { low: chunk[0], high: chunk[chunk.len() - 1], count: chunk.len() })
            .collect()
    }

    /// The index of the range whose `low..=high` holds `key`, by binary
    /// search over ranges in ascending order; `None` when the key falls
    /// below the first low, above the last high, or in a gap.
    pub fn range_index<K: Ord>(key: &K, ranges: &[KeyRange<K>]) -> Option<usize> {
        let (mut lo, mut hi) = (0isize, ranges.len() as isize - 1);
        while lo <= hi {
            let mid = ((lo + hi) / 2) as usize;
            let r = &ranges[mid];
            if *key < r.low { hi = mid as isize - 1 }
            else if *key > r.high { lo = mid as isize + 1 }
            else { return Some(mid) }
        }
        None
    }
}
