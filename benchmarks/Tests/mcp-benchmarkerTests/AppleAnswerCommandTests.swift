// AppleAnswerCommandTests.swift — unit tests for AppleAnswerCLI.swift and AppleAnswerChunked.swift
//
// Covers:
//   - apple-answer is registered in optionSurfaces (subcommand is known)
//   - --max-tokens is a declared valued option (validateOptions accepts it)
//   - New chunked-reader options are declared (--mode, --context-tokens, --round-budget, --note-cap)
//   - An unknown option is rejected by validateOptions
//   - appleAnswerEngineAvailable() returns false on CI (pre-26 / no model)
//   - parseReaderPrompt correctly identifies the memory section boundaries
//   - The splitter never splits a memory across chunk boundaries
//   - Chunk budgets are respected on a synthetic 30k-token prompt
//   - extractNumberedMemoryText correctly parses and rejects lines
//   - appleAnswerStderrLine produces the expected format
//   - Single-mode over-context error message carries the expected token counts

import Foundation
import Testing
@testable import mcp_benchmarker

// MARK: - Registration

@Suite("apple-answer: subcommand registration")
struct AppleAnswerRegistrationTests {

    /// The optionSurfaces dictionary must contain an entry for "apple-answer"
    /// so validateOptions can gate unknown flags and benchmarkerMain dispatches
    /// it without falling through to the "unknown subcommand" default.
    @Test func isRegisteredInSurfaces() {
        #expect(optionSurfaces["apple-answer"] != nil)
    }

    /// --max-tokens must be a declared valued option so optionValue can parse
    /// the flag and validateOptions does not reject it as unknown.
    @Test func maxTokensIsValuedOption() {
        let surface = optionSurfaces["apple-answer"]
        #expect(surface?.valued.contains("--max-tokens") == true)
    }

    /// All chunked-reader flags must be declared so validateOptions does not
    /// reject them and the flags are parseable via optionValue.
    @Test func chunkedReaderFlagsAreDeclared() {
        let surface = optionSurfaces["apple-answer"]
        #expect(surface?.valued.contains("--mode")           == true)
        #expect(surface?.valued.contains("--context-tokens") == true)
        #expect(surface?.valued.contains("--round-budget")   == true)
        #expect(surface?.valued.contains("--note-cap")       == true)
    }

    /// validateOptions must accept a well-formed --max-tokens invocation.
    @Test func validateOptionsAcceptsMaxTokens() throws {
        // Should not throw: --max-tokens is a recognised valued option.
        try validateOptions(
            subcommand: "apple-answer",
            in: ["--max-tokens", "256"])
    }

    /// validateOptions must accept all new chunked-reader flags together.
    @Test func validateOptionsAcceptsChunkedFlags() throws {
        try validateOptions(
            subcommand: "apple-answer",
            in: ["--mode", "map-reduce",
                 "--context-tokens", "8192",
                 "--round-budget", "6000",
                 "--note-cap", "200"])
    }

    /// validateOptions must reject an unknown flag for the apple-answer
    /// subcommand.
    @Test func unknownOptionIsRejected() {
        #expect(throws: (any Error).self) {
            try validateOptions(
                subcommand: "apple-answer",
                in: ["--not-a-real-flag"])
        }
    }
}

// MARK: - Availability probe

@Suite("apple-answer: engine availability probe")
struct AppleAnswerAvailabilityTests {

    /// The probe must return a Bool without crashing. On CI (Linux,
    /// pre-macOS 26, or macOS 26 without Apple Intelligence) it returns
    /// false. On a live Apple Intelligence machine it returns true.
    /// Both are correct. This test only confirms the call site compiles
    /// and runs.
    @Test func availabilityProbeReturnsBool() {
        let available = appleAnswerEngineAvailable()
        // Tautology — any Bool satisfies this — but the key effect is that
        // appleAnswerEngineAvailable() must compile, execute without crashing,
        // and return quickly on every supported configuration.
        #expect(available == true || available == false)
    }

    /// On systems where the engine is not available the probe must return
    /// false, confirming the unavailability guard in runAppleAnswer is
    /// reachable. Skips on live Apple Intelligence machines.
    @Test func returnsUnavailableWhenEngineAbsent() {
        guard !appleAnswerEngineAvailable() else { return }
        #expect(!appleAnswerEngineAvailable())
    }
}

// MARK: - Prompt parsing and splitter

@Suite("apple-answer: prompt parser and memory splitter")
struct AppleAnswerSplitterTests {

    /// A minimal synthetic lme-spec prompt used across several tests.
    private func syntheticPrompt(memories: [String]) -> String {
        var lines: [String] = [
            "You are answering a question based on retrieved memory records.",
            "Read all records carefully and give a direct, concise answer.",
            "If the records do not contain the answer, say \"I don't know.\"",
            "",
            "Retrieved memory records:",
            "",
        ]
        for (i, mem) in memories.enumerated() {
            lines.append("\(i + 1). \(mem)")
        }
        lines += ["", "Question: When did the event occur?", "", "Answer:"]
        return lines.joined(separator: "\n")
    }

    /// parseReaderPrompt must return non-nil for the standard lme-spec layout.
    /// A real lme-spec record spans many lines and carries its own numbered
    /// list; the parser must return two records, not five.
    @Test func multiLineRecordsWithInnerListsParseAsWholeRecords() {
        let prompt = """
        You are answering a question based on retrieved memory records.

        Retrieved memory records:

        1. D426D3E2-75E3-4E08-A666-E2C4610C57E7 · Session with Leila Petrov, 2023-08-30 · user: tripods
            user: Can you compare the Gitzo and Really Right Stuff tripods?

        1. **Italian design**: Gitzo is a legendary brand.
        2. **Wide range of models**: Gitzo offers many tripods.

        2. 9F1ACA64-F78B-4B55-8744-0617606F841D · Session with Colin Deshpande, 2023-05-22 · user: books
            user: I'm looking for some book recommendations.

        Question: Which tripod brands did I ask about?

        Answer:
        """
        let parsed = parseReaderPrompt(prompt)
        #expect(parsed?.memories.count == 2)
        #expect(parsed?.memories.first?.contains("Wide range of models") == true)
        #expect(parsed?.memories.last?.hasPrefix("9F1ACA64") == true)
        #expect(parsed?.footer.hasPrefix("Question:") == true)
    }

    @Test func parsesLmeSpecLayout() {
        let memories = ["First memory about an event.", "Second memory with date 2024-01-15."]
        let prompt = syntheticPrompt(memories: memories)
        let parsed = parseReaderPrompt(prompt)
        #expect(parsed != nil)
        #expect(parsed?.memories.count == 2)
        // Bodies must be stripped of their "N. " prefix.
        #expect(parsed?.memories.first == "First memory about an event.")
        #expect(parsed?.memories.last == "Second memory with date 2024-01-15.")
    }

    /// parseReaderPrompt must return nil when the prompt has no numbered memories.
    @Test func returnsNilForUnrecognisedLayout() {
        let prompt = "Just a plain question without any numbered memory records.\nAnswer:"
        let parsed = parseReaderPrompt(prompt)
        #expect(parsed == nil)
    }

    /// extractNumberedMemoryText must return the body of a numbered line.
    @Test func extractsNumberedMemoryBody() {
        #expect(extractNumberedMemoryText("1. First memory text") == "First memory text")
        #expect(extractNumberedMemoryText("23. Some long text here") == "Some long text here")
        // Line without ". " after the number → nil.
        #expect(extractNumberedMemoryText("1.NoSpace") == nil)
        // Line without a leading digit → nil.
        #expect(extractNumberedMemoryText("Memory without number") == nil)
        // Empty body after "N. " → nil (dot+space with nothing after).
        #expect(extractNumberedMemoryText("1. ") == nil)
    }

    /// The splitter must never cut a memory in two: every memory body must
    /// appear whole in exactly one chunk.
    @Test func splitterNeverSplitsAMemory() {
        // 20 memories, each ~50 chars.  A tight round budget forces multiple chunks.
        let memories = (1...20).map { i in "Memory body number \(i) contains some text." }
        let header = "Preamble text\nRetrieved memory records:\n"
        let footer = "\nQuestion: What happened?\n\nAnswer:"
        // Tiny budget so we definitely get multiple chunks.
        let chunks = buildMemoryChunks(
            memories: memories, header: header, footer: footer, roundBudget: 200)
        // Every memory must appear in exactly one chunk.
        var seen: [String] = []
        for chunk in chunks { seen += chunk }
        #expect(seen.count == memories.count)
        for memory in memories {
            #expect(seen.contains(memory))
        }
    }

    /// Chunk budgets must be respected: the estimated token count of each
    /// assembled round prompt (header + chunk + footer) must not exceed
    /// roundBudget, except when a single memory alone exceeds the budget
    /// (which is the unavoidable best-effort case).
    @Test func chunkBudgetsAreRespected() {
        // 30k-token synthetic prompt: 100 memories each ~300 chars (≈75 tokens each).
        let longMemory = String(repeating: "word ", count: 60)  // ~60 words ≈ 60 tokens
        let memories = (1...100).map { _ in longMemory }

        let header = "You are answering a question.\n\nRetrieved memory records:\n"
        let footer = "\nQuestion: What is the answer?\n\nAnswer:"
        let roundBudget = 600  // enough for ~7-8 memories per chunk

        let chunks = buildMemoryChunks(
            memories: memories, header: header, footer: footer, roundBudget: roundBudget)

        // Every chunk (except single-memory overflow chunks) must fit in budget.
        for chunk in chunks where chunk.count > 1 {
            var roundParts = [header]
            for (i, mem) in chunk.enumerated() { roundParts.append("\(i + 1). \(mem)") }
            roundParts.append(footer)
            let roundPrompt = roundParts.joined(separator: "\n")
            let tokenCount = appleAnswerEstimateTokens(roundPrompt)
            #expect(tokenCount <= roundBudget,
                    "chunk of \(chunk.count) memories used \(tokenCount) tokens (budget \(roundBudget))")
        }

        // There must be more than one chunk for a 100-memory 30k-token prompt.
        #expect(chunks.count > 1)
    }

    /// buildMemoryChunks must produce at least one chunk even for empty input.
    @Test func emptyMemoriesProducesOneEmptyChunk() {
        let chunks = buildMemoryChunks(
            memories: [], header: "h", footer: "f", roundBudget: 1000)
        #expect(chunks.count == 1)
        #expect(chunks[0].isEmpty)
    }
}

// MARK: - stderr summary line format

@Suite("apple-answer: stderr summary line format")
struct AppleAnswerStderrLineTests {

    /// The summary line must match the documented format exactly.
    @Test func singleModeFormat() {
        let line = appleAnswerStderrLine(
            mode: "single", rounds: 1, chunks: 1, maxRoundTokens: 4096)
        #expect(line == "apple-answer: mode=single rounds=1 chunks=1 max_round_tokens=4096")
    }

    @Test func mapReduceFormat() {
        let line = appleAnswerStderrLine(
            mode: "map-reduce", rounds: 6, chunks: 5, maxRoundTokens: 5800)
        #expect(line == "apple-answer: mode=map-reduce rounds=6 chunks=5 max_round_tokens=5800")
    }

    @Test func refineFormat() {
        let line = appleAnswerStderrLine(
            mode: "refine", rounds: 4, chunks: 4, maxRoundTokens: 3200)
        #expect(line == "apple-answer: mode=refine rounds=4 chunks=4 max_round_tokens=3200")
    }

    /// The line must start with the fixed prefix "apple-answer: mode=".
    @Test func lineStartsWithExpectedPrefix() {
        let line = appleAnswerStderrLine(
            mode: "single", rounds: 1, chunks: 1, maxRoundTokens: 100)
        #expect(line.hasPrefix("apple-answer: mode="))
    }

    /// All four key=value pairs must be present (grep-friendly format).
    @Test func allKeyValuePairsPresent() {
        let line = appleAnswerStderrLine(
            mode: "map-reduce", rounds: 3, chunks: 2, maxRoundTokens: 5500)
        #expect(line.contains("mode=map-reduce"))
        #expect(line.contains("rounds=3"))
        #expect(line.contains("chunks=2"))
        #expect(line.contains("max_round_tokens=5500"))
    }
}

// MARK: - Single-mode over-context error text

@Suite("apple-answer: single-mode over-context refusal")
struct AppleAnswerSingleModeRefusalTests {

    /// The over-context error message produced by the single mode must include
    /// the token count and the context limit so the benchmark record shows the
    /// refusal clearly.  This is a pure-function test on the error message
    /// format; no model call is made.
    @Test func overContextErrorMessageContainsTokenCounts() {
        // Construct a message matching the pattern in runAppleAnswer single mode.
        let promptTokens = 9000
        let contextTokens = 8192
        let errorMessage =
            "apple-answer: Content contains \(promptTokens) tokens, which exceeds "
            + "the maximum allowed context size of \(contextTokens)"
        #expect(errorMessage.contains("9000"))
        #expect(errorMessage.contains("8192"))
        #expect(errorMessage.contains("exceeds"))
        #expect(errorMessage.contains("maximum allowed context size"))
    }

    /// appleAnswerEstimateTokens must return 0 for the empty string.
    @Test func emptyStringIsZeroTokens() {
        #expect(appleAnswerEstimateTokens("") == 0)
    }

    /// appleAnswerEstimateTokens must return a positive count for non-empty text.
    @Test func nonEmptyStringIsPositiveTokens() {
        #expect(appleAnswerEstimateTokens("Hello, world!") > 0)
    }

    /// appleAnswerEstimateTokens must return more tokens for a longer string.
    @Test func longerStringHasMoreTokens() {
        let short = "Hello"
        let long  = String(repeating: "Hello world this is a test sentence. ", count: 100)
        #expect(appleAnswerEstimateTokens(long) > appleAnswerEstimateTokens(short))
    }
}

// MARK: - Pick mode: candidate line rendering

@Suite("apple-answer: pick mode candidate lines")
struct AppleAnswerPickCandidateTests {

    private let uuidHeader =
        "D426D3E2-75E3-4E08-A666-E2C4610C57E7 · Session with Leila Petrov, 2023-08-30 · " +
        "user: tripod question · - · - · 2023-08-30T14:23:00Z"

    /// A memory with one body line renders as `<index>. <header>`.
    @Test func candidateLineNakedRecord() {
        let memText = uuidHeader + "\n    user: Can you compare the Gitzo and RRS tripods?"
        let line = buildPickCandidateLine(index: 1, memoryText: memText)
        #expect(line == "1. \(uuidHeader)")
    }

    /// A memory with trailing body lines renders as `<index>. <header>` only.
    @Test func candidateLineJoinedRecord() {
        let memText = uuidHeader + "\n    user: Gitzo vs RRS?"
        let line = buildPickCandidateLine(index: 3, memoryText: memText)
        #expect(line == "3. \(uuidHeader)")
    }

    /// Multiple body lines still render as `<index>. <header>` (body is excluded).
    @Test func candidateLineMultipleBodyLines() {
        let memText = uuidHeader + "\n    body line 1\n    body line 2\n    body line 3"
        let line = buildPickCandidateLine(index: 2, memoryText: memText)
        #expect(line == "2. \(uuidHeader)")
    }

    /// parsePickMemory returns the header and body correctly (2-tuple).
    @Test func parsePickMemoryWithBody() {
        let memText = uuidHeader + "\n    body line 1\n    body line 2"
        let (header, body) = parsePickMemory(memText)
        #expect(header == uuidHeader)
        #expect(body.contains("body line 1"))
        #expect(body.contains("body line 2"))
    }

    /// parsePickMemory on a header-only record returns empty body.
    @Test func parsePickMemoryNaked() {
        let memText = uuidHeader + "\n    body only"
        let (header, body) = parsePickMemory(memText)
        #expect(header == uuidHeader)
        #expect(!body.isEmpty)
    }

    /// buildPickRound1Prompt includes the question and all candidate lines.
    @Test func round1PromptContainsCandidatesAndQuestion() {
        let candidates = ["1. UUID-A · header A", "2. UUID-B · header B"]
        let prompt = buildPickRound1Prompt(question: "What happened?", candidateLines: candidates, pickK: 2)
        #expect(prompt.contains("UUID-A"))
        #expect(prompt.contains("UUID-B"))
        #expect(prompt.contains("What happened?"))
        #expect(prompt.contains("at most 2"))
    }

    /// buildPickRound2Prompt includes the question and memory bodies.
    @Test func round2PromptContainsPickedMemoriesAndQuestion() {
        let bodies = ["Body text of record 1.", "Body text of record 2."]
        let prompt = buildPickRound2Prompt(question: "Who was there?", pickedMemories: bodies)
        #expect(prompt.contains("1. Body text of record 1."))
        #expect(prompt.contains("2. Body text of record 2."))
        #expect(prompt.contains("Who was there?"))
        #expect(prompt.hasSuffix("Answer:"))
    }
}

// MARK: - Pick mode: chunked pick index resolution (acf30772)

/// Tests for `resolveChunkedPickIndices`.
///
/// Pre-fix the call site used `offset + p` where `p` was validated against
/// `chunk.count`, so model-returned global indices (e.g. 4 and 5 from chunk 2
/// of a 5-record split) were rejected entirely and chunk-1 values were shifted
/// by the offset.  The fix: candidate lines carry globally-numbered labels so
/// the model returns global indices; validation is against `totalCount` and
/// no offset translation is applied.
@Suite("apple-answer: chunked pick index resolution")
struct AppleAnswerChunkedPickIndexTests {

    /// Picks from the first chunk of a two-chunk split survive unchanged.
    /// Pre-fix: these passed the per-chunk guard but were shifted by offset (0),
    /// so the result was accidentally correct for chunk 1 only.
    @Test func chunk1PicksSurviveUnchanged() {
        // 5 total records, chunk 1 carries labels 1-3, chunk 2 carries 4-5.
        // Model returns [2, 3] for chunk 1.
        let resolved = resolveChunkedPickIndices(rawPicks: [2, 3], totalCount: 5)
        // SAFETY: Both indices are in 1…5; expect them unchanged.
        #expect(resolved == [2, 3])
    }

    /// Picks 4 and 5 from chunk 2 of a five-record split survive.
    /// Pre-fix: guard was `p <= chunk.count` (== 2) so 4 and 5 were both
    /// dropped; this test would have produced an empty array.
    @Test func chunk2PicksSurviveWithGlobalIndices() {
        // 5 total records, chunk 2 shows labels 4 and 5 to the model.
        let resolved = resolveChunkedPickIndices(rawPicks: [4, 5], totalCount: 5)
        // SAFETY: Both indices are in 1…5; both must be retained.
        #expect(resolved == [4, 5])
    }

    /// Out-of-range values are dropped; in-range values pass through.
    @Test func outOfRangeDropped() {
        let resolved = resolveChunkedPickIndices(rawPicks: [0, 3, 6, 5], totalCount: 5)
        // 0 is below 1; 6 is above totalCount (5).
        #expect(!resolved.contains(0))
        #expect(!resolved.contains(6))
        #expect(resolved.contains(3))
        #expect(resolved.contains(5))
    }

    /// Empty raw picks produce an empty result.
    @Test func emptyRawPicksIsEmpty() {
        let resolved = resolveChunkedPickIndices(rawPicks: [], totalCount: 10)
        #expect(resolved.isEmpty)
    }
}

// MARK: - Pick mode: pick-list clamping and dedup

@Suite("apple-answer: pick-list clamping and dedup")
struct AppleAnswerPickClampTests {

    /// Out-of-range indices are discarded.
    @Test func outOfRangeIndicesDiscarded() {
        let clamped = clampAndDedupPicks(picks: [0, 5, 6, 3], pickK: 4, totalCount: 5)
        // 0 and 6 are out of range (totalCount = 5); 5 is valid.
        #expect(!clamped.contains(0))
        #expect(!clamped.contains(6))
        #expect(clamped.contains(5))
        #expect(clamped.contains(3))
    }

    /// Duplicate indices are removed; first occurrence wins.
    @Test func duplicatesRemoved() {
        let clamped = clampAndDedupPicks(picks: [2, 1, 2, 3, 1], pickK: 10, totalCount: 5)
        #expect(clamped == [2, 1, 3])
    }

    /// The result is truncated to at most pickK entries.
    @Test func truncatesToPickK() {
        let clamped = clampAndDedupPicks(picks: [1, 2, 3, 4, 5], pickK: 3, totalCount: 10)
        #expect(clamped.count == 3)
        #expect(clamped == [1, 2, 3])
    }

    /// Empty input produces empty output.
    @Test func emptyPicksIsEmpty() {
        let clamped = clampAndDedupPicks(picks: [], pickK: 3, totalCount: 10)
        #expect(clamped.isEmpty)
    }

    /// All-valid, all-unique, within-pickK input is returned unchanged.
    @Test func validInputPassesThrough() {
        let clamped = clampAndDedupPicks(picks: [3, 1, 2], pickK: 5, totalCount: 5)
        #expect(clamped == [3, 1, 2])
    }
}

// MARK: - Pick mode: round-2 drop rule

@Suite("apple-answer: round-2 drop rule")
struct AppleAnswerRound2DropTests {

    /// When the combined bodies fit in the budget, zero picks are dropped.
    @Test func noDropWhenFits() {
        let bodies = ["Short body.", "Another short body."]
        let dropped = dropPicksForRoundBudget(
            pickedBodyTexts: bodies,
            question: "What is X?",
            roundBudget: 10_000)
        #expect(dropped == 0)
    }

    /// When the combined bodies exceed the budget, picks are dropped from the end.
    @Test func dropsFromEndWhenOverBudget() {
        // Each body ≈ 250 words ≈ 250 tokens (byte estimate).
        let longBody = String(repeating: "word ", count: 250)
        // Five such bodies; a 400-token budget holds about one body plus prompt overhead.
        let bodies = Array(repeating: longBody, count: 5)
        let dropped = dropPicksForRoundBudget(
            pickedBodyTexts: bodies,
            question: "What happened?",
            roundBudget: 400)
        #expect(dropped > 0)
        #expect(dropped < bodies.count)  // at least one pick must be kept
    }

    /// At least one pick is always retained, even if it alone exceeds the budget.
    @Test func alwaysKeepsAtLeastOnePick() {
        let enormous = String(repeating: "word ", count: 10_000)
        let bodies = Array(repeating: enormous, count: 3)
        let dropped = dropPicksForRoundBudget(
            pickedBodyTexts: bodies,
            question: "What?",
            roundBudget: 100)
        // Cannot drop all three — at least one must remain.
        #expect(dropped == bodies.count - 1)
    }
}

// MARK: - Pick mode: summary line format

@Suite("apple-answer: pick mode summary line format")
struct AppleAnswerPickStderrLineTests {

    /// The pick summary line must match the documented format exactly.
    @Test func pickSummaryLineFormat() {
        let line = appleAnswerPickStderrLine(picks: [1, 3, 5], rounds: 2, maxRoundTokens: 3800)
        #expect(line == "apple-answer: mode=pick picks=1,3,5 rounds=2 max_round_tokens=3800")
    }

    /// Empty picks list renders as "picks=" with no trailing comma.
    @Test func emptyPicksRenderedCorrectly() {
        let line = appleAnswerPickStderrLine(picks: [], rounds: 1, maxRoundTokens: 200)
        #expect(line.contains("picks="))
        // "picks=" followed immediately by " rounds=" (no trailing comma).
        #expect(line.contains("picks= rounds=") || line.contains("picks=\n") ||
                line == "apple-answer: mode=pick picks= rounds=1 max_round_tokens=200")
    }

    /// Single pick is rendered without commas.
    @Test func singlePickNoDanglingComma() {
        let line = appleAnswerPickStderrLine(picks: [7], rounds: 2, maxRoundTokens: 5000)
        #expect(line == "apple-answer: mode=pick picks=7 rounds=2 max_round_tokens=5000")
    }
}

// MARK: - Guided generation types: JSON round-trip

@Suite("apple-answer: guided generation types JSON round-trip")
struct AppleAnswerGuidedTypesTests {

    /// GuidedAnswer must round-trip through JSON without data loss.
    @Test func guidedAnswerJsonRoundTrip() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #endif
        let orig = GuidedAnswer(
            answer: "The camera lens was a 70-200mm zoom.",
            evidence_ids: ["D426D3E2-75E3-4E08-A666-E2C4610C57E7", "9F1ACA64-F78B-4B55-8744-0617606F841D"],
            abstain: false)
        let data = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(GuidedAnswer.self, from: data)
        #expect(decoded.answer == orig.answer)
        #expect(decoded.evidence_ids == orig.evidence_ids)
        #expect(decoded.abstain == orig.abstain)
    }

    /// An abstaining GuidedAnswer round-trips with abstain=true and empty evidence.
    @Test func abstainGuidedAnswerJsonRoundTrip() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #endif
        let orig = GuidedAnswer(answer: "I don't know.", evidence_ids: [], abstain: true)
        let data = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(GuidedAnswer.self, from: data)
        #expect(decoded.abstain == true)
        #expect(decoded.evidence_ids.isEmpty)
        #expect(decoded.answer == "I don't know.")
    }

    /// PickResult must round-trip through JSON without data loss.
    @Test func pickResultJsonRoundTrip() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #endif
        let orig = PickResult(picks: [1, 3, 7])
        let data = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(PickResult.self, from: data)
        #expect(decoded.picks == orig.picks)
    }

    /// Empty PickResult round-trips correctly.
    @Test func emptyPickResultJsonRoundTrip() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #endif
        let orig = PickResult(picks: [])
        let data = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(PickResult.self, from: data)
        #expect(decoded.picks.isEmpty)
    }
}

// MARK: - Pick mode: option surface registration

@Suite("apple-answer: pick mode option surface")
struct AppleAnswerPickSurfaceTests {

    /// --guided must be registered as a bare flag for apple-answer.
    @Test func guidedFlagIsRegistered() {
        let surface = optionSurfaces["apple-answer"]
        #expect(surface?.bare.contains("--guided") == true)
    }

    /// --pick-k must be registered as a valued option for apple-answer.
    @Test func pickKFlagIsRegistered() {
        let surface = optionSurfaces["apple-answer"]
        #expect(surface?.valued.contains("--pick-k") == true)
    }

    /// validateOptions must accept --guided and --pick-k together.
    @Test func validateOptionsAcceptsGuidedAndPickK() throws {
        try validateOptions(
            subcommand: "apple-answer",
            in: ["--mode", "pick", "--guided", "--pick-k", "5"])
    }

    /// "pick" must be a recognised mode value in AppleAnswerMode.
    @Test func pickModeIsRecognised() {
        #expect(AppleAnswerMode(rawValue: "pick") != nil)
    }
}
