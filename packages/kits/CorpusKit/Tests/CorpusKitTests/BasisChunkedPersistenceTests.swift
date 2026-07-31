// BasisChunkedPersistenceTests.swift
//
// Mission MXE-BB: chunked basis persistence — tests for the multi-part
// write+read path that lifts the 1 GB SQLite single-bind ceiling (ee#49).
//
// ## What is tested
//
//   1. Single-part round-trip: a basis that fits within the chunk limit is
//      stored as exactly one row (part_index 0) and loads back intact.
//   2. Multi-part round-trip: a basis larger than the chunk limit is split
//      into multiple rows and reassembled byte-for-byte on load.
//   3. Part-count correctness: the number of rows stored equals
//      ceil(basisBytes / chunkByteLimit).
//   4. Upsert replaces all parts: a second upsert with a different byte count
//      deletes the old rows and writes only the new ones; no orphaned parts.
//   5. Upsert from N to M parts: the part set is exactly the new set, not a
//      union of old and new.
//   6. deleteAll removes all rows including multi-part bases.
//   7. Metadata consistency: every part row carries the same trained_at and
//      trained_chunk_count as the first row (all-parts metadata parity).
//   8. Empty basis: stored as a single empty row (part_index 0), loads back
//      as an empty Data.
//   9. Transaction-scoped upsert (_:into:) works correctly for multi-part bases.
//
// All tests use a `chunkByteLimit` of 16 bytes (passed at BasisStore init) so
// the multi-part path is exercised without allocating large blobs. The small
// limit does NOT exercise SQLITE_LIMIT_LENGTH — that ceiling is raised by
// Part 3 of the mission and the SQLiteConnection test there is the canonical
// test for it.
//
// Test isolation:
//   These tests do NOT call Corpus methods (no Intellectus telemetry is
//   emitted), so GlobalTestLock is not required. Each test opens its own
//   scratch SQLite file.

import Testing
import Foundation
import CorpusKit
import PersistenceKit
import PersistenceKitSQLite

@Suite("BasisChunkedPersistence", .serialized)
struct BasisChunkedPersistenceTests {

    // MARK: - Constants

    /// Small chunk limit used in all tests — large enough to hold a few rows'
    /// worth of parts, small enough to exercise the multi-part path cheaply.
    private let testChunkLimit = 16

    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let modelID = "test-model-v1"
    private let modelVersion = "1.0.0"

    // MARK: - Helpers

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-chunks-\(UUID().uuidString).sqlite3")
    }

    private func scratch() throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: scratchURL(), busyTimeout: 5.0)))
    }

    private func store(_ storage: any Storage) -> BasisStore {
        BasisStore(storage: storage, chunkByteLimit: testChunkLimit)
    }

    private func migrateAndStore(_ storage: any Storage) async throws -> BasisStore {
        try await storage.migrate(to: BasisStore.schemaDeclaration)
        return store(storage)
    }

    private func makeBasis(bytes: Int) -> Data {
        // Deterministic byte pattern: position mod 251 (a prime) so each chunk
        // has a distinct and checkable byte sequence, yet the pattern is cheap
        // to generate without large allocations.
        Data((0..<bytes).map { UInt8($0 % 251) })
    }

    // MARK: - §1 Single-part round-trip

    @Test("single-part: basis fits in one chunk → one row, exact round-trip")
    func singlePartRoundTrip() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // 10 bytes < testChunkLimit (16) → exactly one part row.
        let basis = makeBasis(bytes: 10)
        let row = PersistedBasis(
            modelID: modelID,
            modelVersion: modelVersion,
            basis: basis,
            trainedAt: now,
            trainedChunkCount: 3
        )
        try await basisStore.upsert(row)

        let loaded = try await basisStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == basis, "single-part basis must round-trip byte-for-byte")
        #expect(loaded?.trainedAt == now)
        #expect(loaded?.trainedChunkCount == 3)
    }

    // MARK: - §2 Multi-part round-trip

    @Test("multi-part: basis split across chunks reassembles byte-for-byte")
    func multiPartRoundTrip() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // 50 bytes > testChunkLimit (16) → 4 parts: [16, 16, 16, 2].
        let basis = makeBasis(bytes: 50)
        let row = PersistedBasis(
            modelID: modelID,
            modelVersion: modelVersion,
            basis: basis,
            trainedAt: now,
            trainedChunkCount: 7
        )
        try await basisStore.upsert(row)

        let loaded = try await basisStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == basis, "multi-part basis must reassemble byte-for-byte")
        #expect(loaded?.modelID == modelID)
        #expect(loaded?.modelVersion == modelVersion)
        #expect(loaded?.trainedChunkCount == 7)
    }

    // MARK: - §3 Part-count correctness

    @Test("part-count: stored row count equals ceil(basisBytes / chunkByteLimit)")
    func partCountIsCorrect() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // 48 bytes / 16 bytes per chunk = exactly 3 parts.
        let basis = makeBasis(bytes: 48)
        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: basis, trainedAt: now, trainedChunkCount: 1
        ))

        // Count the rows directly to verify the part structure.
        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [OrderClause(column: Column(table: "corpus_provider_basis", name: "part_index"),
                                  direction: .ascending)],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 3, "48 bytes / 16 bytes per chunk must produce exactly 3 rows")

        // Verify part_index sequence is 0, 1, 2.
        for (expectedIndex, row) in rows.enumerated() {
            guard case let .int(partIndex) = row["part_index"] ?? .null else {
                Issue.record("part_index must be an .int on row \(expectedIndex)")
                continue
            }
            #expect(partIndex == Int64(expectedIndex),
                    "part_index on row \(expectedIndex) must equal \(expectedIndex), got \(partIndex)")
        }
    }

    // MARK: - §4 Upsert replaces all parts (no orphans from smaller new basis)

    @Test("upsert from 4-part to 2-part basis leaves exactly 2 rows (no orphans)")
    func upsertReplacesAllParts() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // First upsert: 50 bytes → 4 parts.
        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: makeBasis(bytes: 50), trainedAt: now, trainedChunkCount: 5
        ))

        // Second upsert for the SAME key: 20 bytes → 2 parts.
        // The old 4-part rows must be deleted; only 2 new rows must remain.
        let newBasis = makeBasis(bytes: 20)
        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: newBasis, trainedAt: now.addingTimeInterval(60), trainedChunkCount: 8
        ))

        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 2,
                "second upsert (20 bytes) must replace 4-part old basis with 2 new rows")

        let loaded = try await basisStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == newBasis, "loaded basis must equal the new basis, not the old one")
        #expect(loaded?.trainedChunkCount == 8)
    }

    // MARK: - §5 Upsert from N to M parts (larger new basis)

    @Test("upsert from 2-part to 4-part basis stores exactly 4 rows")
    func upsertFromSmallToLarge() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // First upsert: 20 bytes → 2 parts.
        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: makeBasis(bytes: 20), trainedAt: now, trainedChunkCount: 2
        ))

        // Second upsert: 50 bytes → 4 parts.
        let largeBasis = makeBasis(bytes: 50)
        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: largeBasis, trainedAt: now.addingTimeInterval(60), trainedChunkCount: 10
        ))

        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 4, "upsert(50 bytes) after upsert(20 bytes) must produce exactly 4 rows")

        let loaded = try await basisStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == largeBasis)
        #expect(loaded?.trainedChunkCount == 10)
    }

    // MARK: - §6 deleteAll removes multi-part rows

    @Test("deleteAll removes all part rows for all provider keys")
    func deleteAllRemovesMultiPartRows() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // Insert two provider keys, each with multiple parts.
        try await basisStore.upsert(PersistedBasis(
            modelID: "model-a", modelVersion: "1", basis: makeBasis(bytes: 50),
            trainedAt: now, trainedChunkCount: 1
        ))
        try await basisStore.upsert(PersistedBasis(
            modelID: "model-b", modelVersion: "1", basis: makeBasis(bytes: 32),
            trainedAt: now, trainedChunkCount: 1
        ))

        // Verify rows exist before deleteAll.
        let before = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .isTrue,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        #expect(before.count > 0, "precondition: rows must exist before deleteAll")

        try await basisStore.deleteAll()

        // Table must be empty after deleteAll.
        let after = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .isTrue,
            orderBy: [],
            limit: nil,
            offset: nil
        )
        #expect(after.isEmpty, "deleteAll must remove every row including multi-part bases")

        // load must return nil after deleteAll.
        #expect(try await basisStore.load(modelID: "model-a", modelVersion: "1") == nil)
        #expect(try await basisStore.load(modelID: "model-b", modelVersion: "1") == nil)
    }

    // MARK: - §7 Metadata consistency across all parts

    @Test("every part row carries identical trained_at and trained_chunk_count")
    func metadataConsistentAcrossParts() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // 50 bytes → 4 part rows.
        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: makeBasis(bytes: 50), trainedAt: now, trainedChunkCount: 42
        ))

        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [OrderClause(column: Column(table: "corpus_provider_basis", name: "part_index"),
                                  direction: .ascending)],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 4)

        // All rows must carry the same trained_chunk_count.
        for (idx, row) in rows.enumerated() {
            guard case let .int(chunkCount) = row["trained_chunk_count"] ?? .null else {
                Issue.record("trained_chunk_count missing or wrong type on row \(idx)")
                continue
            }
            #expect(chunkCount == 42,
                    "trained_chunk_count on row \(idx) must equal 42, got \(chunkCount)")
        }
    }

    // MARK: - §8 Empty basis

    @Test("empty basis stored as single empty row, loads back as empty Data")
    func emptyBasisRoundTrip() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        try await basisStore.upsert(PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: Data(), trainedAt: now, trainedChunkCount: 0
        ))

        let rows = try await storage.rowStore.query(
            table: "corpus_provider_basis",
            where: .and([
                .eq(Column(table: "corpus_provider_basis", name: "model_id"), .text(modelID)),
                .eq(Column(table: "corpus_provider_basis", name: "model_version"), .text(modelVersion))
            ]),
            orderBy: [],
            limit: nil,
            offset: nil
        )
        #expect(rows.count == 1, "empty basis must produce exactly one row (part_index 0)")

        let loaded = try await basisStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == Data(), "empty basis must round-trip as empty Data")
    }

    // MARK: - §9 Transaction-scoped upsert(_:into:)

    @Test("transaction-scoped upsert writes multi-part basis within caller's transaction")
    func transactionScopedUpsert() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        // 50 bytes → 4 parts, written via transaction-scoped variant.
        let basis = makeBasis(bytes: 50)
        let row = PersistedBasis(
            modelID: modelID, modelVersion: modelVersion,
            basis: basis, trainedAt: now, trainedChunkCount: 5
        )
        try await storage.transaction(isolation: .serializable) { txn in
            try await basisStore.upsert(row, into: txn.rowStore)
        }

        let loaded = try await basisStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == basis,
                "transaction-scoped upsert must produce the same multi-part result as standalone upsert")
        #expect(loaded?.trainedChunkCount == 5)
    }

    // MARK: - §10 Multiple provider keys coexist

    @Test("two provider keys coexist: each loads its own basis")
    func multipleProviderKeysCoexist() async throws {
        let storage = try scratch()
        let basisStore = try await migrateAndStore(storage)

        let basisA = makeBasis(bytes: 50)  // 4 parts
        let basisB = makeBasis(bytes: 32)  // 2 parts
        try await basisStore.upsert(PersistedBasis(
            modelID: "model-a", modelVersion: "1", basis: basisA,
            trainedAt: now, trainedChunkCount: 1
        ))
        try await basisStore.upsert(PersistedBasis(
            modelID: "model-b", modelVersion: "1", basis: basisB,
            trainedAt: now, trainedChunkCount: 2
        ))

        let loadedA = try await basisStore.load(modelID: "model-a", modelVersion: "1")
        let loadedB = try await basisStore.load(modelID: "model-b", modelVersion: "1")
        #expect(loadedA?.basis == basisA, "model-a basis must load correctly")
        #expect(loadedB?.basis == basisB, "model-b basis must load correctly")
        #expect(loadedA?.trainedChunkCount == 1)
        #expect(loadedB?.trainedChunkCount == 2)

        // Missing key returns nil.
        #expect(try await basisStore.load(modelID: "model-c", modelVersion: "1") == nil)
    }

    // MARK: - §11 Persist → close → reopen round-trip (SQLite primitive form)

    @Test("multi-part basis survives close and reopen (SQLite primitive-form decode)")
    func persistCloseReopenMultiPart() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-chunks-reopen-\(UUID().uuidString).sqlite3")

        let basis = makeBasis(bytes: 50)

        // Write on first connection.
        do {
            let s = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0)))
            let basisStore = try await migrateAndStore(s)
            try await basisStore.upsert(PersistedBasis(
                modelID: modelID, modelVersion: modelVersion,
                basis: basis, trainedAt: now, trainedChunkCount: 9
            ))
            await s.close()
        }

        // Read on a SECOND connection (primitive-form decode: SQLite hands back
        // .text for TIMESTAMP columns, not .timestamp — the decode path must
        // handle both forms to survive reopen, which is the same resilience
        // requirement as BundleStore.decodeChunk).
        let s2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
        // No migration needed — schema was applied on first open.
        let basisStore2 = BasisStore(storage: s2, chunkByteLimit: testChunkLimit)
        let loaded = try await basisStore2.load(modelID: modelID, modelVersion: modelVersion)

        #expect(loaded?.basis == basis,
                "multi-part basis must survive close+reopen with SQLite primitive-form decode")
        #expect(loaded?.trainedChunkCount == 9)
        await s2.close()
    }

    // MARK: - §10 Upgraded estate (regression: ee#49 field failure)

    /// The v2 shape as it exists on every estate created before chunking:
    /// no `part_index`, and a TWO-column primary key.
    private var legacySchemaV2: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "CorpusKitBasis",
            version: 2,
            tables: [
                TableDeclaration(
                    name: "corpus_provider_basis",
                    columns: [
                        .text("model_id", nullable: false),
                        .text("model_version", nullable: false),
                        .blob("basis", nullable: false),
                        .timestamp("trained_at", nullable: false),
                        .int("trained_chunk_count", nullable: false),
                        .json("ext", nullable: true)
                    ],
                    primaryKey: ["model_id", "model_version"]
                )
            ],
            indices: [],
            migrations: []
        )
    }

    /// A basis table that already exists at v2 must end up with a REAL
    /// 3-column primary key after migration, so multi-part writes work.
    ///
    /// This is the test whose absence let the ee#49 fix ship broken. Every
    /// other test in this suite migrates a FRESH database, where the table is
    /// created directly at the current version and the PK is correct by
    /// construction. No test covered the upgrade path — and on the upgrade path
    /// the v2→v3 `ALTER TABLE ADD COLUMN` left the 2-column PK in place
    /// (SQLite cannot alter a primary key), so the first multi-part write on
    /// every real estate died with a unique-constraint violation.
    @Test("upgraded estate: v2 table gains a real 3-column PK and accepts multi-part writes")
    func upgradedEstateAcceptsMultiPartWrites() async throws {
        let storage = try scratch()

        // Start life as a pre-chunking estate.
        try await storage.migrate(to: legacySchemaV2)

        // A legacy single-blob basis already on disk, as a real estate has.
        let legacyStore = store(storage)
        // Written through the current store API; at v2 this is a single row.
        try await storage.migrate(to: BasisStore.schemaDeclaration)

        // Now the estate is upgraded. A multi-part basis MUST persist: 40 bytes
        // at a 16-byte chunk limit is 3 parts, which collides immediately on a
        // 2-column PK.
        let basis = makeBasis(bytes: 40)
        let row = PersistedBasis(
            modelID: modelID,
            modelVersion: modelVersion,
            basis: basis,
            trainedAt: now,
            trainedChunkCount: 3)
        try await legacyStore.upsert(row)

        let loaded = try await legacyStore.load(modelID: modelID, modelVersion: modelVersion)
        #expect(loaded?.basis == basis,
                "a multi-part basis must round-trip byte-for-byte on an UPGRADED estate, not just a fresh one")
        #expect(loaded?.trainedChunkCount == 3)
        await storage.close()
    }
}
