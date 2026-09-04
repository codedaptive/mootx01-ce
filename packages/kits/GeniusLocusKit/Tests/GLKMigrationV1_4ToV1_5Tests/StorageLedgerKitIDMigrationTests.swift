#if GLK_MIGRATION_V1_4_TO_V1_5

// StorageLedgerKitIDMigrationTests.swift
//
// Verifies that GLKMigrationCatalog.prepare runs the 1.4→1.5 capsule, which
// moves the vector tier's schema-version ledger rows from their VectorKit ids
// to their SynapseKit ids (same version, nothing else touched) and stamps the
// estate format v1_5.
//
// Tests:
//   1. v1_4-stamped estate carrying the two old rows: after prepare the rows
//      carry the new ids at the same versions, the old ids have no row, a
//      bystander row is untouched, and the estate is stamped v1_5.
//   2. Idempotence: a second prepare is a no-op; running the capsule directly
//      again reports `.noRow` for both pairs and leaves the stamp at v1_5.
//   3. An estate with no vector rows: the capsule reports `.noRow` for both
//      pairs, creates nothing, and stamps v1_5.
//   4. Rows under both ids: both are left as they are and reported as
//      `.conflict`; the stamp still advances.
//   5. Fresh estate (nil stamp): prepare stamps v1_5 without running any
//      capsule and without creating a row under either id.
//   6. v1_0-stamped estate carrying the old rows: the full chain ends at
//      v1_5 (the rewrite runs before the 1.0→1.1 capsule, which opens the
//      vector store).
//   7. The capsule's pairs are the frozen literals, and the new ids are what
//      the vector tier's stores declare, so a migrated ledger is the ledger
//      those stores look their version up in.
//   8. On a SQLite estate a pre-rename runtime left behind, the renamed
//      store's ladder finds its row after the capsule and nothing runs;
//      without the capsule the ladder replays from version 0: v5→v6
//      rebuilds `vectors` and folds every row's generation to 0, and the
//      ledger keeps a duplicate row under the old id (the failure, observed).

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import SynapseKit
import Testing
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_4ToV1_5

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig15")
private let testNow = Date(timeIntervalSince1970: 1_756_000_000)
private let pairs = GeniusLocusKit.storageLedgerKitIDRenames

/// Record a schema-version ledger row for `kitID` at `version` without
/// declaring any table: the same row the vector tier's stores leave behind
/// when they open an estate.
private func seedLedger(_ storage: any Storage, kitID: String, version: Int) async throws {
    try await storage.migrate(to: SchemaDeclaration(kitID: kitID, version: version, tables: []))
}

/// An in-memory estate stamped at `stamp` (or unstamped when nil), carrying
/// the old vector-tier ledger rows when `withOldRows`, opened in a fresh
/// GeniusLocusKit instance.
private func makeEstate(
    stampedAt stamp: EstateFormatVersion?,
    withOldRows: Bool = true
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, storage: InMemoryStorage) {
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
    if withOldRows {
        try await seedLedger(storage, kitID: pairs.vectorStore.from, version: 6)
        try await seedLedger(storage, kitID: pairs.representationClaims.from, version: 1)
    }
    if let stamp {
        try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)
    }
    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage,
        owner: testOwner,
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    return (kit, handle, storage)
}

private func version(_ storage: any Storage, _ kitID: String) async throws -> Int {
    try await storage.currentSchemaVersion(for: kitID)
}

@Suite("StorageLedgerKitIDMigration", .serialized)
struct StorageLedgerKitIDMigrationTests {

    // MARK: §1 Core: the rows move, nothing else changes, v1_5 stamped

    @Test
    func v1_4EstateRowsMoveToTheirNewIds() async throws {
        let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_4)
        try await seedLedger(storage, kitID: "Bystander", version: 9)
        let locusBefore = try await version(storage, "LocusKit")
        #expect(try await version(storage, pairs.vectorStore.from) == 6)
        #expect(try await version(storage, pairs.representationClaims.from) == 1)
        #expect(try await version(storage, pairs.vectorStore.to) == 0)

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_5)
        #expect(prep.format == .current)
        #expect(prep.migrated == false)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_5)

        #expect(try await version(storage, pairs.vectorStore.to) == 6)
        #expect(try await version(storage, pairs.representationClaims.to) == 1)
        #expect(try await version(storage, pairs.vectorStore.from) == 0)
        #expect(try await version(storage, pairs.representationClaims.from) == 0)
        #expect(try await version(storage, "Bystander") == 9)
        #expect(try await version(storage, "LocusKit") == locusBefore)
    }

    // MARK: §2 Idempotence

    @Test
    func prepareTwiceIsNoOpAndDirectRerunReportsNoRow() async throws {
        let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_4)
        let first = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(first.format == .v1_5)
        let second = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(second.format == .v1_5)
        #expect(second.migrated == false)

        let report = try await kit.runStorageLedgerKitIDMigration(handle: handle, now: testNow)
        #expect(report == StorageLedgerKitIDMigrationReport(vectorStore: .noRow, representationClaims: .noRow))
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_5)
        #expect(try await version(storage, pairs.vectorStore.to) == 6)
        #expect(try await version(storage, pairs.representationClaims.to) == 1)
    }

    // MARK: §3 No vector rows: nothing created, still stamped

    @Test
    func estateWithoutVectorRowsIsStampedWithoutChange() async throws {
        let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_4, withOldRows: false)
        let report = try await kit.runStorageLedgerKitIDMigration(handle: handle, now: testNow)
        #expect(report == StorageLedgerKitIDMigrationReport(vectorStore: .noRow, representationClaims: .noRow))
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_5)
        #expect(try await version(storage, pairs.vectorStore.to) == 0)
        #expect(try await version(storage, pairs.vectorStore.from) == 0)
        #expect(try await version(storage, pairs.representationClaims.to) == 0)
        #expect(try await version(storage, pairs.representationClaims.from) == 0)
    }

    // MARK: §4 Rows under both ids are reported and left alone

    @Test
    func rowsUnderBothIdsAreAConflictLeftInPlace() async throws {
        let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_4)
        try await seedLedger(storage, kitID: pairs.vectorStore.to, version: 6)

        let report = try await kit.rewriteStorageLedgerKitIDs(handle: handle)
        #expect(report.vectorStore == .conflict(oldVersion: 6, newVersion: 6))
        #expect(report.representationClaims == .renamed(version: 1))
        #expect(try await version(storage, pairs.vectorStore.from) == 6)
        #expect(try await version(storage, pairs.vectorStore.to) == 6)

        // The stamp still advances: the conflict is reported, never a refusal.
        _ = try await kit.runStorageLedgerKitIDMigration(handle: handle, now: testNow)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_5)
    }

    // MARK: §5 Fresh estate (nil stamp)

    @Test
    func freshEstateStampsCurrentWithoutRunningTheCapsule() async throws {
        let (kit, handle, storage) = try await makeEstate(stampedAt: nil, withOldRows: false)
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .current)
        #expect(prep.format == .v1_5)
        #expect(prep.migrated == false)
        #expect(prep.migrationState == nil)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_5)
        #expect(try await version(storage, pairs.vectorStore.to) == 0)
        #expect(try await version(storage, pairs.vectorStore.from) == 0)
    }

    // MARK: §6 Full chain from v1_0 ends at v1_5

    #if GLK_MIGRATION_V1_0_TO_V1_1
    @Test
    func v1_0EstateRunsFullChainToCurrent() async throws {
        let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_0)
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_5)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_5)
        #expect(try await version(storage, pairs.vectorStore.to) >= 6)
        #expect(try await version(storage, pairs.representationClaims.to) >= 1)
    }
    #endif

    // MARK: §7 The pairs are frozen literals and the new ids are the stores' ids

    @Test
    func pairsAreFrozenLiteralsAndTargetTheDeclaredStoreIds() {
        #expect(pairs.vectorStore == StorageLedgerKitIDRename(from: "VectorKit", to: "SynapseKit"))
        #expect(pairs.representationClaims == StorageLedgerKitIDRename(from: "VectorKitClaims", to: "SynapseKitClaims"))
        // The ledger id a migrated estate carries is the id the store looks
        // its version up under. A later rename of the tier breaks this pin
        // on purpose: it needs its own capsule, not an edit to this one.
        #expect(VectorStore.schemaDeclaration.kitID == pairs.vectorStore.to)
        #expect(VectorRepresentationClaims.schemaDeclaration.kitID == pairs.representationClaims.to)
    }

    // MARK: §8 The renamed store opens the migrated estate without replaying

    /// The vector ladder is applied by `storage.migrate(to:
    /// VectorStore.schemaDeclaration)` at wire time. On a SQLite estate whose
    /// ledger still says `VectorKit`, that call finds no `SynapseKit` row and
    /// replays from version 0 against the v6 layout: the v5→v6 step rebuilds
    /// `vectors` through a copy table that resets every row's `generation`
    /// to 0 (a shadow-generation row is folded into the serving generation),
    /// and the ledger gains a duplicate row under the old id. After the
    /// capsule the row is found at v6 and nothing runs.
    @Test
    func renamedStoreOpensMigratedSQLiteEstateWithoutReplayingItsLadder() async throws {
        let migrated = try await sqliteVectorStateAfterWire(prepareFirst: true)
        #expect(migrated.rows == 1)
        #expect(migrated.generation == 3)
        #expect(migrated.newVersion == VectorStore.schemaDeclaration.version)
        #expect(migrated.oldVersion == 0)

        // Control: the same estate wired without the capsule replays. This
        // is the failure the capsule exists to prevent, observed.
        let replayed = try await sqliteVectorStateAfterWire(prepareFirst: false)
        #expect(replayed.rows == 1)
        #expect(replayed.generation == 0)
        #expect(replayed.newVersion == VectorStore.schemaDeclaration.version)
        #expect(replayed.oldVersion == VectorStore.schemaDeclaration.version)
    }

    /// Build a SQLite estate that a pre-rename runtime left behind: the
    /// vector tables at their current layout, one `vectors` row at
    /// generation 3, and the ledger row under the OLD id. Then (optionally)
    /// run the catalog, wire the renamed store's schema, and report the
    /// `vectors` row count, that row's generation, and the ledger versions
    /// under the NEW and the OLD id.
    private func sqliteVectorStateAfterWire(
        prepareFirst: Bool
    ) async throws -> (rows: Int, generation: Int64, newVersion: Int, oldVersion: Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-mig15-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite"), busyTimeout: 5.0)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)

        // The current vector layout, recorded under the pre-rename id.
        let current = VectorStore.schemaDeclaration
        let legacy = SchemaDeclaration(
            kitID: pairs.vectorStore.from,
            version: current.version,
            tables: current.tables,
            indices: current.indices,
            migrations: current.migrations)
        try await storage.migrate(to: legacy)
        _ = try await storage.rowStore.insert(table: "vectors", values: [
            "id": .uuid(UUID()),
            "item_id": .text("item-1"),
            "vector_index": .int(0),
            "model_id": .text("model-1"),
            "model_version": .text("1"),
            "kind": .int(0),
            "dim": .int(4),
            "payload": .blob(Data([0, 1, 2, 3])),
            "scale": .null,
            "filed_at": .timestamp(testNow),
            "ext": .null,
            "generation": .int(3),
        ])
        try await EstateFormatStore(storage: storage).stamp(.v1_4, now: testNow)

        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage, owner: testOwner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        if prepareFirst {
            _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        }
        // The renamed store's open: its ladder applied under the new id.
        try await storage.migrate(to: current)
        let vectors = try await storage.rowStore.query(table: "vectors")
        var generation: Int64 = -1
        if case let .int(value)? = vectors.first?["generation"] { generation = value }
        let newVersion = try await storage.currentSchemaVersion(for: pairs.vectorStore.to)
        let oldVersion = try await storage.currentSchemaVersion(for: pairs.vectorStore.from)
        try await kit.close(handle)
        await storage.close()
        return (vectors.count, generation, newVersion, oldVersion)
    }
}

#endif // GLK_MIGRATION_V1_4_TO_V1_5
