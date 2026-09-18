import Testing
import Foundation
@testable import mcp_benchmarker

// DegeneracyGuardTests.swift — tests for the DegeneracyGuard pure scorer.
//
// The guard is a pure, deterministic scorer fed already-fetched responses.
// No live server is needed. These tests cover the four Verdict cases the
// mission spec (SPEC §9) requires. DegeneracyGuard.swift is implemented.

@Suite struct DegeneracyGuardTests {

    // MARK: - query-invariance (classify)

    // Three distinct queries → identical rankings (same 3 items in same order).
    // Jaccard + rank divergence ≈ 0 across all pairs → .queryInvariant.
    @Test("Identical rankings across 3 distinct probes → queryInvariant")
    func identicalRankingsAcrossThreeProbesIsQueryInvariant() {
        let guard_ = DegeneracyGuard()
        let frozenRanking = ["id-a", "id-b", "id-c", "id-d"]
        // Three probe queries all returned the same frozen ranking.
        let probeRankings = [frozenRanking, frozenRanking, frozenRanking]
        let verdict = guard_.classify(probeRankings: probeRankings)
        if case .queryInvariant = verdict {
            // correct
        } else {
            Issue.record("expected .queryInvariant, got \(verdict)")
        }
    }

    // Three distinct probes → three meaningfully distinct rankings.
    // Pairwise Jaccard/rank divergence should be well above the ≈0 threshold.
    // → .healthy
    @Test("Distinct rankings across 3 probes → healthy")
    func distinctRankingsAreHealthy() {
        let guard_ = DegeneracyGuard()
        let probeRankings = [
            ["apple", "banana", "cherry", "date"],
            ["date", "cherry", "elderberry", "fig"],
            ["grape", "honeydew", "apple", "kiwi"],
        ]
        let verdict = guard_.classify(probeRankings: probeRankings)
        if case .healthy = verdict {
            // correct
        } else {
            Issue.record("expected .healthy, got \(verdict)")
        }
    }

    // Fewer than 2 probe rankings → cannot detect invariance; treat as healthy.
    @Test("Fewer than 2 probe rankings → healthy (cannot detect invariance)")
    func fewerThanTwoProbesIsHealthy() {
        let guard_ = DegeneracyGuard()
        let verdict = guard_.classify(probeRankings: [["id-a", "id-b"]])
        if case .healthy = verdict {
            // correct
        } else {
            Issue.record("expected .healthy for single probe, got \(verdict)")
        }
    }

    // Empty probe set → healthy (no evidence of invariance).
    @Test("Empty probe rankings → healthy")
    func emptyProbeRankingsIsHealthy() {
        let guard_ = DegeneracyGuard()
        let verdict = guard_.classify(probeRankings: [])
        if case .healthy = verdict {
            // correct
        } else {
            Issue.record("expected .healthy for empty probes, got \(verdict)")
        }
    }

    // MARK: - degraded fallback (checkFallback)

    // "found N" + "no results" co-present in text blocks → degradedFallback signal.
    @Test("found-N + no-results hint co-present → checkFallback returns true")
    func foundNAndNoResultsIsDegradedFallback() {
        let guard_ = DegeneracyGuard()
        // The exact FINDINGS pattern: server says it found N but signals no results.
        let blocks = ["found 4 memory(s)", "hint: No results matched your query."]
        #expect(guard_.checkFallback(textBlocks: blocks) == true)
    }

    // "found 0" + nothing else → NOT degradedFallback (a truthful empty result).
    @Test("found-0 alone is not a degraded fallback")
    func foundZeroAloneIsNotFallback() {
        let guard_ = DegeneracyGuard()
        let blocks = ["found 0 memory(s)"]
        #expect(guard_.checkFallback(textBlocks: blocks) == false)
    }

    // Clean result with a found count and actual content → NOT degradedFallback.
    @Test("Normal result block is not a degraded fallback")
    func normalResultIsNotFallback() {
        let guard_ = DegeneracyGuard()
        let blocks = ["found 3 memory(s)", "abc-123  [location]  some content here"]
        #expect(guard_.checkFallback(textBlocks: blocks) == false)
    }

    // MARK: - confirmation contradiction (checkConfirmation)

    // confirmedCount=0 with recall ≈ 1.0 (N=5, total=5) → contradiction.
    @Test("confirmedCount 0 with recall 1.0 → checkConfirmation returns true")
    func confirmedZeroWithPerfectRecallIsContradiction() {
        let guard_ = DegeneracyGuard()
        #expect(guard_.checkConfirmation(confirmedCount: 0, total: 5, recall: 1.0) == true)
    }

    // confirmedCount matches total → no contradiction.
    @Test("confirmedCount == total with high recall → no contradiction")
    func confirmedEqualsTotal() {
        let guard_ = DegeneracyGuard()
        #expect(guard_.checkConfirmation(confirmedCount: 5, total: 5, recall: 0.95) == false)
    }

    // confirmedCount=0 with recall=0 → not a contradiction (nothing was confirmed,
    // nothing recalled — consistent).
    @Test("confirmedCount 0 with recall 0 → no contradiction")
    func confirmedZeroWithZeroRecall() {
        let guard_ = DegeneracyGuard()
        #expect(guard_.checkConfirmation(confirmedCount: 0, total: 5, recall: 0.0) == false)
    }

    // total=0 → not a contradiction (no data to contradict).
    @Test("total 0 → no contradiction")
    func totalZeroIsNotContradiction() {
        let guard_ = DegeneracyGuard()
        #expect(guard_.checkConfirmation(confirmedCount: 0, total: 0, recall: 0.0) == false)
    }

    // MARK: - Verdict diagnostic strings

    // Every verdict case carries a non-empty human diagnostic string.
    @Test("All Verdict cases carry a non-empty diagnostic string")
    func verdictDiagnosticStrings() {
        // Construct each case directly so we do not depend on the guard's logic here.
        let cases: [DegeneracyGuard.Verdict] = [
            .healthy,
            .queryInvariant(diagnostic: "backend returned identical rankings for all probes"),
            .degradedFallback(diagnostic: "found N but no-results hint present"),
            .confirmationContradiction(diagnostic: "confirmed 0/5 but recall is 1.0"),
        ]
        for v in cases {
            #expect(!v.diagnostic.isEmpty, "verdict \(v) has empty diagnostic")
        }
    }

    // MARK: - LegGuardSampler — sampling policy

    // Default .oncePerLeg: the prober closure is called exactly once regardless
    // of how many units call probe(using:).
    @Test("oncePerLeg: prober called exactly once across N units")
    func oncePerLegProbesOnce() async {
        let sampler = LegGuardSampler(policy: .oncePerLeg)
        // nonisolated(unsafe) is safe here: callCount is mutated only inside
        // sequential awaited probe calls and read after the loop completes —
        // no two accesses ever race.
        nonisolated(unsafe) var callCount = 0

        // Simulate 5 units (questions/items) calling probe.
        for _ in 0..<5 {
            _ = await sampler.probe {
                callCount += 1
                // Return distinct rankings so the guard sees a healthy backend.
                return [
                    ["apple", "banana", "cherry"],
                    ["date", "elderberry", "fig"],
                    ["grape", "honeydew", "kiwi"],
                ]
            }
        }

        // The prober closure must have been called exactly once — the first unit.
        // All subsequent units reuse the cached verdict without issuing MCP calls.
        #expect(callCount == 1, "prober called \(callCount) times; expected exactly 1 (oncePerLeg)")
    }

    // .perUnit opt-in: the prober closure is called for every unit.
    @Test("perUnit: prober called for every unit")
    func perUnitProbesEveryUnit() async {
        let sampler = LegGuardSampler(policy: .perUnit)
        // nonisolated(unsafe) is safe here: callCount is mutated only inside
        // sequential awaited probe calls and read after the loop completes —
        // no two accesses ever race.
        nonisolated(unsafe) var callCount = 0
        let unitCount = 4

        for _ in 0..<unitCount {
            _ = await sampler.probe {
                callCount += 1
                return [
                    ["a", "b", "c"],
                    ["d", "e", "f"],
                    ["g", "h", "i"],
                ]
            }
        }

        #expect(callCount == unitCount,
            "prober called \(callCount) times; expected \(unitCount) (perUnit)")
    }

    // A guard refusal (.queryInvariant) on the first unit is cached and
    // returned to all subsequent units — the leg fails loudly across its full
    // result set, not just the first item.
    @Test("Refusal verdict from first probe propagates to all subsequent units")
    func refusalPropagatesAcrossLeg() async {
        let sampler = LegGuardSampler(policy: .oncePerLeg)
        let frozenRanking = ["x", "y", "z"]

        // First probe: returns frozen rankings → guard issues .queryInvariant.
        let (firstVerdict, wasProbed1) = await sampler.probe {
            // All three probe queries return the identical frozen ranking.
            return [frozenRanking, frozenRanking, frozenRanking]
        }

        // Subsequent probes: prober closure must NOT be called (wasProbed == false).
        let (secondVerdict, wasProbed2) = await sampler.probe {
            return [["should", "not", "be", "called"]]
        }
        let (thirdVerdict, wasProbed3) = await sampler.probe {
            return [["should", "not", "be", "called"]]
        }

        // First probe was a real call.
        #expect(wasProbed1 == true, "first probe must have executed the prober")

        // Subsequent probes returned the cached verdict without calling the prober.
        #expect(wasProbed2 == false, "second probe must use cached verdict (wasProbed == false)")
        #expect(wasProbed3 == false, "third probe must use cached verdict (wasProbed == false)")

        // All verdicts must be .queryInvariant — the refusal propagates.
        for (idx, verdict) in [firstVerdict, secondVerdict, thirdVerdict].enumerated() {
            if case .queryInvariant = verdict {
                // correct
            } else {
                Issue.record(
                    "unit \(idx): expected .queryInvariant (refusal propagation), got \(verdict)")
            }
        }
    }
}
