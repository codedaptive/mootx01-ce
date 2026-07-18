// PollTierPolicyTests.swift
//
// Unit tests for PollTierPolicy — the pure adaptive tier decision table.
//
// All tests inject `nowMs` directly so there are no OS time calls,
// no Task.sleep, and no async code. The full transition table is
// exercisable deterministically.

import Testing
import Foundation
@testable import ConvergenceKit

// Synthetic timestamps used throughout. Chosen to avoid ambiguity:
// T0 is "start of session", subsequent Ts advance by recognizable amounts.
private let T0: Int64  = 1_000_000      // arbitrary epoch base
private let T1: Int64  = T0 + 10_000   // +10 s (within fast interval)
private let T2: Int64  = T0 + 25_000   // +25 s (just past one fast interval)
private let T_mid: Int64  = T0 + 100_000   // +100 s (just past activity window of 120 s? no — 100 < 120)
private let T_outside: Int64 = T0 + 130_000 // +130 s (outside 120 s activity window)
private let T_far: Int64     = T0 + 400_000 // +400 s (well past any window)

@Suite("PollTierPolicy — adaptive tier decision table")
struct PollTierPolicyTests {

    // MARK: - Cold-start state

    @Test("cold-start tier is idle")
    func coldStartIsIdle() {
        let policy = PollTierPolicy()
        #expect(policy.tier == .idle)
    }

    @Test("cold-start lastActivityMs is nil")
    func coldStartActivityNil() {
        let policy = PollTierPolicy()
        #expect(policy.lastActivityMs == nil)
    }

    @Test("cold-start nextIntervalMs is idle interval")
    func coldStartIntervalIsIdle() {
        let policy = PollTierPolicy()
        #expect(policy.nextIntervalMs == PollTierPolicy.idleIntervalMs)
    }

    // MARK: - Non-empty pull resets to fast

    @Test("non-empty pull from idle → fast")
    func nonEmptyPullFromIdle() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        #expect(policy.tier == .fast)
    }

    @Test("non-empty pull stamps lastActivityMs")
    func nonEmptyPullStampsActivity() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        #expect(policy.lastActivityMs == T0)
    }

    @Test("non-empty pull from mid → fast")
    func nonEmptyPullFromMid() {
        var policy = PollTierPolicy()
        // Get to mid: non-empty, then empty outside window
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T_outside)
        #expect(policy.tier == .mid)
        policy.recordNonEmptyPull(nowMs: T_outside)
        #expect(policy.tier == .fast)
    }

    @Test("non-empty pull from idle → fast, then interval is fast")
    func nonEmptyPullIntervalIsFast() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        #expect(policy.nextIntervalMs == PollTierPolicy.fastIntervalMs)
    }

    // MARK: - Nudge resets to fast

    @Test("nudge from idle → fast")
    func nudgeFromIdle() {
        var policy = PollTierPolicy()
        policy.recordNudge(nowMs: T0)
        #expect(policy.tier == .fast)
    }

    @Test("nudge stamps lastActivityMs")
    func nudgeStampsActivity() {
        var policy = PollTierPolicy()
        policy.recordNudge(nowMs: T2)
        #expect(policy.lastActivityMs == T2)
    }

    @Test("nudge from mid → fast")
    func nudgeFromMid() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T_outside)
        #expect(policy.tier == .mid)
        policy.recordNudge(nowMs: T_outside)
        #expect(policy.tier == .fast)
    }

    // MARK: - Empty pull outside activity window (decay)

    @Test("empty pull on cold-start (nil lastActivity) stays idle — floor")
    func emptyPullColdStart() {
        var policy = PollTierPolicy()
        // Cold start: idle tier, no prior activity stamped (lastActivityMs == nil).
        // recordEmptyPull: nil lastActivityMs → window guard does not fire
        // → switch on .idle → break (idle is the floor, no further decay).
        policy.recordEmptyPull(nowMs: T0)
        #expect(policy.tier == .idle)
    }

    @Test("empty pull: fast outside activity window → mid")
    func emptyPullFastOutsideWindow() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)    // → fast, lastActivity = T0
        policy.recordEmptyPull(nowMs: T_outside) // T_outside - T0 = 130 s > 120 s window → fast → mid
        #expect(policy.tier == .mid)
    }

    @Test("empty pull: mid outside activity window → idle")
    func emptyPullMidOutsideWindow() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T_outside) // fast → mid
        policy.recordEmptyPull(nowMs: T_far)     // mid → idle (T_far - T0 > window)
        #expect(policy.tier == .idle)
    }

    @Test("empty pull: idle outside activity window → idle (floor)")
    func emptyPullIdleFloor() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T_outside)  // fast → mid
        policy.recordEmptyPull(nowMs: T_far)      // mid → idle
        policy.recordEmptyPull(nowMs: T_far + 100_000) // idle → idle (floor)
        #expect(policy.tier == .idle)
    }

    // MARK: - Empty pull within activity window (hold fast)

    @Test("empty pull within activity window holds fast")
    func emptyPullWithinWindowHoldsFast() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)    // → fast, lastActivity = T0
        // T1 - T0 = 10 s < 120 s window → hold fast
        policy.recordEmptyPull(nowMs: T1)
        #expect(policy.tier == .fast)
    }

    @Test("empty pull exactly at window boundary holds fast")
    func emptyPullAtWindowBoundaryHoldsFast() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        // T0 + 119_999 ms = just inside window
        policy.recordEmptyPull(nowMs: T0 + PollTierPolicy.activityWindowMs - 1)
        #expect(policy.tier == .fast)
    }

    @Test("empty pull just outside window boundary decays")
    func emptyPullJustOutsideWindowDecays() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        // T0 + 120_000 ms = exactly at window (NOT within, since < is strict)
        policy.recordEmptyPull(nowMs: T0 + PollTierPolicy.activityWindowMs)
        #expect(policy.tier == .mid) // fast → mid
    }

    @Test("multiple empty pulls within window do not decay")
    func multipleEmptyPullsWithinWindow() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T0 + 20_000)  // +20 s, within window
        policy.recordEmptyPull(nowMs: T0 + 40_000)  // +40 s, within window
        policy.recordEmptyPull(nowMs: T0 + 60_000)  // +60 s, within window
        #expect(policy.tier == .fast)
    }

    // MARK: - Decay then reset sequence

    @Test("full decay sequence then non-empty pull resets to fast")
    func fullDecayThenReset() {
        var policy = PollTierPolicy()
        // Reach fast
        policy.recordNonEmptyPull(nowMs: T0)
        #expect(policy.tier == .fast)
        // Decay to mid
        policy.recordEmptyPull(nowMs: T_outside)
        #expect(policy.tier == .mid)
        // Decay to idle
        policy.recordEmptyPull(nowMs: T_far)
        #expect(policy.tier == .idle)
        // Non-empty pull resets
        policy.recordNonEmptyPull(nowMs: T_far + 5_000)
        #expect(policy.tier == .fast)
    }

    @Test("nudge after full decay resets to fast and stamps activity")
    func nudgeAfterFullDecayResets() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T_outside)   // → mid
        policy.recordEmptyPull(nowMs: T_far)       // → idle
        policy.recordNudge(nowMs: T_far + 5_000)
        #expect(policy.tier == .fast)
        #expect(policy.lastActivityMs == T_far + 5_000)
    }

    // MARK: - Interval queries

    @Test("fast tier produces fast interval")
    func fastTierInterval() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        #expect(policy.nextIntervalMs == PollTierPolicy.fastIntervalMs)
    }

    @Test("mid tier produces mid interval")
    func midTierInterval() {
        var policy = PollTierPolicy()
        policy.recordNonEmptyPull(nowMs: T0)
        policy.recordEmptyPull(nowMs: T_outside)
        #expect(policy.nextIntervalMs == PollTierPolicy.midIntervalMs)
    }

    @Test("idle tier produces idle interval")
    func idleTierInterval() {
        let policy = PollTierPolicy()
        #expect(policy.nextIntervalMs == PollTierPolicy.idleIntervalMs)
    }

    // MARK: - Named constant sanity

    @Test("fast interval is less than mid interval")
    func fastLessThanMid() {
        #expect(PollTierPolicy.fastIntervalMs < PollTierPolicy.midIntervalMs)
    }

    @Test("mid interval is less than idle interval")
    func midLessThanIdle() {
        #expect(PollTierPolicy.midIntervalMs < PollTierPolicy.idleIntervalMs)
    }

    @Test("activity window is larger than fast interval")
    func activityWindowLargerThanFast() {
        // WHY: the window must span at least two fast-tier intervals to prevent
        // premature decay on the very first empty poll after activity.
        #expect(PollTierPolicy.activityWindowMs > 2 * PollTierPolicy.fastIntervalMs)
    }

    @Test("activity window is less than mid interval × 2")
    func activityWindowBoundedByMid() {
        // WHY: the window shouldn't be so large that we stay in fast tier for
        // multiple mid-tier intervals — that defeats the purpose of the decay ladder.
        #expect(PollTierPolicy.activityWindowMs < 2 * PollTierPolicy.midIntervalMs)
    }
}
