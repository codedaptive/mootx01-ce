import Testing
import Foundation
@testable import mcp_benchmarker

// LoCoMoSpecCorpusCountTests.swift — Full-dataset and formatting tests for the
// LoCoMo spec-lane corpus loader (§3, §4, §6 of LOCOMO_OFFICIAL_PROTOCOL.md).
//
// Two test groups:
//   1. Full-dataset counts (requires benchmarks/fixtures/locomo/data/locomo10.json).
//      Skipped automatically when the file is absent — the file exists on the
//      local build machine and on llm_models; CI may not have it.
//   2. §6 formatting literals — loaded from the shared sample fixture
//      (locomo_spec_sample.json, always present in the test target).
//      Both groups assert the same literal string as the Rust twin
//      (locomo_spec_conformance.rs) to enforce cross-port byte-identical output.
//
// Run with:
//   swift test --scratch-path .build-locospec --filter LoCoMoSpecCorpus

// MARK: - Path helpers

/// Resolves the locomo10.json full dataset path from this file's location.
/// #filePath → Tests/mcp-benchmarkerTests/ → Tests/ → benchmarks/ → fixtures/locomo/data/
private func locomo10URL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // .../mcp-benchmarkerTests/
        .deletingLastPathComponent()   // .../Tests/
        .deletingLastPathComponent()   // .../benchmarks/
        .appendingPathComponent("fixtures/locomo/data/locomo10.json")
}

/// Resolves the shared synthetic sample fixture.
private func sampleURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("locomo_spec_sample.json")
}

// MARK: - Full-dataset corpus counts

@Suite("LoCoMoSpecCorpus — full-dataset counts (locomo10.json)")
struct LoCoMoSpecCorpusCountTests {

    // Load once in each test; the file is small enough (≈ 10 MB) that
    // repeated disk reads do not affect test duration measurably.
    private func loadFullCorpus() throws -> LoCoMoSpecCorpus? {
        let url = locomo10URL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil  // graceful skip
        }
        return try loadLoCoMoSpecCorpus(from: url)
    }

    /// Official dataset total: 1,986 questions across all five categories.
    /// §7 deviation #2: category 5 (adversarial) is NOT excluded in the spec lane.
    @Test("total QA count is 1,986 across all categories")
    func totalQuestionCount() throws {
        guard let corpus = try loadFullCorpus() else { return }
        // All 1,986 questions: 282 + 321 + 96 + 841 + 446 = 1,986.
        #expect(corpus.totalCount == 1986,
                "spec lane must include all 1,986 questions; got \(corpus.totalCount)")
        #expect(corpus.questions.count == 1986,
                "questions array length must equal totalCount")
    }

    /// Per-category counts verified against the official dataset (verified 2026-08-18).
    /// §3 deviation note from LOCOMO_OFFICIAL_PROTOCOL.md §7: all five categories included.
    @Test("category counts: {1:282, 2:321, 3:96, 4:841, 5:446}")
    func categoryCountsMatchOfficial() throws {
        guard let corpus = try loadFullCorpus() else { return }
        let expectedCounts: [Int: Int] = [1: 282, 2: 321, 3: 96, 4: 841, 5: 446]
        for (cat, expCount) in expectedCounts.sorted(by: { $0.key < $1.key }) {
            let gotCount = corpus.categoryCounts[cat] ?? 0
            #expect(gotCount == expCount,
                    "category \(cat) count: expected \(expCount), got \(gotCount)")
        }
        // Cross-check sum equals total.
        let sumOfCategories = expectedCounts.values.reduce(0, +)
        #expect(sumOfCategories == 1986, "sanity: sum of expected category counts must equal 1,986")
    }

    /// Category 5 adversarial questions may have a nil answer OR a non-nil answer (e.g. "No")
    /// depending on the raw dataset field. The scorer ignores the gold answer for cat-5 entirely —
    /// it applies a binary abstention rule solely on the prediction text (§3).
    /// This test only verifies the expected count of 446 cat-5 questions.
    @Test("category 5 question count is 446")
    func cat5Count() throws {
        guard let corpus = try loadFullCorpus() else { return }
        let cat5 = corpus.questions.filter { $0.category == 5 }
        #expect(cat5.count == 446, "expected 446 adversarial questions; got \(cat5.count)")
    }

    /// The spec lane includes 4 non-cat5 questions with empty evidence lists.
    /// §4: evidence recall appends 1 when evidence is empty (not excluded from the run).
    @Test("exactly 4 non-adversarial questions have empty evidence lists")
    func emptyEvidenceNonAdversarialCount() throws {
        guard let corpus = try loadFullCorpus() else { return }
        let emptyEvNonCat5 = corpus.questions.filter {
            $0.category != 5 && $0.evidence.isEmpty
        }
        #expect(emptyEvNonCat5.count == 4)
    }

    /// Category-3 (multi_hop) gold answers are stored verbatim at load time.
    /// §3 mandates truncation at the first ';' — but that truncation happens at
    /// SCORING time (in scoreQuestion), not at loading time. The raw ';'-containing
    /// answer must be visible in the corpus so the scorer can apply the rule.
    @Test("category-3 gold answers preserve ';' segments (truncation is at scoring, not loading)")
    func cat3GoldAnswersPreserveSemicolon() throws {
        guard let corpus = try loadFullCorpus() else { return }
        let cat3 = corpus.questions.filter { $0.category == 3 }
        #expect(cat3.count == 96, "expected 96 category-3 questions")
        // At least some cat-3 answers in the official dataset contain ';' segments.
        // If ALL answers were truncated at load, none would contain ';'.
        let withSemicolon = cat3.filter { $0.answer?.contains(";") == true }
        #expect(!withSemicolon.isEmpty)
    }
}

// MARK: - §6 Context-formatting literals (sample fixture)

@Suite("LoCoMoSpecCorpus — §6 formatting literals (sample fixture)")
struct LoCoMoSpecCorpusFormattingTests {

    private func loadSample() throws -> LoCoMoSpecCorpus? {
        let url = sampleURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadLoCoMoSpecCorpus(from: url)
    }

    // ── Preamble — SAME literal asserted in the Rust twin ─────────────────────
    //
    // §6 of LOCOMO_OFFICIAL_PROTOCOL.md:
    //   "Below is a conversation between two people: {} and {}. The conversation
    //    takes place over multiple days and the date of each conversation is
    //    wriiten at the beginning of the conversation."
    //
    // The typo 'wriiten' (double-i) is in the official prompt and MUST be reproduced
    // verbatim. This is the conformance-critical golden pin for §6.
    //
    // The expected string below is identical to the expected string in
    // locomo_spec_conformance.rs so that any deviation between ports is caught.

    /// §6 preamble with "Alice" and "Bob" — asserts the verbatim official text
    /// including the official typo 'wriiten'.
    @Test("golden pin: loCoMoConversationPreamble produces the verbatim §6 preamble")
    func goldenPinPreambleVerbatim() {
        // §6 literal — DO NOT fix the 'wriiten' typo; it is in the official spec.
        let expected =
            "Below is a conversation between two people: Alice and Bob. " +
            "The conversation takes place over multiple days and the date of each " +
            "conversation is wriiten at the beginning of the conversation."
        let got = loCoMoConversationPreamble(speakerA: "Alice", speakerB: "Bob")
        #expect(got == expected,
                "preamble must match §6 verbatim (including the 'wriiten' typo)")
    }

    /// §6 session header format: "DATE: [timestamp] CONVERSATION:"
    @Test("golden pin: loCoMoSessionHeader matches §6 format exactly")
    func goldenPinSessionHeader() {
        let got = loCoMoSessionHeader(dateTime: "1:56 pm on 8 May, 2023")
        #expect(got == "DATE: 1:56 pm on 8 May, 2023 CONVERSATION:")
    }

    /// §6 turn without image: '[speaker] said, "[text]"'.
    @Test("golden pin: loCoMoFormatTurn — no caption")
    func goldenPinFormatTurnNoCaption() {
        let turn = LoCoMoSpecTurn(
            speaker: "Alice", diaID: "D1:1",
            text: "Hey Bob! I visited the art museum today.",
            imageCaption: nil
        )
        let expected = "Alice said, \"Hey Bob! I visited the art museum today.\""
        #expect(loCoMoFormatTurn(turn) == expected)
    }

    /// §6 turn with image: '[speaker] said, "[text]" and shared [caption]'.
    /// This is the cross-port golden pin for the image-caption branch.
    @Test("golden pin: loCoMoFormatTurn — with caption appends ' and shared [caption]'")
    func goldenPinFormatTurnWithCaption() {
        let turn = LoCoMoSpecTurn(
            speaker: "Bob", diaID: "D1:2",
            text: "That sounds wonderful! Which exhibit?",
            imageCaption: "a painting of a sunset over the ocean"
        )
        // §6 literal — same string asserted in the Rust twin.
        let expected =
            "Bob said, \"That sounds wonderful! Which exhibit?\" " +
            "and shared a painting of a sunset over the ocean"
        #expect(loCoMoFormatTurn(turn) == expected)
    }

    /// loCoMoFormatContext on the sample fixture: verify the full rendered context
    /// contains the §6 preamble, both session headers, the image-caption turn, and
    /// ends with a trailing newline.
    @Test("loCoMoFormatContext renders sample conversation with correct §6 structure")
    func formatContextStructure() throws {
        guard let corpus = try loadSample() else { return }
        let conv = corpus.conversations[0]
        let ctx = loCoMoFormatContext(conv)

        // Preamble (with official typo).
        #expect(ctx.hasPrefix("Below is a conversation between two people: Alice and Bob."))
        #expect(ctx.contains("wriiten"), "context must contain the official 'wriiten' typo")

        // Session headers.
        #expect(ctx.contains("DATE: 3:00 pm on 1 Jan, 2024 CONVERSATION:"),
                "session-1 header must appear")
        #expect(ctx.contains("DATE: 2:00 pm on 10 Jan, 2024 CONVERSATION:"),
                "session-2 header must appear")

        // Non-image turn.
        #expect(ctx.contains("Alice said, \"Hey Bob! I visited the art museum today.\""),
                "non-image turn must use the §6 format without caption")

        // Image-caption turn — the cross-port golden pin.
        #expect(
            ctx.contains(
                "Bob said, \"That sounds wonderful! Which exhibit?\" " +
                "and shared a painting of a sunset over the ocean"),
            "image turn must append ' and shared [caption]' per §6"
        )

        // Trailing newline.
        #expect(ctx.hasSuffix("\n"), "formatted context must end with a trailing newline")

        // Chronological session order: session-1 header appears before session-2 header.
        let s1Pos = ctx.range(of: "DATE: 3:00 pm on 1 Jan, 2024")!.lowerBound
        let s2Pos = ctx.range(of: "DATE: 2:00 pm on 10 Jan, 2024")!.lowerBound
        #expect(s1Pos < s2Pos, "session-1 must appear before session-2 (chronological order)")
    }
}
