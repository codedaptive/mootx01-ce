import Testing
import Foundation
@testable import mcp_benchmarker

// LMESpecGraderTests.swift — Swift conformance tests for LMESpecGrader.
//
// Drives the shared conformance vectors in benchmarks/conformance/lme-spec/grader_vectors.json
// (the same JSON that the Rust leg drives). Same inputs → identical outputs on both legs
// is the conformance contract.
//
// Run with:
//   swift test --scratch-path .build-lmespec --filter LMESpecGraderTests

// MARK: - Fixture path helper

/// Resolves `benchmarks/conformance/lme-spec/<filename>` from this test file's location.
/// Path chain: .../Tests/mcp-benchmarkerTests/ → Tests/ → package root → conformance/lme-spec/
private func lmeSpecConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root (benchmarks/)
        .appendingPathComponent("conformance")
        .appendingPathComponent("lme-spec")
        .appendingPathComponent(filename)
}

private func loadLMESpecJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(
            domain: "LMESpecGraderTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Expected top-level object in \(url.lastPathComponent)"]
        )
    }
    return dict
}

// MARK: - Template rendering tests (drives grader_vectors.json template_cases)

@Suite struct LMESpecGraderTemplateTests {

    @Test("Template cases: all five rendered prompts match vectors")
    func templateCasesMatchVectors() throws {
        let json = try loadLMESpecJSON(lmeSpecConformancePath("grader_vectors.json"))
        let cases = try #require(json["template_cases"] as? [[String: Any]])
        #expect(cases.count == 5, "vectors must contain exactly five template cases")

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let questionType = try #require(c["question_type"] as? String)
            let questionID = try #require(c["question_id"] as? String)
            let question = try #require(c["question"] as? String)
            let answer = try #require(c["answer"] as? String)
            let hypothesis = try #require(c["hypothesis"] as? String)
            let expectedPrompt = try #require(c["expected_prompt"] as? String)

            let actual = try anscheckPrompt(
                questionType: questionType,
                questionID: questionID,
                question: question,
                answer: answer,
                hypothesis: hypothesis
            )
            #expect(
                actual == expectedPrompt,
                "template_case '\(id)': rendered prompt does not match expected — got: \(actual.prefix(120)) — expected: \(expectedPrompt.prefix(120))"
            )
        }
    }
}

// MARK: - Verdict parse tests (drives grader_vectors.json verdict_cases)

@Suite struct LMESpecGraderVerdictTests {

    @Test("Verdict cases: all parse results match vectors")
    func verdictCasesMatchVectors() throws {
        let json = try loadLMESpecJSON(lmeSpecConformancePath("grader_vectors.json"))
        let cases = try #require(json["verdict_cases"] as? [[String: Any]])

        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let evalResponse = try #require(c["eval_response"] as? String)
            let expectedLabel = try #require(c["expected_label"] as? Bool)

            let v = lmeSpecVerdict(evalResponse: evalResponse, judgeModel: "test-model")
            #expect(
                v.label == expectedLabel,
                "verdict_case '\(id)': expected label \(expectedLabel), got \(v.label) for eval_response '\(evalResponse)'"
            )
        }
    }
}

// MARK: - Aggregation tests (drives grader_vectors.json aggregation_cases)

@Suite struct LMESpecGraderAggregationTests {

    @Test("Aggregation case: per-type, task-averaged, overall, abstention accuracy")
    func aggregationCaseMatchesVectors() throws {
        let json = try loadLMESpecJSON(lmeSpecConformancePath("grader_vectors.json"))
        let cases = try #require(json["aggregation_cases"] as? [[String: Any]])
        guard let c = cases.first else {
            throw NSError(domain: "LMESpecGraderTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "aggregation_cases is empty"])
        }

        let records = try #require(c["records"] as? [[String: Any]])
        let expected = try #require(c["expected"] as? [String: Any])

        // Build LMESpecVerdictRecord array from vector records.
        let verdictRecords: [LMESpecVerdictRecord] = try records.map { rec in
            let questionID = try #require(rec["question_id"] as? String)
            let baseType = try #require(rec["base_question_type"] as? String)
            let label = try #require(rec["label"] as? Bool)
            let model = rec["judge_model"] as? String ?? "test-model"
            return LMESpecVerdictRecord(
                questionID: questionID,
                baseQuestionType: baseType,
                verdict: LMESpecVerdict(judgeModel: model, label: label)
            )
        }

        let result = lmeSpecAggregate(verdictRecords)

        // Task-averaged accuracy.
        let expectedTaskAvg = try #require(expected["task_averaged_accuracy"] as? Double)
        #expect(
            abs(result.taskAveragedAccuracy - expectedTaskAvg) < 1e-9,
            "task_averaged_accuracy: expected \(expectedTaskAvg), got \(result.taskAveragedAccuracy)"
        )

        // Overall accuracy.
        let expectedOverall = try #require(expected["overall_accuracy"] as? Double)
        #expect(
            abs(result.overallAccuracy - expectedOverall) < 1e-9,
            "overall_accuracy: expected \(expectedOverall), got \(result.overallAccuracy)"
        )

        // Abstention accuracy.
        let expectedAbsAcc = try #require(expected["abstention_accuracy"] as? Double)
        #expect(
            abs(result.abstentionAccuracy - expectedAbsAcc) < 1e-9,
            "abstention_accuracy: expected \(expectedAbsAcc), got \(result.abstentionAccuracy)"
        )

        // Abstention count.
        let expectedAbsCount = try #require(expected["abstention_count"] as? Int)
        #expect(
            result.abstentionCount == expectedAbsCount,
            "abstention_count: expected \(expectedAbsCount), got \(result.abstentionCount)"
        )

        // Per-type accuracy and count.
        let expectedPerType = try #require(expected["per_type"] as? [[String: Any]])
        let perTypeByName = Dictionary(
            uniqueKeysWithValues: result.perType.map { ($0.questionType, $0) }
        )
        for pt in expectedPerType {
            let typeName = try #require(pt["question_type"] as? String)
            let expAcc = try #require(pt["accuracy"] as? Double)
            let expCount = try #require(pt["count"] as? Int)
            let actual = try #require(perTypeByName[typeName])
            #expect(
                abs(actual.accuracy - expAcc) < 1e-9,
                "per_type '\(typeName)' accuracy: expected \(expAcc), got \(actual.accuracy)"
            )
            #expect(
                actual.count == expCount,
                "per_type '\(typeName)' count: expected \(expCount), got \(actual.count)"
            )
        }
    }
}

// MARK: - Inline unit tests (not vector-driven)

@Suite struct LMESpecGraderInlineTests {

    // ── Template routing ──────────────────────────────────────────────────────

    @Test("Abstention branch: keyed on question_id not question_type")
    func abstentionKeyedOnID() throws {
        // Even with a non-abstention type, '_abs' in question_id routes to abstention.
        let prompt = try anscheckPrompt(
            questionType: "single-session-user",
            questionID: "q1_abs",
            question: "Q", answer: "A", hypothesis: "H"
        )
        #expect(prompt.hasPrefix("I will give you an unanswerable question"))
    }

    @Test("Standard template: single-session-user, single-session-assistant, multi-session share it")
    func standardTemplateSharedByThreeTypes() throws {
        for qtype in ["single-session-user", "single-session-assistant", "multi-session"] {
            let prompt = try anscheckPrompt(
                questionType: qtype, questionID: "q1",
                question: "Q", answer: "GOLD", hypothesis: "H"
            )
            #expect(prompt.contains("Correct Answer: GOLD"),
                    "\(qtype) should use standard template")
            #expect(!prompt.contains("Rubric"), "\(qtype) should not use preference template")
        }
    }

    @Test("Temporal template: off-by-one clause present")
    func temporalTemplate() throws {
        let prompt = try anscheckPrompt(
            questionType: "temporal-reasoning", questionID: "q1",
            question: "Q", answer: "A", hypothesis: "H"
        )
        #expect(prompt.contains("off-by-one errors for the number of days"))
    }

    @Test("Preference template: second slot labeled Rubric")
    func preferenceTemplate() throws {
        let prompt = try anscheckPrompt(
            questionType: "single-session-preference", questionID: "q1",
            question: "Q", answer: "MYRUBRIC", hypothesis: "H"
        )
        #expect(prompt.contains("Rubric: MYRUBRIC"))
        #expect(!prompt.contains("Correct Answer"))
    }

    @Test("Knowledge-update template: updated-answer clause present")
    func knowledgeUpdateTemplate() throws {
        let prompt = try anscheckPrompt(
            questionType: "knowledge-update", questionID: "q1",
            question: "Q", answer: "A", hypothesis: "H"
        )
        #expect(prompt.contains("updated answer is the required answer"))
    }

    @Test("Unknown type throws LMESpecGraderError")
    func unknownTypeThrows() {
        #expect(throws: LMESpecGraderError.self) {
            try anscheckPrompt(
                questionType: "not-a-real-type", questionID: "q1",
                question: "Q", answer: "A", hypothesis: "H"
            )
        }
    }

    // ── Slot fill order ───────────────────────────────────────────────────────

    @Test("Slots fill in order: question then answer then hypothesis")
    func slotFillOrder() throws {
        let prompt = try anscheckPrompt(
            questionType: "single-session-user", questionID: "q1",
            question: "MYQUESTION", answer: "MYANSWER", hypothesis: "MYHYPOTHESIS"
        )
        let qPos = prompt.range(of: "MYQUESTION")!.lowerBound
        let aPos = prompt.range(of: "MYANSWER")!.lowerBound
        let hPos = prompt.range(of: "MYHYPOTHESIS")!.lowerBound
        #expect(qPos < aPos, "question must precede answer in template")
        #expect(aPos < hPos, "answer must precede hypothesis in template")
    }

    // ── Template fidelity: trailing space before first \n\n ───────────────────

    @Test("Standard template: trailing space before first double-newline (verbatim from spec)")
    func standardTrailingSpace() throws {
        let prompt = try anscheckPrompt(
            questionType: "single-session-user", questionID: "q1",
            question: "Q", answer: "A", hypothesis: "H"
        )
        // "answer no. \n\n" verbatim from §2 spec.
        #expect(prompt.contains("answer no. \n\nQuestion:"))
    }

    @Test("Temporal template: trailing space before first double-newline (verbatim from spec)")
    func temporalTrailingSpace() throws {
        let prompt = try anscheckPrompt(
            questionType: "temporal-reasoning", questionID: "q1",
            question: "Q", answer: "A", hypothesis: "H"
        )
        // "is still correct. \n\n" verbatim from §2 spec.
        #expect(prompt.contains("is still correct. \n\nQuestion:"))
    }

    @Test("Knowledge-update template: no trailing space before first double-newline")
    func knowledgeUpdateNoTrailingSpace() throws {
        let prompt = try anscheckPrompt(
            questionType: "knowledge-update", questionID: "q1",
            question: "Q", answer: "A", hypothesis: "H"
        )
        #expect(prompt.contains("required answer.\n\nQuestion:"))
        #expect(!prompt.contains("required answer. \n\n"))
    }

    // ── Verdict parsing ───────────────────────────────────────────────────────

    @Test("Verdict: 'Yes.' → true")
    func verdictYesPeriod() {
        #expect(lmeSpecVerdict(evalResponse: "Yes.", judgeModel: "m").label == true)
    }

    @Test("Verdict: 'no' → false")
    func verdictNo() {
        #expect(lmeSpecVerdict(evalResponse: "no", judgeModel: "m").label == false)
    }

    @Test("Verdict: 'YES it is' → true")
    func verdictYesItIs() {
        #expect(lmeSpecVerdict(evalResponse: "YES it is", judgeModel: "m").label == true)
    }

    @Test("Verdict: ' yes' (leading space) → true")
    func verdictLeadingSpaceYes() {
        #expect(lmeSpecVerdict(evalResponse: " yes", judgeModel: "m").label == true)
    }

    @Test("Verdict: judge model carried through")
    func verdictCarriesModel() {
        let v = lmeSpecVerdict(evalResponse: "yes", judgeModel: "gpt-4o-2024-08-06")
        #expect(v.judgeModel == "gpt-4o-2024-08-06")
    }

    // ── Judge request descriptor ──────────────────────────────────────────────

    @Test("Judge request: §3 fixed parameters n=1, temp=0, max_tokens=10")
    func judgeRequestFixedParams() {
        let req = lmeSpecJudgeRequest(model: "gpt-4o-2024-08-06", prompt: "test prompt")
        #expect(req.n == 1)
        #expect(req.temperature == 0.0)
        #expect(req.maxTokens == 10)
        #expect(req.userMessage == "test prompt")
        #expect(req.model == "gpt-4o-2024-08-06")
    }

    // ── Aggregation inline ────────────────────────────────────────────────────

    @Test("Aggregation: eight-instance case produces correct metrics")
    func aggregationEightInstanceCase() {
        func record(_ id: String, _ type_: String, _ label: Bool) -> LMESpecVerdictRecord {
            LMESpecVerdictRecord(
                questionID: id,
                baseQuestionType: type_,
                verdict: LMESpecVerdict(judgeModel: "m", label: label)
            )
        }

        let records = [
            record("q1",     "single-session-user",       true),
            record("q2",     "single-session-user",       false),
            record("q3_abs", "single-session-preference", true),
            record("q4_abs", "single-session-assistant",  false),
            record("q5",     "multi-session",             true),
            record("q6",     "multi-session",             false),
            record("q7",     "temporal-reasoning",        true),
            record("q8",     "knowledge-update",          true),
        ]
        let result = lmeSpecAggregate(records)

        let byType = Dictionary(uniqueKeysWithValues: result.perType.map { ($0.questionType, $0) })
        #expect(byType["single-session-user"]!.accuracy == 0.5)
        #expect(byType["single-session-user"]!.count == 2)
        #expect(byType["single-session-preference"]!.accuracy == 1.0)
        #expect(byType["single-session-preference"]!.count == 1)
        #expect(byType["single-session-assistant"]!.accuracy == 0.0)
        #expect(byType["single-session-assistant"]!.count == 1)
        #expect(byType["multi-session"]!.accuracy == 0.5)
        #expect(byType["multi-session"]!.count == 2)
        #expect(byType["temporal-reasoning"]!.accuracy == 1.0)
        #expect(byType["temporal-reasoning"]!.count == 1)
        #expect(byType["knowledge-update"]!.accuracy == 1.0)
        #expect(byType["knowledge-update"]!.count == 1)

        // task-averaged = (0.5+1.0+0.0+0.5+1.0+1.0)/6 = 4.0/6 = 0.6667
        #expect(result.taskAveragedAccuracy == 0.6667)
        // overall = 5/8 = 0.6250
        #expect(result.overallAccuracy == 0.625)
        // abstention = 1/2 = 0.5000
        #expect(result.abstentionAccuracy == 0.5)
        #expect(result.abstentionCount == 2)
        // judge model
        #expect(result.judgeModels == ["m"])
    }

    @Test("Aggregation: empty input produces all-zero result with six per-type entries")
    func aggregationEmptyInput() {
        let result = lmeSpecAggregate([])
        #expect(result.taskAveragedAccuracy == 0.0)
        #expect(result.overallAccuracy == 0.0)
        #expect(result.abstentionAccuracy == 0.0)
        #expect(result.abstentionCount == 0)
        #expect(result.perType.count == 6)
        #expect(result.perType.allSatisfy { $0.accuracy == 0.0 && $0.count == 0 })
    }

    @Test("Aggregation: per-type order matches lmeSpecFixedTypeList")
    func perTypeOrderMatchesFixedList() {
        let result = lmeSpecAggregate([])
        let actualOrder = result.perType.map { $0.questionType }
        #expect(actualOrder == lmeSpecFixedTypeList)
    }

    @Test("Aggregation: abstention instances counted toward base type")
    func abstentionInstancesCountTowardBaseType() {
        let records = [
            LMESpecVerdictRecord(
                questionID: "q1_abs",
                baseQuestionType: "multi-session",
                verdict: LMESpecVerdict(judgeModel: "m", label: true)
            )
        ]
        let result = lmeSpecAggregate(records)
        let ms = result.perType.first { $0.questionType == "multi-session" }!
        // The abstention instance contributes to the multi-session bucket.
        #expect(ms.count == 1)
        #expect(ms.accuracy == 1.0)
        // And also to abstention accuracy.
        #expect(result.abstentionAccuracy == 1.0)
        #expect(result.abstentionCount == 1)
    }
}
