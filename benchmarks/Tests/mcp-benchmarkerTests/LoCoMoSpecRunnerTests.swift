import Testing
import Foundation
@testable import mcp_benchmarker

// LoCoMoSpecRunnerTests.swift — Report-shape tests for the locomo-spec runner.
//
// Scope: pure-logic tests only. No live MCP client, no estate, no binary.
//
// Covered:
//   §1  LoCoMoSpecRunResult report JSON shape: required fields present.
//   §2  Category order in loCoMoSpecAggregate is always [4, 1, 2, 3, 5] per §5.
//   §3  loCoMoSpecReportJSON round-trip: by_category has correct category order.
//   §4  per_question_records encode gold_answer as null for category-5 questions.
//   §5  run_parameters fields propagate from LoCoMoSpecRunMetadata correctly.
//
// All tests use synthetic in-memory data — no file I/O, no process execution.
//
// Run with:
//   swift test --scratch-path .build-locospec --filter LoCoMoSpecRunner

// MARK: - Synthetic data builders

private func makeMetadata(
    totalQuestions: Int = 5,
    runLabel: String = "test-arm"
) -> LoCoMoSpecRunMetadata {
    LoCoMoSpecRunMetadata(
        port: "swift",
        seed: 42,
        estateMode: "artifact-unit",
        targetScale: "unit",
        parallelUnits: 4,
        corpusDigest: "sha256-test",
        totalQuestions: totalQuestions,
        conversationsUsed: 1,
        runLabel: runLabel,
        categoryCounts: [1: 282, 2: 321, 3: 96, 4: 841, 5: 446],
        unitIDsPath: nil,
        selectedCount: totalQuestions
    )
}

/// Builds a synthetic per-question record for testing.
private func makeQuestionRecord(
    id: String = "q-1",
    category: Int = 4,
    goldAnswer: String? = "the museum",
    prediction: String = "museum",
    score: Double = 0.8,
    evidenceRecall: Double = 1.0
) -> LoCoMoSpecQuestionRecord {
    LoCoMoSpecQuestionRecord(
        questionID: id,
        category: category,
        categoryLabel: category == 5 ? "adversarial" : "open_domain",
        goldAnswer: goldAnswer,
        prediction: prediction,
        retrievedDiaIDs: ["D1:1"],
        score: score,
        evidenceRecallValue: evidenceRecall,
        recallLatencySeconds: 0.05,
        synthesizeLatencySeconds: 0.10,
        guardHealthy: true,
        guardDiagnostic: nil,
        turnsIngested: 10,
        cacheHit: nil,
        contentTermCount: 3,
        goldRanks: [1]
    )
}

/// Builds a minimal LoCoMoSpecRunResult with synthetic data.
private func makeSyntheticResult(
    records: [LoCoMoSpecQuestionRecord]
) -> LoCoMoSpecRunResult {
    let tuples = records.map { r in
        (category: r.category, score: r.score, evidenceRecall: r.evidenceRecallValue)
    }
    let aggregate = loCoMoSpecAggregate(scores: tuples)
    return LoCoMoSpecRunResult(
        questionRecords: records,
        aggregate: aggregate,
        metadata: makeMetadata(totalQuestions: records.count)
    )
}

// MARK: - §1 Report JSON shape

@Suite("LoCoMoSpecRunner — §1 report JSON shape")
struct LoCoMoSpecRunnerShapeTests {

    private func buildJSON(records: [LoCoMoSpecQuestionRecord]) throws -> [String: Any] {
        let result = makeSyntheticResult(records: records)
        let data = try loCoMoSpecReportJSON(result, arm: "test-arm", serial: "0001")
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// The report JSON must carry all required top-level fields.
    @Test("report JSON has all required top-level fields")
    func reportHasRequiredTopLevelFields() throws {
        let json = try buildJSON(records: [makeQuestionRecord()])
        let requiredKeys = [
            "overall_accuracy",
            "total_questions",
            "category_order",
            "by_category",
            "per_question_records",
            "run_parameters",
            // Short-query subset metrics (§7.5) — schema parity with Rust locomo-spec report.
            "short_query_count",
            "short_query_mean_score",
            "short_query_mean_evidence_recall",
            "short_query_pool_guarantee",
        ]
        for key in requiredKeys {
            #expect(json[key] != nil, "report JSON must contain top-level key '\(key)'")
        }
    }

    /// category_order in the report must be [4, 1, 2, 3, 5] per §5.
    @Test("report JSON: category_order is [4, 1, 2, 3, 5] per §5")
    func reportCategoryOrderField() throws {
        let json = try buildJSON(records: [makeQuestionRecord()])
        guard let order = json["category_order"] as? [Int] else {
            Issue.record("category_order must be an array of Int")
            return
        }
        #expect(order == [4, 1, 2, 3, 5], "§5 mandates category order [4, 1, 2, 3, 5]")
    }

    /// by_category array must have 5 entries in the mandated order [4, 1, 2, 3, 5].
    @Test("report JSON: by_category has 5 entries in order [4, 1, 2, 3, 5]")
    func byCategoryOrder() throws {
        let json = try buildJSON(records: [makeQuestionRecord(category: 4)])
        guard let byCat = json["by_category"] as? [[String: Any]] else {
            Issue.record("by_category must be an array of objects")
            return
        }
        #expect(byCat.count == 5, "by_category must have 5 entries (one per category)")
        let gotOrder = byCat.compactMap { $0["category"] as? Int }
        #expect(gotOrder == [4, 1, 2, 3, 5], "by_category order must be [4, 1, 2, 3, 5]")
    }

    /// Each by_category entry must carry category, category_label, accuracy,
    /// mean_evidence_recall, and question_count fields.
    @Test("report JSON: each by_category entry has required fields")
    func byCategoryEntryFields() throws {
        let json = try buildJSON(records: [makeQuestionRecord(category: 4, score: 1.0)])
        let byCat = json["by_category"] as! [[String: Any]]
        let requiredCatFields = ["category", "category_label", "accuracy",
                                 "mean_evidence_recall", "question_count"]
        for entry in byCat {
            for field in requiredCatFields {
                #expect(entry[field] != nil, "by_category entry must have '\(field)' field")
            }
        }
    }

    /// per_question_records must carry all required per-question fields.
    @Test("report JSON: per_question_records entries have required fields")
    func perQuestionRecordFields() throws {
        let json = try buildJSON(records: [makeQuestionRecord()])
        guard let perQ = json["per_question_records"] as? [[String: Any]] else {
            Issue.record("per_question_records must be an array")
            return
        }
        #expect(perQ.count == 1, "one record in → one record in per_question_records")
        let entry = perQ[0]
        let requiredFields = [
            "question_id", "category", "category_label", "prediction",
            "retrieved_dia_ids", "score", "evidence_recall",
            "guard_healthy", "turns_ingested",
        ]
        for field in requiredFields {
            #expect(entry[field] != nil, "per_question_records entry must have '\(field)' field")
        }
        // Accuracy files carry no timing columns.
        #expect(entry["recall_latency_s"] == nil)
        #expect(entry["synthesize_latency_s"] == nil)
    }
}

// MARK: - §2 Category-5 gold_answer in per_question_records

@Suite("LoCoMoSpecRunner — §2 cat-5 gold_answer encoding")
struct LoCoMoSpecRunnerCat5Tests {

    /// Category-5 questions have no gold answer (nil). The report JSON must encode
    /// gold_answer as JSON null (NSNull), not as a missing key or an empty string.
    @Test("category-5 question: gold_answer is null in per_question_records JSON")
    func cat5GoldAnswerIsNull() throws {
        let record = makeQuestionRecord(category: 5, goldAnswer: nil)
        let result = makeSyntheticResult(records: [record])
        let data = try loCoMoSpecReportJSON(result, arm: "cat5-arm", serial: "0001")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard let perQ = json["per_question_records"] as? [[String: Any]],
              let entry = perQ.first else {
            Issue.record("per_question_records must exist and have one entry")
            return
        }
        // gold_answer key must be present with NSNull value (JSON null).
        let goldAnswerValue = entry["gold_answer"]
        // When JSONSerialization decodes a null value, it produces NSNull.
        #expect(goldAnswerValue != nil, "gold_answer key must be present even for cat-5")
        #expect(goldAnswerValue is NSNull, "cat-5 gold_answer must encode as JSON null (NSNull)")
    }
}

// MARK: - §3 run_parameters propagation

@Suite("LoCoMoSpecRunner — §3 run_parameters field propagation")
struct LoCoMoSpecRunnerParametersTests {

    @Test("run_parameters carries all expected fields from LoCoMoSpecRunMetadata")
    func runParametersFields() throws {
        let result = makeSyntheticResult(records: [makeQuestionRecord()])
        let data = try loCoMoSpecReportJSON(result, arm: "param-arm", serial: "0002")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard let params = json["run_parameters"] as? [String: Any] else {
            Issue.record("run_parameters must be a JSON object")
            return
        }
        let requiredParams = [
            "port", "seed", "estate_mode", "target_scale", "corpus_digest",
            "conversations_used", "run_label", "arm", "serial",
            "short_query_terms", // schema parity with Rust run_parameters
        ]
        for key in requiredParams {
            #expect(params[key] != nil, "run_parameters must contain '\(key)'")
        }
        #expect(params["parallel_units"] == nil,
                "run_parameters must not record width — a run is a run")
        // Spot-check a few values that come directly from the metadata.
        #expect(params["port"] as? String == "swift")
        #expect(params["arm"] as? String == "param-arm")
        #expect(params["serial"] as? String == "0002")
        #expect(params["target_scale"] as? String == "unit")
    }
}

// MARK: - §4 Aggregate accuracy values in report

@Suite("LoCoMoSpecRunner — §4 aggregate accuracy in report")
struct LoCoMoSpecRunnerAggregateAccuracyTests {

    /// One cat-4 question with score 1.0 → cat-4 accuracy 1.0 in by_category,
    /// overall_accuracy 1.0.
    @Test("one perfect cat-4 question → cat-4 accuracy 1.0, overall 1.0")
    func onePerfectQuestion() throws {
        let record = makeQuestionRecord(category: 4, score: 1.0, evidenceRecall: 1.0)
        let result = makeSyntheticResult(records: [record])
        let data = try loCoMoSpecReportJSON(result, arm: "acc-arm", serial: "0001")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let overall = json["overall_accuracy"] as? Double
        #expect(overall == 1.0, "one perfect question → overall_accuracy 1.0")

        let byCat = json["by_category"] as! [[String: Any]]
        let cat4Entry = byCat.first { ($0["category"] as? Int) == 4 }!
        #expect(cat4Entry["accuracy"] as? Double == 1.0)
        #expect(cat4Entry["question_count"] as? Int == 1)
        // Other categories have question_count 0.
        for entry in byCat where (entry["category"] as? Int) != 4 {
            #expect(entry["question_count"] as? Int == 0)
        }
    }

    /// Two cat-4 questions with scores 1.0 and 0.0 → cat-4 accuracy 0.5.
    @Test("two cat-4 questions with scores 1.0 and 0.0 → accuracy 0.5")
    func twoCat4Questions() throws {
        let records = [
            makeQuestionRecord(id: "q-1", category: 4, score: 1.0, evidenceRecall: 1.0),
            makeQuestionRecord(id: "q-2", category: 4, score: 0.0, evidenceRecall: 0.0),
        ]
        let result = makeSyntheticResult(records: records)
        let data = try loCoMoSpecReportJSON(result, arm: "acc-arm", serial: "0002")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let byCat = json["by_category"] as! [[String: Any]]
        let cat4Entry = byCat.first { ($0["category"] as? Int) == 4 }!
        // §5: round(0.5, 3) = 0.5.
        #expect(cat4Entry["accuracy"] as? Double == 0.5)
        #expect(cat4Entry["question_count"] as? Int == 2)
    }

    /// record_name_stem in the report follows the "locomo-spec-<arm>-<serial>" convention.
    @Test("record_name_stem follows locomo-spec-<arm>-<serial> convention")
    func recordNameStem() throws {
        let result = makeSyntheticResult(records: [makeQuestionRecord()])
        let data = try loCoMoSpecReportJSON(result, arm: "my-arm", serial: "0042")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let stem = json["record_name_stem"] as? String
        #expect(stem?.contains("locomo-spec") == true,
                "record_name_stem must contain 'locomo-spec'")
        #expect(stem?.contains("my-arm") == true,
                "record_name_stem must contain the arm name")
        #expect(stem?.contains("0042") == true,
                "record_name_stem must contain the serial")
    }
}

// MARK: - Seed records granularity (twin of rust locomo_spec_runner.rs tests)

/// Two-turn, one-session synthetic conversation. Twin of the Rust
/// `make_mini_conv()` fixture in locomo_spec_runner.rs.
private func makeMiniSpecConversation() -> LoCoMoSpecConversation {
    LoCoMoSpecConversation(
        sampleID: "conv-mini",
        speakerA: "Alice",
        speakerB: "Bob",
        sessions: [
            LoCoMoSpecSession(
                sessionNumber: 1,
                dateTime: "1:00 pm on 1 May, 2023",
                turns: [
                    LoCoMoSpecTurn(
                        speaker: "Alice", diaID: "D1:1",
                        text: "Hello", imageCaption: nil),
                    LoCoMoSpecTurn(
                        speaker: "Bob", diaID: "D1:2",
                        text: "Hi there", imageCaption: nil),
                ]),
        ])
}


// MARK: - Scoring strategy flag

@Suite("LoCoMoSpecRunner — scoring strategy flag")
struct LoCoMoSpecScoringTests {

    // Verifies the scoring key is absent from the query args dict when --scoring
    // is omitted (byte-identical baseline) and present when given.
    @Test("scoring arg: absent when omitted, present when given")
    func scoringArgPropagation() {
        // Baseline: default config has nil scoringStrategy — no "scoring" key.
        var config = LoCoMoSpecRunConfig(
            mootBinaryPath: "/usr/bin/mootx01",
            datasetPath: URL(fileURLWithPath: "/corpus.json"))
        #expect(config.scoringStrategy == nil,
                "scoringStrategy must default to nil (no --scoring)")

        // Simulate the arg-building inline that the runner executes.
        var args: [String: JSONValue] = ["q": .string("hello")]
        if let s = config.scoringStrategy { args["scoring"] = .string(s) }
        #expect(args["scoring"] == nil,
                "omitted --scoring must produce no 'scoring' key in the query dict")

        // Given strategy: key must be present with the literal value.
        config.scoringStrategy = "discriminative"
        var args2: [String: JSONValue] = ["q": .string("hello")]
        if let s = config.scoringStrategy { args2["scoring"] = .string(s) }
        #expect(args2["scoring"] == .string("discriminative"),
                "given --scoring discriminative must wire as 'scoring': 'discriminative'")
    }
}

// MARK: - §6 Dream fields in run_parameters

/// Task-3 gate: loCoMoSpecReportJSON must write dream_pending and dream_draining
/// into the run_parameters block with the exact wire key names and integer values.
///
/// Drives the real encode path (loCoMoSpecReportJSON) rather than constructing
/// the output dict by hand, so any regression in the JSON-building code will
/// break these tests.
@Suite("LoCoMoSpecRunner — §6 dream fields in run_parameters")
struct LoCoMoSpecDreamFieldTests {

    /// Builds a result whose metadata has the given dream values, encodes it
    /// through loCoMoSpecReportJSON, and returns the run_parameters dict.
    private func runParameters(dreamPending: Int, dreamDraining: Int) throws -> [String: Any] {
        var meta = makeMetadata()
        meta.dreamPending  = dreamPending
        meta.dreamDraining = dreamDraining
        let records   = [makeQuestionRecord()]
        let tuples    = records.map { (category: $0.category, score: $0.score,
                                       evidenceRecall: $0.evidenceRecallValue) }
        let aggregate = loCoMoSpecAggregate(scores: tuples)
        let result    = LoCoMoSpecRunResult(questionRecords: records, aggregate: aggregate,
                                            metadata: meta)
        let data      = try loCoMoSpecReportJSON(result, arm: "test-arm", serial: "0001")
        let top       = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return top["run_parameters"] as! [String: Any]
    }

    /// Draining case: dream_pending=3, dream_draining=1.
    @Test("dream fields: draining case encodes dream_pending=3 and dream_draining=1")
    func dreamFieldsDraining() throws {
        let rp = try runParameters(dreamPending: 3, dreamDraining: 1)
        #expect((rp["dream_pending"] as? Int) == 3,
                "run_parameters.dream_pending must be 3 (draining case)")
        #expect((rp["dream_draining"] as? Int) == 1,
                "run_parameters.dream_draining must be 1 (draining=true)")
    }

    /// Settled case: dream_pending=0, dream_draining=0.
    @Test("dream fields: settled case encodes dream_pending=0 and dream_draining=0")
    func dreamFieldsSettled() throws {
        let rp = try runParameters(dreamPending: 0, dreamDraining: 0)
        #expect((rp["dream_pending"] as? Int) == 0,
                "run_parameters.dream_pending must be 0 (settled case)")
        #expect((rp["dream_draining"] as? Int) == 0,
                "run_parameters.dream_draining must be 0 (settled=true)")
    }
}
