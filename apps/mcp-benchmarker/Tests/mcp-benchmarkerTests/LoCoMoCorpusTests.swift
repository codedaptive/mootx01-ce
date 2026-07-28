import XCTest
@testable import mcp_benchmarker

// LoCoMoCorpusTests.swift — Unit tests for the LoCoMo corpus loader.
//
// All tests use the hand-authored synthetic sample at locomo_sample.json;
// no real dataset rows are committed to the repo.

final class LoCoMoCorpusTests: XCTestCase {

    // MARK: - Helpers

    private func sampleURL() throws -> URL {
        // Locate locomo_sample.json relative to this source file.
        // #filePath = Tests/mcp-benchmarkerTests/LoCoMoCorpusTests.swift
        // One level up → Tests/mcp-benchmarkerTests/
        let testDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testDir.appendingPathComponent("locomo_sample.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("locomo_sample.json not found at \(url.path)")
        }
        return url
    }

    // MARK: - Basic load

    func testLoadsSyntheticSample() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())

        // Synthetic sample has 1 conversation.
        XCTAssertEqual(corpus.conversations.count, 1, "expected 1 conversation")
        // 4 scoreable QAs (categories 1-4); 1 adversarial (category 5) excluded.
        XCTAssertEqual(corpus.questions.count, 4, "expected 4 scoreable questions")
        XCTAssertEqual(corpus.adversarialCount, 1, "expected 1 adversarial excluded")
        XCTAssertEqual(corpus.totalCount, 5, "totalCount = questions + adversarial")
    }

    // MARK: - Conversation structure

    func testConversationFields() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let conv = corpus.conversations[0]

        XCTAssertEqual(conv.sampleID, "test-conv-01")
        XCTAssertEqual(conv.speakerA, "Alice")
        XCTAssertEqual(conv.speakerB, "Bob")
        XCTAssertEqual(conv.sessions.count, 2, "expected 2 sessions")
    }

    func testSessionsInOrder() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let conv = corpus.conversations[0]

        XCTAssertEqual(conv.sessions[0].sessionNumber, 1)
        XCTAssertEqual(conv.sessions[1].sessionNumber, 2)

        // Session timestamps from synthetic sample.
        XCTAssertEqual(conv.sessions[0].dateTime, "3:00 pm on 1 Jan, 2024")
        XCTAssertEqual(conv.sessions[1].dateTime, "2:00 pm on 15 Jan, 2024")
    }

    func testTurnCountsPerSession() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let conv = corpus.conversations[0]

        XCTAssertEqual(conv.sessions[0].turns.count, 5, "session 1 has 5 turns")
        XCTAssertEqual(conv.sessions[1].turns.count, 4, "session 2 has 4 turns")
    }

    func testTurnDiaIDs() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let conv = corpus.conversations[0]

        // Verify dia_id values for session 1.
        let s1diaIDs = conv.sessions[0].turns.map(\.diaID)
        XCTAssertEqual(s1diaIDs, ["D1:1", "D1:2", "D1:3", "D1:4", "D1:5"])

        // Verify dia_id values for session 2.
        let s2diaIDs = conv.sessions[1].turns.map(\.diaID)
        XCTAssertEqual(s2diaIDs, ["D2:1", "D2:2", "D2:3", "D2:4"])
    }

    func testAllTurnsFlattened() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let conv = corpus.conversations[0]

        let allTurns = conv.allTurns
        // 5 + 4 turns.
        XCTAssertEqual(allTurns.count, 9)
        // First tuple: session 1, turn "D1:1".
        XCTAssertEqual(allTurns[0].sessionNumber, 1)
        XCTAssertEqual(allTurns[0].turn.diaID, "D1:1")
        // Sixth tuple: session 2, turn "D2:1".
        XCTAssertEqual(allTurns[5].sessionNumber, 2)
        XCTAssertEqual(allTurns[5].turn.diaID, "D2:1")
    }

    // MARK: - Question fields

    func testQuestionCategories() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let categories = corpus.questions.map(\.category)
        // Synthetic sample: categories 1, 2, 3, 4 (category 5 excluded).
        XCTAssertEqual(Set(categories), Set([1, 2, 3, 4]),
                       "expected categories 1-4 in questions")
    }

    func testCategoryLabels() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        let labelByCategory = Dictionary(
            uniqueKeysWithValues: corpus.questions.map { ($0.category, $0.categoryLabel) })
        XCTAssertEqual(labelByCategory[1], "single_hop")
        XCTAssertEqual(labelByCategory[2], "temporal")
        XCTAssertEqual(labelByCategory[3], "multi_hop")
        XCTAssertEqual(labelByCategory[4], "open_domain")
    }

    func testQuestionsHaveConversationIndex() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        // All questions belong to conversation 0.
        for q in corpus.questions {
            XCTAssertEqual(q.conversationIndex, 0,
                           "question \(q.questionID) should reference conversation 0")
        }
    }

    func testQuestionIDsGenerated() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        // Each questionID contains the sample_id prefix.
        for q in corpus.questions {
            XCTAssert(q.questionID.hasPrefix("test-conv-01"),
                      "questionID should start with sampleID: \(q.questionID)")
        }
        // All questionIDs are distinct.
        let ids = corpus.questions.map(\.questionID)
        XCTAssertEqual(Set(ids).count, ids.count, "questionIDs must be unique")
    }

    func testEvidenceField() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        // Category 1 question has single evidence dia_id.
        let cat1 = corpus.questions.first(where: { $0.category == 1 })!
        XCTAssertEqual(cat1.evidence, ["D1:3"])

        // Category 3 question has two evidence dia_ids.
        let cat3 = corpus.questions.first(where: { $0.category == 3 })!
        XCTAssertEqual(cat3.evidence.count, 2)
        XCTAssert(cat3.evidence.contains("D2:2"))
        XCTAssert(cat3.evidence.contains("D2:4"))
    }

    // MARK: - Adversarial exclusion

    func testCategory5Excluded() throws {
        let corpus = try loadLoCoMoCorpus(from: sampleURL())
        // No category 5 questions should appear in the questions array.
        XCTAssert(corpus.questions.allSatisfy { $0.category != 5 },
                  "category 5 must be excluded from questions")
        XCTAssertEqual(corpus.adversarialCount, 1,
                       "adversarial count must reflect excluded questions")
    }

    // MARK: - Error cases

    func testLoadFromNonexistentPathThrows() {
        let bogusURL = URL(fileURLWithPath: "/tmp/does_not_exist_locomo_\(UUID()).json")
        XCTAssertThrowsError(try loadLoCoMoCorpus(from: bogusURL),
                             "loading a nonexistent file should throw LoCoMoLoadError") { error in
            XCTAssert(error is LoCoMoLoadError,
                      "expected LoCoMoLoadError, got \(type(of: error))")
        }
    }

    func testLoadFromMalformedJSONThrows() throws {
        let tmpURL = URL(fileURLWithPath: "/tmp/locomo_malformed_\(UUID()).json")
        try "not valid json [[[".write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        XCTAssertThrowsError(try loadLoCoMoCorpus(from: tmpURL),
                             "malformed JSON should throw LoCoMoLoadError") { error in
            XCTAssert(error is LoCoMoLoadError)
        }
    }

    func testEmptySampleIDThrows() throws {
        let bad = """
        [{"sample_id": "", "conversation": {"speaker_a": "A", "speaker_b": "B",
          "session_1_date_time": "noon", "session_1": [{"speaker": "A", "dia_id": "D1:1", "text": "hi"}]},
          "qa": [], "event_summary": {}, "observation": {}, "session_summary": {}}]
        """
        let tmpURL = URL(fileURLWithPath: "/tmp/locomo_bad_id_\(UUID()).json")
        try bad.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        XCTAssertThrowsError(try loadLoCoMoCorpus(from: tmpURL)) { error in
            guard let le = error as? LoCoMoLoadError else {
                return XCTFail("expected LoCoMoLoadError")
            }
            XCTAssert(le.description.contains("sample_id"),
                      "error should name the missing field: \(le.description)")
        }
    }

    func testNoSessionsThrows() throws {
        let bad = """
        [{"sample_id": "conv-test", "conversation": {"speaker_a": "A", "speaker_b": "B"},
          "qa": [], "event_summary": {}, "observation": {}, "session_summary": {}}]
        """
        let tmpURL = URL(fileURLWithPath: "/tmp/locomo_no_sessions_\(UUID()).json")
        try bad.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        XCTAssertThrowsError(try loadLoCoMoCorpus(from: tmpURL)) { error in
            guard let le = error as? LoCoMoLoadError else {
                return XCTFail("expected LoCoMoLoadError")
            }
            XCTAssert(le.description.contains("no sessions") || le.description.contains("session"),
                      "error should name the missing sessions: \(le.description)")
        }
    }
}
