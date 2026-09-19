import Testing
import Foundation
@testable import mcp_benchmarker

// RollingStatsTests.swift — tests for the rolling/standing-stats system.
//
// These tests exercise the internal RollingSeries sliding window and the
// public RollingStats actor. They live in the core test target because they
// access RollingSeries, which is internal to mcp_benchmarker. The public actor
// surface (RollingStats, RollingStatsSnapshot) is also used by out-of-package
// streaming callers; the math is exercised here for both.

struct RollingStatsTests {

    @Test("RollingSeries mean and nearest-rank p95 match the one-shot series")
    func seriesMeanP95() {
        var s = RollingSeries()
        for v in [0.010, 0.020, 0.030, 0.040, 0.100] { s.record(v) }
        #expect(s.totalCount == 5)
        #expect(abs(s.mean - 0.040) < 1e-9)
        // nearest-rank p95 of 5 samples → ceil(0.95*5)=5th → the max, 0.100.
        #expect(abs(s.p95 - 0.100) < 1e-9)
    }

    @Test("RollingSeries window slides but totalCount keeps the true count")
    func seriesWindowSlides() {
        var s = RollingSeries(cap: 3)
        for v in [1.0, 2.0, 3.0, 4.0, 5.0] { s.record(v) }
        // Window holds only the last 3 samples (3,4,5) → mean 4.0 …
        #expect(abs(s.mean - 4.0) < 1e-9)
        // … but totalCount reflects all 5 recorded.
        #expect(s.totalCount == 5)
    }

    @Test("RollingStats snapshot aggregates labelled series and divergence")
    func snapshotAggregates() async {
        let stats = RollingStats()
        await stats.recordLatency(0.010, label: "mootx01.read")
        await stats.recordLatency(0.030, label: "mootx01.read")
        await stats.recordLatency(0.050, label: "external-source.read")
        await stats.recordDivergence(jaccard: 0.2, kendallRank: 0.0)
        await stats.recordDivergence(jaccard: 0.4, kendallRank: 1.0)

        let snap = await stats.snapshot()
        // Series are emitted in sorted-label order.
        #expect(snap.series.map(\.label) == ["external-source.read", "mootx01.read"])
        let mootRead = snap.series.first { $0.label == "mootx01.read" }!
        #expect(abs(mootRead.mean - 0.020) < 1e-9)
        #expect(mootRead.totalCount == 2)
        // Divergence means: (0.2+0.4)/2 = 0.3 ; (0.0+1.0)/2 = 0.5.
        #expect(snap.divergenceSampleCount == 2)
        #expect(abs(snap.jaccardMean - 0.3) < 1e-9)
        #expect(abs(snap.kendallRankMean - 0.5) < 1e-9)
    }

    @Test("RollingStats snapshot is zero-safe before any divergence sample")
    func snapshotZeroSafe() async {
        let stats = RollingStats()
        await stats.recordLatency(0.01, label: "x")
        let snap = await stats.snapshot()
        #expect(snap.divergenceSampleCount == 0)
        #expect(snap.jaccardMean == 0.0)
        #expect(snap.kendallRankMean == 0.0)
    }
}
