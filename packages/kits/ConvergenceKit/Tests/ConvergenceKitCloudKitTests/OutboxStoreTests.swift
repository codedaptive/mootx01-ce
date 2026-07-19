// OutboxStoreTests.swift
//
// Durable outbox tests: durability, coalescing, confirmation, drain-on-enable,
// and push-failure-keeps-outbox.
//
// Tests operate on InMemoryStorage with the ConvergenceKit side schema applied
// so they exercise OutboxStore behaviour without CloudKit or SQLite.
//
// Push-failure-keeps-outbox is tested at the OutboxStore level (not at the
// CKDatabase transport level). A full transport-fault injection test lands
// with P1-M6 / P4-M1 when per-record push results are wired to the real
// CloudKit seam. The OutboxStore-level test is sufficient to verify the
// read-without-consume contract today.

import Testing
import Foundation
@testable import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

// MARK: - Helpers

private func makeStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
    // Open with a minimal application schema (the side tables are added by
    // CKSideSchema.ensure below, not by the application schema).
    try await storage.open(schema: SchemaDeclaration(
        kitID: "TestApp",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("name")],
                primaryKey: ["id"]
            )
        ]
    ))
    // Ensure the ConvergenceKit side tables (_ck_sync_meta, _ck_outbox).
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

private func makeEntry(
    tableName: String = "items",
    rowKey: String = UUID().uuidString,
    event: SyncEventKind = .insert,
    valuesData: Data? = nil,
    packedHLC: Int64 = 1_000
) -> OutboxEntry {
    // Gap 6: `packedHLC` is a plain logical ordinal (test convenience, param
    // name kept so every call site below is unchanged) — wrapped into a
    // full-width HLC.wireBytes. `ordinal(of:)` below inverts this for
    // assertions that used to read `entry.packedHLC` directly.
    let hlc = HLC(physicalTime: packedHLC, logicalCount: 0, nodeID: 1)
    return OutboxEntry(
        id: UUID(),
        tableName: tableName,
        rowKey: rowKey,
        event: event,
        valuesData: valuesData,
        hlcWireBytes: Data(hlc.wireBytes),
        enqueuedAt: ISO8601DateFormatter().string(from: Date())
    )
}

/// Inverse of `makeEntry`'s `packedHLC` convenience — decode an entry's
/// wire-format HLC back to the physicalTime ordinal used to construct it,
/// for assertions that used to read `entry.packedHLC` directly (gap 6).
private func ordinal(of entry: OutboxEntry) -> Int64 {
    (try? HLC(wireBytes: [UInt8](entry.hlcWireBytes)))?.physicalTime ?? -1
}

// MARK: - Suite

@Suite("OutboxStore — durable outbound queue")
struct OutboxStoreTests {

    // MARK: - Durability across store instance reopen

    @Test("entries survive OutboxStore reopen (stateless store, shared storage)")
    func durabilityAcrossReopen() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString
        let entry = makeEntry(rowKey: rowKey, packedHLC: 500)

        try await OutboxStore.append(entry: entry, to: storage)

        // Simulate "reopen": OutboxStore is stateless; reading from the same
        // storage instance in a fresh call must return the appended entry.
        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        #expect(batch.first?.id == entry.id)
        #expect(batch.first?.rowKey == rowKey)
        #expect(batch.first?.tableName == "items")
    }

    // MARK: - Coalescing: newest-wins by HLC

    @Test("coalescing: newer entry replaces older entry for same (table, rowKey)")
    func coalescingNewerWins() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        let older = makeEntry(rowKey: rowKey, event: .insert, packedHLC: 100)
        let newer = makeEntry(rowKey: rowKey, event: .update, packedHLC: 200)

        try await OutboxStore.append(entry: older, to: storage)
        try await OutboxStore.append(entry: newer, to: storage)

        // Only one entry should survive; it should be the newer one.
        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        #expect(batch.first?.id == newer.id)
        #expect(batch.first?.event == .update)
        #expect(ordinal(of: batch.first!) == 200)
    }

    @Test("coalescing: older entry does NOT replace newer entry (stale write rejected)")
    func coalescingStaleWriteRejected() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        let newer = makeEntry(rowKey: rowKey, event: .update, packedHLC: 300)
        let stale = makeEntry(rowKey: rowKey, event: .insert, packedHLC: 100)

        try await OutboxStore.append(entry: newer, to: storage)
        try await OutboxStore.append(entry: stale, to: storage)   // older HLC — should be ignored

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        #expect(batch.first?.id == newer.id)
        #expect(batch.first?.event == .update)
        #expect(ordinal(of: batch.first!) == 300)
    }

    @Test("coalescing: entries for different rowKeys coexist")
    func coalescingDistinctRowKeys() async throws {
        let storage = try await makeStorage()
        let keyA = UUID().uuidString
        let keyB = UUID().uuidString

        try await OutboxStore.append(entry: makeEntry(rowKey: keyA, packedHLC: 10), to: storage)
        try await OutboxStore.append(entry: makeEntry(rowKey: keyB, packedHLC: 20), to: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 2)
        let keys = Set(batch.map { $0.rowKey })
        #expect(keys == Set([keyA, keyB]))
    }

    @Test("coalescing: delete supersedes earlier insert for same rowKey")
    func coalescingDeleteSupersedesInsert() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID().uuidString

        let insert = makeEntry(rowKey: rowKey, event: .insert, packedHLC: 50)
        let delete = makeEntry(rowKey: rowKey, event: .delete, valuesData: nil, packedHLC: 75)

        try await OutboxStore.append(entry: insert, to: storage)
        try await OutboxStore.append(entry: delete, to: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
        #expect(batch.first?.event == .delete)
    }

    // MARK: - Confirm removes only confirmed entries

    @Test("confirm removes only confirmed IDs, leaving others intact")
    func confirmRemovesOnlyConfirmed() async throws {
        let storage = try await makeStorage()
        let entryA = makeEntry(rowKey: UUID().uuidString, packedHLC: 1)
        let entryB = makeEntry(rowKey: UUID().uuidString, packedHLC: 2)
        let entryC = makeEntry(rowKey: UUID().uuidString, packedHLC: 3)

        try await OutboxStore.append(entry: entryA, to: storage)
        try await OutboxStore.append(entry: entryB, to: storage)
        try await OutboxStore.append(entry: entryC, to: storage)

        // Confirm only A and C.
        try await OutboxStore.confirm(ids: [entryA.id, entryC.id], from: storage)

        let remaining = try await OutboxStore.readBatch(from: storage)
        #expect(remaining.count == 1)
        #expect(remaining.first?.id == entryB.id)
    }

    @Test("confirm with empty list is a no-op")
    func confirmEmptyListIsNoOp() async throws {
        let storage = try await makeStorage()
        let entry = makeEntry()
        try await OutboxStore.append(entry: entry, to: storage)

        try await OutboxStore.confirm(ids: [], from: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.count == 1)
    }

    // MARK: - Drain on enable

    @Test("drainLeftovers returns all pending entries")
    func drainLeftoversReturnsAllEntries() async throws {
        let storage = try await makeStorage()

        for _ in 0..<5 {
            try await OutboxStore.append(entry: makeEntry(rowKey: UUID().uuidString, packedHLC: Int64.random(in: 1...10000)), to: storage)
        }

        let leftovers = try await OutboxStore.drainLeftovers(from: storage)
        #expect(leftovers.count == 5)
    }

    @Test("drainLeftovers returns empty when outbox is empty")
    func drainLeftoversEmptyOutbox() async throws {
        let storage = try await makeStorage()
        let leftovers = try await OutboxStore.drainLeftovers(from: storage)
        #expect(leftovers.isEmpty)
    }

    // MARK: - Push-failure-keeps-outbox

    @Test("readBatch does not remove entries (entries survive simulated push failure)")
    func pushFailureKeepsOutbox() async throws {
        let storage = try await makeStorage()
        let entryA = makeEntry(rowKey: UUID().uuidString, packedHLC: 10)
        let entryB = makeEntry(rowKey: UUID().uuidString, packedHLC: 20)

        try await OutboxStore.append(entry: entryA, to: storage)
        try await OutboxStore.append(entry: entryB, to: storage)

        // Read the batch (simulating the read before a push attempt).
        let batchBeforePush = try await OutboxStore.readBatch(from: storage)
        #expect(batchBeforePush.count == 2)

        // Simulate transport failure: do NOT call confirm(). Entries must survive.
        let batchAfterFailure = try await OutboxStore.readBatch(from: storage)
        #expect(batchAfterFailure.count == 2,
                "entries must survive a push cycle that did not call confirm()")

        let ids = Set(batchAfterFailure.map { $0.id })
        #expect(ids.contains(entryA.id))
        #expect(ids.contains(entryB.id))
    }

    // MARK: - Schema consolidation (B-12)

    @Test("ensure is idempotent: calling twice does not fail or duplicate tables")
    func ensureIsIdempotent() async throws {
        let storage = try await makeStorage()
        // ensure was already called in makeStorage(); a second call must succeed.
        try await CKSideSchema.ensure(storage: storage)

        // Side tables must be queryable after double-ensure.
        let batch = try await OutboxStore.readBatch(from: storage)
        #expect(batch.isEmpty)
    }

    @Test("outbox entries read back with correct field values")
    func outboxEntryRoundTrip() async throws {
        let storage = try await makeStorage()
        let rowID = UUID()
        let valuesData = try JSONEncoder().encode(
            SyncValueMap(["id": .uuid(rowID), "name": .text("hello")])
        )
        let entry = OutboxEntry(
            id: UUID(),
            tableName: "items",
            rowKey: rowID.uuidString,
            event: .insert,
            valuesData: valuesData,
            hlcWireBytes: Data(HLC(physicalTime: 42, logicalCount: 0, nodeID: 1).wireBytes),
            enqueuedAt: "2026-07-16T00:00:00Z"
        )

        try await OutboxStore.append(entry: entry, to: storage)

        let batch = try await OutboxStore.readBatch(from: storage)
        let recovered = try #require(batch.first)

        #expect(recovered.id == entry.id)
        #expect(recovered.tableName == "items")
        #expect(recovered.rowKey == rowID.uuidString)
        #expect(recovered.event == .insert)
        #expect(ordinal(of: recovered) == 42)
        #expect(recovered.enqueuedAt == "2026-07-16T00:00:00Z")
        #expect(recovered.valuesData != nil)

        // Verify the round-tripped values decode correctly.
        let decodedMap = try JSONDecoder().decode(SyncValueMap.self, from: recovered.valuesData!)
        let typedValues = decodedMap.asTypedValues
        #expect(typedValues["name"] == .text("hello"))
    }
}
