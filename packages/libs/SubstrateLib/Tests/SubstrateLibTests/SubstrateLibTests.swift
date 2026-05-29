// SubstrateLibTests.swift
//
// Smoke tests for SubstrateLib's public surface. These tests
// confirm that the kit imports cleanly, that the canonical
// primitives are constructible, and that round-trip operations
// on the public types behave as documented.
//
// Mathematical correctness is verified by the conformance tests
// in Tests/SubstrateLibConformanceTests/, which exercise the
// kit against the bit-identical fixtures from Phase 2 closure.

import XCTest
@testable import SubstrateLib

final class SubstrateLibTests: XCTestCase {

    // MARK: - Fingerprint256

    func testFingerprintConstruction() {
        let fp = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x4)
        XCTAssertEqual(fp.block0, 0x1)
        XCTAssertEqual(fp.block1, 0x2)
        XCTAssertEqual(fp.block2, 0x3)
        XCTAssertEqual(fp.block3, 0x4)
    }

    func testFingerprintEquality() {
        let a = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x4)
        let b = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x4)
        let c = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - HLC

    func testHLCConstruction() {
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1)
        XCTAssertEqual(hlc.physicalTime, 1_000_000)
        XCTAssertEqual(hlc.logicalCount, 0)
        XCTAssertEqual(hlc.nodeID, 1)
    }

    func testHLCOrdering() {
        let earlier = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1)
        let later = HLC(physicalTime: 2_000_000, logicalCount: 0, nodeID: 1)
        XCTAssertLessThan(earlier, later)
    }

    // MARK: - RecallScore

    func testRecallScore() {
        let rowId = UUID()
        let score = RecallScore(rowId: rowId, score: 0.95)
        XCTAssertEqual(score.rowId, rowId)
        XCTAssertEqual(score.score, 0.95)
    }

    // MARK: - RecallResult

    func testRecallResultConstruction() {
        let rowId = UUID()
        let scores = [RecallScore(rowId: rowId, score: 0.9)]
        let result = RecallResult(rows: scores, primitiveName: "test_primitive")
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.primitiveName, "test_primitive")
        XCTAssertNil(result.confidenceInterval)
    }

    // MARK: - Hamming

    func testHammingDistanceIdentity() {
        let a = Fingerprint256(block0: 0xFFFF, block1: 0, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0xFFFF, block1: 0, block2: 0, block3: 0)
        XCTAssertEqual(Hamming.distance(a, b), 0)
    }

    func testHammingDistanceMaxDifference() {
        let zero = Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
        let allOnes = Fingerprint256(block0: .max, block1: .max, block2: .max, block3: .max)
        XCTAssertEqual(Hamming.distance(zero, allOnes), 256)
    }

    // MARK: - ORReduce

    func testORReduceIdentity() {
        let fp = Fingerprint256(block0: 0x1, block1: 0, block2: 0, block3: 0)
        let reduced = ORReduce.reduce([fp])
        XCTAssertEqual(reduced.block0, 0x1)
    }

    func testORReduceCommutative() {
        let a = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0x4, block1: 0x8, block2: 0, block3: 0)
        let ab = ORReduce.reduce([a, b])
        let ba = ORReduce.reduce([b, a])
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.block0, 0x5)
        XCTAssertEqual(ab.block1, 0xA)
    }
}
