// AdaptivePollSchedulerTests.swift
//
// Tests for AdaptivePollScheduler — covers:
//   1. Tier transitions driven by pull results (pure scheduler unit tests)
//   2. nudge() interrupt: immediate pull without waiting for full interval
//   3. Deterministic stop: no further pulls after stop() returns
//   4. Harness integration: write on A → B's scheduler pulls → convergence
//
// Clock injection:
//   All tests pass `sleep: { _ in }` (immediate return) so the scheduler
//   loop runs at maximum async speed without real-time delays. The
//   poll-deadline pattern (loop + Task.yield() + ContinuousClock deadline)
//   waits for convergence rather than sleeping a fixed duration.
//
// Concurrency note:
//   AdaptivePollScheduler is an actor. All calls to start(), stop(), nudge(),
//   currentTier, and nextIntervalMs require `await` from test code.
//   `defer` blocks cannot be async in Swift 6, so cleanup calls appear
//   explicitly at the end of each test rather than in defer blocks.
//
// Test naming: test names describe BEHAVIOR, not implementation. Scheduler
// internals (sleepTask, _policy) are not tested directly — only observable
// outcomes (pull count, tier, convergence).

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
@testable import ConvergenceKitCloudKit

// MARK: - Scheduler unit tests

@Suite("AdaptivePollScheduler — unit")
struct AdaptivePollSchedulerUnitTests {

    // MARK: - Basic lifecycle

    @Test("start() idempotent: calling twice does not duplicate pulls")
    func startIdempotent() async throws {
        let pullCount = Counter()
        let scheduler = AdaptivePollScheduler(
            pull: { await pullCount.increment(); return .empty },
            sleep: { _ in }
        )
        await scheduler.start()
        await scheduler.start()  // second start — should no-op

        // Yield a few times to let the loop run
        for _ in 0..<10 { await Task.yield() }
        await scheduler.stop()

        let count = await pullCount.value
        #expect(count >= 1, "at least one pull should have run")
    }

    @Test("stop() halts the loop: no further pulls after stop")
    func stopHaltsLoop() async throws {
        let pullCount = Counter()
        let scheduler = AdaptivePollScheduler(
            pull: { await pullCount.increment(); return .empty },
            sleep: { _ in }
        )
        await scheduler.start()

        // Let at least a few pulls run
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        while ContinuousClock.now < deadline { await Task.yield() }

        await scheduler.stop()

        // Capture count right after stop
        let countAfterStop = await pullCount.value

        // Yield more — should not get further pulls
        let deadline2 = ContinuousClock.now.advanced(by: .milliseconds(50))
        while ContinuousClock.now < deadline2 { await Task.yield() }

        let countFinal = await pullCount.value
        // Allow one extra pull for any in-flight pull at the exact stop moment
        #expect(countFinal <= countAfterStop + 1,
                "no pulls after stop(); before=\(countAfterStop) after=\(countFinal)")
    }

    // MARK: - Tier transitions via pulls

    @Test("non-empty pull result resets tier to fast")
    func nonEmptyPullResetsToFast() async throws {
        let scheduler = AdaptivePollScheduler(
            pull: { return SyncReceipt(pushed: 0, pulled: 1, conflicts: 0) },
            sleep: { _ in }
        )
        await scheduler.start()

        // Wait for at least one pull to complete
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            await Task.yield()
            let tier = await scheduler.currentTier
            if tier == .fast { break }
        }
        await scheduler.stop()

        let tier = await scheduler.currentTier
        #expect(tier == .fast, "non-empty pull should set tier to fast")
    }

    @Test("empty-only pulls do not promote tier to fast")
    func emptyPullsDoNotPromote() async throws {
        // This test verifies the scheduler's wiring to the policy:
        // if pulls always return empty, the tier must NOT reach fast.
        // (The pure transition-table tests in PollTierPolicyTests cover
        //  exact fast→mid→idle decay; this covers the scheduler's wiring.)
        let pullCount = Counter()
        let scheduler = AdaptivePollScheduler(
            pull: {
                await pullCount.increment()
                return .empty  // always empty: scheduler must not promote tier
            },
            sleep: { _ in }
        )

        // Start at idle tier (cold start)
        let initialTier = await scheduler.currentTier
        #expect(initialTier == .idle)

        await scheduler.start()

        // Let a few pulls run
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        while ContinuousClock.now < deadline { await Task.yield() }
        await scheduler.stop()

        // Tier must NOT be fast — empty pulls must not promote.
        let finalTier = await scheduler.currentTier
        #expect(finalTier != .fast,
                "tier should not reach fast on empty-only pulls")
        #expect(await pullCount.value >= 1,
                "at least one pull should have run")
    }

    // MARK: - nudge() interrupt

    @Test("nudge() fires an immediate pull and resets tier to fast")
    func nudgeFiresImmediatePull() async throws {
        let pullCount = Counter()

        // Use a sleep that DOES sleep briefly (50 ms) so we can distinguish
        // "pull from sleep completion" vs "pull from nudge interrupt".
        // nudge() should interrupt the sleep and fire a pull without waiting.
        let scheduler = AdaptivePollScheduler(
            pull: {
                await pullCount.increment()
                return .empty
            },
            sleep: { d in
                // Sleep 50 ms — long enough that the test can call nudge()
                // before the sleep expires and observe the interruption.
                try? await Task.sleep(for: .milliseconds(50))
            }
        )
        await scheduler.start()

        // Let the loop start and enter the first sleep (give it 5 ms to boot)
        let bootDeadline = ContinuousClock.now.advanced(by: .milliseconds(5))
        while ContinuousClock.now < bootDeadline { await Task.yield() }

        let beforeNudge = await pullCount.value
        await scheduler.nudge()  // Should interrupt the 50 ms sleep immediately

        // Tier should be fast after nudge
        let tierAfterNudge = await scheduler.currentTier
        #expect(tierAfterNudge == .fast, "nudge should reset tier to fast")

        // Wait for the nudge-triggered pull to complete (up to 200 ms)
        let nudgeDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        while ContinuousClock.now < nudgeDeadline {
            await Task.yield()
            let c = await pullCount.value
            if c > beforeNudge { break }
        }
        await scheduler.stop()

        let afterNudge = await pullCount.value
        #expect(afterNudge > beforeNudge,
                "nudge() should have triggered at least one additional pull")
    }

    @Test("nudge() on stopped scheduler is safe no-op")
    func nudgeOnStoppedSchedulerIsNoOp() async throws {
        let pullCount = Counter()
        let scheduler = AdaptivePollScheduler(
            pull: { await pullCount.increment(); return .empty },
            sleep: { _ in }
        )
        // Do NOT call start() — scheduler is stopped
        await scheduler.nudge()  // Should not crash or pull

        // Brief yield — no pull should happen since loop is not running
        for _ in 0..<10 { await Task.yield() }
        #expect(await pullCount.value == 0, "nudge on stopped scheduler should not pull")
    }
}

// MARK: - Harness integration test

/// Integration test: write on A → push from A → B's AdaptivePollScheduler
/// pulls → B converges to A's state WITHOUT a manual `engineB.pull()` call.
///
/// This test proves the scheduler wiring end-to-end: the scheduler's pull
/// closure drives real convergence when backed by TwoEstateFixture's engines.
///
/// Uses fake-sleep (`{ _ in }`) so the scheduler runs at max async speed.
/// The poll-deadline pattern (yield loop + ContinuousClock deadline) waits
/// for B to pull A's write without any fixed `Task.sleep`.
///
/// Cleanup: cannot use `defer { scheduler.stop() }` because defer blocks
/// are synchronous in Swift 6. Instead, stop() is called explicitly after
/// the assertion block.
// .serialized: instant-sleep schedulers spin the async runtime at max speed;
// concurrent integration tests starve each other's Task.yield() convergence
// loops, causing intermittent 5-second deadline expiry. Serialise so each
// test gets the full runtime budget without contention from a sibling scheduler.
@Suite("AdaptivePollScheduler — harness integration (CVK-ICLOUD P3-M2)", .serialized)
struct AdaptivePollSchedulerIntegrationTests {

    @Test("write on A → push A → B scheduler pulls → B converges without manual pull()")
    func schedulerDrivenConvergence() async throws {
        let fixture = try await TwoEstateFixture.make()

        // Create a scheduler for estate B with immediate-return sleep so the
        // loop runs at maximum async speed in the test environment.
        // The pull closure calls engineB.pull() directly — no manual pull() in the test.
        let scheduler = AdaptivePollScheduler(
            pull: { [fixture] in
                try await fixture.engineB.pull()
            },
            sleep: { _ in }  // no real sleep: run as fast as the async runtime allows
        )
        await scheduler.start()

        // Write a row to estate A (this queues it in A's outbox via observer).
        let id = UUID()
        try await fixture.writeA(row: [
            "id":    .uuid(id),
            "title": .text("scheduler-driven"),
            "value": .int(42)
        ])

        // Push from A so the write is available in the shared CloudZoneFake.
        _ = try await fixture.engineA.push()

        // Wait for B's scheduler to pull A's write (poll-deadline, no Task.sleep).
        // The scheduler is running fast (immediate sleep), so it will poll
        // the CloudZoneFake repeatedly. Convergence should happen within
        // a few Task.yield() cycles.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var row: StorageRow? = nil
        while ContinuousClock.now < deadline {
            await Task.yield()
            row = try await fixture.queryB(id: id)
            if row != nil { break }
        }

        // Explicit cleanup — cannot defer because stop() is actor-isolated async.
        await scheduler.stop()

        #expect(row != nil,
                "B should have A's write after scheduler polls (no manual pull() called)")
        if let r = row {
            // Verify the correct value arrived (not just a ghost row).
            let title = r["title"]
            #expect(title == .text("scheduler-driven"),
                    "B's pulled row should carry A's written value")
        }
    }

    // NOTE: The "tier reaches fast on non-empty pull" behavior is covered by
    // AdaptivePollSchedulerUnitTests.nonEmptyPullResetsToFast (no harness needed —
    // the unit test controls the pull return value directly so there is no race
    // between the scheduler's rapid loop and the tier-capture). Tier transitions
    // are also fully exercised by PollTierPolicyTests (27 deterministic pure tests).
    // A tier-check integration test would require controlling the pull return value
    // from inside the harness loop, which is out of scope for this mission.
}

// MARK: - CKError backoff tests (CVK-WB6)

/// Tests that AdaptivePollScheduler honours CKError backoff via RetryPolicy.
///
/// Design notes:
///   - sleep is recorded-and-immediate: `{ d in await recorder.record(d) }`.
///     This lets the loop run at maximum async speed while capturing the
///     effective sleep duration passed by the scheduler.
///   - retryPolicy and jitterSource are both injected for determinism.
///     `jitterFraction: 0.0` pins jitter to zero regardless of jitterSource.
///   - Effective interval = max(tier interval, backoff floor). Tests observe
///     the sleep duration at index N to verify the correct floor is applied.
///   - Sleep/pull index correspondence (0-based): sleep[N] is recorded right
///     before pull[N+1] executes, so when pullCount >= K, sleeps[0..K-1]
///     are guaranteed to be in the recorder.
///
/// .serialized: instant-sleep schedulers spin the async runtime at max speed;
/// concurrent suites would starve each other's Task.yield() loops.
@Suite("AdaptivePollScheduler — CKError backoff (CVK-WB6)", .serialized)
struct AdaptivePollSchedulerBackoffTests {

    // MARK: - Harness helper: records durations without blocking

    private actor IntervalRecorder {
        private var _durations: [Duration] = []
        func record(_ d: Duration) { _durations.append(d) }
        var durations: [Duration] { _durations }
        var count: Int { _durations.count }
    }

    // MARK: - Tests

    @Test("throttle with retryAfterSeconds=30 stretches next poll interval to 30 s")
    func throttleWithRetryAfterStretchesNextInterval() async throws {
        // RetryPolicy: baseDelay=1s, jitterFraction=0 → delay(attempt:0)=1s.
        // Since 1s < retryAfterSeconds(30s), the backoff floor becomes 30_000ms.
        // fast-tier interval = 20_000ms < 30_000ms → sleep[2]=30_000ms.
        let recorder  = IntervalRecorder()
        let callCount = Counter()

        let scheduler = AdaptivePollScheduler(
            pull: {
                let n = await callCount.incrementAndGet()
                switch n {
                case 1:
                    // Non-empty pull → tier becomes fast (20 s interval).
                    return SyncReceipt(pushed: 0, pulled: 1, conflicts: 0)
                case 2:
                    // Rate-limit with 30 s server hint → backoffFloor = 30_000 ms.
                    throw CKError(.requestRateLimited,
                                  userInfo: [CKErrorRetryAfterKey: NSNumber(value: 30.0)])
                default:
                    return .empty
                }
            },
            sleep: { d in await recorder.record(d) },
            retryPolicy: RetryPolicy(baseDelay: 1.0, maxDelay: 60.0, jitterFraction: 0.0),
            jitterSource: { 0.5 }
        )
        await scheduler.start()

        // Three pull completions guarantee sleep[0..2] are all recorded.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            await Task.yield()
            if await callCount.value >= 3 { break }
        }
        await scheduler.stop()

        let durations = await recorder.durations
        // sleep[0]=idle(300 000ms), sleep[1]=fast(20 000ms),
        // sleep[2]=max(fast 20 000, backoff floor 30 000)=30 000ms.
        #expect(durations.count >= 3,
                "expected ≥3 recorded sleep durations; got \(durations.count)")
        if durations.count >= 3 {
            #expect(durations[2] == .milliseconds(30_000),
                    "sleep after rate-limit should honour retryAfter=30 s; got \(durations[2])")
        }
    }

    @Test("consecutive retryable failures grow backoff delay to the policy cap")
    func consecutiveFailuresGrowDelayToCap() async throws {
        // RetryPolicy: baseDelay=30s, maxDelay=60s, jitterFraction=0.
        //   attempt 0: delay = 30s > fast(20s) → sleep[2] = 30_000ms
        //   attempt 1: delay = 60s (capped)    → sleep[3] = 60_000ms
        let recorder  = IntervalRecorder()
        let callCount = Counter()

        let scheduler = AdaptivePollScheduler(
            pull: {
                let n = await callCount.incrementAndGet()
                if n == 1 {
                    return SyncReceipt(pushed: 0, pulled: 1, conflicts: 0) // → fast tier
                }
                throw CKError(.networkFailure, userInfo: [:])  // retryableBackoff(nil)
            },
            sleep: { d in await recorder.record(d) },
            retryPolicy: RetryPolicy(baseDelay: 30.0, maxDelay: 60.0, jitterFraction: 0.0),
            jitterSource: { 0.5 }
        )
        await scheduler.start()

        // Four pull completions guarantee sleep[0..3] are all recorded.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            await Task.yield()
            if await callCount.value >= 4 { break }
        }
        await scheduler.stop()

        let durations = await recorder.durations
        // sleep[3] = max(fast 20_000, backoff floor after attempt 1 = 60_000) = 60_000ms.
        #expect(durations.count >= 4,
                "expected ≥4 recorded sleep durations; got \(durations.count)")
        if durations.count >= 4 {
            #expect(durations[3] == .milliseconds(60_000),
                    "sleep at policy cap should be 60 000 ms; got \(durations[3])")
        }
    }

    @Test("success after retryable failures resets backoff floor to zero")
    func successResetsAttemptCounter() async throws {
        // After one failure backoffFloor=30_000ms; after a success it resets to 0
        // and the next sleep returns to the fast-tier cadence (20_000ms).
        let recorder  = IntervalRecorder()
        let callCount = Counter()

        let scheduler = AdaptivePollScheduler(
            pull: {
                let n = await callCount.incrementAndGet()
                switch n {
                case 1:
                    return SyncReceipt(pushed: 0, pulled: 1, conflicts: 0) // → fast
                case 2:
                    throw CKError(.networkFailure, userInfo: [:]) // → backoffFloor=30_000ms
                case 3:
                    return SyncReceipt(pushed: 0, pulled: 1, conflicts: 0) // reset floor
                default:
                    return .empty
                }
            },
            sleep: { d in await recorder.record(d) },
            retryPolicy: RetryPolicy(baseDelay: 30.0, maxDelay: 60.0, jitterFraction: 0.0),
            jitterSource: { 0.5 }
        )
        await scheduler.start()

        // Four pull completions guarantee sleep[0..3] are all recorded.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            await Task.yield()
            if await callCount.value >= 4 { break }
        }
        await scheduler.stop()

        let durations = await recorder.durations
        // sleep[2] = max(fast 20_000, backoffFloor 30_000) = 30_000ms (backoff in effect)
        // sleep[3] = max(fast 20_000, backoffFloor 0)      = 20_000ms (reset after success)
        #expect(durations.count >= 4,
                "expected ≥4 recorded sleep durations; got \(durations.count)")
        if durations.count >= 4 {
            #expect(durations[2] == .milliseconds(30_000),
                    "sleep while backoff active should be 30 000 ms; got \(durations[2])")
            #expect(durations[3] == .milliseconds(20_000),
                    "sleep after success should reset to fast-tier 20 000 ms; got \(durations[3])")
        }
    }

    @Test("non-retryable pull error does not stretch the next poll interval")
    func nonRetryableDoesNotStretchInterval() async throws {
        // A permanent CKError (badContainer) is non-retryable; backoff state stays 0.
        // The next sleep must remain at the fast-tier cadence (20_000ms), not stretch.
        let recorder  = IntervalRecorder()
        let callCount = Counter()

        let scheduler = AdaptivePollScheduler(
            pull: {
                let n = await callCount.incrementAndGet()
                if n == 1 {
                    return SyncReceipt(pushed: 0, pulled: 1, conflicts: 0) // → fast
                }
                if n == 2 {
                    throw CKError(.badContainer, userInfo: [:]) // permanent → non-retryable
                }
                return .empty
            },
            sleep: { d in await recorder.record(d) },
            retryPolicy: RetryPolicy(baseDelay: 30.0, maxDelay: 60.0, jitterFraction: 0.0),
            jitterSource: { 0.5 }
        )
        await scheduler.start()

        // Three pull completions guarantee sleep[0..2] are all recorded.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            await Task.yield()
            if await callCount.value >= 3 { break }
        }
        await scheduler.stop()

        let durations = await recorder.durations
        // sleep[2] = max(fast 20_000, backoffFloor 0) = 20_000ms — backoff NOT applied.
        #expect(durations.count >= 3,
                "expected ≥3 recorded sleep durations; got \(durations.count)")
        if durations.count >= 3 {
            #expect(durations[2] == .milliseconds(20_000),
                    "non-retryable error must not stretch interval; got \(durations[2])")
        }
    }

    @Test("stop() is deterministic even when pull throws retryable errors")
    func teardownDeterministicAfterErrors() async throws {
        let callCount = Counter()
        let scheduler = AdaptivePollScheduler(
            pull: {
                await callCount.increment()
                throw CKError(.networkUnavailable, userInfo: [:])
            },
            sleep: { _ in },
            retryPolicy: RetryPolicy(baseDelay: 0.001, maxDelay: 0.01, jitterFraction: 0.0),
            jitterSource: { 0.5 }
        )
        await scheduler.start()

        // Let several error cycles run.
        let warmup = ContinuousClock.now.advanced(by: .milliseconds(50))
        while ContinuousClock.now < warmup { await Task.yield() }

        await scheduler.stop()
        let countAfterStop = await callCount.value

        // Yield further — should observe no additional pulls.
        let settle = ContinuousClock.now.advanced(by: .milliseconds(50))
        while ContinuousClock.now < settle { await Task.yield() }

        let countFinal = await callCount.value
        // Allow one extra pull for any pull in-flight at the exact stop moment.
        #expect(countFinal <= countAfterStop + 1,
                "no pulls after stop(); before=\(countAfterStop) after=\(countFinal)")
    }
}

// MARK: - Test helper: thread-safe counter

/// Thread-safe increment counter for asserting pull call counts in tests.
actor Counter {
    private var _value: Int = 0
    func increment() { _value += 1 }
    /// Increment and return the new value atomically within the actor.
    func incrementAndGet() -> Int { _value += 1; return _value }
    var value: Int { _value }
}
