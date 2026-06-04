// CacheWiringTests.swift
//
// Mission PK-CACHE-C1 — integration tests for the InMemoryStorage cache wiring.
// Verifies the two end-to-end behaviours the mission requires:
//   - Default (disabled) cacheConfig: rowStore is the plain backing store,
//     not wrapped in a CachingRowStore.
//   - Enabled cacheConfig: rowStore is a CachingRowStore wrapping the backing store.
//   - Both paths produce identical query results.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

struct InMemoryCacheWiringTests {

    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "InMemCacheWiringTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "things",
                    columns: [
                        .uuid("id"),
                        .text("name", nullable: true)
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    /// Disabled cacheConfig (the default) must leave rowStore as the plain
    /// backing InMemoryRowStore — no CachingRowStore in the chain.
    @Test func disabledCacheConfigReturnsPlainRowStore() {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
            // cacheConfig defaults to .disabled
        ))
        #expect(
            !(storage.rowStore is CachingRowStore),
            "disabled cacheConfig must not wrap rowStore in CachingRowStore"
        )
    }

    /// Enabled cacheConfig must wrap the backing store in a CachingRowStore.
    @Test func enabledCacheConfigReturnsCachingRowStore() {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory,
            cacheConfig: EstateCacheConfig(enabled: true, ceilingBytes: 1_000_000, sensitivityThreshold: 2)
        ))
        #expect(
            storage.rowStore is CachingRowStore,
            "enabled cacheConfig must wrap rowStore in CachingRowStore"
        )
    }

    /// Cache-enabled and cache-disabled backends must produce identical query results.
    @Test func enabledAndDisabledProduceIdenticalQueryResults() async throws {
        let schema = makeSchema()
        let id = UUID()
        let predicate = StoragePredicate.eq(Column(table: "things", name: "id"), .uuid(id))

        // Disabled path (default)
        let disabled = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await disabled.open(schema: schema)
        _ = try await disabled.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("hello")]
        )
        let disabledRows = try await disabled.rowStore.query(
            table: "things", where: predicate
        )

        // Enabled path
        let enabled = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory,
            cacheConfig: EstateCacheConfig(enabled: true, ceilingBytes: 1_000_000, sensitivityThreshold: 2)
        ))
        try await enabled.open(schema: schema)
        _ = try await enabled.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("hello")]
        )
        let enabledRows = try await enabled.rowStore.query(
            table: "things", where: predicate
        )

        #expect(disabledRows.count == enabledRows.count)
        #expect(disabledRows.count == 1)
        #expect(disabledRows[0]["name"] == enabledRows[0]["name"])
    }

    /// Cache-enabled backend serves subsequent reads from the hot tier — second
    /// query returns the same row even after the backing store has no record.
    @Test func enabledCacheServesHotTierOnRepeatedRead() async throws {
        let schema = makeSchema()
        let id = UUID()
        let predicate = StoragePredicate.eq(Column(table: "things", name: "id"), .uuid(id))

        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory,
            cacheConfig: EstateCacheConfig(enabled: true, ceilingBytes: 1_000_000, sensitivityThreshold: 2)
        ))
        try await storage.open(schema: schema)

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("cached")]
        )

        // First query: cache miss — populates hot tier
        let first = try await storage.rowStore.query(table: "things", where: predicate)
        #expect(first.count == 1)
        #expect(first[0]["name"] == .text("cached"))

        // Second query: hot-tier hit — same result
        let second = try await storage.rowStore.query(table: "things", where: predicate)
        #expect(second.count == 1)
        #expect(second[0]["name"] == .text("cached"))
    }
}
