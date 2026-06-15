// PostgreSQLBasicTests.swift
//
// Gated on POSTGRES_TEST_URL env var. When absent, tests return early
// (still pass) so CI without postgres remains green — the swift-testing
// analogue of the prior XCTSkip.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitPostgreSQL
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

struct PostgreSQLBasicTests {

    func connectionString() -> String? {
        ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"]
    }

    func makeStorage(_ cs: String) -> PostgreSQLStorage {
        PostgreSQLStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .postgresql(connectionString: cs, poolSize: 2)
        ))
    }

    func makeSchema(suffix: String = "test") -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "TestKit_\(suffix)",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "drawers_\(suffix)",
                    columns: [
                        .uuid("row_id"),
                        .bitmap("adjective"),
                        .bitmap("operational"),
                        .bitmap("provenance"),
                        .text("verbatim"),
                        .timestamp("captured_at")
                    ],
                    primaryKey: ["row_id"]
                )
            ]
        )
    }

    @Test func openAndSchemaVersion() async throws {
        guard let cs = connectionString() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        let schema = makeSchema(suffix: "open_\(UUID().uuidString.prefix(8))")
        try await storage.open(schema: schema)
        let v = try await storage.currentSchemaVersion()
        #expect(v == 1)
        await storage.close()
    }

    @Test func insertAndQuery() async throws {
        guard let cs = connectionString() else { return }  // POSTGRES_TEST_URL not set
        let storage = makeStorage(cs)
        let suffix = "iq_\(UUID().uuidString.prefix(8))"
        let schema = makeSchema(suffix: suffix)
        try await storage.open(schema: schema)
        defer { Task { await storage.close() } }

        let rowID = UUID()
        let table = "drawers_\(suffix)"
        _ = try await storage.rowStore.insert(
            table: table,
            values: [
                "row_id": .uuid(rowID),
                "adjective": .bitmap(0x01),
                "operational": .bitmap(0x02),
                "provenance": .bitmap(0x04),
                "verbatim": .text("hello pg"),
                "captured_at": .timestamp(Date(timeIntervalSince1970: 1000))
            ]
        )
        let rows = try await storage.rowStore.query(
            table: table,
            where: .eq(Column(table: table, name: "row_id"), .uuid(rowID))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["verbatim"] == .text("hello pg"))
    }
}
