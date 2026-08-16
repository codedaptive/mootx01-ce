// SentinelPartialOverwriteTests.swift
//
// The migration invalidation sentinel must survive every write path except the
// full-corpus retrain that is entitled to replace it.
//
// The gap these cover: the original guard skipped the flush only when the
// in-memory accumulator was EMPTY, on the reasoning that "an accumulator with
// even one term is a genuine flush". In the window this sentinel exists to
// cover — after `mootx01 upgrade` writes it, before the queued full reindex
// runs — a single ingest is enough to put a term in the fresh accumulator. The
// flush then proceeded and wrote a valid PARTIAL blob over the sentinel.
//
// What made that expensive rather than merely wasteful: the migration preserves
// the old `doc_count` anchor. A later population guard could therefore see
// document count equal to the active chunk count, accept the partial counts as
// complete, and publish a basis trained only on post-migration content. The
// preexisting corpus silently stopped contributing to the index.
//
// Every test here FAILS against the previous guard, which is the point of
// writing them: a regression test that passes before the fix tests nothing.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
import CorpusKitProviders
@testable import CorpusKit

@Suite("Sentinel survives partial persists", .serialized)
struct SentinelPartialOverwriteTests {

    private let modelID = "random-indexing-v1"
    private let modelVersion = "1.1.0"
    private let now = Date(timeIntervalSince1970: 1_755_500_000)

    private func openStore() async throws -> (any Storage, CorpusProviderCountsStore) {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("sentinel-partial-\(UUID().uuidString).sqlite3"))))
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        return (storage, CorpusProviderCountsStore(storage: storage))
    }

    /// Writes the post-migration row shape: the sentinel, with the OLD document
    /// count preserved as the migration leaves it. That preserved anchor is what
    /// later lets a partial blob look complete, so it belongs in the fixture.
    private func seedPostMigrationRow(
        _ store: CorpusProviderCountsStore, _ rowStore: any RowStore,
        preservedDocumentCount: Int = 5_000
    ) async throws {
        try await store.upsert(
            PersistedCounts(
                modelID: modelID, modelVersion: modelVersion,
                counts: Data(),                       // the invalidation sentinel
                documentCount: preservedDocumentCount, // anchor the migration keeps
                vocabSize: 40_000, updatedAt: now),
            into: rowStore)
    }

    private func storedCounts(_ store: CorpusProviderCountsStore) async throws -> Data? {
        try await store.load(modelID: modelID, modelVersion: modelVersion)?.counts
    }

    /// The reported case: one ingest lands between the migration and the queued
    /// reindex, so the accumulator holds a term. That must NOT be enough to
    /// replace the sentinel.
    @Test("a partial persist with terms accumulated leaves the sentinel intact")
    func partialPersistWithTermsPreservesSentinel() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }
        try await seedPostMigrationRow(store, storage.rowStore)

        let provider = RandomIndexingProvider()
        provider.accumulateTraining(texts: ["arrived after the migration"])
        #expect(provider.countsVocabularySize > 0,
                "fixture must have a non-empty accumulator or it tests the old case")

        try await store.persistCounts(
            provider: provider, modelID: modelID, modelVersion: modelVersion,
            documentCount: 1, vocabSize: provider.countsVocabularySize,
            updatedAt: now, into: storage.rowStore)

        let after = try await storedCounts(store)
        #expect(after.map(CorpusProviderCountsStore.isInvalidatedCounts) == true,
                """
                A partial persist replaced the invalidation sentinel. The next \
                restore will accept those counts as real and publish a basis \
                trained only on post-migration content.
                """)
    }

    /// The case the original guard did cover, kept so the fix cannot regress it.
    @Test("a persist with an empty accumulator leaves the sentinel intact")
    func emptyPersistPreservesSentinel() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }
        try await seedPostMigrationRow(store, storage.rowStore)

        try await store.persistCounts(
            provider: RandomIndexingProvider(), modelID: modelID,
            modelVersion: modelVersion, documentCount: 0, vocabSize: 0,
            updatedAt: now, into: storage.rowStore)

        let after = try await storedCounts(store)
        #expect(after.map(CorpusProviderCountsStore.isInvalidatedCounts) == true)
    }

    /// The full-corpus retrain is the one path entitled to clear the sentinel.
    /// Without this the fix would be indistinguishable from never clearing it,
    /// and the estate would never recover from the migration.
    @Test("the full-corpus retrain replaces the sentinel")
    func retrainClearsSentinel() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }
        try await seedPostMigrationRow(store, storage.rowStore)

        let provider = RandomIndexingProvider()
        provider.accumulateTraining(texts: ["rebuilt from the whole corpus"])

        try await store.persistCounts(
            provider: provider, modelID: modelID, modelVersion: modelVersion,
            documentCount: 5_000, vocabSize: provider.countsVocabularySize,
            updatedAt: now, into: storage.rowStore,
            clearsInvalidation: true)

        let after = try await storedCounts(store)
        #expect(after.map(CorpusProviderCountsStore.isInvalidatedCounts) == false,
                "the retrain must be able to replace the sentinel, or nothing ever can")
    }

    /// A provider key with NO sentinel is ordinary and must persist normally.
    /// Without this, a fix that refused every non-retrain write would pass every
    /// other test here while breaking incremental persistence outright.
    @Test("a store with no sentinel persists normally")
    func normalPersistUnaffected() async throws {
        let (storage, store) = try await openStore()
        defer { Task { await storage.close() } }
        try await store.upsert(
            PersistedCounts(
                modelID: modelID, modelVersion: modelVersion,
                counts: Data([0x01, 0x02]), documentCount: 1,
                vocabSize: 1, updatedAt: now),
            into: storage.rowStore)

        let provider = RandomIndexingProvider()
        provider.accumulateTraining(texts: ["ordinary incremental write"])

        try await store.persistCounts(
            provider: provider, modelID: modelID, modelVersion: modelVersion,
            documentCount: 2, vocabSize: provider.countsVocabularySize,
            updatedAt: now, into: storage.rowStore)

        let after = try await storedCounts(store)
        #expect(after != nil && after != Data([0x01, 0x02]),
                "an incremental persist on a normal row must still write")
    }
}
