// Sampling.swift
//
// Deterministic continuous-distribution sampling primitives for the
// substrate, cookbook §8.17 (canonical home; section authorship is a
// docs task tracked separately — this file is the reference
// implementation).
//
// These three primitives are the sampling math underneath the
// Thompson-Sampling bandit used by NeuronKit's dreaming-trigger
// selector (NEURONKIT_SPEC §3.4). The bandit *policy* (arms,
// observe, argmax over DreamingTriggerMode) stays in NeuronKit; the
// *sampling math* is a substrate atomic so that one implementation
// serves every consumer (I-25: one implementation per substrate
// atomic, kits never reimplement).
//
//   sampleNormal(rng:)            — Normal(0, 1) via Box-Muller
//   sampleGamma(shape:rng:)       — Gamma(shape, scale=1) via Marsaglia-Tsang
//   sampleBeta(alpha:beta:rng:)   — Beta(α, β) via the Gamma ratio
//
// All randomness routes through the SplitMix64 instance supplied by
// the caller (the substrate PRNG owned by RandomWalks). Uniform draws
// use RandomWalks.uniform01, whose 53-high-bits construction is
// identical in the Swift and Rust ports — so the entire sampling
// stream is cross-port reproducible from a single seed.
//
// CONFORMANCE: the scalar reference is the conformance oracle. The
// outputs are exact IEEE-754 f64 values; cross-port bit-identity is a
// hard requirement, gated by the `sampling` conformance vector
// (test-harness/vectors/sampling.json) over the canonical seed. The
// algorithms use transcendentals (log, sqrt, cos, pow); the substrate
// already commits to platform-libm transcendentals being bit-identical
// between Swift and Rust on the target hardware — see FFT (§8.10),
// which gates cos/sin twiddles to exact f64 bitPattern equality. The
// CRC gate is the early-warning if that ever ceases to hold.
//
// DETERMINISM: a call consumes a data-dependent number of RNG words
// (Gamma's rejection loop and the shape<1 reduction draw variable
// counts), but for a fixed (inputs, seed, starting RNG state) the word
// sequence — and therefore every sample — is reproducible. The RNG is
// threaded by `inout`, never copied, so the consumer observes the
// post-sample state and can chain draws deterministically (this is how
// the bandit draws one Beta per arm from a single seeded stream).
//
// Cookbook references:
//   §8.17  Sampling primitives (this file; section authorship pending)
//   §8.12  Bradley-Terry (adjacent learning math; the bandit's sibling)
//   §7.4   RandomWalks (owner of SplitMix64 + uniform01, reused here)

import Foundation
import SubstrateTypes

/// Deterministic continuous-distribution sampling primitives.
///
/// Stateless namespace: every entry point takes an `inout SplitMix64`
/// so the caller owns and threads the RNG state. No global RNG, no
/// `Date()`, no non-deterministic source — same seed, same starting
/// state ⇒ same sample sequence in both language ports.
public enum Sampling {

    /// Draw a standard Normal(0, 1) sample using the Box-Muller transform.
    ///
    /// Box-Muller: `z = sqrt(-2 · ln(u1)) · cos(2π · u2)`, with
    /// `u1, u2 ~ Uniform[0, 1)`. Returns the cosine branch (a single
    /// sample per call); the sine branch is intentionally discarded so
    /// the RNG consumption is a fixed two uniforms per call and the
    /// cross-port stream stays aligned (no hidden cached-sample state).
    ///
    /// `u1` is clamped up to `Double.leastNormalMagnitude` so `ln` is
    /// defined when the RNG yields exactly zero. The clamp is
    /// numerically invisible in practice (P[u1 == 0] ≈ 2⁻⁵³ from the
    /// uniform construction; the clamp value is far smaller still) and
    /// is applied identically in the Rust port (`f64::MIN_POSITIVE`).
    ///
    /// - Parameter rng: the caller's SplitMix64 state, threaded by reference.
    /// - Returns: one sample from Normal(0, 1).
    @inlinable
    public static func sampleNormal(rng: inout SplitMix64) -> Double {
        let u1 = max(RandomWalks.uniform01(&rng), Double.leastNormalMagnitude)
        let u2 = RandomWalks.uniform01(&rng)
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }

    /// Draw a sample from Gamma(shape, scale = 1) using Marsaglia-Tsang (2000).
    ///
    /// For `shape >= 1` the Marsaglia-Tsang squeeze-and-log rejection
    /// method is used: `d = shape - 1/3`, `c = 1/sqrt(9d)`; propose
    /// `x ~ N(0,1)`, `v = (1 + c·x)³` (requiring `v > 0`), accept on the
    /// squeeze test `u < 1 - 0.0331·x⁴` or the log test
    /// `ln(u) < 0.5·x² + d·(1 - v + ln(v))`. Expected iterations are
    /// O(1) — the squeeze test accepts most proposals without a log.
    ///
    /// For `shape < 1` the Ahrens-Dieter reduction is applied:
    /// `Gamma(α) = Gamma(α+1) · U^(1/α)`, so the main branch only ever
    /// handles `shape >= 1`. The reduction draws one extra uniform
    /// before the recursive Gamma(α+1) draw; the Rust port draws in the
    /// same order so the streams stay aligned.
    ///
    /// - Precondition: `shape > 0`. Shape ≤ 0 is undefined for the Gamma
    ///   distribution and indicates a caller error.
    /// - Parameters:
    ///   - shape: the Gamma shape parameter (k / α), must be > 0.
    ///   - rng: the caller's SplitMix64 state, threaded by reference.
    /// - Returns: one sample from Gamma(shape, 1).
    public static func sampleGamma(shape: Double, rng: inout SplitMix64) -> Double {
        precondition(shape > 0.0, "Gamma shape must be positive (got \(shape))")
        if shape < 1.0 {
            // Ahrens-Dieter reduction so the main branch only handles
            // shape >= 1. The uniform is drawn BEFORE the recursive
            // Gamma(shape+1) draw — Rust matches this order.
            let u = RandomWalks.uniform01(&rng)
            let base = sampleGamma(shape: shape + 1.0, rng: &rng)
            return base * pow(u, 1.0 / shape)
        }
        // Marsaglia-Tsang (2000): d = shape - 1/3, c = 1/sqrt(9d).
        let d = shape - 1.0 / 3.0
        let c = 1.0 / (9.0 * d).squareRoot()
        while true {
            var x: Double
            var v: Double
            // Rejection loop: x ~ N(0,1), v = (1 + cx)^3, require v > 0.
            repeat {
                x = sampleNormal(rng: &rng)
                v = 1.0 + c * x
            } while v <= 0.0
            v = v * v * v  // cube
            let u = RandomWalks.uniform01(&rng)
            let xSq = x * x
            // Squeeze test — avoids the log for the overwhelming majority
            // of proposals (Marsaglia-Tsang's constant 0.0331).
            if u < 1.0 - 0.0331 * (xSq * xSq) {
                return d * v
            }
            // Log acceptance test (exact boundary).
            if log(u) < 0.5 * xSq + d * (1.0 - v + log(v)) {
                return d * v
            }
            // Reject: loop back (rare path — expected constant iterations).
        }
    }

    /// Draw a sample from Beta(alpha, beta) using two Gamma samples.
    ///
    /// `Beta(α, β) = Gamma(α, 1) / (Gamma(α, 1) + Gamma(β, 1))`. The two
    /// Gamma draws share the threaded RNG, so the α draw consumes its
    /// words first, then the β draw — the Rust port draws in the same
    /// order.
    ///
    /// Returns 0.5 when both Gamma draws are zero (a degenerate sum that
    /// cannot occur for `alpha, beta >= 1`, but is handled so the
    /// function is total). For `alpha, beta > 0` the result lies in
    /// `[0, 1]`.
    ///
    /// - Precondition: `alpha > 0` and `beta > 0`.
    /// - Parameters:
    ///   - alpha: the first Beta shape parameter (α), must be > 0.
    ///   - beta: the second Beta shape parameter (β), must be > 0.
    ///   - rng: the caller's SplitMix64 state, threaded by reference.
    /// - Returns: one sample from Beta(α, β).
    public static func sampleBeta(alpha: Double, beta: Double, rng: inout SplitMix64) -> Double {
        precondition(alpha > 0.0, "Beta alpha must be positive (got \(alpha))")
        precondition(beta > 0.0, "Beta beta must be positive (got \(beta))")
        let g1 = sampleGamma(shape: alpha, rng: &rng)
        let g2 = sampleGamma(shape: beta, rng: &rng)
        let total = g1 + g2
        guard total > 0.0 else { return 0.5 }
        return g1 / total
    }
}

// MARK: - Properties
//
//   deterministic:   same (inputs, seed, starting RNG state) → same
//                    sample sequence, in both reference language ports.
//   normal-fixed-rng: sampleNormal consumes exactly two uniforms per
//                     call (cosine branch only; no cached sine sample).
//   gamma-support:   sampleGamma(shape>0) returns a value in [0, ∞).
//   beta-support:    sampleBeta(α>0, β>0) returns a value in [0, 1].
//   rng-threaded:    the RNG is inout, never copied — consumers chain
//                    draws (one Beta per bandit arm) off one stream.
//
// MARK: - Cookbook references
//   §8.17 (sampling), §8.12 (Bradley-Terry), §7.4 (RandomWalks)
