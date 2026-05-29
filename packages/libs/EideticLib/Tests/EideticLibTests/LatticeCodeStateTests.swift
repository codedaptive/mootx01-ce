// LatticeCodeStateTests.swift
//
// Verifies Part 2 of LAUNCH-03B: valid-but-unknown MDCC codes are
// accepted, classified as pending, and round-trip intact.

import XCTest
@testable import EideticLib

final class LatticeCodeStateTests: XCTestCase {

    func testGrammarAcceptsThreeDigitCode() {
        XCTAssertTrue(LatticeCodeGrammar.isWellFormed("540"))
    }

    func testGrammarAcceptsExtension() {
        XCTAssertTrue(LatticeCodeGrammar.isWellFormed("540.137"))
        XCTAssertTrue(LatticeCodeGrammar.isWellFormed("000.00000000"))
    }

    func testGrammarRejectsShortIntegerPart() {
        XCTAssertFalse(LatticeCodeGrammar.isWellFormed("54"))
    }

    func testGrammarRejectsLongIntegerPart() {
        XCTAssertFalse(LatticeCodeGrammar.isWellFormed("5400"))
    }

    func testGrammarRejectsTrailingDot() {
        XCTAssertFalse(LatticeCodeGrammar.isWellFormed("540."))
    }

    func testGrammarRejectsOverlongExtension() {
        XCTAssertFalse(LatticeCodeGrammar.isWellFormed("540.123456789"))
    }

    func testGrammarRejectsNonDigit() {
        XCTAssertFalse(LatticeCodeGrammar.isWellFormed("54a"))
        XCTAssertFalse(LatticeCodeGrammar.isWellFormed("540.1a"))
    }

    func testClassifyKnownCode() {
        let state = EideticLib.classifyLatticeCode(
            "540",
            knownCodes: ["540"]
        )
        XCTAssertEqual(state, .known("540"))
        XCTAssertTrue(state.isWellFormed)
    }

    func testClassifyPendingCode() {
        // Well-formed but not in the bound canon — the
        // valid-but-unknown state.
        let state = EideticLib.classifyLatticeCode(
            "999.42",
            knownCodes: ["540", "541"]
        )
        XCTAssertEqual(state, .pending("999.42"))
        XCTAssertTrue(state.isWellFormed)
    }

    func testClassifyMalformedCode() {
        let state = EideticLib.classifyLatticeCode("bogus")
        XCTAssertEqual(state, .malformed("bogus"))
        XCTAssertFalse(state.isWellFormed)
    }

    func testPendingCodeRoundTripsThroughJSON() throws {
        // The core invariant from the launch plan: a pending
        // code round-trips intact through storage.
        let original = LatticeCodeState.pending("999.42")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LatticeCodeState.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.rawCode, "999.42")
    }

    func testKnownCodeRoundTripsThroughJSON() throws {
        let original = LatticeCodeState.known("540.137")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LatticeCodeState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRawCodeExposesInputForEveryState() {
        XCTAssertEqual(LatticeCodeState.known("540").rawCode, "540")
        XCTAssertEqual(LatticeCodeState.pending("999.9").rawCode, "999.9")
        XCTAssertEqual(LatticeCodeState.malformed("xyz").rawCode, "xyz")
    }
}
