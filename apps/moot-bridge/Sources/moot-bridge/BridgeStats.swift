import Foundation

// BridgeStats.swift — standing/rolling statistics held over the lifetime of a bridge
// session.
//
// Adapted (our code) from the benchmarker RollingStats.swift, trimmed for the
// bridge: the bridge has no divergence/Jaccard/Kendall axis (that was benchmark-only
// machinery), but it DOES track a secondary-failure count — the number of times
// a write fan-out to the non-primary backend failed and was swallowed so the
// client never saw an error. Per Bob: the bridge tracks stats. These flush to the
// ObserverSink stats store (so moot-mgr can dashboard a live session) and to
// stderr (never stdout — stdout is the client's JSON-RPC channel).
//
// Concurrency: the bridge reads client lines serially on one loop, but a write
// fan-out sends to both backends concurrently, so the accumulator is an `actor`.
// Each update is a cheap append/increment; lock granularity is one sample, well
// below the IPC latency the samples measure, so contention is not a concern.

/// A single named latency series accumulated over time, with running mean/p95.
/// Keeps a bounded sample buffer so a multi-hour session does not grow unbounded.
struct BridgeSeries: Sendable {
    /// The most recent samples, in seconds. Bounded to `cap`; once full, the
    /// oldest sample is dropped (a sliding window). p95 is computed over the
    /// retained window, which is the standing tail-latency the report wants.
    private(set) var samples: [Double] = []
    /// Total samples ever recorded (not just the retained window), so counts stay
    /// accurate even after the window slides.
    private(set) var totalCount: Int = 0
    /// Sliding-window capacity. 4096 keeps p95 stable over recent traffic while
    /// bounding memory at a few tens of KB per series.
    private let cap: Int

    init(cap: Int = 4096) { self.cap = cap }

    /// Records one latency sample (seconds), sliding the window when full.
    mutating func record(_ seconds: Double) {
        totalCount += 1
        samples.append(seconds)
        if samples.count > cap {
            samples.removeFirst(samples.count - cap)
        }
    }

    /// Mean over the retained window, or 0 when empty.
    var mean: Double {
        guard !samples.isEmpty else { return 0.0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// 95th-percentile over the retained window (nearest-rank), or 0 when empty.
    var p95: Double {
        guard !samples.isEmpty else { return 0.0 }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        let index = min(max(rank, 1) - 1, sorted.count - 1)
        return sorted[index]
    }
}

/// An immutable snapshot of one series for reporting / emission.
struct BridgeSeriesSnapshot: Sendable, Equatable {
    let label: String
    let mean: Double
    let p95: Double
    let totalCount: Int
}

/// An immutable snapshot of the whole bridge-stats actor.
struct BridgeStatsSnapshot: Sendable, Equatable {
    /// Per-label latency series, e.g. `mempalace.tools/call`,
    /// `mootx01.tools/call.mirror`. Sorted by label for stable output.
    let series: [BridgeSeriesSnapshot]
    /// Number of secondary (non-primary) write fan-outs that failed and were
    /// swallowed so the client never saw an error.
    let secondaryFailureCount: Int
}

/// The rolling/standing statistics for a live bridge session.
///
/// Tracks an arbitrary set of named latency series plus the secondary-failure
/// count. A snapshot can be rendered or emitted at any time.
actor BridgeStats {
    private var series: [String: BridgeSeries] = [:]
    private var secondaryFailureCount: Int = 0

    /// Records one latency sample (seconds) into the named series, creating the
    /// series on first use.
    func recordLatency(_ seconds: Double, label: String) {
        series[label, default: BridgeSeries()].record(seconds)
    }

    /// Records one swallowed secondary-write failure (the fan-out to the
    /// non-primary backend threw or its backend closed its stream).
    func recordSecondaryFailure() {
        secondaryFailureCount += 1
    }

    /// Takes an immutable snapshot of the current state. Series are emitted in
    /// sorted-label order for stable report/diff output.
    func snapshot() -> BridgeStatsSnapshot {
        let seriesSnaps = series.keys.sorted().map { label -> BridgeSeriesSnapshot in
            let s = series[label]!
            return BridgeSeriesSnapshot(label: label, mean: s.mean, p95: s.p95,
                                      totalCount: s.totalCount)
        }
        return BridgeStatsSnapshot(series: seriesSnaps,
                                 secondaryFailureCount: secondaryFailureCount)
    }
}

// MARK: - Rendering

extension BridgeStatsSnapshot {
    /// Renders the snapshot as a human-readable block for stderr. Latencies in
    /// milliseconds. Goes to stderr only — never stdout, which is the client's
    /// JSON-RPC channel.
    func rendered(title: String) -> String {
        var out = "\(title)\n"
        for s in series {
            // Manual label padding — %@ does not honor a width flag on Darwin
            // Foundation, matching the benchmarker's Report.swift approach.
            let label = s.label.padding(toLength: 30, withPad: " ", startingAt: 0)
            out += String(format: "  %@ mean %8.2f ms   p95 %8.2f ms   n=%d\n",
                          label as NSString, s.mean * 1000, s.p95 * 1000, s.totalCount)
        }
        if secondaryFailureCount > 0 {
            out += "  secondary write failures (non-fatal, swallowed): \(secondaryFailureCount)\n"
        }
        return out
    }
}
