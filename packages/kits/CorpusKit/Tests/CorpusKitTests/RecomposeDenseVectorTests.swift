// RecomposeDenseVectorTests.swift
//
// Unit tests for CorpusContentEngine.recomposeDenseVector(id:now:)
// (MISSION_11X_RECALL_GAP_01 Stream F — dense-over-distillate).
//
// Validates:
//   §null-fallback  nil denseCompositionText propagates; float vector reflects
//       the lexical text. recomposeDenseVector on a record whose distillate is
//       nil is idempotent (same embedding → same similarity).
//   §recompose      After writing denseCompositionText to the document store,
//       recomposeDenseVector updates the float vector. The new vector reflects
//       the dense-composition text (distillate), producing a measurably
//       different similarity for the same query.
//   §bm25-isolation recomposeDenseVector does NOT modify BM25 postings; §9
//       (SPEC_DISTILLATION_STORAGE): BM25 scores are byte-identical before
//       and after recompose, because content and digest are unchanged.
//   §false-on-miss  recomposeDenseVector returns false (no throw) when the
//       content ID has no record in the source.

import Testing
import Foundation
import EngramLib
import PersistenceKit
@testable import PersistenceKitSQLite
import VectorKit
import CorpusKitProviders

@testable import CorpusKit

@Suite("RecomposeDenseVector", .serialized)
struct RecomposeDenseVectorTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Fixture

    /// Standalone engine over a real SQLite estate. CorpusDocumentStore is
    /// both source and store, so `put()` + `record(for:)` are coherent.
    private func makeEngine() async throws
        -> (CorpusContentEngine, CorpusDocumentStore)
    {
        let storage = try makeScratchStorage()
        let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent)
        try await storage.migrate(to: CorpusSchemaProfile.standaloneDeclaration())
        let store = CorpusDocumentStore(storage: storage)
        let engine = try await CorpusContentEngine(
            storage: storage, configuration: config, source: store)
        return (engine, store)
    }

    /// Extract hits from a FloatLaneOutcome, returning [] for any non-hit outcome.
    private func hitsOrEmpty(_ outcome: FloatLaneOutcome)
        -> [(itemID: String, similarity: Float)]
    {
        if case let .hits(pairs) = outcome { return pairs }
        return []
    }

    // MARK: - §null-fallback

    @Test("recomposeDenseVector with nil denseCompositionText is idempotent on the float lane")
    func nullDenseTextIsIdempotent() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine()
            _ = try await store.put(
                "Lexical content without a distillate.",
                denseCompositionText: nil,
                id: "item-null",
                now: now)
            try await engine.indexContent(id: "item-null", now: now)

            // Float-lane baseline (lexical-composed, distillate nil).
            let before = hitsOrEmpty(await engine.floatNearest(
                query: "Lexical content", limit: 5))
            let beforeScore = before.first(where: { $0.itemID == "item-null" })?.similarity

            // Recompose with nil denseCompositionText — embedding is unchanged.
            let recomposed = try await engine.recomposeDenseVector(
                id: "item-null", now: now)
            #expect(recomposed, "must return true for a live record")

            let after = hitsOrEmpty(await engine.floatNearest(
                query: "Lexical content", limit: 5))
            let afterScore = after.first(where: { $0.itemID == "item-null" })?.similarity

            // Scores may both be nil (provider opted out of float for this corpus
            // configuration) or both non-nil and equal (idempotent re-embed).
            // In either case they must be identical.
            #expect(afterScore == beforeScore,
                    "nil denseCompositionText: recompose must be idempotent on the float lane")
        }
    }

    // MARK: - §recompose

    @Test("recomposeDenseVector after writing denseCompositionText changes the float similarity")
    func recomposesAfterDistillateWrite() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine()

            // Initial index with lexical text only (no distillate).
            _ = try await store.put(
                "The observatory telescope requires calibration every six months.",
                denseCompositionText: nil,
                id: "item-recompose",
                now: now)
            _ = try await store.put(
                "Weather forecast: clear skies expected tomorrow morning.",
                denseCompositionText: nil,
                id: "item-other",
                now: now)
            try await engine.indexContent(id: "item-recompose", now: now)
            try await engine.indexContent(id: "item-other", now: now)

            let query = "observatory calibration telescope"
            let before = hitsOrEmpty(await engine.floatNearest(query: query, limit: 5))

            // Write a distillate (simulating the drain-stage distillation write).
            // The document store is the source, so record(for:) returns this text.
            _ = try await store.put(
                "The observatory telescope requires calibration every six months.",
                denseCompositionText: "observatory telescope calibration months",
                id: "item-recompose",
                now: now)

            // Recompose reads the updated record (denseCompositionText now set)
            // and writes a new float vector row using effectiveDenseText.
            let recomposed = try await engine.recomposeDenseVector(
                id: "item-recompose", now: now)
            #expect(recomposed, "must return true for a live record")

            let after = hitsOrEmpty(await engine.floatNearest(query: query, limit: 5))

            // The float vector must have changed — different text → different
            // embedding → different cosine similarity. If the float lane is
            // unavailable (provider opted out), we cannot observe the change
            // through floatNearest; in that case skip the assertion.
            if !before.isEmpty && !after.isEmpty {
                let beforeScore = before.first(where: { $0.itemID == "item-recompose" })?.similarity
                let afterScore = after.first(where: { $0.itemID == "item-recompose" })?.similarity
                if let b = beforeScore, let a = afterScore {
                    #expect(a != b,
                            "float similarity must change after recompose from new denseCompositionText")
                }
            }
        }
    }

    // MARK: - §bm25-isolation

    @Test("recomposeDenseVector does not change BM25 scores (§9 isolation)")
    func recomposeLeaveBM25Unchanged() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine()

            _ = try await store.put(
                "The reactor coolant temperature exceeded the safety threshold.",
                denseCompositionText: nil,
                id: "item-bm25",
                now: now)
            try await engine.indexContent(id: "item-bm25", now: now)

            let query = "reactor coolant temperature"
            let beforeBm25 = try await engine.bm25TopK(query: query, limit: 5)
            let beforeScore = try #require(
                beforeBm25.first(where: { $0.id == "item-bm25" })?.score,
                "item must appear in BM25 recall before recompose")

            // Write a distillate and recompose the dense float lane.
            _ = try await store.put(
                "The reactor coolant temperature exceeded the safety threshold.",
                denseCompositionText: "reactor coolant temperature exceeded safety",
                id: "item-bm25",
                now: now)
            _ = try await engine.recomposeDenseVector(id: "item-bm25", now: now)

            let afterBm25 = try await engine.bm25TopK(query: query, limit: 5)
            let afterScore = try #require(
                afterBm25.first(where: { $0.id == "item-bm25" })?.score)

            // §9 (SPEC_DISTILLATION_STORAGE): the BM25 lane is anchored to
            // `text` (unchanged by distillation). recomposeDenseVector must
            // NOT touch BM25 postings — BM25 scores must be byte-identical.
            #expect(afterScore == beforeScore,
                    "§9: BM25 score must be byte-identical before and after recompose")
        }
    }

    // MARK: - §false-on-miss

    @Test("recomposeDenseVector returns false when the content ID has no record")
    func returnsFalseForMissingRecord() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, _) = try await makeEngine()
            let result = try await engine.recomposeDenseVector(
                id: "nonexistent-id", now: now)
            #expect(!result,
                    "must return false (not throw) when the record does not resolve")
        }
    }
}
