//! Sampling — deterministic continuous-distribution sampling primitives
//! for the substrate, cookbook §8.17 (canonical home; section authorship
//! is a docs task tracked separately — this file is the reference
//! implementation).
//!
//! These three primitives are the sampling math underneath the
//! Thompson-Sampling bandit used by NeuronKit's dreaming-trigger selector
//! (NEURONKIT_SPEC §3.4). The bandit *policy* (arms, observe, argmax over
//! `DreamingTriggerMode`) stays in NeuronKit; the *sampling math* is a
//! substrate atomic so one implementation serves every consumer (I-25:
//! one implementation per substrate atomic, kits never reimplement).
//!
//!   `sample_normal(rng)`          — Normal(0, 1) via Box-Muller
//!   `sample_gamma(shape, rng)`    — Gamma(shape, scale=1) via Marsaglia-Tsang
//!   `sample_beta(alpha, beta, rng)` — Beta(α, β) via the Gamma ratio
//!
//! All randomness routes through the `SplitMix64` instance supplied by
//! the caller (the substrate PRNG owned by `random_walks`). Uniform draws
//! use `RandomWalks::uniform01`, whose 53-high-bits construction is
//! identical to the Swift port — so the entire sampling stream is
//! cross-port reproducible from a single seed.
//!
//! CONFORMANCE: the scalar reference is the conformance oracle. Outputs
//! are exact IEEE-754 f64 values; cross-port bit-identity is a hard
//! requirement, gated by the `sampling` conformance vector
//! (test-harness/vectors/sampling.json) over the canonical seed. The
//! algorithms use transcendentals (ln, sqrt, cos, powf); the substrate
//! already commits to platform-libm transcendentals being bit-identical
//! between Swift and Rust on the target hardware — see FFT (§8.10),
//! which gates cos/sin twiddles to exact f64 bit equality. The CRC gate
//! is the early-warning if that ever ceases to hold.
//!
//! DETERMINISM: a call consumes a data-dependent number of RNG words
//! (Gamma's rejection loop and the shape<1 reduction draw variable
//! counts), but for a fixed (inputs, seed, starting RNG state) the word
//! sequence — and therefore every sample — is reproducible. The RNG is
//! threaded by `&mut`, never copied, so the consumer observes the
//! post-sample state and can chain draws deterministically (this is how
//! the bandit draws one Beta per arm from a single seeded stream).
//!
//! Cookbook references:
//!   §8.17  Sampling primitives (this file; section authorship pending)
//!   §8.12  Bradley-Terry (adjacent learning math; the bandit's sibling)
//!   §7.4   RandomWalks (owner of SplitMix64 + uniform01, reused here)

use crate::random_walks::{RandomWalks, SplitMix64};

/// Draw a standard Normal(0, 1) sample using the Box-Muller transform.
///
/// Box-Muller: `z = sqrt(-2 · ln(u1)) · cos(2π · u2)`, with
/// `u1, u2 ~ Uniform[0, 1)`. Returns the cosine branch (a single sample
/// per call); the sine branch is intentionally discarded so RNG
/// consumption is a fixed two uniforms per call and the cross-port stream
/// stays aligned (no hidden cached-sample state).
///
/// `u1` is clamped up to `f64::MIN_POSITIVE` so `ln` is defined when the
/// RNG yields exactly zero (mirrors Swift's `Double.leastNormalMagnitude`).
/// The clamp is numerically invisible in practice and applied identically
/// in both ports.
#[inline]
pub fn sample_normal(rng: &mut SplitMix64) -> f64 {
    let u1 = RandomWalks::uniform01(rng).max(f64::MIN_POSITIVE);
    let u2 = RandomWalks::uniform01(rng);
    (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
}

/// Draw a sample from Gamma(shape, scale = 1) using Marsaglia-Tsang (2000).
///
/// For `shape >= 1` the Marsaglia-Tsang squeeze-and-log rejection method
/// is used: `d = shape - 1/3`, `c = 1/sqrt(9d)`; propose `x ~ N(0,1)`,
/// `v = (1 + c·x)^3` (requiring `v > 0`), accept on the squeeze test
/// `u < 1 - 0.0331·x^4` or the log test
/// `ln(u) < 0.5·x^2 + d·(1 - v + ln(v))`. Expected iterations are O(1) —
/// the squeeze test accepts most proposals without a log.
///
/// For `shape < 1` the Ahrens-Dieter reduction is applied:
/// `Gamma(α) = Gamma(α+1) · U^(1/α)`, so the main branch only ever handles
/// `shape >= 1`. The reduction draws one extra uniform before the
/// recursive Gamma(α+1) draw; the Swift port draws in the same order so
/// the streams stay aligned.
///
/// # Panics
/// Panics if `shape <= 0` — undefined for the Gamma distribution and a
/// caller error (mirrors Swift's `precondition`).
pub fn sample_gamma(shape: f64, rng: &mut SplitMix64) -> f64 {
    assert!(shape > 0.0, "Gamma shape must be positive (got {shape})");
    if shape < 1.0 {
        // Ahrens-Dieter reduction so the main branch only handles
        // shape >= 1. The uniform is drawn BEFORE the recursive
        // Gamma(shape+1) draw — Swift matches this order.
        let u = RandomWalks::uniform01(rng);
        let base = sample_gamma(shape + 1.0, rng);
        return base * u.powf(1.0 / shape);
    }
    // Marsaglia-Tsang (2000): d = shape - 1/3, c = 1/sqrt(9d).
    let d = shape - 1.0 / 3.0;
    let c = 1.0 / (9.0 * d).sqrt();
    loop {
        // Rejection loop: x ~ N(0,1), v = (1 + cx)^3, require v > 0.
        let (x, v) = loop {
            let x = sample_normal(rng);
            let v = 1.0 + c * x;
            if v > 0.0 {
                break (x, v);
            }
        };
        let v = v * v * v; // cube
        let u = RandomWalks::uniform01(rng);
        let x_sq = x * x;
        // Squeeze test — avoids the log for the overwhelming majority of
        // proposals (Marsaglia-Tsang's constant 0.0331).
        if u < 1.0 - 0.0331 * (x_sq * x_sq) {
            return d * v;
        }
        // Log acceptance test (exact boundary).
        if u.ln() < 0.5 * x_sq + d * (1.0 - v + v.ln()) {
            return d * v;
        }
        // Reject: loop back (rare path — expected constant iterations).
    }
}

/// Draw a sample from Beta(alpha, beta) using two Gamma samples.
///
/// `Beta(α, β) = Gamma(α, 1) / (Gamma(α, 1) + Gamma(β, 1))`. The two Gamma
/// draws share the threaded RNG, so the α draw consumes its words first,
/// then the β draw — the Swift port draws in the same order.
///
/// Returns 0.5 when both Gamma draws are zero (a degenerate sum that
/// cannot occur for `alpha, beta >= 1`, but is handled so the function is
/// total). For `alpha, beta > 0` the result lies in `[0, 1]`.
///
/// # Panics
/// Panics if `alpha <= 0` or `beta <= 0` (mirrors Swift's `precondition`).
pub fn sample_beta(alpha: f64, beta: f64, rng: &mut SplitMix64) -> f64 {
    assert!(alpha > 0.0, "Beta alpha must be positive (got {alpha})");
    assert!(beta > 0.0, "Beta beta must be positive (got {beta})");
    let g1 = sample_gamma(alpha, rng);
    let g2 = sample_gamma(beta, rng);
    let total = g1 + g2;
    if total <= 0.0 {
        return 0.5;
    }
    g1 / total
}

// MARK: - Properties
//
//   deterministic:    same (inputs, seed, starting RNG state) → same
//                     sample sequence, in both reference language ports.
//   normal-fixed-rng: sample_normal consumes exactly two uniforms per
//                     call (cosine branch only; no cached sine sample).
//   gamma-support:    sample_gamma(shape>0) returns a value in [0, ∞).
//   beta-support:     sample_beta(α>0, β>0) returns a value in [0, 1].
//   rng-threaded:     the RNG is &mut, never copied — consumers chain
//                     draws (one Beta per bandit arm) off one stream.

#[cfg(test)]
mod tests {
    use super::*;

    // The canonical conformance seed (matches the sampling.json vector
    // generator). Kept in sync with the Swift test + harness.
    const SEED: u64 = 0xCAFE_BABE_DEAD_BEEF;

    #[test]
    fn normal_consumes_two_uniforms() {
        // sample_normal must advance the RNG exactly as two uniform01
        // draws would — proves the fixed-consumption property.
        let mut a = SplitMix64::new(SEED);
        let _ = sample_normal(&mut a);

        let mut b = SplitMix64::new(SEED);
        let _ = RandomWalks::uniform01(&mut b);
        let _ = RandomWalks::uniform01(&mut b);

        assert_eq!(a.state, b.state, "sample_normal must consume exactly two uniforms");
    }

    #[test]
    fn normal_is_deterministic() {
        let mut a = SplitMix64::new(SEED);
        let mut b = SplitMix64::new(SEED);
        for _ in 0..1000 {
            assert_eq!(sample_normal(&mut a).to_bits(), sample_normal(&mut b).to_bits());
        }
    }

    #[test]
    fn normal_mean_near_zero() {
        let mut rng = SplitMix64::new(SEED);
        let n = 100_000;
        let mut sum = 0.0;
        for _ in 0..n {
            sum += sample_normal(&mut rng);
        }
        let mean = sum / (n as f64);
        // Standard error ~ 1/sqrt(n) ≈ 0.003; 0.05 is a generous band.
        assert!(mean.abs() < 0.05, "Normal sample mean drifted: {mean}");
    }

    #[test]
    fn gamma_is_deterministic() {
        for &shape in &[0.3_f64, 0.5, 1.0, 2.0, 5.5, 50.0] {
            let mut a = SplitMix64::new(SEED);
            let mut b = SplitMix64::new(SEED);
            for _ in 0..200 {
                assert_eq!(
                    sample_gamma(shape, &mut a).to_bits(),
                    sample_gamma(shape, &mut b).to_bits(),
                    "Gamma not deterministic at shape {shape}"
                );
            }
        }
    }

    #[test]
    fn gamma_is_nonnegative() {
        let mut rng = SplitMix64::new(SEED);
        for &shape in &[0.1_f64, 0.5, 1.0, 3.0, 20.0] {
            for _ in 0..1000 {
                let g = sample_gamma(shape, &mut rng);
                assert!(g >= 0.0, "Gamma({shape}) produced negative {g}");
                assert!(g.is_finite(), "Gamma({shape}) produced non-finite {g}");
            }
        }
    }

    #[test]
    fn gamma_mean_near_shape() {
        // E[Gamma(shape, 1)] = shape.
        for &shape in &[0.5_f64, 1.0, 2.0, 5.0] {
            let mut rng = SplitMix64::new(SEED ^ shape.to_bits());
            let n = 50_000;
            let mut sum = 0.0;
            for _ in 0..n {
                sum += sample_gamma(shape, &mut rng);
            }
            let mean = sum / (n as f64);
            // Gamma variance = shape; SE = sqrt(shape/n). 5% relative band.
            assert!(
                (mean - shape).abs() < 0.05 * shape + 0.02,
                "Gamma({shape}) mean {mean} far from {shape}"
            );
        }
    }

    #[test]
    fn beta_is_deterministic() {
        let mut a = SplitMix64::new(SEED);
        let mut b = SplitMix64::new(SEED);
        for _ in 0..500 {
            assert_eq!(
                sample_beta(2.0, 3.0, &mut a).to_bits(),
                sample_beta(2.0, 3.0, &mut b).to_bits()
            );
        }
    }

    #[test]
    fn beta_in_unit_interval() {
        let mut rng = SplitMix64::new(SEED);
        for &(a, b) in &[(1.0_f64, 1.0_f64), (2.0, 5.0), (0.5, 0.5), (10.0, 1.0)] {
            for _ in 0..1000 {
                let x = sample_beta(a, b, &mut rng);
                assert!((0.0..=1.0).contains(&x), "Beta({a},{b}) out of [0,1]: {x}");
            }
        }
    }

    #[test]
    fn beta_mean_near_analytic() {
        // E[Beta(α, β)] = α / (α + β).
        for &(a, b) in &[(2.0_f64, 3.0_f64), (1.0, 1.0), (5.0, 2.0)] {
            let mut rng = SplitMix64::new(SEED ^ ((a as u64) << 8 | (b as u64)));
            let n = 50_000;
            let mut sum = 0.0;
            for _ in 0..n {
                sum += sample_beta(a, b, &mut rng);
            }
            let mean = sum / (n as f64);
            let expected = a / (a + b);
            assert!(
                (mean - expected).abs() < 0.02,
                "Beta({a},{b}) mean {mean} far from {expected}"
            );
        }
    }

    #[test]
    #[should_panic(expected = "Gamma shape must be positive")]
    fn gamma_rejects_nonpositive_shape() {
        let mut rng = SplitMix64::new(SEED);
        let _ = sample_gamma(0.0, &mut rng);
    }

    #[test]
    #[should_panic(expected = "Beta alpha must be positive")]
    fn beta_rejects_nonpositive_alpha() {
        let mut rng = SplitMix64::new(SEED);
        let _ = sample_beta(0.0, 1.0, &mut rng);
    }
}
