// HammingNNTopKTieBreakTests.swift
//
// Pins the deterministic tie-break convention for HammingNN.topK:
// equal-distance hits are ordered by rowID.uuidString ascending.
// See HammingNN.swift for the rationale and the heapLarger() helper
// that encodes this ordering in both the heap eviction and final sort.

import Foundation
import Testing
@testable import SubstrateKernel
import SubstrateTypes

@Suite("HammingNN tie-break by rowID ascending")
struct HammingNNTopKTieBreakTests {

    // Construct UUIDs whose string representation orders by last byte,
    // giving a predictable and verifiable string-ascending sequence.
    private func makeID(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    @Test("equal-distance hits return in rowID-ascending order")
    func equalDistanceTieBreakByRowID() {
        let anchor = Fingerprint256.zero
        // Five candidates all at distance 1, presented in descending ID
        // order so the heap must actively tie-break to produce the right
        // output — it cannot rely on insertion order.
        let candidates: [(UUID, Fingerprint256)] = [
            (makeID(5), Fingerprint256(block0: 0b10000, block1: 0, block2: 0, block3: 0)),
            (makeID(3), Fingerprint256(block0: 0b01000, block1: 0, block2: 0, block3: 0)),
            (makeID(1), Fingerprint256(block0: 0b00001, block1: 0, block2: 0, block3: 0)),
            (makeID(4), Fingerprint256(block0: 0b00100, block1: 0, block2: 0, block3: 0)),
            (makeID(2), Fingerprint256(block0: 0b00010, block1: 0, block2: 0, block3: 0)),
        ]
        let hits = HammingNN.topK(anchor: anchor, candidates: candidates, k: 3, blocks: .all)
        #expect(hits.count == 3)
        // All three at distance 1; ascending rowID order.
        #expect(hits[0].distance == 1); #expect(hits[0].rowID == makeID(1))
        #expect(hits[1].distance == 1); #expect(hits[1].rowID == makeID(2))
        #expect(hits[2].distance == 1); #expect(hits[2].rowID == makeID(3))
    }

    @Test("tie-break is deterministic across identical runs")
    func deterministic() {
        let anchor = Fingerprint256.zero
        let candidates: [(UUID, Fingerprint256)] = [
            (makeID(2), Fingerprint256(block0: 0b10, block1: 0, block2: 0, block3: 0)),
            (makeID(1), Fingerprint256(block0: 0b01, block1: 0, block2: 0, block3: 0)),
        ]
        let run1 = HammingNN.topK(anchor: anchor, candidates: candidates, k: 2, blocks: .all)
        let run2 = HammingNN.topK(anchor: anchor, candidates: candidates, k: 2, blocks: .all)
        #expect(run1[0].rowID == run2[0].rowID)
        #expect(run1[1].rowID == run2[1].rowID)
        // Lower ID wins the first slot.
        #expect(run1[0].rowID == makeID(1))
        #expect(run1[1].rowID == makeID(2))
    }

    @Test("primary sort is by distance; tie-break by rowID is secondary")
    func primarySortDistanceSecondaryRowID() {
        let anchor = Fingerprint256.zero
        let candidates: [(UUID, Fingerprint256)] = [
            (makeID(3), Fingerprint256(block0: 0b111, block1: 0, block2: 0, block3: 0)),  // dist 3
            (makeID(4), Fingerprint256(block0: 0b011, block1: 0, block2: 0, block3: 0)),  // dist 2
            (makeID(2), Fingerprint256(block0: 0b011, block1: 0, block2: 0, block3: 0)),  // dist 2
            (makeID(1), Fingerprint256(block0: 0b001, block1: 0, block2: 0, block3: 0)),  // dist 1
        ]
        let hits = HammingNN.topK(anchor: anchor, candidates: candidates, k: 3, blocks: .all)
        #expect(hits.count == 3)
        #expect(hits[0].rowID == makeID(1)); #expect(hits[0].distance == 1)
        // Among the two distance-2 candidates, lower rowID comes first.
        #expect(hits[1].rowID == makeID(2)); #expect(hits[1].distance == 2)
        #expect(hits[2].rowID == makeID(4)); #expect(hits[2].distance == 2)
    }
}
