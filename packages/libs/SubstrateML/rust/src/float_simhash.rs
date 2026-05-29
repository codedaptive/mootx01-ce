// FloatSimHash: float-input SimHash for external embedding providers.
//
// Mirror of Swift's SubstrateLib.FloatSimHash. Same algorithm:
//   - Generate 256 random hyperplanes from a deterministic seed.
//   - For each bit k in 0..256: output_bit_k = sign(<v, h_k>).
//   - Pack into four u64 blocks per Fingerprint256.
//
// The hyperplane generation is seeded (SplitMix64) so the same
// seed always produces the same projection across runs and
// across processes. Bit-identity guaranteed against the Swift
// implementation given the same (vector, seed) tuple.

use substrate_types::fingerprint256::Fingerprint256;
use crate::random_walks::SplitMix64;

/// Project a float vector to a 256-bit Fingerprint256 via
/// signed hyperplane projection.
///
/// Parameters:
///   `vector`: dense input vector (any dimension; 384 for
///     MiniLM, 768 for BERT base, 768 for EmbeddingGemma 300M).
///   `seed`: deterministic seed for hyperplane generation. Same
///     seed always produces the same projection. Different
///     providers should use different seeds so their fingerprints
///     are model-tagged independent of vector content.
pub fn project(vector: &[f32], seed: u64) -> Fingerprint256 {
    if vector.is_empty() {
        return Fingerprint256::ZERO;
    }
    let dim = vector.len();
    let mut blocks: [u64; 4] = [0, 0, 0, 0];
    let mut rng = SplitMix64::new(seed);

    for bit_index in 0..256 {
        let mut sum: f32 = 0.0;
        for &v_i in vector.iter().take(dim) {
            // Rademacher (+1/-1) hyperplane entries via the
            // low bit of the next PRNG output. Matches Swift.
            let u = rng.next();
            let plane: f32 = if (u & 1) == 0 { -1.0 } else { 1.0 };
            sum += plane * v_i;
        }
        if sum > 0.0 {
            let block_index = bit_index / 64;
            let bit_in_block = bit_index % 64;
            blocks[block_index] |= 1u64 << bit_in_block;
        }
    }
    Fingerprint256::new(blocks[0], blocks[1], blocks[2], blocks[3])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic() {
        let v: Vec<f32> = (0..384).map(|i| (i as f32) / 384.0 - 0.5).collect();
        let fp1 = project(&v, 0xDEAD_BEEF);
        let fp2 = project(&v, 0xDEAD_BEEF);
        assert_eq!(fp1, fp2, "same input + seed must produce same fingerprint");
    }

    #[test]
    fn seed_affects_output() {
        let v: Vec<f32> = (0..384).map(|i| (i as f32) / 384.0 - 0.5).collect();
        let fp1 = project(&v, 0x01);
        let fp2 = project(&v, 0x02);
        assert_ne!(fp1, fp2, "different seeds should produce different fingerprints");
    }

    #[test]
    fn empty_vector_returns_zero() {
        let fp = project(&[], 0x42);
        assert_eq!(fp, Fingerprint256::ZERO);
    }

    fn hamming(a: Fingerprint256, b: Fingerprint256) -> u32 {
        (a.block0 ^ b.block0).count_ones()
            + (a.block1 ^ b.block1).count_ones()
            + (a.block2 ^ b.block2).count_ones()
            + (a.block3 ^ b.block3).count_ones()
    }

    #[test]
    fn similar_vectors_close() {
        // Fixed inputs (no rand crate); two vectors that differ
        // only slightly should produce fingerprints with low
        // Hamming distance.
        let mut base: Vec<f32> = (0..384).map(|i| ((i * 17 + 3) % 200) as f32 / 100.0 - 1.0).collect();
        let mut perturbed = base.clone();
        for i in 0..10 {
            perturbed[i] += 0.01;
        }
        // Tiny dummy mutation to silence the "base is never mutated" warning.
        base[0] = base[0];
        let fp1 = project(&base, 0xCAFE);
        let fp2 = project(&perturbed, 0xCAFE);
        let d = hamming(fp1, fp2);
        assert!(d < 32, "small perturbation should preserve most bits; got {}", d);
    }

    #[test]
    fn orthogonal_vectors_far_apart() {
        // Two deterministically-generated different vectors should
        // differ on roughly half the bits (~128 of 256).
        let v1: Vec<f32> = (0..384).map(|i| ((i * 13 + 7) % 200) as f32 / 100.0 - 1.0).collect();
        let v2: Vec<f32> = (0..384).map(|i| ((i * 29 + 11) % 200) as f32 / 100.0 - 1.0).collect();
        let fp1 = project(&v1, 0xABCD);
        let fp2 = project(&v2, 0xABCD);
        let d = hamming(fp1, fp2);
        assert!(d > 80, "random vectors should have meaningful Hamming separation; got {}", d);
        assert!(d < 180, "random vectors shouldn't be near-inverse; got {}", d);
    }
}
