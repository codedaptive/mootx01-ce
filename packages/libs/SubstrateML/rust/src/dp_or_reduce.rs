// dp_or_reduce.rs
//
// Differentially-private OR-reduction per cookbook § 12.6. Mirror
// of glref-swift-DPORReduction.swift.
//
// k-anonymity threshold + Laplace noise. Default ε = 1.0, δ = 1e-9,
// k = 3.

use crate::random_walks::SplitMix64;
use substrate_types::fingerprint256::Fingerprint256;

#[derive(Debug, Clone, Copy)]
pub struct DPParameters {
    pub epsilon: f64,
    pub delta: f64,
    pub k_anonymity: usize,
}

impl DPParameters {
    pub fn new(epsilon: f64, delta: f64, k_anonymity: usize) -> Self {
        assert!(epsilon > 0.0, "epsilon must be positive");
        assert!((0.0..1.0).contains(&delta), "delta in [0,1)");
        assert!(k_anonymity >= 1, "k-anonymity at least 1");
        Self { epsilon, delta, k_anonymity }
    }
}

impl Default for DPParameters {
    fn default() -> Self {
        Self::new(1.0, 1e-9, 3)
    }
}

pub struct DPORReduction;

impl DPORReduction {
    /// Differentially-private OR-reduction over per-estate fingerprints.
    pub fn reduce(fingerprints: &[Fingerprint256],
                  params: &DPParameters,
                  rng_seed: u64) -> Fingerprint256 {
        if fingerprints.is_empty() {
            return Fingerprint256::ZERO;
        }

        // Per-bit popcounts across contributors.
        let mut popcounts = [0_i32; 256];
        for fp in fingerprints {
            for i in 0..256 {
                let block = match i / 64 {
                    0 => fp.block0,
                    1 => fp.block1,
                    2 => fp.block2,
                    _ => fp.block3,
                };
                if (block >> (i % 64)) & 1 == 1 {
                    popcounts[i] += 1;
                }
            }
        }

        // Add Laplace noise of scale 1/ε to each popcount.
        let mut rng = SplitMix64::new(rng_seed);
        let scale = 1.0 / params.epsilon;
        let mut perturbed = [0.0_f64; 256];
        for i in 0..256 {
            perturbed[i] = popcounts[i] as f64 + Self::laplace_noise(scale, &mut rng);
        }

        // Apply k-anonymity threshold.
        let mut out = Fingerprint256::ZERO;
        for i in 0..256 {
            if perturbed[i] >= params.k_anonymity as f64 {
                let mask = 1_u64 << (i % 64);
                match i / 64 {
                    0 => out.block0 |= mask,
                    1 => out.block1 |= mask,
                    2 => out.block2 |= mask,
                    _ => out.block3 |= mask,
                }
            }
        }
        out
    }

    /// Laplace noise with scale b. Inverse-CDF method.
    pub fn laplace_noise(scale: f64, rng: &mut SplitMix64) -> f64 {
        let raw = rng.next();
        let u = ((raw >> 11) as f64 / (1_u64 << 53) as f64) - 0.5;
        let sign = if u >= 0.0 { 1.0 } else { -1.0 };
        -scale * sign * (1.0 - 2.0 * u.abs()).ln()
    }
}
