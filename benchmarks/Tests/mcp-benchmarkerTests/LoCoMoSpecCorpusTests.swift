import XCTest
@testable import mcp_benchmarker

// LoCoMoSpecCorpusTests.swift — Unit tests for the spec-compliant LoCoMo corpus loader.
//
// Verifies:
//   - ALL questions are loaded (no cat-5 or empty-evidence exclusion).
//   - Image captions (blip_caption) are preserved in turns.
//   - Category counts and question structure match the spec.
//   - §6 context-formatting helpers produce byte-identical output to the spec format.
//
// Uses locomo_spec_sample.json (hand-authored synthetic fixture with:
//   session 1: 3 turns, turn D1:2 has a blip_caption
//   session 2: 2 turns
//   QAs: cat1, cat4, cat2-with-empty-evidence, cat5-adversarial).

final class LoCoMoSpecCorpusTests: XCTestCase {

    // MARK: - Helpers

    private func sampleURL() throws -> URL {
        let testDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let url = testDir.appendingPathComponent("locomo_spec_sample.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("locomo_spec_sample.json not found at \(url.path)")
        }
        return url
    }

    // MARK: - Basic load — all 4 QAs included (no exclusions)

    func testLoadsAllQuestions() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        // Fixture has 4 QAs: cat1, cat4, cat2-empty-evidence, cat5 — all included.
        XCTAssertEqual(corpus.questions.count, 4,
                       "spec loader includes all questions; none excluded")
        XCTAssertEqual(corpus.totalCount, 4)
    }

    func testCategory5Included() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let cat5 = corpus.questions.filter { $0.category == 5 }
        XCTAssertEqual(cat5.count, 1,
                       "category 5 adversarial questions must be included in spec loader")
    }

    func testEmptyEvidenceQuestionIncluded() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        // The cat2 QA in the fixture has an empty evidence list.
        let emptyEv = corpus.questions.filter { $0.evidence.isEmpty }
        XCTAssertEqual(emptyEv.count, 1,
                       "questions with empty evidence are included (4 exist in full dataset)")
    }

    // MARK: - Category counts

    func testCategoryCountsMatchFixture() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        // Fixture: cat1=1, cat2=1, cat4=1, cat5=1 (cat3=0)
        XCTAssertEqual(corpus.categoryCounts[1], 1)
        XCTAssertEqual(corpus.categoryCounts[2], 1)
        XCTAssertNil(corpus.categoryCounts[3])    // no cat3 in fixture
        XCTAssertEqual(corpus.categoryCounts[4], 1)
        XCTAssertEqual(corpus.categoryCounts[5], 1)
    }

    // MARK: - Category 5 question structure

    func testCategory5HasAdversarialAnswer() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let cat5 = corpus.questions.first(where: { $0.category == 5 })!
        XCTAssertNil(cat5.answer,
                     "category 5 question must have nil answer (no gold truth)")
        XCTAssertEqual(cat5.adversarialAnswer, "Yes, she hated it.",
                       "adversarial_answer must be loaded for category 5")
    }

    func testCategory5CategoryLabel() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let cat5 = corpus.questions.first(where: { $0.category == 5 })!
        XCTAssertEqual(cat5.categoryLabel, "adversarial")
    }

    // MARK: - Non-category-5 question structure

    func testNonAdversarialQuestionsHaveAnswers() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let nonCat5 = corpus.questions.filter { $0.category != 5 }
        // Cat1 and cat4 in the fixture have gold answers; cat2 has empty evidence
        // but the cat2 fixture entry has no answer field (tests nil tolerance).
        let withAnswer = nonCat5.filter { $0.answer != nil }
        XCTAssert(withAnswer.count >= 2,
                  "at least cat1 and cat4 questions must carry a gold answer")
    }

    // MARK: - Turn image captions

    func testImageCaptionPreservedInTurn() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        // Session 1, turn D1:2 has a blip_caption in the fixture.
        let s1 = conv.sessions[0]
        XCTAssertEqual(s1.turns.count, 3)
        let turnWithCaption = s1.turns[1] // D1:2
        XCTAssertEqual(turnWithCaption.diaID, "D1:2")
        XCTAssertNotNil(turnWithCaption.imageCaption,
                        "blip_caption must be preserved as imageCaption")
        XCTAssertEqual(turnWithCaption.imageCaption,
                       "a painting of a sunset over the ocean")
    }

    func testTurnsWithoutCaptionHaveNilCaption() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        let s1 = conv.sessions[0]
        // D1:1 has no image.
        XCTAssertNil(s1.turns[0].imageCaption, "non-image turn must have nil imageCaption")
        // D1:3 has no image.
        XCTAssertNil(s1.turns[2].imageCaption, "non-image turn must have nil imageCaption")
    }

    // MARK: - Conversation structure

    func testConversationSpeakers() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        XCTAssertEqual(conv.speakerA, "Alice")
        XCTAssertEqual(conv.speakerB, "Bob")
        XCTAssertEqual(conv.sampleID, "spec-conv-01")
    }

    func testSessionsChronologicalOrder() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        XCTAssertEqual(conv.sessions.count, 2)
        XCTAssertEqual(conv.sessions[0].sessionNumber, 1)
        XCTAssertEqual(conv.sessions[1].sessionNumber, 2)
        XCTAssertEqual(conv.sessions[0].dateTime, "3:00 pm on 1 Jan, 2024")
        XCTAssertEqual(conv.sessions[1].dateTime, "2:00 pm on 10 Jan, 2024")
    }

    func testAllTurnsFlattened() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        let flat = conv.allTurns
        // 3 (session1) + 2 (session2) = 5
        XCTAssertEqual(flat.count, 5)
        XCTAssertEqual(flat[0].sessionNumber, 1)
        XCTAssertEqual(flat[0].turn.diaID, "D1:1")
        XCTAssertEqual(flat[3].sessionNumber, 2)
        XCTAssertEqual(flat[3].turn.diaID, "D2:1")
    }

    // MARK: - §6 Context formatting helpers

    /// Preamble must reproduce the official text verbatim, including the typo 'wriiten'.
    /// LOCOMO_OFFICIAL_PROTOCOL.md §6.
    func testPreambleVerbatim() {
        let p = loCoMoConversationPreamble(speakerA: "Alice", speakerB: "Bob")
        XCTAssertTrue(p.contains("wriiten"),
                      "preamble must contain the official typo 'wriiten' (§6)")
        XCTAssertTrue(p.hasPrefix("Below is a conversation between two people: Alice and Bob."),
                      "preamble must start with speaker names substituted")
    }

    func testSessionHeader() {
        let h = loCoMoSessionHeader(dateTime: "1:56 pm on 8 May, 2023")
        XCTAssertEqual(h, "DATE: 1:56 pm on 8 May, 2023 CONVERSATION:",
                       "session header must match §6 format exactly")
    }

    func testFormatTurnNoCaption() {
        let turn = LoCoMoSpecTurn(
            speaker: "Alice", diaID: "D1:1",
            text: "Hey Bob! I visited the art museum today.",
            imageCaption: nil
        )
        let line = loCoMoFormatTurn(turn)
        XCTAssertEqual(line,
                       "Alice said, \"Hey Bob! I visited the art museum today.\"",
                       "turn without image must match §6 format without caption suffix")
    }

    func testFormatTurnWithCaption() {
        // §6: append ' and shared [caption]' for image turns.
        let turn = LoCoMoSpecTurn(
            speaker: "Bob", diaID: "D1:2",
            text: "That sounds wonderful! Which exhibit?",
            imageCaption: "a painting of a sunset over the ocean"
        )
        let line = loCoMoFormatTurn(turn)
        XCTAssertEqual(
            line,
            "Bob said, \"That sounds wonderful! Which exhibit?\" " +
            "and shared a painting of a sunset over the ocean",
            "turn with image must append ' and shared [caption]' per §6"
        )
    }

    func testFormatContextStructure() throws {
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        let ctx = loCoMoFormatContext(conv)

        // Preamble line.
        XCTAssertTrue(ctx.hasPrefix("Below is a conversation between two people: Alice and Bob."),
                      "context must start with preamble")
        XCTAssertTrue(ctx.contains("wriiten"),
                      "context preamble must include the official typo")

        // Session headers.
        XCTAssertTrue(ctx.contains("DATE: 3:00 pm on 1 Jan, 2024 CONVERSATION:"),
                      "context must contain session 1 header")
        XCTAssertTrue(ctx.contains("DATE: 2:00 pm on 10 Jan, 2024 CONVERSATION:"),
                      "context must contain session 2 header")

        // Turn without caption.
        XCTAssertTrue(ctx.contains("Alice said, \"Hey Bob! I visited the art museum today.\""),
                      "context must include non-image turn in §6 format")

        // Turn with caption — caption appended.
        XCTAssertTrue(
            ctx.contains("Bob said, \"That sounds wonderful! Which exhibit?\" " +
                         "and shared a painting of a sunset over the ocean"),
            "context must append caption for image turn"
        )

        // Context must end with a newline (trailing newline after last turn).
        XCTAssertTrue(ctx.hasSuffix("\n"),
                      "context string must end with a newline")

        // Sessions appear in chronological order: session-1 header before session-2 header.
        let s1Pos = ctx.range(of: "DATE: 3:00 pm on 1 Jan, 2024")!.lowerBound
        let s2Pos = ctx.range(of: "DATE: 2:00 pm on 10 Jan, 2024")!.lowerBound
        XCTAssertLessThan(s1Pos, s2Pos,
                          "session 1 header must appear before session 2 (chronological order)")
    }

    func testFormatContextSessionsChronological() throws {
        // Verify session ordering: preamble < session1-header < session1-turn <
        // session2-header < session2-turn.
        let corpus = try loadLoCoMoSpecCorpus(from: sampleURL())
        let conv = corpus.conversations[0]
        let ctx = loCoMoFormatContext(conv)
        let lines = ctx.components(separatedBy: "\n")
        let headerLines = lines.filter { $0.hasPrefix("DATE:") }
        XCTAssertEqual(headerLines.count, 2, "two sessions → two DATE: header lines")
        XCTAssertTrue(headerLines[0].contains("1 Jan"), "first header is session 1")
        XCTAssertTrue(headerLines[1].contains("10 Jan"), "second header is session 2")
    }

    // MARK: - Error cases

    func testLoadFromNonexistentPathThrows() {
        let bogusURL = URL(fileURLWithPath: "/tmp/does_not_exist_spec_\(UUID()).json")
        XCTAssertThrowsError(try loadLoCoMoSpecCorpus(from: bogusURL)) { error in
            XCTAssert(error is LoCoMoSpecLoadError)
        }
    }

    func testLoadFromMalformedJSONThrows() throws {
        let tmpURL = URL(fileURLWithPath: "/tmp/locomo_spec_malformed_\(UUID()).json")
        try "not valid json [[[".write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        XCTAssertThrowsError(try loadLoCoMoSpecCorpus(from: tmpURL)) { error in
            XCTAssert(error is LoCoMoSpecLoadError)
        }
    }
}
