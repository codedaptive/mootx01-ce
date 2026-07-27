import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBScorerTests.swift — unit and conformance tests for LMEBScorer.swift.
//
// Two kinds of tests:
//   1. Conformance vector tests: load conformance/lmeb_vectors.json and verify
//      every case against the Swift leg. Both legs (Swift + Rust) must produce
//      identical outputs for identical inputs — the contract.
//   2. Infrastructure tests: aggregate, percentile, guard-exclusion semantics.

// MARK: - Fixture path helper

/// Resolves `apps/mcp-benchmarker/conformance/<filename>` from this test file.
///   .../Tests/mcp-benchmarkerTests/LMEBScorerTests.swift
///     → mcp-benchmarkerTests/      (1st deletingLastPathComponent)
///     → Tests/                     (2nd)
///     → apps/mcp-benchmarker/      (3rd = package root)
///     → apps/mcp-benchmarker/conformance/<filename>
private func lmebConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

private func loadLMEBConformanceJSON(file: String = #filePath) throws -> [String: Any] {
    let url = lmebConformancePath("lmeb_vectors.json", file: file)
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "LMEBVectors", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected top-level object"])
    }
    return dict
}

// MARK: - nDCG conformance

@Suite("LMEB scorer: nDCG conformance vectors")
struct LMEBNDCGConformanceTests {

    @Test("All nDCG conformance vectors: Swift leg matches expected values within 1e-9")
    func allNDCGVectors() throws {
        let json = try loadLMEBConformanceJSON()
        let cases = try #require(json["ndcg_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let ranked = (c["ranked_doc_ids"] as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let k = c["k"] as? Int ?? 10
            let expected = try #require(c["ndcg"] as? Double, "case \(id) missing 'ndcg'")

            let got = lmebNDCG(rankedDocIDs: ranked, relevantDocIDs: relevant, k: k)
            #expect(abs(got - expected) < 1e-9,
                    "nDCG mismatch for case '\(id)': got \(got), expected \(expected)")
        }
    }
}

// MARK: - MRR conformance

@Suite("LMEB scorer: MRR conformance vectors")
struct LMEBMRRConformanceTests {

    @Test("All MRR conformance vectors: Swift leg matches expected values within 1e-9")
    func allMRRVectors() throws {
        let json = try loadLMEBConformanceJSON()
        let cases = try #require(json["mrr_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let ranked = (c["ranked_doc_ids"] as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let expected = try #require(c["mrr"] as? Double, "case \(id) missing 'mrr'")

            let got = lmebMRR(rankedDocIDs: ranked, relevantDocIDs: relevant)
            #expect(abs(got - expected) < 1e-9,
                    "MRR mismatch for case '\(id)': got \(got), expected \(expected)")
        }
    }
}

// MARK: - Recall conformance

@Suite("LMEB scorer: recall conformance vectors")
struct LMEBRecallConformanceTests {

    @Test("All recall conformance vectors: Swift leg matches expected values within 1e-9")
    func allRecallVectors() throws {
        let json = try loadLMEBConformanceJSON()
        let cases = try #require(json["recall_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let ranked = (c["ranked_doc_ids"] as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])

            let exp1  = try #require(c["recall_at_1"]  as? Double, "case \(id) missing 'recall_at_1'")
            let exp5  = try #require(c["recall_at_5"]  as? Double, "case \(id) missing 'recall_at_5'")
            let exp10 = try #require(c["recall_at_10"] as? Double, "case \(id) missing 'recall_at_10'")

            let got1  = lmebRecall(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 1)
            let got5  = lmebRecall(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 5)
            let got10 = lmebRecall(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 10)

            #expect(abs(got1  - exp1)  < 1e-9, "recall@1 mismatch for '\(id)': got \(got1), expected \(exp1)")
            #expect(abs(got5  - exp5)  < 1e-9, "recall@5 mismatch for '\(id)': got \(got5), expected \(exp5)")
            #expect(abs(got10 - exp10) < 1e-9, "recall@10 mismatch for '\(id)': got \(got10), expected \(exp10)")
        }
    }
}

// MARK: - AP conformance

@Suite("LMEB scorer: AP conformance vectors")
struct LMEBAPConformanceTests {

    @Test("All AP conformance vectors: Swift leg matches expected values within 1e-9")
    func allAPVectors() throws {
        let json = try loadLMEBConformanceJSON()
        let cases = try #require(json["ap_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let ranked = (c["ranked_doc_ids"] as? [String]) ?? []
            let relevant = Set((c["relevant_doc_ids"] as? [String]) ?? [])
            let k = c["k"] as? Int ?? 10
            let expected = try #require(c["ap"] as? Double, "case \(id) missing 'ap'")

            let got = lmebAP(rankedDocIDs: ranked, relevantDocIDs: relevant, k: k)
            #expect(abs(got - expected) < 1e-9,
                    "AP mismatch for case '\(id)': got \(got), expected \(expected)")
        }
    }
}

// MARK: - Aggregate infrastructure

@Suite("LMEB scorer: aggregate infrastructure")
struct LMEBScorerAggregateTests {

    /// Builds a minimal LMEBQueryScore for testing aggregate logic.
    private func makeScore(
        queryID: String,
        guardHealthy: Bool,
        ndcg: Double = 0.5,
        mrr: Double = 0.5,
        r1: Double = 0.0,
        r5: Double = 0.5,
        r10: Double = 1.0,
        ap: Double = 0.5,
        queryLatency: Double = 0.1,
        writeLatency: Double = 0.05
    ) -> LMEBQueryScore {
        LMEBQueryScore(
            queryID: queryID,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardHealthy ? nil : "test-diagnostic",
            nDCGAt10: ndcg,
            mrr: mrr,
            recallAt1: r1,
            recallAt5: r5,
            recallAt10: r10,
            apAt10: ap,
            queryLatencySeconds: queryLatency,
            writeMeanLatencySeconds: writeLatency,
            docsIngested: 5,
            retrievedDocCount: 3,
            rankedDocIDs: [],
            relevantDocIDs: [],
            payloadText: nil
        )
    }

    @Test("Empty input yields zeroed aggregate and zero latency")
    func emptyInputZeros() {
        let (agg, lat) = aggregateLMEBScores([])
        #expect(agg.queryCount == 0)
        #expect(agg.nDCGAt10 == 0.0)
        #expect(agg.mrr == 0.0)
        #expect(lat.queryP50Seconds == 0.0)
        #expect(lat.queryP95Seconds == 0.0)
    }

    @Test("All guard-excluded: aggregate zeros, latency still computed")
    func allGuardExcluded() {
        let scores = [
            makeScore(queryID: "q1", guardHealthy: false, queryLatency: 0.1),
            makeScore(queryID: "q2", guardHealthy: false, queryLatency: 0.3)
        ]
        let (agg, lat) = aggregateLMEBScores(scores)
        #expect(agg.queryCount == 0)
        #expect(agg.nDCGAt10 == 0.0)
        // Latency is recorded for all queries, guard-excluded or not.
        #expect(lat.queryMeanSeconds > 0.0, "latency should be non-zero even for excluded queries")
    }

    @Test("Guard-excluded queries are excluded from aggregate denominator")
    func guardExclusionSemantics() {
        let scores = [
            makeScore(queryID: "q1", guardHealthy: true, ndcg: 1.0),
            makeScore(queryID: "q2", guardHealthy: false, ndcg: 0.0),  // excluded
            makeScore(queryID: "q3", guardHealthy: true, ndcg: 0.5)
        ]
        let (agg, _) = aggregateLMEBScores(scores)
        #expect(agg.queryCount == 2, "only 2 guard-healthy queries")
        // Mean nDCG over q1 and q3: (1.0 + 0.5) / 2 = 0.75
        #expect(abs(agg.nDCGAt10 - 0.75) < 1e-9, "mean nDCG should be 0.75")
    }

    @Test("Latency P95 is computed over all queries including excluded")
    func latencyIncludesExcluded() {
        let scores = [
            makeScore(queryID: "q1", guardHealthy: true,  queryLatency: 0.1),
            makeScore(queryID: "q2", guardHealthy: false, queryLatency: 0.9)  // excluded
        ]
        let (_, lat) = aggregateLMEBScores(scores)
        // Sorted [0.1, 0.9]. P95 (nearest-rank at 95%) → rank = ceil(0.95*2)=2 → 0.9.
        #expect(lat.queryP95Seconds == 0.9, "P95 includes guard-excluded query latencies")
    }

    @Test("MAP@10 is mean AP@10 over guard-healthy queries")
    func mapIsAveragedAP() {
        let scores = [
            makeScore(queryID: "q1", guardHealthy: true, ap: 1.0),
            makeScore(queryID: "q2", guardHealthy: true, ap: 0.5),
            makeScore(queryID: "q3", guardHealthy: true, ap: 0.0)
        ]
        let (agg, _) = aggregateLMEBScores(scores)
        #expect(abs(agg.mapAt10 - (1.0 + 0.5 + 0.0) / 3.0) < 1e-9)
    }
}

// MARK: - Percentile helper

@Suite("LMEB scorer: lmebPercentile")
struct LMEBPercentileTests {

    @Test("Empty input returns 0.0")
    func emptyInput() {
        #expect(lmebPercentile([], 0.95) == 0.0)
    }

    @Test("Single-element input returns that element at any percentile")
    func singleElement() {
        #expect(lmebPercentile([0.5], 0.50) == 0.5)
        #expect(lmebPercentile([0.5], 0.95) == 0.5)
    }

    @Test("P50 of sorted three-element list is the middle element")
    func p50ThreeElements() {
        // [0.1, 0.5, 0.9]: P50 = rank=ceil(0.5*3)=2 → index 1 → 0.5
        #expect(lmebPercentile([0.9, 0.1, 0.5], 0.50) == 0.5)
    }

    @Test("P95 of two-element list returns the larger element")
    func p95TwoElements() {
        // [0.1, 0.9]: P95 = rank=ceil(0.95*2)=2 → index 1 → 0.9
        #expect(lmebPercentile([0.1, 0.9], 0.95) == 0.9)
    }
}

// MARK: - nDCG edge cases (unit)

@Suite("LMEB scorer: nDCG unit edge cases")
struct LMEBNDCGUnitTests {

    @Test("k=0 returns 0.0 regardless of relevance")
    func kZeroReturnsZero() {
        #expect(lmebNDCG(rankedDocIDs: ["doc_a"], relevantDocIDs: ["doc_a"], k: 0) == 0.0)
    }

    @Test("Perfect ranking of three relevant docs: nDCG=1.0")
    func perfectThreeDocs() {
        let ranked = ["doc_a", "doc_b", "doc_c"]
        let relevant: Set<String> = ["doc_a", "doc_b", "doc_c"]
        let result = lmebNDCG(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 10)
        #expect(abs(result - 1.0) < 1e-9)
    }

    @Test("nDCG is bounded by [0.0, 1.0]")
    func boundedRange() {
        let ranked = ["doc_a", "doc_b", "doc_c", "doc_d"]
        let relevant: Set<String> = ["doc_b", "doc_d"]
        let result = lmebNDCG(rankedDocIDs: ranked, relevantDocIDs: relevant, k: 10)
        #expect(result >= 0.0 && result <= 1.0)
    }
}

// MARK: - Integration-shaped test: real builder path populates report fields

@Suite("LMEBReport provenance fields — integration-shaped builder tests")
struct LMEBReportProvenanceTests {

    /// Exercises buildLMEBReport through the real code path with a synthetic query
    /// score that carries payloadText. Asserts encode_barrier, per-query
    /// tokens_per_result, and provenance_summary are all present in the output.
    @Test("buildLMEBReport populates encode_barrier, tokens_per_result, provenance_summary")
    func buildLMEBReportPopulatesProvenanceFields() {
        // "found 2 memory(s)\n..." — lmeParseResultCount returns 2 for this payload.
        let payload = "found 2 memory(s)\nsome retrieved document text here\nanother document snippet"
        let score = LMEBQueryScore(
            queryID: "prov-test-q1",
            guardHealthy: true,
            guardDiagnostic: nil,
            nDCGAt10: 1.0,
            mrr: 1.0,
            recallAt1: 1.0,
            recallAt5: 1.0,
            recallAt10: 1.0,
            apAt10: 1.0,
            queryLatencySeconds: 0.1,
            writeMeanLatencySeconds: 0.02,
            docsIngested: 5,
            retrievedDocCount: 2,
            rankedDocIDs: ["doc-a", "doc-b"],
            relevantDocIDs: ["doc-a"],
            payloadText: payload
        )

        let report = buildLMEBReport(
            runLabel: "prov-test",
            evidenceTypes: ["user_evidence"],
            queriesLoaded: 1,
            scores: [score],
            encodeBarrier: "drain"
        )

        // 1. encode_barrier is present and correct.
        #expect(report.encodeBarrier == "drain",
            "encode_barrier must match the encodeBarrier argument")

        // 2. per_query entry has tokens_per_result set (payload had 2 results).
        guard let q = report.perQuery.first else {
            Issue.record("perQuery must not be empty")
            return
        }
        #expect(q.tokensPerResult != nil,
            "tokens_per_result must be non-nil when payload text was present")

        // 3. provenance_summary is present and populated.
        guard let prov = report.provenanceSummary else {
            Issue.record("provenance_summary must be non-nil when at least one query had payload text")
            return
        }
        #expect(prov.queriesWithPayload == 1,
            "queries_with_payload must equal the count of scores with payload text")
        #expect(prov.meanTokensPerResult != nil,
            "mean_tokens_per_result must be non-nil when queries_with_payload > 0")
        #expect(prov.encodeBarrier == "drain",
            "encode_barrier in provenance_summary must mirror the top-level encode_barrier")
    }
}
