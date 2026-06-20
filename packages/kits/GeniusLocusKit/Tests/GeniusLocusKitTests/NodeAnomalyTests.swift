// NodeAnomalyTests.swift
//
// The pure node-anomaly classifier (NodeAnomalyClassifier) — diffusion §11.2
// write-time read. Mirrored in Rust (node_anomaly.rs tests).

import Testing
import Foundation
@testable import GeniusLocusKit

@Suite("NodeAnomalyClassifier — write-time node anomaly read")
struct NodeAnomalyTests {

    private func motion(volatility: Double, trajectory: [UInt64]) -> NodeMotion {
        NodeMotion(
            rowID: UUID(),
            volatility: volatility,
            eventCount: trajectory.count,
            lastEventPhysicalMs: 1,
            anchorTrajectory: trajectory)
    }

    @Test("high volatility → churning + anomalous")
    func churning() {
        let a = NodeAnomalyClassifier.classify(motion: motion(volatility: 4.0, trajectory: [100]))
        #expect(a.isChurning)
        #expect(a.reanchored == false)
        #expect(a.isAnomalous)
    }

    @Test("a reanchored topic is anomalous even when calm")
    func reanchored() {
        let a = NodeAnomalyClassifier.classify(motion: motion(volatility: 0.5, trajectory: [100, 200]))
        #expect(a.isChurning == false)
        #expect(a.reanchored)
        #expect(a.isAnomalous)
        #expect(a.currentAnchor == 200)
    }

    @Test("a stable single-topic low-volatility node is not anomalous")
    func stable() {
        let a = NodeAnomalyClassifier.classify(motion: motion(volatility: 0.3, trajectory: [100]))
        #expect(a.isAnomalous == false)
    }

    @Test("the churn threshold is honored")
    func thresholdHonored() {
        let m = motion(volatility: 2.5, trajectory: [100])
        #expect(NodeAnomalyClassifier.classify(motion: m, churnThreshold: 2.0).isChurning)
        #expect(NodeAnomalyClassifier.classify(motion: m, churnThreshold: 3.0).isChurning == false)
    }
}
