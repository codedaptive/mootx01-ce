// PairTokenizerTests.swift
//
// `WordPieceTokenizer.tokenizePair` pinned against the reference tokenizer
// (HF `tokenizers` over the same vocab.txt, `truncation="longest_first"`):
// ids, segment ids and the truncation boundary. The same ids are pinned in
// the Rust candle test (`cross_encoder_candle_tests.rs`), so both ports
// feed the classifier identical pairs.
//
// Failure modes: a missing middle `[SEP]`, segment ids that start at the
// wrong position, truncation that trims the shorter sequence or the wrong
// side of a tie.

import Testing
import Foundation
@testable import CorpusKit
@testable import CorpusKitProviders

/// The real 30 522-entry vocabulary the fixtures ship.
private func realVocabulary(maxTokens: Int) throws -> WordPieceTokenizer {
    let url = try #require(Bundle.module.url(
        forResource: "vocab", withExtension: "txt", subdirectory: "minilm-l6-v2-w60"))
    return try WordPieceTokenizer(contentsOf: url, vocabID: "minilm", maxTokens: maxTokens)
}

/// The lab fixture texts (benchmark-ee/cross-encoder-lab/fixtures).
enum CrossEncoderFixture {
    static let capital = "What is the capital of France?"
    static let boiling = "At what temperature does water boil at standard pressure?"
    static let pet = "What kind of animal is a domestic cat?"
    static let paris0 = "Paris is the capital city of France."
    static let paris1 = "Paris stands on the river Seine."
    static let berlin = "Berlin is the capital city of Germany."
    static let water = "At standard atmospheric pressure, pure water boils at 100 degrees Celsius."
    static let cat = "A domestic cat is a small carnivorous mammal often kept as a pet."

    /// Reference ids from the HF tokenizer at max_length 512.
    static let capitalParis0: [Int32] = [101, 2054, 2003, 1996, 3007, 1997, 2605, 1029, 102, 3000, 2003, 1996, 3007, 2103, 1997, 2605, 1012, 102]
    static let boilingWater: [Int32] = [101, 2012, 2054, 4860, 2515, 2300, 26077, 2012, 3115, 3778, 1029, 102, 2012, 3115, 12483, 3778, 1010, 5760, 2300, 26077, 2015, 2012, 2531, 5445, 8292, 4877, 4173, 1012, 102]
    static let petCat: [Int32] = [101, 2054, 2785, 1997, 4111, 2003, 1037, 4968, 4937, 1029, 102, 1037, 4968, 4937, 2003, 1037, 2235, 2482, 29193, 25476, 2411, 2921, 2004, 1037, 9004, 1012, 102]
    /// boiling / water at max_length 16 and 15: longest-first trims the span
    /// to the query's length and then alternates, ties trimming the query.
    static let boilingWater16: [Int32] = [101, 2012, 2054, 4860, 2515, 2300, 26077, 102, 2012, 3115, 12483, 3778, 1010, 5760, 2300, 102]
    static let boilingWater15: [Int32] = [101, 2012, 2054, 4860, 2515, 2300, 26077, 102, 2012, 3115, 12483, 3778, 1010, 5760, 102]
}

@Suite("WordPieceTokenizer.tokenizePair")
struct PairTokenizerTests {

    @Test("pairs match the reference ids and segment ids at max 512")
    func referencePairs() throws {
        let t = try realVocabulary(maxTokens: 512)
        let a = t.tokenizePair(CrossEncoderFixture.capital, CrossEncoderFixture.paris0)
        #expect(a.ids == CrossEncoderFixture.capitalParis0)
        #expect(a.tokenTypeIDs == [Int32](repeating: 0, count: 9) + [Int32](repeating: 1, count: 9))
        let b = t.tokenizePair(CrossEncoderFixture.boiling, CrossEncoderFixture.water)
        #expect(b.ids == CrossEncoderFixture.boilingWater)
        #expect(b.tokenTypeIDs == [Int32](repeating: 0, count: 12) + [Int32](repeating: 1, count: 17))
        let c = t.tokenizePair(CrossEncoderFixture.pet, CrossEncoderFixture.cat)
        #expect(c.ids == CrossEncoderFixture.petCat)
        #expect(c.tokenTypeIDs.count == c.ids.count)
    }

    @Test("longest-first truncation trims the longer side, ties trim the query")
    func longestFirst() throws {
        let sixteen = try realVocabulary(maxTokens: 16)
            .tokenizePair(CrossEncoderFixture.boiling, CrossEncoderFixture.water)
        #expect(sixteen.ids == CrossEncoderFixture.boilingWater16)
        #expect(sixteen.tokenTypeIDs == [Int32](repeating: 0, count: 8) + [Int32](repeating: 1, count: 8))
        let fifteen = try realVocabulary(maxTokens: 15)
            .tokenizePair(CrossEncoderFixture.boiling, CrossEncoderFixture.water)
        #expect(fifteen.ids == CrossEncoderFixture.boilingWater15)
    }

    @Test("an empty span still carries both separators and segment 1")
    func emptySpan() throws {
        let t = try realVocabulary(maxTokens: 512)
        let p = t.tokenizePair("hello", "")
        #expect(p.ids.first == t.classTokenID)
        #expect(p.ids.suffix(2) == [t.separatorTokenID, t.separatorTokenID])
        #expect(p.tokenTypeIDs == [0, 0, 0, 1])
    }

    @Test("a budget below three tokens keeps only the specials")
    func tinyBudget() throws {
        let t = try realVocabulary(maxTokens: 3)
        let p = t.tokenizePair(CrossEncoderFixture.capital, CrossEncoderFixture.paris0)
        #expect(p.ids == [t.classTokenID, t.separatorTokenID, t.separatorTokenID])
        #expect(p.tokenTypeIDs == [0, 0, 1])
    }
}
