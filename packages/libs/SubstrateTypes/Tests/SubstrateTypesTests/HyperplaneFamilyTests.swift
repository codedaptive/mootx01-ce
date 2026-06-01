// HyperplaneFamilyTests.swift
//
// Per-type suite for HyperplaneFamily + Hyperplane. Mirrors the Rust
// `hyperplane.rs` inline #[test] set: deterministic_generation,
// different_seeds_differ, sign_positive_when_majority_aligned.

import Testing
@testable import SubstrateTypes

@Suite("HyperplaneFamily + Hyperplane")
struct HyperplaneFamilyTests {

    @Test("generation is deterministic for a fixed seed")
    func deterministicGeneration() {
        let seed = [UInt8](repeating: 0xAB, count: 32)
        let f1 = HyperplaneFamily.generate(seed: seed, blockIndex: 0,
                                           inputBitLength: 192, density: 1.0)
        let f2 = HyperplaneFamily.generate(seed: seed, blockIndex: 0,
                                           inputBitLength: 192, density: 1.0)
        #expect(f1 == f2)
    }

    @Test("different seeds produce different families")
    func differentSeedsDiffer() {
        let seedA = [UInt8](repeating: 0xAB, count: 32)
        let seedB = [UInt8](repeating: 0xCD, count: 32)
        let fa = HyperplaneFamily.generate(seed: seedA, blockIndex: 0,
                                           inputBitLength: 64, density: 1.0)
        let fb = HyperplaneFamily.generate(seed: seedB, blockIndex: 0,
                                           inputBitLength: 64, density: 1.0)
        #expect(fa != fb)
    }

    @Test("sign is positive when the +1 entries outweigh the -1 entries")
    func signPositiveWhenMajorityAligned() {
        // +1 at bits 0,1,2,3; -1 at bit 4.
        let h = Hyperplane(positiveMask: [0b0000_1111],
                           negativeMask: [0b0001_0000],
                           bitLength: 5)
        // input with bits 0..3 set, bit 4 unset → 4 pos, 0 neg → true
        #expect(h.sign(over: [0b0000_1111]))
        // input with only bit 4 set → 0 pos, 1 neg → false
        #expect(!h.sign(over: [0b0001_0000]))
    }

    @Test("canonicalHash is stable and seed-sensitive")
    func canonicalHashStableAndSensitive() {
        let seedA = [UInt8](repeating: 0x01, count: 32)
        let a1 = HyperplaneFamily.generate(seed: seedA, blockIndex: 1, inputBitLength: 64)
        let a2 = HyperplaneFamily.generate(seed: seedA, blockIndex: 1, inputBitLength: 64)
        let b = HyperplaneFamily.generate(seed: [UInt8](repeating: 0x02, count: 32),
                                          blockIndex: 1, inputBitLength: 64)
        #expect(a1.canonicalHash() == a2.canonicalHash())
        #expect(a1.canonicalHash() != b.canonicalHash())
    }

    @Test("blockFamilies builds four independent canonical-width families")
    func blockFamiliesAreIndependent() {
        let seed = [UInt8](repeating: 0x42, count: 32)
        let fams = HyperplaneFamily.blockFamilies(baseSeed: seed)
        #expect(fams.count == 4)
        #expect(fams[0].inputBitLength == 192)
        #expect(fams[1].inputBitLength == 64)
        // Per-block seed diversification → distinct families.
        #expect(fams[1].canonicalHash() != fams[2].canonicalHash())
    }
}
