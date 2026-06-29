// SubstrateLibTests.swift
//
// Smoke tests for SubstrateLib's public surface. These tests
// confirm that the kit imports cleanly, that the canonical
// primitives are constructible, and that round-trip operations
// on the public types behave as documented.
//
// Deeper verification is in Tests/SubstrateLibConformanceTests/,
// which gates cookbook §2.8 verification-table constants and
// cross-port wire-format parity.

import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes
import Foundation

@Suite("SubstrateLib public-surface smoke tests")
struct SubstrateLibTests {

    // MARK: - Fingerprint256

    @Test func testFingerprintConstruction() {
        let fp = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x4)
        #expect(fp.block0 == 0x1)
        #expect(fp.block1 == 0x2)
        #expect(fp.block2 == 0x3)
        #expect(fp.block3 == 0x4)
    }

    @Test func testFingerprintEquality() {
        let a = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x4)
        let b = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x4)
        let c = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0x3, block3: 0x5)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - HLC

    @Test func testHLCConstruction() {
        let hlc = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1)
        #expect(hlc.physicalTime == 1_000_000)
        #expect(hlc.logicalCount == 0)
        #expect(hlc.nodeID == 1)
    }

    @Test func testHLCOrdering() {
        let earlier = HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1)
        let later = HLC(physicalTime: 2_000_000, logicalCount: 0, nodeID: 1)
        #expect(earlier < later)
    }

    // MARK: - RecallScore

    @Test func testRecallScore() {
        let rowId = UUID()
        let score = RecallScore(rowId: rowId, score: 0.95)
        #expect(score.rowId == rowId)
        #expect(score.score == 0.95)
    }

    // MARK: - RecallResult

    @Test func testRecallResultConstruction() {
        let rowId = UUID()
        let scores = [RecallScore(rowId: rowId, score: 0.9)]
        let result = RecallResult(rows: scores, primitiveName: "test_primitive")
        #expect(result.rows.count == 1)
        #expect(result.primitiveName == "test_primitive")
        #expect(result.confidenceInterval == nil)
    }

    // MARK: - Hamming

    @Test func testHammingDistanceIdentity() {
        let a = Fingerprint256(block0: 0xFFFF, block1: 0, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0xFFFF, block1: 0, block2: 0, block3: 0)
        #expect(Hamming.distance(a, b) == 0)
    }

    @Test func testHammingDistanceMaxDifference() {
        let zero = Fingerprint256(block0: 0, block1: 0, block2: 0, block3: 0)
        let allOnes = Fingerprint256(block0: .max, block1: .max, block2: .max, block3: .max)
        #expect(Hamming.distance(zero, allOnes) == 256)
    }

    // MARK: - ORReduce

    @Test func testORReduceIdentity() {
        let fp = Fingerprint256(block0: 0x1, block1: 0, block2: 0, block3: 0)
        let reduced = ORReduce.reduce([fp])
        #expect(reduced.block0 == 0x1)
    }

    @Test func testORReduceCommutative() {
        let a = Fingerprint256(block0: 0x1, block1: 0x2, block2: 0, block3: 0)
        let b = Fingerprint256(block0: 0x4, block1: 0x8, block2: 0, block3: 0)
        let ab = ORReduce.reduce([a, b])
        let ba = ORReduce.reduce([b, a])
        #expect(ab == ba)
        #expect(ab.block0 == 0x5)
        #expect(ab.block1 == 0xA)
    }
}
