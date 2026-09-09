import Foundation
import Testing
import PersistenceKit
import PersistenceKitInMemory

struct InventorySnapshotTests {
    private func storage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    private var schema: SchemaDeclaration {
        SchemaDeclaration(
            kitID: "InventorySnapshotTests",
            version: 1,
            tables: [
                TableDeclaration(name: "drawers", columns: [.uuid("id"), .text("payload")], primaryKey: ["id"]),
                TableDeclaration(name: "nodes", columns: [.uuid("id"), .text("name")], primaryKey: ["id"]),
            ]
        )
    }

    private func seed(_ storage: InMemoryStorage) async throws {
        _ = try await storage.rowStore.insert(table: "drawers", values: [
            "id": .uuid(UUID()), "payload": .text("drawer")
        ])
        _ = try await storage.rowStore.insert(table: "nodes", values: [
            "id": .uuid(UUID()), "name": .text("node")
        ])
    }

    @Test func copiesDrawersAndNodesTogether() async throws {
        let target = storage()
        try await target.open(schema: schema)
        try await seed(target)

        let snapshot = try await target.captureInventorySnapshot()
        #expect(snapshot.drawers.count == 1)
        #expect(snapshot.nodes.count == 1)
    }

    @Test func rejectsRowsBeyondTheBoundWithoutReturningAPartialSnapshot() async throws {
        let target = storage()
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
    }

    @Test func rejectsCumulativeSerializedBytesDuringCopy() async throws {
        let target = storage()
        try await target.open(schema: schema)
        try await seed(target)

        await #expect(throws: InventorySnapshotError.self) {
            try await target.captureInventorySnapshot(
                limits: InventorySnapshotLimits(maxRowsPerTable: 2, maxSerializedBytes: 1)
            )
        }
    }
}
