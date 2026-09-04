// SchemaKitRenameTests.swift
//
// `Storage.renameSchemaKit(from:to:)` on the in-memory backend (SPEC I-7a):
// the per-kit version entry moves, a second call is a no-op, both ids
// present is a reported conflict, and bystander kits are untouched.

import Foundation
import PersistenceKit
import PersistenceKitInMemory
import Testing

struct SchemaKitRenameTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    @Test func entryMovesWithItsVersionAndSecondCallIsNoOp() async throws {
        let storage = makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "OldKit", version: 3, tables: []))

        let first = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(first == .renamed(version: 3))
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 3)
        #expect(try await storage.currentSchemaVersion(for: "OldKit") == 0)

        let second = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(second == .noRow)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 3)
    }

    @Test func bothIdsPresentIsAConflictThatChangesNothing() async throws {
        let storage = makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "OldKit", version: 1, tables: []))
        try await storage.open(schema: SchemaDeclaration(kitID: "NewKit", version: 2, tables: []))

        let outcome = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(outcome == .conflict(oldVersion: 1, newVersion: 2))
        #expect(try await storage.currentSchemaVersion(for: "OldKit") == 1)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 2)
    }

    @Test func otherEntriesAndTheGlobalMaximumAreUntouched() async throws {
        let storage = makeStorage()
        try await storage.open(schema: SchemaDeclaration(kitID: "OldKit", version: 4, tables: []))
        try await storage.open(schema: SchemaDeclaration(kitID: "Bystander", version: 7, tables: []))
        _ = try await storage.renameSchemaKit(from: "OldKit", to: "NewKit")
        #expect(try await storage.currentSchemaVersion(for: "Bystander") == 7)
        #expect(try await storage.currentSchemaVersion(for: "NewKit") == 4)
        #expect(try await storage.currentSchemaVersion() == 7)
    }
}
