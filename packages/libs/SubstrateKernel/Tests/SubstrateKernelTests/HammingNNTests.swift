// HammingNNTests.swift
//
// Swift library-test peer suite for `HammingNN` (HammingNN.swift).
// Mirrors the behavior set asserted by the Rust `hamming_nn.rs`
// `#[test]` module (2 tests): the top-1 self-match and the
// sorted-ascending top-K contract over a candidate list.
//
// API shape difference from the Rust leg (intentional, per the kit's
// Swift design): Swift `HammingNN.topK` keys candidates by `UUID`
// (`HammingNNHit.rowID: UUID`), where the Rust port uses a `u128`
// row_id. The behaviors asserted are identical; only the identifier
// type differs.

import Foundation
import Testing
@testable import SubstrateKernel
import SubstrateTypes

@Suite("HammingNN")
struct HammingNNTests {

    @Test("top-1 finds the exact self-match at distance 0")
    func topOneFindsSelf() {
        let anchor = Fingerprint256(block0: 0xCAFE, block1: 0xBABE, block2: 0xDEAD, block3: 0xBEEF)
        let idSelf = UUID()
        let idOther = UUID()
        let candidates: [(UUID, Fingerprint256)] = [
            (idSelf, anchor),
            (idOther, Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)),
        ]
        let hits = HammingNN.topK(anchor: anchor, candidates: candidates, k: 1, blocks: .all)
        #expect(hits.count == 1)
        #expect(hits[0].rowID == idSelf)
        #expect(hits[0].distance == 0)
    }

    @Test("top-K returns hits sorted by ascending distance")
    func topKReturnsSortedAscending() {
        let anchor = Fingerprint256.zero
        let candidates: [(UUID, Fingerprint256)] = [
            (UUID(), Fingerprint256(block0: 0xFF, block1: 0, block2: 0, block3: 0)),    // dist 8
            (UUID(), Fingerprint256(block0: 0x1, block1: 0, block2: 0, block3: 0)),     // dist 1
            (UUID(), Fingerprint256(block0: 0x7, block1: 0, block2: 0, block3: 0)),     // dist 3
            (UUID(), Fingerprint256(block0: 0xFFFF, block1: 0, block2: 0, block3: 0)),  // dist 16
        ]
        let hits = HammingNN.topK(anchor: anchor, candidates: candidates, k: 3, blocks: .all)
        #expect(hits.count == 3)
        #expect(hits[0].distance == 1)
        #expect(hits[1].distance == 3)
        #expect(hits[2].distance == 8)
    }
}
