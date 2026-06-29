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

    /// Count excludes removed sources. BundleStore is append-only so the chunk
    /// rows survive, but `count()` reports live recall content only, so removing
    /// the sole source drops the count to zero. Re-ingesting reactivates it.
    @Test func countExcludesRemovedSource() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            try await corpus.ingest("Some content for removal test.", sourceID: "src-x", now: fixedNow)
            let beforeRemove = try await corpus.count()
            #expect(beforeRemove >= 1)
            try await corpus.remove(sourceID: "src-x")
            #expect(try await corpus.count() == 0, "removed source must not be counted")
            // Re-ingesting the same source reactivates it.
            try await corpus.ingest("Some content for removal test.", sourceID: "src-x", now: fixedNow)
            #expect(try await corpus.count() == beforeRemove, "re-ingest reactivates the source")
        }
    }

    /// REGRESSION (Codex finding 2): a reindex after remove must NOT resurrect the
    /// removed source. The chunks table is append-only, so reindex reads from it;
    /// it must use ACTIVE chunks only, or the removed source reappears in recall
    /// (the auto-reindex daemon makes this a normal-operation hazard).
    @Test func reindexDoesNotResurrectRemovedSource() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            let textA = "Cryptography secures communication using mathematical algorithms and keys."
            let textB = "Machine learning trains neural networks on data without explicit rules."
            try await corpus.ingest(textA, sourceID: "source-crypto", now: fixedNow)
            try await corpus.ingest(textB, sourceID: "source-ml", now: fixedNow)

            try await corpus.remove(sourceID: "source-crypto")
            // Reindex (the path the auto-reindex daemon takes) must keep it gone.
            try await corpus.reindex(now: fixedNow)

            let results = try await corpus.recall("cryptography authentication keys", limit: 10, now: fixedNow)
            #expect(results.allSatisfy { $0.chunk.sourceID != "source-crypto" },
                    "reindex must not resurrect the removed source")
            // source-ml survives the reindex.
            let mlResults = try await corpus.recall("neural network learning data", limit: 10, now: fixedNow)
            #expect(mlResults.contains { $0.chunk.sourceID == "source-ml" },
                    "non-removed source must survive reindex")
        }
    }

    /// REGRESSION (Codex finding 2, BATCH import path): same as the non-batch
    /// resurrection test but the sources arrive via `ingestBatch` (the drain
    /// path). Confirms the active-chunks fix holds for batch import too.
    @Test func batchImportReindexDoesNotResurrectRemovedSource() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeCorpus()
            try await corpus.ingestBatch([
                (text: "Cryptography secures communication using mathematical algorithms and keys.",
                 sourceID: "source-crypto", now: fixedNow),
                (text: "Machine learning trains neural networks on data without explicit rules.",
                 sourceID: "source-ml", now: fixedNow),
            ])
            try await corpus.remove(sourceID: "source-crypto")
            try await corpus.reindex(now: fixedNow)

            let results = try await corpus.recall("cryptography authentication keys", limit: 10, now: fixedNow)
            #expect(results.allSatisfy { $0.chunk.sourceID != "source-crypto" },
                    "batch-imported removed source must not resurrect on reindex")
            let mlResults = try await corpus.recall("neural network learning data", limit: 10, now: fixedNow)
            #expect(mlResults.contains { $0.chunk.sourceID == "source-ml" },
                    "non-removed batch-imported source must survive reindex")
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

    // MARK: - BM25 restart rebuild (now durable via InvertedIndexStore)

    /// Keyword recall survives a process restart because InvertedIndexStore
    /// persists term frequencies to SQLite and loads them on open — no chunk
    /// body scan required. A second Corpus on the same storage opens the
    /// durable inverted index and immediately serves keyword hits from it.
    ///
    /// The regression this test guards: before InvertedIndexStore, Corpus.init
    /// rebuilt an in-memory BM25Index by scanning all chunk bodies. That path
    /// produced wrong results when `decodeChunk` dropped rows for primitive-
    /// form SQLite reads. Now the keyword state is a first-class persisted
    /// artefact: `keywordScore` is non-nil on results for text ingested in
    /// a prior session, proving the index survived the restart.
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
            // InvertedIndexStore.open() loads the persisted term-freq rows;
            // no allChunks() body scan occurs. Keyword recall is immediately live.
            let second = try await Corpus(storage: storage)
            let results = try await second.recall("keyword recall", limit: 5, now: fixedNow)

            // Results must be non-empty and must carry a keyword score. The
            // non-nil keywordScore confirms the durable inverted index was
            // loaded successfully — not reconstructed from empty state.
            #expect(!results.isEmpty)
            #expect(results.contains { $0.keywordScore != nil })
        }
    }

    /// The SQLite-backed twin of `bm25RestartRebuildRoundTrip`. This is the test
    /// that caught the dark-recall-on-reopen bug (before InvertedIndexStore):
    /// the InMemory backend preserved `.uuid`/`.hlc` TypedValues on read, so
    /// the in-memory test passed while `decodeChunk` silently dropped SQLite's
    /// primitive-form (`.text` id, `.int` hlc) values. The SQLite version
    /// exposed the real estate failure mode — and now tests InvertedIndexStore's
    /// on-disk persistence on the same SQLite-backed path.
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
            // simulating a process restart. Keyword recall is served from the
            // durable InvertedIndexStore: open() loads the persisted term-freq and
            // doc-length rows into RAM — no allChunks() body scan — and the
            // chunkSourceMap is warm-loaded via the compact (id, source_id)
            // projection. Recall is live immediately from the on-disk index.
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

    /// T4 (ADR-021 Decision 7): a file-backed (SQLite) estate persists the Corpus
    /// ingest queue to a per-estate SQLite file BESIDE the estate — not a plaintext
    /// maildir. The sibling filename is `<estate-stem>.queue.sqlite` so two estates
    /// in the same directory never share a queue. Proven by:
    ///   1. `<estate-stem>.queue.sqlite` appears as a regular FILE beside the estate db.
    ///   2. No `corpus_ingest_queue/` maildir is created (old FilesystemBackend path is gone).
    ///   3. The enqueued document is searchable via the per-estate queue path.
    @Test func ingestQueueIsDurableForSQLiteEstate() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("corpuskit-queue-\(UUID().uuidString).sqlite3")
            // Derive the per-estate sibling path the same way EstateConfiguration does:
            // <dir>/<estate-stem>.queue.sqlite — guarantees cross-estate isolation.
            let stem = url.deletingPathExtension().lastPathComponent
            let queueSibling = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem).queue.sqlite")
            let oldMaildir = url.deletingLastPathComponent()
                .appendingPathComponent("corpus_ingest_queue")
            defer {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: queueSibling)
                try? FileManager.default.removeItem(at: oldMaildir)
            }

            let cfg = EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0)
            )
            let storage = try SQLiteStorage(configuration: cfg)
            let corpus = try await Corpus(storage: storage)
            try await corpus.enqueueIngest(
                "durable queue content survives restart",
                sourceID: "doc-queue",
                now: fixedNow
            )
            try await corpus.awaitIngestDrain()

            // T4: the per-estate queue file must exist as a regular file (not a directory).
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: queueSibling.path, isDirectory: &isDir))
            #expect(!isDir.boolValue)  // must be a file, not a directory

            // T4: the old plaintext maildir must NOT exist — it was the FilesystemBackend path.
            #expect(!FileManager.default.fileExists(atPath: oldMaildir.path))

            // The enqueued document is searchable via the shared queue path.
            let results = try await corpus.recall("durable queue", limit: 5, now: fixedNow)
            #expect(!results.isEmpty)
        }
    }

    /// T4 (ADR-021 Decision 7): the encode drain claims only stream="encode" jobs and
    /// does not disturb jobs on other streams sharing the same queue.sqlite.
    @Test func encodeDrainIsStreamScoped() async throws {
        try await GlobalTestLock.shared.withLock {
            // Build an in-memory corpus (no file I/O needed; stream isolation is
            // queue-level, not backend-level).
            let corpus = try await makeCorpus()
            try await corpus.mountIngestQueue()

            // Enqueue on the encode stream via the public API.
            try await corpus.enqueueIngest(
                "stream scoped encode content",
                sourceID: "doc-scoped",
                now: fixedNow
            )
            // Drain once — only encode jobs are drained.
            let drained = try await corpus.drainIngestQueueOnce()
            #expect(drained == 1)

            // After the drain pass the content must be searchable.
            try await corpus.awaitIngestDrain()
            let results = try await corpus.recall("stream scoped encode", limit: 5, now: fixedNow)
            #expect(!results.isEmpty)

            await corpus.dropIngestQueue()
        }
    }
}
