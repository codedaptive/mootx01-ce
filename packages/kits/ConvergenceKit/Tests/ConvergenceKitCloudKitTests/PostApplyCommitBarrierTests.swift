import CloudKit
import ConvergenceKit
import ConvergenceKitCloudKit
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
import Testing
@testable import ConvergenceKitCloudKit

private enum CommitBarrierProbeError: Error {
    case refused
}

private actor CommitBarrierProbe {
    private(set) var calls = 0
    private(set) var observedIDs: [UUID] = []
    private var shouldRefuse = true

    func consume(_ batch: AppliedBatch) throws {
        calls += 1
        observedIDs = batch.appliedByTable["items"] ?? []
        if shouldRefuse { throw CommitBarrierProbeError.refused }
    }

    func allow() { shouldRefuse = false }
}

@Suite("CloudKit post-apply commit barrier", .serialized)
struct PostApplyCommitBarrierTests {
    private func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "BarrierTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        ColumnDeclaration(name: "title", type: .text, nullable: false),
                    ],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    private func manifest(
        barrier: (@Sendable (AppliedBatch) async throws -> Void)? = nil
    ) -> SyncManifest {
        SyncManifest(
            kitID: "BarrierTestKit",
            schemaVersion: 1,
            zoneIdentifier: "commit-barrier-zone",
            tables: [
                SyncedTable(
                    name: "items",
                    primaryKeyColumn: "id",
                    conflictPolicy: .lastWriterWinsByHLC
                )
            ],
            postApplyCommitBarrier: barrier
        )
    }

    @Test("barrier refusal prevents pull commitment and the same batch retries")
    func refusalRetriesSameBatch() async throws {
        let cloud = CloudZoneFake()
        let sourceStorage = try await makeStorage()
        let destinationStorage = try await makeStorage()
        let source = CloudKitSyncEngine(containerIdentifier: nil)
        let destination = CloudKitSyncEngine(containerIdentifier: nil)
        await source.stateActor.setTestDatabase(cloud)
        await destination.stateActor.setTestDatabase(cloud)
        try await source.enable(manifest: manifest(), storage: sourceStorage)

        let probe = CommitBarrierProbe()
        try await destination.enable(
            manifest: manifest { batch in try await probe.consume(batch) },
            storage: destinationStorage
        )

        let rowID = UUID()
        _ = try await sourceStorage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "title": .text("semantic barrier")],
            conflictColumns: ["id"]
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline,
              try await OutboxStore.readBatch(from: sourceStorage).isEmpty {
            await Task.yield()
        }
        #expect(try await !OutboxStore.readBatch(from: sourceStorage).isEmpty)
        _ = try await source.push()

        await #expect(throws: CommitBarrierProbeError.self) {
            _ = try await destination.pull()
        }
        #expect(await probe.calls == 1)
        #expect(await probe.observedIDs == [rowID])
        if case .enabled(_, _, let lastPullAt) = await destination.state {
            #expect(lastPullAt == nil)
        } else {
            Issue.record("destination must remain enabled after a barrier refusal")
        }

        await probe.allow()
        let receipt = try await destination.pull()
        #expect(receipt.pulled == 1)
        #expect(await probe.calls == 2)
        #expect(try await destinationStorage.rowStore.count(table: "items", where: nil) == 1)
        if case .enabled(_, _, let lastPullAt) = await destination.state {
            #expect(lastPullAt != nil)
        } else {
            Issue.record("destination must remain enabled after a successful retry")
        }
    }
}
