// CountVector256Tests.swift
//
// Per-type suite for CountVector256, the lossless bundle-algebra fold.
// Mirrors the Rust `count_vector.rs` inline #[test] set:
//   accumulate_counts_set_bits, empty_vector_is_identity,
//   tree_fold_equals_direct_accumulation, merge_is_commutative_and_associative,
//   majority_vote_strict_threshold, profile_is_count_over_n.

import Testing
@testable import SubstrateTypes

@Suite("CountVector256 bundle fold")
struct CountVector256Tests {

    /// Deterministic fingerprint generator mirroring the Rust test's
    /// xorshift stream so the two legs fold the same inputs.
    private func fingerprints(seed: UInt64, count: Int) -> [Fingerprint256] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        return (0..<count).map { _ in
            Fingerprint256(block0: next(), block1: next(), block2: next(), block3: next())
        }
    }

    private func withBits(_ bits: [Int]) -> Fingerprint256 {
        var blocks = [UInt64](repeating: 0, count: 4)
        for b in bits { blocks[b / 64] |= UInt64(1) << (b % 64) }
        return Fingerprint256(block0: blocks[0], block1: blocks[1],
                              block2: blocks[2], block3: blocks[3])
    }

    @Test("accumulate raises the count of each set bit")
    func accumulateCountsSetBits() {
        var cv = CountVector256.zero
        cv.accumulate(withBits([0, 64, 255]))
        #expect(cv.n == 1)
        #expect(cv.counts[0] == 1)
        #expect(cv.counts[64] == 1)
        #expect(cv.counts[255] == 1)
        #expect(cv.counts[1] == 0)
        #expect(cv.counts.reduce(0, +) == 3)
    }

    @Test("the empty vector is the fold identity")
    func emptyVectorIsIdentity() {
        let empty = CountVector256.zero
        #expect(empty.n == 0)
        #expect(empty.majorityVote() == .zero)
        #expect(empty.profile() == [Float](repeating: 0, count: 256))
    }

    @Test("tree-fold equals direct accumulation (mergeability)")
    func treeFoldEqualsDirectAccumulation() {
        let all = fingerprints(seed: 42, count: 300)
        let direct = CountVector256.fold(all)
        let g1 = CountVector256.fold(Array(all[0..<137]))
        let g2 = CountVector256.fold(Array(all[137..<255]))
        let g3 = CountVector256.fold(Array(all[255..<300]))
        let merged = g1 + g2 + g3
        #expect(merged == direct)
        #expect(merged.n == 300)
    }

    @Test("merge is commutative and associative")
    func mergeIsCommutativeAndAssociative() {
        let a = CountVector256.fold(fingerprints(seed: 1, count: 50))
        let b = CountVector256.fold(fingerprints(seed: 2, count: 70))
        let c = CountVector256.fold(fingerprints(seed: 3, count: 90))
        #expect(a + b == b + a)
        #expect((a + b) + c == a + (b + c))
    }

    @Test("majorityVote uses a strict threshold (2·c > n)")
    func majorityVoteStrictThreshold() {
        // bit 0: 3 of 4 (majority → set); bit 1: 2 of 4 (tie → clear);
        // bit 2: 1 of 4 (minority → clear).
        let members = [
            withBits([0, 1, 2]),
            withBits([0, 1]),
            withBits([0]),
            withBits([]),
        ]
        let cv = CountVector256.fold(members)
        #expect(cv.n == 4)
        #expect(cv.counts[0] == 3)
        #expect(cv.counts[1] == 2)
        #expect(cv.counts[2] == 1)
        let mv = cv.majorityVote()
        #expect(mv.bit(at: 0))   // strict majority sets the bit
        #expect(!mv.bit(at: 1))  // exact tie does not set the bit
        #expect(!mv.bit(at: 2))  // minority does not set the bit
    }

    @Test("profile is count over n")
    func profileIsCountOverN() {
        let members = [
            withBits([10]),
            withBits([10]),
            withBits([10]),
            withBits([]),
            withBits([]),
        ]
        let p = CountVector256.fold(members).profile()
        #expect(abs(p[10] - 0.6) < 1e-6)
        #expect(abs(p[11] - 0.0) < 1e-6)
    }
}
