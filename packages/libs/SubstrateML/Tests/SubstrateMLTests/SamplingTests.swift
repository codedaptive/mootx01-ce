// SamplingTests.swift
//
// Sampling primitives per cookbook §8.17. swift-testing peer suite for
// Sources/SubstrateML/Sampling.swift, mirroring rust/src/sampling.rs
// (the #[test] set there). Both suites use the canonical conformance
// seed 0xCAFEBABEDEADBEEF and assert exact-bit determinism plus the
// distributional moments (Normal mean ≈ 0, Gamma mean ≈ shape, Beta
// mean ≈ α/(α+β)). Cross-port bit-identity is gated separately by the
// `sampling` conformance vector.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("Sampling")
struct SamplingTests {

    /// The canonical conformance seed (matches sampling.json + Rust).
    static let seed: UInt64 = 0xCAFE_BABE_DEAD_BEEF

    // MARK: - Normal (Box-Muller)

    @Test("sampleNormal consumes exactly two uniforms")
    func normalConsumesTwoUniforms() {
        // Advancing through one sampleNormal must leave the RNG in the
        // same state as two uniform01 draws — the fixed-consumption
        // property that keeps the cross-port stream aligned.
        var a = SplitMix64(seed: Self.seed)
        _ = Sampling.sampleNormal(rng: &a)

        var b = SplitMix64(seed: Self.seed)
        _ = RandomWalks.uniform01(&b)
        _ = RandomWalks.uniform01(&b)

        #expect(a.state == b.state)
    }

    @Test("sampleNormal is deterministic for a fixed seed")
    func normalDeterministic() {
        var a = SplitMix64(seed: Self.seed)
        var b = SplitMix64(seed: Self.seed)
        for _ in 0..<1000 {
            #expect(Sampling.sampleNormal(rng: &a).bitPattern
                    == Sampling.sampleNormal(rng: &b).bitPattern)
        }
    }

    @Test("sampleNormal mean is near zero")
    func normalMeanNearZero() {
        var rng = SplitMix64(seed: Self.seed)
        let n = 100_000
        var sum = 0.0
        for _ in 0..<n { sum += Sampling.sampleNormal(rng: &rng) }
        let mean = sum / Double(n)
        // SE ≈ 1/sqrt(n) ≈ 0.003; 0.05 is a generous band.
        #expect(abs(mean) < 0.05)
    }

    // MARK: - Gamma (Marsaglia-Tsang)

    @Test("sampleGamma is deterministic across shapes")
    func gammaDeterministic() {
        for shape in [0.3, 0.5, 1.0, 2.0, 5.5, 50.0] {
            var a = SplitMix64(seed: Self.seed)
            var b = SplitMix64(seed: Self.seed)
            for _ in 0..<200 {
                #expect(Sampling.sampleGamma(shape: shape, rng: &a).bitPattern
                        == Sampling.sampleGamma(shape: shape, rng: &b).bitPattern)
            }
        }
    }

    @Test("sampleGamma is non-negative and finite")
    func gammaNonNegative() {
        var rng = SplitMix64(seed: Self.seed)
        for shape in [0.1, 0.5, 1.0, 3.0, 20.0] {
            for _ in 0..<1000 {
                let g = Sampling.sampleGamma(shape: shape, rng: &rng)
                #expect(g >= 0.0)
                #expect(g.isFinite)
            }
        }
    }

    @Test("sampleGamma mean is near shape")
    func gammaMeanNearShape() {
        // E[Gamma(shape, 1)] = shape.
        for shape in [0.5, 1.0, 2.0, 5.0] {
            var rng = SplitMix64(seed: Self.seed ^ shape.bitPattern)
            let n = 50_000
            var sum = 0.0
            for _ in 0..<n { sum += Sampling.sampleGamma(shape: shape, rng: &rng) }
            let mean = sum / Double(n)
            #expect(abs(mean - shape) < 0.05 * shape + 0.02)
        }
    }

    // MARK: - Beta (Gamma ratio)

    @Test("sampleBeta is deterministic for a fixed seed")
    func betaDeterministic() {
        var a = SplitMix64(seed: Self.seed)
        var b = SplitMix64(seed: Self.seed)
        for _ in 0..<500 {
            #expect(Sampling.sampleBeta(alpha: 2.0, beta: 3.0, rng: &a).bitPattern
                    == Sampling.sampleBeta(alpha: 2.0, beta: 3.0, rng: &b).bitPattern)
        }
    }

    @Test("sampleBeta lies in the unit interval")
    func betaInUnitInterval() {
        var rng = SplitMix64(seed: Self.seed)
        for (a, b) in [(1.0, 1.0), (2.0, 5.0), (0.5, 0.5), (10.0, 1.0)] {
            for _ in 0..<1000 {
                let x = Sampling.sampleBeta(alpha: a, beta: b, rng: &rng)
                #expect(x >= 0.0 && x <= 1.0)
            }
        }
    }

    @Test("sampleBeta mean matches α/(α+β)")
    func betaMeanNearAnalytic() {
        // E[Beta(α, β)] = α / (α + β).
        for (a, b) in [(2.0, 3.0), (1.0, 1.0), (5.0, 2.0)] {
            var rng = SplitMix64(seed: Self.seed ^ (UInt64(a) << 8 | UInt64(b)))
            let n = 50_000
            var sum = 0.0
            for _ in 0..<n { sum += Sampling.sampleBeta(alpha: a, beta: b, rng: &rng) }
            let mean = sum / Double(n)
            let expected = a / (a + b)
            #expect(abs(mean - expected) < 0.02)
        }
    }
}
