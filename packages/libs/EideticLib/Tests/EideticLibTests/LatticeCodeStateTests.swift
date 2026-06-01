// LatticeCodeStateTests.swift
//
// Verifies Part 2 of LAUNCH-03B: valid-but-unknown MDCC codes are
// accepted, classified as pending, and round-trip intact.

import Testing
import Foundation
@testable import EideticLib

@Suite("Lattice code state")
struct LatticeCodeStateTests {

    @Test("grammar accepts three-digit code")
    func grammarAcceptsThreeDigitCode() {
        #expect(LatticeCodeGrammar.isWellFormed("540"))
    }

    @Test("grammar accepts extension")
    func grammarAcceptsExtension() {
        #expect(LatticeCodeGrammar.isWellFormed("540.137"))
        #expect(LatticeCodeGrammar.isWellFormed("000.00000000"))
    }

    @Test("grammar rejects short integer part")
    func grammarRejectsShortIntegerPart() {
        #expect(!LatticeCodeGrammar.isWellFormed("54"))
    }

    @Test("grammar rejects long integer part")
    func grammarRejectsLongIntegerPart() {
        #expect(!LatticeCodeGrammar.isWellFormed("5400"))
    }

    @Test("grammar rejects trailing dot")
    func grammarRejectsTrailingDot() {
        #expect(!LatticeCodeGrammar.isWellFormed("540."))
    }

    @Test("grammar rejects overlong extension")
    func grammarRejectsOverlongExtension() {
        #expect(!LatticeCodeGrammar.isWellFormed("540.123456789"))
    }

    @Test("grammar rejects non-digit")
    func grammarRejectsNonDigit() {
        #expect(!LatticeCodeGrammar.isWellFormed("54a"))
        #expect(!LatticeCodeGrammar.isWellFormed("540.1a"))
    }

    @Test("classify known code")
    func classifyKnownCode() {
        let state = EideticLib.classifyLatticeCode(
            "540",
            knownCodes: ["540"]
        )
        #expect(state == .known("540"))
        #expect(state.isWellFormed)
    }

    @Test("classify pending code")
    func classifyPendingCode() {
        // Well-formed but not in the bound canon — the
        // valid-but-unknown state.
        let state = EideticLib.classifyLatticeCode(
            "999.42",
            knownCodes: ["540", "541"]
        )
        #expect(state == .pending("999.42"))
        #expect(state.isWellFormed)
    }

    @Test("classify malformed code")
    func classifyMalformedCode() {
        let state = EideticLib.classifyLatticeCode("bogus")
        #expect(state == .malformed("bogus"))
        #expect(!state.isWellFormed)
    }

    @Test("pending code round-trips through JSON")
    func pendingCodeRoundTripsThroughJSON() throws {
        // The core invariant from the launch plan: a pending
        // code round-trips intact through storage.
        let original = LatticeCodeState.pending("999.42")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LatticeCodeState.self, from: data)
        #expect(decoded == original)
        #expect(decoded.rawCode == "999.42")
    }

    @Test("known code round-trips through JSON")
    func knownCodeRoundTripsThroughJSON() throws {
        let original = LatticeCodeState.known("540.137")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LatticeCodeState.self, from: data)
        #expect(decoded == original)
    }

    @Test("rawCode exposes input for every state")
    func rawCodeExposesInputForEveryState() {
        #expect(LatticeCodeState.known("540").rawCode == "540")
        #expect(LatticeCodeState.pending("999.9").rawCode == "999.9")
        #expect(LatticeCodeState.malformed("xyz").rawCode == "xyz")
    }
}
