import Testing
import Foundation
@testable import mcp_benchmarker

// LongMemEvalCorpusTests — unit tests for the LongMemEval JSON loader.
//
// All tests run against the hand-authored synthetic sample committed in this
// same Tests/ directory. No real LongMemEval dataset rows enter the repository.
//
// The synthetic sample (longmemeval_sample.json) contains:
//   - synthetic_001: question_type "single-session-user" (non-abstention, scored)
//   - synthetic_002: question_type "single-session-user_abs" (abstention, excluded)

// MARK: - Path helpers

/// Resolves the synthetic sample JSON from the test file's location.
/// Works in both `swift test` (file is at its source location) and
/// any test runner that preserves the `#filePath` anchor.
///
/// CE flat layout:
///   .../Tests/mcp-benchmarkerTests/LongMemEvalCorpusTests.swift
///     → mcp-benchmarkerTests/ (×1)
///     → Tests/                 (×2)
///     → longmemeval_sample.json (in same mcp-benchmarkerTests/)
private func sampleFixturePath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()  // mcp-benchmarkerTests/
        .appendingPathComponent("longmemeval_sample.json")
}

/// Produces the path for a nonexistent JSON file (used to test load errors).
private func nonexistentPath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .appendingPathComponent("does_not_exist_longmemeval.json")
}

// MARK: - Tests

@Suite("LongMemEval corpus loader")
struct LongMemEvalCorpusTests {

    // MARK: Happy path

    @Test("loads the synthetic sample and returns 1 question, 1 abstention excluded")
    func loadsSyntheticSample() throws {
        let corpus = try loadLMECorpus(from: sampleFixturePath())
        #expect(corpus.questions.count == 1)
        #expect(corpus.abstentionCount == 1)
        #expect(corpus.totalCount == 2)
    }

    @Test("loaded question has correct top-level fields")
    func loadedQuestionFields() throws {
        let corpus = try loadLMECorpus(from: sampleFixturePath())
        let q = try #require(corpus.questions.first)

        #expect(q.questionID == "synthetic_001")
        #expect(q.questionType == "single-session-user")
        #expect(q.question == "What color was the apple Alice mentioned on Monday?")
        #expect(q.answer == "Red")
        #expect(q.questionDate == "2024/01/15 (Mon) 10:00")
        #expect(q.answerSessionIDs == ["session_abc"])
    }

    @Test("haystack arrays are parallel and have the right values")
    func haystackParallelArrays() throws {
        let corpus = try loadLMECorpus(from: sampleFixturePath())
        let q = try #require(corpus.questions.first)

        // Parallel arrays must have identical length.
        #expect(q.haystackSessionIDs.count == q.haystackSessions.count)
        #expect(q.haystackDates.count == q.haystackSessionIDs.count)

        #expect(q.haystackSessionIDs == ["session_abc"])
        #expect(q.haystackDates == ["2024/01/14 (Sun) 09:00"])
    }

    @Test("haystack session turns decode with correct role/content/has_answer")
    func turnDecoding() throws {
        let corpus = try loadLMECorpus(from: sampleFixturePath())
        let q = try #require(corpus.questions.first)
        let session = try #require(q.haystackSessions.first)

        #expect(session.count == 2)
        let t0 = session[0]
        #expect(t0.role == "user")
        #expect(t0.content == "I saw a red apple at the market.")
        #expect(t0.hasAnswer == true)

        let t1 = session[1]
        #expect(t1.role == "assistant")
        #expect(t1.hasAnswer == false)
    }

    @Test("abstention question is excluded from corpus.questions")
    func abstentionExclusion() throws {
        let corpus = try loadLMECorpus(from: sampleFixturePath())
        // The only question in questions[] must be the non-abstention one.
        for q in corpus.questions {
            #expect(!q.questionType.hasSuffix("_abs"),
                    "abstention question '\(q.questionID)' should not appear in corpus.questions")
        }
    }

    // MARK: Schema validation errors

    @Test("missing question_id raises LMELoadError naming the field and index")
    func missingQuestionID() throws {
        let badJSON = """
        [{"question_id": "", "question_type": "single-session-user",
          "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": [], "haystack_session_ids": [],
          "haystack_sessions": [], "answer_session_ids": []}]
        """.data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_bad_id.json")
        try badJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try loadLMECorpus(from: tmp)
            Issue.record("expected LMELoadError for empty question_id, got success")
        } catch let err as LMELoadError {
            #expect(err.description.contains("question_id"),
                    "error should name 'question_id': \(err.description)")
            #expect(err.description.contains("question[0]"),
                    "error should name index 0: \(err.description)")
        }
    }

    @Test("parallel-array length mismatch raises LMELoadError naming the field and index")
    func parallelArrayMismatch() throws {
        // haystack_session_ids has 1 entry; haystack_sessions has 0 — a mismatch.
        let badJSON = """
        [{"question_id": "x1", "question_type": "single-session-user",
          "question": "q", "answer": "a", "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": ["2024/01/01 (Mon) 00:00"],
          "haystack_session_ids": ["sess1"],
          "haystack_sessions": [],
          "answer_session_ids": []}]
        """.data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_bad_parallel.json")
        try badJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try loadLMECorpus(from: tmp)
            Issue.record("expected LMELoadError for parallel-array mismatch, got success")
        } catch let err as LMELoadError {
            #expect(err.description.contains("haystack_session_ids"),
                    "error should name the mismatched field: \(err.description)")
            #expect(err.description.contains("question[0]"),
                    "error should name index 0: \(err.description)")
        }
    }

    @Test("load from nonexistent path throws (not a silent empty corpus)")
    func nonexistentFile() {
        #expect(throws: (any Error).self) {
            try loadLMECorpus(from: nonexistentPath())
        }
    }

    // MARK: Empty-corpus edge case

    @Test("all-abstention file yields zero questions and correct abstentionCount")
    func allAbstentions() throws {
        let absJSON = """
        [{"question_id": "abs1", "question_type": "multi-session_abs",
          "question": "Did X happen?", "answer": "unknown",
          "question_date": "2024/01/01 (Mon) 00:00",
          "haystack_dates": [], "haystack_session_ids": [],
          "haystack_sessions": [], "answer_session_ids": []}]
        """.data(using: .utf8)!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lme_all_abs.json")
        try absJSON.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let corpus = try loadLMECorpus(from: tmp)
        #expect(corpus.questions.isEmpty)
        #expect(corpus.abstentionCount == 1)
        #expect(corpus.totalCount == 1)
    }
}
