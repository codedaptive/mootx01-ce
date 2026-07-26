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

    // "found 0" + nothing else → NOT degradedFallback (empty result is honest).
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
}
