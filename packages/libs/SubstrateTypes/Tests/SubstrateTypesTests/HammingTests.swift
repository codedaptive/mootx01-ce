// HammingTests.swift
//
// Per-type suite for Hamming (distance + similarity over Fingerprint256).
// Mirrors the Rust `hamming.rs` inline #[test] set: zero_to_zero_is_zero,
// one_bit_difference, maximally_distant, block_restricted_distance,
// self_similarity_is_one.

import Testing
@testable import SubstrateTypes

@Suite("Hamming distance + similarity")
struct HammingTests {

    @Test("distance(zero, zero) is 0")
    func zeroToZeroIsZero() {
        #expect(Hamming.distance(.zero, .zero) == 0)
    }

    @Test("one differing bit is distance 1")
    func oneBitDifference() {
        let b = Fingerprint256(block0: 1, block1: 0, block2: 0, block3: 0)
        #expect(Hamming.distance(.zero, b) == 1)
    }

    @Test("all 256 bits differing is distance 256")
    func maximallyDistant() {
        let b = Fingerprint256(block0: .max, block1: .max, block2: .max, block3: .max)
        #expect(Hamming.distance(.zero, b) == 256)
    }

    @Test("block-restricted distance counts only selected blocks")
    func blockRestrictedDistance() {
        let b = Fingerprint256(block0: .max, block1: 0, block2: 0, block3: 0)
        #expect(Hamming.distance(.zero, b, blocks: .block0) == 64)
        #expect(Hamming.distance(.zero, b, blocks: .block1) == 0)
        #expect(Hamming.distance(.zero, b, blocks: [.block0, .block1]) == 64)
    }

    @Test("self-similarity is 1.0")
    func selfSimilarityIsOne() {
        let fp = Fingerprint256(block0: 0xCAFE, block1: 0xBABE,
                                block2: 0xDEAD, block3: 0xBEEF)
        #expect(Hamming.similarity(fp, fp) == 1.0)
    }

    @Test("similarity of maximally-distant fingerprints is 0.0")
    func maxDistanceSimilarityIsZero() {
        let b = Fingerprint256(block0: .max, block1: .max, block2: .max, block3: .max)
        #expect(Hamming.similarity(.zero, b) == 0.0)
    }

    @Test("HammingDistance alias resolves to Hamming")
    func aliasResolves() {
        let b = Fingerprint256(block0: 0b1011, block1: 0, block2: 0, block3: 0)
        #expect(HammingDistance.distance(.zero, b) == 3)
    }
}
