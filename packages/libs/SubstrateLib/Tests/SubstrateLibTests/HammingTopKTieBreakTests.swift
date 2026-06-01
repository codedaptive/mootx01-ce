// HammingTopKTieBreakTests.swift
//
// Phase 3.2 spec-pinned tie-check test
// (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.3.2).
//
// The Phase 3.2 algorithm change (full-sort → heap-based) is
// required to preserve the row-index ascending tie-break. This
// test pins that behavior so future algorithm tweaks can't drift.

import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

@Suite("Hamming top-K tie-break by index ascending")
struct HammingTopKTieBreakTests {

    private let kernel = ScalarKernel()

    // Construct N candidates such that several share the same
    // Hamming distance to the probe. Verify the result orders
    // tied candidates by index ascending.

    @Test func testTiesBreakByIndexAscending() {
        let probe = Fingerprint256.zero
        let candidates: [Fingerprint256] = [
            // index 0: distance 1
            Fingerprint256(block0: 0b0001, block1: 0, block2: 0, block3: 0),
            // index 1: distance 2 (tied with 4, 7)
            Fingerprint256(block0: 0b0011, block1: 0, block2: 0, block3: 0),
            // index 2: distance 3
            Fingerprint256(block0: 0b0111, block1: 0, block2: 0, block3: 0),
            // index 3: distance 1 (tied with 0)
            Fingerprint256(block0: 0, block1: 0b0001, block2: 0, block3: 0),
            // index 4: distance 2 (tied with 1, 7)
            Fingerprint256(block0: 0, block1: 0b0011, block2: 0, block3: 0),
            // index 5: distance 4
            Fingerprint256(block0: 0b1111, block1: 0, block2: 0, block3: 0),
            // index 6: distance 1 (tied with 0, 3)
            Fingerprint256(block0: 0, block1: 0, block2: 0b0001, block3: 0),
            // index 7: distance 2 (tied with 1, 4)
            Fingerprint256(block0: 0, block1: 0, block2: 0b0011, block3: 0),
        ]

        // Top-5: should be three distance-1 candidates by index
        // ascending (0, 3, 6) then two of the three distance-2
        // candidates by index ascending (1, 4). Index 7 falls off.
        let top = kernel.hammingTopK(probe: probe, candidates: candidates, k: 5)

        #expect(top.count == 5)
        #expect(top[0].index == 0); #expect(top[0].distance == 1)
        #expect(top[1].index == 3); #expect(top[1].distance == 1)
        #expect(top[2].index == 6); #expect(top[2].distance == 1)
        #expect(top[3].index == 1); #expect(top[3].distance == 2)
        #expect(top[4].index == 4); #expect(top[4].distance == 2)
    }

    @Test func testTopKEqualsFullSortPrefix() {
        // For any random input, the heap-based result MUST equal
        // the deterministic full-sort + prefix result.
        var rng = SystemRandomNumberGenerator()
        let candidates: [Fingerprint256] = (0..<200).map { _ in
            Fingerprint256(
                block0: UInt64.random(in: 0...UInt64.max, using: &rng),
                block1: UInt64.random(in: 0...UInt64.max, using: &rng),
                block2: UInt64.random(in: 0...UInt64.max, using: &rng),
                block3: UInt64.random(in: 0...UInt64.max, using: &rng)
            )
        }
        let probe = Fingerprint256(block0: 0x123, block1: 0x456,
                                    block2: 0x789, block3: 0xABC)

        let viaHeap = kernel.hammingTopK(probe: probe, candidates: candidates, k: 13)

        // Reference: full sort by (distance, index) ascending,
        // prefix-13. Equivalent to the prior Phase 2 algorithm.
        let scored = candidates.enumerated().map {
            (index: $0, distance: kernel.hammingDistance256(probe, $1))
        }
        let viaFullSort = scored.sorted { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.index < rhs.index
        }.prefix(13).map { (index: $0.index, distance: $0.distance) }

        #expect(viaHeap.count == viaFullSort.count)
        for i in 0..<viaHeap.count {
            #expect(viaHeap[i].index == viaFullSort[i].index,
                "mismatch at position \(i) — heap diverged from full sort")
            #expect(viaHeap[i].distance == viaFullSort[i].distance)
        }
    }

    @Test func testKZeroReturnsEmpty() {
        let probe = Fingerprint256.zero
        let candidates = [
            Fingerprint256(block0: 1, block1: 2, block2: 3, block3: 4)
        ]
        let top = kernel.hammingTopK(probe: probe, candidates: candidates, k: 0)
        #expect(top.isEmpty)
    }

    @Test func testKLargerThanCandidatesReturnsAll() {
        let probe = Fingerprint256.zero
        let candidates: [Fingerprint256] = [
            Fingerprint256(block0: 1, block1: 0, block2: 0, block3: 0),
            Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 1),
        ]
        let top = kernel.hammingTopK(probe: probe, candidates: candidates, k: 10)
        #expect(top.count == 2)
    }
}
