// CorpusCountsMigrationConvergenceTests.swift — CORPUS-COUNTS-01 convergence gate.
//
// Exercises the v3→v4 migration path end to end at the store layer, mirroring
// what `mootx01 upgrade` does via `run_corpus_counts_migration`:
//
//   1. DELETE FROM corpus_provider_vocab WHERE TRUE  (legacy vocab rows gone)
//   2. UPDATE corpus_provider_counts SET counts = X'' WHERE TRUE  (blobs zeroed)
//   3. reindexRequired(queue:storage:now:)            (latch set)
//
// Two assertions:
//
//   A. After migration: legacy rows gone, anchors (doc_count/vocab_size)
//      preserved from the pre-migration values, latch bit set.
//
//   B. After writing v4 term payloads to BOTH a migrated estate and a fresh v4
//      estate, `restoreCounts` returns identical vocabulary — the two paths
//      converge at the read layer.
//
// These tests start from a POPULATED OLDER LAYOUT, matching the rule in
// ProviderVocabStorageTests.swift: tests that migrate fresh databases hide
// real migration bugs (the exact failure shape of ee#49's v3 lazy path).

import Testing
import Foundation
@testable import CorpusKit
import PersistenceKit
import PersistenceKitSQLite
import PersistenceKitInMemory
import QueueKit
import SubstrateTypes

// MARK: - Schema helpers

/// The v3 CorpusKitCounts schema: three tables (counts, references, vocab).
/// Matches the state an estate was in BEFORE the CORPUS-COUNTS-01 migration.
private func v3Schema() -> SchemaDeclaration {
    SchemaDeclaration(
        kitID: "CorpusKitCounts",
        version: 3,
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
            ),
            TableDeclaration(
                name: "corpus_provider_vocab",
                columns: [
                    .text("model_id", nullable: false),
                    .text("model_version", nullable: false),
                    .text("term", nullable: false),
                    .blob("vector", nullable: false),
                    .json("ext", nullable: true)
                ],
                primaryKey: ["model_id", "model_version", "term"]
            )
        ],
        indices: [],
        migrations: []
    )
}

/// Open a fresh on-disk SQLite storage file. SQLite is required for migration
/// tests: InMemoryStorage cannot run schema migrations (it always starts
/// fresh) and would silently hide decode regressions (it returns semantic
/// TypedValues rather than primitive .text/.int on read, masking real
/// round-trip bugs — same rationale as TestScratchStorage.swift).
private func sqliteScratch() throws -> any Storage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("corpuskit-convergence-\(UUID().uuidString).sqlite3")
    return try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
}

/// Open a fresh in-memory QueueKit for the latch call. In-memory is acceptable
/// for the latch in migration tests — we verify job presence, not crash recovery.
private func inMemoryQueue() async throws -> QueueKit {
    let st = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    try await PersistenceKitBackend.openSchema(on: st)
    let backend = PersistenceKitBackend(storage: st)
    return QueueKit(backend: backend)
}

/// One term's payload (8192 bytes = 2048 f32): deterministic, not all-zero.
private func termVector(seed: UInt8) -> Data {
    Data((0..<8192).map { UInt8(($0 + Int(seed)) % 251) })
}

// MARK: - Migration convergence test suite

@Suite("CorpusCountsMigrationConvergence", .serialized)
struct CorpusCountsMigrationConvergenceTests {

    private let modelID = "random-indexing-v1"
    private let modelVersion = "1.1.0"
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    // MARK: - Test A: migration leaves legacy rows gone, anchors preserved, latch set

    /// Simulates `run_corpus_counts_migration` at the store layer on a v3 estate
    /// and asserts the three invariants the upgrade step must satisfy:
    ///   1. Legacy vocab rows are gone (`loadVocab` returns empty).
    ///   2. Growth anchors (doc_count / vocab_size) are preserved — they are
    ///      NOT in the update's values map in the Rust upgrade step.
    ///   3. The reindex latch bit is set in the estate manifest.
    @Test("v3→v4 migration: legacy vocab gone, anchors preserved, latch set")
    func migrationClearsVocabPreservesAnchorsAndSetsLatch() async throws {
        // ── Build a populated v3 estate ──────────────────────────────────────
        let storage = try sqliteScratch()
        try await storage.migrate(to: v3Schema())

        let store = CorpusProviderCountsStore(storage: storage)
        let legacyBlob = Data("legacy-counts-blob".utf8)

        // Write a counts row with non-trivial anchors that must survive migration.
        try await store.upsert(PersistedCounts(
            modelID: modelID, modelVersion: modelVersion,
            counts: legacyBlob, documentCount: 42, vocabSize: 17,
            updatedAt: now))

        // Write legacy vocab rows (v3 layout).
        try await store.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [
                (term: "alpha", vector: termVector(seed: 1)),
                (term: "beta",  vector: termVector(seed: 2)),
                (term: "gamma", vector: termVector(seed: 3))
            ],
            into: storage.rowStore)

        // Confirm legacy rows exist before migration.
        let vocabBefore = try await store.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(vocabBefore.count == 3, "fixture must have 3 legacy vocab rows before migration")

        // ── Migrate to v4 ────────────────────────────────────────────────────
        // The v3→v4 migration creates the integer-keyed pair tables (CREATEs
        // only — no existing row is read or rewritten in the open path, per ee#49).
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)

        // Confirm legacy rows still present after schema migration: the open
        // path does NO bulk transform. This is the property that keeps ee#49 from
        // repeating. The upgrade step (step below) is what clears them.
        let vocabAfterSchemaUpgrade = try await store.loadVocab(
            modelID: modelID, modelVersion: modelVersion)
        #expect(
            vocabAfterSchemaUpgrade.count == 3,
            "legacy vocab rows must survive schema migration — the open path does no bulk transform")

        // ── Simulate run_corpus_counts_migration (upgrade step) ───────────────
        // Mirrors the three operations `apps/mootx01/rust/src/commands/upgrade.rs`
        // `run_corpus_counts_migration()` performs:
        //
        //   1. DELETE FROM corpus_provider_vocab WHERE TRUE
        _ = try await storage.rowStore.delete(table: "corpus_provider_vocab", where: .isTrue)

        //   2. UPDATE corpus_provider_counts SET counts = X'' WHERE TRUE
        //      doc_count and vocab_size are NOT in the update — anchors survive.
        _ = try await storage.rowStore.update(
            table: "corpus_provider_counts",
            values: ["counts": .blob(Data())],
            where: .isTrue)

        //   3. reindexRequired(queue:storage:now:) — the snap-fit latch.
        let queue = try await inMemoryQueue()
        // The manifest table lives on the estate too — the latch writes to it.
        // For this test, we add a minimal manifest table to the same storage
        // so the latch has a place to write its flag (mirroring the real estate
        // layout where the manifest table is part of the LocusKit schema).
        try await storage.migrate(to: SchemaDeclaration(
            kitID: "ManifestForConvergenceTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "manifest",
                    columns: [
                        .text("key", nullable: false),
                        .text("value", nullable: false)
                    ],
                    primaryKey: ["key"]
                )
            ],
            indices: [],
            migrations: []))
        try await reindexRequired(queue: queue, storage: storage, now: now)

        // ── Assertions ───────────────────────────────────────────────────────

        // 1. Legacy vocab rows are gone.
        let vocabAfterUpgrade = try await store.loadVocab(modelID: modelID, modelVersion: modelVersion)
        #expect(
            vocabAfterUpgrade.isEmpty,
            "legacy vocab rows must be gone after the upgrade step (DELETE FROM corpus_provider_vocab WHERE TRUE)")

        // 2. v4 term rows are also empty (no v4 data written yet — that happens
        //    at next retrain after the reindex latch fires).
        let v4Terms = try await store.loadTermPayloads(modelID: modelID)
        #expect(
            v4Terms.isEmpty,
            "v4 term payload rows must be empty immediately after migration — retrain writes them")

        // 3. Anchors (doc_count, vocab_size) survived. The upgrade step zeroes
        //    the blob but does NOT touch the anchor columns.
        let anchor = try await store.growthAnchor(modelID: modelID, modelVersion: modelVersion)
        let a = try #require(anchor, "growth anchor must exist — the counts row was not deleted")
        #expect(a.documentCount == 42, "doc_count must be preserved through the upgrade step")
        #expect(a.vocabSize == 17, "vocab_size must be preserved through the upgrade step")

        // 4. Reindex latch bit is set in the manifest.
        let manifestRows = try await storage.rowStore.query(
            table: "manifest",
            where: .eq(Column(table: "manifest", name: "key"), .text(reindexManifestKey)),
            orderBy: [], limit: 1, offset: nil)
        #expect(!manifestRows.isEmpty, "manifest must carry the reindex-required flag after migration")
        if let row = manifestRows.first, case let .text(v) = row["value"] ?? .null {
            #expect(v == "1", "latch flag value must be '1', got '\(v)'")
        }

        await storage.close()
    }

    // MARK: - Test B: restore/query behavior equivalent on fresh vs migrated estate

    /// Writes identical v4 term payloads to BOTH a freshly-provisioned v4 estate
    /// and an estate that was migrated from v3. Asserts that `loadTermPayloads`
    /// returns identical output on both — the two paths converge at the read layer.
    ///
    /// This is the "composite schema signature" convergence check: same v4 data
    /// written via the same API must be indistinguishable after the migration step.
    @Test("fresh v4 and migrated v4 produce identical restore/query behavior")
    func freshAndMigratedV4Converge() async throws {
        let termData = [
            (term: "alpha", vector: termVector(seed: 10)),
            (term: "beta",  vector: termVector(seed: 20)),
            (term: "gamma", vector: termVector(seed: 30))
        ]

        // ── Fresh v4 estate ──────────────────────────────────────────────────
        let freshStorage = try sqliteScratch()
        try await freshStorage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        let freshStore = CorpusProviderCountsStore(storage: freshStorage)

        // Seed a counts row so the store is in a valid state (the header blob is
        // required to be NOT NULL).
        try await freshStore.upsert(PersistedCounts(
            modelID: modelID, modelVersion: modelVersion,
            counts: Data(), documentCount: 5, vocabSize: 3, updatedAt: now))

        try await freshStore.replaceTermPayloads(
            modelID: modelID, terms: termData, into: freshStorage.rowStore)

        let freshTerms = try await freshStore.loadTermPayloads(modelID: modelID)

        // ── Migrated v4 estate ───────────────────────────────────────────────
        let migratedStorage = try sqliteScratch()
        try await migratedStorage.migrate(to: v3Schema())
        let migratedStore = CorpusProviderCountsStore(storage: migratedStorage)

        // Write the legacy layout (as a fielded estate has).
        let legacyBlob = Data("some-counts-blob".utf8)
        try await migratedStore.upsert(PersistedCounts(
            modelID: modelID, modelVersion: modelVersion,
            counts: legacyBlob, documentCount: 5, vocabSize: 3, updatedAt: now))
        try await migratedStore.replaceVocab(
            modelID: modelID, modelVersion: modelVersion,
            terms: [(term: "old-term", vector: termVector(seed: 99))],
            into: migratedStorage.rowStore)

        // Migrate schema to v4.
        try await migratedStorage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)

        // Apply upgrade step (clears legacy rows, zeroes blob).
        _ = try await migratedStorage.rowStore.delete(table: "corpus_provider_vocab", where: .isTrue)
        _ = try await migratedStorage.rowStore.update(
            table: "corpus_provider_counts",
            values: ["counts": .blob(Data())],
            where: .isTrue)

        // Now write the same v4 term payloads as the fresh estate.
        try await migratedStore.replaceTermPayloads(
            modelID: modelID, terms: termData, into: migratedStorage.rowStore)

        let migratedTerms = try await migratedStore.loadTermPayloads(modelID: modelID)

        // ── Convergence assertion ─────────────────────────────────────────────
        // Both estates must return the same terms after the v4 write. Order is
        // not guaranteed by the store API, so compare as sorted dictionaries.
        // Both estates must carry the same number of terms after the v4 write.
        let freshCount = freshTerms.count
        let migratedCount = migratedTerms.count
        #expect(
            freshCount == migratedCount,
            "fresh v4 and migrated v4 must return the same number of terms (check both count equal \(freshCount))")

        let freshDict = Dictionary(uniqueKeysWithValues: freshTerms.map { ($0.term, $0.vector) })
        let migratedDict = Dictionary(uniqueKeysWithValues: migratedTerms.map { ($0.term, $0.vector) })

        for (term, freshVector) in freshDict {
            guard let migratedVector = migratedDict[term] else {
                Issue.record("term '\(term)' present in fresh estate but absent in migrated estate")
                continue
            }
            #expect(
                freshVector == migratedVector,
                "term '\(term)': fresh vector must equal migrated vector byte-for-byte")
        }

        await freshStorage.close()
        await migratedStorage.close()
    }

    /// deleteAll must clear EVERY layout — v3 vocab AND the v4 pair. The v4
    /// gap shipped once (wave-closing Adams CRITICAL 1): destroyRecallIndex
    /// left dictionary/payload rows behind, and the restore path PREFERS the
    /// v4 pair, so the stale vocabulary shadowed the truth.
    @Test("deleteAll clears v3 vocab and the v4 dictionary/payload pair")
    func deleteAllClearsEveryLayout() async throws {
        let storage = try sqliteScratch()
        try await storage.migrate(to: CorpusProviderCountsStore.schemaDeclaration)
        let store = CorpusProviderCountsStore(storage: storage)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await store.upsert(PersistedCounts(
            modelID: "random-indexing-v1", modelVersion: "1",
            counts: Data("blob".utf8), documentCount: 1, vocabSize: 1, updatedAt: now))
        try await store.replaceVocab(
            modelID: "random-indexing-v1", modelVersion: "1",
            terms: [(term: "legacy", vector: Data([9]))], into: storage.rowStore)
        try await store.replaceTermPayloads(
            modelID: "random-indexing-v1",
            terms: [(term: "modern", vector: Data([7]))], into: storage.rowStore)
        // Populated pre-state in BOTH layouts (falsification anchor).
        #expect(try await store.loadTermPayloads(modelID: "random-indexing-v1").count == 1)
        #expect(try await store.loadVocab(modelID: "random-indexing-v1", modelVersion: "1").count == 1)

        try await store.deleteAll()

        #expect(try await store.loadTermPayloads(modelID: "random-indexing-v1").isEmpty,
                "v4 payloads must not survive deleteAll — stale v4 shadows the restore path")
        #expect(try await store.loadVocab(modelID: "random-indexing-v1", modelVersion: "1").isEmpty,
                "v3 vocab must not survive deleteAll")
        let dictRows = try await storage.rowStore.query(
            table: "corpus_provider_term_dictionary", where: .isTrue,
            orderBy: [], limit: nil, offset: nil)
        #expect(dictRows.isEmpty, "dictionary rows must not survive deleteAll")
        await storage.close()
    }

}
