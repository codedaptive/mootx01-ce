// SkewQueueTests.swift
//
// Pure unit tests for PendingSkewQueue and SkewReplay (R9, CVK-ICLOUD P3-M4).
//
// Tests operate on InMemoryStorage with CKSideSchema.ensure applied, verifying
// enqueue, cap-eviction, drainReady, deleteApplied, and countHeld in isolation
// from the CloudKit and Federation transports.

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
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

private func makeSyncRecord(schemaVersion: Int = 1, table: String = "items") -> SyncRecord {
    SyncRecord(
        table: table,
        event: .update,
        rowKey: UUID(),
        values: SyncValueMap(["name": .text("hello")]),
        hlc: PackedHLC(HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)),
        schemaVersion: schemaVersion,
        kitID: "TestKit"
    )
}

// MARK: - PendingSkewQueue unit tests

@Suite("PendingSkewQueue — enqueue and cap-eviction")
struct PendingSkewQueueTests {

    @Test("enqueue: row appears in table with correct schema_version and payload")
    func enqueueStoresRow() async throws {
        let storage = try await makeStorage()
        let record = makeSyncRecord(schemaVersion: 2)
        try await PendingSkewQueue.enqueue(
            record,
            to: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        let count = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable,
            where: nil
        )
        #expect(count == 1)

        // Verify the schema_version was stored correctly.
        let rows = try await storage.rowStore.query(
            table: CKSideSchema.pendingSkewTable,
            where: nil
        )
        #expect(rows.count == 1)
        guard case .int(let storedVersion) = rows.first?["schema_version"] else {
            Issue.record("schema_version not found or wrong type")
            return
        }
        #expect(Int(storedVersion) == 2)
    }

    @Test("enqueue: multiple records all stored independently")
    func enqueueMultiple() async throws {
        let storage = try await makeStorage()
        let r1 = makeSyncRecord(schemaVersion: 2)
        let r2 = makeSyncRecord(schemaVersion: 3)
        let r3 = makeSyncRecord(schemaVersion: 4)
        try await PendingSkewQueue.enqueue(r1, to: storage, sideTable: CKSideSchema.pendingSkewTable)
        try await PendingSkewQueue.enqueue(r2, to: storage, sideTable: CKSideSchema.pendingSkewTable)
        try await PendingSkewQueue.enqueue(r3, to: storage, sideTable: CKSideSchema.pendingSkewTable)
        let count = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable, where: nil
        )
        #expect(count == 3)
    }

    @Test("cap eviction: oldest entries removed when cap exceeded")
    func capEviction() async throws {
        let storage = try await makeStorage()
        // Fill the table to cap + 3 using a small test cap.
        let testCap = 5
        for i in 0..<(testCap + 3) {
            let record = SyncRecord(
                table: "items",
                event: .update,
                rowKey: UUID(),
                values: SyncValueMap(["name": .text("row \(i)")]),
                hlc: PackedHLC(HLC(physicalTime: Int64(i + 1) * 1000, logicalCount: 0, nodeID: 1)),
                schemaVersion: 2,
                kitID: "TestKit"
            )
            let payload = try JSONEncoder().encode(record)
            let receivedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(i)))
            _ = try await storage.rowStore.upsertSync(
                table: CKSideSchema.pendingSkewTable,
                values: [
                    "id":             .uuid(UUID()),
                    "table_name":     .text("items"),
                    "row_key":        .text(record.rowKey.uuidString),
                    "schema_version": .int(2),
                    "received_at":    .text(receivedAt),
                    "payload":        .blob(payload),
                ],
                conflictColumns: ["id"]
            )
        }
        // Verify we have cap+3 before eviction.
        let before = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable, where: nil
        )
        #expect(before == testCap + 3)

        // Run eviction.
        let evicted = try await PendingSkewQueue.evictIfNeeded(
            cap: testCap,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(evicted == 3)

        let after = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable, where: nil
        )
        #expect(after == testCap)
    }

    @Test("evictIfNeeded: no-op when count is at or below cap")
    func evictionNoOp() async throws {
        let storage = try await makeStorage()
        let record = makeSyncRecord(schemaVersion: 2)
        try await PendingSkewQueue.enqueue(
            record, to: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        let evicted = try await PendingSkewQueue.evictIfNeeded(
            cap: 512,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(evicted == 0)
        let count = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable, where: nil
        )
        #expect(count == 1)
    }
}

// MARK: - SkewReplay unit tests

@Suite("SkewReplay — drain, delete, count")
struct SkewReplayTests {

    @Test("drainReady: returns only entries matching currentVersion")
    func drainReadyFiltersVersion() async throws {
        let storage = try await makeStorage()
        let r1 = makeSyncRecord(schemaVersion: 2)  // should be drained
        let r2 = makeSyncRecord(schemaVersion: 3)  // should remain
        let r3 = makeSyncRecord(schemaVersion: 2)  // should be drained
        try await PendingSkewQueue.enqueue(r1, to: storage, sideTable: CKSideSchema.pendingSkewTable)
        try await PendingSkewQueue.enqueue(r2, to: storage, sideTable: CKSideSchema.pendingSkewTable)
        try await PendingSkewQueue.enqueue(r3, to: storage, sideTable: CKSideSchema.pendingSkewTable)

        let ready = try await SkewReplay.drainReady(
            currentVersion: 2,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(ready.count == 2)
        // Verify records round-trip correctly.
        let returnedVersions = ready.map { $0.record.schemaVersion }
        #expect(returnedVersions.allSatisfy { $0 == 2 })
    }

    @Test("drainReady: empty result when no entries match version")
    func drainReadyEmpty() async throws {
        let storage = try await makeStorage()
        let r1 = makeSyncRecord(schemaVersion: 3)
        try await PendingSkewQueue.enqueue(r1, to: storage, sideTable: CKSideSchema.pendingSkewTable)

        let ready = try await SkewReplay.drainReady(
            currentVersion: 2,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(ready.isEmpty)
    }

    @Test("drainReady: does not delete entries — read-without-consume")
    func drainReadyDoesNotDelete() async throws {
        let storage = try await makeStorage()
        let r1 = makeSyncRecord(schemaVersion: 2)
        try await PendingSkewQueue.enqueue(r1, to: storage, sideTable: CKSideSchema.pendingSkewTable)

        _ = try await SkewReplay.drainReady(
            currentVersion: 2,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        // Entry still present after drainReady.
        let count = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable, where: nil
        )
        #expect(count == 1)
    }

    @Test("deleteApplied: removes specified IDs, leaves others intact")
    func deleteApplied() async throws {
        let storage = try await makeStorage()
        let r1 = makeSyncRecord(schemaVersion: 2)
        let r2 = makeSyncRecord(schemaVersion: 2)
        try await PendingSkewQueue.enqueue(r1, to: storage, sideTable: CKSideSchema.pendingSkewTable)
        try await PendingSkewQueue.enqueue(r2, to: storage, sideTable: CKSideSchema.pendingSkewTable)

        let ready = try await SkewReplay.drainReady(
            currentVersion: 2,
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(ready.count == 2)

        // Delete only the first entry.
        let firstID = ready[0].id
        try await SkewReplay.deleteApplied(
            ids: [firstID],
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        let after = try await storage.rowStore.count(
            table: CKSideSchema.pendingSkewTable, where: nil
        )
        #expect(after == 1)
    }

    @Test("countHeld: counts all entries regardless of schema_version")
    func countHeld() async throws {
        let storage = try await makeStorage()
        try await PendingSkewQueue.enqueue(
            makeSyncRecord(schemaVersion: 2), to: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        try await PendingSkewQueue.enqueue(
            makeSyncRecord(schemaVersion: 3), to: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        try await PendingSkewQueue.enqueue(
            makeSyncRecord(schemaVersion: 4), to: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        let held = try await SkewReplay.countHeld(
            from: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(held == 3)
    }

    @Test("payload round-trips: SyncRecord survives encode→store→decode")
    func payloadRoundTrip() async throws {
        let storage = try await makeStorage()
        let rowKey = UUID()
        let original = SyncRecord(
            table: "items",
            event: .update,
            rowKey: rowKey,
            values: SyncValueMap(["name": .text("round-trip test")]),
            hlc: PackedHLC(HLC(physicalTime: 9000, logicalCount: 3, nodeID: 5)),
            schemaVersion: 2,
            kitID: "TestKit"
        )
        try await PendingSkewQueue.enqueue(
            original, to: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        let ready = try await SkewReplay.drainReady(
            currentVersion: 2, from: storage, sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(ready.count == 1)
        let recovered = ready[0].record
        #expect(recovered.table == original.table)
        #expect(recovered.rowKey == original.rowKey)
        #expect(recovered.schemaVersion == original.schemaVersion)
        #expect(recovered.kitID == original.kitID)
        #expect(recovered.hlc.physicalTime == original.hlc.physicalTime)
        #expect(recovered.hlc.logicalCount == original.hlc.logicalCount)
        #expect(recovered.hlc.nodeID == original.hlc.nodeID)
    }
}
