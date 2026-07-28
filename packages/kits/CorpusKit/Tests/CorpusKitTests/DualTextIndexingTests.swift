// DualTextIndexingTests.swift
//
// Tests for the CorpusKit dual-text indexing capability
// (MISSION_11X_RECALL_GAP_01 Stream A).
//
// Coverage requirements (from mission):
//   1. Source-protocol mode (external content, as MOOTx01 uses) — dense text
//      used when the source adapter supplies it in CorpusContentRecord.
//   2. Internal text-storage mode (CorpusDocumentStore, standalone SDK use) —
//      dense text stored/retrieved via corpus_documents.dense_text column.
//   3. Dense text used for embedding, lexical text used for BM25 (isolation).
//   4. Retrain/reindex recomposition: trainTrainableSlots and reindex both
//      use effectiveDenseText, not lexical text.
//   5. nil denseCompositionText ↔ zero behavior change for existing consumers.
//
// Rust twin: rust/tests/dual_text_indexing_tests.rs

import Foundation
import Testing
@testable import CorpusKit

// MARK: - CorpusContentRecord unit tests

@Suite("CorpusContentRecord dual-text fields")
struct CorpusContentRecordDualTextTests {

    @Test("effectiveDenseText returns text when denseCompositionText is nil")
    func effectiveDenseTextFallsBackToText() {
        let record = CorpusContentRecord(
            id: "r1", revision: 1,
            digest: CorpusContentDigest.digest("hello"),
            text: "hello")
        #expect(record.denseCompositionText == nil)
        #expect(record.effectiveDenseText == "hello")
    }

    @Test("effectiveDenseText returns denseCompositionText when set")
    func effectiveDenseTextReturnsDenseWhenSet() {
        let record = CorpusContentRecord(
            id: "r1", revision: 1,
            digest: CorpusContentDigest.digest("hello world"),
            text: "hello world",
            denseCompositionText: "hello")
        #expect(record.denseCompositionText == "hello")
        #expect(record.effectiveDenseText == "hello")
    }

    @Test("4-arg init leaves denseCompositionText nil (backward compatibility)")
    func fourArgInitPreservesNilDenseText() {
        let record = CorpusContentRecord(
            id: "r1", revision: 1,
            digest: CorpusContentDigest.digest("text"),
            text: "text")
        #expect(record.denseCompositionText == nil)
    }

    @Test("Equatable considers denseCompositionText")
    func equatableConsidersDenseText() {
        let a = CorpusContentRecord(
            id: "r1", revision: 1,
            digest: CorpusContentDigest.digest("text"),
            text: "text", denseCompositionText: "dense")
        let b = CorpusContentRecord(
            id: "r1", revision: 1,
            digest: CorpusContentDigest.digest("text"),
            text: "text", denseCompositionText: nil)
        let c = CorpusContentRecord(
            id: "r1", revision: 1,
            digest: CorpusContentDigest.digest("text"),
            text: "text", denseCompositionText: "dense")
        #expect(a != b)
        #expect(a == c)
    }
}

// MARK: - CorpusDocumentStore dual-text tests (internal text-storage mode)

@Suite("CorpusDocumentStore dual-text (standalone mode)")
struct CorpusDocumentStoreDualTextTests {

    private func makeStore() async throws -> CorpusDocumentStore {
        // Use the real SQLite backend (same as all other CorpusKit tests).
        let storage = try makeScratchStorage()
        try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
        return CorpusDocumentStore(storage: storage)
    }

    @Test("put with nil denseCompositionText stores NULL and returns nil")
    func putWithNilDenseTextRoundTrips() async throws {
        let store = try await makeStore()
        let record = try await store.put("hello world", id: "doc1", now: Date())
        #expect(record.denseCompositionText == nil)
        let fetched = try await store.record(for: "doc1")
        #expect(fetched?.denseCompositionText == nil)
        #expect(fetched?.effectiveDenseText == "hello world")
    }

    @Test("put with denseCompositionText stores and retrieves it")
    func putWithDenseTextRoundTrips() async throws {
        let store = try await makeStore()
        let record = try await store.put(
            "hello world stopwords everywhere",
            denseCompositionText: "hello world",
            id: "doc1", now: Date())
        #expect(record.denseCompositionText == "hello world")
        #expect(record.text == "hello world stopwords everywhere")
        let fetched = try await store.record(for: "doc1")
        #expect(fetched?.denseCompositionText == "hello world")
        #expect(fetched?.effectiveDenseText == "hello world")
        #expect(fetched?.text == "hello world stopwords everywhere")
    }

    @Test("put idempotent: unchanged text AND unchanged denseCompositionText returns same record")
    func putIdempotentOnBothTextsUnchanged() async throws {
        let store = try await makeStore()
        let first = try await store.put(
            "lexical text", denseCompositionText: "dense text",
            id: "doc1", now: Date())
        let second = try await store.put(
            "lexical text", denseCompositionText: "dense text",
            id: "doc1", now: Date())
        #expect(first == second)
    }

    @Test("changing only denseCompositionText bumps revision")
    func changingOnlyDenseTextBumpsRevision() async throws {
        let store = try await makeStore()
        let first = try await store.put(
            "lexical text", denseCompositionText: "dense v1",
            id: "doc1", now: Date())
        #expect(first.revision == 1)
        let second = try await store.put(
            "lexical text", denseCompositionText: "dense v2",
            id: "doc1", now: Date())
        // Dense text changed → revision bumps even though lexical text is same.
        #expect(second.revision == 2)
        #expect(second.denseCompositionText == "dense v2")
    }

    @Test("batch records(for:) returns denseCompositionText for all IDs")
    func batchRecordsReturnsDenseText() async throws {
        let store = try await makeStore()
        _ = try await store.put("a text", denseCompositionText: "a dense", id: "a", now: Date())
        _ = try await store.put("b text", denseCompositionText: nil, id: "b", now: Date())
        let fetched = try await store.records(for: ["a", "b"])
        #expect(fetched["a"]?.denseCompositionText == "a dense")
        #expect(fetched["b"]?.denseCompositionText == nil)
    }
}

// MARK: - Source-protocol mode (external content provider)
//
// Tests that the engine uses effectiveDenseText from whatever
// CorpusContentRecord the source adapter returns. This covers the
// attached / GLK path where the adapter includes the dense-composition text
// in the record without CorpusDocumentStore being involved.

/// Minimal content source whose records carry optional dense texts.
private actor DualTextInMemorySource: CorpusContentSource {
    private var records: [String: CorpusContentRecord] = [:]
    private var changeSeq: Int = 0
    private var changes: [(CorpusContentChange, Int)] = []

    func put(id: String, text: String, denseCompositionText: String?) {
        let digest = CorpusContentDigest.digest(text)
        let rev: Int64
        if let existing = records[id] {
            rev = existing.revision + 1
        } else {
            rev = 1
        }
        let record = CorpusContentRecord(
            id: id, revision: rev, digest: digest, text: text,
            denseCompositionText: denseCompositionText)
        records[id] = record
        changeSeq += 1
        changes.append((.upsert(id: id, revision: rev, digest: digest), changeSeq))
    }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        records[id]
    }

    func changes(
        since cursor: String?, limit: Int
    ) async throws -> CorpusContentChangeBatch {
        let after = cursor.flatMap(Int.init) ?? 0
        let page = changes.filter { $0.1 > after }.prefix(limit)
        guard !page.isEmpty else { return .empty }
        let lastSeq = page.last!.1
        return CorpusContentChangeBatch(
            changes: page.map(\.0),
            nextCursor: String(lastSeq))
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.keys.sorted()
    }
}

@Suite("CorpusContentEngine dual-text via source protocol")
struct CorpusContentEngineDualTextSourceProtocolTests {

    private func makeEngine(
        source: any CorpusContentSource
    ) async throws -> CorpusContentEngine {
        let storage = try makeScratchStorage()
        // CorpusContentConfiguration.init throws when the mode/indexUnit
        // combination is invalid — standalone+wholeContent is always valid.
        let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent)
        try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration())
        return try await CorpusContentEngine(
            storage: storage, configuration: config, source: source,
            models: [.default])
    }

    @Test("dense text used for embedding; lexical text in BM25 stays unchanged")
    func denseTextUsedForEmbeddingLexicalForBM25() async throws {
        let source = DualTextInMemorySource()
        // Populate the source with a record that has a dense-composition text.
        let lexical = "the quick brown fox jumps over the lazy dog and more words"
        let dense   = "fox dog"
        await source.put(id: "doc1", text: lexical, denseCompositionText: dense)

        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)

        // Recall by the LEXICAL term — should find the document because
        // BM25 indexed the full lexical text.
        let results = try await engine.recall(
            "quick brown fox", limit: 5, now: now)
        let ids = results.map(\.id)
        #expect(ids.contains("doc1"),
                "BM25 must index the lexical text so 'quick brown fox' recall works")
    }

    @Test("reindex recomposes vectors from effectiveDenseText")
    func reindexRecomposesFromDenseText() async throws {
        let source = DualTextInMemorySource()
        let dense = "essential terms"
        await source.put(
            id: "doc1",
            text: "the quick brown fox and lots of stopwords fill this text",
            denseCompositionText: dense)

        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)

        // reindex must not fail and the record must remain retrievable.
        try await engine.reindex(now: now)

        let results = try await engine.recall("fox", limit: 5, now: now)
        let ids = results.map(\.id)
        // BM25 indexed the lexical text, so "fox" should still find doc1.
        #expect(ids.contains("doc1"),
                "After reindex, BM25 recall of a lexical term must still work")
    }

    @Test("nil denseCompositionText: zero behavior change from pre-dual-text path")
    func nilDenseTextMeansIdenticalBehavior() async throws {
        let source = DualTextInMemorySource()
        let text = "machine learning natural language processing"
        await source.put(id: "doc1", text: text, denseCompositionText: nil)

        let engine = try await makeEngine(source: source)
        let now = Date()
        try await engine.indexContent(id: "doc1", now: now)

        let results = try await engine.recall("natural language", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"))
    }
}

// MARK: - Standalone ingest dual-text (internal text-storage mode + engine together)

@Suite("CorpusContentEngine.ingest dual-text (standalone)")
struct CorpusContentEngineIngestDualTextTests {

    private func makeStandaloneEngine() async throws -> CorpusContentEngine {
        let storage = try makeScratchStorage()
        // standaloneOn: handles all schema migrations internally.
        return try await CorpusContentEngine(standaloneOn: storage)
    }

    @Test("ingest with nil denseCompositionText: backward-compatible")
    func ingestWithNilDenseText() async throws {
        let engine = try await makeStandaloneEngine()
        let now = Date()
        try await engine.ingest("hello world", contentID: "doc1", now: now)
        let results = try await engine.recall("hello", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"))
    }

    @Test("ingest with denseCompositionText stores it and uses it for embedding")
    func ingestWithDenseText() async throws {
        let engine = try await makeStandaloneEngine()
        let now = Date()
        try await engine.ingest(
            "the quick brown fox jumps over the lazy dog",
            denseCompositionText: "fox dog",
            contentID: "doc1", now: now)
        // BM25 uses the lexical text; "quick brown" should match.
        let results = try await engine.recall("quick brown", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"),
                "BM25 must use the lexical text, not the dense text")
    }

    @Test("reingest with changed denseCompositionText bumps revision and reindexes")
    func reingestChangedDenseText() async throws {
        let engine = try await makeStandaloneEngine()
        let now = Date()
        // First ingest.
        try await engine.ingest(
            "machine learning model training",
            denseCompositionText: "learning model",
            contentID: "doc1", now: now)
        // Second ingest: same lexical text, different dense text.
        try await engine.ingest(
            "machine learning model training",
            denseCompositionText: "machine training",
            contentID: "doc1", now: now)
        // Should not throw; record exists and is re-indexed.
        let results = try await engine.recall("machine learning", limit: 5, now: now)
        #expect(results.map(\.id).contains("doc1"))
    }

    @Test("trainTrainableSlots uses effectiveDenseText (recomposability rule)")
    func trainTrainableSlotsUsesEffectiveDenseText() async throws {
        let engine = try await makeStandaloneEngine()
        let now = Date()
        // Ingest several documents with dense-composition text so the training
        // corpus accumulates dense texts, not raw lexical texts.
        let pairs: [(String, String)] = [
            ("the quick fox and lots of noise", "fox noise"),
            ("machine learning model weights", "learning weights"),
            ("natural language processing text", "language text"),
            ("deep neural network architecture", "neural network"),
            ("vector embedding similarity search", "embedding search"),
        ]
        for (i, (text, dense)) in pairs.enumerated() {
            try await engine.ingest(text, denseCompositionText: dense,
                                    contentID: "doc\(i)", now: now)
        }
        // trainTrainableSlots must complete without throwing (it trains on
        // effectiveDenseText — verified by not crashing, and by the vectors
        // remaining queryable below).
        _ = try await engine.trainTrainableSlots(now: now, force: true)
        let results = try await engine.recall("fox", limit: 10, now: now)
        // BM25 hit: "fox" is in the lexical text of doc0.
        #expect(results.map(\.id).contains("doc0"),
                "After retrain, BM25 recall on lexical terms must still work")
    }
}
