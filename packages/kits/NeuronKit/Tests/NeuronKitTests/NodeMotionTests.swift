// NodeMotionTests.swift
//
// The diffusion node lens (NodeMotionLens) — pure fold + classifier.
// Mirrored in Rust (NeuronKit/rust diffusion/{node_motion,node_anomaly}.rs).
// The estate-reading run/anomaly wrappers are exercised by integration coverage.

import Testing
import Foundation
import SubstrateTypes
import GeniusLocusKit
import NeuronKit

@Suite("NodeMotionLens.fold — node-layer motion (diffusion)")
struct NodeMotionFoldTests {

    let row = UUID()

    private func anchorCode(_ s: String) -> UInt64 {
        SubstrateTypes.LatticeAnchor.udc(s).udcCode
    }
    private func intVal(_ s: String) -> UnifiedAuditValue {
        .integer(Int64(bitPattern: anchorCode(s)))
    }
    private func entry(
        ms: Int64, fieldPath: String,
        after: UnifiedAuditValue, before: UnifiedAuditValue = .null
    ) -> UnifiedAuditEntry {
        UnifiedAuditEntry(
            tier: .locus,
            hlc: HLC(physicalTime: ms, logicalCount: 0, nodeID: 1),
            verb: .mutate, rowID: row, fieldPath: fieldPath,
            beforeValue: before, afterValue: after, originRowID: nil)
    }

    @Test("folds distinct mutation moments + anchor trajectory with decay")
    func foldsHistory() {
        let day: Int64 = 86_400_000
        let now = Date(timeIntervalSince1970: Double(10 * day) / 1000.0)
        let entries = [
            entry(ms: 8 * day, fieldPath: "operational",  after: .bitmap(1)),
            entry(ms: 8 * day, fieldPath: "latticeAnchor", after: intVal("530"), before: .null),
            entry(ms: 9 * day, fieldPath: "latticeAnchor", after: intVal("004"), before: intVal("530")),
            entry(ms: 10 * day, fieldPath: "adjective",    after: .bitmap(2)),
        ]
        let m = NodeMotionLens.fold(entries: entries, rowID: row, now: now, lambdaPerDay: 0.5)
        #expect(m.eventCount == 3)
        #expect(m.anchorTrajectory == [anchorCode("530"), anchorCode("004")])
        #expect(m.currentAnchor == anchorCode("004"))
        #expect(m.reanchored == true)
        #expect(m.lastEventPhysicalMs == 10 * day)
        #expect(abs(m.volatility - (1.0 + exp(-0.5) + exp(-1.0))) < 1e-9)
    }

    @Test("empty history folds to zero motion")
    func emptyHistory() {
        let m = NodeMotionLens.fold(
            entries: [], rowID: row, now: Date(timeIntervalSince1970: 0), lambdaPerDay: 0.5)
        #expect(m.eventCount == 0)
        #expect(m.volatility == 0.0)
        #expect(m.anchorTrajectory.isEmpty)
        #expect(m.currentAnchor == nil)
        #expect(m.reanchored == false)
    }

    // Regression for secfix/ce-node-motion-hlc-dedup: two mutations in the SAME
    // physical millisecond are distinct HLCs (logicalCount differs) and must each
    // count as a mutation moment. The physical-only dedup key collapsed them into
    // one event. Field entries sharing ONE full HLC (one write, many fields) must
    // still collapse to a single event. Mirrors Rust
    // `same_millisecond_distinct_hlcs_are_distinct_events`.
    @Test("same-millisecond distinct HLCs are distinct mutation moments")
    func sameMillisecondDistinctHLCs() {
        let day: Int64 = 86_400_000
        let now = Date(timeIntervalSince1970: Double(8 * day) / 1000.0)
        func entryLC(ms: Int64, lc: Int32, fieldPath: String) -> UnifiedAuditEntry {
            UnifiedAuditEntry(
                tier: .locus,
                hlc: HLC(physicalTime: ms, logicalCount: lc, nodeID: 1),
                verb: .mutate, rowID: row, fieldPath: fieldPath,
                beforeValue: .null, afterValue: .bitmap(1), originRowID: nil)
        }
        let entries = [
            // Write A: two field entries sharing one HLC → ONE event.
            entryLC(ms: 8 * day, lc: 0, fieldPath: "operational"),
            entryLC(ms: 8 * day, lc: 0, fieldPath: "adjective"),
            // Write B: same millisecond, logicalCount bumped → a SECOND event.
            entryLC(ms: 8 * day, lc: 1, fieldPath: "operational"),
        ]
        let m = NodeMotionLens.fold(entries: entries, rowID: row, now: now, lambdaPerDay: 0.5)
        #expect(m.eventCount == 2,
                "same-ms writes with distinct logicalCount must count separately; intra-write field entries sharing one HLC must still collapse")
        // Both events are zero-age → volatility = 2.0 exactly.
        #expect(abs(m.volatility - 2.0) < 1e-9)
    }

    @Test("a node that never reanchors reports reanchored = false")
    func stableTopic() {
        let day: Int64 = 86_400_000
        let now = Date(timeIntervalSince1970: Double(5 * day) / 1000.0)
        let entries = [
            entry(ms: 3 * day, fieldPath: "latticeAnchor", after: intVal("612"), before: .null),
            entry(ms: 4 * day, fieldPath: "operational",   after: .bitmap(8)),
        ]
        let m = NodeMotionLens.fold(entries: entries, rowID: row, now: now, lambdaPerDay: 0.5)
        #expect(m.eventCount == 2)
        #expect(m.reanchored == false)
        #expect(m.currentAnchor == anchorCode("612"))
    }
}

@Suite("NodeMotionLens.classify — write-time node anomaly")
struct NodeAnomalyTests {

    private func motion(volatility: Double, trajectory: [UInt64]) -> NodeMotion {
        NodeMotion(
            rowID: UUID(), volatility: volatility, eventCount: trajectory.count,
            lastEventPhysicalMs: 1, anchorTrajectory: trajectory)
    }

    @Test("high volatility → churning + anomalous")
    func churning() {
        let a = NodeMotionLens.classify(motion: motion(volatility: 4.0, trajectory: [100]))
        #expect(a.isChurning)
        #expect(a.reanchored == false)
        #expect(a.isAnomalous)
    }

    @Test("a reanchored topic is anomalous even when calm")
    func reanchored() {
        let a = NodeMotionLens.classify(motion: motion(volatility: 0.5, trajectory: [100, 200]))
        #expect(a.isChurning == false)
        #expect(a.reanchored)
        #expect(a.isAnomalous)
        #expect(a.currentAnchor == 200)
    }

    @Test("a stable single-topic low-volatility node is not anomalous")
    func stable() {
        let a = NodeMotionLens.classify(motion: motion(volatility: 0.3, trajectory: [100]))
        #expect(a.isAnomalous == false)
    }

    @Test("the churn threshold is honored")
    func thresholdHonored() {
        let m = motion(volatility: 2.5, trajectory: [100])
        #expect(NodeMotionLens.classify(motion: m, churnThreshold: 2.0).isChurning)
        #expect(NodeMotionLens.classify(motion: m, churnThreshold: 3.0).isChurning == false)
    }
}
