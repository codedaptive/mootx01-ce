import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBJudgeAccuracyTests.swift — unit tests for LMEB judge accuracy reporting.
//
// Tests cover three surfaces:
//   1. answer_accuracy: 2/2 CORRECT = 1.0, 0/2 INCORRECT = 0.0, mixed.
//   2. judged_count: counts only queries where judgeCorrect is non-nil.
//   3. tokens_per_correct: total judge tokens / correct count (nil when correct == 0).
//   4. judge_cmd_set: boolean presence-only rule (command text never in report).
//   5. judge_grading: mode string when judge was configured, nil when not.
//
// Stub strategy: synthesise LMEBQueryScore values directly with judgeCorrect and
// judgeTokens set — no subprocess needed to test the report-level computation.
// This isolates the scorer from the runner (judge calls live in runLMEBQueries;
// accuracy aggregation lives in buildLMEBReport).

// MARK: - Helpers

/// Builds a minimal LMEBQueryScore with judge accuracy fields set.
private func makeJudgedScore(
    queryID: String,
    judgeCorrect: Bool?,
    judgeTokens: Int? = 100
) -> LMEBQueryScore {
    LMEBQueryScore(
        queryID: queryID,
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
        docsIngested: 3,
        retrievedDocCount: 2,
        rankedDocIDs: ["doc-a"],
        relevantDocIDs: ["doc-a"],
        payloadText: nil,
        judgeCorrect: judgeCorrect,
        judgeTokens: judgeTokens
    )
}

/// Calls buildLMEBReport with a minimal set of arguments.
/// `judgeCmd` is passed to control `judge_cmd_set`; the value is opaque.
private func buildReport(
    scores: [LMEBQueryScore],
    judgeCmd: String? = nil,
    judgeGrading: LMEJudgeGrading? = nil
) -> LMEBReport {
    buildLMEBReport(
        runLabel: "accuracy-test",
        evidenceTypes: ["user_evidence"],
        queriesLoaded: scores.count,
        results: [],
        scores: scores,
        encodeBarrier: "drain",
        guardSampling: "once",
        estateCache: "off",
        estateEncryption: "plaintext-optout",
        shape: "disk",
        parallelUnits: 1,
        judgeCmd: judgeCmd,
        judgeGrading: judgeGrading
    )
}

// MARK: - answer_accuracy

@Suite("LMEB judge accuracy: answer_accuracy")
struct LMEBAnswerAccuracyTests {

    @Test("All correct: answer_accuracy = 1.0")
    func allCorrectAccuracy() {
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: true),
            makeJudgedScore(queryID: "q2", judgeCorrect: true),
        ]
        let report = buildReport(scores: scores,
                                 judgeCmd: "sentinel", judgeGrading: .substring)
        guard let acc = report.answerAccuracy else {
            Issue.record("answer_accuracy must be non-nil when judge ran")
            return
        }
        #expect(abs(acc - 1.0) < 1e-9, "2/2 correct → accuracy = 1.0")
    }

    @Test("All incorrect: answer_accuracy = 0.0")
    func allIncorrectAccuracy() {
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: false),
            makeJudgedScore(queryID: "q2", judgeCorrect: false),
        ]
        let report = buildReport(scores: scores,
                                 judgeCmd: "sentinel", judgeGrading: .substring)
        guard let acc = report.answerAccuracy else {
            Issue.record("answer_accuracy must be non-nil when judge ran")
            return
        }
        #expect(abs(acc - 0.0) < 1e-9, "0/2 correct → accuracy = 0.0")
    }

    @Test("Mixed: answer_accuracy = 0.5")
    func mixedAccuracy() {
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: true),
            makeJudgedScore(queryID: "q2", judgeCorrect: false),
        ]
        let report = buildReport(scores: scores,
                                 judgeCmd: "sentinel", judgeGrading: .substring)
        guard let acc = report.answerAccuracy else {
            Issue.record("answer_accuracy must be non-nil when judge ran")
            return
        }
        #expect(abs(acc - 0.5) < 1e-9, "1/2 correct → accuracy = 0.5")
    }

    @Test("No judged queries: answer_accuracy is nil")
    func noJudgedQueriesNilAccuracy() {
        // judgeCorrect = nil means the judge did not run for these queries.
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: nil),
            makeJudgedScore(queryID: "q2", judgeCorrect: nil),
        ]
        let report = buildReport(scores: scores)
        #expect(report.answerAccuracy == nil,
                "answer_accuracy must be nil when no queries were judged")
    }

    @Test("Empty score list: answer_accuracy is nil")
    func emptyScoresNilAccuracy() {
        let report = buildReport(scores: [])
        #expect(report.answerAccuracy == nil)
    }
}

// MARK: - judged_count

@Suite("LMEB judge accuracy: judged_count")
struct LMEBJudgedCountTests {

    @Test("judged_count counts only queries with non-nil judgeCorrect")
    func judgedCountOnlyNonNil() {
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: true),
            makeJudgedScore(queryID: "q2", judgeCorrect: nil),   // not judged
            makeJudgedScore(queryID: "q3", judgeCorrect: false),
        ]
        let report = buildReport(scores: scores,
                                 judgeCmd: "sentinel", judgeGrading: .verdict)
        #expect(report.judgedCount == 2,
                "only 2 queries have non-nil judgeCorrect; nil is not counted")
    }

    @Test("judged_count is zero when no judge ran")
    func judgedCountZeroWhenNoJudge() {
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: nil),
        ]
        let report = buildReport(scores: scores)
        #expect(report.judgedCount == 0)
    }
}

// MARK: - tokens_per_correct

@Suite("LMEB judge accuracy: tokens_per_correct")
struct LMEBTokensPerCorrectTests {

    @Test("tokens_per_correct = total tokens / correct count")
    func tokensPerCorrectBasic() {
        // q1: correct, 200 tokens; q2: incorrect, 150 tokens
        // total = 200 + 150 = 350; correct = 1 → tokens_per_correct = 350.0
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: true,  judgeTokens: 200),
            makeJudgedScore(queryID: "q2", judgeCorrect: false, judgeTokens: 150),
        ]
        let report = buildReport(scores: scores,
                                 judgeCmd: "sentinel", judgeGrading: .substring)
        guard let tpc = report.tokensPerCorrect else {
            Issue.record("tokens_per_correct must be non-nil when at least one correct")
            return
        }
        #expect(abs(tpc - 350.0) < 1e-6,
                "tokens_per_correct = (200+150) / 1 = 350.0")
    }

    @Test("tokens_per_correct is nil when correct count is zero")
    func tokensPerCorrectNilWhenNoneCorrect() {
        let scores = [
            makeJudgedScore(queryID: "q1", judgeCorrect: false, judgeTokens: 100),
            makeJudgedScore(queryID: "q2", judgeCorrect: false, judgeTokens: 120),
        ]
        let report = buildReport(scores: scores,
                                 judgeCmd: "sentinel", judgeGrading: .substring)
        #expect(report.tokensPerCorrect == nil,
                "tokens_per_correct must be nil when no queries are correct (division by zero avoided)")
    }

    @Test("tokens_per_correct is nil when no queries were judged")
    func tokensPerCorrectNilWhenNoJudge() {
        let scores = [makeJudgedScore(queryID: "q1", judgeCorrect: nil)]
        let report = buildReport(scores: scores)
        #expect(report.tokensPerCorrect == nil)
    }
}

// MARK: - judge_cmd_set (secrecy rule)

@Suite("LMEB judge accuracy: judge_cmd_set (secrecy rule)")
struct LMEBJudgeCmdSetTests {

    @Test("judge_cmd_set is true when judgeCmd was provided")
    func judgeCmdSetTrue() {
        let report = buildReport(
            scores: [],
            // The command text itself may carry API keys — only boolean presence
            // is written to the report. This test verifies the bool, never the text.
            judgeCmd: "claude -p --some-api-key=SECRET",
            judgeGrading: .substring
        )
        #expect(report.judgeCmdSet == true,
                "judge_cmd_set must be true when judgeCmd is non-nil")
    }

    @Test("judge_cmd_set is false when no judgeCmd was provided")
    func judgeCmdSetFalse() {
        let report = buildReport(scores: [], judgeCmd: nil)
        #expect(report.judgeCmdSet == false,
                "judge_cmd_set must be false when judgeCmd is nil")
    }

    @Test("judge_cmd_set is a Bool — the command text is not in the report")
    func judgeCmdSetIsBoolNotText() {
        // Encode the report as JSON and verify judge_cmd_set is a Bool, not a String.
        let report = buildReport(
            scores: [],
            judgeCmd: "echo my-api-key",
            judgeGrading: .verdict
        )
        guard let data = try? JSONEncoder().encode(report),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Report must be JSON-encodable")
            return
        }
        // judge_cmd_set must be a Bool.
        let raw = dict["judge_cmd_set"]
        #expect(raw is Bool, "judge_cmd_set in JSON must be a Bool, not String or other type")
        // The command text must NOT appear anywhere in the JSON output.
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("my-api-key"),
                "Command text (including API keys) must never appear in the report JSON")
        #expect(!json.contains("echo my-api-key"),
                "judge_cmd value must not appear in the report JSON under any key")
    }
}

// MARK: - judge_grading

@Suite("LMEB judge accuracy: judge_grading field")
struct LMEBJudgeGradingFieldTests {

    @Test("judge_grading is 'substring' when judge configured with substring mode")
    func judgeGradingSubstring() {
        let report = buildReport(scores: [],
                                 judgeCmd: "sentinel", judgeGrading: .substring)
        #expect(report.judgeGrading == "substring")
    }

    @Test("judge_grading is 'verdict' when judge configured with verdict mode")
    func judgeGradingVerdict() {
        let report = buildReport(scores: [],
                                 judgeCmd: "sentinel", judgeGrading: .verdict)
        #expect(report.judgeGrading == "verdict")
    }

    @Test("judge_grading is nil when no judge was configured")
    func judgeGradingNilWhenNoJudge() {
        let report = buildReport(scores: [], judgeCmd: nil, judgeGrading: nil)
        #expect(report.judgeGrading == nil,
                "judge_grading must be nil when judgeCmd was not set")
    }
}
