// InMemoryObserverTests.swift

import Testing
import Foundation
import SubstrateTypes
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

struct InMemoryObserverTests {

    func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    /// Await the first change on `stream`, returning nil if none arrives
    /// within `duration`. The timeout converts a dropped change into a test
    /// failure rather than letting the suite hang on a never-delivered stream.
    private func firstChange(
        from stream: AsyncStream<TableChange>,
        within duration: Duration
    ) async -> TableChange? {
        await withTaskGroup(of: TableChange?.self) { group in
            group.addTask {
                for await change in stream { return change }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func insertNotification() async throws {
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
        #expect(changes.count == 2, "two inserts should produce two notifications")
        #expect(changes[0].event == .insert)
        #expect(changes[0].table == "items")
        #expect(changes[0].rowKey == id1)
    }

    @Test func deleteNotification() async throws {
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
        #expect(deleted == 1)

        let change = await collected.value
        #expect(change != nil)
        #expect(change?.event == .delete)
        #expect(change?.rowKey == id)
    }

    @Test func eventFilterRespected() async throws {
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
        #expect(count == 1, "only insert observed; delete filtered out")
    }

    /// Ordering guarantee: a change from an insert issued immediately after
    /// `observe()` — with no settling sleep — is delivered, because
    /// `observe()` records the subscription synchronously before it returns,
    /// so the subscription is live before the insert can fire. This case
    /// deliberately omits the settling delay the other cases use, so it
    /// regresses if registration ever becomes asynchronous again.
    @Test func observeThenImmediateInsertDelivers() async throws {
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

        // No `Task.sleep` here — the absence of a settling delay is the
        // point of this test.
        let stream = storage.observer.observe(table: "items", events: [.insert])

        let id = UUID()
        _ = try await storage.rowStore.insert(
            table: "items",
            values: ["id": .uuid(id), "name": .text("first")]
        )

        let received = await firstChange(from: stream, within: .seconds(2))
        #expect(received != nil, "change from an insert immediately after observe() must be delivered")
        #expect(received?.event == .insert)
        #expect(received?.rowKey == id)
    }
}
