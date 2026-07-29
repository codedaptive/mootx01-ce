import Testing
import Foundation
@testable import mcp_benchmarker

// ProxyDivergenceTests.swift — tests for the ProxyRunReport.
//
// The proxy run-report assembles a head-to-head summary at session end:
// latency series per backend, Jaccard/Kendall divergence summary, secondary-
// failure count, and worst-diverging tail with both rankings retained.
// ProxyRunReport is implemented.

@Suite struct ProxyDivergenceTests {

    // MARK: - ProxyRunReport structure

    // A fresh (zero-sample) ProxyRunReport reports sane zero values.
    @Test("Fresh ProxyRunReport has zero secondary failures and no worst tail")
    func freshReportIsZero() {
        let report = ProxyRunReport(
            primaryLatencySeries: [],
            secondaryLatencySeries: [],
            jaccardMean: 0.0,
            kendallRankMean: 0.0,
            divergenceSampleCount: 0,
            secondaryFailureCount: 0,
            worstDivergingTail: nil
        )
        #expect(report.secondaryFailureCount == 0)
        #expect(report.divergenceSampleCount == 0)
        #expect(report.worstDivergingTail == nil)
    }

    // Secondary failure count is carried into the report accurately.
    @Test("ProxyRunReport carries the secondary failure count")
    func secondaryFailureCountIsAccurate() {
        let report = ProxyRunReport(
            primaryLatencySeries: [0.010, 0.015, 0.012],
            secondaryLatencySeries: [0.020, 0.025],
            jaccardMean: 0.1,
            kendallRankMean: 0.05,
            divergenceSampleCount: 2,
            secondaryFailureCount: 3,
            worstDivergingTail: nil
        )
        #expect(report.secondaryFailureCount == 3)
        #expect(report.divergenceSampleCount == 2)
    }

    // The worst-diverging tail holds both rankings when present.
    @Test("ProxyRunReport worst-diverging tail holds both rankings")
    func worstTailHoldsBothRankings() {
        let tail = ProxyRunReport.DivergingTail(
            jaccardDivergence: 0.75,
            primaryRanking: ["alpha", "beta", "gamma"],
            secondaryRanking: ["delta", "epsilon", "alpha"]
        )
        let report = ProxyRunReport(
            primaryLatencySeries: [0.010],
            secondaryLatencySeries: [0.020],
            jaccardMean: 0.75,
            kendallRankMean: 0.5,
            divergenceSampleCount: 1,
            secondaryFailureCount: 0,
            worstDivergingTail: tail
        )
        #expect(report.worstDivergingTail != nil)
        #expect(report.worstDivergingTail?.primaryRanking == ["alpha", "beta", "gamma"])
        #expect(report.worstDivergingTail?.secondaryRanking == ["delta", "epsilon", "alpha"])
        #expect(abs(report.worstDivergingTail!.jaccardDivergence - 0.75) < 1e-12)
    }

    // MARK: - Rendered output

    // The report renders to a non-empty string (human-readable block for stderr).
    @Test("ProxyRunReport renders to a non-empty string")
    func reportRendersToString() {
        let report = ProxyRunReport(
            primaryLatencySeries: [0.010, 0.020],
            secondaryLatencySeries: [0.030, 0.040],
            jaccardMean: 0.25,
            kendallRankMean: 0.10,
            divergenceSampleCount: 2,
            secondaryFailureCount: 1,
            worstDivergingTail: ProxyRunReport.DivergingTail(
                jaccardDivergence: 0.5,
                primaryRanking: ["a", "b"],
                secondaryRanking: ["c", "d"]
            )
        )
        let text = report.rendered(primaryName: "mootx01", secondaryName: "contender")
        #expect(!text.isEmpty)
        // The rendered output must mention the failure count somewhere.
        #expect(text.contains("1"))
    }
}
