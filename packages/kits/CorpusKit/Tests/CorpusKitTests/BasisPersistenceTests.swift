// BasisPersistenceTests.swift
//
// Mission 6a-ii-β: basis-persistence table + corpus training lifecycle
// (single provider).
//
// ## What is tested
//
//   1. BasisStore round-trip: upsert → load returns the same row; upsert is an
//      UPSERT (one row per (modelID, modelVersion), retrain replaces in place);
//      deleteAll wipes the table.
//   2. reindex on a trainable Corpus: trains + persists a basis, re-embeds.
//   3. First-ingest auto-train: ingesting into a fresh trainable Corpus with no
//      basis trains+persists on the first ingest; a second ingest does NOT
//      retrain (fold-in path, basis row unchanged).
//   4. Load-on-open: after reindex + close, reopening a trainable Corpus loads
//      the persisted basis (dense lane trained-ready) and serves embeddings
//      identical to the pre-close provider.
//   5. Lifecycle: destroyRecallIndex wipes basis rows (no orphans); a
//      non-trainable Corpus persists no basis.
//
// The trainable provider is RI (RandomIndexingProvider) — the simplest
// distributional provider with no finalize step. The fixed corpus is the α RI
// canonical corpus so the trained state is the established one. Each fixture
// doc is ingested as its own sourceID; a short single-sentence doc yields one
// chunk whose text equals the doc, so the chunk texts reindex trains on equal
// the α corpus exactly.
//
// ## Test isolation
//
// Corpus ingest/reindex emit corpuskit.* metrics through the global Intellectus
// sink. CorpusKitTelemetryTests asserts an EXACT corpuskit.* count while it has
// monitoring enabled with a capturing sink installed globally. Every Corpus-op
// test suite therefore serialises against that window via GlobalTestLock; these
// tests do the same (each body runs under GlobalTestLock.shared.withLock) so a
// basis-lifecycle emission cannot leak into the telemetry test's captured count.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import VectorKit

@Suite("BasisPersistence", .serialized)
struct BasisPersistenceTests {

    // MARK: - Fixed corpus (α RI canonical corpus, as raw single-chunk docs)

    /// The five α RI docs as raw texts. defaultKeywordTokens tokenizes each back
    /// to the α token arrays, so training on these reproduces the α basis.
    private let riDocs: [String] = [
        "car engine drive road vehicle",
        "vehicle road transport car fuel",
        "engine fuel combustion power car",
        "dog bark run fetch animal",
        "animal run cat dog pet"
    ]

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A unique on-disk SQLite file URL. Tests run on the REAL backend (SQLite)
    /// so the persist→reopen path exercises genuine primitive-form read-back
    /// (the .text/.int/.blob/.timestamp forms SQLite hands back), not the
    /// in-RAM backend that preserves semantic TypedValues and hides reopen bugs.
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-basis-\(UUID().uuidString).sqlite3")
    }

    /// Open a fresh SQLiteStorage over `url`. Constructing a SECOND storage over
    /// the SAME url reopens the persisted file — the load-on-open path.
    private func storage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    private func freshRICorpus(_ storage: any Storage) async throws -> Corpus {
        try await Corpus(storage: storage, model: .randomIndexing(provider: RandomIndexingProvider()))
    }

    /// The shared alpha fixture pins the historical 1.0 provider envelope.
    /// Production defaults are 1.1 so persisted pre-correction tokenizer
    /// generations cannot be mistaken for current ones.
    private func legacyRICorpus(_ storage: any Storage) async throws -> Corpus {
        try await Corpus(
            storage: storage,
            model: .randomIndexing(provider: RandomIndexingProvider(modelVersion: "1.0.0")))
    }

    // MARK: - §1 BasisStore round-trip

    @Test("BasisStore upsert → load round-trips the row")
    func basisStoreRoundTrip() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            try await storage.migrate(to: BasisStore.schemaDeclaration)
            let store = BasisStore(storage: storage)

            let row = PersistedBasis(
                modelID: "random-indexing-v1",
                modelVersion: "1.1.0",
                basis: Data([1, 2, 3, 4, 5]),
                trainedAt: now,
                trainedChunkCount: 7
            )
            try await store.upsert(row)
            let loaded = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
            #expect(loaded == row)
            // A different key returns nil.
            let miss = try await store.load(modelID: "corpus-ppmi-v1", modelVersion: "1.0.0")
            #expect(miss == nil)
        }
    }

    @Test("BasisStore upsert replaces in place — one row per provider key")
    func basisStoreUpsertReplaces() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            try await storage.migrate(to: BasisStore.schemaDeclaration)
            let store = BasisStore(storage: storage)

            try await store.upsert(PersistedBasis(
                modelID: "m", modelVersion: "1", basis: Data([1]),
                trainedAt: now, trainedChunkCount: 1))
            try await store.upsert(PersistedBasis(
                modelID: "m", modelVersion: "1", basis: Data([2, 2]),
                trainedAt: now.addingTimeInterval(60), trainedChunkCount: 3))

            let loaded = try await store.load(modelID: "m", modelVersion: "1")
            #expect(loaded?.basis == Data([2, 2]))
            #expect(loaded?.trainedChunkCount == 3)
        }
    }

    @Test("BasisStore deleteAll wipes every row")
    func basisStoreDeleteAll() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            try await storage.migrate(to: BasisStore.schemaDeclaration)
            let store = BasisStore(storage: storage)
            try await store.upsert(PersistedBasis(
                modelID: "m", modelVersion: "1", basis: Data([1]),
                trainedAt: now, trainedChunkCount: 1))
            try await store.deleteAll()
            let loaded = try await store.load(modelID: "m", modelVersion: "1")
            #expect(loaded == nil)
        }
    }

    // MARK: - §2 reindex persists a basis

    @Test("reindex on a trainable Corpus persists a basis keyed by the provider")
    func reindexPersistsBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            for (i, doc) in riDocs.enumerated() {
                try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
            }
            try await corpus.reindex(now: now)

            // The basis row exists for the RI provider key.
            let store = BasisStore(storage: storage)
            let loaded = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
            #expect(loaded != nil)
            #expect(loaded?.trainedChunkCount == riDocs.count)
        }
    }

    // MARK: - §3 first-ingest auto-train

    @Test("first ingest into a fresh trainable Corpus auto-trains and persists")
    func firstIngestAutoTrains() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            let store = BasisStore(storage: storage)

            // No basis before the first ingest.
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0") == nil)

            try await corpus.ingest(riDocs[0], sourceID: "doc-0", now: now)

            // A basis now exists (auto-trained on the first-ingest snapshot).
            let afterFirst = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
            #expect(afterFirst != nil)
            let countAfterFirst = afterFirst?.trainedChunkCount

            // A SECOND ingest must NOT retrain: the basis row (chunk count) is
            // unchanged — the fold-in path embeds the new chunk on the frozen basis.
            try await corpus.ingest(riDocs[1], sourceID: "doc-1", now: now.addingTimeInterval(60))
            let afterSecond = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
            #expect(afterSecond?.trainedChunkCount == countAfterFirst)
        }
    }

    // MARK: - §4 load-on-open

    @Test("reopen loads the persisted basis and serves identical embeddings")
    func reopenLoadsBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            let probe = "car engine"

            // Build, ingest, reindex, capture the trained embedding.
            let before: [Float]
            do {
                let corpus = try await freshRICorpus(try storage(at: url))
                for (i, doc) in riDocs.enumerated() {
                    try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
                }
                try await corpus.reindex(now: now)
                before = try await corpus.embedFloat(probe)
                #expect(!before.isEmpty)
            }

            // Reopen over a SECOND SQLiteStorage on the SAME on-disk file — the
            // genuine restart path. load-on-open reconstructs the trained provider
            // from the persisted basis. A fresh RI provider with no basis load would
            // embed differently (untrained), so identical bits prove the basis was
            // loaded and applied.
            let reopened = try await freshRICorpus(try storage(at: url))
            let after = try await reopened.embedFloat(probe)
            #expect(after.map(\.bitPattern) == before.map(\.bitPattern),
                    "reopened corpus must serve the same trained embedding as before close")
        }
    }

    // MARK: - §5 lifecycle

    @Test("destroyRecallIndex wipes the persisted basis (no orphans)")
    func destroyWipesBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            for (i, doc) in riDocs.enumerated() {
                try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
            }
            try await corpus.reindex(now: now)

            let store = BasisStore(storage: storage)
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0") != nil)

            try await corpus.destroyRecallIndex()
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0") == nil)
        }
    }

    @Test("a non-trainable Corpus persists no basis on reindex")
    func nonTrainablePersistsNoBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            // .deterministic is not trainable.
            let corpus = try await Corpus(storage: storage, model: .deterministic)
            try await corpus.ingest("car engine drive", sourceID: "doc-0", now: now)
            try await corpus.reindex(now: now)

            let store = BasisStore(storage: storage)
            // No basis under the deterministic provider's key.
            let loaded = try await store.load(modelID: "corpus-deterministic-v1", modelVersion: "1.0.0")
            #expect(loaded == nil)
        }
    }

    // MARK: - §6 cross-port conformance: persist → reopen → embed

    /// The α RI canonical fixture, decoded for the conformance anchor: the
    /// trained-basis blob and the per-probe embedding bit patterns. Swift is the
    /// canonical source for the α fixture; this test proves the β
    /// persist→reopen→embed path reproduces exactly that canonical state, and
    /// the Rust leg (corpus_basis_persistence_tests.rs) asserts byte/bit-identity
    /// against the SAME shared fixture — so the full lifecycle is cross-port
    /// deterministic.
    private struct RIBasisFixture: Decodable {
        struct Embedding: Decodable {
            let text: String
            let floatBits: [UInt32]
        }
        let blobBase64: String
        let embeddings: [Embedding]
    }

    @Test("CONFORMANCE: ingest → reindex → reopen → embed matches the α canonical fixture")
    func crossPortPersistReopenEmbed() async throws {
        try await GlobalTestLock.shared.withLock {
            // Load the shared α RI fixture (Swift-canonical, also embedded by the
            // Rust leg). It pins the trained-basis blob and the "car engine"
            // embedding bit patterns the reopened corpus must reproduce.
            let data = try Data(contentsOf: sharedVectorsURL(for: "ri_basis_blob.json"))
            let fixture = try JSONDecoder().decode(RIBasisFixture.self, from: data)
            let expectedBlob = Data(base64Encoded: fixture.blobBase64)!
            let probe = "car engine"
            guard let expectedEmbedding = fixture.embeddings.first(where: { $0.text == probe }) else {
                Issue.record("fixture must contain a 'car engine' embedding entry")
                return
            }

            let url = scratchURL()

            // Ingest the FIXED α corpus (one chunk per doc), reindex to train+persist
            // the basis on the chunk texts, then assert the persisted blob is the α
            // canonical blob byte-for-byte. The chunk texts trained on equal the α
            // corpus (single-sentence docs → one chunk each whose text == the doc),
            // so the trained state — and the blob — is the α canonical one.
            do {
                let corpus = try await legacyRICorpus(try storage(at: url))
                for (i, doc) in riDocs.enumerated() {
                    try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
                }
                try await corpus.reindex(now: now)

                let store = BasisStore(storage: try storage(at: url))
                let persisted = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0")
                #expect(persisted?.basis == expectedBlob,
                        "persisted basis blob must equal the α canonical blob byte-for-byte")
            }

            // Reopen over the SAME on-disk file — load-on-open reconstructs the
            // trained provider from the persisted basis. The reopened corpus's
            // embedding of the fixed probe must equal the α canonical bit patterns.
            // This proves persist → reopen → embed is cross-port deterministic.
            let reopened = try await legacyRICorpus(try storage(at: url))
            let after = try await reopened.embedFloat(probe)
            #expect(after.map(\.bitPattern) == expectedEmbedding.floatBits,
                    "reopened embedding must equal the α canonical 'car engine' bit patterns")
        }
    }

    // MARK: - §7 maintained counts wiring (incremental-counts change set, P3)

    private static let riModelID = "random-indexing-v1"
    private static let riModelVersion = "1.1.0"

    @Test("ingest persists maintained counts with a growing vocab/doc anchor")
    func ingestPersistsCounts() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            let counts = CorpusProviderCountsStore(storage: storage)

            // No counts row before any ingest.
            #expect(try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion) == nil)

            try await corpus.ingest(riDocs[0], sourceID: "doc-0", now: now)
            let a0 = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(a0 != nil, "ingest must persist a counts row")
            #expect(a0?.documentCount == 1)
            let vocab0 = a0?.vocabSize ?? 0
            #expect(vocab0 > 0)

            // A second ingest (new vocabulary) grows both anchors.
            try await corpus.ingest(riDocs[3], sourceID: "doc-3", now: now.addingTimeInterval(60))
            let a1 = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(a1?.documentCount == 2)
            #expect((a1?.vocabSize ?? 0) > vocab0, "new-vocabulary doc must grow the vocab anchor")
        }
    }

    @Test("reopen restores the maintained counts anchor (not reset to zero)")
    func reopenRestoresCounts() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            // Ingest the full corpus, capturing the persisted doc count.
            do {
                let corpus = try await freshRICorpus(try storage(at: url))
                for (i, doc) in riDocs.enumerated() {
                    try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
                }
            }
            let counts = CorpusProviderCountsStore(storage: try storage(at: url))
            let before = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(before?.documentCount == riDocs.count)

            // Reopen and ingest ONE more document. If the accumulator were reset on
            // open instead of restored, the doc count would read 1; restored, it
            // continues from the persisted anchor.
            let reopened = try await freshRICorpus(try storage(at: url))
            try await reopened.ingest("airplane wing flight sky", sourceID: "doc-new",
                                      now: now.addingTimeInterval(120))
            let after = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(after?.documentCount == riDocs.count + 1,
                    "reopened accumulator must continue from the restored doc count, not reset")
        }
    }

    @Test("reopened trainable corpus retrains on reindex (frozen-after-restart fix)")
    func reopenedCorpusRetrains() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            // First session: ingest + reindex → basis trained on the 5-doc corpus.
            do {
                let corpus = try await freshRICorpus(try storage(at: url))
                for (i, doc) in riDocs.enumerated() {
                    try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
                }
                try await corpus.reindex(now: now)
            }
            let store = BasisStore(storage: try storage(at: url))
            #expect(try await store.load(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)?.trainedChunkCount
                == riDocs.count)

            // Reopen, add a new document, reindex. Before the frozen-after-restart
            // fix a reopened corpus dropped its empty-basis factory, so reindex
            // could only re-embed under the loaded basis — the basis would stay
            // trained on 5 chunks forever. With the factory retained, reindex
            // retrains from scratch on the full 6-chunk corpus.
            let reopened = try await freshRICorpus(try storage(at: url))
            try await reopened.ingest("airplane wing flight sky", sourceID: "doc-new",
                                      now: now.addingTimeInterval(120))
            try await reopened.reindex(now: now.addingTimeInterval(180))

            let after = try await store.load(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(after?.trainedChunkCount == riDocs.count + 1,
                    "reopened corpus must retrain on the full corpus (incl. the new doc)")
        }
    }

    @Test("re-ingesting the same source does not inflate maintained counts")
    func reingestDoesNotInflateCounts() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            let counts = CorpusProviderCountsStore(storage: storage)

            for (i, doc) in riDocs.enumerated() {
                try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
            }
            let chunkCount0 = try await corpus.count()
            let a0 = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(a0?.documentCount == riDocs.count)

            // Re-ingest the IDENTICAL sources (same text + sourceID → same
            // content-addressed chunk ids → idempotent no-op in the bundle store).
            // The maintained counts must NOT advance: the fold runs only over
            // newly-inserted chunks, of which there are none on the second pass.
            for (i, doc) in riDocs.enumerated() {
                try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now.addingTimeInterval(60))
            }
            let chunkCount1 = try await corpus.count()
            let a1 = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)

            #expect(chunkCount1 == chunkCount0, "re-ingest must not add chunks (idempotent)")
            #expect(a1?.documentCount == a0?.documentCount,
                    "re-ingest must not inflate the maintained document count")
            #expect(a1?.vocabSize == a0?.vocabSize,
                    "re-ingest must not inflate the maintained vocabulary anchor")
        }
    }

    @Test("re-ingesting the same BATCH does not inflate maintained counts")
    func reingestBatchDoesNotInflateCounts() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            let counts = CorpusProviderCountsStore(storage: storage)

            let batch = riDocs.enumerated().map {
                (text: $0.element, sourceID: "doc-\($0.offset)", now: now)
            }
            try await corpus.ingestBatch(batch)
            let chunkCount0 = try await corpus.count()
            let a0 = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)
            #expect(a0?.documentCount == riDocs.count)

            // Re-import the IDENTICAL batch via the batch (drain) path: every chunk
            // is an idempotent no-op, so the maintained counts must not advance.
            try await corpus.ingestBatch(batch)
            let a1 = try await counts.growthAnchor(
                modelID: Self.riModelID, modelVersion: Self.riModelVersion)

            #expect(try await corpus.count() == chunkCount0,
                    "batch re-import must not add chunks (idempotent)")
            #expect(a1?.documentCount == a0?.documentCount,
                    "batch re-import must not inflate the maintained document count")
            #expect(a1?.vocabSize == a0?.vocabSize,
                    "batch re-import must not inflate the maintained vocabulary anchor")
        }
    }
}
