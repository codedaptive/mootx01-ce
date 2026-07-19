// SlotFencingScenarios.swift
//
// CVK-ICLOUD P4-M3 — Slot exhaustion, eviction, and epoch-fencing scenarios.
//
// PURPOSE: Six test scenarios that prove N2 closes the silent-divergence blind
// spot identified in the slot-registry design review. The core invariant is
// A5 (loud failure, not silent): a device with a stale (slot, epoch) is
// rejected BEFORE any data record reaches the shared cloud, and is then
// re-enrolled with a fresh HLC node ID so all reminted entries are strictly
// greater than any pre-eviction write.
//
// COVERAGE:
//   (1) slotExhausted surfaces loudly when all 15 slots are active and non-evictable.
//   (2) Eviction selects the long-inactive slot via 40-bit masked HLC comparison
//       (exercises the 2026-scale truncation regression territory from Adams P1).
//   (3a) Epoch fence rejects a stale device BEFORE any outbox record reaches the cloud.
//   (3b) remintAll changes nodeID on all entries; reminted HLCs > all pre-eviction HLCs (A2).
//   (3c) Engine auto-reenrolls on push; B converges; cloud records carry new nodeID.
//   (4) Concurrent CAS claimers never share a node ID.
//   (5) LWW ordering is identical on both estates after evict-then-reclaim.
//   (6) Ghost fast-path: old ghost → evictable; recent ghost and heartbeated-active → not.
//
// References:
//   SlotTable.swift         — SlotLongInactivityWindow, SlotGhostWindow, evictionCandidate(now:)
//   EpochFence.swift        — step 3b (epoch check fires before heartbeat save, step 4)
//   OutboxStore.swift       — remintAll(from:newNodeID:nowMillis:)
//   SlotRegistryTests.swift — FakeCloudKitDatabase (internal, accessible from same test module)
//   TwoEstateFixture.swift  — two-estate convergence harness

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import ConvergenceKitCloudKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - P4-M3 module-level private helpers
//
// Named with the "p4m3" prefix to avoid conceptual confusion with the private
// helpers in SlotRegistryTests.swift (those are file-scoped and not visible
// here; unique naming prevents accidental cross-file conceptual coupling).
// ─────────────────────────────────────────────────────────────────────────────

/// A dedicated test zone used only by P4-M3 unit tests. Separate from the
/// TwoEstateFixture convergence zone ("CVK-ICLOUD-P4") to avoid cross-test
/// state leakage when both are in the same test run.
private let p4m3ZoneID = CKRecordZone.ID(
    zoneName: "CVK-P4-M3-Fencing",
    ownerName: CKCurrentUserDefaultName
)

/// Build a no-sleep SlotClaimOperation against the P4-M3 zone.
/// rng: { 0.5 } makes backoff deterministic; sleep: { _ in } makes it instant.
private func p4m3ClaimOp(
    database: FakeCloudKitDatabase,
    deviceUUID: UUID = UUID(),
    maxAttempts: Int = 8,
    clock: @Sendable @escaping () -> Date = { Date() }
) -> SlotClaimOperation {
    SlotClaimOperation(
        database: database,
        zoneID: p4m3ZoneID,
        deviceUUID: deviceUUID,
        maxAttempts: maxAttempts,
        rng: { 0.5 },
        clock: clock,
        sleep: { _ in }
    )
}

/// Build a DeviceSlot value for registry snapshot seeding.
/// `lastActiveHLC: .zero` + recent `claimedAt` = recently-claimed ghost (non-evictable).
private func p4m3Slot(
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

/// Extract the HLC nodeID from an OutboxEntry's full-width wire HLC (gap 6).
/// Applies to OUTBOX ENTRIES where hlcWireBytes = Data(hlc.wireBytes).
/// Matches nodeID(ofWireBytes:) in SlotRegistryTests.swift so assertions are
/// comparable.
private func p4m3NodeIDOf(_ hlcWireBytes: Data) -> Int {
    Int((try? HLC(wireBytes: [UInt8](hlcWireBytes)))?.nodeID ?? -1)
}

/// Extract the HLC nodeID from bits 3–0 of a CKRecord `_syncHLC` field value.
/// Applies to CKRecords where _syncHLC = CKRecordMapping.packed(hlc).
/// Layout (CKRecordMapping.packed): physical 48 | logical 12 | node 4.
/// This is a DIFFERENT layout from HLC.packed — the nodeID is in the low 4 bits.
private func ckRecordNodeIDOf(_ packedHLC: Int64) -> Int {
    Int(UInt64(bitPattern: packedHLC) & 0xF)
}

/// Build a storage backend with the ConvergenceKit outbox side-schema applied.
/// Used by the remint unit test (3b) to create an outbox without a live engine.
private func p4m3Storage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory
    ))
    try await storage.open(schema: SchemaDeclaration(
        kitID: "Test",
        version: 1,
        tables: [TableDeclaration(
            name: "items",
            columns: [
                .uuid("id"),
                ColumnDeclaration(name: "title", type: .text, nullable: true),
                ColumnDeclaration(name: "value", type: .int,  nullable: true),
            ],
            primaryKey: ["id"]
        )]
    ))
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TwoEstateFixture extensions for P4-M3
//
// These methods inject test state directly into the shared CloudZoneFake,
// allowing P4-M3 integration tests to simulate epoch bumps (eviction by a
// third device) and query cloud data records without touching the fake's
// private store.
// ─────────────────────────────────────────────────────────────────────────────

extension TwoEstateFixture {

    /// Seed a slot record with a bumped epoch into the shared cloud, bypassing CAS.
    /// Simulates another device evicting `slot` and re-owning it at the new epoch
    /// while this estate was inactive. After this, any engine still holding the old
    /// epoch will receive reenrollRequired from EpochFence on its next push.
    ///
    /// Uses `Self.zoneID` (the fixture's convergence zone) because the engines'
    /// EpochFence fetches slot records from that zone.
    func bumpSlotEpoch(slot: Int, to epoch: Int64) async {
        let recordID = CKRecord.ID(recordName: "_slot_\(slot)", zoneID: Self.zoneID)
        let record = CKRecord(recordType: "_ck_device_slot", recordID: recordID)
        // New owner UUID — another device took this slot after eviction.
        record["device_uuid"]     = UUID().uuidString as CKRecordValue
        record["epoch"]           = epoch as CKRecordValue
        record["last_active_hlc"] = Int64(0) as CKRecordValue
        // ISO8601 string — schema-invariants.md: date storage is TEXT, never REAL.
        record["claimed_at"] = SlotRecordMapping.iso8601.string(from: Date()) as CKRecordValue
        await cloud.seed(record: record)
    }

    /// All non-slot CKRecords currently stored in the shared cloud.
    func allCloudDataRecords() async -> [CKRecord] {
        await cloud.allDataRecords()
    }

    /// Count of non-slot records in the cloud for the fixture's zone.
    func cloudDataRecordCount() async -> Int {
        await cloud.dataRecordCount(in: Self.zoneID)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Test suite
// ─────────────────────────────────────────────────────────────────────────────

@Suite("CVK-ICLOUD P4-M3 — Slot exhaustion, eviction, fencing")
struct SlotFencingScenarios {

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 1: slotExhausted (A5 — loud failure)
    // ─────────────────────────────────────────────────────────────────────────

    /// 15 devices claim slots 1–15 via CAS on a shared FakeCloudKitDatabase.
    /// Each claimed slot has lastActiveHLC=.zero and claimedAt=now — making them
    /// recently-claimed ghosts (within the 1-hour ghost window), so none is an
    /// eviction candidate. A 16th claim finds all slots occupied and non-evictable
    /// → SyncError.slotExhausted must surface loudly to the caller (A5).
    @Test("(1) slotExhausted: 16th active claim with no eviction candidate → loud SyncError.slotExhausted")
    func slotExhaustedOnSixteenthClaim() async throws {
        let db = FakeCloudKitDatabase()
        var claimedSlots: [Int] = []

        // 15 sequential CAS claims. Deterministic order: lowest free slot first.
        for _ in 0..<15 {
            let op = p4m3ClaimOp(database: db, deviceUUID: UUID())
            let slot = try await op.claim(preferring: nil)
            claimedSlots.append(slot.slot)
        }

        // All 15 claims must land on distinct valid slots.
        #expect(Set(claimedSlots).count == 15,
                "15 sequential CAS claims must produce 15 distinct slot numbers")
        #expect(claimedSlots.allSatisfy { (1...15).contains($0) },
                "all claimed slots must be in the valid registry range 1–15")

        // 16th claim: all 15 slots active and within the ghost window (non-evictable).
        // SlotClaimOperation must throw slotExhausted.
        let op16 = p4m3ClaimOp(database: db, deviceUUID: UUID(), maxAttempts: 2)
        var caught: SyncError? = nil
        do {
            _ = try await op16.claim(preferring: nil)
            Issue.record("expected SyncError.slotExhausted but claim succeeded")
        } catch let err as SyncError {
            caught = err
        } catch {
            Issue.record("expected SyncError, got \(error)")
        }

        // A5: slotExhausted must surface loudly, not be silenced.
        guard case .slotExhausted(let activeCount) = caught else {
            Issue.record("expected .slotExhausted, got \(String(describing: caught))")
            return
        }
        #expect(activeCount > 0,
                "slotExhausted must report a positive active-slot count")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 2: eviction with 2026-scale packed-round-trip HLC
    // ─────────────────────────────────────────────────────────────────────────

    /// 14 active non-evictable slots + 1 long-inactive slot whose lastActiveHLC
    /// physicalTime is 35 days ago expressed as a full-width 2026 Unix-ms value.
    /// That value (~1.749e12) exceeds 2^40 (~1.10e12), so it truncates to its
    /// 40-bit residue when packed via HLC.packed and re-read via HLC(packed:).
    ///
    /// WHY THE 2026-SCALE PATH MATTERS:
    /// Without the dual-mask fix in SlotTable.evictionCandidate(), comparing the
    /// truncated physicalTime against full-width nowMillis makes every non-ghost
    /// slot look ~35 years stale — ALL become eviction-eligible (Adams P1 CRITICAL #1).
    /// With the fix (both sides masked to 40 bits), only the genuinely inactive
    /// slot qualifies, and the 16th claim correctly evicts it.
    @Test("(2) eviction: 16th claim with 2026-scale inactive HLC slot → evict slot 15 + epoch bump (40-bit truncation regression territory)")
    func evictionWithPackedRoundTripHLC() async throws {
        let db = FakeCloudKitDatabase()
        let now = Date()

        // 14 active non-evictable slots: HLC.zero + claimedAt=now.
        // lastActiveHLC=.zero means "never heartbeated" and claimedAt=now means
        // the 1-hour ghost window has not passed → not evictable via ghost fast-path
        // and no physicalTime to compare via the long-inactivity path.
        for slotNumber in 1...14 {
            let slot = p4m3Slot(slotNumber: slotNumber, lastActiveHLC: HLC.zero, claimedAt: now)
            await db.seed(record: SlotRecordMapping.record(from: slot, zoneID: p4m3ZoneID))
        }

        // Slot 15: long-inactive. physicalTime is full-width 2026-scale (> 2^40).
        let nowMs            = Int64(now.timeIntervalSince1970 * 1000)  // ~1.75e12
        let thirtyFiveDaysMs = Int64(35 * 24 * 60 * 60 * 1000)
        let evictablePhysMs  = nowMs - thirtyFiveDaysMs  // still > 2^40, truncates on pack

        let inactiveSlot = p4m3Slot(
            slotNumber: 15,
            epoch: 3,
            // Full-width physicalTime. When packed via HLC.packed (40-bit physical field)
            // then re-read via HLC(packed:), physicalTime becomes evictablePhysMs & 0xFF_FFFF_FFFF.
            // SlotTable.evictionCandidate() masks BOTH sides before comparing, so the
            // 35-day delta survives the truncation correctly.
            lastActiveHLC: HLC(physicalTime: evictablePhysMs, logicalCount: 0, nodeID: 15),
            claimedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970 - 35 * 24 * 60 * 60)
        )
        // Seed via SlotRecordMapping to exercise the encode/decode path that
        // real CloudKit registry records use (pack → CKRecord field → unpack).
        await db.seed(record: SlotRecordMapping.record(from: inactiveSlot, zoneID: p4m3ZoneID))

        // 16th device claims with a fixed clock = now so the eviction math is
        // symmetric with our evictablePhysMs setup above.
        let newDeviceUUID = UUID()
        let op = SlotClaimOperation(
            database: db,
            zoneID: p4m3ZoneID,
            deviceUUID: newDeviceUUID,
            maxAttempts: 5,
            rng: { 0.5 },
            clock: { now },
            sleep: { _ in }
        )
        let claimed = try await op.claim(preferring: nil)

        // Slot 15 must be evicted (only slot with lastActiveHLC beyond 30 days).
        #expect(claimed.slot      == 15,          "slot 15 must be the eviction candidate")
        #expect(claimed.epoch     == 4,           "epoch must bump 3 → 4 on eviction")
        #expect(claimed.deviceUUID == newDeviceUUID)
        #expect(claimed.lastActiveHLC == HLC.zero, "lastActiveHLC must be .zero after eviction")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3a: EpochFence rejects BEFORE any record reaches the cloud
    // ─────────────────────────────────────────────────────────────────────────

    /// A device holds stale identity (slot=5, epoch=1). The shared cloud has
    /// slot 5 at epoch=2 (bumped while the device was inactive). EpochFence.heartbeat
    /// detects the mismatch at step 3b and throws reenrollRequired BEFORE step 4
    /// (heartbeat save). Zero data records land in the cloud.
    ///
    /// This directly tests A5 and N2: the fence fires at the epoch check (a
    /// metadata operation), NOT after outbox entries have been pushed under the stale
    /// nodeID. Silent LWW divergence requires two devices to share a nodeID; this
    /// gate prevents that from ever happening.
    @Test("(3a) epoch fence: reenrollRequired thrown BEFORE any record reaches cloud (A5, N2)")
    func staleFenceBeforeAnyRecordLands() async throws {
        let cloud = CloudZoneFake()

        // Seed slot 5 at epoch=2 (another device evicted and re-claimed it).
        let bumpedID = CKRecord.ID(recordName: "_slot_5", zoneID: p4m3ZoneID)
        let bumped   = CKRecord(recordType: "_ck_device_slot", recordID: bumpedID)
        bumped["device_uuid"]     = UUID().uuidString as CKRecordValue
        bumped["epoch"]           = Int64(2) as CKRecordValue
        bumped["last_active_hlc"] = Int64(0) as CKRecordValue
        bumped["claimed_at"]      = SlotRecordMapping.iso8601.string(from: Date()) as CKRecordValue
        await cloud.seed(record: bumped)

        // Stale identity: this device believes it owns slot=5 at epoch=1.
        let staleIdentity = DeviceIdentity(deviceUUID: UUID(), slot: 5, epoch: 1, claimedAt: Date())
        let currentHLC    = HLC(physicalTime: 1_000, logicalCount: 0, nodeID: 5)

        // Count data records before the fence call — must remain zero after.
        let countBefore = await cloud.dataRecordCount(in: p4m3ZoneID)
        #expect(countBefore == 0, "cloud must have zero data records before the fence call")

        // EpochFence.heartbeat: step 3b fires (remote epoch=2, local epoch=1) →
        // throws reenrollRequired. Step 4 (heartbeat CAS save) never executes.
        var caughtError: SyncError? = nil
        do {
            try await EpochFence.heartbeat(
                identity: staleIdentity,
                currentHLC: currentHLC,
                database: cloud,
                zoneID: p4m3ZoneID
            )
            Issue.record("expected .reenrollRequired but EpochFence.heartbeat completed without error")
        } catch let err as SyncError {
            caughtError = err
        } catch {
            Issue.record("expected SyncError, got: \(error)")
        }

        guard case .reenrollRequired(let slot, let staleEpoch, let currentEpoch) = caughtError else {
            Issue.record("expected .reenrollRequired, got \(String(describing: caughtError))")
            return
        }
        #expect(slot         == 5, "fence must identify the correct slot")
        #expect(staleEpoch   == 1, "fence must report the local (stale) epoch")
        #expect(currentEpoch == 2, "fence must report the remote (current) epoch")

        // N2 invariant: zero data records landed before the fence fired.
        let countAfter = await cloud.dataRecordCount(in: p4m3ZoneID)
        #expect(countAfter == 0,
                "A5/N2: zero data records must reach the cloud before reenrollRequired fires")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3b: Re-enrollment remints outbox; reminted HLCs > pre-eviction HLCs
    // ─────────────────────────────────────────────────────────────────────────

    /// After re-enrollment, OutboxStore.remintAll() must:
    ///   (a) change all entry nodeIDs to the new slot's nodeID,
    ///   (b) preserve entry count,
    ///   (c) maintain ascending order,
    ///   (d) produce HLCs strictly greater than every pre-eviction HLC (A2).
    ///
    /// Violation of (d) would allow a receiving estate to apply re-enrolled records
    /// BEFORE the old identity's writes in LWW order, creating stale-wins outcomes
    /// that differ across replicas.
    @Test("(3b) remint: new nodeID on all entries; reminted HLCs strictly > all pre-eviction HLCs (A2)")
    func reEnrollRemintNodeIDAndOrdering() async throws {
        let storage = try await p4m3Storage()
        let now = Date()
        let baseNowMs = Int64(now.timeIntervalSince1970 * 1000)

        // Seed 5 outbox entries under old slot nodeID=5.
        let oldNodeID = Int32(5)
        var gen = HLCGenerator(nodeID: oldNodeID)
        var originalHLCs: [HLC] = []
        for i in 0..<5 {
            let hlc = gen.send(now: baseNowMs + Int64(i))
            originalHLCs.append(hlc)
            let entry = OutboxEntry(
                id:         UUID(),
                tableName:  "items",
                rowKey:     UUID().uuidString,
                event:      .insert,
                valuesData: nil,
                hlcWireBytes: Data(hlc.wireBytes),
                enqueuedAt: ISO8601DateFormatter().string(from: now)
            )
            try await OutboxStore.append(entry: entry, to: storage)
        }
        let originalMaxHLC = originalHLCs.max()!

        // Verify pre-remint: all 5 entries carry nodeID=5.
        let before = try await OutboxStore.readBatch(from: storage)
        #expect(before.count == 5)
        for entry in before {
            let nid = p4m3NodeIDOf(entry.hlcWireBytes)
            #expect(nid == 5, "pre-remint: expected nodeID 5, got \(nid)")
        }

        // Remint under new slot nodeID=9. nowMillis advanced +10 s to guarantee
        // the HLCGenerator seeds above the original entries' physical times (A2).
        let newNodeID    = Int32(9)
        let remintNowMs  = baseNowMs + 10_000
        try await OutboxStore.remintAll(from: storage, newNodeID: newNodeID, nowMillis: remintNowMs)

        let after = try await OutboxStore.readBatch(from: storage)

        // (a) Entry count preserved.
        #expect(after.count == 5, "remintAll must preserve the entry count")

        // (b) All entries now carry nodeID=9.
        for entry in after {
            let nid = p4m3NodeIDOf(entry.hlcWireBytes)
            #expect(nid == Int(newNodeID), "post-remint: expected nodeID \(newNodeID), got \(nid)")
        }

        let remintedHLCs = after.map { (try? HLC(wireBytes: [UInt8]($0.hlcWireBytes))) ?? .zero }

        // (c) Ascending order preserved (chronological integrity for the push drain).
        for i in 0..<(remintedHLCs.count - 1) {
            #expect(remintedHLCs[i] < remintedHLCs[i + 1],
                    "reminted HLCs must be in ascending order")
        }

        // (d) Every reminted HLC is strictly greater than the pre-eviction maximum (A2).
        // This ensures re-enrolled records WIN LWW against any historical writes from
        // the old nodeID — no stale-re-send-beats-new-write confusion.
        for (i, reminted) in remintedHLCs.enumerated() {
            #expect(reminted > originalMaxHLC,
                    "reminted HLC[\(i)] must exceed the pre-eviction maximum (A2 ordering contract)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 3c: Engine integration — auto-reenroll on push, B converges
    // ─────────────────────────────────────────────────────────────────────────

    /// Full two-estate integration test for the reenroll flow:
    ///   1. Estate A writes 3 rows (queued in outbox, not yet pushed).
    ///   2. A's slot is "evicted" in the shared cloud (epoch bumped by a third device).
    ///   3. A's push(): EpochFence fires reenrollRequired → engine auto-reenrolls
    ///      (claims new slot, remints outbox) → push completes without error.
    ///   4. B pulls and receives all 3 rows from A.
    ///   5. All pushed CKRecords carry A's NEW slot nodeID in _syncHLC.
    @Test("(3c) integration: epoch bump → push auto-reenrolls → B converges; pushed records carry new nodeID")
    func reenrollAndConvergeViaEngine() async throws {
        let fixture = try await TwoEstateFixture.make()

        // Capture A's initial slot identity (set during enable()).
        guard let identA = await fixture.engineA.stateActor.currentIdentity else {
            Issue.record("estate A must have a slot identity after enable()")
            return
        }
        let oldSlotA = identA.slot

        // Write 3 rows on A; they land in A's outbox under oldSlotA's nodeID.
        let rowIDs = (0..<3).map { _ in UUID() }
        for rowID in rowIDs {
            try await fixture.writeA(row: [
                "id":    .uuid(rowID),
                "title": .text("pre-eviction"),
                "value": .int(99)
            ])
        }

        // Simulate eviction: bump A's slot epoch in the shared cloud.
        // A's next EpochFence.heartbeat will see a mismatch → reenrollRequired.
        await fixture.bumpSlotEpoch(slot: oldSlotA, to: identA.epoch + 1)

        // A pushes: EpochFence → reenrollRequired → engine reenrolls (new slot,
        // remints outbox) → push proceeds with reminted records. Must not throw.
        _ = try await fixture.engineA.push()

        // B pulls A's 3 reminted records.
        _ = try await fixture.engineB.pull()

        // Convergence: all 3 rows must be visible on B.
        for rowID in rowIDs {
            let onB = try await fixture.queryB(id: rowID)
            #expect(onB != nil, "row \(rowID) must be visible on B after pull (convergence)")
        }

        // Re-enrollment: A must now hold a DIFFERENT slot (old slot was evicted).
        guard let newIdentA = await fixture.engineA.stateActor.currentIdentity else {
            Issue.record("estate A must still have an identity after reenroll")
            return
        }
        #expect(newIdentA.slot != oldSlotA,
                "A must have a new slot after reenroll (old slot was evicted)")
        let newSlotA = newIdentA.slot

        // nodeID correctness: all pushed data records must carry A's new slot nodeID.
        // After reenroll, the engine generates HLCs with newSlotA's nodeID; reminted
        // outbox entries — and therefore pushed CKRecords — carry that nodeID.
        let cloudRecords = await fixture.allCloudDataRecords()
        #expect(!cloudRecords.isEmpty, "cloud must have data records after A's push")
        for record in cloudRecords {
            // CKRecord _syncHLC uses CKRecordMapping.packed() layout (48|12|4),
            // NOT HLC.packed layout (8|16|40). nodeID lives in the low 4 bits.
            let packed    = (record["_syncHLC"] as? NSNumber)?.int64Value ?? 0
            let recordNID = ckRecordNodeIDOf(packed)
            #expect(recordNID == newSlotA,
                    "cloud record \(record.recordID.recordName): expected nodeID \(newSlotA), got \(recordNID)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 4: CAS race — one winner per slot, no shared nodeIDs
    // ─────────────────────────────────────────────────────────────────────────

    /// Three concurrent claimers race for an empty registry. FakeCloudKitDatabase
    /// serializes modifyRecords (actor), so exactly one wins slot 1; the losers
    /// get serverRecordChanged and retry onto different slots. After all three
    /// succeed, no two active devices share a slot number (= nodeID).
    @Test("(4) CAS race: concurrent claimers → distinct slots, no shared nodeIDs")
    func casRaceNoSharedNodeID() async throws {
        let db    = FakeCloudKitDatabase()
        let uuidA = UUID()
        let uuidB = UUID()
        let uuidC = UUID()

        let opA = p4m3ClaimOp(database: db, deviceUUID: uuidA, maxAttempts: 8)
        let opB = p4m3ClaimOp(database: db, deviceUUID: uuidB, maxAttempts: 8)
        let opC = p4m3ClaimOp(database: db, deviceUUID: uuidC, maxAttempts: 8)

        // Concurrent claims. FakeCloudKitDatabase's actor serializes modifyRecords:
        // exactly one write per slot succeeds; others collide and retry.
        async let resultA = opA.claim(preferring: nil)
        async let resultB = opB.claim(preferring: nil)
        async let resultC = opC.claim(preferring: nil)
        let (a, b, c) = try await (resultA, resultB, resultC)

        // All three must succeed with valid slot numbers.
        #expect((1...15).contains(a.slot))
        #expect((1...15).contains(b.slot))
        #expect((1...15).contains(c.slot))

        // Core property: no two active devices share a slot number (= nodeID).
        let slotSet = Set([a.slot, b.slot, c.slot])
        #expect(slotSet.count == 3,
                "concurrent claimers must hold distinct slot numbers (no shared nodeIDs); A=\(a.slot) B=\(b.slot) C=\(c.slot)")

        // Correct UUID assignment.
        #expect(a.deviceUUID == uuidA)
        #expect(b.deviceUUID == uuidB)
        #expect(c.deviceUUID == uuidC)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 5: Ordering soundness after evict+reclaim
    // ─────────────────────────────────────────────────────────────────────────

    /// After re-enrollment, LWW comparisons on the old identity's historical writes
    /// must resolve identically on both estates. Estate A's post-re-enroll write
    /// (T3, clock advanced +20s) must beat B's earlier stale write (T2) on BOTH
    /// estates — identical final state, no divergence.
    ///
    /// Sequence:
    ///   A writes v1 (T1) → both estates sync (baseline).
    ///   B writes stale v2 (T2, not yet pushed).
    ///   A's slot is evicted; A's clock advances +20 s → T3 > T2 guaranteed.
    ///   A writes v3 (T3, post-clock-advance).
    ///   A pushes: auto-reenrolls, remints, pushes v3 under new nodeID.
    ///   B pushes stale v2: CloudZoneFake HLC-aware merge discards it (T2 < T3).
    ///   Both estates pull → sync-meta must be identical.
    @Test("(5) ordering soundness: post-re-enroll write (T3) beats stale B write (T2) on both estates")
    func orderingSoundnessAfterEvictReclaim() async throws {
        let fixture  = try await TwoEstateFixture.make()
        let sharedID = UUID()

        // Baseline: A writes v1, both estates sync.
        try await fixture.writeA(row: [
            "id":    .uuid(sharedID),
            "title": .text("v1-from-A"),
            "value": .int(1)
        ])
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.pull()
        let onB_initial = try await fixture.queryB(id: sharedID)
        #expect(onB_initial != nil, "B must have A's v1 write after initial sync")

        // Capture A's slot before eviction.
        guard let identA = await fixture.engineA.stateActor.currentIdentity else {
            Issue.record("estate A must have an identity before eviction")
            return
        }

        // B writes stale v2 at T2 (before A's clock advance). Not pushed yet.
        try await fixture.writeB(row: [
            "id":    .uuid(sharedID),
            "title": .text("v2-stale-from-B"),
            "value": .int(2)
        ])

        // Evict A's slot; advance A's HLC generator +20 s → T3 = wallClock + 20s > T2.
        await fixture.bumpSlotEpoch(slot: identA.slot, to: identA.epoch + 1)
        await fixture.engineA.stateActor.advanceClock(by: 20_000)

        // A writes v3 at T3 (post-clock-advance, strictly higher HLC than B's v2).
        try await fixture.writeA(row: [
            "id":    .uuid(sharedID),
            "title": .text("v3-final-from-A"),
            "value": .int(3)
        ])

        // A pushes: auto-reenrolls, remints outbox, pushes v3 (T3) under new nodeID.
        _ = try await fixture.engineA.push()

        // B pushes stale v2 (T2): CloudZoneFake HLC-aware merge discards it (T2 < T3).
        _ = try await fixture.engineB.push()

        // Both estates pull to reach final converged state.
        _ = try await fixture.engineA.pull()
        _ = try await fixture.engineB.pull()

        // One more round to settle any in-flight state.
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.push()
        _ = try await fixture.engineA.pull()
        _ = try await fixture.engineB.pull()

        // Ordering soundness: both estates must show A's v3 (highest HLC = T3).
        let onA_final = try await fixture.queryA(id: sharedID)
        let onB_final = try await fixture.queryB(id: sharedID)

        #expect(onA_final?["title"] == .text("v3-final-from-A"),
                "A must show the post-re-enroll write (T3 = highest HLC wins LWW)")
        #expect(onB_final?["title"] == .text("v3-final-from-A"),
                "B must also show A's post-re-enroll write (LWW resolves identically on both estates)")

        // Definitive convergence proof: sync-meta tables must be identical.
        try await fixture.assertSyncMetaMatch(table: "items")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Scenario 6: Ghost fast-path vs heartbeated and recent slots
    // ─────────────────────────────────────────────────────────────────────────

    /// Ghost fast-path eviction (adjudication A4):
    ///   - old ghost (HLC.zero, claimedAt > SlotGhostWindow ago)      → evictable via fast-path
    ///   - recent ghost (HLC.zero, claimedAt < SlotGhostWindow ago)   → NOT evictable
    ///   - heartbeated-active (non-zero HLC within 30-day window)      → NOT evictable
    ///   - heartbeated-stale (non-zero HLC beyond 30-day window)       → evictable via slow-path
    ///
    /// The ghost fast-path fires FIRST so old ghost slots are freed quickly
    /// (in ~1 hour) rather than waiting 30 days for the long-inactivity path.
    @Test("(6) ghost fast-path: old ghost → evictable; recent ghost + heartbeated-active → not; stale heartbeat → evictable")
    func ghostFastPathEviction() {
        let now   = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // Slot 1: old ghost — HLC.zero, claimedAt past the 1-hour ghost window → EVICTABLE.
        let ghostOld = p4m3Slot(
            slotNumber: 1,
            lastActiveHLC: HLC.zero,
            claimedAt: Date().addingTimeInterval(-(SlotGhostWindow + 120))  // 1 hr + 2 min ago
        )

        // Slot 2: recent ghost — HLC.zero, claimedAt right now → NOT evictable (within window).
        let ghostRecent = p4m3Slot(
            slotNumber: 2,
            lastActiveHLC: HLC.zero,
            claimedAt: now
        )

        // Slot 3: heartbeated-active — non-zero lastActiveHLC 1 day ago (within 30-day window).
        let oneDayMs = Int64(24 * 60 * 60 * 1000)
        let heartbeatedActive = p4m3Slot(
            slotNumber: 3,
            lastActiveHLC: HLC(physicalTime: nowMs - oneDayMs, logicalCount: 0, nodeID: 3),
            claimedAt: Date().addingTimeInterval(-30 * 24 * 60 * 60)
        )

        // evictionCandidate on a 3-slot table: only the old ghost qualifies.
        let tableThree    = SlotTable(slots: [ghostOld, ghostRecent, heartbeatedActive])
        let candidate     = tableThree.evictionCandidate(now: now)
        #expect(candidate?.slot == 1,
                "only the old ghost (slot 1) qualifies; recent ghost and heartbeated-active are not eligible")

        // Full registry (15 slots): claimSlot returns the old ghost as the candidate.
        var allSlots = [ghostOld, ghostRecent, heartbeatedActive]
        for n in 4...15 {
            allSlots.append(p4m3Slot(slotNumber: n, lastActiveHLC: HLC.zero, claimedAt: now))
        }
        let fullTable = SlotTable(slots: allSlots)
        let decision  = fullTable.claimSlot(for: UUID(), preferring: nil, now: { now })
        guard case .evictionCandidate(let evictee) = decision else {
            Issue.record("expected evictionCandidate in full registry, got \(decision)")
            return
        }
        #expect(evictee.slot == 1,
                "ghost fast-path in full registry must select the old ghost (slot 1)")

        // No candidate when only heartbeated-active + recent ghost.
        let tableNoCandidate = SlotTable(slots: [heartbeatedActive, ghostRecent])
        let noCandidate      = tableNoCandidate.evictionCandidate(now: now)
        #expect(noCandidate == nil,
                "heartbeated-active + recent ghost → no eviction candidate")

        // Heartbeated-stale: beyond 30-day long-inactivity window → evictable (slow path).
        let thirtyFiveDaysMs = Int64(35 * 24 * 60 * 60 * 1000)
        let heartbeatedStale = p4m3Slot(
            slotNumber: 7,
            lastActiveHLC: HLC(physicalTime: nowMs - thirtyFiveDaysMs, logicalCount: 0, nodeID: 7),
            claimedAt: Date().addingTimeInterval(-35 * 24 * 60 * 60)
        )
        let tableStale    = SlotTable(slots: [heartbeatedStale, ghostRecent])
        let staleCandidate = tableStale.evictionCandidate(now: now)
        #expect(staleCandidate?.slot == 7,
                "heartbeated slot beyond 30-day window qualifies via long-inactivity slow path")
    }
}
