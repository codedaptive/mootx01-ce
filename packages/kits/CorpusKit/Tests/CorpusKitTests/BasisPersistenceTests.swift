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
//   3. First-ingest auto-train + growth retrain: ingesting into a fresh trainable
//      Corpus trains on the first ingest; a SECOND ingest also retrains when the
//      corpus has doubled (growth-retrain, Kinsta-fix), but a third ingest does
//      NOT retrain unless it crosses the next doubling threshold (fold-in path).
//   4. Load-on-open: after reindex + close, reopening a trainable Corpus loads
//      the persisted basis (dense lane trained-ready) and serves embeddings
//      identical to the pre-close provider.
//   5. Lifecycle: destroyRecallIndex wipes basis rows (no orphans); a
//      non-trainable Corpus persists no basis.
//   6. Cross-port conformance: persist → reopen → embed matches the α canonical
//      fixture (byte-for-byte parity with the Rust port).
//   7. Per-doc ingest non-degeneracy (REGRESSION — fixes Kinsta-verified recall
//      collapse): after 20+ docs ingested one-at-a-time, LSA-basis query
//      discrimination is non-degenerate (relevant docs rank in top-k).
//   8. Reindex recovers a deliberately-degenerate basis: inject a 1-doc-trained
//      LSA basis, reopen, confirm OOV, reindex, confirm recovery.
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

    // MARK: - §1 BasisStore round-trip

    @Test("BasisStore upsert → load round-trips the row")
    func basisStoreRoundTrip() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            try await storage.migrate(to: BasisStore.schemaDeclaration)
            let store = BasisStore(storage: storage)

            let row = PersistedBasis(
                modelID: "random-indexing-v1",
                modelVersion: "1.0.0",
                basis: Data([1, 2, 3, 4, 5]),
                trainedAt: now,
                trainedChunkCount: 7
            )
            try await store.upsert(row)
            let loaded = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0")
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
            let loaded = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0")
            #expect(loaded != nil)
            #expect(loaded?.trainedChunkCount == riDocs.count)
        }
    }

    // MARK: - §3 first-ingest auto-train + growth retrain

    @Test("first ingest auto-trains; second ingest growth-retrains; third fold-ins")
    func firstIngestAutoTrainsAndGrowthRetrains() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            let store = BasisStore(storage: storage)

            // No basis before the first ingest.
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0") == nil)

            // Doc 0: first-ingest auto-train fires, basis trained on 1 chunk.
            try await corpus.ingest(riDocs[0], sourceID: "doc-0", now: now)
            let afterFirst = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0")
            #expect(afterFirst != nil)
            #expect(afterFirst?.trainedChunkCount == 1,
                    "first ingest must auto-train on the 1-chunk corpus")

            // Doc 1: corpus grows to 2 chunks, 2 >= 1 * 2 → growth retrain fires.
            // This prevents a rank-1 LSA SVD (trained on 1 doc) from persisting
            // as the frozen basis (Kinsta-verified recall regression fix).
            try await corpus.ingest(riDocs[1], sourceID: "doc-1", now: now.addingTimeInterval(60))
            let afterSecond = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0")
            #expect(afterSecond?.trainedChunkCount == 2,
                    "second ingest must growth-retrain: corpus doubled from 1 to 2 chunks")

            // Doc 2: corpus grows to 3 chunks, 3 < 2 * 2 = 4 → fold-in (no retrain).
            try await corpus.ingest(riDocs[2], sourceID: "doc-2", now: now.addingTimeInterval(120))
            let afterThird = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0")
            #expect(afterThird?.trainedChunkCount == 2,
                    "third ingest must fold-in: corpus 3 < 4 (2 * 2), no retrain yet")
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
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0") != nil)

            try await corpus.destroyRecallIndex()
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.0.0") == nil)
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
                let corpus = try await freshRICorpus(try storage(at: url))
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
            let reopened = try await freshRICorpus(try storage(at: url))
            let after = try await reopened.embedFloat(probe)
            #expect(after.map(\.bitPattern) == expectedEmbedding.floatBits,
                    "reopened embedding must equal the α canonical 'car engine' bit patterns")
        }
    }

    // MARK: - §7 maintained counts wiring (incremental-counts change set, P3)

    private static let riModelID = "random-indexing-v1"
    private static let riModelVersion = "1.0.0"

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

    // MARK: - §8 per-doc ingest non-degeneracy (REGRESSION — Kinsta-verified bug)

    /// 20 documents split evenly between two topics: cars and animals.
    /// Each doc uses distinct vocabulary so that a well-trained LSA basis
    /// can separate them into different semantic directions. A degenerate basis
    /// (trained on 1 doc only) would have only car vocabulary, so animal-topic
    /// queries would be all-OOV.
    private let lsaCarDocs: [String] = (1...10).map {
        "car engine fuel road vehicle drive speed combustion power auto document \($0)"
    }
    private let lsaAnimalDocs: [String] = (1...10).map {
        "dog cat bark fetch run animal pet fur forest wild document \($0)"
    }

    private func freshLSACorpus(_ storage: any Storage) async throws -> Corpus {
        // Default LsaProvider: rank=3, svdSweeps=30, modelID="lsa-v1".
        try await Corpus(storage: storage, model: .lsa(provider: LsaProvider()))
    }

    /// REGRESSION TEST — fails on code with degenerate-basis bug, passes after fix.
    ///
    /// Per-document ingest (the impatient encode path) used to train the LSA basis
    /// on the FIRST document only, producing a rank-1 SVD. All subsequent documents
    /// would fold onto this 1-doc basis, collapsing all query vectors to the same
    /// direction — Kinsta-verified recall from 0.853 to 0.56 any@5 on LongMemEval
    /// 50q (2026-07-26).
    ///
    /// After the fix, growth retrains fire at 2× chunk doublings until the corpus
    /// reaches the stability threshold (50 chunks), so the basis reflects the full
    /// accumulated corpus. With 20 docs the final auto-train covers 16 of them,
    /// giving a much richer vocabulary and non-degenerate semantic directions.
    ///
    /// Degenerate-basis signal: "dog bark fetch animal" are all OOV in a 1-car-doc
    /// vocabulary → floatNearest returns .unavailableNoVocabHit. After the fix,
    /// those terms are in-vocabulary and the animal docs rank in the top results.
    @Test("per-doc ingest of 20 docs produces a non-degenerate LSA basis (REGRESSION)")
    func perDocIngestProducesNonDegenerateBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshLSACorpus(storage)

            // Ingest all 20 docs ONE AT A TIME (the impatient path).
            let allDocs = lsaCarDocs + lsaAnimalDocs
            for (i, doc) in allDocs.enumerated() {
                let category = i < 10 ? "car" : "animal"
                try await corpus.ingest(
                    doc,
                    sourceID: "\(category)-\(i)",
                    now: now.addingTimeInterval(TimeInterval(i))
                )
            }

            // Degenerate-basis signal: on old code, animal query is OOV (only
            // car vocabulary in the 1-doc trained basis). After the fix the
            // growth-retrain path trains on all 16+ docs before this query runs,
            // so animal terms ARE in-vocabulary.
            let animalQuery = await corpus.floatNearest(query: "dog bark fetch animal", limit: 5)
            guard case .hits(let animalHits) = animalQuery else {
                // If we get .unavailableNoVocabHit (OOV) or .unavailableProviderOptOut,
                // the basis was degenerate — this is the regression we're catching.
                Issue.record("""
                    animal query returned a dark outcome (\(animalQuery)) — \
                    basis is degenerate (trained on too few docs). \
                    Expected .hits from a non-degenerate 20-doc basis.
                    """)
                return
            }

            // At least one animal doc should rank in the top 5. A non-degenerate
            // basis separates car and animal semantic directions; a degenerate one
            // would rank them randomly or return no results.
            let hasAnimalDoc = animalHits.prefix(5).contains { $0.itemID.hasPrefix("animal-") }
            #expect(hasAnimalDoc,
                    "animal query must retrieve an animal doc from a non-degenerate 20-doc LSA basis")

        }
    }

    // MARK: - §9 reindex recovers a deliberately-degenerate basis

    /// Verify that reindex(now:) retrains on the FULL corpus and restores a basis
    /// that was deliberately degraded to a 1-doc-trained state.
    ///
    /// Flow:
    ///   1. Ingest 20 docs via ingestBatch (Phase 1b trains on full corpus).
    ///   2. Overwrite the basis in BasisStore with a 1-doc-trained "degenerate" blob.
    ///   3. Reopen the corpus — it loads the degenerate basis from BasisStore.
    ///   4. Confirm degenerate state: animal query is OOV (car-only vocabulary).
    ///   5. Call corpus.reindex(now:) — must retrain on all 20 docs.
    ///   6. Confirm recovery: trainedChunkCount == 20 and animal query returns hits.
    @Test("reindex recovers a deliberately-degenerate LSA basis")
    func reindexRecoversDegenerateBasis() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            let allDocs = lsaCarDocs + lsaAnimalDocs
            let lsaModelID = "lsa-v1"
            let lsaModelVersion = "1.0.0"

            // Phase 1: ingest all 20 docs via batch (Phase 1b trains on full corpus).
            do {
                let s1 = try storage(at: url)
                let corpus = try await freshLSACorpus(s1)
                let items: [(text: String, sourceID: String, now: Date)] =
                    allDocs.enumerated().map { (i, doc) in
                        let cat = i < 10 ? "car" : "animal"
                        return (text: doc, sourceID: "\(cat)-\(i)",
                                now: now.addingTimeInterval(TimeInterval(i)))
                    }
                try await corpus.ingestBatch(items)
                // Verify batch trained on full corpus.
                let store = BasisStore(storage: s1)
                let goodBasis = try await store.load(modelID: lsaModelID, modelVersion: lsaModelVersion)
                #expect(goodBasis?.trainedChunkCount == allDocs.count,
                        "ingestBatch must train on the full 20-doc corpus")
            }

            // Phase 2: inject a degenerate (1-doc-trained) basis blob into BasisStore.
            let degradedBlob: Data = {
                let p = LsaProvider()
                p.trainOnCorpus(texts: [allDocs[0]])    // car-only vocabulary
                return p.serializeBasis()
            }()
            let s2 = try storage(at: url)
            let basisStore2 = BasisStore(storage: s2)
            try await basisStore2.upsert(PersistedBasis(
                modelID: lsaModelID,
                modelVersion: lsaModelVersion,
                basis: degradedBlob,
                trainedAt: now,
                trainedChunkCount: 1
            ))

            // Phase 3: reopen the corpus — resolveProvider loads the degenerate basis.
            let s3 = try storage(at: url)
            let corpus3 = try await freshLSACorpus(s3)

            // Phase 4: confirm the degenerate state. "dog bark fetch animal" are
            // all-OOV in the 1-car-doc vocabulary → the float lane should be dark.
            // We assert this as a soft check: the injection is expected to produce
            // OOV (unavailableNoVocabHit) or a provider opt-out, but even if the
            // degenerate blob behaves differently, Phases 5–6 still test recovery.
            let animalBefore = await corpus3.floatNearest(
                query: "dog bark fetch animal", limit: 5)
            let isDark: Bool
            switch animalBefore {
            case .unavailableNoVocabHit, .unavailableProviderOptOut, .unavailableNoFloatRows:
                isDark = true
            default:
                isDark = false
            }
            #expect(isDark,
                    "animal query must be dark before reindex — degenerate 1-doc basis has no animal vocabulary")

            // Phase 5: reindex retrains on the full corpus.
            try await corpus3.reindex(now: now.addingTimeInterval(100))

            // Phase 6: verify recovery — basis now trained on all 20 docs.
            let basisStore3 = BasisStore(storage: s3)
            let reindexedBasis = try await basisStore3.load(
                modelID: lsaModelID, modelVersion: lsaModelVersion)
            #expect(reindexedBasis?.trainedChunkCount == allDocs.count,
                    "reindex must retrain on the full corpus (all 20 docs)")

            // Animal query must now return hits — vocabulary restored by full retrain.
            let animalAfter = await corpus3.floatNearest(
                query: "dog bark fetch animal", limit: 5)
            guard case .hits(let animalHits) = animalAfter else {
                Issue.record("""
                    animal query still dark after reindex (\(animalAfter)). \
                    reindex must restore the full vocabulary so animal terms are \
                    in-vocabulary and animal docs rank in results.
                    """)
                return
            }
            let hasAnimalDoc = animalHits.prefix(5).contains { $0.itemID.hasPrefix("animal-") }
            #expect(hasAnimalDoc,
                    "animal doc must rank in top-5 after reindex on the full 20-doc corpus")
        }
    }
}
