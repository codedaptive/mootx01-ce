import Foundation

// Timing.swift — the three named timing series and their aggregation.
//
// The benchmarker measures three distinct latencies, named per the mission
// spec, and keeps them independent so a slow write path cannot be masked by
// a fast query path in the aggregate.

/// The latencies the benchmarker measures, named per the mission spec.
enum TimingSeriesKind: String, Sendable, CaseIterable {
    case capture        // time to write one entry to the target
    case recall         // time to query the target
    case verification   // time to confirm a manifest entry is present + ranked
    case sourceRecall   // time to query the source (head-to-head, --compare-source only)
}

/// A single latency series with mean and p95 over recorded samples.
struct TimingSeries: Sendable {
    private(set) var samples: [Double] = []

    /// Records one sample, in seconds.
    mutating func record(_ seconds: Double) {
        samples.append(seconds)
    }

    /// Number of recorded samples.
    var count: Int { samples.count }

    /// Arithmetic mean of recorded samples, or 0 when empty.
    var mean: Double {
        guard !samples.isEmpty else { return 0.0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// 95th-percentile sample, or 0 when empty. Nearest-rank method: the
    /// ceil(0.95 * N)-th sample (1-indexed) of the sorted samples. Chosen
    /// over interpolation because it always returns an actually-observed
    /// latency, which is what a tail-latency report should show.
    var p95: Double {
        guard !samples.isEmpty else { return 0.0 }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        let index = min(max(rank, 1) - 1, sorted.count - 1)
        return sorted[index]
    }
}

/// Holds the three named series and routes samples to the right one.
struct TimingCollection: Sendable {
    private var store: [TimingSeriesKind: TimingSeries]

    init() {
        // Pre-seed all three kinds so an unrecorded kind reads as a present,
        // empty series rather than a missing one.
        store = Dictionary(uniqueKeysWithValues: TimingSeriesKind.allCases.map { ($0, TimingSeries()) })
    }

    /// Records one sample into the named series.
    mutating func record(_ seconds: Double, into kind: TimingSeriesKind) {
        store[kind, default: TimingSeries()].record(seconds)
    }

    /// The series for a kind. An untouched kind reads as an empty series.
    func series(_ kind: TimingSeriesKind) -> TimingSeries {
        store[kind] ?? TimingSeries()
    }
}
