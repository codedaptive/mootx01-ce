import Testing
import Foundation
@testable import mcp_benchmarker

// LMESpecRunnerTests.swift — shape tests for the lme-spec runner helpers.
//
// Scope: pure-logic tests only. No live MCP client, no estate, no judge subprocess.
//
//   §1  hypothesis JSONL line shape: {question_id, hypothesis}
//   §2  judge-input line shape: anscheck_prompt + §3 call parameters
//   §3  LMESpecReport Codable round-trip — judged_count: 0 path
//   §4  LMESpecReport Codable round-trip — all fields (judged_count > 0)
//   §5  LMESpecReportParams Codable round-trip
//   §6  Verdict-consumption path: synthetic records → aggregate → report shape
//
// All functions under test are internal to the mcp_benchmarker module and are
// reached via @testable import.
//
// Run with:
//   swift test --scratch-path .build-lmespec --filter LMESpecRunnerTests

// MARK: - Hypothesis JSONL line (spec §1)

@Suite("LMESpec runner — hypothesis JSONL line")
struct LMESpecRunnerHypothesisTests {

    @Test("hypothesis line: keys are question_id and hypothesis, trailing newline")
    func hypothesisLineShape() throws {
        let line = try #require(
            lmeSpecHypothesisLine(questionID: "gpt4_abc123", hypothesis: "Blue"),
            "lmeSpecHypothesisLine must return a non-nil string"
        )
        #expect(line.hasSuffix("\n"), "hypothesis JSONL line must end with newline")

        // The line must be valid JSON when stripped of the trailing newline.
        let data = Data(line.utf8.dropLast())
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "hypothesis line must be valid JSON object"
        )

        // spec §1 required keys.
        #expect(obj["question_id"] as? String == "gpt4_abc123",
                "hypothesis line must carry question_id")
        #expect(obj["hypothesis"] as? String == "Blue",
                "hypothesis line must carry hypothesis")
        // Exactly two keys: the spec §1 shape carries no extra fields.
        #expect(obj.count == 2, "hypothesis line must have exactly two keys")
    }

    @Test("hypothesis line: nil hypothesis encodes as empty string (every question present)")
    func hypothesisLineNilHypothesis() throws {
        // spec §1: every question must appear so the line count equals question count.
        // Nil hypothesis (error path) encodes as empty string rather than omitting the record.
        let line = try #require(lmeSpecHypothesisLine(questionID: "q_err", hypothesis: nil))
        let data = Data(line.utf8.dropLast())
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(obj["hypothesis"] as? String == "",
                "nil hypothesis should encode as empty string")
        #expect(obj["question_id"] as? String == "q_err")
    }

    @Test("hypothesis line: keys sorted alphabetically (sortedKeys option)")
    func hypothesisLineKeysAreSorted() throws {
        // lmeSpecHypothesisLine uses JSONSerialization.data with .sortedKeys.
        // "hypothesis" < "question_id" alphabetically.
        let line = try #require(lmeSpecHypothesisLine(questionID: "q1", hypothesis: "ans"))
        let withoutNewline = line.trimmingCharacters(in: .newlines)
        let hPos = try #require(withoutNewline.range(of: "\"hypothesis\""))
        let qPos = try #require(withoutNewline.range(of: "\"question_id\""))
        #expect(hPos.lowerBound < qPos.lowerBound,
                "sorted keys: 'hypothesis' must precede 'question_id'")
    }
}

// MARK: - Judge-input dump line (spec §2 / §3)

@Suite("LMESpec runner — judge-input dump line")
struct LMESpecRunnerJudgeInputTests {

    // Helper: build and parse a standard judge-input line for a non-abstention question.
    private func makeJudgeInputObj(
        questionID: String = "q_ssu_001",
        baseType: String = "single-session-user",
        isAbstention: Bool = false,
        hypothesis: String = "The sky is blue.",
        judgeModel: String = "gpt-4o-2024-08-06"
    ) throws -> [String: Any] {
        let prompt = try anscheckPrompt(
            questionType: baseType,
            questionID: questionID,
            question: "What color is the sky?",
            answer: "blue",
            hypothesis: hypothesis
        )
        let line = try #require(
            lmeSpecJudgeInputLine(
                questionID: questionID,
                baseQuestionType: baseType,
                isAbstention: isAbstention,
                hypothesis: hypothesis,
                anscheckPrompt: prompt,
                judgeModel: judgeModel
            )
        )
        let data = Data(line.utf8.dropLast())
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "judge-input line must be valid JSON object"
        )
    }

    @Test("judge-input line: carries required metadata fields")
    func judgeInputLineMetadata() throws {
        let obj = try makeJudgeInputObj()
        #expect(obj["type"] as? String == "question",    "type must be 'question'")
        #expect(obj["question_id"] as? String == "q_ssu_001")
        #expect(obj["base_question_type"] as? String == "single-session-user")
        #expect((obj["is_abstention"] as? Bool) == false)
        #expect(obj["hypothesis"] as? String == "The sky is blue.")
        #expect(obj["model"] as? String == "gpt-4o-2024-08-06")
    }

    @Test("judge-input line: spec §3 fixed parameters n=1, temperature=0, max_tokens=10")
    func judgeInputLineSection3Params() throws {
        let obj = try makeJudgeInputObj()
        // spec §3 verbatim: n=1, temperature=0, max_tokens=10.
        #expect(obj["n"] as? Int == 1,
                "spec §3 parameter n must be 1")
        let temp = obj["temperature"]
        let tempIsZero = (temp as? Int == 0) || (temp as? Double == 0.0)
        #expect(tempIsZero, "spec §3 parameter temperature must be 0")
        #expect(obj["max_tokens"] as? Int == 10,
                "spec §3 parameter max_tokens must be 10")
    }

    @Test("judge-input line: anscheck_prompt matches byte-exact spec §2 filled prompt")
    func judgeInputLineAnscheckPrompt() throws {
        let expectedPrompt = try anscheckPrompt(
            questionType: "single-session-user",
            questionID: "q_ssu_001",
            question: "What color is the sky?",
            answer: "blue",
            hypothesis: "The sky is blue."
        )
        let obj = try makeJudgeInputObj()
        #expect(obj["anscheck_prompt"] as? String == expectedPrompt,
                "anscheck_prompt must match anscheckPrompt output byte for byte")
    }

    @Test("judge-input line: abstention question sets is_abstention true")
    func judgeInputLineAbstentionFlag() throws {
        let obj = try makeJudgeInputObj(
            questionID: "q_ms_001_abs",
            baseType: "multi-session",
            isAbstention: true
        )
        #expect((obj["is_abstention"] as? Bool) == true,
                "abstention question must carry is_abstention: true")
    }

    @Test("judge-input line: ends with trailing newline")
    func judgeInputLineTrailingNewline() throws {
        let prompt = try anscheckPrompt(
            questionType: "temporal-reasoning",
            questionID: "q_tr_001",
            question: "How many days?", answer: "18", hypothesis: "About 19."
        )
        let line = try #require(
            lmeSpecJudgeInputLine(
                questionID: "q_tr_001",
                baseQuestionType: "temporal-reasoning",
                isAbstention: false,
                hypothesis: "About 19.",
                anscheckPrompt: prompt,
                judgeModel: "gpt-4o-2024-08-06"
            )
        )
        #expect(line.hasSuffix("\n"), "judge-input line must end with newline")
    }
}

// MARK: - LMESpecReport Codable — judged_count: 0 path

@Suite("LMESpec runner — LMESpecReport Codable, judged_count: 0")
struct LMESpecRunnerReportZeroJudgedTests {

    // Minimum synthetic report for the judged_count: 0 path.
    // All optional accuracy fields are nil — absent from JSON output.
    private func makeZeroJudgedReport() -> LMESpecReport {
        let emptyPerType = lmeSpecFixedTypeList.map { typeName in
            LMESpecReportPerType(questionType: typeName, accuracy: 0.0, count: 0)
        }
        return LMESpecReport(
            perType: emptyPerType,
            taskAveragedAccuracy: nil,
            overallAccuracy: nil,
            abstentionAccuracy: nil,
            abstentionCount: 3,
            judgeModels: [],
            judgedCount: 0,
            runID: "AAAAAAAA-0000-0000-0000-000000000000",
            runLabel: "lme-spec-m-seed42-shape-test",
            variant: "m",
            generatedAt: "2026-08-18T12:00:00Z",
            port: "swift",
            seed: 42,
            estateMode: "artifact-unit",
            targetScale: "unit",
            totalQuestions: 3
        )
    }

    @Test("judged_count: 0 — optional accuracy fields absent from JSON")
    func zeroJudgedOptionalFieldsAbsent() throws {
        let report = makeZeroJudgedReport()
        let data = try JSONEncoder().encode(report)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["task_averaged_accuracy"] == nil,
                "task_averaged_accuracy must be absent when judged_count is 0")
        #expect(json["overall_accuracy"] == nil,
                "overall_accuracy must be absent when judged_count is 0")
        #expect(json["abstention_accuracy"] == nil,
                "abstention_accuracy must be absent when judged_count is 0")
    }

    @Test("judged_count: 0 — required fields present and correct")
    func zeroJudgedRequiredFieldsPresent() throws {
        let report = makeZeroJudgedReport()
        let data = try JSONEncoder().encode(report)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["judged_count"] as? Int == 0)
        #expect(json["abstention_count"] as? Int == 3)
        #expect(json["total_questions"] as? Int == 3)
        #expect(json["port"] as? String == "swift")
        #expect(json["variant"] as? String == "m")
        #expect((json["judge_models"] as? [String])?.isEmpty == true)
    }

    @Test("judged_count: 0 — per_type array has six entries in fixed §4 order")
    func zeroJudgedPerTypeFixedOrder() throws {
        let report = makeZeroJudgedReport()
        let data = try JSONEncoder().encode(report)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let perType = try #require(json["per_type"] as? [[String: Any]])
        #expect(perType.count == 6, "per_type must have exactly six entries")
        for (i, entry) in perType.enumerated() {
            #expect(entry["question_type"] as? String == lmeSpecFixedTypeList[i],
                    "per_type[\(i)].question_type order mismatch")
            #expect(entry["accuracy"] as? Double == 0.0)
            #expect(entry["count"] as? Int == 0)
        }
    }

    @Test("judged_count: 0 — Codable round-trip preserves all fields")
    func zeroJudgedRoundTrip() throws {
        let report = makeZeroJudgedReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(LMESpecReport.self, from: data)
        #expect(decoded.judgedCount == 0)
        #expect(decoded.abstentionCount == 3)
        #expect(decoded.totalQuestions == 3)
        #expect(decoded.port == "swift")
        #expect(decoded.taskAveragedAccuracy == nil)
        #expect(decoded.overallAccuracy == nil)
        #expect(decoded.abstentionAccuracy == nil)
        #expect(decoded.perType.count == 6)
    }
}

// MARK: - LMESpecReport Codable — all fields (judged_count > 0)

@Suite("LMESpec runner — LMESpecReport Codable, judged_count > 0")
struct LMESpecRunnerReportAllFieldsTests {

    private func makeFullReport() -> LMESpecReport {
        let perType = lmeSpecFixedTypeList.enumerated().map { (i, typeName) in
            LMESpecReportPerType(questionType: typeName, accuracy: Double(i) * 0.1, count: i + 1)
        }
        return LMESpecReport(
            perType: perType,
            taskAveragedAccuracy: 0.6667,
            overallAccuracy: 0.625,
            abstentionAccuracy: 0.5,
            abstentionCount: 2,
            judgeModels: ["gpt-4o-2024-08-06"],
            judgedCount: 8,
            runID: "BBBBBBBB-1111-1111-1111-111111111111",
            runLabel: "lme-spec-m-seed1-full",
            variant: "m",
            generatedAt: "2026-08-18T12:00:00Z",
            port: "swift",
            seed: 1,
            estateMode: "artifact-unit",
            targetScale: "unit",
            totalQuestions: 8
        )
    }

    @Test("judged_count > 0 — all optional accuracy fields present in JSON")
    func fullReportOptionalFieldsPresent() throws {
        let data = try JSONEncoder().encode(makeFullReport())
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["task_averaged_accuracy"] != nil)
        #expect(json["overall_accuracy"] != nil)
        #expect(json["abstention_accuracy"] != nil)
    }

    @Test("judged_count > 0 — Codable round-trip preserves spec §4 accuracy fields")
    func fullReportRoundTrip() throws {
        let data = try JSONEncoder().encode(makeFullReport())
        let decoded = try JSONDecoder().decode(LMESpecReport.self, from: data)
        #expect(decoded.judgedCount == 8)
        #expect(abs((decoded.taskAveragedAccuracy ?? -1) - 0.6667) < 1e-9)
        #expect(abs((decoded.overallAccuracy ?? -1) - 0.625) < 1e-9)
        #expect(abs((decoded.abstentionAccuracy ?? -1) - 0.5) < 1e-9)
        #expect(decoded.abstentionCount == 2)
        #expect(decoded.judgeModels == ["gpt-4o-2024-08-06"])
    }

    @Test("task_averaged_accuracy and overall_accuracy DIFFER (unequal type counts)")
    func taskAvgDiffersFromOverall() {
        // From the grader_vectors.json eight-instance case:
        //   task_averaged_accuracy = 0.6667 (unweighted mean of six per-type raw means)
        //   overall_accuracy        = 0.6250 (mean over all 8 instances)
        // These differ because type counts are unequal (ssu:2, ssp:1, ssa:1, ms:2, tr:1, ku:1).
        // This distinguishability is what spec §4 requires the lme-spec lane to preserve.
        let report = makeFullReport()
        let taskAvg = report.taskAveragedAccuracy!
        let overall = report.overallAccuracy!
        #expect(abs(taskAvg - overall) > 1e-6)
    }
}

// MARK: - LMESpecReportParams Codable

@Suite("LMESpec runner — LMESpecReportParams Codable")
struct LMESpecRunnerReportParamsTests {

    private func makeParams(limit: Int? = 10) -> LMESpecReportParams {
        LMESpecReportParams(
            variant: "m",
            seed: 42,
            limit: limit,
            offset: 0,
            judgeModel: "gpt-4o-2024-08-06",
            judgeCmdSet: true,
            dumpJudgeInputsSet: false
        )
    }

    @Test("LMESpecReportParams Codable round-trip")
    func paramsRoundTrip() throws {
        let data = try JSONEncoder().encode(makeParams())
        let decoded = try JSONDecoder().decode(LMESpecReportParams.self, from: data)
        #expect(decoded.variant == "m")
        #expect(decoded.seed == 42)
        #expect(decoded.limit == 10)
        #expect(decoded.judgeModel == "gpt-4o-2024-08-06")
        #expect(decoded.judgeCmdSet == true)
        #expect(decoded.dumpJudgeInputsSet == false)
    }

    @Test("LMESpecReportParams: judge_cmd_set flag stored; actual command text absent (privacy)")
    func paramsJudgeCmdPrivacy() throws {
        let data = try JSONEncoder().encode(makeParams())
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["judge_model"] != nil,       "judge_model must be stored")
        #expect(json["judge_cmd_set"] as? Bool == true, "judge_cmd_set flag must be stored")
        #expect(json["judge_cmd"] == nil,         "judge_cmd text must NOT be stored")
    }

    @Test("LMESpecReportParams: nil limit encodes as absent (run without limit)")
    func paramsNilLimitAbsent() throws {
        let data = try JSONEncoder().encode(makeParams(limit: nil))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["limit"] == nil, "nil limit must be absent from JSON")
    }
}

// MARK: - Verdict-consumption path

@Suite("LMESpec runner — verdict-consumption path")
struct LMESpecRunnerVerdictConsumptionTests {

    // Build the synthetic verdict batch from grader_vectors.json eight-instance case.
    // This exercises the same aggregation path that runLMESpec uses internally.
    @Test("synthetic verdict batch produces correct §4 aggregate and report shape")
    func syntheticVerdictBatchAggregation() {
        func rec(_ id: String, _ base: String, _ label: Bool) -> LMESpecVerdictRecord {
            LMESpecVerdictRecord(
                questionID: id,
                baseQuestionType: base,
                verdict: LMESpecVerdict(judgeModel: "gpt-4o-2024-08-06", label: label)
            )
        }
        // Mirrors grader_vectors.json aggregation_cases[0].records.
        let records = [
            rec("q1",     "single-session-user",       true),
            rec("q2",     "single-session-user",       false),
            rec("q3_abs", "single-session-preference", true),
            rec("q4_abs", "single-session-assistant",  false),
            rec("q5",     "multi-session",             true),
            rec("q6",     "multi-session",             false),
            rec("q7",     "temporal-reasoning",        true),
            rec("q8",     "knowledge-update",          true),
        ]

        let agg = lmeSpecAggregate(records)

        // Verify aggregate matches vector-expected values.
        #expect(agg.taskAveragedAccuracy == 0.6667)
        #expect(agg.overallAccuracy      == 0.625)
        #expect(agg.abstentionAccuracy   == 0.5)
        #expect(agg.abstentionCount      == 2)

        // task-averaged and overall differ (unequal type counts — the key §4 property).
        #expect(abs(agg.taskAveragedAccuracy - agg.overallAccuracy) > 1e-6)

        // Synthesize the report (same path as runLMESpec internal logic).
        let perType: [LMESpecReportPerType] = agg.perType.map { pt in
            LMESpecReportPerType(questionType: pt.questionType, accuracy: pt.accuracy, count: pt.count)
        }
        let report = LMESpecReport(
            perType: perType,
            taskAveragedAccuracy: agg.taskAveragedAccuracy,
            overallAccuracy: agg.overallAccuracy,
            abstentionAccuracy: agg.abstentionAccuracy,
            abstentionCount: agg.abstentionCount,
            judgeModels: agg.judgeModels,
            judgedCount: records.count,
            runID: UUID().uuidString,
            runLabel: "test-consumption",
            variant: "m",
            generatedAt: "2026-08-18T00:00:00Z",
            port: "swift",
            seed: 0,
            estateMode: "artifact-unit",
            targetScale: "unit",
            totalQuestions: records.count
        )

        #expect(report.judgedCount == 8)
        #expect(report.taskAveragedAccuracy == 0.6667)
        #expect(report.overallAccuracy == 0.625)
        #expect(report.judgeModels == ["gpt-4o-2024-08-06"])
        #expect(report.abstentionCount == 2)
    }

    @Test("judged_count: 0 — report shape when no judge is attached")
    func noJudgeAttachedReportShape() {
        // When no judgeCmd is configured, judgedCount is 0 and the optional
        // accuracy fields are nil. abstentionCount is still populated from the corpus.
        let emptyAgg = lmeSpecAggregate([])

        let perType: [LMESpecReportPerType] = emptyAgg.perType.map { pt in
            LMESpecReportPerType(questionType: pt.questionType, accuracy: pt.accuracy, count: pt.count)
        }
        let report = LMESpecReport(
            perType: perType,
            taskAveragedAccuracy: nil,
            overallAccuracy: nil,
            abstentionAccuracy: nil,
            abstentionCount: 30,    // from corpus question list, not verdicts
            judgeModels: [],
            judgedCount: 0,
            runID: UUID().uuidString,
            runLabel: "test-no-judge",
            variant: "m",
            generatedAt: "2026-08-18T00:00:00Z",
            port: "swift",
            seed: 0,
            estateMode: "artifact-unit",
            targetScale: "unit",
            totalQuestions: 100
        )

        #expect(report.judgedCount == 0)
        #expect(report.taskAveragedAccuracy == nil)
        #expect(report.overallAccuracy == nil)
        #expect(report.abstentionAccuracy == nil)
        // abstentionCount reflects the corpus regardless of judge attachment.
        #expect(report.abstentionCount == 30)
        #expect(report.judgeModels.isEmpty)
    }
}

// MARK: - Per-question degradation on unresolvable unit (§ unit-scale guard)

/// Verifies that lme-spec unit-scale degrades a question (guardHealthy: false)
/// when its unit cannot be resolved from the catalog, rather than throwing the
/// resolver error out of the per-question loop.
///
/// Pre-fix behaviour (commit before this change): `try artifactUnitEstateDir(...)`
/// propagates its MCPError out of the for loop, so `runLMESpec` throws before
/// any report is produced. The test therefore FAILS against the unfixed code
/// (the `try await runLMESpec(...)` call throws) and PASSES after the fix.
///
/// Matches the Rust twin in lme_spec_runner.rs (lines 1099-1120): a failed
/// `resolve_unit_from_catalog` appends a degraded `LmeSpecPerQuestionResult`
/// and continues the loop rather than unwinding the whole run.
@Suite("LMESpec runner — per-question degradation on unresolvable unit")
struct LMESpecRunnerDegradationTests {

    @Test("lme-spec unit scale: run degrades instead of throwing for an unresolvable unit")
    func lmeSpecUnitScaleDegradesOnUnresolvableUnit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lme-spec-degrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outDir = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Catalog with one set row for "unit-present", whose directory does NOT exist
        // on disk (hasEstateDatabase returns false → resolver skips the row and
        // reports "not in the catalog" for it too).
        // "unit-absent" has no set row at all.
        //
        // "catalog containing one of two question ids": the JSON references unit-present
        // in its sets; unit-absent is completely absent from the catalog.
        let setBase = tmp.appendingPathComponent("sets")
        try FileManager.default.createDirectory(at: setBase, withIntermediateDirectories: true)

        let catalog: [String: Any] = [
            "sets": [
                ["base": setBase.path, "path": "units"]
            ]
        ]
        let catalogPath = tmp.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogPath)

        // Two minimal questions: one whose id is referenced in the catalog (but whose
        // directory has no estate database) and one that is completely absent.
        let questions: [LMESpecQuestion] = [
            LMESpecQuestion(
                questionID: "unit-present",
                questionType: "multi-session",
                question: "Q1?",
                answer: "A1",
                questionDate: "2024/01/01 (Mon) 00:00",
                haystackDates: [],
                haystackSessionIDs: [],
                haystackSessions: [],
                answerSessionIDs: []),
            LMESpecQuestion(
                questionID: "unit-absent",
                questionType: "multi-session",
                question: "Q2?",
                answer: "A2",
                questionDate: "2024/01/01 (Mon) 00:00",
                haystackDates: [],
                haystackSessionIDs: [],
                haystackSessions: [],
                answerSessionIDs: []),
        ]

        let config = LMESpecRunConfig(
            // mootBinaryPath is never reached: both questions degrade before connect.
            mootBinaryPath: "/usr/bin/true",
            datasetPath: URL(fileURLWithPath: "/dev/null"),
            variant: "m",
            limit: nil,
            offset: 0,
            seed: 0,
            outDir: outDir,
            runLabel: "degrade-gate",
            runSerial: "0001",
            dumpJudgeInputsPath: nil,
            judgeCmd: nil,
            judgeModel: "test-model",
            targetScale: .unit,
            catalogPath: catalogPath,
            estateDir: nil)

        // Pre-fix: this call throws (artifactUnitEstateDir propagates out of the loop).
        // Post-fix: both questions degrade; the loop completes; the report is returned.
        let report = try await runLMESpec(questions: questions, config: config)

        // Both questions completed the loop (degraded, not thrown).
        #expect(report.totalQuestions == 2,
                "both questions must appear even when their units are unresolvable")
        #expect(report.judgedCount == 0,
                "degraded questions produce no verdicts")

        // Verify the exact diagnostic text the resolver emits for the absent unit.
        // This is the string that lands in guardDiagnostic for the degraded result,
        // byte-identical with the Rust resolver's output for the same failure.
        do {
            _ = try artifactUnitEstateDir(catalogPath: catalogPath, id: "unit-absent")
            Issue.record("expected throw for unit-absent")
        } catch let e as MCPError {
            #expect(e.description ==
                "unit 'unit-absent' is not in the catalog at \(catalogPath.path)",
                "degraded result carries the resolver's exact 'not in the catalog' text")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

// MARK: - per_question_results round-trip

/// Verifies that a degraded per-question row (guardHealthy: false) survives
/// LMESpecReport JSON encoding and decoding with its guard_diagnostic intact.
///
/// The defect under test: perQuestionResults was computed but never wired into
/// LMESpecReport, so the data was absent from every written report.
/// The assertion is against the round-tripped value (encoded to bytes, decoded
/// back), not the in-memory struct — because the defect was in serialisation.
@Suite("LMESpec runner — per_question_results round-trip")
struct LMESpecPerQuestionResultsReportTests {

    @Test("degraded row survives JSON round-trip: question_id, guard_healthy, guard_diagnostic")
    func degradedRowRoundTrip() throws {
        let questionID         = "lme_perq_degraded_01"
        let expectedDiagnostic = "estate probe failed: connection refused"

        let row = LMESpecReportPerQuestionRow(
            questionID:       questionID,
            baseQuestionType: "single-session-user",
            isAbstention:     false,
            hypothesis:       nil,
            verdictRecord:    nil,
            guardHealthy:     false,
            guardDiagnostic:  expectedDiagnostic,
            cacheHit:         nil,
            turnsIngested:    0)

        let emptyPerType = lmeSpecFixedTypeList.map {
            LMESpecReportPerType(questionType: $0, accuracy: 0.0, count: 0)
        }
        var report = LMESpecReport(
            perType:              emptyPerType,
            taskAveragedAccuracy: nil,
            overallAccuracy:      nil,
            abstentionAccuracy:   nil,
            abstentionCount:      0,
            judgeModels:          [],
            judgedCount:          0,
            runID:                "CCCCCCCC-0000-0000-0000-000000000000",
            runLabel:             "lme-spec-per-question-round-trip-test",
            variant:              "s",
            generatedAt:          "2026-09-14T00:00:00Z",
            port:                 "swift",
            seed:                 1,
            estateMode:           "artifact-unit",
            targetScale:          "unit",
            totalQuestions:       1)
        report.perQuestionResults = [row]

        // Encode to JSON bytes, decode back.
        // An in-memory assertion would pass even with the serialisation missing;
        // the round-trip is the discriminating gate.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data    = try encoder.encode(report)
        let restored = try JSONDecoder().decode(LMESpecReport.self, from: data)

        // a. per_question_results is present and non-empty.
        #expect(!restored.perQuestionResults.isEmpty,
                "per_question_results must be non-empty after round-trip")

        // b. Find the row by the literal question_id.
        let found = restored.perQuestionResults.first { $0.questionID == questionID }
        let degradedRow = try #require(
            found,
            "must find row with question_id 'lme_perq_degraded_01' in per_question_results")

        // c. guard_healthy is false on the degraded row.
        #expect(degradedRow.guardHealthy == false,
                "guard_healthy must be false on the degraded row")

        // d. guard_diagnostic carries the exact diagnostic text.
        #expect(degradedRow.guardDiagnostic == expectedDiagnostic,
                "guard_diagnostic must equal 'estate probe failed: connection refused'")
    }
}
