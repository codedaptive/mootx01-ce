#if MOOTX01_MINERS
// AdornmentValidatorsTests.swift
//
// Golden-pin conformance tests for AdornmentValidators (SPEC_ADORNMENT §3,
// adornment rebuild 2026-08-23).
//
// GOLDEN PIN — the literal fixture below is mirrored verbatim by the Rust
// port in AdornmentLib/rust/src/adornment_validators.rs (test mod
// `adornment_validators::tests`). Both ports MUST assert the identical
// input → expected output to satisfy the four-way conformance gate.
// If you change any expected value here, change the Rust test too.
//
// The pin covers:
//   AV-1  containsWordBoundary — entity present at word boundary
//   AV-2  containsWordBoundary — substring-only (no word boundary) → false
//   AV-3  containsWordBoundary — empty entity → false
//   AV-4  validateCount — count present in claim AND source
//   AV-5  validateCount — count in claim but absent from source → false
//   AV-6  validateDate — year token present in both claim and source
//   AV-7  validateDate — claim year absent from source → false
//   AV-8  validateDate — no year in claim → true (vacuous pass)

import Testing
@testable import AdornmentLib

@Suite("AdornmentValidators — golden-pin conformance")
struct AdornmentValidatorsTests {

    // AV-1: "Newton" appears as a whole word in the source text.
    @Test("AV-1 containsWordBoundary — entity at word boundary returns true")
    func av1_containsWordBoundaryPresent() {
        let source = "Isaac Newton published his laws in 1687."
        #expect(AdornmentValidators.containsWordBoundary(entity: "Newton", in: source) == true)
    }

    // AV-2: "Newton" appears only inside "Newtonian" — NOT a word boundary.
    @Test("AV-2 containsWordBoundary — entity only as substring returns false")
    func av2_containsWordBoundarySubstringOnly() {
        let source = "Newtonian mechanics underpins classical physics."
        #expect(AdornmentValidators.containsWordBoundary(entity: "Newton", in: source) == false)
    }

    // AV-3: empty entity string → false.
    @Test("AV-3 containsWordBoundary — empty entity returns false")
    func av3_containsWordBoundaryEmptyEntity() {
        let source = "Any source text here."
        #expect(AdornmentValidators.containsWordBoundary(entity: "", in: source) == false)
    }

    // AV-4: count 25 present in both claim ("25 papers") and source.
    @Test("AV-4 validateCount — count in both claim and source returns true")
    func av4_validateCountValid() {
        let claim = "Newton published 25 papers between 1665 and 1687."
        let source = "Historians estimate Newton wrote 25 scientific papers."
        #expect(AdornmentValidators.validateCount(claim: claim, in: source, expectedCount: 25) == true)
    }

    // AV-5: count 42 present in claim but absent from source → false.
    @Test("AV-5 validateCount — count in claim but absent from source returns false")
    func av5_validateCountNotInSource() {
        let claim = "Newton published 42 papers."
        let source = "Historians estimate Newton wrote 25 scientific papers."
        #expect(AdornmentValidators.validateCount(claim: claim, in: source, expectedCount: 42) == false)
    }

    // AV-6: year 1687 appears in both claim and source.
    @Test("AV-6 validateDate — year in both claim and source returns true")
    func av6_validateDateValid() {
        let claim = "Newton published the Principia in 1687."
        let source = "The Principia Mathematica was released in 1687 by Isaac Newton."
        #expect(AdornmentValidators.validateDate(claim: claim, in: source) == true)
    }

    // AV-7: year 1702 in claim does not appear in source → false.
    @Test("AV-7 validateDate — claim year absent from source returns false")
    func av7_validateDateYearNotInSource() {
        let claim = "Newton discovered gravity in 1702."
        let source = "The apple incident is dated to 1666 in Newton's notebooks."
        #expect(AdornmentValidators.validateDate(claim: claim, in: source) == false)
    }

    // AV-8: claim with no year → vacuous true (caller only invokes when
    // claim references a date; no year means no date claim to validate).
    @Test("AV-8 validateDate — no year in claim returns true (vacuous)")
    func av8_validateDateNoYear() {
        let claim = "Newton invented calculus."
        let source = "Newton and Leibniz independently developed calculus."
        #expect(AdornmentValidators.validateDate(claim: claim, in: source) == true)
    }
}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.
