// AdaptivePollScheduler.swift
//
// Owns the adaptive poll loop for the CloudKit inbound path.
//
// WHY POLLING IS THE CORRECTNESS PATH:
// The resident process (a launchd service) cannot hold an APNs entitlement.
// CKRecordZoneSubscription silent-push wakeups are an optional latency
// accelerator for host apps that DO hold the entitlement — they are not the
// delivery guarantee. This scheduler IS the guarantee.
//
// DESIGN:
//   - Injected sleep function (testable: pass { _ in } to run loop at max speed)
//   - Injected pull closure (testable: pass a fake that returns controlled receipts)
//   - Owned Task that runs the poll loop
//   - nudge() interrupts the current sleep immediately, fires a pull, resets to fast
//
// SLEEP INTERRUPTION MECHANISM:
//   nudge() cancels the current sleep sub-task (_sleepTask). The sub-task catches
//   CancellationError and exits cleanly; the loop's `await _sleepTask?.value`
//   returns, the pull fires immediately. The main loop Task is NOT cancelled —
//   only the sleep sub-task is interrupted. This gives true immediate-pull
//   semantics without terminating the loop.
//
// CKRERROR BACKOFF (tracked follow-up — see comment in runLoop):
//   When the push path receives a .retryableBackoff(retryAfter:) result from
//   CKErrorTaxonomy, the engine should delay future pull cycles to avoid
//   hammering a throttled CloudKit endpoint. The seam for this is
//   recordThrottled(retryAfterMs:) on the policy — not yet wired. Tracked
//   in docs/status/CVK_ICLOUD/TRACKED_FOLLOWUPS.md (scheduler retryableBackoff
//   wiring item).
//
// NUDGE CONTRACT (SPEC B-11, INTERFACE § 2):
//   nudge() → immediate pull + reset to fast tier.
//   Callers:
//     OutboxDrainDebouncer fires nudge() after each local push so the remote
//     peer sees the write sooner than idle cadence would deliver (P3-M1).
//     APNs/local IPC wakeup handler calls nudge() via handleRemoteNotification
//     (P3-M3), delegating tier accounting to the scheduler.
//
// SPEC: CONVERGENCEKIT_SPEC.md § 5 B-11 (convergence loop).
// INTERFACE: CONVERGENCEKIT_INTERFACE.md § 2 CloudKitSyncEngine — nudge().

import Foundation
import ConvergenceKit

// MARK: - Closure types

/// Pull closure: invoked by the scheduler to pull inbound changes.
/// Returns a SyncReceipt whose `pulled` count drives tier accounting.
public typealias SchedulerPullFn = @Sendable () async throws -> SyncReceipt

/// Sleep function: injected for testability.
///
/// Production: `{ d in try await Task.sleep(for: d) }`
/// Tests: `{ _ in }` — returns immediately, letting the loop run at max
///                       speed driven by async Task.yield() scheduling.
public typealias SchedulerSleepFn = @Sendable (Duration) async throws -> Void

// MARK: - AdaptivePollScheduler

/// Adaptive tiered poll scheduler for the CloudKit inbound path.
///
/// Manages a `PollTierPolicy` that governs how frequently pulls occur based
/// on observed zone activity. The tier decays from fast → mid → idle during
/// quiet periods and resets to fast on any activity signal.
///
/// Thread model: `actor` isolation prevents concurrent mutations of
/// `_policy` and `_sleepTask`. All public methods are actor-isolated; the
/// pull closure and sleep function are `@Sendable` so they cross the actor
/// boundary safely.
public actor AdaptivePollScheduler {

    // MARK: - State

    private var _policy: PollTierPolicy = .init()
    private var _loopTask: Task<Void, Never>?
    private var _sleepTask: Task<Void, Never>?

    // MARK: - Injected dependencies

    private let _pull: SchedulerPullFn
    private let _sleep: SchedulerSleepFn

    // MARK: - Init

    /// Create an adaptive poll scheduler.
    ///
    /// - Parameters:
    ///   - pull: Closure that performs one pull cycle. Should call
    ///           `CloudKitSyncEngine.pull()` (or an equivalent fake in tests).
    ///   - sleep: Sleep function. Production default: `Task.sleep(for:)`.
    ///            Tests: pass `{ _ in }` for immediate-return so the loop
    ///            runs as fast as the async runtime allows.
    public init(
        pull: @escaping SchedulerPullFn,
        sleep: @escaping SchedulerSleepFn = { d in try await Task.sleep(for: d) }
    ) {
        self._pull  = pull
        self._sleep = sleep
    }

    // MARK: - Lifecycle

    /// Start the poll loop. Idempotent: no-op if already started.
    ///
    /// Safe to call right after `CloudKitSyncEngine.enable()` completes.
    /// The loop begins with a full-interval sleep so the first pull does not
    /// fire immediately — the engine's `enable()` path already drains
    /// leftover outbox entries and the first explicit pull (if any) is the
    /// caller's responsibility.
    public func start() {
        guard _loopTask == nil else { return }
        _loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    /// Stop the poll loop deterministically.
    ///
    /// Cancels the loop task and any active sleep sub-task. The caller can
    /// `await` this method and be confident no further pulls will be scheduled
    /// after it returns. Satisfies I-2 (disable() stops observation).
    public func stop() {
        // Cancel the sleep sub-task first (unblocks any pending sleep immediately).
        _sleepTask?.cancel()
        _sleepTask = nil
        // Cancel the loop task.
        _loopTask?.cancel()
        _loopTask = nil
    }

    /// External accelerator: fire an immediate pull and reset to fast tier.
    ///
    /// Interrupts the current sleep by cancelling `_sleepTask`. The loop wakes,
    /// fires a pull without waiting for the normal interval, and the result
    /// drives tier accounting as usual.
    ///
    /// Calling `nudge()` while the scheduler is stopped is a safe no-op:
    /// `_sleepTask` is nil, so the cancellation is a no-op, and the tier
    /// is stamped (for when start() is called later).
    ///
    /// Nudge is THE SEAM for external accelerators (B-11, INTERFACE § 2):
    ///   - P3-M3 OutboxDrainDebouncer wires this after each push cycle
    ///   - Future APNs wakeup handlers call nudge() rather than pull() directly
    ///   - Local IPC from a companion process calls nudge() to accelerate pull
    public func nudge() {
        _policy.recordNudge(nowMs: nowMs())
        // Interrupt the sleep so the pull fires immediately.
        _sleepTask?.cancel()
    }

    // MARK: - Policy query (for tests and diagnostics)

    /// The current polling tier (for tests and diagnostic surfaces).
    public var currentTier: PollTier {
        _policy.tier
    }

    /// The next interval in milliseconds (for diagnostic surfaces).
    public var nextIntervalMs: Int64 {
        _policy.nextIntervalMs
    }

    // MARK: - Private — poll loop

    private func runLoop() async {
        while !Task.isCancelled {
            let intervalMs = _policy.nextIntervalMs
            let interval   = Duration.milliseconds(intervalMs)

            // Sleep for the current tier's interval, or until nudge() cancels
            // the sleep sub-task.
            //
            // Why a separate sub-task instead of Task.sleep directly:
            //   nudge() must be able to interrupt the sleep without cancelling
            //   the entire loop. By sleeping in a child Task, nudge() can
            //   cancel ONLY the sleep; the parent loop task stays alive and
            //   proceeds to pull immediately after the sub-task exits.
            //
            // NOTE — CKError throttle override (tracked follow-up):
            //   When the push path surfaces retryableBackoff(retryAfter:), the
            //   engine should call a future recordThrottled(retryAfterMs:) method
            //   on this policy to override `intervalMs` with the server-suggested
            //   floor. The seam for that wire is here: replace `intervalMs` with
            //   `max(intervalMs, throttleFloorMs)` before constructing `interval`.
            //   Until that follow-up ships, the tier cadence governs unconditionally.
            let sleepTask = Task { [_sleep, interval] in
                do {
                    try await _sleep(interval)
                } catch {
                    // CancellationError from nudge() or stop() — exit cleanly.
                }
            }
            _sleepTask = sleepTask
            // Await the sleep sub-task. Returns immediately if cancelled by nudge().
            await sleepTask.value
            _sleepTask = nil

            if Task.isCancelled { break }

            // Pull and update tier based on result.
            do {
                let receipt = try await _pull()
                if receipt.pulled > 0 {
                    _policy.recordNonEmptyPull(nowMs: nowMs())
                } else {
                    _policy.recordEmptyPull(nowMs: nowMs())
                }
            } catch {
                // Pull failure (notEnabled, transport error, etc.).
                // Treat as empty pull for tier purposes — the scheduler
                // should not promote on errors, and should not crash.
                // CKError-specific backoff will be added in P3-M4.
                _policy.recordEmptyPull(nowMs: nowMs())
            }
        }
    }

    // MARK: - Clock helper

    /// Current wall-clock in milliseconds since Unix epoch.
    ///
    /// Matches the `nowMillis()` convention in EngineClock.swift. Kept here
    /// (rather than using EngineClock) because PollTierPolicy is in the core
    /// ConvergenceKit module and the scheduler is in ConvergenceKitCloudKit —
    /// the scheduler provides its own clock rather than calling into the actor.
    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
