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

use std::sync::OnceLock;

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::float_simhash_planes::FloatSimHashPlanes;
use substrate_kernel::kernel::{PortableKernel, SubstrateKernel};
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
    // Single canonical leaf: project routes through the SubstrateKernel dispatch
    // op (SUBSTRATEKERNEL_SPEC § 5.4) rather than an inline loop. `planes`
    // materializes the ±1 hyperplane set; the kernel applies it (pure
    // signed-sum-and-sign). The platform kernel is selected once and cached — the
    // projection is on the hot encode path, so re-selecting per call would re-run
    // backend detection. A SIMD float backend (1.1) drops in at the kernel with no
    // change to this call site.
    let p = planes(seed, vector.len());
    dispatch_kernel().float_simhash_project(vector, &p)
}

/// The platform kernel, selected once and reused. On aarch64 (with the SIMD
/// feature) this is `SimdKernel`, which inherits the scalar
/// `float_simhash_project` reference until the 1.1 SIMD float backend overrides
/// it; elsewhere it is `ScalarKernel`.
fn dispatch_kernel() -> &'static (dyn SubstrateKernel + 'static) {
    static KERNEL: OnceLock<Box<dyn SubstrateKernel>> = OnceLock::new();
    KERNEL
        .get_or_init(PortableKernel::for_current_platform)
        .as_ref()
}

/// Materialize the ±1 hyperplane set `project` uses for `dim`, as a
/// `FloatSimHashPlanes` for the SubstrateKernel dispatch op
/// `float_simhash_project` (SUBSTRATEKERNEL_SPEC § 5.4).
///
/// Generated in the SAME SplitMix64 draw order `project` consumes — 256
/// hyperplanes outer, `dim` coordinates inner — so the kernel op fed these
/// planes reproduces `project(vector, seed)` bit for bit. A sign bit is set
/// when the draw's low bit is 1 (plane = +1), matching `project`'s
/// `if (u & 1) == 0 { -1.0 } else { 1.0 }`. Deterministic and seed-immutable;
/// callers cache it per (seed, dim).
pub fn planes(seed: u64, dim: usize) -> FloatSimHashPlanes {
    let total = 256 * dim;
    let mut words = vec![0u64; (total + 63) / 64];
    let mut rng = SplitMix64::new(seed);
    let mut bit_index = 0usize;
    for _ in 0..256 {
        for _ in 0..dim {
            let u = rng.next();
            if (u & 1) == 1 {
                words[bit_index >> 6] |= 1u64 << (bit_index & 63);
            }
            bit_index += 1;
        }
    }
    FloatSimHashPlanes::new(dim, words)
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
