// SchemaLedgerPreparationTests.swift
//
// `VectorStore.prepareSchemaLedger(storage:)` and
// `VectorRepresentationClaims.prepareSchemaLedger(storage:)` move the
// vector tier's schema-version ledger rows from their former kit ids
// (VectorKit / VectorKitClaims) to the current ids before the ladder runs.
//
// Tests:
//   1. The constants: the current id is the declared kit id and the former
//      ids are the pinned rename pair (identical literal in the Rust twin).
//   2. Fresh storage: no row under either id, prepare is a no-op and creates
//      nothing.
//   3. Legacy row: a `VectorKit` v6 row moves to `SynapseKit` at v6 and the
//      old id has no row; the claims ledger does the same for v1.
//   4. Rows under both ids (the generation-3 SQLite fixture of §5 plus a
//      `SynapseKit` v6 row): prepare does not throw, both rows stay with their
//      versions, and prepare + migrate keeps the row at generation 3. The
//      claims ledger likewise passes with both its rows left in place.
//   5. SQLite estate a pre-rename runtime left behind (ledger row `VectorKit`
//      v6, one `vectors` row at generation 3): prepare + migrate keeps the
//      row at generation 3 and the ledger carries one row, under `SynapseKit`.
//      Control: migrate without prepare replays the ladder and folds the
//      generation to 0 (the failure the preparation exists to prevent).

import Foundation
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
@testable import SynapseKit

private let testNow = Date(timeIntervalSince1970: 1_756_000_000)

/// Record a schema-version ledger row for `kitID` at `version` without
/// declaring any table: the row a store leaves behind when it opens an estate.
private func seedLedger(_ storage: any Storage, kitID: String, version: Int) async throws {
    try await storage.migrate(to: SchemaDeclaration(kitID: kitID, version: version, tables: []))
}

private func version(_ storage: any Storage, _ kitID: String) async throws -> Int {
    try await storage.currentSchemaVersion(for: kitID)
}

private func inMemory() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
}

@Suite("SchemaLedgerPreparation")
struct SchemaLedgerPreparationTests {

    // MARK: §1 Constants

    @Test
    func constantsPinTheRenamePair() {
        #expect(VectorStore.kitID == "SynapseKit")
        #expect(VectorStore.schemaDeclaration.kitID == VectorStore.kitID)
        #expect(VectorStore.formerKitIDs == ["VectorKit"])
        #expect(VectorRepresentationClaims.kitID == "SynapseKitClaims")
        #expect(VectorRepresentationClaims.schemaDeclaration.kitID == VectorRepresentationClaims.kitID)
        #expect(VectorRepresentationClaims.formerKitIDs == ["VectorKitClaims"])
    }

    // MARK: §2 Fresh storage

    @Test
    func freshStorageIsANoOp() async throws {
        let storage = inMemory()
        try await VectorStore.prepareSchemaLedger(storage: storage)
        try await VectorRepresentationClaims.prepareSchemaLedger(storage: storage)
        #expect(try await version(storage, VectorStore.kitID) == 0)
        #expect(try await version(storage, "VectorKit") == 0)
        #expect(try await version(storage, VectorRepresentationClaims.kitID) == 0)
        #expect(try await version(storage, "VectorKitClaims") == 0)
    }

    // MARK: §3 Legacy rows move

    @Test
    func legacyRowsMoveToTheCurrentIds() async throws {
        let storage = inMemory()
        try await seedLedger(storage, kitID: "VectorKit", version: 6)
        try await seedLedger(storage, kitID: "VectorKitClaims", version: 1)

        try await VectorStore.prepareSchemaLedger(storage: storage)
        try await VectorRepresentationClaims.prepareSchemaLedger(storage: storage)

        #expect(try await version(storage, VectorStore.kitID) == 6)
        #expect(try await version(storage, "VectorKit") == 0)
        #expect(try await version(storage, VectorRepresentationClaims.kitID) == 1)
        #expect(try await version(storage, "VectorKitClaims") == 0)

        // A second call finds nothing to move and changes nothing.
        try await VectorStore.prepareSchemaLedger(storage: storage)
        #expect(try await version(storage, VectorStore.kitID) == 6)
    }

    // MARK: §4 Conflict warns and leaves both rows

    @Test
    func rowsUnderBothIdsWarnAndAreLeftInPlace() async throws {
        // Pinned fixture (identical in the Rust twin and the CorpusKit pair):
        // `VectorKit` v6 with one `vectors` row at generation 3, plus a
        // `SynapseKit` v6 ledger row. Prepare returns normally, both ledger
        // rows keep their versions, and migrate under the current id finds
        // its ladder position there — the row stays at generation 3.
        let conflicted = try await sqliteVectorStateAfterMigrate(
            prepareFirst: true, seedCurrentIDRow: true)
        #expect(conflicted.rows == 1)
        #expect(conflicted.generation == 3)
        #expect(conflicted.newVersion == VectorStore.schemaDeclaration.version)
        #expect(conflicted.oldVersion == VectorStore.schemaDeclaration.version)

        // The claims ledger applies the same policy.
        let storage = inMemory()
        try await seedLedger(storage, kitID: "VectorKitClaims", version: 1)
        try await seedLedger(storage, kitID: VectorRepresentationClaims.kitID, version: 1)
        try await VectorRepresentationClaims.prepareSchemaLedger(storage: storage)
        #expect(try await version(storage, "VectorKitClaims") == 1)
        #expect(try await version(storage, VectorRepresentationClaims.kitID) == 1)
    }

    // MARK: §5 SQLite: the ladder does not replay after preparation

    @Test
    func preparedSQLiteEstateKeepsItsGeneration() async throws {
        let prepared = try await sqliteVectorStateAfterMigrate(prepareFirst: true)
        #expect(prepared.rows == 1)
        #expect(prepared.generation == 3)
        #expect(prepared.newVersion == VectorStore.schemaDeclaration.version)
        #expect(prepared.oldVersion == 0)
    }

    @Test
    func unpreparedSQLiteEstateReplaysAndFoldsGenerationToZero() async throws {
        // Control: the failure the preparation exists to prevent, observed.
        let replayed = try await sqliteVectorStateAfterMigrate(prepareFirst: false)
        #expect(replayed.rows == 1)
        #expect(replayed.generation == 0)
        #expect(replayed.newVersion == VectorStore.schemaDeclaration.version)
        #expect(replayed.oldVersion == VectorStore.schemaDeclaration.version)
    }

    /// Build a SQLite estate a pre-rename runtime left behind: the vector
    /// tables at their current layout under the OLD ledger id, one `vectors`
    /// row at generation 3. With `seedCurrentIDRow` a ledger row under the
    /// NEW id at the current version is added as well (the conflicted
    /// ledger). Then (optionally) prepare the ledger, apply the current
    /// declaration, and report the row count, that row's generation, and the
    /// ledger versions under the NEW and the OLD id.
    private func sqliteVectorStateAfterMigrate(
        prepareFirst: Bool, seedCurrentIDRow: Bool = false
    ) async throws -> (rows: Int, generation: Int64, newVersion: Int, oldVersion: Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("synapsekit-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite"), busyTimeout: 5.0)))

        let current = VectorStore.schemaDeclaration
        let legacy = SchemaDeclaration(
            kitID: VectorStore.formerKitIDs[0],
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
            "dim": .int(256),
            "payload": .blob(Data(repeating: 0xA5, count: 32)),
            "scale": .null,
            "filed_at": .timestamp(testNow),
            "ext": .null,
            "generation": .int(3),
        ])

        if seedCurrentIDRow {
            try await seedLedger(storage, kitID: VectorStore.kitID, version: current.version)
        }
        if prepareFirst {
            try await VectorStore.prepareSchemaLedger(storage: storage)
        }
        try await storage.migrate(to: current)
        let vectors = try await storage.rowStore.query(table: "vectors")
        var generation: Int64 = -1
        if case let .int(value)? = vectors.first?["generation"] { generation = value }
        let newVersion = try await version(storage, VectorStore.kitID)
        let oldVersion = try await version(storage, VectorStore.formerKitIDs[0])
        await storage.close()
        return (vectors.count, generation, newVersion, oldVersion)
    }
}
