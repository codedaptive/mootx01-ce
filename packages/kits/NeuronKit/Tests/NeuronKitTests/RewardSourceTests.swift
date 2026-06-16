// RewardSourceTests.swift
//
// Conformance tests for the two-source reward seam (NEURONKIT_SPEC § 3.1
// step 1). Verifies that:
//  - ExplicitDiaryRewardSource returns the explicit reward when present.
//  - ExplicitDiaryRewardSource falls back to RecallTraceRewardSource when
//    the target has no explicit reward.
//  - RecallTraceRewardSource's trace-derived behaviour is unchanged.
//  - The precedence rule is enforced: explicit → fallback.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

@Suite("RewardSource — two-source seam (NEURONKIT_SPEC § 3.1 step 1)")
struct RewardSourceTests {

    // Helper: build a minimal RecallTraceItem for reward tests.
    private func item(_ target: String, used: Bool) -> RecallTraceItem {
        RecallTraceItem(
            target: target,
            recalledAt: Date(timeIntervalSince1970: 0),
            operationalBitmap: used ? RecallTraceItem.flagUsed : 0
        )
    }

    // MARK: - RecallTraceRewardSource (step 1b)

    @Test("RecallTraceRewardSource: used=true yields 1.0")
    func recallTraceUsedYieldsOne() {
        let src = RecallTraceRewardSource()
        #expect(src.reward(for: item("t1", used: true)) == 1.0)
    }

    @Test("RecallTraceRewardSource: used=false yields 0.0")
    func recallTraceUnusedYieldsZero() {
        let src = RecallTraceRewardSource()
        #expect(src.reward(for: item("t1", used: false)) == 0.0)
    }

    @Test("RecallTraceRewardSource: kind is .recallTrace")
    func recallTraceKind() {
        #expect(RecallTraceRewardSource().kind == .recallTrace)
    }

    // MARK: - ExplicitDiaryRewardSource (step 1a)

    @Test("ExplicitDiaryRewardSource: explicit reward returned for known target")
    func explicitRewardReturnedForKnownTarget() {
        let src = ExplicitDiaryRewardSource(rewardsByTarget: ["drawer-A": 0.9])
        #expect(src.reward(for: item("drawer-A", used: false)) == 0.9)
    }

    @Test("ExplicitDiaryRewardSource: fallback used for unknown target")
    func explicitRewardFallsBackForUnknownTarget() {
        // No entry for "drawer-B" → falls back to RecallTraceRewardSource.
        let src = ExplicitDiaryRewardSource(rewardsByTarget: ["drawer-A": 0.9])
        // used=true → trace fallback returns 1.0
        #expect(src.reward(for: item("drawer-B", used: true)) == 1.0)
        // used=false → trace fallback returns 0.0
        #expect(src.reward(for: item("drawer-B", used: false)) == 0.0)
    }

    @Test("ExplicitDiaryRewardSource: kind is .explicitDiaryReward")
    func explicitDiaryRewardKind() {
        let src = ExplicitDiaryRewardSource(rewardsByTarget: [:])
        #expect(src.kind == .explicitDiaryReward)
    }

    @Test("ExplicitDiaryRewardSource: explicit overrides trace-based used=true (precedence)")
    func explicitOverridesTraceSignal() {
        // Explicit reward is 0.2 even though used=true would yield 1.0 via trace.
        let src = ExplicitDiaryRewardSource(rewardsByTarget: ["drawer-C": 0.2])
        let r = src.reward(for: item("drawer-C", used: true))
        #expect(r == 0.2, "explicit value must override trace-derived 1.0")
    }

    @Test("ExplicitDiaryRewardSource: multiple targets, each returns its own explicit reward")
    func explicitMultipleTargets() {
        let src = ExplicitDiaryRewardSource(rewardsByTarget: [
            "x": 0.3,
            "y": 0.8,
        ])
        #expect(src.reward(for: item("x", used: false)) == 0.3)
        #expect(src.reward(for: item("y", used: false)) == 0.8)
        // Unknown target falls back to trace.
        #expect(src.reward(for: item("z", used: true)) == 1.0)
    }
}
