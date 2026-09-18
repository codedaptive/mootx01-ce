import Testing
import Foundation
@testable import mcp_benchmarker

// MemBenchSpecScorerTests.swift — Unit tests for MemBenchSpecScorer.
//
// Verifies:
//   1. §3 letter-parse helpers (strict path and fallback normalization).
//   2. §3 answerCorrect: exact string equality.
//   3. §4 getRecall: nil/None → 0, deduplication, duplicate targets, partial overlap.
//   4. Aggregation: overall, per-category (canonical ordering), per-perspective.
//   5. §5 efficiency stats: count/mean/p50/p95 via lmePercentile convention.
//   6. §6 capacity bucketing: range assignment, open-ended last bucket.
//   7. Conformance-vector agreement with scorer_vectors.json.

@Suite("MemBenchSpec §3 letter parsing")
struct MemBenchSpecLetterParseTests {

    // MARK: - Strict path

    @Test("strict: valid letters A-D returned unchanged")
    func strictValidLetters() {
        #expect(membenchSpecParseLetterStrict("A") == "A")
        #expect(membenchSpecParseLetterStrict("B") == "B")
        #expect(membenchSpecParseLetterStrict("C") == "C")
        #expect(membenchSpecParseLetterStrict("D") == "D")
    }

    @Test("strict: letter with trailing space returns nil")
    func strictLetterWithSpaceNil() {
        // Strict path does not strip spaces — that is the fallback's job (§3).
        #expect(membenchSpecParseLetterStrict("A ") == nil)
    }

    @Test("strict: lowercase returns nil")
    func strictLowercaseNil() {
        #expect(membenchSpecParseLetterStrict("a") == nil)
    }

    @Test("strict: empty string returns nil")
    func strictEmptyNil() {
        #expect(membenchSpecParseLetterStrict("") == nil)
    }

    @Test("strict: multi-character string returns nil")
    func strictMultiCharNil() {
        #expect(membenchSpecParseLetterStrict("AB") == nil)
        #expect(membenchSpecParseLetterStrict("E") == nil)
    }

    // MARK: - Fallback normalization path

    @Test("fallback: spaces stripped before validation")
    func fallbackSpaces() {
        // §3: s.replace(" ","").replace("\n","")
        #expect(membenchSpecParseLetterFallback(" A ") == "A")
        #expect(membenchSpecParseLetterFallback("  B  ") == "B")
    }

    @Test("fallback: newlines stripped before validation")
    func fallbackNewlines() {
        #expect(membenchSpecParseLetterFallback("A\n") == "A")
        #expect(membenchSpecParseLetterFallback("\nC\n") == "C")
    }

    @Test("fallback: no remaining characters after strip → nil")
    func fallbackOnlyWhitespaceNil() {
        #expect(membenchSpecParseLetterFallback("   ") == nil)
    }

    @Test("fallback: two non-space letters after strip → nil (not a single-letter A-D)")
    func fallbackMultiLetterAfterStripNil() {
        // "C D" → strip spaces → "CD" → not valid → nil
        #expect(membenchSpecParseLetterFallback("C D") == nil)
    }
}

// MARK: -

@Suite("MemBenchSpec §3 answer correctness")
struct MemBenchSpecAnswerCorrectTests {

    @Test("exact match returns true")
    func exactMatch() {
        #expect(membenchSpecAnswerCorrect(response: "A", groundTruth: "A") == true)
        #expect(membenchSpecAnswerCorrect(response: "D", groundTruth: "D") == true)
    }

    @Test("mismatch returns false")
    func mismatch() {
        #expect(membenchSpecAnswerCorrect(response: "A", groundTruth: "B") == false)
        #expect(membenchSpecAnswerCorrect(response: "C", groundTruth: "D") == false)
    }

    @Test("case-sensitive: lowercase does not match uppercase")
    func caseSensitive() {
        // §3 is plain string equality — case matters.
        #expect(membenchSpecAnswerCorrect(response: "a", groundTruth: "A") == false)
    }
}

// MARK: -

@Suite("MemBenchSpec §4 get_recall")
struct MemBenchSpecGetRecallTests {

    @Test("nil retrieved returns 0 (§4: if res == None: return 0)")
    func nilRetrievedReturnsZero() {
        let r = membenchSpecGetRecall(retrievedStepIDs: nil, targetStepIDs: [1, 2])
        #expect(abs(r - 0.0) < 1e-9, "nil → 0.0")
    }

    @Test("empty retrieved (non-nil) returns 0")
    func emptyRetrievedReturnsZero() {
        let r = membenchSpecGetRecall(retrievedStepIDs: [], targetStepIDs: [1, 2])
        #expect(abs(r - 0.0) < 1e-9, "empty retrieved → 0.0")
    }

    @Test("duplicates in retrieved are deduped before count (§4: res = list(set(res)))")
    func duplicatesInRetrievedDeduped() {
        // [1,1,2] deduplicated → {1,2}; both in targets [1,2] → ct=2; std_set={1,2}; 2/2=1.0
        let r = membenchSpecGetRecall(retrievedStepIDs: [1, 1, 2], targetStepIDs: [1, 2])
        #expect(abs(r - 1.0) < 1e-9, "deduped retrieved hits all targets → 1.0")
    }

    @Test("duplicate targets counted only once in denominator (§4: len(std_set))")
    func duplicateTargetsDenominator() {
        // targets [1,1,2] → std_set={1,2}, len=2; retrieved [1] → ct=1 → 1/2=0.5
        let r = membenchSpecGetRecall(retrievedStepIDs: [1], targetStepIDs: [1, 1, 2])
        #expect(abs(r - 0.5) < 1e-9, "duplicate targets: denominator = distinct count")
    }

    @Test("partial overlap: only matching retrieved ids count")
    func partialOverlap() {
        // Retrieved [1,3], targets [1,2]: 1 matches, 3 does not → ct=1, std_set={1,2} → 0.5
        let r = membenchSpecGetRecall(retrievedStepIDs: [1, 3], targetStepIDs: [1, 2])
        #expect(abs(r - 0.5) < 1e-9, "partial overlap → 0.5")
    }

    @Test("no overlap returns 0")
    func noOverlap() {
        let r = membenchSpecGetRecall(retrievedStepIDs: [3, 4], targetStepIDs: [1, 2])
        #expect(abs(r - 0.0) < 1e-9, "no overlap → 0.0")
    }

    @Test("perfect single-target recall returns 1.0")
    func perfectSingleTarget() {
        let r = membenchSpecGetRecall(retrievedStepIDs: [5], targetStepIDs: [5])
        #expect(abs(r - 1.0) < 1e-9, "single target retrieved → 1.0")
    }

    @Test("empty target list returns 0 (div-by-zero guard)")
    func emptyTargetReturnsZero() {
        let r = membenchSpecGetRecall(retrievedStepIDs: [1, 2], targetStepIDs: [])
        #expect(abs(r - 0.0) < 1e-9, "empty target list → 0 (no div by zero)")
    }
}

// MARK: -

@Suite("MemBenchSpec aggregation")
struct MemBenchSpecAggregationTests {

    private func makeScore(
        category: String,
        agent: String = "FirstAgent",
        correct: Bool,
        recall: Double
    ) -> MemBenchSpecItemScore {
        MemBenchSpecItemScore(category: category, agent: agent, correct: correct, recall: recall)
    }

    @Test("overall accuracy and recall are means over all items")
    func overallMeans() {
        let scores = [
            makeScore(category: "simple", correct: true,  recall: 1.0),
            makeScore(category: "simple", correct: true,  recall: 1.0),
            makeScore(category: "noisy",  correct: false, recall: 0.5),
        ]
        let agg = membenchSpecAggregate(scores)
        // accuracy = 2/3; mean recall = (1+1+0.5)/3 = 5/6
        #expect(agg.overall.count == 3)
        #expect(abs(agg.overall.accuracy - 2.0 / 3.0) < 1e-9, "accuracy 2/3")
        #expect(abs(agg.overall.meanRecall - 5.0 / 6.0) < 1e-9, "meanRecall 5/6")
    }

    @Test("canonical category ordering: simple precedes noisy even when noisy appears first in input")
    func canonicalCategoryOrdering() {
        let scores = [
            makeScore(category: "noisy",  correct: true, recall: 1.0),
            makeScore(category: "simple", correct: true, recall: 1.0),
        ]
        let agg = membenchSpecAggregate(scores)
        let labels = agg.byCategory.map(\.label)
        let simpleIdx = labels.firstIndex(of: "simple") ?? Int.max
        let noisyIdx  = labels.firstIndex(of: "noisy")  ?? Int.max
        #expect(simpleIdx < noisyIdx, "simple must precede noisy in canonical order")
    }

    @Test("per-category accuracy and recall correct within slice")
    func perCategorySlice() throws {
        // 2 "simple" (1 correct, 1 wrong), 1 "noisy" (correct).
        let scores = [
            makeScore(category: "simple", correct: true,  recall: 1.0),
            makeScore(category: "simple", correct: false, recall: 0.0),
            makeScore(category: "noisy",  correct: true,  recall: 0.8),
        ]
        let agg = membenchSpecAggregate(scores)
        let simple = try #require(agg.byCategory.first(where: { $0.label == "simple" }))
        let noisy  = try #require(agg.byCategory.first(where: { $0.label == "noisy" }))
        #expect(simple.count == 2)
        #expect(abs(simple.accuracy - 0.5) < 1e-9, "simple: 1/2 correct → 0.5")
        #expect(abs(simple.meanRecall - 0.5) < 1e-9, "simple: (1+0)/2 = 0.5")
        #expect(noisy.count == 1)
        #expect(abs(noisy.accuracy - 1.0) < 1e-9, "noisy: 1/1 correct → 1.0")
    }

    @Test("per-perspective breakdown splits by agent label")
    func perPerspective() throws {
        let scores = [
            makeScore(category: "simple", agent: "FirstAgent",  correct: true,  recall: 1.0),
            makeScore(category: "simple", agent: "ThirdAgent",  correct: false, recall: 0.5),
            makeScore(category: "noisy",  agent: "ThirdAgent",  correct: true,  recall: 1.0),
        ]
        let agg = membenchSpecAggregate(scores)
        let fa = try #require(agg.byPerspective.first(where: { $0.label == "FirstAgent" }))
        let ta = try #require(agg.byPerspective.first(where: { $0.label == "ThirdAgent" }))
        #expect(fa.count == 1)
        #expect(abs(fa.accuracy - 1.0) < 1e-9)
        #expect(ta.count == 2)
        // ThirdAgent: 1/2 correct → 0.5; recall = (0.5+1.0)/2 = 0.75
        #expect(abs(ta.accuracy - 0.5) < 1e-9)
        #expect(abs(ta.meanRecall - 0.75) < 1e-9)
    }

    @Test("empty input produces zero overall and empty breakdowns")
    func emptyInput() {
        let agg = membenchSpecAggregate([])
        #expect(agg.overall.count == 0)
        #expect(abs(agg.overall.accuracy - 0.0) < 1e-9)
        #expect(agg.byCategory.isEmpty)
        #expect(agg.byPerspective.isEmpty)
    }

    @Test("unknown/HighLevel category appended after canonical labels")
    func highLevelCategoryAppended() {
        let scores = [
            makeScore(category: "reflective", correct: true, recall: 1.0),
            makeScore(category: "simple",     correct: true, recall: 1.0),
        ]
        let agg = membenchSpecAggregate(scores)
        let labels = agg.byCategory.map(\.label)
        let simpleIdx     = labels.firstIndex(of: "simple") ?? Int.max
        let reflectiveIdx = labels.firstIndex(of: "reflective") ?? Int.max
        #expect(simpleIdx < reflectiveIdx, "canonical 'simple' before unknown 'reflective'")
    }
}

// MARK: -

@Suite("MemBenchSpec §5 efficiency stats")
struct MemBenchSpecEfficiencyStatsTests {

    @Test("empty durations produce zero stats")
    func emptyProducesZero() {
        let stats = membenchSpecEfficiencyStats(durations: [])
        #expect(stats.count == 0)
        #expect(abs(stats.mean - 0.0) < 1e-9)
        #expect(abs(stats.p50 - 0.0) < 1e-9)
        #expect(abs(stats.p95 - 0.0) < 1e-9)
    }

    @Test("single sample: mean=p50=p95=sample")
    func singleSample() {
        let stats = membenchSpecEfficiencyStats(durations: [0.1])
        #expect(stats.count == 1)
        #expect(abs(stats.mean - 0.1) < 1e-9)
        #expect(abs(stats.p50  - 0.1) < 1e-9)
        #expect(abs(stats.p95  - 0.1) < 1e-9)
    }

    @Test("five values: mean, p50, p95 via lmePercentile (nearest-rank, ceil(p*n))")
    func fiveValuePercentiles() {
        // [0.1, 0.2, 0.3, 0.4, 0.5] sorted.
        // mean = 0.3
        // p50: rank = ceil(0.5*5)=3, index=2 → 0.3
        // p95: rank = ceil(0.95*5)=5, index=4 → 0.5
        let stats = membenchSpecEfficiencyStats(durations: [0.1, 0.2, 0.3, 0.4, 0.5])
        #expect(stats.count == 5)
        #expect(abs(stats.mean - 0.3) < 1e-9, "mean")
        #expect(abs(stats.p50  - 0.3) < 1e-9, "p50")
        #expect(abs(stats.p95  - 0.5) < 1e-9, "p95")
    }

    @Test("unsorted input is sorted internally before percentile")
    func unsortedInput() {
        // Same values as above, shuffled.
        let stats = membenchSpecEfficiencyStats(durations: [0.5, 0.1, 0.3, 0.2, 0.4])
        #expect(abs(stats.p50 - 0.3) < 1e-9, "p50 after sort")
    }
}

// MARK: -

@Suite("MemBenchSpec §6 capacity bucketing")
struct MemBenchSpecCapacityBucketTests {

    @Test("empty samples produce zero-count buckets")
    func emptysamples() {
        let buckets = membenchSpecCapacityBuckets(samples: [], bucketBoundaries: [1000, 5000])
        #expect(buckets.count == 3, "always boundaries+1 buckets")
        #expect(buckets.allSatisfy { $0.count == 0 }, "zero samples → count=0")
        #expect(buckets.allSatisfy { abs($0.accuracy - 0.0) < 1e-9 })
    }

    @Test("samples land in correct buckets and open-ended last bucket has nil high")
    func sampleRanges() throws {
        // Boundaries [1000, 5000] → [0,1000), [1000,5000), [5000,∞)
        let samples = [(500, true), (1500, false), (6000, true)]
        let buckets = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [1000, 5000])
        #expect(buckets.count == 3)
        let b0 = try #require(buckets[0] as MemBenchSpecCapacityBucket?)
        let b1 = try #require(buckets[1] as MemBenchSpecCapacityBucket?)
        let b2 = try #require(buckets[2] as MemBenchSpecCapacityBucket?)
        #expect(b0.tokenLow == 0, "b0 low")
        #expect(b0.tokenHigh == 1000, "b0 high")
        #expect(b0.count == 1, "b0 count")
        #expect(abs(b0.accuracy - 1.0) < 1e-9, "b0 accuracy: 1 correct")
        #expect(b1.count == 1, "b1 count")
        #expect(abs(b1.accuracy - 0.0) < 1e-9, "b1 accuracy: 1 incorrect")
        #expect(b2.tokenHigh == nil, "b2 is open-ended")
        #expect(b2.count == 1, "b2 count")
        #expect(abs(b2.accuracy - 1.0) < 1e-9, "b2 accuracy")
    }

    @Test("no boundaries: one open-ended bucket covering all samples")
    func noBoundaries() {
        let samples = [(100, true), (9999, false)]
        let buckets = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [])
        #expect(buckets.count == 1, "zero boundaries → one bucket")
        #expect(buckets[0].count == 2)
        #expect(abs(buckets[0].accuracy - 0.5) < 1e-9, "1/2 correct → 0.5")
        #expect(buckets[0].tokenHigh == nil)
    }

    @Test("boundary on exact token count: sample at boundary falls in upper bucket")
    func exactBoundaryFallsInUpperBucket() {
        // Boundary [100]: [0,100), [100,∞). Sample at 100 is ≥ 100, so upper bucket.
        let samples = [(100, true)]
        let buckets = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [100])
        #expect(buckets[0].count == 0, "100 not in [0,100)")
        #expect(buckets[1].count == 1, "100 is in [100,∞)")
    }

    @Test("unsorted boundaries are sorted internally")
    func unsortedBoundaries() {
        // Pass boundaries in reverse; result must match sorted order.
        let samples = [(50, true), (150, false), (300, true)]
        let bucketsReversed = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [200, 100])
        let bucketsSorted   = membenchSpecCapacityBuckets(samples: samples, bucketBoundaries: [100, 200])
        #expect(bucketsReversed.count == bucketsSorted.count)
        for (a, b) in zip(bucketsReversed, bucketsSorted) {
            #expect(a.tokenLow == b.tokenLow)
            #expect(a.tokenHigh == b.tokenHigh)
            #expect(a.count == b.count)
        }
    }
}

// MARK: -

@Suite("MemBenchSpec conformance vectors")
struct MemBenchSpecConformanceVectorTests {

    private struct ScorerVectors: Decodable {
        let getRecallCases: [GetRecallCase]
        let answerEqualityCases: [AnswerEqualityCase]
        let aggregationCases: [AggregationCase]

        enum CodingKeys: String, CodingKey {
            case getRecallCases     = "get_recall_cases"
            case answerEqualityCases = "answer_equality_cases"
            case aggregationCases   = "aggregation_cases"
        }
    }

    private struct GetRecallCase: Decodable {
        let id: String
        let retrievedStepIDs: [Int]?
        let targetStepIDs: [Int]
        let expectedRecall: Double
        let note: String

        enum CodingKeys: String, CodingKey {
            case id
            case retrievedStepIDs   = "retrieved_step_ids"
            case targetStepIDs      = "target_step_ids"
            case expectedRecall     = "expected_recall"
            case note
        }
    }

    private struct AnswerEqualityCase: Decodable {
        let id: String
        let response: String
        let groundTruth: String
        let expectedCorrect: Bool
        let note: String

        enum CodingKeys: String, CodingKey {
            case id
            case response
            case groundTruth    = "ground_truth"
            case expectedCorrect = "expected_correct"
            case note
        }
    }

    private struct AggregationCase: Decodable {
        let id: String
        let items: [AggItem]
        let expectedOverallAccuracy: Double
        let expectedOverallMeanRecall: Double

        enum CodingKeys: String, CodingKey {
            case id
            case items
            case expectedOverallAccuracy   = "expected_overall_accuracy"
            case expectedOverallMeanRecall = "expected_overall_mean_recall"
        }
    }

    private struct AggItem: Decodable {
        let category: String
        let agent: String
        let correct: Bool
        let recall: Double
    }

    private func loadVectors() throws -> ScorerVectors {
        // conformance/membench-spec/scorer_vectors.json is in the repo root's
        // conformance directory; locate it relative to the source file's directory.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Tests/mcp-benchmarkerTests/
            .deletingLastPathComponent()     // Tests/
            .deletingLastPathComponent()     // benchmarks/
            .appendingPathComponent("conformance/membench-spec/scorer_vectors.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ScorerVectors.self, from: data)
    }

    @Test("get_recall cases match expected values to 1e-9")
    func getRecallVectors() throws {
        let vectors = try loadVectors()
        for c in vectors.getRecallCases {
            let result = membenchSpecGetRecall(
                retrievedStepIDs: c.retrievedStepIDs,
                targetStepIDs: c.targetStepIDs
            )
            #expect(
                abs(result - c.expectedRecall) < 1e-9,
                "case \(c.id): expected \(c.expectedRecall), got \(result) — \(c.note)"
            )
        }
    }

    @Test("answer equality cases match expected values")
    func answerEqualityVectors() throws {
        let vectors = try loadVectors()
        for c in vectors.answerEqualityCases {
            let result = membenchSpecAnswerCorrect(response: c.response, groundTruth: c.groundTruth)
            #expect(
                result == c.expectedCorrect,
                "case \(c.id): expected \(c.expectedCorrect), got \(result) — \(c.note)"
            )
        }
    }

    @Test("aggregation cases match expected overall accuracy and mean recall")
    func aggregationVectors() throws {
        let vectors = try loadVectors()
        for c in vectors.aggregationCases {
            let scores = c.items.map { item in
                MemBenchSpecItemScore(
                    category: item.category,
                    agent: item.agent,
                    correct: item.correct,
                    recall: item.recall
                )
            }
            let agg = membenchSpecAggregate(scores)
            #expect(
                abs(agg.overall.accuracy - c.expectedOverallAccuracy) < 1e-9,
                "case \(c.id) accuracy: expected \(c.expectedOverallAccuracy), got \(agg.overall.accuracy)"
            )
            #expect(
                abs(agg.overall.meanRecall - c.expectedOverallMeanRecall) < 1e-9,
                "case \(c.id) meanRecall: expected \(c.expectedOverallMeanRecall), got \(agg.overall.meanRecall)"
            )
        }
    }
}
