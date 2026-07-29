import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletReportTests — aggregation + the definition-of-superior verdict logic
// (Phase 2.2), against synthetic per-needle scores. Pure: no live backend.

@Suite("Gauntlet report")
struct GauntletReportTests {

    private let kValues = [1, 5, 10]

    private func score(needle: String, tier: NoiseTier, rank: Int?, complete: Double,
                       contam: Int, latency: Double) -> NeedleScore {
        var found: [Int: Bool] = [:]
        for k in kValues { found[k] = (rank.map { $0 <= k }) ?? false }
        return NeedleScore(needleID: needle, tier: tier, foundAtK: found, rank: rank,
                           completeness: complete, contamination: contam,
                           latencySeconds: latency, bytesReturned: 100)
    }

    @Test("aggregate computes mean found@k, MRR, completeness, contamination")
    func aggregateMath() {
        let scores = [
            score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.01),
            score(needle: "b", tier: .lexical, rank: 5, complete: 0.0, contam: 2, latency: 0.03),
        ]
        let agg = StrategyTierAggregate.from(tier: .lexical, scores: scores, kValues: kValues)
        #expect(agg.needleCount == 2)
        #expect(agg.foundAtK[1] == 0.5)        // one of two at rank 1
        #expect(agg.foundAtK[5] == 1.0)        // both within 5
        #expect(abs(agg.mrr - (1.0 + 0.2) / 2) < 1e-9)
        #expect(agg.completeness == 0.5)
        #expect(agg.meanContamination == 1.0)
    }

    @Test("superiority MET: mootx01 ties/wins every tier and is strictly less contaminated")
    func superiorityMet() {
        let report = buildReport(
            contender: [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 3, latency: 0.05)],
            mootRaw:   [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)],
            mootRrf:   [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)],
            mootMatrix:[score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)])
        #expect(report.superiorityVerdict().contains("MET"))
        #expect(!report.superiorityVerdict().contains("NOT MET"))
    }

    @Test("superiority NOT MET: mootx01 loses a tier on found@k")
    func superiorityLostTier() {
        let report = buildReport(
            contender: [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.05)],
            mootRaw:   [score(needle: "a", tier: .lexical, rank: 3, complete: 1.0, contam: 0, latency: 0.01)],
            mootRrf:   [score(needle: "a", tier: .lexical, rank: 3, complete: 1.0, contam: 0, latency: 0.01)],
            mootMatrix:[score(needle: "a", tier: .lexical, rank: 3, complete: 1.0, contam: 0, latency: 0.01)])
        // contender found@1=1.0, mootx01 found@1=0.0 → mootx01 loses tier T1.
        #expect(report.superiorityVerdict().contains("NOT MET"))
        #expect(report.superiorityVerdict().contains("T1"))
    }

    @Test("superiority NOT MET: ties every tier but no strict edge on contam or latency")
    func superiorityNoEdge() {
        let report = buildReport(
            contender: [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)],
            mootRaw:   [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)],
            mootRrf:   [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)],
            mootMatrix:[score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 1, latency: 0.05)])
        let verdict = report.superiorityVerdict()
        #expect(verdict.contains("NOT MET"))
        #expect(verdict.contains("not strictly better"))
    }

    @Test("definition-of-superior text appears verbatim in the rendered header")
    func definitionVerbatim() {
        let report = buildReport(
            contender: [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.05)],
            mootRaw:   [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.05)],
            mootRrf:   [score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.05)],
            mootMatrix:[score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.05)])
        #expect(report.rendered().contains(GauntletRunReport.definitionOfSuperior))
    }

    // MARK: - helper

    private func buildReport(contender: [NeedleScore], mootRaw: [NeedleScore],
                             mootRrf: [NeedleScore], mootMatrix: [NeedleScore]) -> GauntletRunReport {
        let strategies = [
            StrategyResult.build(name: "contender", isMootx01: false, scores: contender, kValues: kValues),
            StrategyResult.build(name: "mootx01:raw", isMootx01: true, scores: mootRaw, kValues: kValues),
            StrategyResult.build(name: "mootx01:rrf", isMootx01: true, scores: mootRrf, kValues: kValues),
            StrategyResult.build(name: "mootx01:matrixAware", isMootx01: true, scores: mootMatrix, kValues: kValues),
        ]
        return GauntletRunReport(seed: 1, runLabel: "test", kValues: kValues,
                                 distractorsPerNeedle: 1, tierCounts: [.lexical: 1],
                                 strategies: strategies, worstFailures: [], guardHealthy: true)
    }
}
