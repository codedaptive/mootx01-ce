// PartialStateRecallTests.swift
//
// Partial-state recall per cookbook § 8.8. swift-testing peer suite
// for Sources/SubstrateML/PartialStateRecall.swift, mirroring
// rust/src/partial_state_recall.rs (7 #[test]) case-for-case with the
// Rust 1e-12 tolerance. Rust's RowId(n) maps to fixed UUIDs.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("PartialStateRecall")
struct PartialStateRecallTests {

    private func fp(_ b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64) -> Fingerprint256 {
        Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }
    private func rid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    @Test("a row identical to the anchor scores zero (fails the differ constraint)")
    func identicalScoresZero() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC)
        let s = PartialStateRecall.score(rowFingerprint: anchor, anchor: anchor,
                                         matchBlocks: [0, 1], differBlocks: [2, 3])
        #expect(s == 0.0)
    }

    @Test("a fully-inverted row scores zero (fails the match constraint)")
    func complementScoresZero() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC)
        let inverse = fp(~0xFF, ~0xAA, ~0xBB, ~0xCC)
        let s = PartialStateRecall.score(rowFingerprint: inverse, anchor: anchor,
                                         matchBlocks: [0, 1], differBlocks: [2, 3])
        #expect(s == 0.0)
    }

    @Test("matching the match-blocks and differing maximally on differ-blocks scores 1.0")
    func idealPartialMatch() {
        let anchor = fp(0xFF, 0xAA, 0x00, 0x00)
        let row = fp(0xFF, 0xAA, ~0, ~0)
        let s = PartialStateRecall.score(rowFingerprint: row, anchor: anchor,
                                         matchBlocks: [0, 1], differBlocks: [2, 3])
        // match_d = 0, differ_d = 128 ⇒ match_score=1, differ_score=1 ⇒ product=1.
        #expect(abs(s - 1.0) < tol)
    }

    @Test("an empty match-block set yields zero")
    func emptyMatchBlocksZero() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC)
        let row = fp(0, 0, 0, 0)
        let s = PartialStateRecall.score(rowFingerprint: row, anchor: anchor,
                                         matchBlocks: [], differBlocks: [0, 1, 2, 3])
        #expect(s == 0.0)
    }

    @Test("an empty differ-block set yields zero")
    func emptyDifferBlocksZero() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC)
        let row = fp(0, 0, 0, 0)
        let s = PartialStateRecall.score(rowFingerprint: row, anchor: anchor,
                                         matchBlocks: [0, 1, 2, 3], differBlocks: [])
        #expect(s == 0.0)
    }

    @Test("topK orders results by descending score")
    func topKOrdersDescending() {
        let anchor = fp(0xFF, 0xAA, 0x00, 0x00)
        let rows: [(rowId: UUID, fingerprint: Fingerprint256)] = [
            (rid(1), fp(0xFF, 0xAA, ~0, ~0)),  // ideal: score 1.0
            (rid(2), fp(0xFF, 0xAA, 0xFF, 0xFF)),
            (rid(3), fp(0x00, 0x00, ~0, ~0)),  // perfect differ but no match ⇒ 0
        ]
        let result = PartialStateRecall.topK(anchor: anchor, rows: rows,
                                             matchBlocks: [0, 1], differBlocks: [2, 3], k: 3)
        #expect(result[0].rowId == rid(1))
        #expect(result[0].score > result[1].score)
    }

    @Test("topK respects k")
    func topKRespectsK() {
        let anchor = fp(0, 0, 0, 0)
        let rows: [(rowId: UUID, fingerprint: Fingerprint256)] =
            (0..<10).map { (rid(UInt8($0)), fp(UInt64($0), 0, ~0, ~0)) }
        let result = PartialStateRecall.topK(anchor: anchor, rows: rows,
                                             matchBlocks: [0, 1], differBlocks: [2, 3], k: 3)
        #expect(result.count == 3)
    }

    private let tol = 1e-12
}
