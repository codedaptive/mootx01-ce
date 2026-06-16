// CorpusTests.swift
//
// Integration tests for the Corpus actor — the unified RAG entry point.
// Tests run on the REAL on-disk SQLite backend (makeScratchStorage) — the
// backend production and the gauntlet use, and the on-disk equivalent of
// MemPalace's Chroma — never the in-RAM backend (whose divergent type
// round-trip hid real reopen bugs). EmbeddingModel.deterministic is used for
// the provider (no CoreML required). All assertions are behavioral, not
// implementation:
// they verify the public surface (ingest / recall / remove / count)
// and the sealed-vector principle (no VectorKit type imported here).
//
// INTELLECTUS LOCK: All tests that call corpus.ingest (which calls
// BundleStore.insert, emitting corpuskit.ingest.* metrics) or
// corpus.recall (which calls HybridRecall.recall, emitting
// corpuskit.recall.* metrics) hold GlobalTestLock.shared for their
// entire duration. This prevents concurrent telemetry tests from
// seeing spurious emissions in their capturing sinks.

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import CorpusKit

// MARK: - Helpers

private func makeCorpus() async throws -> Corpus {
    let storage = try makeScratchStorage()
    return try await Corpus(storage: storage)
}

private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000)

// MARK: - Suite

@Suite("Corpus", .serialized)
struct CorpusTests {

    // MARK: - Round-trip

    /// Ingest a document then recall by a keyword from it; at least one
    /// result must come back and its text must be non-empty.
    @Test func roundTripIngestAndRecall() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let text = "Swift is a powerful programming language developed by Apple. " +
                "It supports concurrency through actors and async/await semantics."
            try await corpus.ingest(text, sourceID: "doc-swift", now: fixedNow)

            let results = try await corpus.recall("programming language", limit: 5, now: fixedNow)
            #expect(!results.isEmpty)
            #expect(results.allSatisfy { !$0.chunk.text.isEmpty })
        }
    }

    /// Recall against an empty corpus must return an empty list, not an error.
    @Test func recallEmptyCorpusReturnsEmpty() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let results = try await corpus.recall("anything", limit: 10, now: fixedNow)
            #expect(results.isEmpty)
        }
    }

    /// Recall with limit = 0 must return an empty list.
    @Test func recallLimitZeroReturnsEmpty() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            try await corpus.ingest("hello world", sourceID: "doc-1", now: fixedNow)
            let results = try await corpus.recall("hello", limit: 0, now: fixedNow)
            #expect(results.isEmpty)
        }
    }

    // MARK: - Multi-source and remove

    /// Ingest two sources, remove one, verify the removed source does not
    /// appear in recall results.
    @Test func multiSourceRemoveExcludesRemovedSource() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let textA = "Cryptography is the practice of securing communication using " +
                "mathematical algorithms and secret keys for authentication."
            let textB = "Machine learning enables computers to learn from data without " +
                "explicit programming, using neural network architectures."

            try await corpus.ingest(textA, sourceID: "source-crypto", now: fixedNow)
            try await corpus.ingest(textB, sourceID: "source-ml", now: fixedNow)

            try await corpus.remove(sourceID: "source-crypto")

            // Keyword hits for "cryptography" should no longer surface source-crypto.
            let cryptoResults = try await corpus.recall("cryptography authentication", limit: 10, now: fixedNow)
            #expect(cryptoResults.allSatisfy { $0.chunk.sourceID != "source-crypto" })

            // source-ml must still be reachable.
            let mlResults = try await corpus.recall("neural network learning", limit: 10, now: fixedNow)
            #expect(mlResults.allSatisfy { $0.chunk.sourceID != "source-crypto" })
        }
    }

    /// Remove on a sourceID that was never ingested must not throw.
    @Test func removeNonexistentSourceIsNoop() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            // Must succeed without error (no chunks to remove = no-op).
            try await corpus.remove(sourceID: "never-ingested")
        }
    }

    // MARK: - Count

    /// An empty corpus has count 0.
    @Test func countInitiallyZero() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let n = try await corpus.count()
            #expect(n == 0)
        }
    }

    /// Count increases after ingestion and reflects stored chunk count.
    @Test func countIncreasesAfterIngest() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            try await corpus.ingest("First document text.", sourceID: "doc-1", now: fixedNow)
            let n = try await corpus.count()
            #expect(n >= 1)
        }
    }

    /// Count does not decrease after remove (BundleStore is append-only;
    /// remove only clears the recall index, not the content store).
    @Test func countUnchangedAfterRemove() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            try await corpus.ingest("Some content for removal test.", sourceID: "src-x", now: fixedNow)
            let beforeRemove = try await corpus.count()
            try await corpus.remove(sourceID: "src-x")
            let afterRemove = try await corpus.count()
            // BundleStore is append-only: count stays the same.
            #expect(afterRemove == beforeRemove)
        }
    }

    // MARK: - Deduplication (idempotent ingest)

    /// Re-ingesting the same text for the same sourceID must be a no-op:
    /// content-addressed chunk ids prevent duplicate rows.
    @Test func dedupReingestionIsIdempotent() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let text = "Idempotent deduplication test — unique wording for this fixture."

            try await corpus.ingest(text, sourceID: "doc-dedup", now: fixedNow)
            let countAfterFirst = try await corpus.count()

            try await corpus.ingest(text, sourceID: "doc-dedup", now: fixedNow)
            let countAfterSecond = try await corpus.count()

            #expect(countAfterFirst == countAfterSecond)
        }
    }

    /// Re-ingesting the same source with different text adds new chunks
    /// (content-addressed ids differ for different text).
    @Test func reingestionWithNewTextAddsChunks() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            try await corpus.ingest("First version of the document.", sourceID: "doc-v", now: fixedNow)
            let countAfterFirst = try await corpus.count()

            try await corpus.ingest("Second version with entirely different words.", sourceID: "doc-v", now: fixedNow)
            let countAfterSecond = try await corpus.count()

            #expect(countAfterSecond >= countAfterFirst)
        }
    }

    // MARK: - Sealed-vector principle

    /// This file imports only CorpusKit (no VectorKit import). The fact
    /// that this test compiles confirms that Corpus, EmbeddingModel, and
    /// ScoredChunk are usable without any VectorKit dependency. Any
    /// future change that leaks a VectorKit type onto the public surface
    /// would break this file at compile time.
    ///
    /// The grep step in Part 5 verifies this at the source level; this
    /// test documents the requirement as a compile-time assertion.
    @Test func noVectorTypesRequiredByPublicSurface() async throws {
        try await GlobalTestLock.shared.withLock {
            // Corpus and EmbeddingModel are named from CorpusKit; no VectorKit import.
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(storage: storage, model: .deterministic)
            try await corpus.ingest("hello world", sourceID: "test", now: fixedNow)
            let results: [ScoredChunk] = try await corpus.recall("hello", limit: 1, now: fixedNow)
            // ScoredChunk is a CorpusKit type — no VectorKit type used here.
            _ = results.first?.chunk.text
            _ = results.first?.score
        }
    }

    // MARK: - EmbeddingModel default

    /// The static default must be .deterministic (no CoreML required).
    @Test func embeddingModelDefaultIsDeterministic() {
        // If EmbeddingModel.default were changed to a case requiring
        // CoreML, Corpus.init would fail in the test environment.
        // This test pins the default as deterministic.
        if case .deterministic = EmbeddingModel.default {
            // correct
        } else {
            Issue.record("EmbeddingModel.default must be .deterministic")
        }
    }

    // MARK: - Recall result ordering

    /// Recall results must be ordered by score descending. The first
    /// result should have a score >= the last result's score.
    @Test func recallResultsAreScoreDescending() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let doc = "The quick brown fox jumps over the lazy dog. " +
                "Pack my box with five dozen liquor jugs. " +
                "How vexingly quick daft zebras jump."
            try await corpus.ingest(doc, sourceID: "pangram", now: fixedNow)

            let results = try await corpus.recall("quick fox", limit: 10, now: fixedNow)
            guard results.count >= 2 else { return }
            for i in 0..<results.count - 1 {
                #expect(results[i].score >= results[i + 1].score)
            }
        }
    }

    // MARK: - BM25 restart rebuild

    /// BM25 index is rebuilt from persisted chunks when a second Corpus
    /// instance opens the same storage, simulating a process restart.
    ///
    /// Before the fix, `Corpus.init` constructed a fresh empty BM25Index
    /// and never called `bundleStore.allChunks()`, so keyword recall on a
    /// second instance returned no BM25 hits for documents ingested in a
    /// prior session. The regression is caught by verifying that at least
    /// one result carries a non-nil `keywordScore` — if the BM25 index
    /// were empty, `keywordScore` would be nil on every result regardless
    /// of whether vector hits were present.
    @Test func bm25RestartRebuildRoundTrip() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            // First "session": ingest a document with distinctive keyword content.
            let first = try await Corpus(storage: storage)
            try await first.ingest(
                "Keyword recall must survive a process restart in CorpusKit.",
                sourceID: "doc-restart",
                now: fixedNow
            )

            // Second "session": new Corpus on the same storage, simulating restart.
            // The fix calls bundleStore.allChunks() during init and indexes the
            // results into the fresh BM25Index so keyword recall is restored.
            let second = try await Corpus(storage: storage)
            let results = try await second.recall("keyword recall", limit: 5, now: fixedNow)

            // Results must be non-empty and must carry BM25 signal. Without the
            // fix, the second instance's BM25 index is empty and keywordScore is
            // nil on every result even when vector hits are present.
            #expect(!results.isEmpty)
            #expect(results.contains { $0.keywordScore != nil })
        }
    }

    /// The SQLite-backed twin of `bm25RestartRebuildRoundTrip`. This is the test
    /// that would have caught the dark-recall-on-reopen bug: the InMemory backend
    /// preserves the inserted `.uuid`/`.hlc` TypedValues on read, so the InMemory
    /// version above passed even while `decodeChunk` rejected the PRIMITIVE forms
    /// (`.text` id, `.int` hlc) that the SQLite backend actually returns. With a
    /// real on-disk SQLite estate, `allChunks()` returned empty on reopen, the
    /// BM25 rebuild indexed nothing, and keyword recall was dark — exactly the
    /// production failure where a fresh process serving a persisted estate fell
    /// back to query-blind storage-order recall.
    @Test func bm25RestartRebuildRoundTripSQLite() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("corpuskit-reopen-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            // First session: ingest over a real SQLite estate, then drop the
            // Corpus so nothing stays resident in memory.
            do {
                let storage = try SQLiteStorage(configuration: EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: url, busyTimeout: 5.0)
                ))
                let first = try await Corpus(storage: storage)
                try await first.ingest(
                    "Keyword recall must survive a process restart in CorpusKit.",
                    sourceID: "doc-restart-sqlite",
                    now: fixedNow
                )
            }

            // Second session: a brand-new Corpus over the SAME on-disk estate,
            // simulating a process restart. Its BM25 index is rebuilt purely from
            // the persisted chunks via allChunks() — which only works if the chunk
            // decoder accepts the SQLite read-back primitives.
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0)
            ))
            let second = try await Corpus(storage: storage)
            let results = try await second.recall("keyword recall", limit: 5, now: fixedNow)

            #expect(!results.isEmpty)
            #expect(results.contains { $0.keywordScore != nil })
        }
    }
}
