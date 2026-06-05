// PartialStateRecallValidationTests.swift
//
// Input-validation guards added by MX-Tidy (2026-06-05):
//   - Block IDs must be in {0, 1, 2, 3}. An out-of-domain ID
//     corrupts the denominator (counted) while not contributing to
//     the Hamming distance (ignored), producing silently wrong scores.
//     Both score() and topK() assert via precondition.
//   - k in topK() must be non-negative (precondition, matching
//     HammingNN.topK's k > 0 style).
//
// Note: precondition failures terminate the process and cannot be
// tested directly in Swift Testing. This suite tests:
//   (a) Valid inputs produce correct results — regression against
//       the existing test suite behavior.
//   (b) Edge cases (empty blocks, k=0) that use the guard path
//       without triggering a precondition.
// The block-ID and k preconditions are verified by code inspection
// and documented in the PartialStateRecall.swift header.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("PartialStateRecall input validation")
struct PartialStateRecallValidationTests {

    private func fp(_ b0: UInt64, _ b1: UInt64, _ b2: UInt64, _ b3: UInt64) -> Fingerprint256 {
        Fingerprint256(block0: b0, block1: b1, block2: b2, block3: b3)
    }
    private func rid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    // MARK: - Valid inputs: existing behavior unchanged

    @Test("valid block IDs {0,1} and {2,3} produce correct score")
    func validBlockIDsProduceCorrectScore() {
        let anchor = fp(0xFF, 0xAA, 0x00, 0x00)
        let row = fp(0xFF, 0xAA, ~0, ~0)
        // match on blocks 0+1 (identical), differ on blocks 2+3 (maximal)
        let s = PartialStateRecall.score(rowFingerprint: row, anchor: anchor,
                                         matchBlocks: [0, 1], differBlocks: [2, 3])
        #expect(abs(s - 1.0) < 1e-12)
    }

    @Test("all four valid block IDs {0,1,2,3} are accepted")
    func allFourValidBlockIDsAccepted() {
        let anchor = fp(0xFF, 0xAA, 0xBB, 0xCC)
        let row = fp(0xFF, 0xAA, 0xBB, 0xCC)
        // Identical row: differ_score = 0, so product = 0.
        let s = PartialStateRecall.score(rowFingerprint: row, anchor: anchor,
                                         matchBlocks: [0, 1], differBlocks: [2, 3])
        #expect(s == 0.0)
    }

    @Test("topK with k=0 returns empty without precondition failure")
    func topKWithKZeroReturnsEmpty() {
        let anchor = fp(0, 0, 0, 0)
        let rows: [(rowId: UUID, fingerprint: Fingerprint256)] = [
            (rid(1), fp(0xFF, 0, 0, 0)),
        ]
        let result = PartialStateRecall.topK(anchor: anchor, rows: rows,
                                              matchBlocks: [0, 1], differBlocks: [2, 3], k: 0)
        #expect(result.isEmpty)
    }

    @Test("topK with k=1 returns the best row from a valid set")
    func topKWithKOneReturnsBestRow() {
        let anchor = fp(0xFF, 0xAA, 0x00, 0x00)
        let rows: [(rowId: UUID, fingerprint: Fingerprint256)] = [
            (rid(1), fp(0xFF, 0xAA, ~0, ~0)),  // ideal: score 1.0
            (rid(2), fp(0x00, 0x00, ~0, ~0)),  // match fails: score 0.0
        ]
        let result = PartialStateRecall.topK(anchor: anchor, rows: rows,
                                              matchBlocks: [0, 1], differBlocks: [2, 3], k: 1)
        #expect(result.count == 1)
        #expect(result[0].rowId == rid(1))
        #expect(abs(result[0].score - 1.0) < 1e-12)
    }

    @Test("single-block score uses only that block's 64 bits in denominator")
    func singleBlockScore() {
        // match on block 0 only: match_total_bits = 64
        // differ on block 1 only: differ_total_bits = 64
        let anchor = fp(0, 0, 0, 0)
        let row = fp(0, ~0, 0, 0)  // identical on block 0, all-1 on block 1
        let s = PartialStateRecall.score(rowFingerprint: row, anchor: anchor,
                                         matchBlocks: [0], differBlocks: [1])
        // match_d = 0, differ_d = 64 -> match_score = 1, differ_score = 1, product = 1.
        #expect(abs(s - 1.0) < 1e-12)
    }
}
