// MemoryClustersSchemaTests.swift
//
// Tests for the memory_clusters schema addition (DG1).
//
// Verifies three contracts:
//   T1  `estateSchemaDeclaration` contains the memory_clusters table with
//       the correct column names declared in the spec (DISTILLATION_DESIGN.md §3).
//   T2  Both required indices (status, factoid) are present in the
//       schema declaration.
//   T3  A fresh in-memory estate accepts an insert and retrieves the row
//       by status — confirms the table is operational, not just declared.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - T1 + T2: Schema declaration correctness

@Suite("memory_clusters schema declaration (DG1)")
struct MemoryClustersSchemaDeclarationTests {

    /// The estate schema declaration contains exactly one memory_clusters
    /// table with the nine columns specified in DISTILLATION_DESIGN.md §3.
    @Test("memory_clusters table present with correct columns")
    func memoryClustersTableColumns() throws {
        let decl = GeniusLocusKitSchema.estateSchemaDeclaration
        let table = try #require(decl.tables.first(where: { $0.name == "memory_clusters" }))
        let names = table.columns.map(\.name)
        #expect(names == [
            "id",
            "status",
            "snr",
            "member_ids",
            "member_count",
            "factoid_id",
            "held_reason",
            "filed_at",
            "updated_at",
        ])
        // Primary key is the cluster UUID.
        #expect(table.primaryKey == ["id"])
        // No generated columns — a flat staging table, no bitmap extracts.
        #expect(table.generatedColumns.isEmpty)
    }

    /// The estate schema declaration contains both memory_clusters indices.
    @Test("memory_clusters indices present in schema declaration")
    func memoryClustersIndices() {
        let decl = GeniusLocusKitSchema.estateSchemaDeclaration
        let indexNames = decl.indices.map(\.name)
        #expect(indexNames.contains("idx_memory_clusters_status"))
        #expect(indexNames.contains("idx_memory_clusters_factoid"))

        // Verify index metadata matches the spec.
        let statusIdx = decl.indices.first(where: { $0.name == "idx_memory_clusters_status" })
        #expect(statusIdx?.table == "memory_clusters")
        #expect(statusIdx?.columns == ["status"])
        #expect(statusIdx?.unique == false)

        let factoidIdx = decl.indices.first(where: { $0.name == "idx_memory_clusters_factoid" })
        #expect(factoidIdx?.table == "memory_clusters")
        #expect(factoidIdx?.columns == ["factoid_id"])
        #expect(factoidIdx?.unique == false)
    }
}

// MARK: - T3: Live estate insert + query

@Suite("memory_clusters live estate (DG1)")
struct MemoryClustersLiveEstateTests {

    /// Open a fresh in-memory estate and insert a minimal row
    /// (status='open', member_ids='[]', member_count=0).
    /// Query back by status and confirm the row is returned.
    @Test("insert and query memory_clusters row by status")
    func insertAndQueryByStatus() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)

        let clusterID = UUID()
        // Fixed timestamp — no Date() calls inside test logic per the fleet rule.
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let values: [String: TypedValue] = [
            "id": .uuid(clusterID),
            "status": .text("open"),
            "member_ids": .json(Data("[]".utf8)),
            "member_count": .int(0),
            "filed_at": .timestamp(now),
            "updated_at": .timestamp(now),
        ]
        _ = try await storage.rowStore.insert(table: "memory_clusters", values: values)

        let rows = try await storage.rowStore.query(
            table: "memory_clusters",
            where: .eq(Column(table: "memory_clusters", name: "status"), .text("open"))
        )
        #expect(rows.count == 1)
    }
}
