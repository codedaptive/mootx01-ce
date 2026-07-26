import Testing
import Foundation
@testable import mcp_benchmarker

// QualityScoringTests.swift — Swift Testing coverage for the `quality`
// benchmark's pure scoring math. Every expected value is HAND-COMPUTED from
// the metric definition (no live products, no GPU). These pin the math the
// live head-to-head depends on.

// MARK: - Recall@k

@Suite struct RecallAtKTests {

    // Target at rank 1 → recall@{1,5,10} all 1.
    @Test func targetAtRankOne() {
        let ranked = ["t", "a", "b"]
        #expect(recallAtK(ranked: ranked, target: "t", k: 1) == 1.0)
        #expect(recallAtK(ranked: ranked, target: "t", k: 5) == 1.0)
        #expect(recallAtK(ranked: ranked, target: "t", k: 10) == 1.0)
    }

    // Target at rank 3 → recall@1 = 0, recall@5 = 1, recall@10 = 1.
    @Test func targetAtRankThree() {
        let ranked = ["a", "b", "t", "c"]
        #expect(recallAtK(ranked: ranked, target: "t", k: 1) == 0.0)
        #expect(recallAtK(ranked: ranked, target: "t", k: 5) == 1.0)
        #expect(recallAtK(ranked: ranked, target: "t", k: 10) == 1.0)
    }

    // Target absent → 0 at every depth.
    @Test func targetAbsent() {
        let ranked = ["a", "b", "c"]
        #expect(recallAtK(ranked: ranked, target: "t", k: 1) == 0.0)
        #expect(recallAtK(ranked: ranked, target: "t", k: 10) == 0.0)
    }

    // Target at exactly rank k is inside the cut; at k+1 it is not.
    @Test func boundaryAtK() {
        let ranked = ["a", "b", "c", "d", "t"]  // t at rank 5
        #expect(recallAtK(ranked: ranked, target: "t", k: 5) == 1.0)
        #expect(recallAtK(ranked: ranked, target: "t", k: 4) == 0.0)
    }
}

// MARK: - Precision@k

@Suite struct PrecisionAtKTests {

    // top-5 = [target, close, far, far, far]; relevant = 2 (target + close);
    // precision@5 = 2/5 = 0.4.
    @Test func mixedTopFive() {
        let truth = QueryTruth(targetId: "t", closeIds: ["c1", "c2"])
        let ranked = ["t", "c1", "f1", "f2", "f3"]
        #expect(abs(precisionAtK(ranked: ranked, truth: truth, k: 5) - 0.4) < 1e-12)
    }

    // Fewer than k results: empty slots count against precision. top-10 has 3
    // relevant of a possible 10 → 3/10 = 0.3, NOT 3/3.
    @Test func shortListPenalisedByDenominatorK() {
        let truth = QueryTruth(targetId: "t", closeIds: ["c1", "c2", "c3"])
        let ranked = ["t", "c1", "c2"]  // only 3 results, all relevant
        #expect(abs(precisionAtK(ranked: ranked, truth: truth, k: 10) - 0.3) < 1e-12)
    }

    // All far → precision 0.
    @Test func allIrrelevant() {
        let truth = QueryTruth(targetId: "t", closeIds: ["c1"])
        let ranked = ["f1", "f2", "f3"]
        #expect(precisionAtK(ranked: ranked, truth: truth, k: 5) == 0.0)
    }
}

// MARK: - Reciprocal rank / MRR

@Suite struct ReciprocalRankTests {

    @Test func rankOneIsOne() {
        #expect(reciprocalRank(ranked: ["t", "a"], target: "t") == 1.0)
    }

    @Test func rankTwoIsHalf() {
        #expect(reciprocalRank(ranked: ["a", "t"], target: "t") == 0.5)
    }

    @Test func rankFourIsQuarter() {
        #expect(abs(reciprocalRank(ranked: ["a", "b", "c", "t"], target: "t") - 0.25) < 1e-12)
    }

    @Test func absentIsZero() {
        #expect(reciprocalRank(ranked: ["a", "b"], target: "t") == 0.0)
    }

    // MRR is the mean of reciprocal ranks: ranks 1 and 3 → (1 + 1/3)/2 = 2/3.
    @Test func mrrMeanAcrossTwoQueries() {
        let q1 = ScoredQuery(truth: QueryTruth(targetId: "t", closeIds: []),
                             rankedCorpusIDs: ["t", "a"])           // RR = 1
        let q2 = ScoredQuery(truth: QueryTruth(targetId: "t", closeIds: []),
                             rankedCorpusIDs: ["a", "b", "t"])      // RR = 1/3
        let m = aggregateRetrieval([q1, q2])
        #expect(abs(m.mrr - (2.0 / 3.0)) < 1e-12)
    }
}

// MARK: - nDCG

@Suite struct NDCGTests {

    // Perfect ranking: target then close then far. Actual == ideal → 1.0.
    @Test func perfectRankingIsOne() {
        let truth = QueryTruth(targetId: "t", closeIds: ["c1"])
        let ranked = ["t", "c1", "f1"]
        #expect(abs(ndcgAtK(ranked: ranked, truth: truth, k: 10) - 1.0) < 1e-12)
    }

    // Hand-computed swap case. truth: target t (gain 2), one close c (gain 1).
    // Ranked = [c, t, f]:
    //   actual DCG = 1/log2(2) + 2/log2(3) = 1.0 + 2/1.5849625 = 1.0 + 1.261859 = 2.261859
    //   ideal DCG  = 2/log2(2) + 1/log2(3) = 2.0 + 0.630930          = 2.630930
    //   nDCG = 2.261859 / 2.630930 = 0.859727...
    @Test func swappedTargetAndCloseHandComputed() {
        let truth = QueryTruth(targetId: "t", closeIds: ["c"])
        let ranked = ["c", "t", "f"]
        let actual = 1.0 / log2(2.0) + 2.0 / log2(3.0)
        let ideal  = 2.0 / log2(2.0) + 1.0 / log2(3.0)
        let expected = actual / ideal
        #expect(abs(ndcgAtK(ranked: ranked, truth: truth, k: 10) - expected) < 1e-12)
        // Sanity: this expected lands near 0.8597.
        #expect(abs(expected - 0.859727) < 1e-5)
    }

    // No relevant item in the top-k → 0.
    @Test func noRelevantInTopKIsZero() {
        let truth = QueryTruth(targetId: "t", closeIds: ["c"])
        let ranked = ["f1", "f2", "f3"]
        #expect(ndcgAtK(ranked: ranked, truth: truth, k: 10) == 0.0)
    }

    // Target present but only at a deep rank beyond k → 0 within the cut.
    @Test func targetBeyondCutIsZero() {
        let truth = QueryTruth(targetId: "t", closeIds: [])
        let ranked = ["f1", "f2", "f3", "f4", "f5", "t"]  // t at rank 6
        #expect(ndcgAtK(ranked: ranked, truth: truth, k: 5) == 0.0)
    }
}

// MARK: - Filter precision / recall

@Suite struct FilterScoreTests {

    // Exact match → precision 1, recall 1, f1 1.
    @Test func exactMatch() {
        let s = scoreFilter(returned: ["a", "b", "c"], expected: ["a", "b", "c"])
        #expect(s.precision == 1.0)
        #expect(s.recall == 1.0)
        #expect(s.f1 == 1.0)
        #expect(s.truePositives == 3)
    }

    // Over-returns one wrong id: returned {a,b,c,x}, expected {a,b,c}.
    //   precision = 3/4 = 0.75; recall = 3/3 = 1.0; f1 = 2*0.75*1/(1.75)=0.857142...
    @Test func falsePositiveLowersPrecision() {
        let s = scoreFilter(returned: ["a", "b", "c", "x"], expected: ["a", "b", "c"])
        #expect(abs(s.precision - 0.75) < 1e-12)
        #expect(s.recall == 1.0)
        #expect(abs(s.f1 - (2 * 0.75 * 1.0 / 1.75)) < 1e-12)
    }

    // Misses one: returned {a,b}, expected {a,b,c}.
    //   precision = 2/2 = 1.0; recall = 2/3 = 0.6667
    @Test func falseNegativeLowersRecall() {
        let s = scoreFilter(returned: ["a", "b"], expected: ["a", "b", "c"])
        #expect(s.precision == 1.0)
        #expect(abs(s.recall - (2.0 / 3.0)) < 1e-12)
    }

    // Empty returned, non-empty expected: precision vacuously 1, recall 0, f1 0.
    @Test func emptyReturnedAgainstExpected() {
        let s = scoreFilter(returned: [], expected: ["a", "b"])
        #expect(s.precision == 1.0)
        #expect(s.recall == 0.0)
        #expect(s.f1 == 0.0)
    }

    // Both empty → perfect (nothing to find, nothing wrongly returned).
    @Test func bothEmptyIsPerfect() {
        let s = scoreFilter(returned: [], expected: [])
        #expect(s.precision == 1.0)
        #expect(s.recall == 1.0)
        #expect(s.f1 == 1.0)
    }
}

// MARK: - Aggregation

@Suite struct AggregateRetrievalTests {

    // Empty input → all zeros, queryCount 0.
    @Test func emptyAggregate() {
        let m = aggregateRetrieval([])
        #expect(m.queryCount == 0)
        #expect(m.recallAt1 == 0.0)
        #expect(m.mrr == 0.0)
        #expect(m.ndcgAt10 == 0.0)
    }

    // Two queries, recall@1: one hits (target rank 1), one misses (target rank 3).
    // mean recall@1 = (1 + 0)/2 = 0.5; recall@5 = (1+1)/2 = 1.0.
    @Test func meanRecallAcrossTwo() {
        let q1 = ScoredQuery(truth: QueryTruth(targetId: "t", closeIds: []),
                             rankedCorpusIDs: ["t", "a", "b"])
        let q2 = ScoredQuery(truth: QueryTruth(targetId: "t", closeIds: []),
                             rankedCorpusIDs: ["a", "b", "t"])
        let m = aggregateRetrieval([q1, q2])
        #expect(m.queryCount == 2)
        #expect(abs(m.recallAt1 - 0.5) < 1e-12)
        #expect(abs(m.recallAt5 - 1.0) < 1e-12)
    }
}
