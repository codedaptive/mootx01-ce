// AsOfQueryTests.swift
//
// Verifies the as-of temporal query surface on the InMemory backend.
// Part 1: the gate is ON — .asOf returns featureGated; .present and
// nil behave identically to the standard query.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct AsOfQueryTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "AsOfTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("row_id"),
                        .text("content"),
                        .hlc("created_hlc"),
                        .hlc("tombstoned_hlc", nullable: true)
                    ],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    // MARK: - Gate tests

    @Test func asOfQueryReturnsFeatureGated() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        let asOf = AsOfCoordinate.asOf(hlc)

        await #expect(throws: StorageError.self) {
            _ = try await storage.rowStore.query(
                table: "items",
                where: nil,
                orderBy: [],
                limit: nil,
                offset: nil,
                asOf: asOf
            )
        }
    }

    @Test func asOfQueryErrorIsFeatureGatedWithCorrectName() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        do {
            _ = try await storage.rowStore.query(
                table: "items",
                where: nil,
                orderBy: [],
                limit: nil,
                offset: nil,
                asOf: .asOf(hlc)
            )
            Issue.record("Expected featureGated error")
        } catch let error as StorageError {
            #expect(error == .featureGated(feature: "asOfQuery"))
        }
    }

    @Test func asOfProjectedQueryReturnsFeatureGated() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        await #expect(throws: StorageError.self) {
            _ = try await storage.rowStore.query(
                table: "items",
                where: nil,
                orderBy: [],
                limit: nil,
                offset: nil,
                columns: ["row_id", "content"],
                asOf: .asOf(hlc)
            )
        }
    }

    @Test func asOfSkipCorruptQueryReturnsFeatureGated() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        await #expect(throws: StorageError.self) {
            _ = try await storage.rowStore.querySkipCorrupt(
                table: "items",
                where: nil,
                orderBy: [],
                limit: nil,
                offset: nil,
                columns: nil,
                asOf: .asOf(hlc)
            )
        }
    }

    // MARK: - Present / nil passthrough tests

    @Test func presentQueryBehavesLikeStandardQuery() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let id = UUID()
        let hlc = HLC(physicalTime: 500, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "items",
            values: [
                "row_id": .uuid(id),
                "content": .text("hello"),
                "created_hlc": .hlc(hlc),
            ]
        )

        // Query with .present
        let presentRows = try await storage.rowStore.query(
            table: "items",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil,
            asOf: .present
        )
        #expect(presentRows.count == 1)
        #expect(presentRows[0]["content"] == .text("hello"))
    }

    @Test func nilAsOfQueryBehavesLikeStandardQuery() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let id = UUID()
        let hlc = HLC(physicalTime: 500, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "items",
            values: [
                "row_id": .uuid(id),
                "content": .text("world"),
                "created_hlc": .hlc(hlc),
            ]
        )

        // Query with nil asOf
        let nilRows = try await storage.rowStore.query(
            table: "items",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil,
            asOf: nil
        )
        #expect(nilRows.count == 1)
        #expect(nilRows[0]["content"] == .text("world"))

        // Compare with standard query (no asOf parameter)
        let standardRows = try await storage.rowStore.query(
            table: "items",
            where: nil
        )
        #expect(standardRows.count == nilRows.count)
    }

    @Test func presentProjectedQueryPassesThrough() async throws {
        let storage = makeStorage()
        try await storage.open(schema: makeSchema())

        let id = UUID()
        let hlc = HLC(physicalTime: 500, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "items",
            values: [
                "row_id": .uuid(id),
                "content": .text("projected"),
                "created_hlc": .hlc(hlc),
            ]
        )

        let rows = try await storage.rowStore.query(
            table: "items",
            where: nil,
            orderBy: [],
            limit: nil,
            offset: nil,
            columns: ["row_id"],
            asOf: .present
        )
        #expect(rows.count == 1)
    }
}
