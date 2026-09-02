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
        schemaVersion: Int = 1,
        barrier: (@Sendable (AppliedBatch) async throws -> Void)? = nil
    ) -> SyncManifest {
        SyncManifest(
            kitID: "BarrierTestKit",
            schemaVersion: schemaVersion,
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

    /// Seed a future-schema (v2) `items` record into the cloud fake, pull it
    /// under a v1 manifest so it lands in `_ck_pending_skew`, and disable the
    /// engine. Returns the held row's key. Mirrors the hold phase of
    /// SkewIntegrationTests so the replay phase can be driven with a barrier.
    private func holdFutureSchemaRecord(
        cloud: CloudZoneFake,
        engine: CloudKitSyncEngine,
        storage: any Storage
    ) async throws -> UUID {
        let rowID = UUID()
        let zoneID = CKRecordZone.ID(zoneName: "commit-barrier-zone", ownerName: CKCurrentUserDefaultName)
        let record = try CKRecordMapping.record(
            from: ["id": .uuid(rowID), "title": .text("held for replay")],
            table: "items",
            rowKey: rowID,
            hlc: HLC(physicalTime: 5000, logicalCount: 0, nodeID: 1),
            schemaVersion: 2,
            kitID: "BarrierTestKit",
            zone: zoneID
        )
        await cloud.seed(record: record)

        try await engine.enable(manifest: manifest(schemaVersion: 1), storage: storage)
        _ = try await engine.pull()
        #expect(try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable) == 1)
        #expect(try await storage.rowStore.count(table: "items", where: nil) == 0)
        try await engine.disable()
        return rowID
    }

    @Test("skew replay on enable invokes the barrier with the replayed record")
    func skewReplayInvokesBarrier() async throws {
        let cloud = CloudZoneFake()
        let storage = try await makeStorage()
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        let rowID = try await holdFutureSchemaRecord(cloud: cloud, engine: engine, storage: storage)

        let probe = CommitBarrierProbe()
        await probe.allow()
        try await engine.enable(
            manifest: manifest(schemaVersion: 2) { batch in try await probe.consume(batch) },
            storage: storage
        )

        #expect(await probe.calls == 1)
        #expect(await probe.observedIDs == [rowID])
        #expect(try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable) == 0)
        #expect(try await storage.rowStore.count(table: "items", where: nil) == 1)
    }

    @Test("barrier refusal on skew replay retains the queue entry and fails enable")
    func skewReplayRefusalRetainsQueueEntry() async throws {
        let cloud = CloudZoneFake()
        let storage = try await makeStorage()
        let engine = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)
        let rowID = try await holdFutureSchemaRecord(cloud: cloud, engine: engine, storage: storage)

        let probe = CommitBarrierProbe()
        let v2 = manifest(schemaVersion: 2) { batch in try await probe.consume(batch) }
        await #expect(throws: CommitBarrierProbeError.self) {
            try await engine.enable(manifest: v2, storage: storage)
        }
        #expect(await probe.calls == 1)
        #expect(await probe.observedIDs == [rowID])
        // The queue entry is the replay cursor: a refusal must leave it held.
        #expect(try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable) == 1)
        if case .disabled = await engine.state {} else {
            Issue.record("engine must not report enabled after a replay barrier refusal")
        }

        // The rows were applied idempotently; the next enable() offers the
        // same held record to the barrier again and drains the queue once
        // the barrier accepts it.
        await probe.allow()
        try await engine.enable(manifest: v2, storage: storage)
        #expect(await probe.calls == 2)
        #expect(await probe.observedIDs == [rowID])
        #expect(try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable) == 0)
        #expect(try await storage.rowStore.count(table: "items", where: nil) == 1)
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
