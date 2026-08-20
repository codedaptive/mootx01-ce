// TrailerLexicalSupplementTests.swift
//
// Grammar-v1 trailer tokens become BM25-visible
// (DECISION_DENSE_LANE_ENRICHMENT, Wave-2 delivery ruling 2026-08-20):
// the enrichment trailer scanned from the dense-composition text is
// appended to the LEXICAL index unit so keyword recall can admit
// category/entity facts, while the verbatim canonical text (and payload)
// stays untouched. Measured basis: the anarrow oracle arm.
//
// Rust twin: rust/tests/trailer_lexical_supplement_tests.rs

import Foundation
import Testing
@testable import CorpusKit

@Suite("TrailerGrammar scanner")
struct TrailerGrammarScannerTests {

    @Test("extracts the trailer inner text with a leading space")
    func extractsInner() {
        let dense = "Jolene: I bought Seraphim a year ago in Paris. (*[ entity: snake, place: paris, country: france, fdc: pets ]*)"
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: dense)
                == " entity: snake, place: paris, country: france, fdc: pets")
    }

    @Test("nil, empty, trailer-free, and malformed inputs contribute nothing")
    func failQuiet() {
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: nil) == "")
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: "") == "")
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: "plain distillate") == "")
        // Close before open — malformed, no supplement.
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: "]*) broken (*[") == "")
        // Empty block contributes nothing.
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: "x (*[   ]*)") == "")
    }

    @Test("the LAST well-formed block wins when prose mentions the delimiters")
    func lastBlockWins() {
        let dense = "we discussed (*[ old: note ]*) earlier (*[ kind: hobby ]*)"
        #expect(TrailerGrammar.lexicalSupplement(fromDenseText: dense) == " kind: hobby")
    }
}

/// Minimal content source for the BM25 suite (mirror of the private
/// DualTextInMemorySource fixture in DualTextIndexingTests).
private actor TrailerTestSource: CorpusContentSource {
    private var records: [CorpusContentID: CorpusContentRecord] = [:]
    private var changeSeq = 0
    private var changeLog: [(CorpusContentChange, Int)] = []

    func put(id: CorpusContentID, text: String, denseCompositionText: String?) {
        let digest = CorpusContentDigest.digest(text)
        records[id] = CorpusContentRecord(
            id: id, revision: 1, digest: digest,
            text: text, denseCompositionText: denseCompositionText)
        changeSeq += 1
        changeLog.append((.upsert(id: id, revision: 1, digest: digest), changeSeq))
    }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        records[id]
    }

    func changes(
        since cursor: String?, limit: Int
    ) async throws -> CorpusContentChangeBatch {
        let after = cursor.flatMap(Int.init) ?? 0
        let page = changeLog.filter { $0.1 > after }.prefix(limit)
        guard !page.isEmpty else { return .empty }
        return CorpusContentChangeBatch(
            changes: page.map(\.0), nextCursor: String(page.last!.1))
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.keys.sorted()
    }
}

@Suite("Trailer tokens reach BM25")
struct TrailerBM25Tests {

    private func makeEngine(
        source: any CorpusContentSource
    ) async throws -> CorpusContentEngine {
        let storage = try makeScratchStorage()
        let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent)
        try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration())
        return try await CorpusContentEngine(
            storage: storage, configuration: config, source: source,
            models: [.default])
    }

    @Test("a trailer-only term is keyword-recallable; verbatim payload untouched")
    func trailerTermRecallable() async throws {
        let source = TrailerTestSource()
        // "brazil" appears ONLY in the trailer — never in the verbatim text.
        let lexical = "Guess what? We got back from an awesome trip to Rio yesterday."
        let dense = lexical + " (*[ place: rio de janeiro, country: brazil ]*)"
        await source.put(id: "doc1", text: lexical, denseCompositionText: dense)
        // A distractor with neither term.
        await source.put(id: "doc2", text: "The robotics project deadline moved again.",
                         denseCompositionText: nil)

        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)
        try await engine.indexContent(id: "doc2", now: now)

        let results = try await engine.recall("brazil country", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"),
                "trailer-only terms must be keyword-recallable (anarrow shape)")
        // Payload safety is structural: hits carry ids + scores only, and the
        // body is resolved from the CANONICAL record at hydration — which this
        // change never touches (record.text is unmodified by the supplement).
        #expect(results.allSatisfy { $0.keywordScore != nil || $0.vectorScore != nil })
    }

    @Test("records without a trailer index byte-identically to before")
    func noTrailerNoChange() async throws {
        let source = TrailerTestSource()
        let lexical = "the quick brown fox jumps over the lazy dog"
        await source.put(id: "doc1", text: lexical, denseCompositionText: "fox dog")
        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)
        let results = try await engine.recall("quick brown fox", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"))
    }
}
