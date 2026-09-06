#if GLK_MIGRATION_V1_5_TO_V1_6

// IndexCompositionColumnDropMigrationTests.swift
//
// Verifies that GLKMigrationCatalog.prepare runs the 1.5→1.6 capsule, which
// drops the retired `corpus_index_state.composition_policy` column from a
// populated estate by replaying CorpusKit's checkpoint ladder (v4), keeps
// every checkpoint row, and stamps the estate format v1_6.
//
// Tests:
//   1. v1_5-stamped estate whose ledger records CorpusKitIndexState at v3 and
//      whose checkpoint row carries the column: after prepare the column is
//      gone, the row's other fields are intact, the ledger reads v4 and the
//      estate is stamped v1_6.
//   2. The same on an estate with NO CorpusKitIndexState ledger row (the
//      composite-declaration shape every provisioned estate has): the ladder
//      replays from version 0 and still drops the column.
//   3. Idempotence: a second prepare is a no-op; running the capsule directly
//      again leaves the ledger at v4 and the stamp at v1_6.
//   4. Fresh estate (nil stamp): prepare stamps v1_6 without running the
//      capsule and without recording a CorpusKitIndexState row.
//   5. On a SQLite estate the column is physically gone (a row read returns
//      no such key) and the row survives.
//   6. v1_4-stamped estate: the chain runs the 1.4→1.5 capsule and then this
//      one, ending at v1_6 (gated on the 1.4→1.5 capsule being compiled).

import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_5ToV1_6

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig16")
private let testNow = Date(timeIntervalSince1970: 1_756_000_000)
private let checkpointKitID = CorpusIndexStateStore.schemaDeclaration.kitID

/// The v3 checkpoint layout: the current declaration's tables plus the
/// retired column, recorded under `kitID` at version 3 with no migrations,
/// exactly what a populated estate carries before the capsule runs.
private func legacyCheckpointDeclaration(kitID: String) -> SchemaDeclaration {
    let current = CorpusIndexStateStore.schemaDeclaration
    let tables = current.tables.map { table -> TableDeclaration in
        guard table.name == "corpus_index_state" else { return table }
        return TableDeclaration(
            name: table.name,
            columns: table.columns + [
                ColumnDeclaration(
                    name: "composition_policy", type: .text, nullable: false,
                    defaultValue: .text(""))
            ],
            primaryKey: table.primaryKey)
    }
    return SchemaDeclaration(kitID: kitID, version: 3, tables: tables, indices: current.indices)
}

/// One checkpoint row carrying a policy id in the retired column.
private func insertLegacyCheckpoint(_ storage: any Storage) async throws {
    _ = try await storage.rowStore.insert(table: "corpus_index_state", values: [
        "content_id": .text("content-1"),
        "revision": .int(2),
        "digest": .text("digest-1"),
        "index_version": .int(7),
        "applied_cursor": .null,
        "updated_at": .timestamp(testNow),
        "operational_bitmap": .bitmap(3),
        "composition_policy": .text("lex=original;dense=original"),
    ])
}

/// An estate on `storage` stamped at `stamp` (or unstamped when nil), whose
/// corpus_index_state table carries the retired column and one row. The
/// checkpoint ledger is recorded under CorpusKitIndexState at v3 when
/// `withLedgerRow`, or under a composite-style id otherwise (no
/// CorpusKitIndexState row, the shape a provisioned estate has).
private func makeEstate(
    storage: any Storage,
    stampedAt stamp: EstateFormatVersion?,
    withLedgerRow: Bool = true
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
    let legacy = legacyCheckpointDeclaration(
        kitID: withLedgerRow ? checkpointKitID : "CompositeFixture")
    try await storage.migrate(to: legacy)
    try await insertLegacyCheckpoint(storage)
    if let stamp {
        try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)
    }
    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage,
        owner: testOwner,
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    return (kit, handle)
}

private func inMemory() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
}

/// The one checkpoint row, as the row store reads it back.
private func checkpointRow(_ storage: any Storage) async throws -> StorageRow {
    let rows = try await storage.rowStore.query(table: "corpus_index_state")
    #expect(rows.count == 1)
    return rows.first ?? StorageRow(values: [:])
}

@Suite("IndexCompositionColumnDropMigration", .serialized)
struct IndexCompositionColumnDropMigrationTests {

    // MARK: §1 Ledger at v3: the column goes, the row stays, v1_6 stamped

    @Test
    func v1_5EstateWithLedgerRowDropsTheColumn() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_5)
        #expect(try await storage.currentSchemaVersion(for: checkpointKitID) == 3)
        #expect(try await checkpointRow(storage)["composition_policy"] == .text("lex=original;dense=original"))

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_6)
        #expect(prep.format == .current)
        #expect(prep.migrated == false)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_6)
        #expect(try await storage.currentSchemaVersion(for: checkpointKitID)
            == CorpusIndexStateStore.schemaDeclaration.version)

        let row = try await checkpointRow(storage)
        #expect(row["composition_policy"] == nil)
        #expect(row["content_id"] == .text("content-1"))
        #expect(row["revision"] == .int(2))
        #expect(row["digest"] == .text("digest-1"))
        #expect(row["index_version"] == .int(7))
        #expect(row["operational_bitmap"] == .bitmap(3))
    }

    // MARK: §2 No ledger row (composite shape): the ladder replays from 0

    @Test
    func v1_5EstateWithoutLedgerRowDropsTheColumn() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_5, withLedgerRow: false)
        #expect(try await storage.currentSchemaVersion(for: checkpointKitID) == 0)

        let report = try await kit.runIndexCompositionColumnDropMigration(handle: handle, now: testNow)
        #expect(report == IndexCompositionColumnDropMigrationReport(
            checkpointSchemaVersion: CorpusIndexStateStore.schemaDeclaration.version, format: .v1_6))
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_6)
        let row = try await checkpointRow(storage)
        #expect(row["composition_policy"] == nil)
        #expect(row["content_id"] == .text("content-1"))
        #expect(row["operational_bitmap"] == .bitmap(3))
    }

    // MARK: §3 Idempotence

    @Test
    func prepareTwiceIsNoOpAndDirectRerunLeavesTheLadderAlone() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_5)
        let first = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(first.format == .v1_6)
        let second = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(second.format == .v1_6)
        #expect(second.migrated == false)

        let report = try await kit.runIndexCompositionColumnDropMigration(handle: handle, now: testNow)
        #expect(report.checkpointSchemaVersion == CorpusIndexStateStore.schemaDeclaration.version)
        #expect(report.format == .v1_6)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_6)
        let row = try await checkpointRow(storage)
        #expect(row["composition_policy"] == nil)
        #expect(row["content_id"] == .text("content-1"))
    }

    // MARK: §4 Fresh estate (nil stamp)

    @Test
    func freshEstateStampsCurrentWithoutRunningTheCapsule() async throws {
        let storage = inMemory()
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage, owner: testOwner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .current)
        #expect(prep.migrated == false)
        #expect(prep.migrationState == nil)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_6)
        #expect(try await storage.currentSchemaVersion(for: checkpointKitID) == 0)
    }

    // MARK: §5 SQLite: the column is physically gone and the row survives

    @Test
    func sqliteEstateLosesTheColumnAndKeepsTheRow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-mig16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("estate.sqlite")
        let estateID = UUID()
        // The estate a previous runtime left behind: written through one
        // storage instance that is then closed, so the new runtime below
        // registers no declaration carrying the column (SQLite refuses two
        // kits declaring one table with different layouts in one process;
        // a restarted daemon never sees the old layout's declaration).
        do {
            let writer = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: estateID, backend: .sqlite(url: url, busyTimeout: 5.0)))
            _ = try await LocusKit.Estate.create(storage: writer, owner: testOwner)
            try await writer.migrate(to: legacyCheckpointDeclaration(kitID: "CompositeFixture"))
            try await insertLegacyCheckpoint(writer)
            try await EstateFormatStore(storage: writer).stamp(.v1_5, now: testNow)
            #expect(try await checkpointRow(writer)["composition_policy"] == .text("lex=original;dense=original"))
            await writer.close()
        }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: estateID, backend: .sqlite(url: url, busyTimeout: 5.0)))
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage, owner: testOwner, identityKeyStore: InMemoryEstateIdentityKeyStore())

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_6)
        let row = try await checkpointRow(storage)
        #expect(row["composition_policy"] == nil)
        #expect(row["content_id"] == .text("content-1"))
        #expect(row["digest"] == .text("digest-1"))
        #expect(try await storage.currentSchemaVersion(for: checkpointKitID)
            == CorpusIndexStateStore.schemaDeclaration.version)

        // A second replay of the ladder is a no-op: dropColumn on an absent
        // column does not error (the addColumn rule in reverse).
        try await storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)
        _ = try await kit.runIndexCompositionColumnDropMigration(handle: handle, now: testNow)
        #expect(try await checkpointRow(storage)["composition_policy"] == nil)
        try await kit.close(handle)
        await storage.close()
    }

    // MARK: §6 Chain from v1_4 ends at v1_6

    #if GLK_MIGRATION_V1_4_TO_V1_5
    @Test
    func v1_4EstateRunsBothCapsulesToCurrent() async throws {
        let storage = inMemory()
        let (kit, handle) = try await makeEstate(storage: storage, stampedAt: .v1_4)
        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_6)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_6)
        #expect(try await checkpointRow(storage)["composition_policy"] == nil)
    }
    #endif
}

#endif // GLK_MIGRATION_V1_5_TO_V1_6
