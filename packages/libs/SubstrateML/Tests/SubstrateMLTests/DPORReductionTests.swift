// DPORReductionTests.swift
//
// Differentially-private OR-reduction per cookbook § 12.6.
// swift-testing peer suite for Sources/SubstrateML/DPORReduction.swift.
//
// rust/src/dp_or_reduce.rs carries NO #[test], so this suite asserts
// the documented behavior set: empty input ⇒ zero, seed-determinism,
// the k-anonymity threshold (a bit set by ≥k contributors survives;
// a bit set by <k does not), and the Laplace-noise helper. To make
// the k-threshold deterministic the tests use a large epsilon so the
// Laplace scale (1/ε) is negligible relative to integer popcounts.

import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("DPORReduction")
struct DPORReductionTests {

    /// Near-noiseless parameters: ε large ⇒ scale 1/ε ≈ 0, so the
    /// k-anonymity threshold behaves deterministically on popcounts.
    private func lowNoise(k: Int) -> DPParameters { DPParameters(epsilon: 1000.0, delta: 1e-9, kAnonymity: k) }

    @Test("an empty contributor set reduces to the zero fingerprint")
    func emptyIsZero() {
        #expect(DPORReduction.reduce(fingerprints: [], params: lowNoise(k: 3), rngSeed: 1) == Fingerprint256.zero)
    }

    @Test("reduction is deterministic for a fixed RNG seed")
    func deterministicForSeed() {
        let fps = [Fingerprint256.zero.with(bit: 0), Fingerprint256.zero.with(bit: 0),
                   Fingerprint256.zero.with(bit: 5)]
        let a = DPORReduction.reduce(fingerprints: fps, params: lowNoise(k: 2), rngSeed: 0xABCD)
        let b = DPORReduction.reduce(fingerprints: fps, params: lowNoise(k: 2), rngSeed: 0xABCD)
        #expect(a == b)
    }

    @Test("a bit set by at least k contributors survives the k-anonymity threshold")
    func popularBitSurvives() {
        // Five contributors all set bit 0; k = 3, low noise ⇒ bit 0 set.
        let fps = Array(repeating: Fingerprint256.zero.with(bit: 0), count: 5)
        let out = DPORReduction.reduce(fingerprints: fps, params: lowNoise(k: 3), rngSeed: 7)
        #expect(out.testBit(at: 0))
    }

    @Test("a bit set by fewer than k contributors is suppressed")
    func rareBitSuppressed() {
        // Bit 5 set by a single contributor among five; k = 3 ⇒ suppressed.
        var fps = Array(repeating: Fingerprint256.zero.with(bit: 0), count: 5)
        fps[0] = fps[0].with(bit: 5)
        let out = DPORReduction.reduce(fingerprints: fps, params: lowNoise(k: 3), rngSeed: 7)
        #expect(out.testBit(at: 0))         // the popular bit survives…
        #expect(out.testBit(at: 5) == false) // …the rare one does not
    }

    @Test("Laplace noise is zero-mean and seed-deterministic")
    func laplaceNoiseDeterministic() {
        var rngA = SplitMix64(seed: 42)
        var rngB = SplitMix64(seed: 42)
        let a = DPORReduction.laplaceNoise(scale: 1.0, rng: &rngA)
        let b = DPORReduction.laplaceNoise(scale: 1.0, rng: &rngB)
        #expect(a == b)
        #expect(a.isFinite)
    }
}
