// RowKeyDerivationAgreementTests.swift
//
// Gate: public RowKeyDerivation.deterministicRowKey returns THE SAME value
// the SQLite backend assigns as the RowKey of a single-column TEXT-PK row.
//
// This is the cross-seam conformance gate introduced when RowKeyDerivation
// was widened to public API in KGFACT_AUDIT Unit 1. The prior comment block
// in RowKeyDerivation.swift named RowKeyDerivationCrossCheckTests.swift as
// the gate; that file never existed. This file is the gate.
//
// What it proves: the public contract point 1 — "the returned value IS the
// RowKey the storage layer assigns to a single-column TEXT-primary-key row
// carrying that id, in every backend." Exercised here against the SQLite
// backend because that is the production path for kg_facts rows.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite

@Suite("RowKeyDerivation public contract — SQLite backend agreement (KGFACT_AUDIT U1)")
struct RowKeyDerivationAgreementTests {

    // MARK: - Helpers

    /// Fresh SQLite storage with a minimal kg_facts-shaped table (TEXT primary
    /// key named "id"). Each test gets its own temporary database file, so the
    /// two cases cannot see each other's rows.
    private func makeStorageAsync() async throws -> SQLiteStorage {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pk-rowkey-agreement-\(UUID().uuidString).sqlite")
        let storage = try TestStorage.sqliteThrowing(url)
        let schema = SchemaDeclaration(
            kitID: "test-rowkey-agreement",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "kg_facts",
                    columns: [
                        ColumnDeclaration.text("id"),
                        ColumnDeclaration.text("note"),
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
        try await storage.open(schema: schema)
        return storage
    }

    // MARK: - Gate tests

    /// Contract point 1 + 3: a non-UUID kg_facts id — the RowKey the SQLite
    /// backend assigns equals deterministicRowKey(from:) of the same id.
    @Test("non-UUID kg_facts id: insert RowKey equals deterministicRowKey(from:)")
    func nonUUIDIdAgreement() async throws {
        let storage = try await makeStorageAsync()
        let id = "fact-not-a-uuid-1"
        let handle = try await storage.rowStore.insert(
            table: "kg_facts",
            values: ["id": .text(id), "note": .text("gate")]
        )
        let derived = RowKeyDerivation.deterministicRowKey(from: id)
        #expect(
            handle.key == derived,
            "kg_facts RowKey for non-UUID id must equal deterministicRowKey(from:)"
        )
    }

    /// Contract point 1 + 2: a UUID-shaped kg_facts id — the RowKey the SQLite
    /// backend assigns equals that UUID (deterministicRowKey passes it through).
    @Test("UUID-shaped kg_facts id: insert RowKey is that UUID unchanged")
    func uuidIdAgreement() async throws {
        let storage = try await makeStorageAsync()
        let id = UUID()
        let handle = try await storage.rowStore.insert(
            table: "kg_facts",
            values: ["id": .text(id.uuidString), "note": .text("gate")]
        )
        let derived = RowKeyDerivation.deterministicRowKey(from: id.uuidString)
        #expect(
            handle.key == derived,
            "kg_facts RowKey for UUID-shaped id must equal deterministicRowKey(from:)"
        )
        #expect(
            handle.key == id,
            "deterministicRowKey passes a UUID-shaped string through unchanged"
        )
    }
}
