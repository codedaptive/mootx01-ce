import Testing
import Foundation
@testable import mcp_benchmarker

// LongMemEvalScorerTests.swift — unit and conformance tests for LongMemEvalScorer.swift.
//
// Two kinds of tests:
//   1. Conformance vector tests: load conformance/longmemeval_vectors.json and
//      verify every case against the Swift leg. Both legs (Swift + Rust) must
//      produce identical outputs for identical inputs — the contract.
//   2. Infrastructure tests: lmePercentile, aggregateLMEScores, report round-trip,
//      guard-exclusion semantics.

// MARK: - Fixture path helper

/// Resolves `apps/mcp-benchmarker/conformance/<filename>` from this test file:
///   .../Tests/mcp-benchmarkerTests/   (1st deletingLastPathComponent)
///   .../Tests/                         (2nd)
///   .../apps/mcp-benchmarker/          (3rd = package root)
///   .../apps/mcp-benchmarker/conformance/<filename>
private func conformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

private func loadConformanceJSON(file: String = #filePath) throws -> [String: Any] {
    let url = conformancePath("longmemeval_vectors.json", file: file)
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "LMEVectors", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected top-level object"])
    }
    return dict
}

// MARK: - Conformance vector tests: recall cases

@Suite("LME scorer: recall conformance vectors")
struct LMEScorerRecallConformanceTests {

    @Test("All recall conformance vectors: both legs produce identical results")
    func allRecallVectors() throws {
        let json = try loadConformanceJSON()
        let cases = try #require(json["recall_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let rankedSessions = (c["ranked_session_ids"] as? [String]) ?? []
            let answerIDs = Set((c["answer_session_ids"] as? [String]) ?? [])

            let expectedAny1  = try #require(c["recall_any_at_1"]  as? Double)
            let expectedAny5  = try #require(c["recall_any_at_5"]  as? Double)
            let expectedAny10 = try #require(c["recall_any_at_10"] as? Double)
            let expectedAll1  = try #require(c["recall_all_at_1"]  as? Double)
            let expectedAll5  = try #require(c["recall_all_at_5"]  as? Double)
            let expectedAll10 = try #require(c["recall_all_at_10"] as? Double)
            let expectedMRR   = try #require(c["mrr"]              as? Double)

            let gotAny1  = lmeRecallAny(rankedSessions: rankedSessions, answerIDs: answerIDs, k: 1)
            let gotAny5  = lmeRecallAny(rankedSessions: rankedSessions, answerIDs: answerIDs, k: 5)
            let gotAny10 = lmeRecallAny(rankedSessions: rankedSessions, answerIDs: answerIDs, k: 10)
            let gotAll1  = lmeRecallAll(rankedSessions: rankedSessions, answerIDs: answerIDs, k: 1)
            let gotAll5  = lmeRecallAll(rankedSessions: rankedSessions, answerIDs: answerIDs, k: 5)
            let gotAll10 = lmeRecallAll(rankedSessions: rankedSessions, answerIDs: answerIDs, k: 10)
            let gotMRR   = lmeSessionMRR(rankedSessions: rankedSessions, answerIDs: answerIDs)

            #expect(abs(gotAny1  - expectedAny1)  < 1e-9, "'\(id)' recall_any_at_1: expected \(expectedAny1), got \(gotAny1)")
            #expect(abs(gotAny5  - expectedAny5)  < 1e-9, "'\(id)' recall_any_at_5: expected \(expectedAny5), got \(gotAny5)")
            #expect(abs(gotAny10 - expectedAny10) < 1e-9, "'\(id)' recall_any_at_10: expected \(expectedAny10), got \(gotAny10)")
            #expect(abs(gotAll1  - expectedAll1)  < 1e-9, "'\(id)' recall_all_at_1: expected \(expectedAll1), got \(gotAll1)")
            #expect(abs(gotAll5  - expectedAll5)  < 1e-9, "'\(id)' recall_all_at_5: expected \(expectedAll5), got \(gotAll5)")
            #expect(abs(gotAll10 - expectedAll10) < 1e-9, "'\(id)' recall_all_at_10: expected \(expectedAll10), got \(gotAll10)")
            #expect(abs(gotMRR   - expectedMRR)   < 1e-9, "'\(id)' mrr: expected \(expectedMRR), got \(gotMRR)")
        }
    }
}

// MARK: - Conformance vector tests: UUID mapping cases

@Suite("LME scorer: UUID mapping conformance vectors")
struct LMEScorerUUIDMappingConformanceTests {

    @Test("All UUID mapping conformance vectors: both legs produce identical results")
    func allUUIDMappingVectors() throws {
        let json = try loadConformanceJSON()
        let cases = try #require(json["uuid_mapping_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let retrievedUUIDs = (c["retrieved_uuids"] as? [String]) ?? []
            let rawManifest = try #require(c["manifest"] as? [[String: Any]])
            let expected = try #require(c["expected_ranked_session_ids"] as? [String])

            // Build LMEManifestEntry from the minimal manifest representation in the vector.
            // turnIndex, sessionIndex, role are unused in lmeRankedSessions — fill with defaults.
            let manifest: [LMEManifestEntry] = rawManifest.compactMap { entry in
                guard let uuid = entry["uuid"] as? String,
                      let sessionID = entry["session_id"] as? String else { return nil }
                return LMEManifestEntry(uuid: uuid, sessionID: sessionID,
                                       turnIndex: 0, sessionIndex: 0, role: "user")
            }

            let got = lmeRankedSessions(uuids: retrievedUUIDs, manifest: manifest)
            #expect(got == expected, "uuid_mapping '\(id)': expected \(expected), got \(got)")
        }
    }
}

// MARK: - Infrastructure tests

@Suite("LME scorer: infrastructure")
struct LMEScorerInfrastructureTests {

    // MARK: lmePercentile

    @Test("lmePercentile: p50 of [1.0, 2.0, 3.0] = 2.0")
    func p50ThreeValues() {
        // sorted: [1,2,3]. rank = ceil(0.50 * 3) = 2. index = 2-1 = 1. → 2.0
        let result = lmePercentile([1.0, 2.0, 3.0], 0.50)
        #expect(abs(result - 2.0) < 1e-9)
    }

    @Test("lmePercentile: p95 of [1.0] = 1.0")
    func p95SingleValue() {
        #expect(abs(lmePercentile([1.0], 0.95) - 1.0) < 1e-9)
    }

    @Test("lmePercentile: empty input returns 0.0")
    func p95EmptyInput() {
        #expect(lmePercentile([], 0.95) == 0.0)
    }

    @Test("lmePercentile: p95 of five values")
    func p95FiveValues() {
        // sorted: [1,2,3,4,5]. rank = ceil(0.95 * 5) = ceil(4.75) = 5. index = 4. → 5.0
        let result = lmePercentile([3.0, 1.0, 5.0, 2.0, 4.0], 0.95)
        #expect(abs(result - 5.0) < 1e-9)
    }

    // MARK: aggregateLMEScores

    @Test("aggregateLMEScores: empty input yields zeroed aggregate with queryCount 0")
    func aggregateEmpty() {
        let (agg, lat) = aggregateLMEScores([])
        #expect(agg.queryCount == 0)
        #expect(agg.mrr == 0.0)
        #expect(lat.queryP50Seconds == 0.0)
    }

    @Test("aggregateLMEScores: guard-excluded questions are excluded from aggregate")
    func aggregateGuardExclusion() {
        // One healthy, one excluded. Aggregate denominator must be 1, not 2.
        let healthy = makeScore(questionID: "q1", guardHealthy: true,
                                recallAny1: 1.0, mrr: 1.0, queryLatency: 0.1)
        let excluded = makeScore(questionID: "q2", guardHealthy: false,
                                 recallAny1: 0.0, mrr: 0.0, queryLatency: 0.2)
        let (agg, lat) = aggregateLMEScores([healthy, excluded])
        #expect(agg.queryCount == 1)
        #expect(abs(agg.recallAnyAt1 - 1.0) < 1e-9,
                "aggregate should be over 1 healthy question only, not diluted by excluded")
        #expect(abs(agg.mrr - 1.0) < 1e-9)
        // Latency uses ALL questions (healthy + excluded).
        // Two latencies: 0.1 and 0.2. P50 = lmePercentile([0.1, 0.2], 0.5).
        // rank = ceil(0.5 * 2) = 1. index = 0. → 0.1
        #expect(abs(lat.queryP50Seconds - 0.1) < 1e-9)
    }

    @Test("aggregateLMEScores: mean is correct across multiple healthy questions")
    func aggregateMean() {
        // Two healthy questions: recall_any@1 = 1.0 and 0.0. Mean should be 0.5.
        let s1 = makeScore(questionID: "q1", guardHealthy: true,
                           recallAny1: 1.0, mrr: 1.0, queryLatency: 0.1)
        let s2 = makeScore(questionID: "q2", guardHealthy: true,
                           recallAny1: 0.0, mrr: 0.0, queryLatency: 0.3)
        let (agg, _) = aggregateLMEScores([s1, s2])
        #expect(agg.queryCount == 2)
        #expect(abs(agg.recallAnyAt1 - 0.5) < 1e-9)
        #expect(abs(agg.mrr - 0.5) < 1e-9)
    }

    // MARK: Report round-trip

    @Test("LMEReport encodes and decodes with all key fields intact")
    func reportRoundTrip() throws {
        let corpusStats = LMEReportCorpusStats(questionsLoaded: 100, abstentionExcluded: 10,
                                               questionsRun: 5, guardExcluded: 1)
        let aggregate = LMEReportAggregate(queryCount: 4,
                                           recallAnyAt1: 0.75, recallAnyAt5: 0.90,
                                           recallAnyAt10: 0.95,
                                           recallAllAt1: 0.50, recallAllAt5: 0.80,
                                           recallAllAt10: 0.90,
                                           mrr: 0.70)
        let latency = LMEReportLatency(queryP50Seconds: 0.15, queryP95Seconds: 0.30,
                                       queryMeanSeconds: 0.16, writeMeanSeconds: 0.05)
        let pq = LMEReportPerQuestion(
            questionID: "gpt4_abc", questionType: "multi-session",
            turnsIngested: 42, guardHealthy: true, guardDiagnostic: nil,
            recallAnyAt1: 1.0, recallAnyAt5: 1.0, recallAnyAt10: 1.0,
            recallAllAt1: 0.0, recallAllAt5: 1.0, recallAllAt10: 1.0,
            mrr: 1.0,
            queryLatencySeconds: 0.15, writeMeanLatencySeconds: 0.05,
            rankedSessionIDs: ["sess_a", "sess_b"],
            answerSessionIDs: ["sess_a", "sess_c"],
            retrievedUUIDCount: 8,
            exactDiscrimination: "discrimination: high — clear top result.",
            exactRecallProvenance: "recall_provenance: dense_lane:active degraded_stages:none",
            denseDiscrimination: nil,
            denseRecallProvenance: nil
        )
        let tokenEfficiency = LMEReportTokenEfficiency(
            exactArmMeanTokens: 1200.0, denseArmMeanTokens: 300.0,
            denseExactTokenRatio: 0.25,
            exactEvidenceHitRate: nil, denseEvidenceHitRate: nil,
            exactHitsPer1kTokens: nil, denseHitsPer1kTokens: nil,
            exactTokensPerResult: 42.0, denseTokensPerResult: nil,
            denseExactTokensPerResultRatio: nil
        )
        let laneHealth = LMEReportLaneHealth(
            exactDiscriminationDistribution: ["high": 1],
            denseDiscriminationDistribution: [:],
            exactDenseLaneDarkCount: 0,
            exactDegradedCount: 0,
            denseDegradedCount: 0
        )
        let report = LMEReport(
            runID: "TEST-RUN-ID", runLabel: "lme-s-seed20260725",
            variant: "s", generatedAt: "2026-07-25T00:00:00Z",
            corpusStats: corpusStats, aggregate: aggregate,
            latency: latency, perQuestion: [pq],
            tokenEfficiency: tokenEfficiency,
            encodeBarrier: "drain",
            laneHealth: laneHealth
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)

        let decoded = try JSONDecoder().decode(LMEReport.self, from: data)

        // Verify top-level fields.
        #expect(decoded.runID == "TEST-RUN-ID")
        #expect(decoded.runLabel == "lme-s-seed20260725")
        #expect(decoded.variant == "s")
        // Verify contract key names in the raw JSON (check the key spelling directly).
        let rawJSON = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let aggJSON = try #require(rawJSON["aggregate"] as? [String: Any])
        #expect(aggJSON["query_count"] != nil, "contract key 'query_count' must be present")
        #expect(aggJSON["mrr"] != nil, "contract key 'mrr' must be present")
        #expect(aggJSON["recall_any_at_1"] != nil, "key 'recall_any_at_1' must be present")
        #expect(aggJSON["recall_all_at_1"] != nil, "key 'recall_all_at_1' must be present")
        // Verify the LME-03 additive token_efficiency key is present (and has correct sub-keys).
        #expect(rawJSON["token_efficiency"] != nil, "additive key 'token_efficiency' must be present")
        let teJSON = try #require(rawJSON["token_efficiency"] as? [String: Any])
        #expect(teJSON["exact_arm_mean_tokens"] != nil, "key 'exact_arm_mean_tokens' must be present")
        #expect(teJSON["dense_arm_mean_tokens"] != nil, "key 'dense_arm_mean_tokens' must be present")
        #expect(teJSON["dense_exact_token_ratio"] != nil, "key 'dense_exact_token_ratio' must be present")
        // Defect 2 additive keys.
        #expect(teJSON["exact_tokens_per_result"] != nil, "key 'exact_tokens_per_result' must be present")
        // Defect 3 + Defect 1 additive keys.
        #expect(rawJSON["encode_barrier"] != nil, "key 'encode_barrier' must be present")
        #expect(rawJSON["lane_health"] != nil, "key 'lane_health' must be present")
        let lhJSON = try #require(rawJSON["lane_health"] as? [String: Any])
        #expect(lhJSON["exact_discrimination_distribution"] != nil)
        #expect(lhJSON["exact_dense_lane_dark_count"] != nil)
        // Per-question provenance keys.
        let pqJSON = try #require((rawJSON["per_question"] as? [[String: Any]])?.first)
        #expect(pqJSON["exact_discrimination"] != nil, "key 'exact_discrimination' must be present")

        // Verify aggregate round-trips correctly.
        #expect(abs(decoded.aggregate.recallAnyAt1 - 0.75) < 1e-9)
        #expect(abs(decoded.aggregate.mrr - 0.70) < 1e-9)

        // Verify per_question round-trips correctly.
        let dq = try #require(decoded.perQuestion.first)
        #expect(dq.questionID == "gpt4_abc")
        #expect(dq.turnsIngested == 42)
        #expect(dq.guardHealthy == true)
        #expect(dq.rankedSessionIDs == ["sess_a", "sess_b"])
    }

    // MARK: scoreLMEQuestion (unit — no live MCP)

    @Test("scoreLMEQuestion: guard-excluded result gets zeroed metrics")
    func scoreGuardExcluded() {
        let result = LMEQuestionResult(
            questionID: "q-excluded",
            questionType: "multi-session",
            queryLatencySeconds: 0.12,
            retrievedUUIDs: ["uuid-1"],
            manifest: [LMEManifestEntry(uuid: "uuid-1", sessionID: "sess_a",
                                        turnIndex: 0, sessionIndex: 0, role: "user")],
            answerSessionIDs: ["sess_a"],
            guardHealthy: false,
            guardDiagnostic: "queryInvariant: identical rankings across all probes",
            turnsIngested: 3,
            writeMeanLatencySeconds: 0.05,
            exactPayloadText: nil,
            densePayloadText: nil,
            denseQueryLatencySeconds: nil,
            exactJudgeAnswer: nil,
            exactJudgeCorrect: nil,
            denseJudgeAnswer: nil,
            denseJudgeCorrect: nil
        )
        let score = scoreLMEQuestion(result)
        #expect(score.guardHealthy == false)
        #expect(score.recallAnyAt1 == 0.0)
        #expect(score.recallAnyAt5 == 0.0)
        #expect(score.recallAnyAt10 == 0.0)
        #expect(score.recallAllAt1 == 0.0)
        #expect(score.mrr == 0.0)
        // Latency must still be recorded.
        #expect(abs(score.queryLatencySeconds - 0.12) < 1e-9)
    }

    @Test("scoreLMEQuestion: healthy guard with hit at rank 1 scores correctly")
    func scoreHealthyHitRank1() {
        let result = LMEQuestionResult(
            questionID: "q-hit",
            questionType: "single-session-user",
            queryLatencySeconds: 0.10,
            retrievedUUIDs: ["uuid-a", "uuid-b"],
            manifest: [
                LMEManifestEntry(uuid: "uuid-a", sessionID: "sess_a",
                                 turnIndex: 0, sessionIndex: 0, role: "user"),
                LMEManifestEntry(uuid: "uuid-b", sessionID: "sess_b",
                                 turnIndex: 1, sessionIndex: 1, role: "assistant"),
            ],
            answerSessionIDs: ["sess_a"],
            guardHealthy: true,
            guardDiagnostic: nil,
            turnsIngested: 2,
            writeMeanLatencySeconds: 0.04,
            exactPayloadText: nil,
            densePayloadText: nil,
            denseQueryLatencySeconds: nil,
            exactJudgeAnswer: nil,
            exactJudgeCorrect: nil,
            denseJudgeAnswer: nil,
            denseJudgeCorrect: nil
        )
        let score = scoreLMEQuestion(result)
        #expect(score.guardHealthy == true)
        #expect(abs(score.recallAnyAt1 - 1.0) < 1e-9)
        #expect(abs(score.mrr - 1.0) < 1e-9)
        #expect(score.rankedSessionIDs == ["sess_a", "sess_b"])
    }
}

// MARK: - Provenance parsing unit tests (Defect 3)

@Suite("LME provenance parsing")
struct LMEProvenanceParsingTests {

    @Test("lmeParseResultCount: extracts N from 'found N memory(s)'")
    func parseResultCountMemory() {
        let payload = "found 7 memory(s)\n\nsome content"
        #expect(lmeParseResultCount(payload) == 7)
    }

    @Test("lmeParseResultCount: extracts N from 'found N distilled factoid(s)'")
    func parseResultCountDistilled() {
        let payload = "found 3 distilled factoid(s)\n\nsome factoid content"
        #expect(lmeParseResultCount(payload) == 3)
    }

    @Test("lmeParseResultCount: handles 'for: ...' suffix correctly")
    func parseResultCountWithSuffix() {
        let payload = "found 12 memory(s) for: user: hello\n\nresult text"
        #expect(lmeParseResultCount(payload) == 12)
    }

    @Test("lmeParseResultCount: returns nil for 'no memories found'")
    func parseResultCountNoMemories() {
        let payload = "no memories found."
        #expect(lmeParseResultCount(payload) == nil)
    }

    @Test("lmeParseResultCount: returns nil for empty payload")
    func parseResultCountEmpty() {
        #expect(lmeParseResultCount("") == nil)
    }

    @Test("lmeParseDiscriminationLine: extracts high discrimination line")
    func parseDiscriminationHigh() {
        let payload = "found 5 memory(s)\n\nresult text\ndiscrimination: high — clear top result.\nrecall_provenance: dense_lane:active degraded_stages:none"
        let line = lmeParseDiscriminationLine(payload)
        #expect(line == "discrimination: high — clear top result.")
    }

    @Test("lmeParseDiscriminationLine: returns nil when absent")
    func parseDiscriminationAbsent() {
        let payload = "found 5 memory(s)\n\nresult text with no diagnostics"
        #expect(lmeParseDiscriminationLine(payload) == nil)
    }

    @Test("lmeParseRecallProvenanceLine: extracts active dense lane line")
    func parseProvenanceActiveLane() {
        let payload = "found 3 memory(s)\n\nresult\ndiscrimination: medium — partial separation.\nrecall_provenance: dense_lane:active degraded_stages:none"
        let line = lmeParseRecallProvenanceLine(payload)
        #expect(line == "recall_provenance: dense_lane:active degraded_stages:none")
    }

    @Test("lmeParseRecallProvenanceLine: extracts dark dense lane line")
    func parseProvenanceDarkLane() {
        let payload = "found 2 memory(s)\n\nresult\nrecall_provenance: dense_lane:dark:encode_backlog degraded_stages:none"
        let line = lmeParseRecallProvenanceLine(payload)
        #expect(line?.contains("dense_lane:dark:") == true)
    }

    @Test("lmeExtractDiscriminationLevel: extracts each level correctly")
    func extractDiscriminationLevels() {
        #expect(lmeExtractDiscriminationLevel("discrimination: high — clear top result.") == "high")
        #expect(lmeExtractDiscriminationLevel("discrimination: medium — partial separation.") == "medium")
        #expect(lmeExtractDiscriminationLevel("discrimination: low — top results are within epsilon") == "low")
        #expect(lmeExtractDiscriminationLevel("discrimination: not_found — query contains distinctive tokens") == "not_found")
        #expect(lmeExtractDiscriminationLevel("discrimination: n/a — single/zero results.") == "n/a")
    }
}

// MARK: - Tokens-per-result arithmetic cancellation test (Defect 2)

@Suite("LME tokens-per-result: arithmetic cancellation case")
struct LMETokensPerResultTests {

    // The arithmetic-cancellation case: 20 exact results × 168 chars each vs
    // 8 dense results × 414 chars each. Total byte counts are nearly equal
    // (~3360 vs ~3312), so the naive dense/exact token ratio ≈ 1.0. But
    // dense delivers far fewer results per token cost:
    //   exact tpr: (3360+3)/4 tokens / 20 results ≈ 42.05 tokens/result
    //   dense tpr: (3312+3)/4 tokens / 8 results  ≈ 103.5 tokens/result
    //   per-result ratio: 103.5 / 42.05 ≈ 2.46 ≈ 2.5 (not 1.0)
    @Test("Arithmetic cancellation: per-result ratio ≈ 2.5 while token ratio ≈ 1.0")
    func arithmeticCancellationCase() {
        // Build 20 exact results × 168 UTF-8 chars each.
        let exactItemText = String(repeating: "x", count: 168)
        let exactPayload = "found 20 memory(s)\n" + Array(repeating: exactItemText, count: 20).joined(separator: "\n")
        // Build 8 dense results × 414 UTF-8 chars each.
        let denseItemText = String(repeating: "y", count: 414)
        let densePayload = "found 8 distilled factoid(s)\n" + Array(repeating: denseItemText, count: 8).joined(separator: "\n")

        let exactCount = lmeParseResultCount(exactPayload)
        let denseCount = lmeParseResultCount(densePayload)
        #expect(exactCount == 20, "exact result count should be 20")
        #expect(denseCount == 8, "dense result count should be 8")

        let exactTokens = lmeEstimateTokens(exactPayload)
        let denseTokens = lmeEstimateTokens(densePayload)

        // Byte ratio ≈ 1.0 (naive test incorrectly signals parity).
        let byteRatio = Double(exactPayload.utf8.count) / Double(densePayload.utf8.count)
        #expect(abs(byteRatio - 1.0) < 0.15, "byte ratio should be near 1.0 (≈\(byteRatio))")

        // Per-result ratio ≈ 2.5 (correct signal that dense costs more per result).
        let exactTPR = Double(exactTokens) / Double(exactCount!)
        let denseTPR = Double(denseTokens) / Double(denseCount!)
        let perResultRatio = denseTPR / exactTPR
        #expect(perResultRatio > 2.0 && perResultRatio < 3.5,
                "per-result ratio should be ≈ 2.5, got \(perResultRatio)")
    }
}

// MARK: - Test helpers

/// Builds a minimal LMEQuestionScore for aggregate / guard-exclusion tests.
private func makeScore(
    questionID: String,
    guardHealthy: Bool,
    recallAny1: Double,
    mrr: Double,
    queryLatency: Double
) -> LMEQuestionScore {
    LMEQuestionScore(
        questionID: questionID,
        questionType: "single-session-user",
        guardHealthy: guardHealthy,
        guardDiagnostic: guardHealthy ? nil : "test-diagnostic",
        recallAnyAt1: recallAny1, recallAnyAt5: recallAny1, recallAnyAt10: recallAny1,
        recallAllAt1: recallAny1, recallAllAt5: recallAny1, recallAllAt10: recallAny1,
        mrr: mrr,
        rankedSessionIDs: [],
        answerSessionIDs: ["sess_x"],
        queryLatencySeconds: queryLatency,
        writeMeanLatencySeconds: 0.01,
        turnsIngested: 5,
        retrievedUUIDCount: 3
    )
}
