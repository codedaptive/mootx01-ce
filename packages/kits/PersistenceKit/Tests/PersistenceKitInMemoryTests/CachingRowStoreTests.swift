// CachingRowStoreTests.swift
//
// Tests for CachingRowStore and CacheInvalidator.
// Verifies: cache hit/miss, sensitivity gate, write-through invalidation,
// observer-driven invalidation, and LRU eviction.
//
// Each test works by populating the cache via a query, then deleting the
// row from the backing store directly (without going through CachingRowStore).
// A subsequent query either returns from cache (hit) or falls through to
// the now-empty backing store (miss/invalidated).

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
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

@Suite("CachingRowStoreTests")
struct CachingRowStoreTests {

    // MARK: — Fixtures

    static let schema = SchemaDeclaration(
        kitID: "CacheTest",
        version: 1,
        tables: [
            TableDeclaration(
                name: "things",
                columns: [
                    .uuid("id"),
                    .text("name", nullable: true),
                    .int("provenance", nullable: true),
                ],
                primaryKey: ["id"]
            )
        ]
    )

    func makeStorage() async throws -> InMemoryStorage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: Self.schema)
        return storage
    }

    func makeCaching(
        backing: any RowStore,
        ceilingBytes: Int = 10_000_000,
        threshold: Int = 2
    ) -> CachingRowStore {
        CachingRowStore(
            backing: backing,
            config: EstateCacheConfig(
                enabled: true,
                ceilingBytes: ceilingBytes,
                sensitivityThreshold: threshold
            )
        )
    }

    /// Encode a sensitivity level into the `provenance` column value.
    /// level = (raw >> 4) & 0x7  →  raw = level << 4
    func provenance(level: Int) -> TypedValue { .int(Int64(level) << 4) }

    func idPredicate(table: String = "things", _ id: UUID) -> StoragePredicate {
        .eq(Column(table: table, name: "id"), .uuid(id))
    }

    // MARK: — Cache miss / hit

    @Test("Cache miss falls through to backing store")
    func cacheMissFallsThroughToBacking() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("alice")]
        )

        let rows = try await caching.query(
            table: "things", where: idPredicate(id)
        )
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("alice"))
    }

    @Test("Cache miss populates the hot tier for subsequent hits")
    func cacheMissPopulatesHotTier() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("bob")]
        )
        let p = idPredicate(id)

        // First query: miss → populates
        _ = try await caching.query(table: "things", where: p)

        // Delete from backing store directly (bypasses CachingRowStore, no
        // automatic invalidation) — if the cache is populated, the next query
        // returns the pre-delete snapshot from cache.
        _ = try await storage.rowStore.delete(table: "things", where: p)

        // Second query: cache hit → returns the cached row
        let hit = try await caching.query(table: "things", where: p)
        #expect(hit.count == 1, "second query should hit the cache")
        #expect(hit[0]["name"] == .text("bob"))
    }

    @Test("Cache hit returns same result as backing store")
    func cacheHitMatchesBackingResult() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("charlie")]
        )
        let p = idPredicate(id)

        // Miss: populate from backing
        let fromBacking = try await caching.query(table: "things", where: p)
        // Hit: return from cache
        let fromCache = try await caching.query(table: "things", where: p)

        #expect(fromBacking.count == fromCache.count)
        #expect(fromBacking[0]["name"] == fromCache[0]["name"])
    }

    // MARK: — Sensitivity gate

    @Test("Row without provenance column caches normally")
    func noProvenanceColumnAdmitted() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore, threshold: 0)
        let id = UUID()

        // No provenance key in values → absent → admitted
        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("x")]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)
        _ = try await storage.rowStore.delete(table: "things", where: p)
        let hit = try await caching.query(table: "things", where: p)
        #expect(hit.count == 1, "absent provenance → row is cached")
    }

    @Test("Row with provenance at threshold level is admitted (boundary)")
    func provenanceAtThresholdAdmitted() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore, threshold: 1)
        let id = UUID()

        // Level 1 (Elevated) with threshold=1 → admitted (level ≤ threshold)
        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["id": .uuid(id), "name": .text("y"), "provenance": provenance(level: 1)]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)
        _ = try await storage.rowStore.delete(table: "things", where: p)
        let hit = try await caching.query(table: "things", where: p)
        #expect(hit.count == 1, "level == threshold → admitted to cache")
    }

    @Test("Row with provenance sensitivity above threshold is not cached")
    func provenanceAboveThresholdRejected() async throws {
        let storage = try await makeStorage()
        // threshold=0 → only Normal (level 0) admitted; Elevated (level 1) rejected
        let caching = makeCaching(backing: storage.rowStore, threshold: 0)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["id": .uuid(id), "name": .text("elevated"), "provenance": provenance(level: 1)]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)
        _ = try await storage.rowStore.delete(table: "things", where: p)

        // If it was not cached, backing has nothing → returns empty
        let miss = try await caching.query(table: "things", where: p)
        #expect(miss.count == 0, "level > threshold → not cached; backing returns nothing after delete")
    }

    @Test("Row with provenance Secret (level 3) never cached regardless of threshold")
    func provenanceSecretAlwaysRejected() async throws {
        let storage = try await makeStorage()
        // Even at the maximum threshold=2, Secret (level 3) is excluded
        let caching = makeCaching(backing: storage.rowStore, threshold: 2)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["id": .uuid(id), "name": .text("secret"), "provenance": provenance(level: 3)]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)
        _ = try await storage.rowStore.delete(table: "things", where: p)

        let miss = try await caching.query(table: "things", where: p)
        #expect(miss.count == 0, "Secret always excluded from cache")
    }

    @Test("Unparseable provenance fails closed — row not cached")
    func unparseableProvenanceFailsClosed() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore, threshold: 2)
        let id = UUID()

        // .text value for provenance is unparseable as Int64 → fail closed
        _ = try await storage.rowStore.insert(
            table: "things",
            values: ["id": .uuid(id), "name": .text("bad"), "provenance": .text("not-an-int")]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)
        _ = try await storage.rowStore.delete(table: "things", where: p)

        let miss = try await caching.query(table: "things", where: p)
        #expect(miss.count == 0, "unparseable provenance → fail closed; row not cached")
    }

    // MARK: — Write-through invalidation

    @Test("update via CachingRowStore invalidates the cached entry")
    func updateInvalidatesCache() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("before")]
        )
        let p = idPredicate(id)

        // Populate cache
        _ = try await caching.query(table: "things", where: p)

        // Update through CachingRowStore → invalidates cache
        _ = try await caching.update(
            table: "things",
            values: ["name": .text("after")],
            where: p
        )

        // Next query falls through to backing (cache is clear) → gets updated row
        let updated = try await caching.query(table: "things", where: p)
        #expect(updated.count == 1)
        #expect(updated[0]["name"] == .text("after"))
    }

    @Test("delete via CachingRowStore invalidates the cached entry")
    func deleteInvalidatesCache() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("exists")]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)
        _ = try await caching.delete(table: "things", where: p)

        let after = try await caching.query(table: "things", where: p)
        #expect(after.count == 0, "deleted row must not be returned from cache")
    }

    @Test("upsert via CachingRowStore invalidates the cached entry")
    func upsertInvalidatesCache() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("initial")]
        )
        let p = idPredicate(id)

        _ = try await caching.query(table: "things", where: p)

        // Upsert updates the existing row through CachingRowStore
        _ = try await caching.upsert(
            table: "things",
            values: ["id": .uuid(id), "name": .text("updated")],
            conflictColumns: ["id"]
        )

        let after = try await caching.query(table: "things", where: p)
        #expect(after.count == 1)
        #expect(after[0]["name"] == .text("updated"))
    }

    // MARK: — StorageObserver-driven invalidation

    @Test("StorageObserver event from external write invalidates cached entry")
    func observerEventInvalidatesCache() async throws {
        let storage = try await makeStorage()
        let caching = makeCaching(backing: storage.rowStore)
        let id = UUID()

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(id), "name": .text("cached")]
        )
        let p = idPredicate(id)

        // Populate cache
        _ = try await caching.query(table: "things", where: p)

        let invalidator = CacheInvalidator(
            cache: caching,
            observer: storage.observer,
            tables: ["things"]
        )
        defer { invalidator.cancel() }

        // Allow the subscription to register before the write fires.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Delete directly through the backing store (bypasses CachingRowStore).
        // The backing observer fires, CacheInvalidator receives the event.
        _ = try await storage.rowStore.delete(table: "things", where: p)

        // Allow the CacheInvalidator task to process the observer event.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Cache should be invalidated; backing has no row → returns empty
        let after = try await caching.query(table: "things", where: p)
        #expect(after.count == 0, "observer-driven invalidation cleared the cache entry")
    }

    // MARK: — LRU eviction

    @Test("LRU eviction fires when byte ceiling is exceeded")
    func lruEvictionFiresOnCeilingExceeded() async throws {
        let storage = try await makeStorage()

        // Row bytes estimate: 64 (overhead) + "id"(2)+8 + UUID(24) + "name"(4)+8 + "alice"(5)+16 = 131
        // Ceiling = 200 → first row admitted, second triggers eviction of first.
        let caching = CachingRowStore(
            backing: storage.rowStore,
            config: EstateCacheConfig(enabled: true, ceilingBytes: 200, sensitivityThreshold: 2)
        )

        let idA = UUID(), idB = UUID()
        let pA = idPredicate(idA), pB = idPredicate(idB)

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(idA), "name": .text("alice")]
        )
        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(idB), "name": .text("bob")]
        )

        // Populate A (LRU = A)
        _ = try await caching.query(table: "things", where: pA)
        // Populate B → ceiling exceeded → A evicted, B cached
        _ = try await caching.query(table: "things", where: pB)

        // Delete both from backing to expose cache hits vs misses
        _ = try await storage.rowStore.delete(table: "things", where: pA)
        _ = try await storage.rowStore.delete(table: "things", where: pB)

        // B: still in cache → hit
        let resultB = try await caching.query(table: "things", where: pB)
        #expect(resultB.count == 1, "B was admitted last and should still be in cache")

        // A: evicted → miss → backing has nothing (deleted) → empty
        let resultA = try await caching.query(table: "things", where: pA)
        #expect(resultA.count == 0, "A was evicted by LRU; backing returns nothing after delete")
    }

    @Test("Evicted row falls through to backing store on next read")
    func evictedRowFallsThroughToBacking() async throws {
        let storage = try await makeStorage()
        let caching = CachingRowStore(
            backing: storage.rowStore,
            config: EstateCacheConfig(enabled: true, ceilingBytes: 200, sensitivityThreshold: 2)
        )

        let idA = UUID(), idB = UUID()
        let pA = idPredicate(idA), pB = idPredicate(idB)

        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(idA), "name": .text("first")]
        )
        _ = try await storage.rowStore.insert(
            table: "things", values: ["id": .uuid(idB), "name": .text("second")]
        )

        // Populate A, then B (A gets evicted). Backing still has both rows.
        _ = try await caching.query(table: "things", where: pA)
        _ = try await caching.query(table: "things", where: pB)

        // A was evicted but the backing store still has it → fall through returns it
        let resultA = try await caching.query(table: "things", where: pA)
        #expect(resultA.count == 1, "evicted row still readable via backing store")
        #expect(resultA[0]["name"] == .text("first"))
    }
}
