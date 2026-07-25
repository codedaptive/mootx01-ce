// DatabaseInventoryTests.swift
//
// Deterministic table-inventory coverage (GLK shared-content 1.1, P0).
//
// The inventory fold is the protected-state baseline the shared-content
// migration compares before and after destructive steps: it must be
// deterministic across captures, order-independent across row insertion
// order, sensitive to any row mutation, and able to exclude
// nondeterministic audit-stamp columns.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory

struct DatabaseInventoryTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
    }

    private var schema: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "InventoryKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "widgets",
                    columns: [.uuid("id"), .text("name"), .int("rank"),
                              .timestamp("created_at", nullable: true)],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    private func insertWidget(
        _ storage: InMemoryStorage, id: UUID, name: String, rank: Int64,
        createdAt: Date? = nil
    ) async throws {
        _ = try await storage.rowStore.insert(table: "widgets", values: [
            "id": .uuid(id),
            "name": .text(name),
            "rank": .int(rank),
            "created_at": createdAt.map { TypedValue.timestamp($0) } ?? .null
        ])
    }

    @Test func captureIsDeterministicAndOrderIndependent() async throws {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!

        let forward = makeStorage()
        try await forward.open(schema: schema)
        try await insertWidget(forward, id: idA, name: "a", rank: 1)
        try await insertWidget(forward, id: idB, name: "b", rank: 2)

        let reversed = makeStorage()
        try await reversed.open(schema: schema)
        try await insertWidget(reversed, id: idB, name: "b", rank: 2)
        try await insertWidget(reversed, id: idA, name: "a", rank: 1)

        let invForward = try await DatabaseInventory.capture(
            storage: forward, tables: ["widgets"])
        let invReversed = try await DatabaseInventory.capture(
            storage: reversed, tables: ["widgets"])
        #expect(invForward == invReversed)
        #expect(invForward[0].rowCount == 2)
    }

    @Test func foldDetectsRowMutation() async throws {
        let storage = makeStorage()
        try await storage.open(schema: schema)
        let id = UUID()
        try await insertWidget(storage, id: id, name: "a", rank: 1)
        let baseline = try await DatabaseInventory.capture(
            storage: storage, tables: ["widgets"])

        _ = try await storage.rowStore.update(
            table: "widgets",
            values: ["rank": .int(2)],
            where: .eq(Column(table: "widgets", name: "id"), .uuid(id)))
        let mutated = try await DatabaseInventory.capture(
            storage: storage, tables: ["widgets"])
        #expect(baseline[0].contentFold != mutated[0].contentFold)
        #expect(baseline[0].rowCount == mutated[0].rowCount)
    }

    @Test func excludedColumnsDoNotAffectFold() async throws {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!

        let early = makeStorage()
        try await early.open(schema: schema)
        try await insertWidget(early, id: idA, name: "a", rank: 1,
                               createdAt: Date(timeIntervalSince1970: 100))

        let late = makeStorage()
        try await late.open(schema: schema)
        try await insertWidget(late, id: idA, name: "a", rank: 1,
                               createdAt: Date(timeIntervalSince1970: 999))

        let exclusions = ["widgets": Set(["created_at"])]
        let invEarly = try await DatabaseInventory.capture(
            storage: early, tables: ["widgets"], excludingColumns: exclusions)
        let invLate = try await DatabaseInventory.capture(
            storage: late, tables: ["widgets"], excludingColumns: exclusions)
        #expect(invEarly == invLate)

        // Without the exclusion the differing stamp must change the fold.
        let strictEarly = try await DatabaseInventory.capture(
            storage: early, tables: ["widgets"])
        let strictLate = try await DatabaseInventory.capture(
            storage: late, tables: ["widgets"])
        #expect(strictEarly[0].contentFold != strictLate[0].contentFold)
    }

    @Test func canonicalValueEncodingMatchesCrossPortFixture() {
        // Frozen encodings — the Rust twin asserts the same strings
        // (database_inventory.rs::tests).
        #expect(DatabaseInventory.canonicalValueEncoding(.float(1.5)) == "f:3ff8000000000000")
        #expect(DatabaseInventory.canonicalValueEncoding(.null) == "n")
        #expect(DatabaseInventory.canonicalValueEncoding(.bool(true)) == "b:1")
        #expect(DatabaseInventory.canonicalValueEncoding(.int(-7)) == "i:-7")
        #expect(DatabaseInventory.canonicalValueEncoding(.text("hé")) == "t:3:hé")
        #expect(DatabaseInventory.canonicalValueEncoding(
            .uuid(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!))
            == "u:00000000-0000-0000-0000-00000000000a")
        #expect(DatabaseInventory.canonicalValueEncoding(
            .timestamp(Date(timeIntervalSince1970: 1.5))) == "s:1500")
        #expect(DatabaseInventory.canonicalValueEncoding(
            .blob(Data([0xDE, 0xAD]))) == "x:2:dead")
    }
}
