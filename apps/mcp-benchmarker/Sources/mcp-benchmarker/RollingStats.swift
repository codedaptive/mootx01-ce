import Foundation

// RollingStats.swift — standing/rolling statistics held over the lifetime of a
// long-running run (the `serve` proxy and the `pressure` driver).
//
// Unlike `TimingCollection` (which a one-shot transfer/benchmark builds and
// then summarizes once), these stats accumulate continuously as traffic flows.
// The proxy updates them on every forwarded call and every mirrored call; the
// pressure driver updates them per op per path. A snapshot can be taken at any
// time to render a report or to emit the current state into the ObserverSink
// stats store.
//
// Concurrency: the proxy forwards calls serially on one reader loop, but the
// mirror fan-out and the pressure driver run concurrent Tasks, so the
// accumulator is an `actor`. Each update is a cheap append/increment; the lock
// granularity is one sample, which is well below the network/IPC latency the
// samples measure, so contention is not a concern.

/// A single named latency series accumulated over time, with running mean/p95.
/// Mirrors `TimingSeries` but lives inside the rolling actor and keeps a
/// bounded sample buffer so a multi-hour `serve` run does not grow unbounded.
struct RollingSeries: Sendable {
    /// The most recent samples, in seconds. Bounded to `cap`; once full, the
    /// oldest sample is dropped (a sliding window). p95 is computed over the
    /// retained window, which is the standing tail-latency the report wants.
    private(set) var samples: [Double] = []
    /// Total samples ever recorded (not just the retained window), so counts
    /// stay accurate even after the window slides.
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
    /// Same method as `TimingSeries.p95` so the two surfaces report on one scale.
    var p95: Double {
        guard !samples.isEmpty else { return 0.0 }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        let index = min(max(rank, 1) - 1, sorted.count - 1)
        return sorted[index]
    }
}

/// An immutable snapshot of one series for reporting / emission.
struct RollingSeriesSnapshot: Sendable {
    let label: String
    let mean: Double
    let p95: Double
    let totalCount: Int
}

/// An immutable snapshot of the whole rolling-stats actor.
struct RollingStatsSnapshot: Sendable {
    /// Per-label latency series (e.g. "primary.tools/call", "secondary.recall",
    /// or the four pressure paths "mootx01.read", "memory.write", …).
    let series: [RollingSeriesSnapshot]
    /// Per-divergence-axis aggregates over query/recall comparisons.
    let jaccardMean: Double
    let kendallRankMean: Double
    let divergenceSampleCount: Int
}

/// The rolling/standing statistics for a long-running benchmarker run.
///
/// Tracks an arbitrary set of named latency series plus the two divergence
/// axes (Jaccard set + normalized Kendall rank) accumulated across every
/// query/recall comparison. A snapshot can be rendered or emitted at any time.
actor RollingStats {
    private var series: [String: RollingSeries] = [:]
    private var jaccardSum: Double = 0
    private var kendallSum: Double = 0
    private var divergenceCount: Int = 0

    /// Records one latency sample (seconds) into the named series, creating the
    /// series on first use.
    func recordLatency(_ seconds: Double, label: String) {
        series[label, default: RollingSeries()].record(seconds)
    }

    /// Records one query/recall divergence comparison: Jaccard set divergence
    /// and normalized rank divergence between two result orderings.
    func recordDivergence(jaccard: Double, kendallRank: Double) {
        jaccardSum += jaccard
        kendallSum += kendallRank
        divergenceCount += 1
    }

    /// Takes an immutable snapshot of the current state. Series are emitted in
    /// sorted-label order for stable report/diff output.
    func snapshot() -> RollingStatsSnapshot {
        let seriesSnaps = series.keys.sorted().map { label -> RollingSeriesSnapshot in
            let s = series[label]!
            return RollingSeriesSnapshot(label: label, mean: s.mean, p95: s.p95,
                                         totalCount: s.totalCount)
        }
        let n = Double(max(divergenceCount, 1))
        return RollingStatsSnapshot(
            series: seriesSnaps,
            // Guard against divide-by-zero before any comparison has happened.
            jaccardMean: divergenceCount == 0 ? 0 : jaccardSum / n,
            kendallRankMean: divergenceCount == 0 ? 0 : kendallSum / n,
            divergenceSampleCount: divergenceCount
        )
    }
}

// MARK: - Rendering

extension RollingStatsSnapshot {
    /// Renders the snapshot as a human-readable block for stdout / the `report`
    /// subcommand. Latencies shown in milliseconds.
    func rendered(title: String) -> String {
        var out = "\(title)\n"
        for s in series {
            // Manual label padding — %@ does not honor a width flag on Darwin
            // Foundation, matching Report.swift's approach.
            let label = s.label.padding(toLength: 22, withPad: " ", startingAt: 0)
            out += String(format: "  %@ mean %8.2f ms   p95 %8.2f ms   n=%d\n",
                          label as NSString, s.mean * 1000, s.p95 * 1000, s.totalCount)
        }
        if divergenceSampleCount > 0 {
            out += String(format: "  divergence (n=%d):  jaccard set %.4f   kendall rank %.4f\n",
                          divergenceSampleCount, jaccardMean, kendallRankMean)
        }
        return out
    }
}
