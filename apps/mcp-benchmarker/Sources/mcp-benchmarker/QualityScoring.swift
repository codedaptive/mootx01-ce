import Foundation

// QualityScoring.swift — the pure scoring math for the `quality` benchmark.
//
// Every function here is deterministic and GPU-free: it takes a ranked list of
// corpus ids (what a product returned, best-first) plus the query's ground
// truth, and returns a number. No I/O, no live products, no Metal. This is the
// part the unit tests pin against hand-computed values; the live pipeline in
// QualityEngine only PRODUCES the ranked lists, it does not score.
//
// All ranked-list inputs are corpus ids (the ground-truth identity), already
// mapped from the product's own result ids by the engine. A product id that
// could not be mapped to a corpus id is dropped before scoring (it cannot be
// judged), which is the conservative choice — an unmappable hit never earns
// credit and never displaces a judged hit's rank, because the engine compacts
// the list before handing it here.

// MARK: - Graded relevance

/// The graded relevance of one result for one query, used by nDCG.
///
/// The fixture defines three relevance grades (see queries.json / README):
///   - the single `expectTargetId` is the canonical answer            → gain 2
///   - any `closeId` (same-cluster, graded-relevant) is partial credit → gain 1
///   - everything else (far / unjudged) is irrelevant                  → gain 0
///
/// Gains are the exponent-free linear gains DCG uses directly (2^gain - 1 with
/// these small integer grades would distort the 2-vs-1 ratio the fixture
/// intends, so the linear gain is used deliberately).
enum RelevanceGrade: Int, Sendable {
    case irrelevant = 0
    case close = 1
    case target = 2
}

/// The ground truth for one query: the single target id and the set of
/// graded-relevant close ids. Far/unjudged ids are anything not in either.
struct QueryTruth: Sendable {
    let targetId: String
    let closeIds: Set<String>

    /// The graded relevance of a single result id.
    func grade(of id: String) -> RelevanceGrade {
        if id == targetId { return .target }
        if closeIds.contains(id) { return .close }
        return .irrelevant
    }
}

// MARK: - Recall@k / Precision@k

/// recall@k: did the target appear within the top-k results?
///
/// There is exactly one target per query, so recall@k is binary (1 if the
/// target id is among the first k ranked results, else 0). Aggregated across
/// queries this becomes the fraction of queries whose target was recalled by
/// depth k — the standard "recall@k" for a single-relevant-item benchmark.
func recallAtK(ranked: [String], target: String, k: Int) -> Double {
    guard k > 0 else { return 0.0 }
    return ranked.prefix(k).contains(target) ? 1.0 : 0.0
}

/// precision@k: what fraction of the top-k results are relevant (target OR a
/// close id)? Denominator is k, not the number of results returned — a product
/// that returns fewer than k results is penalised for the empty slots, which is
/// the correct precision@k convention (precision is "of the k you'd show, how
/// many are good"). Far/unjudged ids count as not-relevant.
func precisionAtK(ranked: [String], truth: QueryTruth, k: Int) -> Double {
    guard k > 0 else { return 0.0 }
    let topK = ranked.prefix(k)
    let relevant = topK.filter { truth.grade(of: $0) != .irrelevant }.count
    return Double(relevant) / Double(k)
}

// MARK: - MRR

/// Reciprocal rank of the target for one query: 1 / (1-based rank of the
/// target), or 0 if the target is absent from the ranked list. The mean of
/// this across queries is MRR. First-position target → 1.0; second → 0.5; etc.
func reciprocalRank(ranked: [String], target: String) -> Double {
    guard let zeroBased = ranked.firstIndex(of: target) else { return 0.0 }
    return 1.0 / Double(zeroBased + 1)
}

// MARK: - nDCG

/// Discounted Cumulative Gain over the ranked list, with the standard log2
/// position discount: gain_i / log2(i + 1) for 1-based position i. Position 1
/// is undiscounted (log2(2) = 1).
private func dcg(grades: [RelevanceGrade]) -> Double {
    var sum = 0.0
    for (zeroBased, grade) in grades.enumerated() {
        let position = zeroBased + 1            // 1-based
        let discount = log2(Double(position) + 1.0)
        sum += Double(grade.rawValue) / discount
    }
    return sum
}

/// nDCG@k: DCG of the product's top-k ranking divided by the ideal DCG (the
/// same gains placed in the best possible order). 1.0 = the product placed the
/// most-relevant items in the most-prominent slots; 0.0 = no relevant item in
/// the top-k. The ideal ranking is: the one target (gain 2) first, then every
/// close id (gain 1), truncated to k — exactly the relevant items the query
/// declares, best-first.
func ndcgAtK(ranked: [String], truth: QueryTruth, k: Int) -> Double {
    guard k > 0 else { return 0.0 }

    // Actual DCG: grade the product's top-k in returned order.
    let actualGrades = ranked.prefix(k).map { truth.grade(of: $0) }
    let actual = dcg(grades: actualGrades)

    // Ideal DCG: the perfect ranking of THIS query's relevant items —
    // target (gain 2) then each close id (gain 1) — truncated to k.
    var idealGrades: [RelevanceGrade] = [.target]
    idealGrades.append(contentsOf: Array(repeating: .close, count: truth.closeIds.count))
    let ideal = dcg(grades: Array(idealGrades.prefix(k)))

    // ideal is 0 only if there are no relevant items at all, which cannot
    // happen here (every query has exactly one target). Guard anyway so a
    // degenerate truth yields 0 rather than NaN.
    guard ideal > 0 else { return 0.0 }
    return actual / ideal
}

// MARK: - Filter precision / recall

/// Precision and recall of a filter result against the known-correct id set.
///
/// A filter (mootx01 `userConfirmed`, or the contender's per-wing) is correct iff it
/// returns EXACTLY the expected corpus ids. Precision = |returned ∩ expected| /
/// |returned| (did it return only correct ids?); recall = |returned ∩ expected|
/// / |expected| (did it return all correct ids?). Sets, not ranks: a filter is
/// a membership predicate, order is irrelevant.
struct FilterScore: Sendable, Equatable {
    let precision: Double
    let recall: Double
    /// Harmonic mean of precision and recall; 0 when both are 0.
    let f1: Double
    let returnedCount: Int
    let expectedCount: Int
    let truePositives: Int
}

/// Scores one filter result. Empty `returned` with non-empty `expected` is
/// precision 1.0 (vacuously — nothing wrong was returned) but recall 0.0
/// (nothing right was returned either); F1 collapses to 0. Empty `expected`
/// with empty `returned` is a perfect (1,1) — there was nothing to find and
/// nothing was wrongly returned.
func scoreFilter(returned: Set<String>, expected: Set<String>) -> FilterScore {
    let truePositives = returned.intersection(expected).count

    // Precision denominator is what the filter returned; recall denominator is
    // what it should have found. The vacuous cases (empty denominator) resolve
    // to 1.0 — "no false positives" / "nothing to recall" — so a correctly
    // empty result scores perfectly rather than dividing by zero.
    let precision = returned.isEmpty ? (expected.isEmpty ? 1.0 : 1.0)
                                     : Double(truePositives) / Double(returned.count)
    let recall = expected.isEmpty ? 1.0
                                  : Double(truePositives) / Double(expected.count)

    let f1: Double
    if precision + recall > 0 {
        f1 = 2 * precision * recall / (precision + recall)
    } else {
        f1 = 0.0
    }

    return FilterScore(precision: precision,
                       recall: recall,
                       f1: f1,
                       returnedCount: returned.count,
                       expectedCount: expected.count,
                       truePositives: truePositives)
}

// MARK: - Aggregation

/// Aggregate retrieval metrics over many queries — every value is the mean of
/// the per-query value across the scored queries. The depths {1,5,10} are the
/// mission-specified recall/precision cut-offs; nDCG is reported at 10 (the
/// deepest cut, the most discriminating).
struct RetrievalMetrics: Sendable, Equatable {
    let queryCount: Int
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let mrr: Double
    let ndcgAt10: Double
    let precisionAt5: Double
    let precisionAt10: Double
}

/// One query's mapped ground truth plus the ranked corpus ids a product
/// returned for it. The engine builds these; aggregation is pure.
struct ScoredQuery: Sendable {
    let truth: QueryTruth
    let rankedCorpusIDs: [String]
}

/// Averages the per-query metrics into a single RetrievalMetrics. An empty
/// input yields an all-zero metrics with queryCount 0 (nothing to average).
func aggregateRetrieval(_ scored: [ScoredQuery]) -> RetrievalMetrics {
    guard !scored.isEmpty else {
        return RetrievalMetrics(queryCount: 0, recallAt1: 0, recallAt5: 0,
                                recallAt10: 0, mrr: 0, ndcgAt10: 0,
                                precisionAt5: 0, precisionAt10: 0)
    }
    let n = Double(scored.count)

    // Sum each per-query metric, then divide by the query count. Kept as one
    // pass over the queries so a large corpus is scored in O(queries × k).
    var r1 = 0.0, r5 = 0.0, r10 = 0.0, mrrSum = 0.0
    var ndcg = 0.0, p5 = 0.0, p10 = 0.0
    for q in scored {
        let ranked = q.rankedCorpusIDs
        let target = q.truth.targetId
        r1  += recallAtK(ranked: ranked, target: target, k: 1)
        r5  += recallAtK(ranked: ranked, target: target, k: 5)
        r10 += recallAtK(ranked: ranked, target: target, k: 10)
        mrrSum += reciprocalRank(ranked: ranked, target: target)
        ndcg += ndcgAtK(ranked: ranked, truth: q.truth, k: 10)
        p5  += precisionAtK(ranked: ranked, truth: q.truth, k: 5)
        p10 += precisionAtK(ranked: ranked, truth: q.truth, k: 10)
    }

    return RetrievalMetrics(queryCount: scored.count,
                            recallAt1: r1 / n,
                            recallAt5: r5 / n,
                            recallAt10: r10 / n,
                            mrr: mrrSum / n,
                            ndcgAt10: ndcg / n,
                            precisionAt5: p5 / n,
                            precisionAt10: p10 / n)
}
