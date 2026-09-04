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
import SynapseKit

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

    // MARK: - §2b standalone RI gate: foldOrderProvenanceUnknown

    /// Standalone RI gate: the Corpus (standalone) reindex always records
    /// `.corpus(.foldOrderProvenanceUnknown)` for RandomIndexing because the live
    /// accumulator folds counts in ingest-arrival order while a from-scratch train
    /// would fold in activeChunks() order. RI is float-order-sensitive, so
    /// provenance cannot be proven equal — a pending delta is irrelevant in
    /// standalone mode; this is purely a fold-order provenance issue.
    ///
    /// This gate pins the `CorpusPathReason` case used for standalone RI so
    /// it is not accidentally regressed to the attached-mode `deltaNotFoldSafe`
    /// case (which describes a non-empty pending delta, a different condition).
    @Test("Standalone RI reindex records foldOrderProvenanceUnknown — not deltaNotFoldSafe")
    func standaloneRIDecisionIsFoldOrderProvenanceUnknown() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try storage(at: scratchURL())
            let corpus = try await freshRICorpus(storage)
            // Ingest the first two RI docs so the corpus is non-empty.
            try await corpus.ingest(riDocs[0], sourceID: "doc-0", now: now)
            try await corpus.ingest(riDocs[1], sourceID: "doc-1", now: now.addingTimeInterval(10))
            // Reindex: RI's countsDeltaFoldSafe == false → standalone rejection
            // with foldOrderProvenanceUnknown (live fold order ≠ activeChunks() order).
            try await corpus.reindex(now: now.addingTimeInterval(20))
            let decision = await corpus._trainingPathDecision(for: "random-indexing-v1")
            #expect(decision == .corpus(.foldOrderProvenanceUnknown),
                    "standalone RI reindex must record foldOrderProvenanceUnknown — not deltaNotFoldSafe, which is the attached-mode case for a non-empty pending delta")
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
            #expect(try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0") == nil)

            // Doc 0: first-ingest auto-train fires, basis trained on 1 chunk.
            try await corpus.ingest(riDocs[0], sourceID: "doc-0", now: now)
            let afterFirst = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
            #expect(afterFirst != nil)
            #expect(afterFirst?.trainedChunkCount == 1,
                    "first ingest must auto-train on the 1-chunk corpus")

            // Doc 1: corpus grows to 2 chunks, 2 >= 1 * 2 → growth retrain fires.
            // This prevents a rank-1 LSA SVD (trained on 1 doc) from persisting
            // as the frozen basis (Kinsta-verified recall regression fix).
            try await corpus.ingest(riDocs[1], sourceID: "doc-1", now: now.addingTimeInterval(60))
            let afterSecond = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
            #expect(afterSecond?.trainedChunkCount == 2,
                    "second ingest must growth-retrain: corpus doubled from 1 to 2 chunks")

            // Doc 2: corpus grows to 3 chunks, 3 < 2 * 2 = 4 → fold-in (no retrain).
            try await corpus.ingest(riDocs[2], sourceID: "doc-2", now: now.addingTimeInterval(120))
            let afterThird = try await store.load(modelID: "random-indexing-v1", modelVersion: "1.1.0")
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
            let lsaModelVersion = "1.1.0"

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

// MARK: - CountsRefactorDigestGates

/// Byte-identity digest gates for the maintained-counts seam.
///
/// Pure provider-level tests — no storage, no Corpus. Each gate verifies a
/// property that the retrain wiring (Part 3) depends on:
///
///   T1–T4  RandomIndexing: restore→finalize byte-identity; term-row round-trip;
///          permuted fold order (F-3 pin); corrupted term row.
///   T5–T8  PPMI: restore→finalize byte-identity; delta-fold extend;
///          permuted fold order (commutativity); corrupted blob.
///   T9–T10 LSA / NMF: counts-only unsupported, state unchanged.
///
/// Providers are constructed with their default inits so scratch / counts-side
/// / restored instances share identity, matching the existing serialization
/// test pattern in PpmiBasisSerializationTests.swift.
@Suite("CountsRefactorDigestGates")
struct CountsRefactorDigestGates {

    // MARK: Fixture corpus
    //
    // Eight short docs with deliberately shared terms across docs so fold ORDER
    // changes the sequence in which float values accumulate in RI context vectors
    // (verifying F-3 sensitivity or the lack thereof for small corpora — T3 pins
    // whichever outcome is observed). Unique-per-doc terms keep vocab non-trivial.
    private let corpus: [String] = [
        "car engine drive road vehicle",
        "road leads city transport route",
        "city cars traffic congestion roads",
        "drive car work commute daily",
        "engine powers car fuel combustion",
        "road work ahead slow lane merge",
        "city traffic slow delay signal",
        "engine runs road speed distance route"
    ]

    // MARK: - Storage helpers for corpus-path gates

    /// Fixed point-in-time date used as `now` throughout corpus-path gates so
    /// all test runs are deterministic.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A unique on-disk SQLite file URL. Tests use the real SQLite backend to
    /// exercise the persist→reopen path (in-RAM backend preserves semantic
    /// TypedValues and hides reopen bugs).
    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-counts-\(UUID().uuidString).sqlite3")
    }

    /// Open a fresh SQLiteStorage over `url`. Constructing a second storage over
    /// the same url reopens the persisted file, exercising the load-on-open path.
    private func storage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    // MARK: - T1: RI restore → finalize byte-identity

    /// Scratch `trainOnCorpus` and counts-side `addToCounts` + `restoreCounts` +
    /// `finalizeFromCounts` must produce byte-identical `serializeBasis()` output.
    /// This is the core acceptance contract for the RI counts path.
    @Test("T1: RI restore→finalize byte-identity")
    func riRestoreFinalizeBytesMatch() throws {
        // Scratch: canonical training path.
        let scratch = RandomIndexingProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        // Counts side: fold via addToCounts in the same document order.
        let countsSide = RandomIndexingProvider()
        for doc in corpus { countsSide.addToCounts(text: doc) }
        let countsBlob = countsSide.serializeCounts()

        // Restore into a fresh provider and finalize.
        let restored = RandomIndexingProvider()
        try restored.restoreCounts(from: countsBlob)
        #expect(restored.finalizeFromCounts() == true,
                "RI finalizeFromCounts must return true: restored vocab IS the basis")
        let b = restored.serializeBasis()

        #expect(a == b,
                "T1: RI serializeBasis after restore must be byte-identical to scratch")
    }

    // MARK: - T2: RI v4 term-row round-trip

    /// decomposeCounts → restoreCounts(header:terms:) → finalizeFromCounts →
    /// serializeBasis must reproduce the scratch bytes. Promotes the term-row
    /// codec through the finalizeFromCounts seam.
    @Test("T2: RI term-row round-trip via decomposeCounts")
    func riTermRowRoundTrip() throws {
        let scratch = RandomIndexingProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        let countsSide = RandomIndexingProvider()
        for doc in corpus { countsSide.addToCounts(text: doc) }
        guard let decomposed = countsSide.decomposeCounts() else {
            Issue.record("T2: decomposeCounts returned nil for RI — expected non-nil")
            return
        }

        let fresh = RandomIndexingProvider()
        try fresh.restoreCounts(header: decomposed.header, terms: decomposed.terms)
        #expect(fresh.finalizeFromCounts() == true,
                "T2: RI finalizeFromCounts must return true after term-row restore")
        let c = fresh.serializeBasis()

        #expect(c == a,
                "T2: RI serializeBasis after term-row restore must be byte-identical to scratch")
    }

    // MARK: - T3: RI permuted fold order (F-3 gate)

    /// Fold addToCounts over the REVERSED corpus, serialize, restore, finalize,
    /// and compare bytes to scratch. This pins the observed order-sensitivity of
    /// RI's float accumulation (reviewer finding F-3).
    ///
    /// For small corpora (each dimension sum bounded by a few dozen ±1 additions)
    /// float32 represents the partial sums exactly and no rounding divergence
    /// occurs — the bytes come out EQUAL. This is the expected outcome for this
    /// fixture corpus and is documented here so the test gates the behaviour
    /// rather than assuming inequality. A larger corpus with sums exceeding the
    /// float32 exact-integer range (2^24) would diverge; that regime is the F-3
    /// concern in production.
    @Test("T3: RI permuted fold order pins F-3 observed behaviour")
    func riPermutedFoldOrderObserved() throws {
        let scratch = RandomIndexingProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        let reversed = RandomIndexingProvider()
        for doc in corpus.reversed() { reversed.addToCounts(text: doc) }
        let reversedBlob = reversed.serializeCounts()

        let restoredReversed = RandomIndexingProvider()
        try restoredReversed.restoreCounts(from: reversedBlob)
        _ = restoredReversed.finalizeFromCounts()
        let d = restoredReversed.serializeBasis()

        // F-8c precondition: the equality a == d is arithmetic necessity only
        // while every per-dimension accumulated value stays inside float32's
        // exact-integer range (2^24 ≈ 16.7M). Assert this holds for the fixture
        // corpus before relying on the equality below. A fixture that outgrows
        // the bound must fail HERE with an actionable message rather than on
        // the equality assertion, which is inscrutable without this context.
        let allCorpusTerms = Set(corpus.flatMap { defaultKeywordTokens($0) })
        let maxAbsAccumulated: Float = allCorpusTerms
            .compactMap { reversed.contextVector(forTerm: $0) }
            .flatMap { $0 }
            .map { abs($0) }
            .max() ?? 0.0
        #expect(
            maxAbsAccumulated < 16_777_216,
            "F-8c precondition: equality below 2^24 is arithmetic necessity, not an order-safety property; exceeding it is the F-3 divergence regime — a fixture that outgrows this bound must fail HERE rather than on the equality assertion below")

        // OBSERVED OUTCOME (run first, assertion updated to match):
        // For this 8-doc corpus each per-dimension sum is bounded by
        // ±(window * docs) ≈ ±32, well within float32's exact-integer range
        // (2^24 ≈ 16.7M). All additions are exact regardless of order, so the
        // bytes are EQUAL. This is the correct assertion for this fixture;
        // a corpus with much larger per-dimension sums would produce UNEQUAL
        // bytes, exposing the F-3 rounding sensitivity.
        #expect(a == d,
                "T3: small corpus RI — reversed fold order yields same bytes (sums fit exact float32)")
    }

    // MARK: - T4: RI corrupted term row

    /// Flipping one byte in the middle of a term's vector Data must cause
    /// either a decoding failure OR a finalized basis whose bytes differ from
    /// the scratch basis. The disjunction guards against silent bit-flip
    /// acceptance that could produce a subtly wrong basis.
    @Test("T4: RI corrupted term row causes decode failure or basis divergence")
    func riCorruptedTermRow() throws {
        let scratch = RandomIndexingProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        let countsSide = RandomIndexingProvider()
        for doc in corpus { countsSide.addToCounts(text: doc) }
        guard var decomposed = countsSide.decomposeCounts() else {
            Issue.record("T4: decomposeCounts returned nil — cannot test corruption path")
            return
        }

        // Flip one byte in the middle of the first term's vector payload. The
        // vector bytes are raw float32 data; flipping a bit mid-payload corrupts
        // one float component without triggering a length mismatch.
        guard !decomposed.terms.isEmpty else {
            Issue.record("T4: decomposed term list is empty — no term to corrupt")
            return
        }
        var entry = decomposed.terms[0]
        // Guard: vector must have at least 5 bytes (4-byte u32 length + payload).
        guard entry.vector.count > 4 else {
            Issue.record("T4: term vector too short to corrupt mid-payload")
            return
        }
        let mid = entry.vector.count / 2
        entry.vector[mid] ^= 0xFF
        decomposed.terms[0] = entry

        let corruptedProvider = RandomIndexingProvider()
        do {
            try corruptedProvider.restoreCounts(header: decomposed.header,
                                                terms: decomposed.terms)
            _ = corruptedProvider.finalizeFromCounts()
            let e = corruptedProvider.serializeBasis()
            // Decode succeeded; the corrupted float must change the basis bytes.
            #expect(e != a,
                    "T4: corrupted term row must produce different basis bytes than scratch")
        } catch {
            // A decoding failure is also an acceptable guard — the disjunction passes.
        }
    }

    // MARK: - T5: PPMI restore → finalize byte-identity

    /// Same shape as T1 but for PPMI. Counts blob holds integer co-occurrence
    /// state; finalize() on the restored state must derive byte-identical
    /// ppmiVectors to a from-scratch trainOnCorpus run.
    @Test("T5: PPMI restore→finalize byte-identity")
    func ppmiRestoreFinalizeBytesMatch() throws {
        let scratch = PpmiProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        let countsSide = PpmiProvider()
        for doc in corpus { countsSide.addToCounts(text: doc) }
        let countsBlob = countsSide.serializeCounts()

        let restored = PpmiProvider()
        try restored.restoreCounts(from: countsBlob)
        #expect(restored.finalizeFromCounts() == true,
                "T5: PPMI finalizeFromCounts must return true after restore")
        let b = restored.serializeBasis()

        #expect(a == b,
                "T5: PPMI serializeBasis after restore+finalize must be byte-identical to scratch")
    }

    // MARK: - T6: PPMI delta-fold extend

    /// Counts over the first 5 docs → serialize → restore into fresh →
    /// addToCounts the remaining 3 docs → finalizeFromCounts → serializeBasis
    /// must equal scratch trainOnCorpus over all 8.
    ///
    /// Promotes the P2 codec commutative property through the new seam; pattern
    /// precedent: PpmiBasisSerializationTests.swift countsIncrementalExtendEqualsFromScratch.
    @Test("T6: PPMI delta-fold after restore equals from-scratch over full corpus")
    func ppmiDeltaFoldExtendsCorrectly() throws {
        // Head: first 5 docs.
        let head = PpmiProvider()
        for doc in corpus.prefix(5) { head.addToCounts(text: doc) }
        let headBlob = head.serializeCounts()

        // Restore and extend with the remaining 3 docs.
        let extended = PpmiProvider()
        try extended.restoreCounts(from: headBlob)
        for doc in corpus.dropFirst(5) { extended.addToCounts(text: doc) }
        #expect(extended.finalizeFromCounts() == true,
                "T6: PPMI finalizeFromCounts must return true after delta extend")
        let f = extended.serializeBasis()

        // From-scratch over all 8 docs.
        let fullScratch = PpmiProvider()
        fullScratch.trainOnCorpus(texts: corpus)
        let g = fullScratch.serializeBasis()

        #expect(f == g,
                "T6: PPMI delta-fold extend must produce byte-identical basis to full scratch")
    }

    // MARK: - T7: PPMI permuted fold order

    /// Fold addToCounts over REVERSED corpus → restore → finalize → bytes EQUAL
    /// to scratch. Asserts the integer-map commutativity that countsDeltaFoldSafe
    /// declares: any fold order yields the same counts, the same finalize, the
    /// same bytes.
    @Test("T7: PPMI permuted fold order yields identical basis (commutativity)")
    func ppmiPermutedFoldOrderIsCommutative() throws {
        let scratch = PpmiProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        let reversed = PpmiProvider()
        for doc in corpus.reversed() { reversed.addToCounts(text: doc) }
        let reversedBlob = reversed.serializeCounts()

        let restoredReversed = PpmiProvider()
        try restoredReversed.restoreCounts(from: reversedBlob)
        #expect(restoredReversed.finalizeFromCounts() == true,
                "T7: PPMI finalizeFromCounts must return true after reversed-fold restore")
        let h = restoredReversed.serializeBasis()

        #expect(h == a,
                "T7: PPMI reversed fold order must yield byte-identical basis (integer-map commutativity)")
    }

    // MARK: - T8: PPMI corrupted blob

    /// Flip one byte at roughly 3/4 of the blob length (inside the map payload
    /// region, past magic/version/ids). Restore must throw OR the finalized bytes
    /// must differ from scratch. Guards against silent corruption acceptance.
    @Test("T8: PPMI corrupted blob causes decode failure or basis divergence")
    func ppmiCorruptedBlobGuardsAgainstSilentAcceptance() throws {
        let scratch = PpmiProvider()
        scratch.trainOnCorpus(texts: corpus)
        let a = scratch.serializeBasis()

        let countsSide = PpmiProvider()
        for doc in corpus { countsSide.addToCounts(text: doc) }
        var blobBytes = [UInt8](countsSide.serializeCounts())

        // Flip one byte at 3/4 through the blob — past magic (4) + version (1) +
        // string headers, well into the map payload region.
        guard blobBytes.count > 20 else {
            Issue.record("T8: PPMI counts blob too small to corrupt at 3/4 position")
            return
        }
        let target = blobBytes.count * 3 / 4
        blobBytes[target] ^= 0xFF

        let corruptedProvider = PpmiProvider()
        do {
            try corruptedProvider.restoreCounts(from: Data(blobBytes))
            _ = corruptedProvider.finalizeFromCounts()
            let corrupted = corruptedProvider.serializeBasis()
            // Restore succeeded; the corrupted counts must change the basis bytes.
            #expect(corrupted != a,
                    "T8: corrupted PPMI blob must produce different basis bytes than scratch")
        } catch {
            // A decoding failure is also acceptable — the disjunction passes.
        }
    }

    // MARK: - T9: LSA counts-only unsupported

    /// Build counts via addToCounts, serialize, restore into a fresh provider,
    /// capture serializeBasis() before finalizeFromCounts(). Assert the method
    /// returns false and that serializeBasis() is unchanged (state must not be
    /// mutated by a false-returning finalizeFromCounts call).
    @Test("T9: LSA finalizeFromCounts returns false and leaves state unchanged")
    func lsaCountsOnlyUnsupported() throws {
        let lsaP = LsaProvider()
        for doc in corpus { lsaP.addToCounts(text: doc) }
        let lsaBlob = lsaP.serializeCounts()

        let lsaRestored = LsaProvider()
        try lsaRestored.restoreCounts(from: lsaBlob)
        // Capture serializeBasis before calling finalizeFromCounts — the call
        // must not alter the provider's state.
        let pre = lsaRestored.serializeBasis()

        #expect(lsaRestored.finalizeFromCounts() == false,
                "T9: LSA finalizeFromCounts must return false (TF rows not persisted)")
        #expect(lsaRestored.serializeBasis() == pre,
                "T9: LSA state must be unchanged after finalizeFromCounts() == false")
    }

    // MARK: - T10: NMF counts-only unsupported

    /// Same as T9 for NMF. The counts blob holds only vocab + documentCount
    /// anchors; per-document TF rows required by NMF factorization are not
    /// persisted, so finalizeFromCounts must return false without mutating state.
    @Test("T10: NMF finalizeFromCounts returns false and leaves state unchanged")
    func nmfCountsOnlyUnsupported() throws {
        let nmfP = NmfProvider()
        for doc in corpus { nmfP.addToCounts(text: doc) }
        let nmfBlob = nmfP.serializeCounts()

        let nmfRestored = NmfProvider()
        try nmfRestored.restoreCounts(from: nmfBlob)
        let pre = nmfRestored.serializeBasis()

        #expect(nmfRestored.finalizeFromCounts() == false,
                "T10: NMF finalizeFromCounts must return false (TF rows not persisted)")
        #expect(nmfRestored.serializeBasis() == pre,
                "T10: NMF state must be unchanged after finalizeFromCounts() == false")
    }

    // MARK: - F-2 gate: corpus path heal → counts accumulator rebuilt

    /// Gate F-2: after a corpus-path reindex, the F-2 heal rebuilds the slot's
    /// counts accumulator by folding the same texts in the same order. This means
    /// the next reindex call (when no sources have changed) can take the counts
    /// path (countsDocumentCount == chunks.count). Conversely, removing a source
    /// after the corpus-path reindex drives a population mismatch on the next
    /// reindex call.
    ///
    /// Sequence: ingest A and B → reindex (corpus path, F-2 heal applied) →
    /// remove A → reindex → decision must be corpus(.populationMismatch) and
    /// the new trainedChunkCount must be 1 (B only).
    @Test("F-2: remove after corpus-path reindex drives populationMismatch + retrain on B only")
    func f2HealDrivesPopulationMismatchAfterRemoval() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            let stor = try storage(at: url)
            let corpus = try await Corpus(
                storage: stor,
                model: .ppmi(provider: PpmiProvider()))

            // Two distinct texts: A uses unique terms, B uses different unique terms.
            // This lets us verify A-terms are absent after retraining on B only.
            let textA = "xenon argon krypton noble gases rare elements unique"
            let textB = "fibonacci sequence golden ratio mathematics number theory"

            try await corpus.ingest(textA, sourceID: "f2-source-a", now: now)
            try await corpus.ingest(textB, sourceID: "f2-source-b", now: now)

            // First reindex: corpus path (first call, no prior basis via counts path).
            // F-2 heal runs inside the corpus-path install loop: rebuilds counts
            // accumulator from both texts; countsDocumentCount == 2.
            try await corpus.reindex(now: now.addingTimeInterval(10))
            // The decision on the first reindex is corpus path (no counts row yet at
            // construction; the counts accumulator from ingest is not yet stored as
            // a countsRestore-eligible snapshot). After reindex, a second immediate
            // reindex with no changes would take countsRestore.
            let firstDecision = await corpus._trainingPathDecision(for: "ppmi-v1")
            // First reindex decision: countsRestore when auto-training during ingest
            // has already populated countsDocumentCount == chunks.count (counts path
            // eligible), or a corpus(.populationMismatch) when countsDocumentCount
            // and chunks.count diverged. Both are valid — the critical F-2 invariant
            // is verified by the second reindex decision below.
            #expect(firstDecision != nil,
                    "F-2 gate: first reindex must record a decision")

            let basisStoreFirst = BasisStore(storage: stor)
            let rowAfterFirst = try await basisStoreFirst.load(
                modelID: "ppmi-v1", modelVersion: "1.1.0")
            #expect(rowAfterFirst?.trainedChunkCount == 2,
                    "F-2: corpus-path reindex on 2 sources must set trainedChunkCount = 2")

            // Remove source A. Now only B remains (chunks.count = 1).
            // countsDocumentCount (from F-2 heal) = 2 ≠ 1 → populationMismatch.
            try await corpus.remove(sourceID: "f2-source-a")

            // Second reindex: population mismatch → corpus path → retrain on B only.
            try await corpus.reindex(now: now.addingTimeInterval(20))
            let secondDecision = await corpus._trainingPathDecision(for: "ppmi-v1")
            #expect(secondDecision == .corpus(.populationMismatch),
                    "F-2: after removing A, countsDocumentCount (2) ≠ chunks.count (1) → populationMismatch")

            // doc_count decreased: trainedChunkCount must now be 1 (B only).
            let stor2 = try storage(at: url)
            let rowAfterSecond = try await BasisStore(storage: stor2)
                .load(modelID: "ppmi-v1", modelVersion: "1.1.0")
            #expect(rowAfterSecond?.trainedChunkCount == 1,
                    "F-2: after removing A, retraining on B only must set trainedChunkCount = 1")

            // Verify the new basis equals from-scratch PPMI on B only.
            // This proves A-terms are absent (they were in the old basis trained on A+B).
            let twin = PpmiProvider()
            twin.trainOnCorpus(texts: [textB])
            let twinDigest = CorpusContentDigest.digest(twin.serializeBasis())
            let engineDigest = CorpusContentDigest.digest(
                try #require(rowAfterSecond?.basis,
                             "F-2: basis row must exist after corpus-path reindex on B only"))
            #expect(engineDigest == twinDigest,
                    "F-2: basis after removing A must match from-scratch PPMI trained on B only (A-terms absent)")
        }
    }

    // MARK: - Standalone byte-identity gate

    /// Standalone byte-identity: ingest N docs via Corpus (standalone), call
    /// reindex. When countsDocumentCount matches chunks.count (F-2 heal ensures
    /// this is possible on the second reindex after the first corpus-path pass),
    /// the counts-restore path must yield a basis byte-identical to a from-scratch
    /// PPMI trained on the same texts.
    ///
    /// This gate exercises the complete counts-path round-trip for the standalone
    /// Corpus: ingest folds texts into the live accumulator; persistMaintainedCounts
    /// flushes to storage; restoreCounts reconstructs; finalizeFromCounts produces
    /// the serving basis. The result is byte-identical to trainOnCorpus on the same
    /// texts because PPMI co-occurrence counts are commutative.
    @Test("Standalone byte-identity: counts-restore digest matches from-scratch twin")
    func standaloneCountsRestoreDigestMatchesTwin() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()
            let stor = try storage(at: url)
            let corpus = try await Corpus(
                storage: stor,
                model: .ppmi(provider: PpmiProvider()))

            // Five distinct texts — the same texts used for PPMI fixture conformance
            // in the provider tests, so the token space is well-exercised.
            let texts = [
                "car engine drive road vehicle transport",
                "vehicle road transport car fuel combustion",
                "engine fuel combustion power car exhaust",
                "dog bark run fetch animal companion",
                "animal run cat dog pet friend"
            ]

            // Ingest all texts. The ingest path folds each into the live counts
            // accumulator AND triggers auto-training (first-ingest + doubling paths).
            for (i, text) in texts.enumerated() {
                try await corpus.ingest(text, sourceID: "sid-\(i)", now: now)
            }

            // First reindex: corpus path (auto-training may have trained a basis,
            // but the standalone reindex's counts-path eligibility also requires
            // countsDocumentCount == chunks.count — the F-2 heal from the corpus-
            // path pass inside reindex sets this for the NEXT reindex call).
            try await corpus.reindex(now: now.addingTimeInterval(10))

            // Second reindex: F-2 heal from the first pass has set countsDocumentCount
            // == 5 == chunks.count. PPMI is capable and fold-safe → counts path.
            try await corpus.reindex(now: now.addingTimeInterval(20))
            let secondDecision = await corpus._trainingPathDecision(for: "ppmi-v1")
            #expect(secondDecision == .countsRestore,
                    "byte-identity gate: second reindex with matching population must take countsRestore path")

            // From-scratch twin: PPMI trained on all 5 texts via the same trainOnCorpus
            // call that the corpus-path reindex uses (addToCounts × N + finalizeFromCounts).
            let twin = PpmiProvider()
            twin.trainOnCorpus(texts: texts)
            let twinDigest = CorpusContentDigest.digest(twin.serializeBasis())

            // Engine's persisted basis (from counts path) must match.
            let stor2 = try storage(at: url)
            let basisRow = try await BasisStore(storage: stor2)
                .load(modelID: "ppmi-v1", modelVersion: "1.1.0")
            let engineDigest = CorpusContentDigest.digest(
                try #require(basisRow?.basis,
                             "byte-identity gate: basis row must exist after counts-restore reindex"))
            #expect(engineDigest == twinDigest,
                    "byte-identity gate: counts-restore basis must be byte-identical to from-scratch twin")
        }
    }
}
