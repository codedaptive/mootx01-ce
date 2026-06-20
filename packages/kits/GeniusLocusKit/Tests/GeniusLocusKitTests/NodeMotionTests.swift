// NodeMotionTests.swift
//
// The pure node-layer fold (NodeMotionFold) — diffusion build step §11.2.
// Mirrored in Rust (node_motion.rs / node_motion tests).

import Testing
import Foundation
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("NodeMotionFold — node-layer motion (diffusion)")
struct NodeMotionTests {

    let row = UUID()

    private func anchorCode(_ s: String) -> UInt64 {
        SubstrateTypes.LatticeAnchor.udc(s).udcCode
    }

    private func intVal(_ s: String) -> UnifiedAuditValue {
        .integer(Int64(bitPattern: anchorCode(s)))
    }

    private func entry(
        ms: Int64,
        fieldPath: String,
        after: UnifiedAuditValue,
        before: UnifiedAuditValue = .null
    ) -> UnifiedAuditEntry {
        UnifiedAuditEntry(
            tier: .locus,
            hlc: HLC(physicalTime: ms, logicalCount: 0, nodeID: 1),
            verb: .mutate,
            rowID: row,
            fieldPath: fieldPath,
            beforeValue: before,
            afterValue: after,
            originRowID: nil
        )
    }

    @Test("folds distinct mutation moments + anchor trajectory with decay")
    func foldsHistory() {
        let day: Int64 = 86_400_000
        // now = 10 days after epoch (seconds for Date; ms internally in the fold).
        let now = Date(timeIntervalSince1970: Double(10 * day) / 1000.0)
        // Three distinct mutation moments (the two 8-day entries share one HLC).
        let entries = [
            entry(ms: 8 * day, fieldPath: "operational",   after: .bitmap(1)),
            entry(ms: 8 * day, fieldPath: "latticeAnchor",  after: intVal("530"), before: .null),
            entry(ms: 9 * day, fieldPath: "latticeAnchor",  after: intVal("004"), before: intVal("530")),
            entry(ms: 10 * day, fieldPath: "adjective",     after: .bitmap(2)),
        ]
        let m = NodeMotionFold.fold(entries: entries, rowID: row, now: now, lambdaPerDay: 0.5)

        #expect(m.eventCount == 3)
        #expect(m.anchorTrajectory == [anchorCode("530"), anchorCode("004")])
        #expect(m.currentAnchor == anchorCode("004"))
        #expect(m.reanchored == true)
        #expect(m.lastEventPhysicalMs == 10 * day)
        // ages 2 / 1 / 0 days → volatility = e^-1 + e^-0.5 + e^0.
        #expect(abs(m.volatility - (1.0 + exp(-0.5) + exp(-1.0))) < 1e-9)
    }

    @Test("empty history folds to zero motion")
    func emptyHistory() {
        let m = NodeMotionFold.fold(
            entries: [], rowID: row, now: Date(timeIntervalSince1970: 0), lambdaPerDay: 0.5)
        #expect(m.eventCount == 0)
        #expect(m.volatility == 0.0)
        #expect(m.anchorTrajectory.isEmpty)
        #expect(m.currentAnchor == nil)
        #expect(m.reanchored == false)
    }

    @Test("a node that never reanchors reports reanchored = false")
    func stableTopic() {
        let day: Int64 = 86_400_000
        let now = Date(timeIntervalSince1970: Double(5 * day) / 1000.0)
        let entries = [
            entry(ms: 3 * day, fieldPath: "latticeAnchor", after: intVal("612"), before: .null),
            entry(ms: 4 * day, fieldPath: "operational",   after: .bitmap(8)),
        ]
        let m = NodeMotionFold.fold(entries: entries, rowID: row, now: now, lambdaPerDay: 0.5)
        #expect(m.eventCount == 2)
        #expect(m.reanchored == false)
        #expect(m.currentAnchor == anchorCode("612"))
    }
}
