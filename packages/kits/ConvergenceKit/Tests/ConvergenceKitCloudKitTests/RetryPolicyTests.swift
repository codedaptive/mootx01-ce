// RetryPolicyTests.swift
//
// Verifies RetryPolicy.delay(forAttempt:suggestedRetryAfter:jitterSource:)
// for determinism, exponential growth, cap enforcement, jitter, and
// server-suggested delay as hard floor (CVK-ICLOUD P1-M6 R6).
//
// All tests inject a deterministic jitterSource closure so results are exact
// and not subject to random variation. The production path uses the default
// Double.random closure; tests bypass it.

import Testing
import Foundation
@testable import ConvergenceKitCloudKit

@Suite("RetryPolicy delay computation")
struct RetryPolicyTests {

    let policy = RetryPolicy(baseDelay: 1.0, maxDelay: 60.0, jitterFraction: 0.2)

    // No-jitter helper: zeroes out the signed jitter term (jitter = 0 when source = 0.5).
    private func zeroJitter() -> Double { 0.5 }

    // MARK: Exponential growth

    @Test("attempt 0 produces baseDelay (no jitter)")
    func attempt0() {
        let delay = policy.delay(forAttempt: 0, jitterSource: zeroJitter)
        // baseDelay × 2^0 = 1.0, jitter = 1.0 × 0.2 × (2×0.5 - 1) = 0
        #expect(delay == 1.0)
    }

    @Test("attempt 1 produces 2× base (no jitter)")
    func attempt1() {
        let delay = policy.delay(forAttempt: 1, jitterSource: zeroJitter)
        #expect(delay == 2.0)
    }

    @Test("attempt 2 produces 4× base (no jitter)")
    func attempt2() {
        let delay = policy.delay(forAttempt: 2, jitterSource: zeroJitter)
        #expect(delay == 4.0)
    }

    @Test("attempt 3 produces 8× base (no jitter)")
    func attempt3() {
        let delay = policy.delay(forAttempt: 3, jitterSource: zeroJitter)
        #expect(delay == 8.0)
    }

    // MARK: Cap enforcement

    @Test("cap: attempt 6 would be 64s but is capped at maxDelay 60s (no jitter)")
    func capAt6() {
        // 1.0 × 2^6 = 64 > maxDelay(60) → capped to 60
        let delay = policy.delay(forAttempt: 6, jitterSource: zeroJitter)
        #expect(delay == 60.0)
    }

    @Test("cap: very high attempt (100) still returns at most maxDelay + jitter")
    func capAtHighAttempt() {
        // max jitter up = capped × jitterFraction × 1 = 60 × 0.2 = 12
        let delay = policy.delay(forAttempt: 100, jitterSource: { 1.0 })
        #expect(delay <= 60.0 + 60.0 * 0.2 + 0.001)
    }

    @Test("overflow guard: attempt 31 produces same capped result as attempt 30")
    func overflowGuard() {
        let at30 = policy.delay(forAttempt: 30, jitterSource: zeroJitter)
        let at31 = policy.delay(forAttempt: 31, jitterSource: zeroJitter)
        // exponent clamps at 30 for both; results identical
        #expect(at30 == at31)
    }

    // MARK: Jitter direction

    @Test("jitter source = 0.0 → minimum jitter (negative direction)")
    func jitterNegative() {
        // jitter = capped × 0.2 × (2×0.0 - 1) = -capped×0.2
        // attempt 0: capped=1.0, jitter=-0.2, result=0.8
        let delay = policy.delay(forAttempt: 0, jitterSource: { 0.0 })
        #expect(abs(delay - 0.8) < 1e-9)
    }

    @Test("jitter source = 1.0 → maximum jitter (positive direction)")
    func jitterPositive() {
        // jitter = capped × 0.2 × (2×1.0 - 1) = +capped×0.2
        // attempt 0: capped=1.0, jitter=+0.2, result=1.2
        let delay = policy.delay(forAttempt: 0, jitterSource: { 1.0 })
        #expect(abs(delay - 1.2) < 1e-9)
    }

    @Test("delay is always non-negative even with extreme negative jitter")
    func alwaysNonNegative() {
        // Very small base, very large jitter fraction — clamp to 0
        let edgePolicy = RetryPolicy(baseDelay: 0.001, maxDelay: 0.001, jitterFraction: 1.0)
        let delay = edgePolicy.delay(forAttempt: 0, jitterSource: { 0.0 })
        #expect(delay >= 0.0)
    }

    // MARK: Server-suggested delay as hard floor

    @Test("suggestedRetryAfter overrides computed delay when larger")
    func suggestedFloor() {
        // Computed for attempt 0 with no jitter: 1.0
        // Server suggests 30.0 → result must be 30.0
        let delay = policy.delay(forAttempt: 0,
                                 suggestedRetryAfter: 30.0,
                                 jitterSource: zeroJitter)
        #expect(delay == 30.0)
    }

    @Test("suggestedRetryAfter is not applied when computed delay is larger")
    func computedLargerThanSuggested() {
        // attempt 5: capped = min(32, 60) = 32, no jitter → 32
        // suggested 1.0 → result 32 (computed wins)
        let delay = policy.delay(forAttempt: 5,
                                 suggestedRetryAfter: 1.0,
                                 jitterSource: zeroJitter)
        #expect(delay == 32.0)
    }

    @Test("no suggestedRetryAfter → delay matches exponential schedule (deterministic)")
    func deterministicWithoutSuggestion() {
        let delay1 = policy.delay(forAttempt: 3, jitterSource: zeroJitter)
        let delay2 = policy.delay(forAttempt: 3, jitterSource: zeroJitter)
        #expect(delay1 == delay2)
        #expect(delay1 == 8.0)
    }

    // MARK: .default configuration

    @Test(".default configuration has expected values")
    func defaultConfiguration() {
        #expect(RetryPolicy.default.baseDelay == 1.0)
        #expect(RetryPolicy.default.maxDelay == 60.0)
        #expect(RetryPolicy.default.jitterFraction == 0.2)
    }
}
