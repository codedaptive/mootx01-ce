// FloatSimHashTests.swift
//
// FloatSimHash random-hyperplane projection per cookbook § 8.6.
// swift-testing peer suite for Sources/SubstrateML/FloatSimHash.swift,
// mirroring rust/src/float_simhash.rs (5 #[test]). Converted from
// the original XCTest suite; the two similarity tests now use the
// same deterministic input vectors as the Rust mirror (no unseeded
// RNG) so results are reproducible and comparable across legs.

import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("FloatSimHash projection")
struct FloatSimHashTests {

    /// Hamming distance over the 256 bits, mirroring the Rust
    /// `hamming` test helper.
    private func hamming(_ a: Fingerprint256, _ b: Fingerprint256) -> Int {
        (a.block0 ^ b.block0).nonzeroBitCount
            + (a.block1 ^ b.block1).nonzeroBitCount
            + (a.block2 ^ b.block2).nonzeroBitCount
            + (a.block3 ^ b.block3).nonzeroBitCount
    }

    @Test("same input + seed produces the same fingerprint")
    func deterministic() {
        let v: [Float] = (0..<384).map { Float($0) / 384.0 - 0.5 }
        let fp1 = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        let fp2 = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        #expect(fp1 == fp2, "same input + seed must produce same fingerprint")
    }

    @Test("different seeds produce different fingerprints")
    func seedAffectsOutput() {
        let v: [Float] = (0..<384).map { Float($0) / 384.0 - 0.5 }
        let fp1 = FloatSimHash.project(vector: v, seed: 0x01)
        let fp2 = FloatSimHash.project(vector: v, seed: 0x02)
        #expect(fp1 != fp2, "different seeds should produce different fingerprints")
    }

    @Test("empty vector returns the zero fingerprint")
    func emptyVectorReturnsZero() {
        let fp = FloatSimHash.project(vector: [], seed: 0x42)
        #expect(fp == Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0))
    }

    @Test("a small perturbation preserves most bits")
    func similarVectorsClose() {
        // Fixed deterministic inputs (mirrors the Rust test): two
        // vectors that differ only slightly should produce
        // fingerprints with low Hamming distance.
        let base: [Float] = (0..<384).map { Float(($0 * 17 + 3) % 200) / 100.0 - 1.0 }
        var perturbed = base
        for i in 0..<10 { perturbed[i] += 0.01 }
        let fp1 = FloatSimHash.project(vector: base, seed: 0xCAFE)
        let fp2 = FloatSimHash.project(vector: perturbed, seed: 0xCAFE)
        let d = hamming(fp1, fp2)
        #expect(d < 32, "small perturbation should preserve most bits; got \(d)")
    }

    @Test("unrelated vectors have meaningful Hamming separation")
    func orthogonalVectorsFarApart() {
        // Two deterministically-generated different vectors should
        // differ on roughly half the bits (~128 of 256).
        let v1: [Float] = (0..<384).map { Float(($0 * 13 + 7) % 200) / 100.0 - 1.0 }
        let v2: [Float] = (0..<384).map { Float(($0 * 29 + 11) % 200) / 100.0 - 1.0 }
        let fp1 = FloatSimHash.project(vector: v1, seed: 0xABCD)
        let fp2 = FloatSimHash.project(vector: v2, seed: 0xABCD)
        let d = hamming(fp1, fp2)
        #expect(d > 80, "unrelated vectors should have meaningful Hamming separation; got \(d)")
        #expect(d < 180, "unrelated vectors shouldn't be near-inverse; got \(d)")
    }
}
