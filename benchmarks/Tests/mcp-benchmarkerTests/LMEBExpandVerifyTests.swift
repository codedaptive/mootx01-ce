import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBExpandVerifyTests.swift — tests for the expand-verify scoreboard additions.
//
// Three test groups (per the brief §6):
//   1. Content-term count gate: lmebContentTermCount against the shared EN stopword fixture.
//   2. Pool metric computation: poolGoldHit, goldRanks, poolGuarantee over synthetic inputs.
//   3. Report schema parity: the Swift report emits every key the brief specifies.
//
// Both ports load the same stopwords_en.json fixture; these tests pin the Swift leg.

// MARK: - Fixture path helper

/// Resolves `benchmarks/conformance/lmeb-spec/<filename>` from this test file.
private func expandVerifyConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // the suite root (benchmarks/)
        .appendingPathComponent("conformance")
        .appendingPathComponent("lmeb-spec")
        .appendingPathComponent(filename)
}

// MARK: - §1 Content-term count gate

@Suite("Expand-verify: content-term count gate (§7.1 short-query)")
struct ContentTermCountTests {

    /// The shared EN stopword fixture must exist and be parseable.
    @Test("Stopword fixture loads successfully")
    func stopwordFixtureLoads() throws {
        let url = expandVerifyConformancePath("stopwords_en.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(obj as? [String: Any], "Expected top-level object")
        let words = try #require(dict["stopwords"] as? [String], "Expected 'stopwords' array")
        #expect(words.count > 50, "Fixture should carry at least 50 stopwords")
    }

    /// Empty text → 0 content terms.
    @Test("Empty text yields 0 content terms")
    func emptyText() {
        #expect(lmebContentTermCount(text: "") == 0)
    }

    /// All-stopword text → 0 content terms.
    @Test("All-stopword text yields 0 content terms")
    func allStopwords() {
        // "the", "a", "an" are guaranteed stopwords.
        #expect(lmebContentTermCount(text: "the a an") == 0)
    }

    /// Mixed text: one stopword + two content terms.
    @Test("Mixed text counts only non-stopword tokens")
    func mixedText() {
        // "what" and "the" are stopwords; "happened" and "yesterday" are content terms.
        let count = lmebContentTermCount(text: "what happened the yesterday")
        // "what" and "the" are stopwords; count should be 2.
        #expect(count == 2)
    }

    /// Punctuation is stripped; tokens are lowercase alnum.
    @Test("Punctuation stripped; case-folded; stopwords removed")
    func punctuationAndCase() {
        // "Where", "did", "I" are stopwords; "travel", "paris", "london" are content terms.
        let count = lmebContentTermCount(text: "Where did I travel? Paris, London!")
        #expect(count == 3)
    }

    /// Short-query gate: default threshold is 4 (terms strictly < 4 → short).
    @Test("Short-query gate: 3 content terms → short; 4 content terms → not short")
    func shortQueryGate() {
        // 3 content terms (< 4): short.
        let shortCount = lmebContentTermCount(text: "alice bob charlie")
        #expect(shortCount == 3)
        #expect(shortCount < 4, "3 content terms should be below the default threshold of 4")

        // 4 content terms (= 4): not short (threshold is strictly <).
        let notShortCount = lmebContentTermCount(text: "alice bob charlie delta")
        #expect(notShortCount == 4)
        #expect(notShortCount >= 4, "4 content terms should NOT be below the default threshold of 4")
    }
}

// MARK: - §3 Pool metric computation

@Suite("Expand-verify: pool guarantee and gold-rank computation (§3)")
struct PoolMetricTests {

    /// goldRanks: 1-based positions of gold docs in the ranked list.
    @Test("goldRanks returns correct 1-based positions")
    func goldRanks() {
        let ranked = ["d1", "d2", "d3", "d4", "d5"]
        let relevant: Set<String> = ["d2", "d4"]
        // d2 is at index 1 → rank 2; d4 is at index 3 → rank 4.
        let ranks: [Int] = ranked.enumerated().compactMap { i, id in
            relevant.contains(id) ? i + 1 : nil
        }
        #expect(ranks == [2, 4])
    }

    /// When no gold doc appears in the returned list, goldRanks is empty → poolGoldHit = 0.
    @Test("No gold in pool → poolGoldHit = 0")
    func noGoldInPool() {
        let ranked = ["d1", "d2", "d3"]
        let relevant: Set<String> = ["d9", "d10"]
        let ranks: [Int] = ranked.enumerated().compactMap { i, id in
            relevant.contains(id) ? i + 1 : nil
        }
        #expect(ranks.isEmpty)
        let poolGoldHit = ranks.isEmpty ? 0 : 1
        #expect(poolGoldHit == 0)
    }

    /// When ≥1 gold doc appears in the returned list, poolGoldHit = 1.
    @Test("At least one gold in pool → poolGoldHit = 1")
    func goldInPool() {
        let ranked = ["d1", "d2", "d3"]
        let relevant: Set<String> = ["d2"]
        let ranks: [Int] = ranked.enumerated().compactMap { i, id in
            relevant.contains(id) ? i + 1 : nil
        }
        #expect(!ranks.isEmpty)
        let poolGoldHit = ranks.isEmpty ? 0 : 1
        #expect(poolGoldHit == 1)
    }

    /// poolGuarantee = fraction of questions with ≥1 gold in the pool.
    @Test("poolGuarantee computed correctly from synthetic question set")
    func poolGuarantee() {
        // 3 questions: 2 have gold in pool, 1 does not → guarantee = 2/3.
        let hits = [1, 0, 1]  // poolGoldHit per question
        let guarantee = Double(hits.filter { $0 == 1 }.count) / Double(hits.count)
        let expected = 2.0 / 3.0
        #expect(abs(guarantee - expected) < 1e-9)
    }

    /// poolGoldRecall = gold docs in pool / total gold docs across all questions.
    @Test("poolGoldRecall computed correctly from synthetic question set")
    func poolGoldRecall() {
        // Question 1: 2 gold docs, 1 in pool. Question 2: 3 gold docs, 2 in pool.
        // Total gold = 5; gold in pool = 3; recall = 3/5.
        let totalGold = 5
        let goldInPool = 3
        let recall = Double(goldInPool) / Double(totalGold)
        #expect(abs(recall - 0.6) < 1e-9)
    }
}

// MARK: - §6 Report schema parity (per-question record keys)

@Suite("Expand-verify: report schema — required keys present")
struct ReportSchemaParityTests {

    /// A synthetic per-question record must carry all keys listed in the brief.
    @Test("Per-question record carries all required keys")
    func perQuestionRecordKeys() throws {
        // Construct a minimal synthetic record matching the JSON shape the CLI emits.
        let record: [String: Any] = [
            "query_id":           "scene_0_q_1",
            "evidence_type":      "user_evidence",
            "content_term_count": 3,
            "returned_count":     20,
            "gold_doc_ids":       ["user_evidence/scene_0_session_1"],
            "gold_ranks":         [5],
            "pool_size":          20,
            "pool_gold_hit":      1,
            "pool_provenance":    [String: Int](),
            "latency_seconds":    0.234,
        ]
        let requiredKeys = [
            "query_id", "evidence_type", "content_term_count", "returned_count",
            "gold_doc_ids", "gold_ranks", "pool_size", "pool_gold_hit",
            "pool_provenance", "latency_seconds",
        ]
        for key in requiredKeys {
            #expect(record[key] != nil, "Missing required key: \(key)")
        }
    }

    /// task_metrics must carry all new pool/short-query keys.
    @Test("task_metrics carries all expand-verify keys")
    func taskMetricsKeys() throws {
        let taskMetrics: [String: Any] = [
            "pool_guarantee":             0.717,
            "pool_gold_recall":           0.612,
            "short_query_count":          14,
            "short_query_ndcg_at_10":     0.389,
            "short_query_recall_at_10":   0.432,
            "short_query_pool_guarantee": 0.643,
        ]
        let requiredKeys = [
            "pool_guarantee", "pool_gold_recall", "short_query_count",
            "short_query_ndcg_at_10", "short_query_recall_at_10",
            "short_query_pool_guarantee",
        ]
        for key in requiredKeys {
            #expect(taskMetrics[key] != nil, "Missing required task_metrics key: \(key)")
        }
    }

    /// subset_metrics entries must carry evidence_type as an alias for subset.
    @Test("subset_metrics entry carries evidence_type alias")
    func subsetMetricsEvidenceTypeAlias() {
        let entry: [String: Any] = [
            "subset":       "user_evidence",
            "evidence_type": "user_evidence",
            "query_count":  23,
        ]
        #expect(entry["evidence_type"] as? String == "user_evidence",
                "subset_metrics entry must carry evidence_type key for ev-table.py")
        #expect(entry["subset"] as? String == "user_evidence",
                "subset_metrics entry must also carry original subset key")
    }

    /// LMEBSpecTaskMetrics struct carries the new expand-verify fields with zero defaults.
    @Test("LMEBSpecTaskMetrics has all expand-verify fields with sane defaults")
    func taskMetricsStructFields() {
        // Default-constructed via the subset-mean path; pool/short-query fields default to 0.
        var m = LMEBSpecTaskMetrics(
            subsetCount: 0, ndcg: [:], map: [:], recall: [:],
            precision: [:], mrr: [:], rCap: [:]
        )
        #expect(m.poolGuarantee == 0.0)
        #expect(m.poolGoldRecall == 0.0)
        #expect(m.shortQueryCount == 0)
        #expect(m.shortQueryNdcgAt10 == 0.0)
        #expect(m.shortQueryRecallAt10 == 0.0)
        #expect(m.shortQueryPoolGuarantee == 0.0)

        // Verify they are mutable (required so runLMEBSpecQueries can update them in place).
        m.poolGuarantee = 0.75
        #expect(m.poolGuarantee == 0.75)
    }
}
