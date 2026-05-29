// InMemoryObserverTests.swift

import XCTest
import SubstrateTypes
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

final class InMemoryObserverTests: XCTestCase {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func testInsertNotification() async throws {
        let storage = makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ObserverTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name")],
                    primaryKey: ["id"]
                )
            ]
        ))

        let stream = storage.observer.observe(table: "items", events: [.insert])
        let collected = Task<[TableChange], Never> {
            var out: [TableChange] = []
            for await change in stream {
                out.append(change)
                if out.count >= 2 { break }
            }
            return out
        }

        // Give the subscription a moment to register.
        try await Task.sleep(nanoseconds: 50_000_000)

        let id1 = UUID(), id2 = UUID()
        _ = try await storage.rowStore.insert(table: "items", values: ["id": .uuid(id1), "name": .text("first")])
        _ = try await storage.rowStore.insert(table: "items", values: ["id": .uuid(id2), "name": .text("second")])

        let changes = await collected.value
        XCTAssertEqual(changes.count, 2, "two inserts should produce two notifications")
        XCTAssertEqual(changes[0].event, .insert)
        XCTAssertEqual(changes[0].table, "items")
        XCTAssertEqual(changes[0].rowKey, id1)
    }

    func testDeleteNotification() async throws {
        let storage = makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ObserverTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name")],
                    primaryKey: ["id"]
                )
            ]
        ))

        let id = UUID()
        _ = try await storage.rowStore.insert(table: "items", values: ["id": .uuid(id), "name": .text("x")])

        let stream = storage.observer.observe(table: "items", events: [.delete])
        let collected = Task<TableChange?, Never> {
            for await change in stream { return change }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let deleted = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(id))
        )
        XCTAssertEqual(deleted, 1)

        let change = await collected.value
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.event, .delete)
        XCTAssertEqual(change?.rowKey, id)
    }

    func testEventFilterRespected() async throws {
        let storage = makeStorage()
        try await storage.open(schema: SchemaDeclaration(
            kitID: "ObserverTest",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("name")],
                    primaryKey: ["id"]
                )
            ]
        ))

        // Only observe inserts; delete should not fire.
        let stream = storage.observer.observe(table: "items", events: [.insert])
        let collected = Task<Int, Never> {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 1 { break }
            }
            return count
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let id = UUID()
        _ = try await storage.rowStore.insert(table: "items", values: ["id": .uuid(id), "name": .text("x")])
        _ = try await storage.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(id))
        )

        let count = await collected.value
        XCTAssertEqual(count, 1, "only insert observed; delete filtered out")
    }
}
