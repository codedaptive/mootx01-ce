// RowKeyDeterminismMoneyTests.swift
//
// Gap 5 fix verification — SQLiteBackend.extractRowKey.
//
// Swift twin of PersistenceKitInMemoryTests/RowKeyDeterminismMoneyTests.swift.
// See that file's header for the full gap-5 writeup. This file proves the
// SAME property on the PRODUCTION SQLite backend: two INDEPENDENT SQLite
// databases (two separate temp files — the direct model of two federation
// spokes, each with their own local .sqlite file) writing a row with the
// SAME single-column `.text` primary-key VALUE must resolve to the SAME
// internal `RowKey`.
//
// Before gap 5, `extractRowKey` (SQLiteStorage.swift:1009+) already parsed
// a UUID-SHAPED `.text` PK value deterministically (`UUID(uuidString:)`),
// so the UUID-shaped case here was already correct on SQLite — this test
// pins that it REMAINS correct. The genuinely non-UUID case, however, fell
// through to a random `UUID()` on SQLite too (no SHA-256 fallback existed)
// — THE MONEY TEST is that non-UUID case: it must now resolve identically
// across independent SQLite databases, closing the gap for LocusKit's
// documented, not-yet-exercised deterministic-id capability.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite

@Suite("Gap 5 money test — SQLiteStorage resolves the SAME RowKey across independent databases")
struct RowKeyDeterminismMoneyTests {

    func makeStorage() throws -> SQLiteStorage {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gap5-rowkey-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("test.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dbURL, busyTimeout: 5.0)
        ))
    }

    func openWidgetsSchema(_ storage: SQLiteStorage) async throws {
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "widgets",
                    columns: [.text("id"), .text("note")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
    }

    @Test("two independent SQLite databases resolve the SAME RowKey for the same UUID-shaped .text PK value")
    func sameUUIDShapedTextPKResolvesSameKeyAcrossDatabases() async throws {
        let storageA = try makeStorage()
        let storageB = try makeStorage()
        try await openWidgetsSchema(storageA)
        try await openWidgetsSchema(storageB)
        let idValue = UUID().uuidString

        let handleA = try await storageA.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("from A")],
            conflictColumns: ["id"]
        )
        let handleB = try await storageB.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("from B")],
            conflictColumns: ["id"]
        )

        #expect(handleA.key == handleB.key,
                "two independent SQLite databases must resolve the SAME RowKey for the same UUID-shaped .text PK value")
    }

    /// THE MONEY TEST: genuinely non-UUID id — before gap 5, `extractRowKey`
    /// had a `UUID(uuidString:)` fallback but NO SHA-256 derivation, so this
    /// exact case still fell through to a random `UUID()` even on SQLite.
    @Test("two independent SQLite databases resolve the SAME RowKey for the same non-UUID .text PK value")
    func sameNonUUIDTextPKResolvesSameKeyAcrossDatabases() async throws {
        let storageA = try makeStorage()
        let storageB = try makeStorage()
        try await openWidgetsSchema(storageA)
        try await openWidgetsSchema(storageB)
        let idValue = "widget-alpha"

        let handleA = try await storageA.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("from A")],
            conflictColumns: ["id"]
        )
        let handleB = try await storageB.rowStore.upsert(
            table: "widgets", values: ["id": .text(idValue), "note": .text("from B")],
            conflictColumns: ["id"]
        )

        #expect(handleA.key == handleB.key,
                "gap 5 money test: two independent SQLite databases must resolve the SAME RowKey for the same non-UUID .text PK value")
        // Cross-check against the shared vector (RowKeyDerivationConformanceTests.swift,
        // row_key_derivation.rs, MerkleRollupTests.swift's gap-5 cross-check).
        #expect(handleA.key.uuidString == "5653F1D5-D5DE-5B4F-A820-E6BA150A14E2")
    }

    @Test("a .uuid-typed PK is unaffected — the fast path is unchanged")
    func uuidTypedPKUnaffected() async throws {
        let storage = try makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit", version: 1,
            tables: [TableDeclaration(name: "items", columns: [.uuid("id"), .text("note")], primaryKey: ["id"])],
            indices: [], migrations: []
        ))
        let id = UUID()
        let handle = try await storage.rowStore.upsert(
            table: "items", values: ["id": .uuid(id), "note": .text("x")], conflictColumns: ["id"]
        )
        #expect(handle.key == id, "a .uuid PK's value IS the RowKey — unchanged by gap 5")
    }
}
