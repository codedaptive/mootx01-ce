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

// MARK: - Latency window

/// A rolling window of drain-latency samples for percentile computation.
/// Maintained by the QueueKit caller across drain calls.
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

// MARK: - Report entry point

/// Emit queue-state metrics after a drain call completes.
///
/// Off-path cost is a single `Atomic<Bool>` load + branch when monitoring
/// is disabled — effectively zero overhead. When enabled, makes one
/// `pendingCount()` call and emits at most six metrics.
///
/// - Parameters:
///   - backend:    The QueueBackend whose pending count to read.
///   - drained:    The jobs returned by the last drain() call.
///   - drainStart: Epoch-seconds when the drain call started.
///   - now:        Epoch-seconds at drain completion (caller-supplied).
///   - estateTag:  The estate UUID string for metric tagging.
///   - window:     The running latency window (maintained by the caller).
public func reportQueueStats(
    backend: any QueueBackend,
    drained: [(job: Job, sessionID: SessionID)],
    drainStart: Double,
    now: Double,
    estateTag: String,
    window: inout QueueLatencyWindow
) async {
    // Off-path gate: single atomic load + branch. ~1 ns when disabled.
    guard Intellectus.isEnabled else { return }

    let drainLatencyMs = (now - drainStart) * 1000.0

    // Tags carried by all queue.* metrics for estate-level filtering.
    let tags: [String: String] = ["estate": estateTag, "kit": "QueueKit"]

    // Snapshot depth at this drain cycle. A pendingCount read failure must NOT
    // be reported as `queue.depth = 0`: a fabricated zero is indistinguishable
    // from a genuinely empty queue and would tell the observer "all drained"
    // when the truth is "could not read the depth". On failure we emit NO depth
    // metric (the consumer sees a gap, not a false floor) and a dedicated
    // `queue.depth_unavailable` error counter so the read fault is itself
    // observable. The depth-derived metrics below (idle_nonempty,
    // head_of_line_age) are likewise skipped when depth is unknown — they
    // cannot be computed honestly without it.
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

    // Latency percentiles from the rolling window.
    window.append(drainLatencyMs)
    Intellectus.report(.metric(
        name: "queue.latency_p50_ms",
        value: window.percentile(50),
        tags: tags,
        ts: now
    ))
    Intellectus.report(.metric(
        name: "queue.latency_p95_ms",
        value: window.percentile(95),
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
