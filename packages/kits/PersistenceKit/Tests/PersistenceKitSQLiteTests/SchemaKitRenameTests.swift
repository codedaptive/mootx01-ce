// SchemaKitRenameTests.swift
//
// `Storage.renameSchemaKit(from:to:)` on the SQLite backend (SPEC I-7a):
// the ledger row moves with its version, a second call is a no-op, both
// ids present is a reported conflict, and a store opened under the new id
// does NOT replay its ladder. The replay probe is a migration step that
// inserts one row into a probe table: one row means the ladder ran once,
// at the original open; a second row means it replayed.

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import Testing

struct SchemaKitRenameTests {

    private func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("storagekit-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: tmpDir.appendingPathComponent("test.sqlite"), busyTimeout: 5.0)
        ))
    }

    /// A three-version ladder under `kitID`. The 2 → 3 step inserts one
    /// probe row, so the probe table's row count is the number of times the
    /// ladder has run on this file.
    private func ladder(kitID: String) -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: kitID,
            version: 3,
            tables: [
                TableDeclaration(
                    name: "rename_probe",
                    columns: [.uuid("id"), .text("note")],
                    primaryKey: ["id"]
                )
            ],
            migrations: [
                Migration(fromVersion: 0, toVersion: 1, operations: []),
                Migration(fromVersion: 1, toVersion: 2, operations: []),
                Migration(fromVersion: 2, toVersion: 3, operations: [
                    .custom(
                        sqlite: "INSERT INTO \"rename_probe\" (\"id\", \"note\") VALUES ('\(UUID().uuidString)', 'ladder ran')",
                        postgresql: nil),
                ]),
            ]
        )
    }

    private func probeRows(_ storage: SQLiteStorage) async throws -> Int {
        try await storage.rowStore.query(table: "rename_probe").count
    }

    @Test func rowMovesWithItsVersionAndSecondCallIsNoOp() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: ladder(kitID: "OldKit"))
        #expect(try await storage.currentSchemaVersion(for: "OldKit") == 3)
        #expect(try await probeRows(storage) == 1)

        let first = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(first == .renamed(version: 3))
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 3)
        #expect(try await storage.currentSchemaVersion(for: "OldKit") == 0)

        let second = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(second == .noRow)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 3)
        await storage.close()
    }

    @Test func storeOpenedUnderTheNewIdDoesNotReplayItsLadder() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: ladder(kitID: "OldKit"))
        #expect(try await probeRows(storage) == 1)
        _ = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")

        // The renamed store finds its row and runs nothing.
        try await storage.open(schema: ladder(kitID: "NewKit"))
        #expect(try await probeRows(storage) == 1)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 3)

        // Control: an id with no row replays from version 0. This is the
        // failure the rename exists to prevent.
        try await storage.open(schema: ladder(kitID: "UnrenamedKit"))
        #expect(try await probeRows(storage) == 2)
        await storage.close()
    }

    @Test func bothIdsPresentIsAConflictThatChangesNothing() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "OldKit", version: 1, tables: []))
        try await storage.open(schema: SchemaDeclaration(kitID: "NewKit", version: 2, tables: []))

        let outcome = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(outcome == .conflict(oldVersion: 1, newVersion: 2))
        #expect(try await storage.currentSchemaVersion(for: "OldKit") == 1)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 2)
        await storage.close()
    }

    @Test func otherRowsAreUntouched() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "OldKit", version: 4, tables: []))
        try await storage.open(schema: SchemaDeclaration(kitID: "Bystander", version: 7, tables: []))
        _ = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(try await storage.currentSchemaVersion(for: "Bystander") == 7)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 4)
        await storage.close()
    }
}
