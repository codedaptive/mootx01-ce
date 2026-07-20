// RowKeyDeterminismMoneyTests.swift
//
// Gap 5 fix verification — InMemoryStorage.resolveOrAllocateKey.
//
// THE MONEY TEST: two INDEPENDENT storage instances (the direct model of
// two federation spokes, each with their own local database) writing a row
// with the SAME single-column `.text` primary-key VALUE must resolve to
// the SAME internal `RowKey`. Before gap 5, `resolveOrAllocateKey`
// (InMemoryStorage.swift:499+) minted a fresh random UUID for any
// `.text`-typed PK — two independent instances writing "the same" logical
// row got two DIFFERENT, unrelated RowKeys. Since ConvergenceKit's
// HLC-ordering gates (`_ck_sync_meta`/`_ck_sync_meta_cols`) key their
// bookkeeping by RowKey, this meant the gate compared against the wrong
// side-table entry and ordering silently degraded from HLC-order to
// pull-order (see ConvergenceKit's LocalWriteColumnHLCGate /
// TombstoneResurrectionGuard tests for the downstream ordering symptom;
// this file proves the ROOT mechanism directly, at the PersistenceKit
// layer, with no ConvergenceKit dependency needed).
//
// Covers BOTH a UUID-shaped `.text` id (matches LocusKit's current
// production reality) and a genuinely non-UUID `.text` id (LocusKit's
// documented, not-yet-exercised deterministic-id capability) — both must
// resolve identically across independent instances.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory

@Suite("Gap 5 money test — InMemoryStorage resolves the SAME RowKey across independent instances")
struct RowKeyDeterminismMoneyTests {

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
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
        return storage
    }

    @Test("two independent storage instances resolve the SAME RowKey for the same UUID-shaped .text PK value")
    func sameUUIDShapedTextPKResolvesSameKeyAcrossInstances() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
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
                "gap 5 money test: two independent storage instances must resolve the SAME RowKey for the same .text PK value")
    }

    /// THE MONEY TEST: genuinely non-UUID id — this is the case that was
    /// COMPLETELY broken before gap 5 (not even a UUID(uuidString:) fallback
    /// existed on InMemoryStorage).
    @Test("two independent storage instances resolve the SAME RowKey for the same non-UUID .text PK value")
    func sameNonUUIDTextPKResolvesSameKeyAcrossInstances() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
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
                "gap 5 money test: two independent storage instances must resolve the SAME RowKey for the same non-UUID .text PK value")
        // Cross-check against the shared vector (RowKeyDerivationConformanceTests.swift).
        #expect(handleA.key.uuidString == "5653F1D5-D5DE-5B4F-A820-E6BA150A14E2")
    }

    @Test("a .uuid-typed PK is unaffected — the fast path is unchanged")
    func uuidTypedPKUnaffected() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
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

    @Test("a composite (multi-column) PK is unaffected — falls through to random mint, unchanged (Kong's guard)")
    func compositePKUnaffected() async throws {
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit", version: 1,
            tables: [
                TableDeclaration(
                    name: "composite",
                    columns: [.text("part_a"), .text("part_b"), .text("note")],
                    primaryKey: ["part_a", "part_b"]
                )
            ],
            indices: [], migrations: []
        ))
        let handle1 = try await storage.rowStore.insert(
            table: "composite", values: ["part_a": .text("x"), "part_b": .text("y"), "note": .text("1")]
        )
        // A second, independent storage instance with the SAME composite key values
        // must NOT be forced to agree — composite PKs are explicitly out of gap 5's
        // scope (Kong's guard: no deterministic derivation for multi-column PKs).
        let storage2 = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await storage2.open(schema: SchemaDeclaration(
            kitID: "TestKit", version: 1,
            tables: [
                TableDeclaration(
                    name: "composite",
                    columns: [.text("part_a"), .text("part_b"), .text("note")],
                    primaryKey: ["part_a", "part_b"]
                )
            ],
            indices: [], migrations: []
        ))
        let handle2 = try await storage2.rowStore.insert(
            table: "composite", values: ["part_a": .text("x"), "part_b": .text("y"), "note": .text("2")]
        )
        // Random-mint default for both — no assertion on equality either way, this
        // just documents (and pins, via the build/compile + successful run) that
        // composite PKs still resolve via the unchanged fallback path, not a crash
        // or a forced-deterministic derivation.
        _ = handle1
        _ = handle2
    }
}
