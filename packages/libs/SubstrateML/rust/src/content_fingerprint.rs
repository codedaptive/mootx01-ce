//! content_fingerprint.rs — a 256-bit SimHash of a drawer's TEXT, the
//! placement key input for chests (LocusKit § 12). Mirrors the Swift
//! `ContentFingerprint` exactly.
//!
//! The stored drawer fingerprint is structural (bitmaps, lattice, lineage
//! and capture week, channel and source); no text enters it, so two
//! drawers about different things filed the same way collide on it. Chest
//! placement needs the opposite: drawers that say similar things must land
//! near each other whatever their filing. This is that value. It is
//! computed at capture and at re-bin and never stored; the tree carries
//! the placement, not the key.
//!
//! THE MATH. Classic feature SimHash over the drawer's character
//! 3-shingles (`shingle_similarity::shingles`, the same set the cohesion
//! statistic scores, so chest locality and the anomaly statistic measure
//! one thing). Each shingle contributes four 64-bit feature hashes, one
//! per block: FNV-1a 64 of the shingle prefixed by the block's salt
//! (`c0:`, `c1:`, `c2:`, `c3:`). For every bit position a counter takes
//! +1 when the feature hash has the bit set and −1 when it is clear; the
//! output bit is set when the counter ends above zero. Shingles that two
//! texts share push the same bits the same way, so the Hamming distance
//! between two content fingerprints falls with the shingle overlap.
//!
//! WHY NOT THE HYPERPLANE KERNEL. `simhash::block` hashes a FIXED-width
//! bit vector through a manifest's hyperplane family; a shingle set has
//! no fixed width, and folding it into one would lose the per-feature
//! vote that makes SimHash track overlap. The vote form needs no family
//! and no manifest: the value is a pure function of the text, identical
//! on every device and both ports, which is what a chest name derived
//! from it requires (ADR-026 D7).
//!
//! DETERMINISM. The counters are exact integer sums, so the order the
//! shingle set is visited in cannot change the result; no float, no
//! clock, no randomness. The empty text (no
//! shingles) yields `Fingerprint256::ZERO`.

use std::collections::BTreeSet;

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::fnv;

use crate::shingle_similarity::shingles;

/// The per-block salts. Four independent feature hashes per shingle come
/// from one FNV-1a family by prefixing the shingle; the prefix is part of
/// the conformance contract (pinned in the test vectors).
pub const BLOCK_SALTS: [&str; 4] = ["c0:", "c1:", "c2:", "c3:"];

/// The content fingerprint of `text`: the 256-bit SimHash of its
/// shingles; `Fingerprint256::ZERO` for a text with no shingles.
pub fn fingerprint(text: &str) -> Fingerprint256 {
    fingerprint_of_shingles(&shingles(text))
}

/// The content fingerprint over a PRE-COMPUTED shingle set, for a caller
/// that already shingled the text for the cohesion statistic. The string
/// form delegates here (one implementation, I-25).
pub fn fingerprint_of_shingles(set: &BTreeSet<String>) -> Fingerprint256 {
    if set.is_empty() {
        return Fingerprint256::ZERO;
    }
    // 4 blocks × 64 bit counters. i32 cannot overflow: a text would need
    // over two billion distinct shingles.
    let mut counters = [0i32; 256];
    for shingle in set {
        for (block, salt) in BLOCK_SALTS.iter().enumerate() {
            let h = fnv::hash64(&format!("{salt}{shingle}"));
            let base = block * 64;
            for bit in 0..64 {
                counters[base + bit] += if (h >> bit) & 1 == 1 { 1 } else { -1 };
            }
        }
    }
    let mut words = [0u64; 4];
    for (block, word) in words.iter_mut().enumerate() {
        for bit in 0..64 {
            if counters[block * 64 + bit] > 0 {
                *word |= 1u64 << bit;
            }
        }
    }
    Fingerprint256::new(words[0], words[1], words[2], words[3])
}
