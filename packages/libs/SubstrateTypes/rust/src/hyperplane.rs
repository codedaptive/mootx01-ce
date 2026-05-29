// hyperplane.rs
//
// 64 random hyperplanes per fingerprint block, manifest-immutable
// per cookbook § 3.7. Four families total (H_0..H_3), one per
// block of the 256-bit fingerprint.
//
// Each hyperplane is a ±1-valued vector of the appropriate length
// (192 for block 0, 64 for blocks 1..3). For binary inputs, the
// dot product reduces to:
//
//   sign(<v, h>) = sign(popcount(v & h.positive) - popcount(v & h.negative))
//
// CONSTITUTIONAL: hyperplane seeds are set at estate creation and
// never rotate within an estate version. Rotation requires a new
// estate or a v2 successor architecture migration. This is what
// makes fingerprints stable across captures and what allows
// cross-replica sync (CRDT § 5) to converge.

/// A single ±1-valued hyperplane of arbitrary bit-length, encoded
/// as two bitmasks. `positive_mask` has a 1 wherever the
/// hyperplane has +1; `negative_mask` has a 1 wherever the
/// hyperplane has −1; both have 0 elsewhere.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hyperplane {
    #[cfg_attr(feature = "serde-support", serde(rename = "positiveMask"))]
    pub positive_mask: Vec<u64>,
    #[cfg_attr(feature = "serde-support", serde(rename = "negativeMask"))]
    pub negative_mask: Vec<u64>,
    #[cfg_attr(feature = "serde-support", serde(rename = "bitLength"))]
    pub bit_length: usize,
}

impl Hyperplane {
    pub fn new(positive_mask: Vec<u64>, negative_mask: Vec<u64>,
               bit_length: usize) -> Self {
        assert_eq!(positive_mask.len(), negative_mask.len(),
                   "masks must have equal length");
        assert!(positive_mask.len() * 64 >= bit_length,
                "mask length must cover bit_length");
        Self { positive_mask, negative_mask, bit_length }
    }

    /// Computes `sign(<v, h>)` for binary `v`. Returns true if
    /// the dot product is strictly positive, false otherwise.
    /// Ties (dot product == 0) resolve to false; the manifest's
    /// seed family is chosen so ties are vanishingly rare in
    /// practice (the per-block input has full bit length, well
    /// past the regime where 0 dot products are common).
    #[inline]
    pub fn sign(&self, v: &[u64]) -> bool {
        assert_eq!(v.len(), self.positive_mask.len(),
                   "input must match hyperplane mask length");
        let mut pos: u32 = 0;
        let mut neg: u32 = 0;
        for i in 0..v.len() {
            pos = pos.wrapping_add((v[i] & self.positive_mask[i]).count_ones());
            neg = neg.wrapping_add((v[i] & self.negative_mask[i]).count_ones());
        }
        pos > neg
    }
}

/// A family of 64 hyperplanes covering one fingerprint block.
/// Lives in the estate manifest under `hyperplane_seeds.H_n`.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HyperplaneFamily {
    #[cfg_attr(feature = "serde-support", serde(rename = "blockIndex"))]
    pub block_index: usize,        // 0, 1, 2, or 3
    #[cfg_attr(feature = "serde-support", serde(rename = "inputBitLength"))]
    pub input_bit_length: usize,   // 192 for block 0, 64 for blocks 1..3
    pub planes: Vec<Hyperplane>,   // exactly 64 planes (name matches Swift)
}

impl HyperplaneFamily {
    pub fn new(block_index: usize,
               input_bit_length: usize,
               planes: Vec<Hyperplane>) -> Self {
        assert!(block_index < 4, "block index must be 0..3");
        assert_eq!(planes.len(), 64,
                   "hyperplane family requires exactly 64 planes");
        for p in &planes {
            assert_eq!(p.bit_length, input_bit_length,
                       "all planes must share input bit length");
        }
        Self { block_index, input_bit_length, planes }
    }

    /// Deterministic generation from a 32-byte seed. Used at
    /// estate creation to populate the manifest. Two estates with
    /// the same seed produce identical families; two estates with
    /// different seeds produce incompatible fingerprints.
    ///
    /// `density` controls the proportion of non-zero entries in
    /// each plane. 1.0 means dense ±1; 0.5 means roughly half
    /// the bits are 0 (sparse hyperplane case from OQ-2.1).
    pub fn generate(seed: &[u8; 32],
                    block_index: usize,
                    input_bit_length: usize,
                    density: f64) -> HyperplaneFamily {
        assert!(density > 0.0 && density <= 1.0,
                "density must be in (0, 1]");
        let mut rng = SplitMix64::new(seed);
        let word_count = (input_bit_length + 63) / 64;
        let mut planes = Vec::with_capacity(64);
        for _ in 0..64 {
            let mut pos = vec![0u64; word_count];
            let mut neg = vec![0u64; word_count];
            for bit in 0..input_bit_length {
                let r = rng.next();
                // Compute threshold safely. At density = 1.0,
                // (u64::MAX as f64) rounds up past u64::MAX, so
                // the saturating cast back to u64 still produces
                // u64::MAX, which means r < threshold is false
                // for r == u64::MAX (one bit pattern in 2^64 misses
                // the active branch). Treat density >= 1.0 as
                // "every bit active" to match the Swift mirror and
                // avoid that asymmetry.
                let is_active = if density >= 1.0 {
                    true
                } else {
                    let threshold = (u64::MAX as f64 * density) as u64;
                    r < threshold
                };
                if is_active {
                    let sign_draw = rng.next();
                    if sign_draw & 1 == 1 {
                        pos[bit / 64] |= 1u64 << (bit % 64);
                    } else {
                        neg[bit / 64] |= 1u64 << (bit % 64);
                    }
                }
            }
            planes.push(Hyperplane::new(pos, neg, input_bit_length));
        }
        HyperplaneFamily::new(block_index, input_bit_length, planes)
    }

    /// Stable 64-bit hash of the family's content, used for audit
    /// trails when a pairing is established or dissolved. FNV-1a
    /// over the canonical wire serialization: block_index (1 byte),
    /// input_bit_length (4 bytes BE), then for each of the 64
    /// planes the positive_mask and negative_mask words BE.
    /// Two families with identical content produce identical hashes;
    /// two with any difference produce different hashes with high
    /// probability.
    pub fn canonical_hash(&self) -> u64 {
        let mut h: u64 = 0xCBF29CE484222325;
        let mix = |h: &mut u64, b: u8| {
            *h ^= b as u64;
            *h = h.wrapping_mul(0x100000001B3);
        };
        mix(&mut h, self.block_index as u8);
        for b in (self.input_bit_length as u32).to_be_bytes() {
            mix(&mut h, b);
        }
        for plane in &self.planes {
            for w in &plane.positive_mask {
                for b in w.to_be_bytes() { mix(&mut h, b); }
            }
            for w in &plane.negative_mask {
                for b in w.to_be_bytes() { mix(&mut h, b); }
            }
        }
        h
    }

    /// Canonical per-block SimHash input widths (cookbook section 3):
    /// block 0 is the 192-bit bitmap triple, blocks 1..3 are 64-bit
    /// facet words.
    pub const CANONICAL_BLOCK_WIDTHS: [usize; 4] = [192, 64, 64, 64];

    /// Generate the canonical four-block family set from one 32-byte
    /// base seed. The base is diversified per block (generate does not
    /// vary on block_index) and each block uses its canonical width.
    /// Mirror of the Swift `HyperplaneFamily.blockFamilies`.
    pub fn block_families(base_seed: &[u8; 32], density: f64) -> [HyperplaneFamily; 4] {
        [
            HyperplaneFamily::generate(&Self::diversified_seed(base_seed, 0), 0, 192, density),
            HyperplaneFamily::generate(&Self::diversified_seed(base_seed, 1), 1, 64, density),
            HyperplaneFamily::generate(&Self::diversified_seed(base_seed, 2), 2, 64, density),
            HyperplaneFamily::generate(&Self::diversified_seed(base_seed, 3), 3, 64, density),
        ]
    }

    /// Mix a block index into a 32-byte base seed and expand back to 32
    /// bytes, giving each block an independent seed. Byte-identical to
    /// the Swift `HyperplaneFamily.diversifiedSeed`.
    pub fn diversified_seed(base: &[u8], block_index: usize) -> [u8; 32] {
        let mut h: u64 = 0xCBF2_9CE4_8422_2325;
        for &byte in base {
            h ^= byte as u64;
            h = h.wrapping_mul(0x0000_0100_0000_01B3);
        }
        h ^= (block_index as u8) as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
        Self::expand_seed_64(h)
    }

    /// Expand a 64-bit seed to 32 bytes via four SplitMix64 rounds.
    /// Byte-identical to the Swift `HyperplaneFamily.expandSeed64`.
    pub fn expand_seed_64(seed: u64) -> [u8; 32] {
        let mut out = [0u8; 32];
        let mut state = seed;
        for i in 0..4 {
            state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^= z >> 31;
            for j in 0..8 {
                out[i * 8 + j] = ((z >> (j * 8)) & 0xFF) as u8;
            }
        }
        out
    }
}

// SplitMix64 PRNG
//
// Deterministic, fast, well-mixed PRNG suitable for generating
// hyperplane bit patterns from a 32-byte seed. Not cryptographic;
// fine here because the hyperplane content is not secret (the
// manifest is plaintext) — what matters is determinism and good
// statistical distribution.

struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn new(seed: &[u8; 32]) -> Self {
        let mut s: u64 = 0;
        for i in 0..8 {
            s |= (seed[i] as u64) << (i * 8);
        }
        for chunk in 1..4 {
            let mut w: u64 = 0;
            for i in 0..8 {
                w |= (seed[chunk * 8 + i] as u64) << (i * 8);
            }
            s ^= w.wrapping_add(0x9E3779B97F4A7C15);
        }
        Self { state: s }
    }

    fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
}

// Manifest hookup
//
// In production storage, the four families live as:
//
//   manifest.hyperplane_seeds.H_0 (block 0, 192-bit, 24-byte planes)
//   manifest.hyperplane_seeds.H_1 (block 1, 64-bit,  8-byte planes)
//   manifest.hyperplane_seeds.H_2 (block 2, 64-bit,  8-byte planes)
//   manifest.hyperplane_seeds.H_3 (block 3, 64-bit,  8-byte planes)
//
// Total storage: 24*64 + 8*64*3 = 3072 bytes per estate.
//
// Federation extends with H_shared_household, H_shared_fleet,
// H_shared_company, H_shared_industry, H_shared_msp — same
// generation, different seeds per pairing scope.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_generation() {
        let seed = [0xABu8; 32];
        let f1 = HyperplaneFamily::generate(&seed, 0, 192, 1.0);
        let f2 = HyperplaneFamily::generate(&seed, 0, 192, 1.0);
        assert_eq!(f1, f2);
    }

    #[test]
    fn different_seeds_differ() {
        let seed_a = [0xABu8; 32];
        let seed_b = [0xCDu8; 32];
        let fa = HyperplaneFamily::generate(&seed_a, 0, 64, 1.0);
        let fb = HyperplaneFamily::generate(&seed_b, 0, 64, 1.0);
        assert_ne!(fa, fb);
    }

    #[test]
    fn sign_positive_when_majority_aligned() {
        // hand-craft a hyperplane: +1 at bits 0,1,2,3; -1 at bit 4
        let pos = vec![0b0000_1111u64];
        let neg = vec![0b0001_0000u64];
        let h = Hyperplane::new(pos, neg, 5);
        // input with bits 0,1,2,3 set and bit 4 unset → 4 pos, 0 neg
        assert!(h.sign(&[0b0000_1111u64]));
        // input with bit 4 set and bits 0..3 unset → 0 pos, 1 neg
        assert!(!h.sign(&[0b0001_0000u64]));
    }
}
