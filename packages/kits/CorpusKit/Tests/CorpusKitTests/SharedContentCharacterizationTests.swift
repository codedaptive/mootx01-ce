// SharedContentCharacterizationTests.swift
//
// Characterization of the CURRENT (pre-cutover) Corpus engine
// (GLK shared-content 1.1, P0).
//
// These tests document — as executable fact — exactly where today's engine
// creates the second content projection the 1.1 mission removes:
//
//   1. ingest copies verbatim source text into `chunks` rows;
//   2. the `Chunker` splits documents on the default path;
//   3. every BM25 posting and vector row is keyed by CHUNK UUID, not by
//      the source (Drawer) ID, and recall must translate back through
//      `sourceIDs(forChunkIDs:)`;
//   4. the ingest queue payload carries verbatim content;
//   5. `destroyRecallIndex` deletes ALL vector rows including rows of
//      model IDs this corpus never wrote (the broad-deletion hazard the
//      representation manifest closes in P5).
//
// When later phases land, the tests marked CURRENT-BEHAVIOR are expected
// to be updated or retired WITH the phase that changes the behavior —
// each documents a defect the mission corrects, not a contract to keep.

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import Testing
import VectorKit
import EngramLib

@testable import CorpusKit

@Suite("SharedContentCharacterization", .serialized)
struct SharedContentCharacterizationTests {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCorpusWithStorage() async throws -> (Corpus, any Storage) {
        let storage = try makeScratchStorage()
        let corpus = try await Corpus(storage: storage)
        return (corpus, storage)
    }

    // MARK: - 1. Verbatim text copy

    @Test func ingestCopiesVerbatimTextIntoChunkRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let (corpus, storage) = try await makeCorpusWithStorage()
            let text = "The drawer is the canonical content row in a GLK estate."
            try await corpus.ingest(text, sourceID: "drawer-1", now: fixedNow)

            let rows = try await storage.rowStore.query(
                table: "chunks", where: nil, orderBy: [], limit: nil, offset: nil)
            #expect(rows.count == 1)
            guard case let .text(storedText)? = rows.first?["text"] else {
                Issue.record("chunk row has no text column")
                return
            }
            // CURRENT-BEHAVIOR: the verbatim source text is duplicated into
            // the chunks table — the second content projection.
            #expect(storedText == text)

            // The copy is rooted through corpus_metadata (a per-source
            // Merkle root over the COPIED text, parallel to the Drawer root).
            let metadataCount = try await storage.rowStore.count(
                table: "corpus_metadata", where: nil)
            #expect(metadataCount == 1)
        }
    }

    // MARK: - 2. Chunker on the default path

    @Test func chunkerSplitsLongDocumentsIntoChunkRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let (corpus, storage) = try await makeCorpusWithStorage()
            // ~4000 chars — far past the 800-char chunk target, so the
            // default path MUST invoke the Chunker and produce several rows.
            let sentence = "Chunking splits long documents into overlapping windows. "
            let text = String(repeating: sentence, count: 70)
            try await corpus.ingest(text, sourceID: "drawer-long", now: fixedNow)

            let rows = try await storage.rowStore.query(
                table: "chunks", where: nil, orderBy: [], limit: nil, offset: nil)
            // CURRENT-BEHAVIOR: passage production is unconditional — there
            // is no whole-content mode.
            #expect(rows.count > 1)

            var offsets: [Int64] = []
            for row in rows {
                if case let .int(offset)? = row["start_offset"] { offsets.append(offset) }
            }
            #expect(offsets.contains(0))
            #expect(Set(offsets).count == offsets.count)
        }
    }

    // MARK: - 3. Chunk-UUID identity lane + translation join

    @Test func recallIndexKeysAreChunkUUIDsRequiringTranslation() async throws {
        try await GlobalTestLock.shared.withLock {
            let (corpus, storage) = try await makeCorpusWithStorage()
            let sourceID = "drawer-identity"
            try await corpus.ingest(
                "Identity crosses every lane as the drawer id.",
                sourceID: sourceID, now: fixedNow)

            // BM25 postings are keyed by chunk UUID, not the source ID.
            let doclenRows = try await storage.rowStore.query(
                table: "iix_doclens", where: nil, orderBy: [], limit: nil, offset: nil)
            #expect(!doclenRows.isEmpty)
            var chunkIDs: [UUID] = []
            for row in doclenRows {
                guard case let .text(itemID)? = row["item_id"] else { continue }
                #expect(itemID != sourceID)
                if let uuid = UUID(uuidString: itemID) { chunkIDs.append(uuid) }
            }
            #expect(chunkIDs.count == doclenRows.count,
                    "every BM25 item key is a chunk UUID")

            // Vector rows are keyed by the same chunk UUIDs.
            let vectorRows = try await storage.rowStore.query(
                table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
            #expect(!vectorRows.isEmpty)
            for row in vectorRows {
                guard case let .text(itemID)? = row["item_id"] else { continue }
                #expect(itemID != sourceID)
                #expect(UUID(uuidString: itemID) != nil)
            }

            // CURRENT-BEHAVIOR: hydrating a hit back to its Drawer requires
            // the chunk→source translation join.
            let translated = await corpus.sourceIDs(forChunkIDs: chunkIDs)
            #expect(Set(translated.values) == [sourceID])
        }
    }

    // MARK: - 4. Queue payload carries verbatim content

    @Test func ingestQueueJobCarriesVerbatimText() throws {
        let text = "Verbatim content should not ride the queue."
        let job = IngestJob(sourceID: "drawer-q", text: text, capturedAt: fixedNow)
        let encoded = try JSONEncoder().encode(job)
        let payload = String(decoding: encoded, as: UTF8.self)
        // CURRENT-BEHAVIOR: the serialized queue job embeds the full text —
        // the 1.1 contract replaces this with ID/revision/digest/cursor.
        #expect(payload.contains("Verbatim content should not ride the queue."))
    }

    // MARK: - 5. Broad deletion in the lifecycle path

    @Test func destroyRecallIndexDeletesUnrelatedModelRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let (corpus, storage) = try await makeCorpusWithStorage()
            try await corpus.ingest(
                "Corpus content whose derived rows may be destroyed.",
                sourceID: "drawer-own", now: fixedNow)

            // Seed a vector row under a model ID this corpus NEVER wrote —
            // standing in for another lane's representation in the shared
            // estate storage.
            let unrelated = Engram(blocks: 0x1111, 0x2222, 0x3333, 0x4444)
            try await corpus.sharedVectorStore.addVector(
                itemID: "drawer-own",
                engram: unrelated,
                modelID: "unrelated-lane-v1",
                modelVersion: "1.0.0",
                filedAt: fixedNow)

            try await corpus.destroyRecallIndex()

            // CURRENT-BEHAVIOR: the teardown is unscoped — the unrelated
            // lane's row is destroyed with the corpus's own rows. P5 makes
            // this ownership-aware via the representation manifest.
            let survivors = try await storage.rowStore.count(table: "vectors", where: nil)
            #expect(survivors == 0)
        }
    }

    // MARK: - Inventory baseline over a deterministic build

    @Test func inventoryBaselineIdentifiesEveryDerivedTable() async throws {
        try await GlobalTestLock.shared.withLock {
            let (corpus, storage) = try await makeCorpusWithStorage()
            try await corpus.ingest("Alpha content for drawer one.",
                                    sourceID: "drawer-1", now: fixedNow)
            try await corpus.ingest("Beta content for drawer two.",
                                    sourceID: "drawer-2", now: fixedNow)

            // The pre-cutover estate surface the migration must account for:
            // canonical copy (chunks + corpus_metadata), BM25 lane
            // (iix_termfreqs + iix_doclens), vector lane (vectors), and the
            // sidecar stores. Row counts pin which tables hold state after a
            // plain double-ingest.
            let inventory = try await DatabaseInventory.capture(
                storage: storage,
                tables: ["chunks", "corpus_metadata", "iix_termfreqs",
                         "iix_doclens", "vectors", "removed_sources"],
                // hlc + created_at are wall-clock-stamped; exclude so this
                // baseline is comparable across capture instants.
                excludingColumns: ["chunks": ["hlc", "created_at"]])
            let byTable = Dictionary(uniqueKeysWithValues: inventory.map { ($0.table, $0) })
            #expect(byTable["chunks"]?.rowCount == 2)
            #expect(byTable["corpus_metadata"]?.rowCount == 2)
            #expect(byTable["iix_doclens"]?.rowCount == 2)
            #expect((byTable["iix_termfreqs"]?.rowCount ?? 0) > 0)
            // Binary engram row per chunk; the deterministic provider also
            // stores a float row per chunk (its float lane is live).
            #expect(byTable["vectors"]?.rowCount == 4)
            #expect(byTable["removed_sources"]?.rowCount == 0)

            // Determinism: an identical build in a fresh estate produces the
            // SAME folds for the content-addressed tables (timestamps
            // excluded) — the property migration baselines rely on.
            let (corpus2, storage2) = try await makeCorpusWithStorage()
            try await corpus2.ingest("Alpha content for drawer one.",
                                     sourceID: "drawer-1", now: fixedNow)
            try await corpus2.ingest("Beta content for drawer two.",
                                     sourceID: "drawer-2", now: fixedNow)
            let inventory2 = try await DatabaseInventory.capture(
                storage: storage2,
                tables: ["chunks", "iix_termfreqs", "iix_doclens"],
                excludingColumns: ["chunks": ["hlc", "created_at"]])
            let byTable2 = Dictionary(uniqueKeysWithValues: inventory2.map { ($0.table, $0) })
            #expect(byTable2["chunks"]?.contentFold == byTable["chunks"]?.contentFold)
            #expect(byTable2["iix_termfreqs"]?.contentFold == byTable["iix_termfreqs"]?.contentFold)
            #expect(byTable2["iix_doclens"]?.contentFold == byTable["iix_doclens"]?.contentFold)
        }
    }
}
