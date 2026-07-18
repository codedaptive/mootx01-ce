// OutboxDrainDebouncer.swift
//
// Coalescing scheduler that debounces outbox drain triggers.
//
// PROBLEM: naive push-on-every-write creates per-keystroke push storms.
// A user typing in a text field fires a write per character; without
// coalescing, each character would attempt a push to CloudKit or a
// federation relay, wasting bandwidth and hammering rate limits (B-11).
//
// SOLUTION: arm() starts or extends a coalescing window. The trigger
// fires once the write stream quiets (coalescingWindow elapses with no
// new arm()). A max-latency ceiling guarantees a trigger even under a
// hot write stream — the trigger fires within maxLatency of the burst's
// first arm() regardless of subsequent write activity.
//
// DESIGN:
// - Pure scheduler: no CloudKit, no PersistenceKit, no observer coupling.
//   All dependencies injected (sleep primitive, trigger closure) so the
//   type is deterministically unit-testable with a fake clock.
// - Single owned Task per burst; no fire-and-forget tasks. Task handle
//   is stored in `task` and cancelled explicitly by arm() or cancel().
// - Generation counter prevents double-trigger when a completing sleep
//   races a new arm() or cancel(). Actor isolation serializes all access;
//   generation is the final guard against a stale fireTrigger() call.
// - cancel() is async: awaits the owned Task so callers get a
//   deterministic teardown guarantee. After cancel() returns, the
//   trigger will NOT be called — the I-2 contract.
//
// CONSTANTS (OutboxDrainDebouncer.Constants):
//   coalescingWindow = 2 s  — window reset by each arm()
//   maxLatency       = 10 s — ceiling from the burst's first arm()
//
// USAGE (CloudKitStateActor):
//   enable()  → creates a debouncer whose trigger calls push()
//   disable() → awaits debouncer.cancel() before clearing state
//   recordOutbound() → calls debouncer.arm() after successful append
//
// Used by CloudKitStateActor (ConvergenceKitCloudKit). Any backend that
// owns a durable outbox can adopt the same pattern.

import Foundation

// MARK: - OutboxDrainDebouncer

/// Coalescing scheduler that fires a trigger after write activity quiets.
///
/// Call `arm()` after each durable outbox write. `arm()` starts or extends
/// a coalescing window; if another `arm()` arrives before the window expires,
/// the window resets from the current time. The trigger fires once the window
/// expires without a new arm() call.
///
/// The max-latency ceiling guarantees forward progress: even a sustained write
/// stream fires the trigger within `maxLatency` of the burst's first `arm()`.
///
/// All methods are actor-isolated. Callers from other actors use `await`.
/// The actor's executor ensures no concurrent mutation of generation, task,
/// or firstArmTime.
public actor OutboxDrainDebouncer {

    // MARK: - Constants

    /// Time constants for the coalescing window and max-latency ceiling.
    public enum Constants {
        /// Coalescing window: each arm() resets this countdown before triggering.
        ///
        /// WHY 2 s: coalesces rapid-fire writes (e.g. a batch of 10 upserts in a
        /// tight loop) into one push while keeping perceived latency short for
        /// interactive single-row edits. A single isolated write triggers a push
        /// within 2 s of the edit.
        public static let coalescingWindow: Duration = .seconds(2)

        /// Max-latency ceiling: the trigger fires within this time of the first
        /// arm() in a burst, even if writes never stop.
        ///
        /// WHY 10 s: a sustained write stream (bulk import, large migration) must
        /// not defer push indefinitely. Without the ceiling, arm() resetting the
        /// window on every write would postpone the trigger until writes stop.
        /// 10 s balances batch efficiency against sync responsiveness.
        public static let maxLatency: Duration = .seconds(10)
    }

    // MARK: - Dependencies (injected)

    /// Sleep primitive. Production: `{ try await Task.sleep(for: $0) }`.
    ///
    /// Tests inject a fake that records requested durations and completes
    /// them on demand — no wall time, fully deterministic. The injected
    /// sleep must throw CancellationError when the Task is cancelled so
    /// the debouncer's cancel path works correctly.
    private let sleepFn: @Sendable (Duration) async throws -> Void

    /// Trigger closure. Typically the engine's push() wrapped with error handling.
    ///
    /// Called exactly once per burst, after the coalescing window expires or
    /// the max-latency ceiling is hit. Must be @Sendable — it is called from
    /// an unstructured Task that is not isolated to any particular actor.
    private let triggerFn: @Sendable () async -> Void

    // MARK: - Configuration

    private let coalescingWindow: Duration
    private let maxLatency: Duration

    // MARK: - Internal state

    /// Generation counter. Incremented on every arm() and on cancel().
    ///
    /// fireTrigger(generation:) is a no-op unless its token matches the
    /// current generation. This prevents double-trigger when arm() is called
    /// while the previous task's sleep is completing: the previous task's
    /// fireTrigger call arrives on the actor's executor AFTER arm() has
    /// advanced generation, so the stale token fails the guard check and the
    /// trigger is not called twice.
    private var generation: UInt64 = 0

    /// The active debounce task. Never fire-and-forget: this reference is
    /// always stored here until the task is replaced (by arm()) or cancelled
    /// (by cancel()). cancel() awaits task.value before returning.
    private var task: Task<Void, Never>?

    /// When the current burst started (the instant of the first arm() that
    /// created the active task). Nil when no burst is in progress.
    ///
    /// Ceiling enforcement: sleep duration is bounded to
    ///   min(now + coalescingWindow, firstArmTime + maxLatency) - now
    /// so the trigger fires within maxLatency of the burst start even if
    /// arm() keeps extending the window.
    private var firstArmTime: ContinuousClock.Instant?

    // MARK: - Init

    public init(
        coalescingWindow: Duration = Constants.coalescingWindow,
        maxLatency: Duration = Constants.maxLatency,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        trigger: @escaping @Sendable () async -> Void
    ) {
        self.coalescingWindow = coalescingWindow
        self.maxLatency = maxLatency
        self.sleepFn = sleep
        self.triggerFn = trigger
    }

    // MARK: - arm()

    /// Arm the debouncer after a write. Starts or extends the coalescing window.
    ///
    /// If no task is running, records `firstArmTime` (burst start) and launches
    /// a task that sleeps for `min(coalescingWindow, remaining ceiling)`.
    ///
    /// If a task is already running, cancels it and relaunches with recalculated
    /// sleep duration. The window resets from `now`; the ceiling stays fixed at
    /// `firstArmTime + maxLatency`. As the burst ages, the ceiling dominates and
    /// the sleep shortens, ensuring the trigger fires within maxLatency.
    ///
    /// - Parameter now: The logical current time. Default is `ContinuousClock.now`.
    ///   Tests pass an explicit value to control timing without wall-clock dependency.
    public func arm(now: ContinuousClock.Instant = ContinuousClock.now) {
        // Record burst start the first time this burst is armed.
        let first = firstArmTime ?? now
        if firstArmTime == nil { firstArmTime = now }

        // Cancel the stale task. The new one replaces it below.
        task?.cancel()

        // Advance generation so any queued fireTrigger() from the cancelled
        // task is a no-op. Actor isolation guarantees the cancelled task's
        // fireTrigger() call must wait for arm() to release the executor
        // before running — by then self.generation != myGen.
        generation &+= 1
        let myGen = generation

        // Compute sleep duration.
        //
        // windowDeadline  = now + coalescingWindow  (extended on each arm())
        // ceilingDeadline = first + maxLatency      (fixed for this burst)
        // sleepUntil      = min(window, ceiling)    (ceiling wins as burst ages)
        // sleepDuration   = max(0, sleepUntil - now)  (never negative)
        let windowDeadline  = now + coalescingWindow
        let ceilingDeadline = first + maxLatency
        let sleepUntil      = min(windowDeadline, ceilingDeadline)
        let sleepDuration   = max(.zero, sleepUntil - now)

        // Capture sleepFn by value (it is @Sendable). The task runs nonisolated
        // (the [weak self] capture moves it off the actor's isolation domain) so
        // the sleep does NOT hold the actor's executor — the actor remains
        // responsive to new arm() and cancel() calls while the task sleeps.
        let capturedSleep = sleepFn
        task = Task { [weak self] in
            do {
                try await capturedSleep(sleepDuration)
            } catch {
                // CancellationError (arm() restarted or cancel() called) or
                // fake-clock error: do not trigger.
                return
            }
            // Hop to the actor's executor for the generation check and trigger.
            await self?.fireTrigger(generation: myGen)
        }
    }

    // MARK: - cancel()

    /// Cancel the debouncer and await the owned task.
    ///
    /// After cancel() returns, triggerFn will NOT be called — even if arm() was
    /// invoked just before cancel(). Three-layer guarantee:
    ///
    /// 1. generation is incremented: any queued fireTrigger(generation:) sees a
    ///    stale token and returns immediately.
    /// 2. task?.cancel() signals cancellation to the sleeping task; it throws
    ///    CancellationError and exits without calling fireTrigger.
    /// 3. await t?.value waits for the task to finish. If the task already
    ///    completed its sleep and is queued to call fireTrigger, this suspend
    ///    lets fireTrigger run (where the generation mismatch short-circuits it)
    ///    before returning. After await returns, the trigger is provably silent.
    public func cancel() async {
        // Invalidate any pending fireTrigger before suspending.
        generation &+= 1
        task?.cancel()
        let t = task
        task = nil
        firstArmTime = nil
        // Await after clearing task/firstArmTime. If fireTrigger() runs while
        // we are suspended here, it will see (generation != self.generation)
        // from the increment above and return immediately.
        await t?.value
    }

    // MARK: - fireTrigger (private)

    /// Invoke the trigger if this generation is still current.
    ///
    /// Called on the actor's executor after the task's sleep completes.
    /// The generation check is the final guard against stale invocations.
    private func fireTrigger(generation: UInt64) async {
        guard generation == self.generation else {
            // Stale: arm() or cancel() advanced self.generation since this
            // task's sleep started. Drop without triggering.
            return
        }
        // Clear burst state BEFORE calling the trigger. This allows the
        // trigger closure to re-arm the debouncer (e.g. on transport failure)
        // without the re-arm seeing an active task already in the slot.
        task = nil
        firstArmTime = nil
        await triggerFn()
    }
}
