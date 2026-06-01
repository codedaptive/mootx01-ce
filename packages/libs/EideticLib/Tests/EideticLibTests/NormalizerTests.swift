// NormalizerTests.swift
//
// Per-type coverage for Normalizer (Sources/EideticLib/Normalizer.swift).
// Normalizer.normalize is the case-fold surface applied before stemming
// and gazetteer lookup. Mirrors the Rust port's normalizer.rs #[test]
// set (ascii fold, mixed case, Unicode letters, empty, determinism) so
// both legs agree on the covered cases.

import Testing
@testable import EideticLib
@testable import LatticeLib

@Suite("Normalizer")
struct NormalizerTests {

    @Test("ASCII uppercase lowers")
    func asciiUppercaseLowers() {
        #expect(Normalizer.normalize("HELLO") == "hello")
    }

    @Test("ASCII lowercase unchanged")
    func asciiLowercaseUnchanged() {
        #expect(Normalizer.normalize("hello") == "hello")
    }

    @Test("mixed case lowers")
    func mixedCaseLowers() {
        #expect(Normalizer.normalize("HelloWorld") == "helloworld")
    }

    @Test("Unicode letters lower")
    func unicodeLettersLower() {
        // Cyrillic uppercase folds to lowercase, matching the Rust port.
        #expect(Normalizer.normalize("МИР") == "мир")
    }

    @Test("empty string yields empty")
    func emptyStringYieldsEmpty() {
        #expect(Normalizer.normalize("") == "")
    }

    @Test("determinism holds")
    func determinismHolds() {
        #expect(Normalizer.normalize("Test") == Normalizer.normalize("Test"))
    }
}
