// ProviderVocabStorageTests.swift
//
// Mission MXE-RT: term-keyed provider vocabulary storage.
//
// Every test here starts from a POPULATED OLDER LAYOUT, never a fresh
// database. That rule exists because the ee#49 fix shipped broken twice for
// exactly the opposite reason: every basis test migrated a fresh estate, where
// the schema is created correctly by construction and no upgrade path ever
// runs, so a migration that could not work on a fielded estate passed a full
// green suite.

import Testing
import Foundation
import CorpusKit
import PersistenceKit
import PersistenceKitSQLite

@Suite("ProviderVocabStorage", .serialized)
struct ProviderVocabStorageTests {

    private let modelID = "random-indexing-v1"
    private let modelVersion = "1.1.0"
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func scratch() throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("corpuskit-vocab-\(UUID().uuidString).sqlite3"),
                busyTimeout: 5.0)))
    }

    /// The v2 shape: counts blob only, no term table.
    private var legacySchemaV2: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "CorpusKitCounts",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "corpus_provider_counts",
                    columns: [
                        .text("model_id", nullable: false),
                        .text("model_version", nullable: false),
                        .blob("counts", nullable: false),
                        .int("doc_count", nullable: false),
                        .int("vocab_size", nullable: false),
                        .timestamp("updated_at", nullable: false),
                        .json("ext", nullable: true)
                    ],
                    primaryKey: ["model_id", "model_version"]
                ),
                TableDeclaration(
                    name: "corpus_provider_count_references",
                    columns: [
                        .text("model_id", nullable: false),
                        .text("model_version", nullable: false),
                        .text("content_id", nullable: false),
                        .int("revision", nullable: false),
                        .text("digest", nullable: false),
                        .timestamp("updated_at", nullable: false),
                        .json("ext", nullable: true)
                    ],
                    primaryKey: ["model_id", "model_version", "content_id"]
                )
            ],
            indices: [],
            migrations: []
        )
    }

    /// One term's payload, the same width RandomIndexing writes: 2048 f32.
    private func vector(seed: UInt8) -> Data {
        Data((0..<8192).map { UInt8(($0 &+ Int(seed)) % 251) })
    }

    /// An estate created before the term table gains it on migrate, keeps its
    /// existing counts row untouched, and can then store and read back terms.
    @Test("upgraded estate: gains the term table without disturbing the counts row")
    func upgradedEstateGainsTermTable() async throws {
        let storage = try scratch()
        try await storage.migrate(to: legacySchemaV2)

        // Populate the legacy layout, as a fielded estate has.
        let legacyStore = CorpusProviderCountsStore(storage: storage)
        let legacyBlob = Data("legacy-serialized-counts".utf8)
        try await legacyStore.upsert(PersistedCounts(
            modelID: modelID, modelVersion: modelVersion,
            counts: legacyBlob, documentCount: 7, vocabSize: 3, updatedAt: now))

        // Upgrade.
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)

        // The pre-existing counts row is untouched — this is the property that
        // makes the migration safe to run on a multi-gigabyte estate.
        let reloaded = try await legacyStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(reloaded?.counts == legacyBlob)
        #expect(reloaded?.documentCount == 7)

        // No term rows yet: an upgraded estate must report empty so callers
        // fall back to the legacy blob rather than concluding "no vocabulary".
        let before = try await legacyStore.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(before.isEmpty)

        // And the new table works.
        let terms = [(term: "alpha", vector: vector(seed: 1)),
                     (term: "beta", vector: vector(seed: 2))]
        try await legacyStore.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: terms, into: storage.rowStore)

        let after = try await legacyStore.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(after.count == 2)
        #expect(Dictionary(uniqueKeysWithValues: after.map { ($0.term, $0.vector) })
                == Dictionary(uniqueKeysWithValues: terms.map { ($0.term, $0.vector) }),
                "term vectors must round-trip byte-for-byte")
        await storage.close()
    }

    /// No single bound value scales with vocabulary.
    ///
    /// This is the property the blob design could not offer, and the direct
    /// cause of ee#49: at ~123K terms the single counts blob reached
    /// 1,009,861,855 bytes and exceeded SQLite's bind ceiling. Asserting the
    /// per-bind size — rather than merely that the write succeeded — is what
    /// makes this a regression test instead of a smoke test.
    @Test("no single bound value scales with vocabulary size")
    func perTermBindsAreBounded() async throws {
        let storage = try scratch()
        try await storage.migrate(to: legacySchemaV2)
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        let store = CorpusProviderCountsStore(storage: storage)

        let terms = (0..<250).map { (term: "term-\($0)", vector: vector(seed: UInt8($0 % 251))) }
        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: terms, into: storage.rowStore)

        let loaded = try await store.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded.count == 250)
        let widest = loaded.map(\.vector.count).max() ?? 0
        #expect(widest == 8192,
                "each bound value must be one term's vector, not the whole map; got \(widest)")
        await storage.close()
    }

    /// Replacing the vocabulary yields exactly the new set, never a union.
    @Test("replaceVocab replaces rather than accumulating")
    func replaceVocabDoesNotAccumulate() async throws {
        let storage = try scratch()
        try await storage.migrate(to: legacySchemaV2)
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        let store = CorpusProviderCountsStore(storage: storage)

        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "old-a", vector: vector(seed: 1)),
                    (term: "old-b", vector: vector(seed: 2))],
            into: storage.rowStore)
        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "new-a", vector: vector(seed: 3))],
            into: storage.rowStore)

        let loaded = try await store.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded.map(\.term) == ["new-a"],
                "a retrain must leave exactly the new generation, not a union with the old")
        await storage.close()
    }

    /// Two provider keys do not see each other's vocabulary.
    @Test("vocabulary is scoped per provider key")
    func vocabIsScopedPerProvider() async throws {
        let storage = try scratch()
        try await storage.migrate(to: legacySchemaV2)
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        let store = CorpusProviderCountsStore(storage: storage)

        try await store.replaceVocab(
            modelID: "ppmi-v1", modelVersion: modelVersion,
            terms: [(term: "shared-term", vector: vector(seed: 9))],
            into: storage.rowStore)
        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "shared-term", vector: vector(seed: 1))],
            into: storage.rowStore)

        let ri = try await store.loadVocab(modelID: modelID, modelVersion: modelVersion)
        let ppmi = try await store.loadVocab(modelID: "ppmi-v1", modelVersion: modelVersion)
        #expect(ri.count == 1 && ppmi.count == 1)
        #expect(ri[0].vector != ppmi[0].vector,
                "the same term under two providers must hold two distinct vectors")
        await storage.close()
    }

    /// A wholesale clear must not leave a previous generation's terms behind.
    @Test("deleteAll clears the term table too")
    func deleteAllClearsVocab() async throws {
        let storage = try scratch()
        try await storage.migrate(to: legacySchemaV2)
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        let store = CorpusProviderCountsStore(storage: storage)

        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "doomed", vector: vector(seed: 4))],
            into: storage.rowStore)
        try await store.deleteAll()

        let loaded = try await store.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded.isEmpty,
                "stale terms would outlive the counts row they belong to")
        await storage.close()
    }
}

// MARK: - Provider decomposition round-trip

import CorpusKitProviders

@Suite("ProviderCountsDecomposition", .serialized)
struct ProviderCountsDecompositionTests {

    /// Decompose → restore reproduces the identical vocabulary, and the
    /// header alone is still a decodable counts blob.
    ///
    /// The header staying decodable is load-bearing, not cosmetic: it is what
    /// keeps `corpus_provider_counts.counts` NOT NULL and non-empty after the
    /// split. A NULL or undecodable value there is read by every caller as
    /// "no counts, start from zero", which would silently discard an estate's
    /// accumulated statistics rather than fail.
    @Test("decomposeCounts round-trips through restoreCounts(header:terms:)")
    func decomposeRoundTrips() throws {
        let provider = RandomIndexingProvider(modelID: "random-indexing-v1", modelVersion: "1.1.0")
        provider.trainOnCorpus(texts: [
            "alpha beta gamma delta",
            "beta gamma epsilon",
            "gamma delta zeta eta theta"
        ])
        let originalSize = provider.countsVocabularySize
        #expect(originalSize > 0, "fixture must actually train a vocabulary")

        let decomposed = try #require(
            provider.decomposeCounts(),
            "RandomIndexing must offer a term decomposition — it is the provider whose counts scale with vocabulary")
        #expect(decomposed.terms.count == originalSize,
                "one entry per vocabulary term")

        // The header alone must still decode as a counts blob, yielding an
        // empty vocabulary rather than an error.
        let headerOnly = RandomIndexingProvider(modelID: "random-indexing-v1", modelVersion: "1.1.0")
        try headerOnly.restoreCounts(from: decomposed.header)
        #expect(headerOnly.countsVocabularySize == 0)

        // Full rehydration reproduces the original vocabulary exactly.
        let restored = RandomIndexingProvider(modelID: "random-indexing-v1", modelVersion: "1.1.0")
        try restored.restoreCounts(header: decomposed.header, terms: decomposed.terms)
        #expect(restored.countsVocabularySize == originalSize)

        // Byte-level equivalence: re-serializing the rehydrated provider must
        // reproduce the original blob exactly. This is the check that proves
        // the split did not perturb the cross-port conformance contract.
        #expect(restored.serializeCounts() == provider.serializeCounts(),
                "a decompose/restore cycle must be byte-transparent to the blob format")
    }

    /// No single term entry carries the whole map.
    @Test("each decomposed entry is one term's vector, not the map")
    func entriesAreBounded() throws {
        let provider = RandomIndexingProvider(modelID: "random-indexing-v1", modelVersion: "1.1.0")
        provider.trainOnCorpus(texts: ["alpha beta gamma", "delta epsilon zeta"])
        let decomposed = try #require(provider.decomposeCounts())

        let wholeBlob = provider.serializeCounts().count
        let widest = decomposed.terms.map(\.vector.count).max() ?? 0
        #expect(widest < wholeBlob,
                "a per-term entry must be strictly smaller than the whole serialized map")
        // 2048 f32 plus the u32 count prefix.
        #expect(widest == 2048 * 4 + 4,
                "expected one 2048-dimensional f32 vector per entry; got \(widest) bytes")
    }
}
