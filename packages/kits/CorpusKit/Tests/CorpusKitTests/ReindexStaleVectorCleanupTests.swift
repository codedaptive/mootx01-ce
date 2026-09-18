// ReindexStaleVectorCleanupTests.swift
//
// Finding B (MEDIUM) regression coverage — CT-01 wave.
//
// `Corpus.reindex(now:)` Phase 2 skips non-trainable slots (FDC,
// deterministic, NL) because their vectors are basis-invariant and
// re-embedding them is wasted work. The bug: the skip also bypassed the
// stale-vector cleanup that removes rows belonging to removed sources.
// After the fix, non-trainable slots prune vector rows for removed sources
// without re-embedding anything.
//
// Test strategy: approach (b) — direct contract test. After a source is
// removed its chunks still live in the append-only chunks table. We plant a
// stale vector row for a removed source's chunk under the non-trainable
// (deterministic) modelID via the VectorStore public API, then call
// reindex() and assert the stale row is gone. This tests the reindex
// contract head-on: reindex is the REPAIR operation and must be self-
// sufficient regardless of how residue arose (slot-set change across opens,
// direct write, etc.).

import Testing
import Foundation
@testable import CorpusKit
import CorpusKitProviders
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import SynapseKit

@Suite("ReindexStaleVectorCleanup", .serialized)
struct ReindexStaleVectorCleanupTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-stale-vec-\(UUID().uuidString).sqlite3")
    }

    private func makeStorage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    /// All vectors-table rows as "model|item|index" → payload encoding.
    /// Used to detect presence/absence of specific rows.
    private func vectorRowKeys(_ storage: any Storage) async throws -> Set<String> {
        let rows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        var keys = Set<String>()
        for row in rows {
            guard case let .text(item)? = row["item_id"],
                  case let .int(vectorIndex)? = row["vector_index"],
                  case let .text(model)? = row["model_id"] else { continue }
            keys.insert("\(model)|\(item)|\(vectorIndex)")
        }
        return keys
    }

    // MARK: - Finding B regression test

    /// Verifies that `reindex` prunes stale non-trainable vector rows for
    /// removed sources.
    ///
    /// Contract test (approach b): a stale vector row is planted directly
    /// via VectorStore for a removed source's chunk under the deterministic
    /// (non-trainable) modelID. Before the fix, reindex() left this row
    /// intact. After the fix, it must be gone.
    ///
    /// The corpus holds ONE trainable slot (randomIndexing, freshBasisBlob ≠ nil)
    /// and ONE non-trainable slot (deterministic, freshBasisBlob = nil).
    /// reembedChunks covers the trainable slot; explicit cleanup in the
    /// non-trainable branch covers the deterministic slot.
    @Test func reindexPrunesNonTrainableVectorsForRemovedSources() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let storage = try makeStorage(at: url)

            // Build a two-slot corpus: one trainable, one non-trainable.
            let corpus = try await Corpus(
                storage: storage,
                models: [
                    .randomIndexing(provider: RandomIndexingProvider()),
                    .deterministic
                ])

            // Ingest two sources. Both get vectors under both modelIDs.
            try await corpus.ingest(
                "The quick brown fox jumps over the lazy dog.",
                sourceID: "kept-source",
                now: now)
            try await corpus.ingest(
                "A document about ships and navigation on the sea.",
                sourceID: "gone-source",
                now: now)

            // Remove gone-source. remove() cleans its vectors for all currently
            // held modelIDs (both trainable and non-trainable). After this step
            // there are no residual rows for gone-source — the stale state
            // we need for the contract test does not yet exist.
            try await corpus.remove(sourceID: "gone-source")

            // --- Plant a stale vector row (approach b) ---
            // Retrieve the chunk ID(s) for gone-source from the append-only
            // chunks table (the source was removed but its chunks still exist
            // in the chunks table, as required by the BundleStore contract).
            let bundleStore = BundleStore(storage: storage)
            let goneChunks = try await bundleStore.chunksForSource("gone-source")
            #expect(!goneChunks.isEmpty,
                    "gone-source must have at least one chunk in the append-only chunks table")

            let staleChunkID = goneChunks[0].id.uuidString

            // Plant a stale binary vector row for gone-source's chunk under the
            // deterministic (non-trainable) modelID. This simulates residue that
            // can arise when the slot set changes between corpus opens (the
            // production-reachable scenario described in the mission brief) or
            // via any other path that bypasses the remove() cleanup.
            let vs = VectorStore(
                storage: storage,
                sidecarURL: VectorStore.defaultSidecarURL(for: storage))
            let staleEngram = Engram(blocks: 0xAA, 0xBB, 0xCC, 0xDD)
            try await vs.addVector(
                itemID: staleChunkID,
                engram: staleEngram,
                modelID: "corpus-deterministic-v1",
                modelVersion: "1.0.0",
                filedAt: now)

            // Confirm the stale row exists before reindex.
            let beforeKeys = try await vectorRowKeys(storage)
            let staleKey = "corpus-deterministic-v1|\(staleChunkID)|0"
            #expect(beforeKeys.contains(staleKey),
                    "stale deterministic vector row must be present before reindex")

            // Trigger reindex. The fix must prune the stale deterministic row
            // in the non-trainable slot's cleanup pass, without re-embedding.
            try await corpus.reindex(now: now)

            let afterKeys = try await vectorRowKeys(storage)

            // PRIMARY ASSERTION: the stale non-trainable row for the removed
            // source must be gone after reindex.
            #expect(!afterKeys.contains(staleKey),
                    "reindex must prune stale non-trainable (deterministic) vector rows for removed sources")

            // CONTROL: the kept source must still have vector rows. The
            // trainable slot re-embeds kept-source's chunks via reembedChunks.
            // The non-trainable (deterministic) slot does NOT re-embed, so its
            // kept-source rows must survive unchanged from the initial ingest.
            let keptDeterministicRows = afterKeys.filter {
                $0.hasPrefix("corpus-deterministic-v1|") && !$0.contains(staleChunkID)
            }
            #expect(!keptDeterministicRows.isEmpty,
                    "kept-source deterministic vector rows must survive reindex")
        }
    }
}
