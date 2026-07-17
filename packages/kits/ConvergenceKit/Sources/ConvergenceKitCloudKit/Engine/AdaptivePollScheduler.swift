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
//   - Injected RetryPolicy + jitter source (testable: pass deterministic values)
//   - Injected nowMs clock (testable: pass a synthetic clock for time-sensitive tests)
//   - Optional injected gcFn (testable: pass a fake to verify GC trigger timing)
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
// CKRERROR BACKOFF (CVK-WB6):
//   When the pull closure throws, CKErrorTaxonomy classifies the error:
//     .retryableBackoff(retryAfter:) — consecutive retryable failures grow the
//       backoff floor via RetryPolicy (exponential, capped, ±jitter). The next
//       sleep is max(tier interval, backoffFloor), honouring retryAfterSeconds
//       as a minimum floor. Success resets the attempt counter and backoff floor.
//     .reclaim / .conflict / .permanent — surface via log, tier cadence unchanged,
//       backoff state left untouched. These errors are unusual on the pull path
//       (they originate on the push path) but classified for completeness.
//   All inputs to the delay computation are injected (RetryPolicy, jitterSource)
//   so tests can drive the full backoff arc deterministically.
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
// GC wiring: CVK-WB7 — gcFn is called after each successful pull with
//   the current nowMs value; the closure decides whether GC is due.

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

/// GC closure: called with the current wall-clock ms after each successful pull.
/// The closure checks whether the GC interval has elapsed and runs
/// `TombstoneGC.compact` if so. Errors are swallowed by the caller —
/// a GC failure is non-fatal to the convergence loop.
///
/// Production: wraps `CloudKitStateActor.gcIfDue(nowMs:)`.
/// Tests: pass a fake that records calls or asserts timing.
/// Nil (default): GC is disabled for this scheduler instance.
public typealias SchedulerGCFn = @Sendable (Int64) async throws -> Void

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

    // MARK: - CKError backoff state

    /// Number of consecutive retryable pull failures since the last success.
    /// Drives RetryPolicy's exponential backoff schedule (CVK-WB6).
    private var _retryAttempt: Int = 0

    /// Minimum sleep floor (ms) computed from RetryPolicy after the last
    /// retryable failure. The effective sleep is max(tier interval, _backoffFloorMs).
    /// Reset to 0 on pull success.
    private var _backoffFloorMs: Int64 = 0

    // MARK: - Injected dependencies

    private let _pull: SchedulerPullFn
    private let _sleep: SchedulerSleepFn
    private let _retryPolicy: RetryPolicy
    /// Jitter source injected for deterministic testing.
    ///
    /// Production default: `{ Double.random(in: 0..<1) }`.
    /// Tests: pass a fixed value (e.g. `{ 0.5 }`) to pin jitter to zero
    /// when using `jitterFraction: 0.0`, or to a known offset otherwise.
    private let _jitterSource: @Sendable () -> Double
    /// Wall-clock source in milliseconds since Unix epoch.
    ///
    /// Production default: real system clock.
    /// Tests: pass a synthetic closure to control "due" / "not due"
    /// decisions in both tier accounting and GC scheduling without
    /// real-time delays. Both `nudge()` and the GC check use this same
    /// injection so the two features stay temporally consistent in tests.
    private let _nowMs: @Sendable () -> Int64
    /// Optional GC closure. Called with the current nowMs after each
    /// successful pull. The closure decides whether the daily GC interval
    /// has elapsed and runs compaction if so. Nil disables GC for this
    /// scheduler instance.
    private let _gcFn: SchedulerGCFn?

    // MARK: - Init

    /// Create an adaptive poll scheduler.
    ///
    /// - Parameters:
    ///   - pull: Closure that performs one pull cycle. Should call
    ///           `CloudKitSyncEngine.pull()` (or an equivalent fake in tests).
    ///   - sleep: Sleep function. Production default: `Task.sleep(for:)`.
    ///            Tests: pass `{ _ in }` for immediate-return so the loop
    ///            runs as fast as the async runtime allows.
    ///   - retryPolicy: Backoff policy applied to consecutive retryable failures.
    ///                  Default is `RetryPolicy.default` (1 s base, 60 s cap, ±20% jitter).
    ///   - jitterSource: Returns a value in [0, 1) used by RetryPolicy's jitter
    ///                   computation. Default: `Double.random(in: 0..<1)`.
    ///                   Tests: pass a fixed closure for determinism.
    public init(
        pull: @escaping SchedulerPullFn,
        sleep: @escaping SchedulerSleepFn = { d in try await Task.sleep(for: d) },
        retryPolicy: RetryPolicy = .default,
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        gcFn: SchedulerGCFn? = nil
    ) {
        self._pull         = pull
        self._sleep        = sleep
        self._retryPolicy  = retryPolicy
        self._jitterSource = jitterSource
        self._nowMs        = nowMs
        self._gcFn         = gcFn
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
        _policy.recordNudge(nowMs: _nowMs())
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
            // Effective sleep: tier interval or backoff floor, whichever is larger.
            // After a retryable error the backoff floor stretches the sleep beyond
            // the tier cadence; it resets to 0 on success (CVK-WB6).
            let tierIntervalMs = _policy.nextIntervalMs
            let nowMillis      = _nowMs()
            let effectiveMs    = max(tierIntervalMs, _backoffFloorMs)
            let interval       = Duration.milliseconds(effectiveMs)

            // Sleep for the effective interval, or until nudge() cancels the sub-task.
            //
            // Why a separate sub-task instead of Task.sleep directly:
            //   nudge() must be able to interrupt the sleep without cancelling
            //   the entire loop. By sleeping in a child Task, nudge() can
            //   cancel ONLY the sleep; the parent loop task stays alive and
            //   proceeds to pull immediately after the sub-task exits.
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

            // Pull and update tier + backoff state based on result.
            do {
                let receipt = try await _pull()
                // Success: clear backoff state so the next sleep returns to tier cadence.
                _retryAttempt   = 0
                _backoffFloorMs = 0
                if receipt.pulled > 0 {
                    _policy.recordNonEmptyPull(nowMs: nowMillis)
                } else {
                    _policy.recordEmptyPull(nowMs: nowMillis)
                }
                // Scheduled tombstone GC (CVK-WB7): after each successful pull, fire
                // the GC closure with the current nowMs. The closure checks whether the
                // daily interval has elapsed and runs TombstoneGC.compact if so.
                // Non-fatal: a GC failure (storage error, etc.) is swallowed here so the
                // convergence loop is never interrupted by background maintenance.
                if let gcFn = _gcFn {
                    try? await gcFn(nowMillis)
                }
            } catch {
                let errorClass = CKErrorClass.classify(error)
                switch errorClass {
                case .retryableBackoff(let retryAfter):
                    // Retryable (throttle, network unavailable, etc.): grow the
                    // backoff floor exponentially, honouring retryAfterSeconds as
                    // a minimum floor. Tier treats this as an empty pull (no
                    // promotion; may decay if outside activity window).
                    let backoffDelay = _retryPolicy.delay(
                        forAttempt:          _retryAttempt,
                        suggestedRetryAfter: retryAfter,
                        jitterSource:        _jitterSource
                    )
                    _backoffFloorMs = Int64(backoffDelay * 1_000)
                    _retryAttempt  += 1
                    _policy.recordEmptyPull(nowMs: nowMillis)

                default:
                    // Non-retryable on the pull path (reclaim / conflict / permanent):
                    // surface via caller diagnostics if needed; tier cadence unchanged;
                    // backoff state unchanged. These classes originate on the push path —
                    // seeing them here is unusual but should not cause cascading backoff.
                    _policy.recordEmptyPull(nowMs: nowMillis)
                }
            }
        }
    }

}
// MARK: - Clock note
//
// The scheduler's clock is the `_nowMs` injected closure. Production default:
// `{ Int64(Date().timeIntervalSince1970 * 1000) }` — same convention as
// `nowMillis()` in EngineClock.swift. Using an injected closure rather than a
// private method means tests that need to control the "due / not due" decision
// for both GC and tier accounting can pass a synthetic clock to the initialiser
// without subclassing or other indirection.
