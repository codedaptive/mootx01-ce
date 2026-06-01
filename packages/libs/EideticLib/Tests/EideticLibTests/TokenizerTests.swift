// TokenizerTests.swift
//
// Per-type coverage for Tokenizer (Sources/EideticLib/Tokenizer.swift).
// Tokenizer.tokenize is the UAX #29 word-boundary surface (Foundation
// enumerateSubstrings(.byWords) over ICU). Mirrors the Rust port's
// tokenizer.rs #[test] set (empty, simple phrase, punctuation dropped,
// multi-script, determinism); the source documents byte-identical
// output on these covered cases.

import Testing
@testable import EideticLib
@testable import LatticeLib

@Suite("Tokenizer")
struct TokenizerTests {

    @Test("empty string yields no tokens")
    func emptyStringYieldsNoTokens() {
        #expect(Tokenizer.tokenize("").isEmpty)
    }

    @Test("simple English phrase tokenizes")
    func simpleEnglishPhraseTokenizes() {
        #expect(Tokenizer.tokenize("organic chemistry research")
            == ["organic", "chemistry", "research"])
    }

    @Test("punctuation dropped")
    func punctuationDropped() {
        #expect(Tokenizer.tokenize("Hello, world! How are you?")
            == ["Hello", "world", "How", "are", "you"])
    }

    @Test("multi-script handled")
    func multiScriptHandled() {
        // Mixed Latin and Cyrillic, with punctuation between.
        #expect(Tokenizer.tokenize("Hello, мир!") == ["Hello", "мир"])
    }

    @Test("determinism holds")
    func determinismHolds() {
        let a = Tokenizer.tokenize("the quick brown fox")
        let b = Tokenizer.tokenize("the quick brown fox")
        #expect(a == b)
    }
}
