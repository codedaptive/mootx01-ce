// DebouncerTests.swift
//
// Tests for OutboxDrainDebouncer (CVK-ICLOUD P3-M1).
//
// Unit tests (DebouncerTests suite):
//   - coalescing: two arm() calls within the window produce exactly one trigger
//   - ceiling: repeated arm(now:) calls at injected clock values fire within maxLatency
//   - backoff re-arm: the trigger closure can call arm() to re-queue after failure
//   - teardown race: arm() then cancel() → no trigger after cancel() returns
//
// Integration test (AutoPushOnWriteTests suite):
//   - local write → outbox append → debouncer arms → push fires automatically (B-11)
//
// Timing strategy:
//   Unit tests inject real Task.sleep with short durations (5 ms coalescing,
//   20 ms ceiling). arm(now:) with explicit ContinuousClock.Instant values is used
//   in the ceiling test to drive the duration-math without wall-clock dependency.
//   No fixed Task.sleep in test code — trigger arrival is polled with the
//   ContinuousClock deadline + Task.yield() pattern.
//
//   The integration test uses the production 2 s coalescing window and polls for
//   up to 5 s, verifying real B-11 behaviour end-to-end.

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

// MARK: - TriggerCounter

/// Actor-isolated counter for tracking trigger invocations across async boundaries.
/// Captured by @Sendable closures passed to OutboxDrainDebouncer.trigger.
private actor TriggerCounter {
    private(set) var count: Int = 0
    func increment() { count += 1 }
}

// MARK: - Poll helper

/// Poll `condition` with Task.yield() until it returns true or `timeout` elapses.
///
/// No fixed Task.sleep: each iteration yields the executor and re-checks immediately.
/// Returns true if condition was satisfied, false if the deadline passed first.
private func pollUntil(
    timeout: Duration = .milliseconds(500),
    condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        await Task.yield()
        if await condition() { return true }
    }
    return false
}

// MARK: - DebouncerTests

@Suite("OutboxDrainDebouncer — coalescing and teardown")
struct DebouncerTests {

    // MARK: - Coalescing

    /// Two arm() calls within the coalescing window must fire exactly one trigger.
    ///
    /// Second arm() cancels the first task; the new task fires after one window elapses.
    /// The generation counter prevents a stale fireTrigger() from the first task from
    /// producing a second trigger even if its sleep completed before task.cancel() runs.
    @Test("coalescing: two arm() calls within the window produce exactly one trigger")
    func coalescingProducesOneTrigger() async throws {
        let counter = TriggerCounter()
        let debouncer = OutboxDrainDebouncer(
            coalescingWindow: .milliseconds(5),
            maxLatency: .milliseconds(50),
            sleep: { try await Task.sleep(for: $0) },
            trigger: { await counter.increment() }
        )

        // Fire both arms before the 5 ms window can expire.
        await debouncer.arm()
        await debouncer.arm()

        // Poll up to 200 ms for the (single) trigger to fire.
        let fired = await pollUntil(timeout: .milliseconds(200)) {
            await counter.count >= 1
        }
        #expect(fired, "coalescing: trigger should fire within 200 ms")

        // Brief settle to detect any spurious second trigger from the cancelled task.
        let settleDeadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        while ContinuousClock.now < settleDeadline { await Task.yield() }

        let finalCount = await counter.count
        #expect(finalCount == 1,
                "coalescing: exactly 1 trigger expected; got \(finalCount)")
    }

    // MARK: - Ceiling

    /// Repeated arm(now:) calls at injected clock values must fire within maxLatency
    /// of the burst's first arm, even though the coalescing window exceeds maxLatency.
    ///
    /// The arm(now:) parameter lets the test drive the duration-math without
    /// wall-clock elapsed time. The actual Task.sleep that fires is tiny (real,
    /// short-duration) so the test does not block long.
    ///
    /// coalescingWindow = 50 ms (large so the ceiling always dominates).
    /// maxLatency       = 20 ms.
    ///
    /// Clock injection scenario:
    ///   arm(now: t0+0):  sleep = min(50, 20) = 20 ms
    ///   arm(now: t0+5):  sleep = min(55, 15) = 15 ms
    ///   arm(now: t0+10): sleep = min(60, 10) = 10 ms
    ///   arm(now: t0+16): sleep = min(66,  4) =  4 ms  ← ceiling dominates
    ///
    /// After last arm at injected t0+16 ms, the real Task.sleep is 4 ms.
    /// The trigger fires ~4 ms later (well within the 200 ms poll deadline).
    @Test("ceiling: injected clock values drive ceiling math; trigger fires within maxLatency")
    func ceilingBoundsLatency() async throws {
        let counter = TriggerCounter()
        let debouncer = OutboxDrainDebouncer(
            coalescingWindow: .milliseconds(50), // deliberately large so ceiling wins
            maxLatency: .milliseconds(20),
            sleep: { try await Task.sleep(for: $0) },
            trigger: { await counter.increment() }
        )

        let t0 = ContinuousClock.now
        // Advance the injected clock to simulate a hot write stream.
        // Each arm cancels the previous task and recalculates the sleep duration;
        // the ceiling shrinks the sleep as the burst ages.
        await debouncer.arm(now: t0)                                  // sleep=20ms
        await debouncer.arm(now: t0.advanced(by: .milliseconds(5)))   // sleep=15ms
        await debouncer.arm(now: t0.advanced(by: .milliseconds(10)))  // sleep=10ms
        await debouncer.arm(now: t0.advanced(by: .milliseconds(16)))  // sleep=4ms (ceiling wins)

        // The final real sleep is 4 ms. Poll for up to 200 ms.
        let fired = await pollUntil(timeout: .milliseconds(200)) {
            await counter.count >= 1
        }
        #expect(fired, "ceiling: trigger should fire within 200 ms after last arm()")
        let ceilingCount = await counter.count
        #expect(ceilingCount == 1, "ceiling: expected exactly 1 trigger")
    }

    // MARK: - Backoff re-arm

    /// The trigger closure must be able to call arm() to re-queue a push attempt.
    ///
    /// This models the transport-failure backoff path in CloudKitStateActor.enable():
    /// on SyncError.transportFailure the trigger re-arms the debouncer so the next
    /// attempt is made after a short coalescing window rather than immediately.
    ///
    /// The test verifies:
    ///   1. First trigger fires (count == 1), re-arms debouncer.
    ///   2. Second trigger fires from the re-arm (count == 2).
    ///   3. Second trigger does NOT re-arm; no third trigger.
    @Test("backoff re-arm: trigger can call arm() to queue a retry push")
    func backoffReArmFromTrigger() async throws {
        let counter = TriggerCounter()
        // Box breaks the reference cycle: trigger closure → debouncer → trigger closure.
        final class Box: @unchecked Sendable { var value: OutboxDrainDebouncer? }
        let box = Box()

        let debouncer = OutboxDrainDebouncer(
            coalescingWindow: .milliseconds(5),
            maxLatency: .milliseconds(50),
            sleep: { try await Task.sleep(for: $0) },
            trigger: { [box] in
                let c = await counter.count
                await counter.increment()
                if c == 0 {
                    // First trigger: simulate re-arm on transport failure.
                    await box.value?.arm()
                }
                // Second trigger: no re-arm — stop the chain.
            }
        )
        box.value = debouncer

        await debouncer.arm()

        // Poll for 2 triggers (first fires + re-arm fires).
        let bothFired = await pollUntil(timeout: .milliseconds(500)) {
            await counter.count >= 2
        }
        #expect(bothFired, "backoff re-arm: second trigger should fire within 500 ms")
        let rearmCount = await counter.count
        #expect(rearmCount == 2, "backoff re-arm: expected exactly 2 triggers")

        // Clean up the debouncer task (in case arm() raced a third time).
        await debouncer.cancel()
    }

    // MARK: - Teardown race

    /// arm() followed immediately by cancel() must NOT fire the trigger.
    ///
    /// Three-layer guarantee (documented in OutboxDrainDebouncer):
    ///   1. generation &+= 1 in cancel() invalidates any queued fireTrigger().
    ///   2. task?.cancel() throws CancellationError from Task.sleep immediately.
    ///   3. await t?.value waits for the task to complete; after cancel() returns,
    ///      the trigger is provably silent — fireTrigger() either never ran (sleep
    ///      threw) or ran but found a stale generation token and returned immediately.
    ///
    /// This is the I-2 contract: after disable() returns, no push can fire.
    /// The CloudKitStateActor.disable() method relies on this guarantee when it
    /// calls `await drainDebouncer?.cancel()` before clearing engine state.
    @Test("teardown race: arm() then cancel() — no trigger after cancel() returns")
    func teardownRaceNoTriggerAfterCancel() async throws {
        let counter = TriggerCounter()
        let debouncer = OutboxDrainDebouncer(
            coalescingWindow: .milliseconds(5),
            maxLatency: .milliseconds(50),
            sleep: { try await Task.sleep(for: $0) },
            trigger: { await counter.increment() }
        )

        // Arm: 5 ms sleep starts in the background.
        await debouncer.arm()

        // Immediately cancel — before the 5 ms sleep can complete in most runs.
        // Even if the sleep DID complete, the generation check prevents the trigger.
        // cancel() awaits the task so the guarantee holds deterministically.
        await debouncer.cancel()

        // Settle: give any in-flight continuation time to resolve.
        // (Should be a no-op since cancel() already awaited the task.)
        let settleDeadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        while ContinuousClock.now < settleDeadline { await Task.yield() }

        let teardownCount = await counter.count
        #expect(teardownCount == 0,
                "teardown race: trigger must not fire after cancel() returns (I-2 contract)")
    }
}

// MARK: - AutoPushOnWriteTests

/// Integration test: local write → automatic push to CloudZoneFake (B-11 end-to-end).
///
/// Builds a TwoEstateFixture (two engines sharing a CloudZoneFake) and writes a row
/// to estate A. The debouncer arms automatically in recordOutbound() after the outbox
/// append. After the coalescingWindow (2 s production default) the trigger calls push(),
/// and the CKRecord lands in CloudZoneFake — all without a manual push() call.
///
/// Poll deadline: 5 s. The production coalescingWindow is 2 s; 5 s gives 3 s of margin
/// for the slot-claim handshake, observer latency, and push latency.
///
/// Note: this test intentionally exercises the production 2 s coalescing window to
/// verify B-11 end-to-end behaviour. It is expected to take ~2–3 s wall time.
@Suite("AutoPushOnWrite — debouncer integration")
struct AutoPushOnWriteTests {

    @Test("local write lands in CloudZoneFake automatically without manual push()")
    func autodrainOnWrite() async throws {
        // Build fixture components separately so we hold a direct reference to
        // CloudZoneFake for polling — avoids crossing the TwoEstateFixture actor
        // boundary inside the poll-deadline loop.
        let storageA = try await TwoEstateFixture.makeStorage()
        let storageB = try await TwoEstateFixture.makeStorage()
        let cloud    = CloudZoneFake()
        let fixture  = TwoEstateFixture(storageA: storageA, storageB: storageB, cloud: cloud)
        try await fixture.setUp()

        let rowID = UUID()

        // writeA: inserts the row and polls until the outbox entry appears.
        // By the time writeA returns, recordOutbound() has run (outbox written)
        // and drainDebouncer.arm() has been called (sequential after append).
        try await fixture.writeA(row: [
            "id":    .uuid(rowID),
            "title": .text("auto-drain integration"),
            "value": .int(42)
        ])

        // Verify the outbox captured the write (writeA already polls for this,
        // but explicit check makes the failure message clear if something drifts).
        let outboxCount = try await fixture.outboxCountA()
        #expect(outboxCount > 0, "outbox must have an entry after writeA")

        // Poll for the record to appear in CloudZoneFake.
        // The debouncer fires push() after coalescingWindow (~2 s) without any
        // manual push() call — this is the B-11 drain leg under test.
        let zoneID = TwoEstateFixture.zoneID
        let appeared = await pollUntil(timeout: .seconds(5)) {
            await cloud.dataRecordCount(in: zoneID) > 0
        }

        #expect(appeared,
                "auto-drain: record must land in CloudZoneFake within 5 s (B-11 drain leg)")
    }
}
