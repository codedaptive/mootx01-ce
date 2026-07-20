// SlotRegistryTests.swift
//
// Tests for the N2 CloudKit slot registry: claim flow, CAS races, eviction,
// epoch fencing, and outbox re-mint.
//
// All tests use FakeCloudKitDatabase (a pure in-process actor) so they run
// without a CloudKit container or network. FakeCloudKitDatabase implements
// real CAS semantics using Swift object identity: a fetched record is the same
// CKRecord instance as the one in the store; a freshly-created record is a
// different object. Saving the same instance (mutation-in-place eviction) passes
// the CAS check; saving a different instance for the same slot ID fails with
// serverRecordChanged, matching production behavior.
//
// Coverage (6 test cases + 1 helper):
//   1. claim-free-slot        — empty registry → slot 1 claimed
//   2. claim-race-retries     — two concurrent claims → each wins a distinct slot
//   3. exhaustion             — all 15 slots active → slotExhausted thrown
//   4. eviction+epoch-bump    — ghost slot → evicted, epoch bumped
//   5. fence-epoch-mismatch   — epoch advanced on server → reenrollRequired
//   6. remint-on-reenroll     — OutboxStore.remintAll changes nodeIDs in outbox

import Testing
import Foundation
import CloudKit
@testable import ConvergenceKitCloudKit
import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes

// MARK: - FakeCloudKitDatabase

/// In-process CAS-correct CloudKit database for slot registry tests.
///
/// CAS semantics (ifServerRecordUnchanged):
/// - No existing record for the slot → insert succeeds.
/// - Existing record AND incoming record is the SAME object (mutation-in-place) → update succeeds.
/// - Existing record AND incoming record is a DIFFERENT object → CAS conflict → throws serverRecordChanged.
///
/// This faithfully models CloudKit's own behavior: a fetched CKRecord carries the server change tag
/// as an opaque property; saving the fetched-and-mutated instance passes the server's check because
/// the tag matches; saving a freshly-constructed instance fails because it has no change tag.
/// Object identity is a reliable in-process proxy for this.
///
/// modifyRecordZones is a no-op that always succeeds (not needed for registry tests).
/// fetchZoneChanges is a no-op (not used by SlotClaimOperation or EpochFence).
actor FakeCloudKitDatabase: CloudKitDatabaseProtocol {

    // The in-memory record store: ID → CKRecord
    private var store: [CKRecord.ID: CKRecord] = [:]

    // CAS check: the ObjectIdentifier of the record that was last stored for each ID.
    // A fresh CKRecord has a different ObjectIdentifier than any stored record.
    private var storedIdentifiers: [CKRecord.ID: ObjectIdentifier] = [:]

    /// Pre-populate the fake database with a record, bypassing CAS.
    /// Used by tests to set up initial registry state (occupied slots, ghosts, etc.).
    func seed(record: CKRecord) {
        store[record.recordID] = record
        storedIdentifiers[record.recordID] = ObjectIdentifier(record)
    }

    /// Overwrite a slot's epoch field, simulating eviction by another device
    /// while this device was away. Used by the fence-epoch-mismatch test.
    func bumpEpoch(for recordID: CKRecord.ID, to newEpoch: Int64) {
        guard let record = store[recordID] else { return }
        record["epoch"] = newEpoch as CKRecordValue
        // Keep same object identity — the record was modified server-side
    }

    // MARK: - CloudKitDatabaseProtocol

    func fetch(
        withRecordIDs recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for id in recordIDs {
            if let record = store[id] {
                results[id] = .success(record)
            } else {
                // Record absent — slot is free (not an error, just missing)
                let err = NSError(
                    domain: CKErrorDomain,
                    code: CKError.Code.unknownItem.rawValue,
                    userInfo: nil
                )
                results[id] = .failure(err)
            }
        }
        return results
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]

        for record in recordsToSave {
            let id = record.recordID

            if savePolicy == .ifServerRecordUnchanged {
                if let existingIdentifier = storedIdentifiers[id] {
                    // CAS check: the incoming record must be the same instance we returned from fetch
                    if existingIdentifier != ObjectIdentifier(record) {
                        // Different instance → CAS conflict (serverRecordChanged)
                        let casError = NSError(
                            domain: CKErrorDomain,
                            code: CKError.Code.serverRecordChanged.rawValue,
                            userInfo: nil
                        )
                        throw casError
                    }
                }
                // No existing record OR same instance → allow the write
            }

            store[id] = record
            storedIdentifiers[id] = ObjectIdentifier(record)
            saveResults[id] = .success(record)
        }

        return (saveResults, [:])
    }

    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        return CloudKitZoneChanges(modifiedRecords: [], deletedRecordIDs: [], changeToken: nil)
    }

    func modifyRecordZones(
        saving recordZonesToSave: [CKRecordZone],
        deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
        return ([:], [:])
    }

    // No-op subscription implementation — slot registry tests do not exercise
    // zone subscriptions. Required by CloudKitDatabaseProtocol (P3-M3).
    func modifySubscriptions(
        saving subscriptionsToSave: [CKSubscription],
        deleting subscriptionIDsToDelete: [CKSubscription.ID]
    ) async throws -> (
        saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
        deleteResults: [CKSubscription.ID: Result<Void, any Error>]
    ) {
        return ([:], [:])
    }
}

// MARK: - Test helpers

private let testZoneID = CKRecordZone.ID(
    zoneName: "TestEstate",
    ownerName: CKCurrentUserDefaultName
)

/// HLC nodeID decoded from an OutboxEntry's full-width wire HLC (gap 6).
private func nodeID(ofWireBytes wire: Data) -> Int {
    Int((try? HLC(wireBytes: [UInt8](wire)))?.nodeID ?? -1)
}

/// Make a DeviceSlot for use as a fake registry entry.
private func makeSlot(
    slotNumber: Int,
    epoch: Int64 = 1,
    deviceUUID: UUID = UUID(),
    lastActiveHLC: HLC = HLC.zero,
    claimedAt: Date = Date()
) -> DeviceSlot {
    DeviceSlot(
        slot: slotNumber,
        epoch: epoch,
        deviceUUID: deviceUUID,
        lastActiveHLC: lastActiveHLC,
        claimedAt: claimedAt
    )
}

/// Make a storage backend with the ConvergenceKit side schema applied.
private func makeStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
    try await storage.open(schema: SchemaDeclaration(
        kitID: "Test",
        version: 1,
        tables: [TableDeclaration(name: "items", columns: [.uuid("id")], primaryKey: ["id"])]
    ))
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

/// Make a no-sleep SlotClaimOperation for deterministic tests.
private func makeClaimOp(
    database: FakeCloudKitDatabase,
    deviceUUID: UUID = UUID(),
    maxAttempts: Int = 5
) -> SlotClaimOperation {
    SlotClaimOperation(
        database: database,
        zoneID: testZoneID,
        deviceUUID: deviceUUID,
        maxAttempts: maxAttempts,
        rng: { 0.5 },              // fixed jitter → deterministic backoff
        clock: { Date() },
        sleep: { _ in }            // no-op sleep → tests don't wait
    )
}

// MARK: - Tests

@Suite("Slot registry — claim flow")
struct SlotClaimTests {

    /// Empty registry → claim succeeds and returns slot 1 (lowest free).
    @Test("claim-free-slot: empty registry → slot 1")
    func claimFreeSlot() async throws {
        let db = FakeCloudKitDatabase()
        let deviceUUID = UUID()
        let op = makeClaimOp(database: db, deviceUUID: deviceUUID)

        let claimed = try await op.claim(preferring: nil)

        #expect(claimed.slot == 1, "should claim the lowest free slot")
        #expect(claimed.epoch == 1, "fresh claim starts at epoch 1")
        #expect(claimed.deviceUUID == deviceUUID)
        #expect(claimed.lastActiveHLC == HLC.zero, "heartbeat happens at push time, not claim time")
    }

    /// Two concurrent claims on an empty registry.
    /// One wins slot 1; the other gets serverRecordChanged, retries, and wins slot 2.
    /// Both end up with distinct slots.
    @Test("claim-race: two concurrent claims → distinct slots")
    func claimRace() async throws {
        let db = FakeCloudKitDatabase()
        let uuidA = UUID()
        let uuidB = UUID()
        let opA = makeClaimOp(database: db, deviceUUID: uuidA, maxAttempts: 8)
        let opB = makeClaimOp(database: db, deviceUUID: uuidB, maxAttempts: 8)

        // Run both claims concurrently via a task group.
        // FakeCloudKitDatabase is an actor: modifyRecords calls are serialized.
        // The first save for slot 1 succeeds; the second gets serverRecordChanged.
        // The loser retries, finds slot 1 occupied, claims slot 2.
        async let resultA = opA.claim(preferring: nil)
        async let resultB = opB.claim(preferring: nil)
        let (a, b) = try await (resultA, resultB)

        // Both should succeed with DIFFERENT slots.
        #expect(a.slot != b.slot, "concurrent claimers must land on distinct slots")
        #expect((1...15).contains(a.slot))
        #expect((1...15).contains(b.slot))

        // Both should have their own UUIDs.
        #expect(a.deviceUUID == uuidA)
        #expect(b.deviceUUID == uuidB)
    }

    /// Debug helper: verify FakeDB fetch returns all seeded records
/// All 15 slots occupied by recently-active devices → slotExhausted.
    @Test("exhaustion: all slots occupied → slotExhausted")
    func exhaustion() async throws {
        let db = FakeCloudKitDatabase()

        // Seed all 15 slots with active (non-evictable) devices.
        //
        // WHY HLC.zero + recent claimedAt:
        // The HLC physicalTime field is 40 bits. Current Unix time in milliseconds
        // (~1.75 trillion in 2026) overflows 40 bits, so ANY non-zero physicalTime
        // that round-trips through pack/unpack appears ~35 years old to the
        // SlotTable eviction check. To make a slot "not evictable" without a
        // heartbeat: use lastActiveHLC = HLC.zero (which takes the ghost path,
        // not the long-inactivity path) and set claimedAt to "now" so the ghost
        // window has not elapsed. A slot with lastActiveHLC=.zero and recent
        // claimedAt is NOT a ghost (< 1 hour old) and NOT long-inactive
        // (HLC.zero excluded from long-inactivity candidates).
        let now = Date()
        for slotNumber in 1...15 {
            let slot = makeSlot(
                slotNumber: slotNumber,
                lastActiveHLC: HLC.zero,
                claimedAt: now
            )
            let record = SlotRecordMapping.record(from: slot, zoneID: testZoneID)
            await db.seed(record: record)
        }

        let op = makeClaimOp(database: db, maxAttempts: 3)

        await #expect(throws: SyncError.self) {
            _ = try await op.claim(preferring: nil)
        }

        // Verify the error is specifically slotExhausted.
        do {
            _ = try await op.claim(preferring: nil)
            Issue.record("expected slotExhausted to be thrown")
        } catch SyncError.slotExhausted {
            // correct
        } catch {
            Issue.record("expected SyncError.slotExhausted, got \(error)")
        }
    }

    /// One ghost slot present → claim evicts it and bumps the epoch.
    ///
    /// A ghost slot is: lastActiveHLC == .zero AND claimedAt older than SlotGhostWindow (1 hour).
    /// SlotTable fast-paths ghost eviction (adjudication A4).
    @Test("eviction+epoch-bump: ghost slot → evicted with bumped epoch")
    func evictionAndEpochBump() async throws {
        let db = FakeCloudKitDatabase()

        // Fill slots 1–14 with active (non-evictable) devices.
        // Same HLC.zero + recent claimedAt pattern as the exhaustion test —
        // see exhaustion test comment for why this makes slots non-evictable.
        let now = Date()
        for slotNumber in 1...14 {
            let slot = makeSlot(
                slotNumber: slotNumber,
                lastActiveHLC: HLC.zero,
                claimedAt: now
            )
            let record = SlotRecordMapping.record(from: slot, zoneID: testZoneID)
            await db.seed(record: record)
        }

        // Slot 15: ghost (lastActiveHLC = .zero, claimedAt > 1 hour ago)
        let ghostClaimedAt = Date().addingTimeInterval(-(SlotGhostWindow + 60))
        let ghostSlot = makeSlot(
            slotNumber: 15,
            epoch: 3,
            lastActiveHLC: HLC.zero,
            claimedAt: ghostClaimedAt
        )
        let ghostRecord = SlotRecordMapping.record(from: ghostSlot, zoneID: testZoneID)
        await db.seed(record: ghostRecord)

        let newDeviceUUID = UUID()
        let op = makeClaimOp(database: db, deviceUUID: newDeviceUUID)

        let claimed = try await op.claim(preferring: nil)

        #expect(claimed.slot == 15, "should evict the ghost at slot 15")
        #expect(claimed.epoch == 4, "eviction bumps epoch from 3 to 4")
        #expect(claimed.deviceUUID == newDeviceUUID)
    }
}

// MARK: - Epoch fence tests

@Suite("Epoch fence — push-path verification")
struct EpochFenceTests {

    /// If the slot's epoch on CloudKit has been bumped (evicted while away),
    /// EpochFence.heartbeat must throw reenrollRequired BEFORE any outbox processing.
    @Test("fence-epoch-mismatch: stale epoch → reenrollRequired before outbox read")
    func fenceRejectsSupersededEpoch() async throws {
        let db = FakeCloudKitDatabase()

        // Seed slot 3 with epoch 1 (what this device thinks it owns)
        let slot3 = makeSlot(
            slotNumber: 3,
            epoch: 1,
            lastActiveHLC: HLC(physicalTime: 500, logicalCount: 0, nodeID: 3)
        )
        let record3 = SlotRecordMapping.record(from: slot3, zoneID: testZoneID)
        await db.seed(record: record3)

        // Simulate eviction: another device bumped epoch to 2 while we were away.
        let recordID3 = SlotRecordMapping.recordID(slot: 3, zoneID: testZoneID)
        await db.bumpEpoch(for: recordID3, to: 2)

        // Device thinks it has slot=3, epoch=1 (stale)
        let staleIdentity = DeviceIdentity(
            deviceUUID: UUID(),
            slot: 3,
            epoch: 1,
            claimedAt: Date()
        )
        let currentHLC = HLC(physicalTime: 1_000, logicalCount: 0, nodeID: 3)

        var caughtError: SyncError? = nil
        do {
            try await EpochFence.heartbeat(
                identity: staleIdentity,
                currentHLC: currentHLC,
                database: db,
                zoneID: testZoneID
            )
            Issue.record("expected reenrollRequired to be thrown")
        } catch let err as SyncError {
            caughtError = err
        } catch {
            Issue.record("expected SyncError, got \(error)")
        }

        guard case .reenrollRequired(let slot, let staleEpoch, let currentEpoch) = caughtError else {
            Issue.record("expected .reenrollRequired, got \(String(describing: caughtError))")
            return
        }
        #expect(slot == 3)
        #expect(staleEpoch == 1)
        #expect(currentEpoch == 2)
    }
}

// MARK: - Re-mint tests

@Suite("OutboxStore.remintAll — A2 re-enrollment safety")
struct RemintTests {

    /// After remintAll, every pending outbox entry has the new nodeID in its HLC.
    ///
    /// WHY remint is safe: outbox entries are unpushed local state — no remote
    /// replica has seen these HLCs. LWW treats re-minted HLCs as the latest local
    /// writes. The new nodeID means no namespace collision with any previously-pushed HLC.
    @Test("remint: re-enrollment changes all outbox entry nodeIDs")
    func remintChangesNodeIDs() async throws {
        let storage = try await makeStorage()
        let now = Date()

        // Seed the outbox with 5 entries using nodeID=3 (old slot)
        let oldNodeID = Int32(3)
        var gen = HLCGenerator(nodeID: oldNodeID)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        for i in 0..<5 {
            let hlc = gen.send(now: nowMs + Int64(i))
            let entry = OutboxEntry(
                id: UUID(),
                tableName: "items",
                rowKey: UUID().uuidString,
                event: .insert,
                valuesData: nil,
                hlcWireBytes: Data(hlc.wireBytes),
                enqueuedAt: ISO8601DateFormatter().string(from: now)
            )
            try await OutboxStore.append(entry: entry, to: storage)
        }

        // Verify all 5 entries have nodeID=3 before remint
        let beforeEntries = try await OutboxStore.readBatch(from: storage)
        #expect(beforeEntries.count == 5)
        for entry in beforeEntries {
            #expect(nodeID(ofWireBytes: entry.hlcWireBytes) == 3,
                    "pre-remint: expected nodeID 3, got \(nodeID(ofWireBytes: entry.hlcWireBytes))")
        }

        // Re-mint all entries under new nodeID=7 (new slot after re-enrollment)
        let newNodeID = Int32(7)
        try await OutboxStore.remintAll(from: storage, newNodeID: newNodeID, nowMillis: nowMs + 10_000)

        // Verify all entries now have nodeID=7
        let afterEntries = try await OutboxStore.readBatch(from: storage)
        #expect(afterEntries.count == 5, "remint must preserve entry count")
        for entry in afterEntries {
            #expect(nodeID(ofWireBytes: entry.hlcWireBytes) == 7,
                    "post-remint: expected nodeID 7, got \(nodeID(ofWireBytes: entry.hlcWireBytes))")
        }

        // Verify the entries are still in ascending HLC order (ordering preserved)
        let hlcs = afterEntries.map { (try? HLC(wireBytes: [UInt8]($0.hlcWireBytes))) ?? .zero }
        for i in 0..<(hlcs.count - 1) {
            #expect(hlcs[i] < hlcs[i + 1], "HLC ordering must be preserved after remint")
        }
    }

    /// remintAll on an empty outbox is a no-op.
    @Test("remint: empty outbox → no-op")
    func remintEmptyOutbox() async throws {
        let storage = try await makeStorage()

        // Verify outbox is empty
        let before = try await OutboxStore.readBatch(from: storage)
        #expect(before.isEmpty)

        // remintAll on empty outbox must not throw
        try await OutboxStore.remintAll(from: storage, newNodeID: 5, nowMillis: 1_000_000)

        let after = try await OutboxStore.readBatch(from: storage)
        #expect(after.isEmpty)
    }
}
