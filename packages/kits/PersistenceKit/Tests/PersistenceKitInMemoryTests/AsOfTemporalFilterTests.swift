// AsOfTemporalFilterTests.swift
//
// Part 2 conformance: verifies ColumnRole metadata and temporal
// filter logic. The as-of gate remains ON in production; these
// tests exercise the filter directly on query results to prove
// the schema metadata and filter function are correct.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

struct AsOfTemporalFilterTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func makeTemporalSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "TemporalTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "nodes",
                    columns: [
                        .uuid("node_id"),
                        .text("payload"),
                        .createdHlc("created_hlc"),
                        .tombstonedHlc("tombstoned_hlc")
                    ],
                    primaryKey: ["node_id"]
                )
            ]
        )
    }

    // MARK: - Schema metadata tests

    @Test func columnRoleCreatedHlcIsSet() {
        let schema = makeTemporalSchema()
        let table = schema.tables[0]
        #expect(table.createdHlcColumn == "created_hlc")
    }

    @Test func columnRoleTombstonedHlcIsSet() {
        let schema = makeTemporalSchema()
        let table = schema.tables[0]
        #expect(table.tombstonedHlcColumn == "tombstoned_hlc")
    }

    @Test func supportsAsOfFilterIsTrue() {
        let schema = makeTemporalSchema()
        #expect(schema.tables[0].supportsAsOfFilter)
    }

    @Test func tableWithoutRolesDoesNotSupportAsOf() {
        let schema = SchemaDeclaration(
            kitID: "PlainKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "plain",
                    columns: [
                        .uuid("id"),
                        .hlc("some_hlc")
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
        #expect(!schema.tables[0].supportsAsOfFilter)
        #expect(schema.tables[0].createdHlcColumn == nil)
    }

    @Test func createdHlcConvenienceIsNotNullable() {
        let col = ColumnDeclaration.createdHlc("c")
        #expect(col.role == .createdHlc)
        #expect(!col.nullable)
        #expect(col.type == .hlc)
    }

    @Test func tombstonedHlcConvenienceIsNullable() {
        let col = ColumnDeclaration.tombstonedHlc("t")
        #expect(col.role == .tombstonedHlc)
        #expect(col.nullable)
        #expect(col.type == .hlc)
    }

    // MARK: - Temporal filter conformance

    /// Applies the as-of temporal filter to query results using
    /// ColumnRole metadata. This is the filter logic that will be
    /// used when the gate is lifted (NT-L4 + NT-P3).
    private func filterAsOf(
        rows: [StorageRow],
        at hlc: HLC,
        table: TableDeclaration
    ) -> [StorageRow] {
        guard let createdCol = table.createdHlcColumn else { return rows }
        let tombCol = table.tombstonedHlcColumn

        return rows.filter { row in
            guard let createdVal = row[createdCol],
                  case .hlc(let created) = createdVal else {
                return false
            }
            guard created <= hlc else { return false }

            if let tombCol, let tombVal = row[tombCol] {
                if case .hlc(let tombstoned) = tombVal {
                    return tombstoned > hlc
                }
            }
            // No tombstone or null tombstone → still live
            return true
        }
    }

    @Test func temporalFilterIncludesRowCreatedBeforeT() async throws {
        let storage = makeStorage()
        let schema = makeTemporalSchema()
        try await storage.open(schema: schema)

        let id = UUID()
        let created = HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(id),
                "payload": .text("visible"),
                "created_hlc": .hlc(created),
            ]
        )

        let allRows = try await storage.rowStore.query(table: "nodes", where: nil)
        let queryTime = HLC(physicalTime: 200, logicalCount: 0, nodeID: 1)
        let filtered = filterAsOf(rows: allRows, at: queryTime, table: schema.tables[0])
        #expect(filtered.count == 1)
        #expect(filtered[0]["payload"] == .text("visible"))
    }

    @Test func temporalFilterExcludesRowCreatedAfterT() async throws {
        let storage = makeStorage()
        let schema = makeTemporalSchema()
        try await storage.open(schema: schema)

        let id = UUID()
        let created = HLC(physicalTime: 300, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(id),
                "payload": .text("future"),
                "created_hlc": .hlc(created),
            ]
        )

        let allRows = try await storage.rowStore.query(table: "nodes", where: nil)
        let queryTime = HLC(physicalTime: 200, logicalCount: 0, nodeID: 1)
        let filtered = filterAsOf(rows: allRows, at: queryTime, table: schema.tables[0])
        #expect(filtered.isEmpty)
    }

    @Test func temporalFilterExcludesTombstonedRowBeforeT() async throws {
        let storage = makeStorage()
        let schema = makeTemporalSchema()
        try await storage.open(schema: schema)

        let id = UUID()
        let created = HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)
        let tombstoned = HLC(physicalTime: 150, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(id),
                "payload": .text("deleted"),
                "created_hlc": .hlc(created),
                "tombstoned_hlc": .hlc(tombstoned),
            ]
        )

        let allRows = try await storage.rowStore.query(table: "nodes", where: nil)
        let queryTime = HLC(physicalTime: 200, logicalCount: 0, nodeID: 1)
        let filtered = filterAsOf(rows: allRows, at: queryTime, table: schema.tables[0])
        #expect(filtered.isEmpty)
    }

    @Test func temporalFilterIncludesRowNotYetTombstonedAtT() async throws {
        let storage = makeStorage()
        let schema = makeTemporalSchema()
        try await storage.open(schema: schema)

        let id = UUID()
        let created = HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)
        let tombstoned = HLC(physicalTime: 300, logicalCount: 0, nodeID: 1)
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(id),
                "payload": .text("alive-at-200"),
                "created_hlc": .hlc(created),
                "tombstoned_hlc": .hlc(tombstoned),
            ]
        )

        let allRows = try await storage.rowStore.query(table: "nodes", where: nil)
        let queryTime = HLC(physicalTime: 200, logicalCount: 0, nodeID: 1)
        let filtered = filterAsOf(rows: allRows, at: queryTime, table: schema.tables[0])
        #expect(filtered.count == 1)
        #expect(filtered[0]["payload"] == .text("alive-at-200"))
    }

    @Test func temporalFilterMultipleRowsCorrectSlice() async throws {
        let storage = makeStorage()
        let schema = makeTemporalSchema()
        try await storage.open(schema: schema)

        // Row A: created=100, no tombstone → visible at T=250
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(UUID()),
                "payload": .text("A-live"),
                "created_hlc": .hlc(HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)),
            ]
        )
        // Row B: created=100, tombstoned=200 → NOT visible at T=250
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(UUID()),
                "payload": .text("B-dead"),
                "created_hlc": .hlc(HLC(physicalTime: 100, logicalCount: 0, nodeID: 1)),
                "tombstoned_hlc": .hlc(HLC(physicalTime: 200, logicalCount: 0, nodeID: 1)),
            ]
        )
        // Row C: created=300, no tombstone → NOT visible at T=250
        _ = try await storage.rowStore.insert(
            table: "nodes",
            values: [
                "node_id": .uuid(UUID()),
                "payload": .text("C-future"),
                "created_hlc": .hlc(HLC(physicalTime: 300, logicalCount: 0, nodeID: 1)),
            ]
        )

        let allRows = try await storage.rowStore.query(table: "nodes", where: nil)
        #expect(allRows.count == 3)

        let queryTime = HLC(physicalTime: 250, logicalCount: 0, nodeID: 1)
        let filtered = filterAsOf(rows: allRows, at: queryTime, table: schema.tables[0])
        #expect(filtered.count == 1)
        #expect(filtered[0]["payload"] == .text("A-live"))
    }
}
