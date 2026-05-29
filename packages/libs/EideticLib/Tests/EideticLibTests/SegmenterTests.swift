// SegmenterTests.swift
//
// Tests for `EideticLib.sentences(_:)` and
// `EideticLib.sentencesByDelimiter(_:)`. Mirror the apple-nlp-accel
// pattern's two-path contract (cookbook §2.2): the delimiter
// reference is cross-platform identical; the platform-routed entry
// agrees with the reference on inputs that don't exercise language-
// specific edge cases.

import XCTest
@testable import EideticLib

final class SegmenterTests: XCTestCase {

    // MARK: - Empty / single-sentence

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(EideticLib.sentences("").isEmpty)
        XCTAssertTrue(EideticLib.sentencesByDelimiter("").isEmpty)
    }

    func testSingleSentenceNoTerminatorReturnsFullInput() {
        let text = "this is one fragment with no terminator"
        let segs = EideticLib.sentencesByDelimiter(text)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(String(segs[0]), text)
    }

    // MARK: - Delimiter reference

    func testDelimiterSplitsOnPeriodExclaimQuestion() {
        let text = "First. Second! Third? Fourth"
        let segs = EideticLib.sentencesByDelimiter(text)
        XCTAssertEqual(segs.count, 4)
        XCTAssertEqual(String(segs[0]), "First.")
        XCTAssertEqual(String(segs[1]), " Second!")
        XCTAssertEqual(String(segs[2]), " Third?")
        XCTAssertEqual(String(segs[3]), " Fourth")
    }

    func testDelimiterSplitsOnNewline() {
        let text = "Line one\nLine two\nLine three"
        let segs = EideticLib.sentencesByDelimiter(text)
        XCTAssertEqual(segs.count, 3)
        // The newline is preserved at the end of each split segment.
        XCTAssertTrue(String(segs[0]).hasSuffix("\n"))
        XCTAssertTrue(String(segs[1]).hasSuffix("\n"))
        XCTAssertFalse(String(segs[2]).hasSuffix("\n"))
    }

    func testDelimiterTotalCoverage() {
        // Segments must concatenate back to the original input
        // exactly: no bytes added, none dropped, none reordered.
        let text = "Alpha. Beta! Gamma? Delta\nEpsilon"
        let segs = EideticLib.sentencesByDelimiter(text)
        let rejoined = segs.map(String.init).joined()
        XCTAssertEqual(rejoined, text)
    }

    // MARK: - Platform-routed entry agreement

    func testRoutedAndReferenceAgreeOnSimpleInput() {
        // Input free of language-specific edge cases (no abbreviations,
        // no quotation tricks). Both paths must produce the same
        // number of segments and the same concatenation. Apple's
        // NLTokenizer may differ in whitespace ownership of segment
        // boundaries, so we compare round-trip equality and
        // segment counts rather than byte equality of each segment.
        let text = "One sentence. Two sentences. Three sentences."
        let routed = EideticLib.sentences(text)
        let reference = EideticLib.sentencesByDelimiter(text)
        XCTAssertEqual(routed.count, reference.count,
                       "platform-routed and reference must agree on segment count for unambiguous input")
        XCTAssertEqual(routed.map(String.init).joined(),
                       reference.map(String.init).joined(),
                       "both paths must concatenate to the same total coverage")
    }

    func testRoutedRoundTripsToInput() {
        // The routed entry, like the reference, must produce
        // segments that concatenate back to the original input.
        let text = "Round trip. Round trip. Round trip."
        let segs = EideticLib.sentences(text)
        XCTAssertEqual(segs.map(String.init).joined(), text)
    }

    // MARK: - Pathological inputs

    func testInputWithOnlyTerminatorsProducesEmptyButCoveringSegments() {
        let text = "..."
        let segs = EideticLib.sentencesByDelimiter(text)
        XCTAssertEqual(segs.count, 3)
        for s in segs { XCTAssertEqual(String(s), ".") }
        XCTAssertEqual(segs.map(String.init).joined(), text)
    }

    func testInputWithoutTerminatorYieldsSingleSegment() {
        let text = "no terminators here"
        let routed = EideticLib.sentences(text)
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(String(routed[0]), text)
    }
}
