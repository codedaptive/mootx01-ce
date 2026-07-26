import XCTest
@testable import mcp_benchmarker

// LoCoMoScorerTests.swift — Unit tests for LoCoMo scoring math.
//
// All expected values are driven by conformance/locomo_vectors.json so that
// the same hand-computed values drive both the Swift and Rust test suites.
// The test logic mirrors LongMemEvalScorerTests.swift.

final class LoCoMoScorerTests: XCTestCase {

    // MARK: - Helpers

    /// Load and parse the locomo_vectors.json conformance file.
    private func loadLoCoMoVectors() throws -> [String: Any] {
        // Locate conformance/ relative to this test file.
        // #filePath = Tests/mcp-benchmarkerTests/LoCoMoScorerTests.swift
        // 3 levels up → apps/mcp-benchmarker/
        let testFile = URL(fileURLWithPath: #filePath)
        let benchRoot = testFile
            .deletingLastPathComponent()    // mcp-benchmarkerTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // Sources (wrong — see below)
        // Actually: Tests/mcp-benchmarkerTests/ is sibling to Sources/; both
        // are under apps/mcp-benchmarker/. So we need:
        // #filePath → .../Tests/mcp-benchmarkerTests/LoCoMoScorerTests.swift
        // parent → .../Tests/mcp-benchmarkerTests/
        // parent → .../Tests/
        // parent → .../apps/mcp-benchmarker/
        let benchRootFixed = testFile
            .deletingLastPathComponent()    // .../Tests/mcp-benchmarkerTests/
            .deletingLastPathComponent()    // .../Tests/
            .deletingLastPathComponent()    // .../apps/mcp-benchmarker/
        let vectorURL = benchRootFixed
            .appendingPathComponent("conformance")
            .appendingPathComponent("locomo_vectors.json")

        guard FileManager.default.fileExists(atPath: vectorURL.path) else {
            throw XCTSkip("locomo_vectors.json not found at \(vectorURL.path)")
        }
        let data = try Data(contentsOf: vectorURL)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Recall conformance vectors

    func testRecallConformanceVectors() throws {
        let vectors = try loadLoCoMoVectors()
        guard let cases = vectors["recall_cases"] as? [[String: Any]] else {
            XCTFail("recall_cases missing from locomo_vectors.json")
            return
        }

        for c in cases {
            let id = c["id"] as! String
            let rankedDiaIDs = c["ranked_dia_ids"] as! [String]
            let evidenceDiaIDs = c["evidence_dia_ids"] as! [String]
            let evidenceSet = Set(evidenceDiaIDs)

            let expRa1  = c["recall_any_at_1"] as! Double
            let expRa5  = c["recall_any_at_5"] as! Double
            let expRa10 = c["recall_any_at_10"] as! Double
            let expRl1  = c["recall_all_at_1"] as! Double
            let expRl5  = c["recall_all_at_5"] as! Double
            let expRl10 = c["recall_all_at_10"] as! Double
            let expMRR  = c["mrr"] as! Double

            let tol = 1e-9

            // LoCoMo reuses the LME scoring math directly with dia_ids.
            let gotRa1  = lmeRecallAny(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 1)
            let gotRa5  = lmeRecallAny(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 5)
            let gotRa10 = lmeRecallAny(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 10)
            let gotRl1  = lmeRecallAll(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 1)
            let gotRl5  = lmeRecallAll(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 5)
            let gotRl10 = lmeRecallAll(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet, k: 10)
            let gotMRR  = lmeSessionMRR(rankedSessions: rankedDiaIDs, answerIDs: evidenceSet)

            XCTAssertEqual(gotRa1,  expRa1,  accuracy: tol, "'\(id)' recall_any_at_1")
            XCTAssertEqual(gotRa5,  expRa5,  accuracy: tol, "'\(id)' recall_any_at_5")
            XCTAssertEqual(gotRa10, expRa10, accuracy: tol, "'\(id)' recall_any_at_10")
            XCTAssertEqual(gotRl1,  expRl1,  accuracy: tol, "'\(id)' recall_all_at_1")
            XCTAssertEqual(gotRl5,  expRl5,  accuracy: tol, "'\(id)' recall_all_at_5")
            XCTAssertEqual(gotRl10, expRl10, accuracy: tol, "'\(id)' recall_all_at_10")
            XCTAssertEqual(gotMRR,  expMRR,  accuracy: tol, "'\(id)' mrr")
        }
    }

    // MARK: - UUID→dia_id mapping conformance vectors

    func testUUIDMappingConformanceVectors() throws {
        let vectors = try loadLoCoMoVectors()
        guard let cases = vectors["uuid_mapping_cases"] as? [[String: Any]] else {
            XCTFail("uuid_mapping_cases missing from locomo_vectors.json")
            return
        }

        for c in cases {
            let id = c["id"] as! String
            let retrievedUUIDs = c["retrieved_uuids"] as! [String]
            let rawManifest = c["manifest"] as! [[String: Any]]
            let expectedRankedDiaIDs = c["expected_ranked_dia_ids"] as! [String]

            // Build manifest as LMEManifestEntry (diaID in sessionID slot).
            let manifest: [LMEManifestEntry] = rawManifest.map { entry in
                LMEManifestEntry(
                    uuid: entry["uuid"] as! String,
                    sessionID: entry["dia_id"] as! String,  // dia_id → sessionID slot
                    turnIndex: 0,
                    sessionIndex: 0,
                    role: "speaker"
                )
            }

            let gotRanked = lmeRankedSessions(uuids: retrievedUUIDs, manifest: manifest)
            XCTAssertEqual(gotRanked, expectedRankedDiaIDs,
                           "'\(id)' uuid_mapping: expected \(expectedRankedDiaIDs), got \(gotRanked)")
        }
    }

    // MARK: - Per-category breakdown

    func testCategoryBreakdownSingleCategory() {
        // Create 3 scored questions, all single_hop.
        let scores: [LoCoMoQuestionScore] = [
            makeScore(category: 1, label: "single_hop", guardHealthy: true,
                      ra5: 1.0, rl5: 1.0, mrr: 1.0),
            makeScore(category: 1, label: "single_hop", guardHealthy: true,
                      ra5: 0.0, rl5: 0.0, mrr: 0.0),
            makeScore(category: 1, label: "single_hop", guardHealthy: true,
                      ra5: 1.0, rl5: 0.0, mrr: 0.5),
        ]
        let (_, cats, _) = aggregateLoCoMoScores(scores)
        let singleHop = cats.first(where: { $0.label == "single_hop" })!
        XCTAssertEqual(singleHop.queryCount, 3)
        XCTAssertEqual(singleHop.recallAnyAt5, (1.0 + 0.0 + 1.0) / 3.0,
                       accuracy: 1e-9, "single_hop recall_any@5")
        XCTAssertEqual(singleHop.recallAllAt5, (1.0 + 0.0 + 0.0) / 3.0,
                       accuracy: 1e-9, "single_hop recall_all@5")
        XCTAssertEqual(singleHop.mrr, (1.0 + 0.0 + 0.5) / 3.0,
                       accuracy: 1e-9, "single_hop mrr")
        // Other categories should have queryCount = 0.
        for cat in cats where cat.label != "single_hop" {
            XCTAssertEqual(cat.queryCount, 0, "\(cat.label) must have 0 questions")
        }
    }

    func testCategoryBreakdownMixedCategories() {
        let scores: [LoCoMoQuestionScore] = [
            makeScore(category: 1, label: "single_hop", guardHealthy: true, ra5: 1.0, rl5: 1.0, mrr: 1.0),
            makeScore(category: 2, label: "temporal",   guardHealthy: true, ra5: 0.5, rl5: 0.0, mrr: 0.5),
            makeScore(category: 3, label: "multi_hop",  guardHealthy: true, ra5: 1.0, rl5: 0.0, mrr: 1.0),
            makeScore(category: 4, label: "open_domain",guardHealthy: true, ra5: 0.0, rl5: 0.0, mrr: 0.0),
        ]
        let (agg, cats, _) = aggregateLoCoMoScores(scores)
        XCTAssertEqual(agg.queryCount, 4)
        // Overall recall_any@5 = (1+0.5+1+0)/4 = 2.5/4 = 0.625
        XCTAssertEqual(agg.recallAnyAt5, 0.625, accuracy: 1e-9, "overall recall_any@5")
        for cat in cats {
            XCTAssertEqual(cat.queryCount, 1, "\(cat.label) must have 1 question")
        }
    }

    func testGuardExcludedNotCountedInCategories() {
        let scores: [LoCoMoQuestionScore] = [
            makeScore(category: 1, label: "single_hop", guardHealthy: true,  ra5: 1.0, rl5: 1.0, mrr: 1.0),
            makeScore(category: 1, label: "single_hop", guardHealthy: false, ra5: 0.0, rl5: 0.0, mrr: 0.0),
        ]
        let (agg, cats, _) = aggregateLoCoMoScores(scores)
        XCTAssertEqual(agg.queryCount, 1, "only 1 guard-healthy question")
        let singleHop = cats.first(where: { $0.label == "single_hop" })!
        XCTAssertEqual(singleHop.queryCount, 1, "guard-excluded question must not count in category")
    }

    // MARK: - Aggregate

    func testAggregateAllHealthy() {
        let scores = (0..<4).map { _ in
            makeScore(category: 1, label: "single_hop", guardHealthy: true,
                      ra5: 1.0, rl5: 1.0, mrr: 1.0)
        }
        let (agg, _, _) = aggregateLoCoMoScores(scores)
        XCTAssertEqual(agg.queryCount, 4)
        XCTAssertEqual(agg.recallAnyAt5, 1.0, accuracy: 1e-9)
        XCTAssertEqual(agg.mrr, 1.0, accuracy: 1e-9)
    }

    func testAggregateAllGuardExcluded() {
        let scores = (0..<3).map { _ in
            makeScore(category: 1, label: "single_hop", guardHealthy: false,
                      ra5: 0.0, rl5: 0.0, mrr: 0.0)
        }
        let (agg, _, _) = aggregateLoCoMoScores(scores)
        XCTAssertEqual(agg.queryCount, 0)
        XCTAssertEqual(agg.recallAnyAt5, 0.0, accuracy: 1e-9)
    }

    func testAggregateEmptyInput() {
        let (agg, cats, lat) = aggregateLoCoMoScores([])
        XCTAssertEqual(agg.queryCount, 0)
        XCTAssertEqual(cats.count, 4, "4 category buckets always returned")
        for cat in cats { XCTAssertEqual(cat.queryCount, 0) }
        XCTAssertEqual(lat.queryP50Seconds, 0.0, accuracy: 1e-9)
    }

    // MARK: - Latency stats

    func testLatencyP50P95() {
        let latencies = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        let scores: [LoCoMoQuestionScore] = latencies.enumerated().map { idx, lat in
            makeScoreWithLatency(category: 1, label: "single_hop",
                                 queryLatency: lat, writeLatency: 0.01)
        }
        let (_, _, latStats) = aggregateLoCoMoScores(scores)
        // p50 of [0.1..1.0] (10 values) = sorted[ceil(0.5*10)-1] = sorted[4] = 0.5
        XCTAssertEqual(latStats.queryP50Seconds, 0.5, accuracy: 1e-9)
        // p95 = sorted[ceil(0.95*10)-1] = sorted[9] = 1.0
        XCTAssertEqual(latStats.queryP95Seconds, 1.0, accuracy: 1e-9)
    }

    // MARK: - Score question function

    func testScoreLoCoMoQuestionBasic() {
        // One retrieved UUID mapping to the evidence dia_id.
        let manifest = [
            LoCoMoManifestEntry(uuid: "uuid-1", diaID: "D1:3",
                                sessionNumber: 1, turnIndex: 2, speaker: "Alice"),
            LoCoMoManifestEntry(uuid: "uuid-2", diaID: "D2:1",
                                sessionNumber: 2, turnIndex: 0, speaker: "Bob"),
        ]
        let result = LoCoMoQuestionResult(
            questionID: "test-q-0",
            categoryLabel: "single_hop",
            category: 1,
            queryLatencySeconds: 0.05,
            retrievedUUIDs: ["uuid-1", "uuid-2"],
            manifest: manifest,
            evidenceDiaIDs: ["D1:3"],
            guardHealthy: true,
            guardDiagnostic: nil,
            turnsIngested: 2,
            writeMeanLatencySeconds: 0.01
        )
        let score = scoreLoCoMoQuestion(result)
        XCTAssertEqual(score.questionID, "test-q-0")
        XCTAssertEqual(score.categoryLabel, "single_hop")
        XCTAssertEqual(score.recallAnyAt1, 1.0, accuracy: 1e-9, "D1:3 at rank 1")
        XCTAssertEqual(score.recallAnyAt5, 1.0, accuracy: 1e-9)
        XCTAssertEqual(score.mrr, 1.0, accuracy: 1e-9, "MRR=1 when evidence at rank 1")
        XCTAssertEqual(score.rankedDiaIDs, ["D1:3", "D2:1"],
                       "manifest maps uuid-1→D1:3, uuid-2→D2:1")
    }

    func testScoreLoCoMoQuestionGuardExcluded() {
        let result = LoCoMoQuestionResult(
            questionID: "test-q-1",
            categoryLabel: "temporal",
            category: 2,
            queryLatencySeconds: 0.05,
            retrievedUUIDs: ["uuid-1"],
            manifest: [LoCoMoManifestEntry(uuid: "uuid-1", diaID: "D1:3",
                                            sessionNumber: 1, turnIndex: 2, speaker: "Alice")],
            evidenceDiaIDs: ["D1:3"],
            guardHealthy: false,
            guardDiagnostic: "backend returned identical results for all queries",
            turnsIngested: 1,
            writeMeanLatencySeconds: 0.01
        )
        let score = scoreLoCoMoQuestion(result)
        XCTAssertFalse(score.guardHealthy)
        // Guard-excluded: all metrics zero regardless of what was retrieved.
        XCTAssertEqual(score.recallAnyAt1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(score.recallAnyAt5, 0.0, accuracy: 1e-9)
        XCTAssertEqual(score.mrr, 0.0, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeScore(
        category: Int,
        label: String,
        guardHealthy: Bool,
        ra5: Double,
        rl5: Double,
        mrr: Double
    ) -> LoCoMoQuestionScore {
        LoCoMoQuestionScore(
            questionID: "q-\(UUID().uuidString)",
            categoryLabel: label,
            category: category,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardHealthy ? nil : "test guard failure",
            recallAnyAt1: 0,
            recallAnyAt5: ra5,
            recallAnyAt10: ra5,
            recallAllAt1: 0,
            recallAllAt5: rl5,
            recallAllAt10: rl5,
            mrr: mrr,
            rankedDiaIDs: [],
            evidenceDiaIDs: [],
            queryLatencySeconds: 0.05,
            writeMeanLatencySeconds: 0.01,
            turnsIngested: 5,
            retrievedUUIDCount: 3
        )
    }

    private func makeScoreWithLatency(
        category: Int,
        label: String,
        queryLatency: Double,
        writeLatency: Double
    ) -> LoCoMoQuestionScore {
        LoCoMoQuestionScore(
            questionID: "q-\(UUID().uuidString)",
            categoryLabel: label,
            category: category,
            guardHealthy: true,
            guardDiagnostic: nil,
            recallAnyAt1: 0, recallAnyAt5: 0, recallAnyAt10: 0,
            recallAllAt1: 0, recallAllAt5: 0, recallAllAt10: 0,
            mrr: 0,
            rankedDiaIDs: [],
            evidenceDiaIDs: [],
            queryLatencySeconds: queryLatency,
            writeMeanLatencySeconds: writeLatency,
            turnsIngested: 5,
            retrievedUUIDCount: 3
        )
    }
}
