// SegmenterTests.swift
//
// Tests for `EideticLib.sentences(_:)` and
// `EideticLib.sentencesByDelimiter(_:)`. Mirror the apple-nlp-accel
// pattern's two-path contract (cookbook §2.2): the delimiter
// reference is cross-platform identical; the platform-routed entry
// agrees with the reference on inputs that don't exercise language-
// specific edge cases.

import Testing
@testable import EideticLib

@Suite("Segmenter")
struct SegmenterTests {

    // MARK: - Empty / single-sentence

    @Test("empty input returns empty")
    func emptyInputReturnsEmpty() {
        #expect(EideticLib.sentences("").isEmpty)
        #expect(EideticLib.sentencesByDelimiter("").isEmpty)
    }

    @Test("single sentence, no terminator, returns full input")
    func singleSentenceNoTerminatorReturnsFullInput() {
        let text = "this is one fragment with no terminator"
        let segs = EideticLib.sentencesByDelimiter(text)
        #expect(segs.count == 1)
        #expect(String(segs[0]) == text)
    }

    // MARK: - Delimiter reference

    @Test("delimiter splits on period, exclaim, question")
    func delimiterSplitsOnPeriodExclaimQuestion() {
        let text = "First. Second! Third? Fourth"
        let segs = EideticLib.sentencesByDelimiter(text)
        #expect(segs.count == 4)
        #expect(String(segs[0]) == "First.")
        #expect(String(segs[1]) == " Second!")
        #expect(String(segs[2]) == " Third?")
        #expect(String(segs[3]) == " Fourth")
    }

    @Test("delimiter splits on newline")
    func delimiterSplitsOnNewline() {
        let text = "Line one\nLine two\nLine three"
        let segs = EideticLib.sentencesByDelimiter(text)
        #expect(segs.count == 3)
        // The newline is preserved at the end of each split segment.
        #expect(String(segs[0]).hasSuffix("\n"))
        #expect(String(segs[1]).hasSuffix("\n"))
        #expect(!String(segs[2]).hasSuffix("\n"))
    }

    @Test("delimiter total coverage")
    func delimiterTotalCoverage() {
        // Segments must concatenate back to the original input
        // exactly: no bytes added, none dropped, none reordered.
        let text = "Alpha. Beta! Gamma? Delta\nEpsilon"
        let segs = EideticLib.sentencesByDelimiter(text)
        let rejoined = segs.map(String.init).joined()
        #expect(rejoined == text)
    }

    // MARK: - Platform-routed entry agreement

    @Test("routed and reference agree on simple input")
    func routedAndReferenceAgreeOnSimpleInput() {
        // Input free of language-specific edge cases (no abbreviations,
        // no quotation tricks). Both paths must produce the same
        // number of segments and the same concatenation. Apple's
        // NLTokenizer may differ in whitespace ownership of segment
        // boundaries, so we compare round-trip equality and
        // segment counts rather than byte equality of each segment.
        let text = "One sentence. Two sentences. Three sentences."
        let routed = EideticLib.sentences(text)
        let reference = EideticLib.sentencesByDelimiter(text)
        #expect(routed.count == reference.count,
                "platform-routed and reference must agree on segment count for unambiguous input")
        #expect(routed.map(String.init).joined() == reference.map(String.init).joined(),
                "both paths must concatenate to the same total coverage")
    }

    @Test("routed round-trips to input")
    func routedRoundTripsToInput() {
        // The routed entry, like the reference, must produce
        // segments that concatenate back to the original input.
        let text = "Round trip. Round trip. Round trip."
        let segs = EideticLib.sentences(text)
        #expect(segs.map(String.init).joined() == text)
    }

    // MARK: - Pathological inputs

    @Test("input with only terminators produces empty but covering segments")
    func inputWithOnlyTerminatorsProducesEmptyButCoveringSegments() {
        let text = "..."
        let segs = EideticLib.sentencesByDelimiter(text)
        #expect(segs.count == 3)
        for s in segs { #expect(String(s) == ".") }
        #expect(segs.map(String.init).joined() == text)
    }

    @Test("input without terminator yields single segment")
    func inputWithoutTerminatorYieldsSingleSegment() {
        let text = "no terminators here"
        let routed = EideticLib.sentences(text)
        #expect(routed.count == 1)
        #expect(String(routed[0]) == text)
    }
}
