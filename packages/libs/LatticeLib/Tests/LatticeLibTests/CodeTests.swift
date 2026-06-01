// CodeTests.swift
//
// Grammar checks for MDCC codes. Validity is independent of canon
// presence: a code may be well-formed but valid-but-unknown.

import Testing
@testable import LatticeLib

@Suite("Code grammar")
struct CodeTests {

    @Test("three-digit integer is well-formed")
    func threeDigit() {
        #expect(Code.isWellFormed("000"))
        #expect(Code.isWellFormed("540"))
        #expect(Code.isWellFormed("999"))
    }

    @Test("integer plus decimal extension is well-formed")
    func withExtension() {
        #expect(Code.isWellFormed("540.1"))
        #expect(Code.isWellFormed("540.12345678"))
    }

    @Test("decimal extension capped at maxExtensionDigits")
    func extensionCap() {
        #expect(Code.maxExtensionDigits == 8)
        #expect(Code.isWellFormed("540.123456789") == false)
    }

    @Test("malformed inputs are rejected")
    func malformed() {
        #expect(Code.isWellFormed("") == false)
        #expect(Code.isWellFormed("54") == false)        // two digits
        #expect(Code.isWellFormed("5400") == false)      // four digits before dot
        #expect(Code.isWellFormed("540.") == false)      // dot without extension
        #expect(Code.isWellFormed(".540") == false)      // leading dot
        #expect(Code.isWellFormed("abc") == false)
        #expect(Code.isWellFormed("540.abc") == false)
    }

    @Test("integerBase parses the three-digit prefix")
    func integerBase() {
        #expect(Code.integerBase(of: "540.137") == 540)
        #expect(Code.integerBase(of: "000") == 0)
        #expect(Code.integerBase(of: "malformed") == nil)
    }
}
