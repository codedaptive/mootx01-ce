// SkewIntegrationTests.swift
//
// CloudKit integration tests for schema-skew pending queue (R9, CVK-ICLOUD P3-M4).
//
// Tests exercise the full pull() → enqueue → enable() → replay → apply path
// using a single-estate CloudKitSyncEngine with an injected CloudZoneFake.
// CKRecords are crafted with specific schemaVersions via CKRecordMapping.record().
//
// Test matrix (mission spec):
//   1. hold-then-replay: future-schema record held in _ck_pending_skew during pull;
//      applied to user table after re-enable() with upgraded manifest.
//   2. downgrade-rejected: record with schemaVersion < manifest.schemaVersion counted
//      as conflict (not enqueued in the skew queue).
//   3. echo-suppressed: outbox stays empty after replay (upsertSync uses .syncApply
//      origin; observer skips outbox append per echo-suppression contract, I-10).
//   4. event emission: pull() emits recordsHeldForMigration when future-schema records
//      are held; enable() emits it again when still-held records remain.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Helpers

/// Open InMemoryStorage with the `items` table schema shared by all skew tests.
/// CKSideSchema.ensure is called inside CloudKitStateActor.enable(), so it is
/// NOT called here — that mirrors the production path. The test app schema is
/// version 1; the manifest schemaVersion is supplied separately per test.
private func makeSkewStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
    try await storage.open(schema: SchemaDeclaration(
        kitID: "TestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("title")],
                primaryKey: ["id"]
            )
        ],
        indices: [],
        migrations: []
    ))
    return storage
}

/// Build a manifest for the `items` table with a given sync schemaVersion.
private func makeManifest(schemaVersion: Int) -> SyncManifest {
    SyncManifest(
        kitID: "TestKit",
        schemaVersion: schemaVersion,
        zoneIdentifier: "CVK-SKEW-TEST",
        tables: [
            SyncedTable(
                name: "items",
                direction: .bidirectional,
                primaryKeyColumn: "id",
                conflictPolicy: .lastWriterWinsByHLC
            )
        ]
    )
}

private let testZoneID = CKRecordZone.ID(
    zoneName: "CVK-SKEW-TEST",
    ownerName: CKCurrentUserDefaultName
)

/// Build and seed a CKRecord with the given schemaVersion into a cloud fake.
/// Returns the rowKey used so callers can query the user table afterward.
@discardableResult
private func seedRecord(
    into cloud: CloudZoneFake,
    schemaVersion: Int,
    title: String = "Held item"
) async throws -> UUID {
    let rowKey = UUID()
    let hlc = HLC(physicalTime: 5000, logicalCount: 0, nodeID: 1)
    let record = try CKRecordMapping.record(
        from: ["id": .uuid(rowKey), "title": .text(title)],
        table: "items",
        rowKey: rowKey,
        hlc: hlc,
        schemaVersion: schemaVersion,
        kitID: "TestKit",
        zone: testZoneID
    )
    await cloud.seed(record: record)
    return rowKey
}

// MARK: - Event collection helper

/// Actor-based collector for SyncEvents. Safely captures events from a
/// Task closure in Swift 6's strict concurrency model.
private actor EventCollector {
    private var collected: [SyncEvent] = []
    func add(_ event: SyncEvent) { collected.append(event) }
    func getAll() -> [SyncEvent] { collected }
}

/// Collect all SyncEvents emitted during an async block.
///
/// Subscribes to the engine's event stream before the block, then YIELDS
/// to let `attachSubscriber` run on the state actor (critical ordering),
/// then runs the block, yields again to let buffered events flush, cancels
/// the collector task, and returns whatever events were recorded.
///
/// The collector actor ensures the Task closure captures no non-Sendable
/// state (Swift 6 strict concurrency safe).
///
/// WHY yield before the block: `subscribe()` launches a Task internally
/// that calls `stateActor.attachSubscriber(continuation)`. If we call
/// `pull()` before that task runs, the actor has no registered subscriber
/// and all emitted events are discarded. Yielding 20+ times lets the
/// subscriber-attachment task execute before any events are emitted.
private func collectEvents(
    from engine: CloudKitSyncEngine,
    during block: () async throws -> Void
) async throws -> [SyncEvent] {
    let collector = EventCollector()
    let stream = engine.subscribe()
    // Start the collector task immediately so it blocks on the stream.
    let task = Task { [collector] in
        for await event in stream {
            await collector.add(event)
        }
    }
    // Yield to let the attachSubscriber task on the state actor run before
    // the block produces any events. Without this yield the actor may not
    // have processed the subscription yet and events are silently dropped.
    for _ in 0..<30 { await Task.yield() }
    try await block()
    // Yield again to let any queued event deliveries flush before we stop.
    for _ in 0..<30 { await Task.yield() }
    task.cancel()
    return await collector.getAll()
}

// MARK: - Integration tests

@Suite("Skew integration — hold, replay, echo, events")
struct SkewIntegrationTests {

    // MARK: 1. hold-then-replay-after-version-bump

    @Test("hold-then-replay: future-schema record held during pull, applied on re-enable")
    func holdThenReplay() async throws {
        let storage = try await makeSkewStorage()
        let cloud   = CloudZoneFake()
        let engine  = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)

        // Seed a record with schemaVersion=2 into the cloud.
        _ = try await seedRecord(into: cloud, schemaVersion: 2, title: "Future row")

        // --- Phase 1: enable with v1 manifest, pull → record held ---

        let v1Manifest = makeManifest(schemaVersion: 1)
        try await engine.enable(manifest: v1Manifest, storage: storage)
        _ = try await engine.pull()

        // Record must be held in _ck_pending_skew, NOT in the items table.
        let held = try await SkewReplay.countHeld(
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(held == 1, "expected 1 held record, got \(held)")

        let itemsAfterV1Pull = try await storage.rowStore.query(table: "items", where: nil)
        #expect(itemsAfterV1Pull.isEmpty,
                "items table must be empty — record must not be applied with v1 manifest")

        // --- Phase 2: disable, re-enable with v2 manifest → replay applies record ---

        try await engine.disable()
        let v2Manifest = makeManifest(schemaVersion: 2)
        try await engine.enable(manifest: v2Manifest, storage: storage)

        // Replay happens during enable(). The queue should now be empty.
        let heldAfterReplay = try await SkewReplay.countHeld(
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(heldAfterReplay == 0,
                "pending-skew queue must be drained after enable() with v2 manifest")

        // And the record must have landed in the items table.
        let itemsAfterV2Enable = try await storage.rowStore.query(table: "items", where: nil)
        #expect(itemsAfterV2Enable.count == 1,
                "items table must have 1 row after replay, got \(itemsAfterV2Enable.count)")

        // Verify the replayed row carries the correct title (payload round-trip).
        if let row = itemsAfterV2Enable.first {
            if case .text(let title) = row["title"] {
                #expect(title == "Future row", "replayed row must carry original title")
            } else {
                Issue.record("title column missing or wrong type in replayed row")
            }
        }
    }

    // MARK: 2. downgrade-rejected

    @Test("downgrade-rejected: older-schema record counts as conflict, not held")
    func downgradeRejected() async throws {
        let storage = try await makeSkewStorage()
        let cloud   = CloudZoneFake()
        let engine  = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)

        // Seed a record with schemaVersion=0 — older than the estate's manifest v1.
        try await seedRecord(into: cloud, schemaVersion: 0, title: "Downgrade row")

        let v1Manifest = makeManifest(schemaVersion: 1)
        try await engine.enable(manifest: v1Manifest, storage: storage)
        let receipt = try await engine.pull()

        // The downgrade-schema record is a conflict, not a hold.
        #expect(receipt.conflicts >= 1,
                "downgrade record must increment conflict counter")

        // Must NOT appear in the skew queue.
        let held = try await SkewReplay.countHeld(
            from: storage,
            sideTable: CKSideSchema.pendingSkewTable
        )
        #expect(held == 0, "downgrade record must not be enqueued in pending-skew")

        // Must NOT appear in the items table.
        let items = try await storage.rowStore.query(table: "items", where: nil)
        #expect(items.isEmpty, "downgrade record must not be applied to items table")
    }

    // MARK: 3. echo-suppressed (outbox stays empty after replay)

    @Test("echo-suppressed: replayed records do not re-enter outbox")
    func echoSuppressed() async throws {
        let storage = try await makeSkewStorage()
        let cloud   = CloudZoneFake()
        let engine  = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)

        // Seed a future-schema record.
        try await seedRecord(into: cloud, schemaVersion: 2, title: "Echo test row")

        // Phase 1: hold during v1 pull.
        try await engine.enable(manifest: makeManifest(schemaVersion: 1), storage: storage)
        _ = try await engine.pull()

        // Outbox must be empty after pull — held records are not pushed back.
        let outboxAfterHold = try await OutboxStore.readBatch(from: storage)
        #expect(outboxAfterHold.isEmpty,
                "outbox must be empty after holding a future-schema record")

        // Phase 2: re-enable with v2 → replay.
        try await engine.disable()
        try await engine.enable(manifest: makeManifest(schemaVersion: 2), storage: storage)

        // Allow any observer tasks to flush (yield multiple times).
        for _ in 0..<30 { await Task.yield() }

        // Outbox must still be empty — replay writes via upsertSync (.syncApply origin)
        // which the observer ignores (echo-suppression invariant, I-10).
        let outboxAfterReplay = try await OutboxStore.readBatch(from: storage)
        #expect(outboxAfterReplay.isEmpty,
                "outbox must stay empty after replay (echo-suppression must hold)")
    }

    // MARK: 4. event emission

    @Test("event emission: pull emits recordsHeldForMigration for future-schema records")
    func eventEmittedOnPull() async throws {
        let storage = try await makeSkewStorage()
        let cloud   = CloudZoneFake()
        let engine  = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)

        // Seed two future-schema records.
        try await seedRecord(into: cloud, schemaVersion: 2, title: "Hold A")
        try await seedRecord(into: cloud, schemaVersion: 2, title: "Hold B")

        try await engine.enable(manifest: makeManifest(schemaVersion: 1), storage: storage)

        let events = try await collectEvents(from: engine) {
            _ = try await engine.pull()
        }

        // Exactly one recordsHeldForMigration event must be emitted with count=2.
        let heldEvents = events.compactMap { event -> Int? in
            if case .recordsHeldForMigration(let count) = event { return count }
            return nil
        }
        #expect(!heldEvents.isEmpty,
                "pull must emit at least one recordsHeldForMigration event")
        #expect(heldEvents.first == 2,
                "event count must equal number of held records (2), got \(String(describing: heldEvents.first))")
    }

    @Test("event emission: enable emits recordsHeldForMigration when future records remain unharvested")
    func eventEmittedOnEnableWhenStillHeld() async throws {
        let storage = try await makeSkewStorage()
        let cloud   = CloudZoneFake()
        let engine  = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)

        // Seed one v2 record and one v3 record.
        // After re-enable with v2 manifest, the v2 record is drained but v3 stays held.
        try await seedRecord(into: cloud, schemaVersion: 2, title: "v2 row")
        try await seedRecord(into: cloud, schemaVersion: 3, title: "v3 row")

        // Phase 1: pull with v1 → both held.
        try await engine.enable(manifest: makeManifest(schemaVersion: 1), storage: storage)
        _ = try await engine.pull()
        let beforeReplay = try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable)
        #expect(beforeReplay == 2)

        // Phase 2: re-enable with v2 → drains the v2 entry, v3 stays.
        try await engine.disable()

        let enableEvents = try await collectEvents(from: engine) {
            try await engine.enable(manifest: makeManifest(schemaVersion: 2), storage: storage)
        }

        // v3 row still in queue.
        let afterReplay = try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable)
        #expect(afterReplay == 1, "v3 row must remain held after v2 enable")

        // enable() must emit recordsHeldForMigration because 1 entry still held.
        let heldFromEnable = enableEvents.compactMap { event -> Int? in
            if case .recordsHeldForMigration(let count) = event { return count }
            return nil
        }
        #expect(!heldFromEnable.isEmpty,
                "enable() must emit recordsHeldForMigration when queue is non-empty after replay")
        #expect(heldFromEnable.first == 1,
                "event count must equal still-held count (1), got \(String(describing: heldFromEnable.first))")
    }

    // MARK: 5. correct-version record unaffected (sanity gate)

    @Test("same-version record applied normally — skew path not triggered")
    func sameVersionAppliedNormally() async throws {
        let storage = try await makeSkewStorage()
        let cloud   = CloudZoneFake()
        let engine  = CloudKitSyncEngine(containerIdentifier: nil)
        await engine.stateActor.setTestDatabase(cloud)

        // Seed a record with schemaVersion matching the manifest (v1 == v1).
        _ = try await seedRecord(into: cloud, schemaVersion: 1, title: "Normal row")

        try await engine.enable(manifest: makeManifest(schemaVersion: 1), storage: storage)
        let receipt = try await engine.pull()

        // Record applied normally.
        #expect(receipt.conflicts == 0)
        let items = try await storage.rowStore.query(table: "items", where: nil)
        #expect(items.count == 1, "same-version record must land in items table")

        // Skew queue must remain empty.
        let held = try await SkewReplay.countHeld(from: storage, sideTable: CKSideSchema.pendingSkewTable)
        #expect(held == 0, "skew queue must remain empty for same-version records")
    }
}
