// TokenizerTests.swift
//
// Peer suite for the Tokenizer protocol's default keywordTokens
// extension (Sources/CorpusKit/Tokenizer.swift). DeterministicTokenizer
// does not override keywordTokens, so it exercises the default path:
// lowercase, keep alphabetic + ASCII digits, split on every other
// scalar. This is the surface BM25Index calls.

import Testing
import CorpusKit
import CorpusKitProviders

@Suite("Tokenizer.keywordTokens (default)")
struct TokenizerTests {

    let tokenizer = DeterministicTokenizer()

    @Test func lowercasesAndSplitsOnPunctuation() {
        #expect(tokenizer.keywordTokens("Hello, World!") == ["hello", "world"])
    }

    @Test func keepsAlphanumericRuns() {
        #expect(tokenizer.keywordTokens("abc123 def456") == ["abc123", "def456"])
    }

    @Test func collapsesRepeatedSeparators() {
        #expect(tokenizer.keywordTokens("  the   quick\t\nbrown  ") == ["the", "quick", "brown"])
    }

    @Test func emptyStringProducesNoTokens() {
        #expect(tokenizer.keywordTokens("").isEmpty)
    }

    @Test func punctuationOnlyProducesNoTokens() {
        #expect(tokenizer.keywordTokens("!!! ... ???").isEmpty)
    }

    @Test func exposesProtocolVocabularySurface() {
        // The protocol requirements DeterministicTokenizer satisfies.
        #expect(tokenizer.vocabID == "deterministic-v1")
        #expect(tokenizer.maxTokens == 128)
        #expect(tokenizer.padTokenID == 0)
        #expect(tokenizer.unknownTokenID == 1)
    }
}
