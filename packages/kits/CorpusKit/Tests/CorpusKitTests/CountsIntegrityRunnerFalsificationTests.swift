// CountsIntegrityRunnerFalsificationTests.swift
//
// Proves that CountsIntegrityRunner's four invariants CAN fail.
//
// A conformance runner nobody has seen fail is a claim, not a gate. Four
// missions each shipped a defect that a coherence check would have caught, and
// each shipped it past a green suite — so a runner added now must demonstrate
// that it DETECTS the exact row states those defects produced, or it is one
// more green thing that proves nothing.
//
// Each invariant gets a PAIR of tests:
//
//   …IsCaught       constructs the violating row state, runs the invariant
//                   inside `withKnownIssue`, which FAILS THE TEST if the
//                   runner records no issue. This is the falsification: the
//                   runner is observed failing on demand. Weaken the
//                   invariant and this test goes red.
//
//   …CleanPasses    runs the same invariant on a coherent store and expects
//                   silence. This is the half that catches an invariant
//                   asserting something trivially true — one that fires on
//                   everything would fail here.
//
// The violating states are built from ROWS rather than by reverting production
// code, so these tests are permanent rather than a one-off experiment.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import CorpusKit

@Suite("CountsIntegrityRunner falsification", .serialized)
struct CountsIntegrityRunnerFalsificationTests {

    private let modelID = "random-indexing-v1"
    private let modelVersion = "1.0.0"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func openStore() async throws -> (any Storage, CorpusProviderCountsStore) {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("corpuskit-integrity-\(UUID().uuidString).sqlite3"))))
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        return (storage, CorpusProviderCountsStore(storage: storage))
    }

    private func seedCountsRow(_ store: CorpusProviderCountsStore,
                               _ rowStore: any RowStore,
                               counts: Data = Data([0x01])) async throws {
        try await store.upsert(
            PersistedCounts(
                modelID: modelID, modelVersion: modelVersion,
                counts: counts, documentCount: 1, vocabSize: 1, updatedAt: now),
            into: rowStore)
    }

    // MARK: - I-1 orphan reference

    /// The CT-02 residual, reproduced as row state: a reference row naming a
    /// provider generation whose counts row is gone. Before that fix,
    /// `removeContent` produced exactly this, and the population guard read
    /// 50 + 2 = 52 against a store holding 51.
    @Test("I-1 fires on a reference row whose counts row is gone")
    func i1_orphanReferenceIsCaught() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }

        try await seedCountsRow(store, storage.rowStore)
        try await store.upsertReference(
            PersistedCountsReference(
                modelID: modelID, modelVersion: modelVersion,
                contentID: "doc-1", revision: 1, digest: "d1", updatedAt: now),
            into: storage.rowStore)
        _ = try await storage.rowStore.delete(
            table: "corpus_provider_counts",
            where: .eq(Column(table: "corpus_provider_counts", name: "model_id"),
                       .text(modelID)))

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i1-broken")
        await withKnownIssue("I-1 must reject a reference with no live counts row") {
            try await runner.referenceRowsHaveLiveCountsRow()
        }
    }

    @Test("I-1 stays silent when every reference has a counts row")
    func i1_cleanPasses() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }

        try await seedCountsRow(store, storage.rowStore)
        try await store.upsertReference(
            PersistedCountsReference(
                modelID: modelID, modelVersion: modelVersion,
                contentID: "doc-1", revision: 1, digest: "d1", updatedAt: now),
            into: storage.rowStore)

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i1-clean")
        try await runner.referenceRowsHaveLiveCountsRow()
    }

    // MARK: - I-2 dictionary bit with no payload

    /// CT-02's shape: a term whose dictionary mask still claims a model that
    /// has no payload rows at all — the dictionary outliving what it describes.
    @Test("I-2 fires on a dictionary bit for a model with no payload")
    func i2_orphanModelBitIsCaught() async throws {
        let (storage, _) = try await openStore()
        defer { Task { await storage.close() } }

        // Model 3 claims the term; no payload row for model 3 is ever written.
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(1), "term": .text("stranded"),
                     "models": .int(Int64(1) << 3)])

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i2-broken")
        await withKnownIssue("I-2 must reject a model bit with no payload rows") {
            try await runner.termDictionaryHasNoOrphanModelBits()
        }
    }

    /// A ZERO mask is deliberately legal — a name no model currently claims,
    /// which `clearTermPayloads` produces and the next persist re-sets. If I-2
    /// ever starts firing on it, this test catches the over-reach.
    @Test("I-2 stays silent on a zero mask and on a bit with payload")
    func i2_cleanPasses() async throws {
        let (storage, _) = try await openStore()
        defer { Task { await storage.close() } }

        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(1), "term": .text("unclaimed"), "models": .int(0)])
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(2), "term": .text("claimed"),
                     "models": .int(Int64(1) << 3)])
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_payload",
            values: ["model_id": .int(3), "term_id": .int(2),
                     "vector": .blob(Data(repeating: 1, count: 8))])

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i2-clean")
        try await runner.termDictionaryHasNoOrphanModelBits()
    }

    // MARK: - I-3 payload with no dictionary entry

    /// A payload row nothing can reach: no dictionary row maps a term string
    /// to this `term_id`, so the bytes are resident and unqueryable.
    @Test("I-3 fires on a payload row with no dictionary entry")
    func i3_payloadWithoutDictionaryEntryIsCaught() async throws {
        let (storage, _) = try await openStore()
        defer { Task { await storage.close() } }

        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_payload",
            values: ["model_id": .int(3), "term_id": .int(99),
                     "vector": .blob(Data(repeating: 2, count: 8))])

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i3-broken")
        await withKnownIssue("I-3 must reject a payload row the dictionary does not describe") {
            try await runner.termPayloadMatchesDictionary()
        }
    }

    /// The subtler I-3 case: the dictionary knows the term, but does not set
    /// THIS model's bit. The payload is still unreachable through it.
    @Test("I-3 fires when the dictionary omits this model's bit")
    func i3_dictionaryMissingModelBitIsCaught() async throws {
        let (storage, _) = try await openStore()
        defer { Task { await storage.close() } }

        // Dictionary claims model 1 only; payload is written for model 3.
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(7), "term": .text("mismatched"),
                     "models": .int(Int64(1) << 1)])
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_payload",
            values: ["model_id": .int(3), "term_id": .int(7),
                     "vector": .blob(Data(repeating: 4, count: 8))])

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i3-mismatch")
        await withKnownIssue("I-3 must reject a payload whose model bit is unset") {
            try await runner.termPayloadMatchesDictionary()
        }
    }

    @Test("I-3 stays silent when payload and dictionary agree")
    func i3_cleanPasses() async throws {
        let (storage, _) = try await openStore()
        defer { Task { await storage.close() } }

        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(7), "term": .text("agreed"),
                     "models": .int(Int64(1) << 3)])
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_payload",
            values: ["model_id": .int(3), "term_id": .int(7),
                     "vector": .blob(Data(repeating: 4, count: 8))])

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i3-clean")
        try await runner.termPayloadMatchesDictionary()
    }

    // MARK: - I-4 sentinel with surviving term rows

    /// The m2 case: a generation carrying the migration invalidation sentinel
    /// (empty counts blob) that still has v3 term rows. A restore would find
    /// those rows and use them, which is what the sentinel exists to prevent.
    @Test("I-4 fires on a sentinel blob that still has term rows")
    func i4_sentinelWithSurvivingTermRowsIsCaught() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }

        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "survivor", vector: Data(repeating: 7, count: 8))],
            into: storage.rowStore)
        try await seedCountsRow(store, storage.rowStore, counts: Data())

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i4-broken")
        await withKnownIssue("I-4 must reject term rows surviving an invalidation sentinel") {
            try await runner.invalidatedCountsHasNoSurvivingTermRows()
        }
    }

    /// Surviving v4 term rows alongside the sentinel are LEGAL — the migration
    /// leaves them deliberately (T2 of the Rust sentinel suite). Widening I-4
    /// to the v4 tables would fail on a correctly migrated estate, so this pins
    /// the boundary rather than the behaviour.
    @Test("I-4 does not fire on surviving v4 term rows")
    func i4_doesNotFireOnSurvivingV4TermRows() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }

        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(1), "term": .text("kept"),
                     "models": .int(Int64(1) << 3)])
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_payload",
            values: ["model_id": .int(3), "term_id": .int(1),
                     "vector": .blob(Data(repeating: 1, count: 8))])
        try await seedCountsRow(store, storage.rowStore, counts: Data())

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i4-v4")
        try await runner.invalidatedCountsHasNoSurvivingTermRows()
    }

    @Test("I-4 stays silent on a populated counts blob with term rows")
    func i4_cleanPasses() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }

        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "ordinary", vector: Data(repeating: 3, count: 8))],
            into: storage.rowStore)
        try await seedCountsRow(store, storage.rowStore, counts: Data([0x01, 0x02]))

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "i4-clean")
        try await runner.invalidatedCountsHasNoSurvivingTermRows()
    }

    // MARK: - Whole-set smoke

    /// An empty store satisfies every invariant vacuously. Without this, a
    /// runner that threw on the state every test starts from would make every
    /// call site look broken.
    @Test("verifyIntegrity passes on an empty store")
    func emptyStoreIsCoherent() async throws {
        let (storage, _) = try await openStore()
        defer { Task { await storage.close() } }

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "empty")
        try await runner.verifyIntegrity()
    }

    /// `verifyIntegrity` on a store carrying rows in every table. The empty
    /// store passes all four invariants vacuously, so it cannot show that the
    /// whole set agrees on a populated store — which is the state every real
    /// call site is in.
    @Test("verifyIntegrity passes on a fully populated coherent store")
    func populatedStoreIsCoherent() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }

        try await seedCountsRow(store, storage.rowStore)
        try await store.upsertReference(
            PersistedCountsReference(
                modelID: modelID, modelVersion: modelVersion,
                contentID: "doc-1", revision: 1, digest: "d1", updatedAt: now),
            into: storage.rowStore)
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_dictionary",
            values: ["term_id": .int(1), "term": .text("coherent"),
                     "models": .int(Int64(1) << 3)])
        _ = try await storage.rowStore.insert(
            table: "corpus_provider_term_payload",
            values: ["model_id": .int(3), "term_id": .int(1),
                     "vector": .blob(Data(repeating: 1, count: 8))])
        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "coherent", vector: Data(repeating: 9, count: 8))],
            into: storage.rowStore)

        let runner = CountsIntegrityRunner(rowStore: storage.rowStore, label: "populated")
        try await runner.verifyIntegrity()
    }
}
