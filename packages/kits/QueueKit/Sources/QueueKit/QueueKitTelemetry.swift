// QueueKitTelemetry.swift
//
// Self-report telemetry for QueueKit — emits queue depth, throughput,
// latency, and backpressure metrics via IntellectusLib.
//
// Off when monitoring is disabled (single atomic bool, ~1 ns). On-path:
// one pendingCount() query + a few Intellectus.report calls.
// Never modifies queue state; purely additive side effects.
//
// Metric namespace: queue.*
//   queue.depth              — pending job count at snapshot time
//   queue.drain_count        — jobs claimed in the last drain call
//   queue.idle_nonempty      — 1.0 when depth>0 but drain returned 0
//   queue.latency_p50_ms     — median drain latency (ms) over recent window
//   queue.latency_p95_ms     — 95th-pct drain latency (ms) over recent window
//   queue.head_of_line_age_s — age of oldest drained job (seconds), or 0.0 when drain returned no jobs
//
// Tags: estate (estate UUID string), kit ("QueueKit")

import Foundation
import IntellectusLib
import Synchronization

// MARK: - Latency window

/// A rolling window of drain-latency samples for percentile computation.
/// Maintained by the QueueKit caller across drain calls.
///
/// The struct itself is NOT synchronised — concurrent access goes through
/// `QueueLatencyWindowBox` below.
public struct QueueLatencyWindow: Sendable {
    private var samples: [Double] = []
    private let capacity: Int

    public init(capacity: Int = 100) { self.capacity = capacity }

    public mutating func append(_ ms: Double) {
        samples.append(ms)
        if samples.count > capacity { samples.removeFirst() }
    }

    /// Returns the p-th percentile of the current window (0–100).
    /// Returns 0 when the window is empty or `p` is out of range / non-finite.
    ///
    /// P7-secfix: a NaN or out-of-range `p` produced an out-of-bounds index crash
    /// (`Int(nan) == 0` but `Int(inf)` traps; `p < 0` or `p > 100` produces
    /// indices outside [0, count-1]). Guard added before the index computation.
    public func percentile(_ p: Double) -> Double {
        guard p.isFinite, p >= 0, p <= 100 else { return 0 }
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let idx = Int((p / 100.0) * Double(sorted.count - 1))
        return sorted[max(0, min(idx, sorted.count - 1))]
    }
}

/// Thread-safe holder for the rolling drain-latency window.
///
/// Concurrent drainers on one `QueueKit` instance are LEGITIMATE — the
/// encode worker and the discrete import worker share the per-estate
/// queue, and each `drain(stream:)` call reports into the same window.
/// An unguarded `var` window under that concurrency corrupts the sample
/// array's heap buffer (observed as a SIGSEGV in `Array.append` from
/// `reportQueueStats` under full-suite test load). Rust twin already
/// guards: `facade.rs` `latency_window: Mutex<QueueLatencyWindow>`.
///
/// Combined inner state — latency window AND emission throttle — guarded
/// by a single Mutex so sample-and-check-throttle is one atomic operation.
/// This prevents a concurrent drain from racing between "shouldEmit=true"
/// and the subsequent emission gate update.
public final class QueueLatencyWindowBox: Sendable {
    /// Inner state: mutable under the Mutex lock.
    private struct Inner {
        var window: QueueLatencyWindow
        /// Epoch-seconds of the last Intellectus.report emission for this
        /// stream. Starts at 0.0 (guaranteed to fire on the first call when
        /// monitoring is enabled, since now >> 0 + interval for any real clock).
        var lastEmissionEpoch: Double = 0.0
    }

    private let inner: Mutex<Inner>

    public init(capacity: Int = 100) {
        inner = Mutex(Inner(window: QueueLatencyWindow(capacity: capacity)))
    }

    /// Append a latency sample, then check the emission throttle.
    ///
    /// The sample is ALWAYS appended so the rolling window accumulates every
    /// drain tick — the aggregate p50/p95 reflects all ticks, not just the
    /// ones that fire an emission.
    ///
    /// - Parameters:
    ///   - ms: Drain latency in milliseconds.
    ///   - now: Current epoch-seconds (caller-supplied; never calls Date()).
    ///   - interval: Minimum seconds between emissions (pass 30.0 from the
    ///               `EMISSION_INTERVAL_S` constant at the call site).
    /// - Returns: `(p50, p95, shouldEmit)` — percentiles from the current
    ///            window plus a flag that is `true` at most once per `interval`.
    ///            When `shouldEmit` is `true`, `lastEmissionEpoch` is updated
    ///            to `now` inside the lock.
    public func sample(_ ms: Double, now: Double, interval: Double) -> (p50: Double, p95: Double, shouldEmit: Bool) {
        inner.withLock { state in
            state.window.append(ms)
            let p50 = state.window.percentile(50)
            let p95 = state.window.percentile(95)
            let shouldEmit = now - state.lastEmissionEpoch >= interval
            if shouldEmit { state.lastEmissionEpoch = now }
            return (p50, p95, shouldEmit)
        }
    }
}

// MARK: - Report entry point

// Minimum seconds between queue.* metric emissions per estate stream.
//
// A busy queue drains 100+ times per second; without rate-limiting every
// drain tick emits five metrics (depth, drain_count, idle_nonempty, p50, p95),
// flooding the metric_samples table at ~116 rows/sec — observed to reach
// 6 M rows in 3 hours in production. 30 s is long enough to keep the
// dashboard responsive without producing millions of rows per day.
//
// The latency window ACCUMULATES on every tick regardless (see
// QueueLatencyWindowBox.sample); emission carries the aggregate over the
// whole window, not just the last tick.
private let EMISSION_INTERVAL_S: Double = 30.0

/// Emit queue-state metrics after a drain call completes.
///
/// Off-path cost is a single `Atomic<Bool>` load + branch when monitoring
/// is disabled — effectively zero overhead. When enabled, samples the
/// latency window every tick but rate-limits all Intellectus.report calls
/// to at most once per `EMISSION_INTERVAL_S` (30 s) per estate stream,
/// preventing the metric-flood observed in production (6 M rows / 3 h).
///
/// - Parameters:
///   - backend:    The QueueBackend whose pending count to read.
///   - drained:    The jobs returned by the last drain() call.
///   - drainStart: Epoch-seconds when the drain call started.
///   - now:        Epoch-seconds at drain completion (caller-supplied).
///   - estateTag:  The estate UUID string for metric tagging.
///   - window:     The running latency window (thread-safe box maintained by
///     the caller; see `QueueLatencyWindowBox` for why it must be guarded).
public func reportQueueStats(
    backend: any QueueBackend,
    drained: [(job: Job, sessionID: SessionID)],
    drainStart: Double,
    now: Double,
    estateTag: String,
    window: QueueLatencyWindowBox
) async {
    // Off-path gate: single atomic load + branch. ~1 ns when disabled.
    guard Intellectus.isEnabled else { return }

    let drainLatencyMs = (now - drainStart) * 1000.0

    // Sample the window on every drain tick (window accumulates between
    // emissions). Check the throttle gate atomically inside the box.
    let (p50, p95, shouldEmit) = window.sample(drainLatencyMs, now: now, interval: EMISSION_INTERVAL_S)

    // Rate-limit: skip emission until the interval elapses.
    guard shouldEmit else { return }

    // All Intellectus.report calls below fire at most once per EMISSION_INTERVAL_S.
    let tags: [String: String] = ["estate": estateTag, "kit": "QueueKit"]

    // Snapshot depth at this emission point. A pendingCount read failure must
    // NOT be reported as `queue.depth = 0`: a fabricated zero is
    // indistinguishable from a genuinely empty queue and would tell the
    // observer "all drained" when the truth is "could not read the depth".
    // On failure we emit NO depth metric (the consumer sees a gap, not a false
    // floor) and a dedicated `queue.depth_unavailable` error counter so the
    // read fault is itself observable. Depth-derived metrics (idle_nonempty,
    // head_of_line_age) are likewise skipped when depth is unknown.
    let depthOpt = try? await backend.pendingCount()
    if let depth = depthOpt {
        Intellectus.report(.metric(
            name: "queue.depth",
            value: Double(depth),
            tags: tags,
            ts: now
        ))
    } else {
        Intellectus.report(.metric(
            name: "queue.depth_unavailable",
            value: 1,
            tags: tags,
            ts: now
        ))
    }

    // Jobs returned by this drain call.
    Intellectus.report(.metric(
        name: "queue.drain_count",
        value: Double(drained.count),
        tags: tags,
        ts: now
    ))

    // idle_nonempty = 1 when there are pending jobs but drain returned 0.
    // Non-zero signals the drain is falling behind: queue growing faster
    // than it is being consumed. Skipped entirely when depth is unknown —
    // emitting 0 (or 1) from an unread depth would fabricate a falling-behind
    // verdict the read could not support.
    if let depth = depthOpt {
        let idleNonempty: Double = (depth > 0 && drained.isEmpty) ? 1.0 : 0.0
        Intellectus.report(.metric(
            name: "queue.idle_nonempty",
            value: idleNonempty,
            tags: tags,
            ts: now
        ))
    }

    // Latency percentiles from the rolling window — already computed above.
    // Both values reflect ALL drain ticks since the last emission, not just
    // the current tick (the window accumulates every call to sample()).
    Intellectus.report(.metric(
        name: "queue.latency_p50_ms",
        value: p50,
        tags: tags,
        ts: now
    ))
    Intellectus.report(.metric(
        name: "queue.latency_p95_ms",
        value: p95,
        tags: tags,
        ts: now
    ))

    // Head-of-line age: age of the oldest pending job when drain returned
    // nothing despite a non-empty queue. When drain returned jobs, use the
    // oldest drained job's submit time as a proxy for pipeline latency.
    // HLC physicalTime is milliseconds since epoch.
    // The depth>0-and-idle branch is only honest when depth is known; if depth
    // could not be read, fall through to the drained-jobs proxy (or nothing).
    if let depth = depthOpt, depth > 0, drained.isEmpty {
        // Pending jobs present but none drained; age unknown without reading
        // job records — emit 0 as the "blocked, unknown age" sentinel.
        Intellectus.report(.metric(
            name: "queue.head_of_line_age_s",
            value: 0.0,
            tags: tags,
            ts: now
        ))
    } else if let oldest = drained.min(by: { $0.job.submittedAt < $1.job.submittedAt }) {
        // Age = current epoch seconds - job's submit epoch seconds.
        // HLC.physicalTime is ms since epoch; convert to seconds.
        let submitEpochS = Double(oldest.job.submittedAt.physicalTime) / 1000.0
        let ageS = max(0, now - submitEpochS)
        Intellectus.report(.metric(
            name: "queue.head_of_line_age_s",
            value: ageS,
            tags: tags,
            ts: now
        ))
    }
}
