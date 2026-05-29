// FloatSimHashTests.swift

import XCTest
import SubstrateTypes
@testable import SubstrateML

final class FloatSimHashTests: XCTestCase {

    func testDeterministic() {
        let v: [Float] = (0..<384).map { Float($0) / 384.0 - 0.5 }
        let fp1 = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        let fp2 = FloatSimHash.project(vector: v, seed: 0xDEAD_BEEF)
        XCTAssertEqual(fp1, fp2, "same input + seed must produce same fingerprint")
    }

    func testSeedAffectsOutput() {
        let v: [Float] = (0..<384).map { Float($0) / 384.0 - 0.5 }
        let fp1 = FloatSimHash.project(vector: v, seed: 0x01)
        let fp2 = FloatSimHash.project(vector: v, seed: 0x02)
        XCTAssertNotEqual(fp1, fp2, "different seeds should produce different fingerprints")
    }

    func testEmptyVectorReturnsZero() {
        let fp = FloatSimHash.project(vector: [], seed: 0x42)
        XCTAssertEqual(fp, Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0))
    }

    func testSimilarVectorsClose() {
        // Two vectors that differ only slightly should produce
        // fingerprints with low Hamming distance.
        let base: [Float] = (0..<384).map { _ in Float.random(in: -1...1) }
        var perturbed = base
        for i in 0..<10 {
            perturbed[i] += 0.01
        }
        let fp1 = FloatSimHash.project(vector: base, seed: 0xCAFE)
        let fp2 = FloatSimHash.project(vector: perturbed, seed: 0xCAFE)

        // Hamming distance over 256 bits.
        let d0 = (fp1.block0 ^ fp2.block0).nonzeroBitCount
        let d1 = (fp1.block1 ^ fp2.block1).nonzeroBitCount
        let d2 = (fp1.block2 ^ fp2.block2).nonzeroBitCount
        let d3 = (fp1.block3 ^ fp2.block3).nonzeroBitCount
        let total = d0 + d1 + d2 + d3

        // Random fingerprints differ on ~128 bits on average. A
        // small perturbation should leave most bits unchanged.
        XCTAssertLessThan(total, 32, "small perturbation should preserve most bits; got \(total)")
    }

    func testOrthogonalVectorsFarApart() {
        // Two random vectors with no shared structure should differ
        // on roughly half the bits (~128 of 256). Allow a wide band
        // for statistical variation.
        let v1: [Float] = (0..<384).map { _ in Float.random(in: -1...1) }
        let v2: [Float] = (0..<384).map { _ in Float.random(in: -1...1) }
        let fp1 = FloatSimHash.project(vector: v1, seed: 0xABCD)
        let fp2 = FloatSimHash.project(vector: v2, seed: 0xABCD)

        let d = (fp1.block0 ^ fp2.block0).nonzeroBitCount
            + (fp1.block1 ^ fp2.block1).nonzeroBitCount
            + (fp1.block2 ^ fp2.block2).nonzeroBitCount
            + (fp1.block3 ^ fp2.block3).nonzeroBitCount
        XCTAssertGreaterThan(d, 80, "random vectors should have meaningful Hamming separation; got \(d)")
        XCTAssertLessThan(d, 180, "random vectors shouldn't be near-inverse; got \(d)")
    }
}
