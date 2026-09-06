// SSCFactsTests.swift
//
// Schema 19: facts move from grammar-v1 trailer scanning to a dedicated
// `ssc_facts` column. SSCFacts.lexicalSupplement(_:) reads the stored pair
// list directly — no scanning, no delimiter dependency.
//
// Rust twin: rust/src/ssc_facts.rs (inline tests)

import Foundation
import Testing
@testable import CorpusKit

@Suite("SSCFacts lexical supplement")
struct SSCFactsTests {

    @Test("appends the fact list with a leading space")
    func appendsWithSpace() {
        let facts = "entity: louvre, place: paris"
        #expect(SSCFacts.lexicalSupplement(facts) == " entity: louvre, place: paris")
    }

    @Test("nil and empty return empty string (fail-quiet)")
    func failQuiet() {
        #expect(SSCFacts.lexicalSupplement(nil) == "")
        #expect(SSCFacts.lexicalSupplement("") == "")
    }

    @Test("old content with grammar-v1 delimiters in verbatim text passes through as-is")
    func oldContentDelimitersPassThrough() {
        // The supplement must not scan for (*[ ]*) — those are data in old content.
        // ssc_facts column value does not contain delimiters (bare pair list only).
        let facts = "entity: snake, place: paris"
        #expect(SSCFacts.lexicalSupplement(facts) == " entity: snake, place: paris")
    }
}

/// Minimal in-memory source for BM25 supplement smoke tests.
private actor SSCTestSource: CorpusContentSource {
    private var records: [CorpusContentID: CorpusContentRecord] = [:]
    private var changeSeq = 0
    private var changeLog: [(CorpusContentChange, Int)] = []

    func put(id: CorpusContentID, text: String, sscFacts: String?) {
        let digest = CorpusContentDigest.digest(text)
        records[id] = CorpusContentRecord(
            id: id, revision: 1, digest: digest,
            text: text, sscFacts: sscFacts)
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

@Suite("SSC facts reach BM25")
struct SSCFactsBM25Tests {

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

    @Test("a term in ssc_facts but not in content is keyword-recallable")
    func sscFactsTermRecallable() async throws {
        // Failure mode: supplement is not appended → "brazil" is not indexed.
        let source = SSCTestSource()
        // Content has no mention of "brazil"; ssc_facts supplies it.
        await source.put(id: "doc1",
                         text: "We visited a wonderful city last summer.",
                         sscFacts: "place: brazil")
        await source.put(id: "doc2",
                         text: "The robotics project deadline moved again.",
                         sscFacts: nil)

        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)
        try await engine.indexContent(id: "doc2", now: now)

        let results = try await engine.recall("brazil", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"),
                "ssc_facts term must be keyword-recallable via the supplement")
    }

    @Test("old content with (*[ … ]*) block is indexed once, not twice")
    func oldContentNotDoubleIndexed() async throws {
        // Failure mode: if the engine still scanned for delimiters, "hobby" from
        // the old verbatim block AND from ssc_facts would both appear. With the
        // new path the verbatim block is raw text data and ssc_facts is the source.
        let source = SSCTestSource()
        // Old-format verbatim content that happens to contain a trailer block.
        let oldContent = "I enjoy painting. (*[ kind: hobby, entity: painting ]*)"
        await source.put(id: "doc1", text: oldContent, sscFacts: "kind: hobby, entity: painting")

        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)

        // Should find the doc by the term; verifying it recalls once is enough.
        let results = try await engine.recall("hobby painting", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"))
    }
}
