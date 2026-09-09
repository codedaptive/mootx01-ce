import Foundation
import Testing
import SubstrateTypes
@testable import PersistenceKit
@testable import PersistenceKitSQLite

private actor SnapshotTransactionGate {
    private var openedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var captureStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didTransactionOpen = false
    private var releaseRequested = false
    private var didCaptureStart = false
    private var didSnapshotReturn = false

    func transactionOpened() {
        didTransactionOpen = true
        let waiters = openedWaiters
        openedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForTransactionToOpen() async {
        guard !didTransactionOpen else { return }
        await withCheckedContinuation { continuation in
            openedWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !releaseRequested else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func releaseTransaction() {
        releaseRequested = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func captureStarted() {
        didCaptureStart = true
        let waiters = captureStartedWaiters
        captureStartedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForCaptureToStart() async {
        guard !didCaptureStart else { return }
        await withCheckedContinuation { continuation in
            captureStartedWaiters.append(continuation)
        }
    }

    func snapshotReturned() {
        didSnapshotReturn = true
    }

    func snapshotHasReturned() -> Bool { didSnapshotReturn }
}

struct SQLiteInventorySnapshotTests {
    private func storage() throws -> SQLiteStorage {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inventory-snapshot-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("estate.sqlite")
        return try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5)
        ))
    }

    private var schema: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "SQLiteInventorySnapshotTests",
            version: 1,
            tables: [
                TableDeclaration(name: "drawers", columns: [.uuid("id"), .text("payload")], primaryKey: ["id"]),
                TableDeclaration(name: "nodes", columns: [.uuid("id"), .text("name")], primaryKey: ["id"]),
            ]
        )
    }

    private func seed(_ storage: SQLiteStorage) async throws {
        _ = try await storage.rowStore.insert(table: "drawers", values: [
            "id": .uuid(UUID()), "payload": .text("drawer")
        ])
        _ = try await storage.rowStore.insert(table: "nodes", values: [
            "id": .uuid(UUID()), "name": .text("node")
        ])
    }

    private func executeFixtureSQL(_ sql: String, on storage: SQLiteStorage) async throws {
        try await storage.backend.connection.exec(sql)
    }

    @Test func canonicalByteCountMatchesSharedArrayAndBlobBoundaries() {
        #expect(InventorySnapshot.serializedByteCount(of: StorageRow(values: [
            "a": .array([])
        ])) == 6)
        #expect(InventorySnapshot.serializedByteCount(of: StorageRow(values: [
            "a": .array([.array([])])
        ])) == 10)
        #expect(InventorySnapshot.serializedByteCount(of: StorageRow(values: [
            "b": .blob(Data([0x00, 0xff]))
        ])) == 10)
    }

    @Test func capturesBothTablesInOneSnapshot() async throws {
        let target = try storage()
        try await target.open(schema: schema)
        try await seed(target)

        let snapshot = try await target.captureInventorySnapshot()
        #expect(snapshot.drawers.count == 1)
        #expect(snapshot.nodes.count == 1)
        await target.close()
    }

    @Test func waitsForAnOpenTransactionThenCapturesBothCommittedTables() async throws {
        let target = try storage()
        try await target.open(schema: schema)
        let gate = SnapshotTransactionGate()

        let transaction = Task {
            try await target.transaction { transaction in
                _ = try await transaction.rowStore.insert(table: "drawers", values: [
                    "id": .uuid(UUID()), "payload": .text("drawer")
                ])
                await gate.transactionOpened()
                await gate.waitForRelease()
                _ = try await transaction.rowStore.insert(table: "nodes", values: [
                    "id": .uuid(UUID()), "name": .text("node")
                ])
            }
        }
        await gate.waitForTransactionToOpen()

        let capture = Task {
            await gate.captureStarted()
            let snapshot = try await target.captureInventorySnapshot()
            await gate.snapshotReturned()
            return snapshot
        }
        await gate.waitForCaptureToStart()

        // Give the capture task a scheduling turn while the transaction is
        // deliberately suspended. A snapshot that ignored the active
        // transaction would complete here with only the drawer row.
        await Task.yield()
        let returnedBeforeCommit = await gate.snapshotHasReturned()
        #expect(!returnedBeforeCommit)

        await gate.releaseTransaction()
        try await transaction.value
        let snapshot = try await capture.value
        #expect(snapshot.drawers.count == 1)
        #expect(snapshot.nodes.count == 1)
        await target.close()
    }

    @Test func limitPlusOneRejectsAnOversizedTable() async throws {
        let target = try storage()
        try await target.open(schema: schema)
        try await seed(target)
        _ = try await target.rowStore.insert(table: "drawers", values: [
            "id": .uuid(UUID()), "payload": .text("second drawer")
        ])

        await #expect(throws: InventorySnapshotError.self) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 1, maxSerializedBytes: 1_024)
            )
        }
        await target.close()
    }

    @Test func rejectsByteBoundBeforeReturningASnapshot() async throws {
        let target = try storage()
        try await target.open(schema: schema)
        try await seed(target)

        await #expect(throws: InventorySnapshotError.self) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 2, maxSerializedBytes: 1)
            )
        }
        await target.close()
    }

    @Test func rejectsAnOversizedSingleBodyFromLengthPreflight() async throws {
        let target = try storage()
        try await target.open(schema: schema)
        _ = try await target.rowStore.insert(table: "drawers", values: [
            "id": .uuid(UUID()), "payload": .text(String(repeating: "x", count: 1_048_576))
        ])
        _ = try await target.rowStore.insert(table: "nodes", values: [
            "id": .uuid(UUID()), "name": .text("node")
        ])

        await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 1_024)) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 2, maxSerializedBytes: 1_024)
            )
        }
        #expect(await target.backend.inventorySnapshotFullRowMaterializations == 0)
        await target.close()
    }

    @Test func rejectsCanonicalFramingGapBeforeMaterializingTheBody() async throws {
        let target = try storage()
        try await target.open(schema: schema)
        _ = try await target.rowStore.insert(table: "drawers", values: [
            "id": .uuid(UUID()), "payload": .text(String(repeating: "x", count: 50))
        ])

        // The legacy length-only preflight counted 100 bytes here. Canonical
        // `t:<length>:` framing makes the exact row 105 bytes, so 102 must
        // reject before SQLite copies the row body into Swift.
        await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 102)) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 2, maxSerializedBytes: 102)
            )
        }
        #expect(await target.backend.inventorySnapshotFullRowMaterializations == 0)
        await target.close()
    }

    @Test func rejectsOversizedWrongStorageClassBeforeMaterializingFixedWidthColumn() async throws {
        let target = try storage()
        let fixedWidthSchema = SchemaDeclaration(
            kitID: "SQLiteInventorySnapshotFixedWidthGuardTests",
            version: 1,
            tables: [
                TableDeclaration(name: "drawers", columns: [.uuid("id")], primaryKey: ["id"]),
                TableDeclaration(name: "nodes", columns: [.uuid("id")], primaryKey: ["id"]),
            ]
        )
        try await target.open(schema: fixedWidthSchema)
        try await executeFixtureSQL(
            "INSERT INTO \"drawers\" (\"id\") VALUES (zeroblob(1048576))",
            on: target
        )

        await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 1_024)) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 1, maxSerializedBytes: 1_024)
            )
        }
        #expect(await target.backend.inventorySnapshotFullRowMaterializations == 0)
        await target.close()
    }

    @Test func highBitHLCExactCanonicalBoundaryIsAcceptedThenRejected() async throws {
        let target = try storage()
        let hlcSchema = SchemaDeclaration(
            kitID: "SQLiteInventorySnapshotHLCBoundaryTests",
            version: 1,
            tables: [
                TableDeclaration(name: "drawers", columns: [.hlc("h")], primaryKey: ["h"]),
                TableDeclaration(name: "nodes", columns: [.hlc("h")], primaryKey: ["h"]),
            ]
        )
        try await target.open(schema: hlcSchema)
        _ = try await target.rowStore.insert(table: "drawers", values: [
            "h": .hlc(HLC(packed: 0x8000_0000_0000_0000))
        ])

        _ = try await target.captureInventorySnapshot(
            limits: InventorySnapshotLimits(maxRowsPerTable: 1, maxSerializedBytes: 23)
        )
        await #expect(throws: InventorySnapshotError.byteLimitExceeded(limit: 22)) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 1, maxSerializedBytes: 22)
            )
        }
        await target.close()
    }
}
