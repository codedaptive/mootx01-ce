// RecallTypesTests.swift
//
// Per-type suite for the recall-result vocabulary: RecallScore,
// DistanceBreakdown, RecallResult, RowProjection.
//
// SWIFT/RUST CONTRACT (verified in RecallTypes.swift):
// Rust now has mirrors for RecallScore, DistanceBreakdown, RecallResult,
// and RowProjection in packages/libs/SubstrateTypes/rust/src/recall_types.rs.
// This suite asserts the Swift recall-type contract and parity surface;
// the Rust port carries equivalent type definitions for the conformance-gated
// wire path.

import Foundation
import Testing
@testable import SubstrateTypes

@Suite("RecallTypes — recall vocabulary (mirrored in Rust)")
struct RecallTypesTests {

    @Test("RecallScore stores its (rowId, score) pair and is Equatable")
    func recallScorePair() {
        let id: RowId = UUID()
        let s = RecallScore(rowId: id, score: 0.75)
        #expect(s.rowId == id)
        #expect(s.score == 0.75)
        #expect(s == RecallScore(rowId: id, score: 0.75))
    }

    @Test("DistanceBreakdown defaults every contribution to 0")
    func distanceBreakdownDefaults() {
        let d = DistanceBreakdown()
        #expect(d.latticeContribution == 0)
        #expect(d.fingerprintContribution == 0)
        #expect(d.temporalContribution == 0)
        #expect(d.bitmapContribution == 0)
    }

    @Test("DistanceBreakdown stores per-component contributions")
    func distanceBreakdownStores() {
        let d = DistanceBreakdown(lattice: 0.1, fingerprint: 0.2,
                                  temporal: 0.3, bitmap: 0.4)
        #expect(d.latticeContribution == 0.1)
        #expect(d.fingerprintContribution == 0.2)
        #expect(d.temporalContribution == 0.3)
        #expect(d.bitmapContribution == 0.4)
    }

    @Test("RecallResult carries ranked rows, breakdown defaults, and primitive name")
    func recallResultShape() {
        let rows = [RecallScore(rowId: UUID(), score: 0.9),
                    RecallScore(rowId: UUID(), score: 0.4)]
        let r = RecallResult(rows: rows, primitiveName: "fingerprint")
        #expect(r.rows.count == 2)
        #expect(r.primitiveName == "fingerprint")
        #expect(r.confidenceInterval == nil)              // defaults to nil
        #expect(r.breakdown.fingerprintContribution == 0) // default breakdown
    }

    @Test("RecallResult preserves an explicit confidence interval")
    func recallResultConfidenceInterval() {
        let r = RecallResult(rows: [], confidenceInterval: (0.2, 0.8),
                             primitiveName: "vector")
        let ci = try! #require(r.confidenceInterval)
        #expect(ci.lower == 0.2)
        #expect(ci.upper == 0.8)
    }

    @Test("RowProjection holds the minimal recall-input projection")
    func rowProjectionShape() {
        let id: RowId = UUID()
        let p = RowProjection(
            rowId: id,
            captureHLC: HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1),
            fingerprint: Fingerprint256(block0: 7, block1: 0, block2: 0, block3: 0),
            lattice: LatticeAnchor(udcCode: 5),
            bitmaps: (1, 2, 3),
            rowState: RowState.active.rawValue)
        #expect(p.rowId == id)
        #expect(p.captureHLC.physicalTime == 1000)
        #expect(p.fingerprint.block0 == 7)
        #expect(p.lattice.udcCode == 5)
        #expect(p.bitmaps.operational == 2)
        #expect(p.rowState == 0)
    }
}
