// PairTokenizerTests.swift
//
// `WordPieceTokenizer.tokenizePair` pinned against the reference tokenizer
// (HF `tokenizers` over the same vocab.txt, `truncation="longest_first"`):
// ids, segment ids and the truncation boundary.
//
// The id arrays (the ground-truth) live in the shared fixture:
//   SynapseKit/Tests/Fixtures/encoder/cross_encoder_tokenizer_parity.json
// The Rust candle test reads the same file, so both ports pin against a
// single source of truth. Do not duplicate the arrays here.
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

// MARK: - Shared fixture loader
// These types and helpers are internal (not private) so PairScorerFactoryTests
// can read the same fixture without duplicating the loader.

/// A single pair entry from `cross_encoder_tokenizer_parity.json`.
struct TokenizerParityPair: Decodable {
    let name: String
    let query: String
    let span: String
    let max_length: Int?
    let ids: [Int32]
    let query_token_count: Int
    let span_token_count: Int
}

struct TokenizerParityFixture: Decodable {
    /// Query and span texts keyed by short label (e.g. "capital", "paris0").
    let texts: [String: String]
    let pairs: [TokenizerParityPair]

    /// Look up a pair by name; fails the test if the name is absent.
    func pair(named name: String) throws -> TokenizerParityPair {
        guard let p = pairs.first(where: { $0.name == name }) else {
            throw TestError("cross_encoder_tokenizer_parity.json: pair '\(name)' not found")
        }
        return p
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

/// URL of `SynapseKit/Tests/Fixtures/encoder/cross_encoder_tokenizer_parity.json`.
/// #filePath = …/packages/kits/CorpusKit/Tests/CorpusKitTests/<file>.
/// Go up four components to packages/kits/, then into the sibling kit.
func tokenizerParityFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CorpusKitTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // CorpusKit/
        .deletingLastPathComponent() // kits/
        .appendingPathComponent("SynapseKit/Tests/Fixtures/encoder/cross_encoder_tokenizer_parity.json")
}

func loadTokenizerParityFixture() throws -> TokenizerParityFixture {
    let data = try Data(contentsOf: tokenizerParityFixtureURL())
    return try JSONDecoder().decode(TokenizerParityFixture.self, from: data)
}

@Suite("WordPieceTokenizer.tokenizePair")
struct PairTokenizerTests {

    @Test("pairs match the reference ids and segment ids at max 512")
    func referencePairs() throws {
        let fixture = try loadTokenizerParityFixture()
        let t = try realVocabulary(maxTokens: 512)

        let cp = try fixture.pair(named: "capital_paris0")
        let a = t.tokenizePair(fixture.texts["capital"]!, fixture.texts["paris0"]!)
        #expect(a.ids == cp.ids)
        #expect(a.tokenTypeIDs == [Int32](repeating: 0, count: cp.query_token_count) + [Int32](repeating: 1, count: cp.span_token_count))

        let bw = try fixture.pair(named: "boiling_water")
        let b = t.tokenizePair(fixture.texts["boiling"]!, fixture.texts["water"]!)
        #expect(b.ids == bw.ids)
        #expect(b.tokenTypeIDs == [Int32](repeating: 0, count: bw.query_token_count) + [Int32](repeating: 1, count: bw.span_token_count))

        let pc = try fixture.pair(named: "pet_cat")
        let c = t.tokenizePair(fixture.texts["pet"]!, fixture.texts["cat"]!)
        #expect(c.ids == pc.ids)
        #expect(c.tokenTypeIDs.count == c.ids.count)
    }

    @Test("longest-first truncation trims the longer side, ties trim the query")
    func longestFirst() throws {
        let fixture = try loadTokenizerParityFixture()

        let bw16 = try fixture.pair(named: "boiling_water_16")
        let sixteen = try realVocabulary(maxTokens: 16)
            .tokenizePair(fixture.texts["boiling"]!, fixture.texts["water"]!)
        #expect(sixteen.ids == bw16.ids)
        #expect(sixteen.tokenTypeIDs == [Int32](repeating: 0, count: bw16.query_token_count) + [Int32](repeating: 1, count: bw16.span_token_count))

        let bw15 = try fixture.pair(named: "boiling_water_15")
        let fifteen = try realVocabulary(maxTokens: 15)
            .tokenizePair(fixture.texts["boiling"]!, fixture.texts["water"]!)
        #expect(fifteen.ids == bw15.ids)
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
        let fixture = try loadTokenizerParityFixture()
        let t = try realVocabulary(maxTokens: 3)
        let p = t.tokenizePair(fixture.texts["capital"]!, fixture.texts["paris0"]!)
        #expect(p.ids == [t.classTokenID, t.separatorTokenID, t.separatorTokenID])
        #expect(p.tokenTypeIDs == [0, 0, 1])
    }
}
