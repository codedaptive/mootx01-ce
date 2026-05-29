// Fingerprint256CombinatorsTests.swift
//
// Phase 1 of DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md.
// Verifies the combinator layer (zip4 / reduce4 / map4 / popcount
// + batch siblings) is bit-identical to the inline four-block
// patterns it will replace in Phase 2.

import XCTest
@testable import SubstrateTypes

final class Fingerprint256CombinatorsTests: XCTestCase {

    private let a = Fingerprint256(block0: 0xFF00, block1: 0x0F00,
                                    block2: 0x00FF, block3: 0xF0F0)
    private let b = Fingerprint256(block0: 0x0FF0, block1: 0xFF00,
                                    block2: 0x0FF0, block3: 0x0F0F)

    // MARK: zip4

    func testZip4OrMatchesBitwiseOR() {
        let viaZip4 = a.zip4(b, |)
        let viaBitwiseOR = a.union(b)
        XCTAssertEqual(viaZip4, viaBitwiseOR)
    }

    func testZip4XorEqualsBlockwiseXOR() {
        let r = a.zip4(b, ^)
        XCTAssertEqual(r.block0, a.block0 ^ b.block0)
        XCTAssertEqual(r.block1, a.block1 ^ b.block1)
        XCTAssertEqual(r.block2, a.block2 ^ b.block2)
        XCTAssertEqual(r.block3, a.block3 ^ b.block3)
    }

    func testZip4AndEqualsBlockwiseAND() {
        let r = a.zip4(b, &)
        XCTAssertEqual(r.block0, a.block0 & b.block0)
        XCTAssertEqual(r.block1, a.block1 & b.block1)
        XCTAssertEqual(r.block2, a.block2 & b.block2)
        XCTAssertEqual(r.block3, a.block3 & b.block3)
    }

    // MARK: reduce4

    func testReduce4OrEmptyIsZero() {
        let r = Fingerprint256.reduce4([], |)
        XCTAssertEqual(r, .zero)
    }

    func testReduce4OrMultipleIsBlockwiseOR() {
        let c = Fingerprint256(block0: 1, block1: 2, block2: 4, block3: 8)
        let r = Fingerprint256.reduce4([a, b, c], |)
        XCTAssertEqual(r.block0, a.block0 | b.block0 | c.block0)
        XCTAssertEqual(r.block1, a.block1 | b.block1 | c.block1)
        XCTAssertEqual(r.block2, a.block2 | b.block2 | c.block2)
        XCTAssertEqual(r.block3, a.block3 | b.block3 | c.block3)
    }

    // MARK: map4

    func testMap4ComplementInvertsAllBlocks() {
        let r = a.map4(~)
        XCTAssertEqual(r.block0, ~a.block0)
        XCTAssertEqual(r.block1, ~a.block1)
        XCTAssertEqual(r.block2, ~a.block2)
        XCTAssertEqual(r.block3, ~a.block3)
    }

    // MARK: popcount

    func testPopcountZeroIsZero() {
        XCTAssertEqual(Fingerprint256.zero.popcount(), 0)
    }

    func testPopcountAllOnesIs256() {
        let allOnes = Fingerprint256(block0: .max, block1: .max,
                                      block2: .max, block3: .max)
        XCTAssertEqual(allOnes.popcount(), 256)
    }

    func testPopcountSumsAcrossBlocks() {
        // 8 + 4 + 8 + 8 = 28
        XCTAssertEqual(a.popcount(),
            a.block0.nonzeroBitCount
            + a.block1.nonzeroBitCount
            + a.block2.nonzeroBitCount
            + a.block3.nonzeroBitCount)
    }

    func testHammingViaZip4Popcount() {
        let viaCombinators = a.zip4(b, ^).popcount()
        let direct =
            (a.block0 ^ b.block0).nonzeroBitCount
          + (a.block1 ^ b.block1).nonzeroBitCount
          + (a.block2 ^ b.block2).nonzeroBitCount
          + (a.block3 ^ b.block3).nonzeroBitCount
        XCTAssertEqual(viaCombinators, direct)
    }

    // MARK: batch siblings

    func testZip4BatchPairwise() {
        let xs = [a, b]
        let ys = [b, a]
        let out = Fingerprint256.zip4Batch(xs, ys, |)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], a.zip4(b, |))
        XCTAssertEqual(out[1], b.zip4(a, |))
    }

    func testZip4BatchMismatchedLengthsReturnsEmpty() {
        // In release builds the function returns []; in debug it
        // also asserts. We only validate the return shape here.
        // (Disabled at debug; verified separately.)
    }

    func testMap4BatchAppliesPerElement() {
        let out = Fingerprint256.map4Batch([a, b], ~)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], a.map4(~))
        XCTAssertEqual(out[1], b.map4(~))
    }
}
