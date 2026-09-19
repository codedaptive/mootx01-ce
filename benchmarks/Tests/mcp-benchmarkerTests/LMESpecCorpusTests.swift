import Testing
import Foundation
@testable import mcp_benchmarker

// LMESpecCorpusTests — unit tests for the spec-compliant LongMemEval corpus loader.
//
// All tests run against the hand-authored synthetic fixture lme_spec_sample.json
// committed in this same Tests/mcp-benchmarkerTests/ directory.
//
// The synthetic fixture contains three questions:
//   spec_001   question_type "single-session-user"        → isAbstention=false, baseQType="single-session-user"
//   spec_002_abs question_type "multi-session"            → isAbstention=true  (qid contains '_abs'), baseQType="multi-session"
//   spec_003   question_type "temporal-reasoning_abs"     → isAbstention=false (qid has NO '_abs'), baseQType="temporal-reasoning"
//
// Key invariants verified:
//   - All 3 questions are loaded (no filtering)
//   - isAbstention uses question_id selector per §2 (not question_type)
//   - baseQuestionType strips trailing '_abs' from question_type
//   - Schema validation matches the loadLMECorpus error style

// MARK: - Path helpers

/// Resolves the spec fixture JSON from the test file's source location.
/// Works in `swift test` (file is at its source path; #filePath is correct).
private func specFixturePath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()      // → mcp-benchmarkerTests/
        .appendingPathComponent("lme_spec_sample.json")
}

/// Nonexistent path for error-path tests.
private func nonexistentSpecPath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .appendingPathComponent("does_not_exist_lme_spec.json")
}

// MARK: - Happy-path tests

@Suite("LMESpec corpus loader — happy path")
struct LMESpecCorpusHappyPathTests {

    @Test("loads all 3 questions from the spec fixture (no filtering)")
    func loadsAllInstances() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        // Per spec §1 and §6 row 2: ALL instances are loaded, including abstention.
        #expect(corpus.questions.count == 3,
                "totalCount should be 3, got \(corpus.questions.count)")
        #expect(corpus.totalCount == 3)
    }

    @Test("abstentionCount reflects only questions where question_id contains '_abs'")
    func abstentionCount() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        // spec_002_abs has '_abs' in question_id → 1 abstention.
        // spec_001 and spec_003 do NOT have '_abs' in question_id.
        // spec_003 has '_abs' in question_type but that is NOT the §2 selector.
        #expect(corpus.abstentionCount == 1,
                "abstentionCount should be 1, got \(corpus.abstentionCount)")
    }

    @Test("spec_001 is a standard non-abstention question")
    func spec001Fields() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        let q = try #require(corpus.questions.first(where: { $0.questionID == "spec_001" }))

        #expect(q.questionID == "spec_001")
        #expect(q.questionType == "single-session-user")
        #expect(q.question == "What color is the car Alice mentioned?")
        #expect(q.answer == "Blue")
        #expect(q.answerSessionIDs == ["sess_001"])

        // §2 abstention selector: '_abs' in question_id → false.
        #expect(!q.isAbstention, "spec_001 should not be abstention")
        // §4 base type: no suffix to strip.
        #expect(q.baseQuestionType == "single-session-user")
    }

    @Test("spec_002_abs is abstention via question_id selector (§2)")
    func spec002AbsFields() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        let q = try #require(corpus.questions.first(where: { $0.questionID == "spec_002_abs" }))

        #expect(q.questionID == "spec_002_abs")
        // question_type is the base type (no '_abs' suffix in real dataset).
        #expect(q.questionType == "multi-session")
        // §2: abstention = '_abs' in question_id.
        #expect(q.isAbstention, "spec_002_abs should be abstention (qid contains '_abs')")
        // baseQuestionType has no suffix to strip.
        #expect(q.baseQuestionType == "multi-session")
        // answer is the unanswerability explanation (§2 abstention block uses it as Explanation).
        #expect(!q.answer.isEmpty, "answer/explanation should be present for abstention question")
    }

    @Test("spec_003 is NOT abstention despite question_type ending in '_abs'")
    func spec003NotAbstention() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        let q = try #require(corpus.questions.first(where: { $0.questionID == "spec_003" }))

        #expect(q.questionID == "spec_003")
        #expect(q.questionType == "temporal-reasoning_abs")
        // §2 selector uses question_id: 'spec_003' does NOT contain '_abs'.
        #expect(!q.isAbstention,
                "spec_003 should NOT be abstention — question_id has no '_abs'")
        // baseQuestionType strips the trailing '_abs' from question_type.
        #expect(q.baseQuestionType == "temporal-reasoning",
                "baseQuestionType should strip '_abs' suffix")
    }

    @Test("baseQuestionType maps onto the §4 six-type list for all fixture questions")
    func baseTypesAreValid() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        for q in corpus.questions {
            let bt = q.baseQuestionType
            let qid = q.questionID
            #expect(lmeSpecBaseTypes.contains(bt),
                    "baseQuestionType '\(bt)' for qid '\(qid)' is not in the §4 fixed type list")
        }
    }

    @Test("countsByBaseType sums all 3 questions under their base types")
    func countsByBaseType() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        let counts = corpus.countsByBaseType()
        // spec_001 → single-session-user (1)
        #expect(counts["single-session-user"] == 1)
        // spec_002_abs → multi-session (1); abstention aggregates under base type per §4.
        #expect(counts["multi-session"] == 1)
        // spec_003 → temporal-reasoning (1); '_abs' stripped from question_type.
        #expect(counts["temporal-reasoning"] == 1)
        // Total across all types must equal question count.
        let total = counts.values.reduce(0, +)
        #expect(total == corpus.totalCount,
                "countsByBaseType total \(total) != totalCount \(corpus.totalCount)")
    }

    @Test("haystack parallel arrays decode correctly for spec_001")
    func haystackArraysParallel() throws {
        let corpus = try loadLMESpecCorpus(from: specFixturePath())
        let q = try #require(corpus.questions.first(where: { $0.questionID == "spec_001" }))

        #expect(q.haystackSessionIDs.count == q.haystackSessions.count)
        #expect(q.haystackDates.count == q.haystackSessionIDs.count)
        #expect(q.haystackSessionIDs == ["sess_001"])
        #expect(q.haystackDates == ["2024/02/28 (Thu) 18:00"])

        let session = try #require(q.haystackSessions.first)
        #expect(session.count == 2)
        #expect(session[0].role == "user")
        #expect(session[0].hasAnswer == true)
        #expect(session[1].role == "assistant")
        #expect(session[1].hasAnswer == false)
    }

    @Test("load from nonexistent path throws (fail-loud, not silent empty corpus)")
    func nonexistentFileFails() {
        #expect(throws: (any Error).self) {
            try loadLMESpecCorpus(from: nonexistentSpecPath())
        }
    }
}

// MARK: - Schema validation tests

@Suite("LMESpec corpus loader — schema validation")
struct LMESpecCorpusValidationTests {

    @Test("missing question_id raises LMESpecLoadError naming the field and index")
    func missingQuestionID() throws {
        let badJSON = """
        [{"question_id": "", "question_type": "single-session-user",
          "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": [], "haystack_session_ids": [],
          "haystack_sessions": [], "answer_session_ids": []}]
        """.data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_spec_bad_id.json")
        try badJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try loadLMESpecCorpus(from: tmp)
            Issue.record("expected LMESpecLoadError for empty question_id, got success")
        } catch let err as LMESpecLoadError {
            #expect(err.description.contains("question_id"),
                    "error should name 'question_id': \(err.description)")
            #expect(err.description.contains("question[0]"),
                    "error should name index 0: \(err.description)")
        }
    }

    @Test("parallel-array length mismatch raises LMESpecLoadError")
    func parallelArrayMismatch() throws {
        let badJSON = """
        [{"question_id": "x1", "question_type": "multi-session",
          "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": ["2024/01/01 (Mon) 00:00"],
          "haystack_session_ids": ["sess1"],
          "haystack_sessions": [],
          "answer_session_ids": []}]
        """.data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_spec_bad_parallel.json")
        try badJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try loadLMESpecCorpus(from: tmp)
            Issue.record("expected LMESpecLoadError for parallel-array mismatch, got success")
        } catch let err as LMESpecLoadError {
            #expect(err.description.contains("haystack_session_ids"),
                    "error should name the mismatched field: \(err.description)")
            #expect(err.description.contains("question[0]"),
                    "error should name index 0: \(err.description)")
        }
    }

    @Test("all-abstention file yields all questions loaded (no filtering)")
    func allAbstentionsIncluded() throws {
        // Spec deviation fix: the original loader excluded '_abs' questions.
        // The spec corpus includes them all. Verify that a file with only
        // abstention-type question_ids loads successfully with count == 2.
        let absJSON = """
        [
          {"question_id": "abs_q1_abs", "question_type": "multi-session",
           "question": "Did X happen?", "answer": "No evidence found.",
           "question_date": "2024/01/01 (Mon) 00:00",
           "haystack_dates": [], "haystack_session_ids": [],
           "haystack_sessions": [], "answer_session_ids": []},
          {"question_id": "abs_q2_abs", "question_type": "knowledge-update",
           "question": "What is Y?", "answer": "Not mentioned.",
           "question_date": "2024/01/02 (Tue) 00:00",
           "haystack_dates": [], "haystack_session_ids": [],
           "haystack_sessions": [], "answer_session_ids": []}
        ]
        """.data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_spec_all_abs.json")
        try absJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let corpus = try loadLMESpecCorpus(from: tmp)
        // Both questions are loaded — spec corpus never filters.
        #expect(corpus.questions.count == 2)
        #expect(corpus.abstentionCount == 2)
        #expect(corpus.totalCount == 2)
    }

    @Test("empty-array file yields empty corpus with zero questions")
    func emptyFile() throws {
        let emptyJSON = "[]".data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_spec_empty.json")
        try emptyJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let corpus = try loadLMESpecCorpus(from: tmp)
        #expect(corpus.questions.isEmpty)
        #expect(corpus.abstentionCount == 0)
        #expect(corpus.totalCount == 0)
    }
}
