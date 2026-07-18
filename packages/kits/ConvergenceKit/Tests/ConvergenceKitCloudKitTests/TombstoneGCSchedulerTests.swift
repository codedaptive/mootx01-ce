// TombstoneGCSchedulerTests.swift
//
// Tests for the CloudKit-backend tombstone GC scheduling seam (CVK-WB7).
//
// These tests exercise CloudKitStateActor.gcIfDue(storage:nowMs:) directly
// with a fake clock so the "due / not due" decision is fully deterministic
// without real-time delays.
//
// COVERED CASES:
//   1. gcRunsWhenDue: when no prior GC has run (lastGCMs = 0) and nowMs
//      >= gcIntervalMs, gcIfDue compacts eligible tombstones.
//   2. gcSkippedWhenNotDue: after a GC run, a second call within the 24h
//      window is a no-op — tombstones inserted after the first run survive.
//   3. tombstonesInsideRetentionWindowSurvive: GC runs but entries whose
//      physical time is within SyncTombstone.gcRetentionSeconds are kept.
//
// INVARIANT verified in test 3: the retention window (30 d) must exceed the
// slot-eviction long window (P1-M3 constant, not yet shipped). An entry whose
// physical time is close to the cutoff survives because the 40-bit mask
// comparison in TombstoneGC.compact respects the full retention window.
//
// Setup: InMemoryStorage + CKSideSchema.ensure (creates _ck_sync_meta and
// _ck_change_token). CloudKitStateActor is created without an active CloudKit
// container; gcIfDue(storage:nowMs:) is called directly so no enable() or
// CloudKit credentials are needed.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Helpers

private func makeStorage() async throws -> any Storage {
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
                columns: [.uuid("id"), .text("note")],
                primaryKey: ["id"]
            )
        ],
        indices: [],
        migrations: []
    ))
    // CKSideSchema.ensure creates _ck_sync_meta and _ck_change_token (plus
    // other side tables). Both are needed for gcIfDue.
    try await CKSideSchema.ensure(storage: storage)
    return storage
}

/// Pack a physical-time-only HLC: node=1, logicalCount=0, physicalTime=ms.
/// Mirrors the HLC layout in TombstoneGC.compact so the GC correctly
/// identifies the test entry's age.
private func makePackedHLC(physicalMs: Int64) -> Int64 {
    let node: Int64    = 1  // 8 bits in the high byte
    let logical: Int64 = 0  // 16 bits above the physical field
    return (node << 56) | (logical << 40) | (physicalMs & 0xFF_FFFF_FFFF)
}

/// Insert a tombstone entry (_ck_sync_meta, is_deleted=1) for a given
/// table/key with the specified physical time as the HLC.
private func insertTombstone(
    storage: any Storage,
    table: String,
    key: String,
    physicalMs: Int64
) async throws {
    _ = try await storage.rowStore.upsert(
        table: "_ck_sync_meta",
        values: [
            "table_name":     .text(table),
            "primary_key":    .text(key),
            "sync_hlc":       .int(makePackedHLC(physicalMs: physicalMs)),
            "schema_version": .int(1),
            "kit_id":         .text("TestKit"),
            "is_deleted":     .int(1),
        ],
        conflictColumns: ["table_name", "primary_key"]
    )
}

/// Count tombstone rows in _ck_sync_meta.
private func tombstoneCount(storage: any Storage) async throws -> Int {
    let rows = try await storage.rowStore.query(
        table: "_ck_sync_meta",
        where: .eq(Column(table: "_ck_sync_meta", name: "is_deleted"), .int(1))
    )
    return rows.count
}

// MARK: - Test suite

@Suite("TombstoneGC scheduler — CloudKit (CVK-WB7)")
struct TombstoneGCSchedulerTests {

    // MARK: - Test 1: GC runs when due

    @Test("gcIfDue compacts eligible tombstones when no prior GC has run")
    func gcRunsWhenDue() async throws {
        let storage = try await makeStorage()
        let actor   = CloudKitStateActor(containerIdentifier: nil)

        // Use nowMs = gcIntervalMs so (nowMs - 0) == gcIntervalMs → GC is due.
        // Physical time for the tombstone must be old enough to pass the
        // retention cutoff at this nowMs.
        let nowMs      = TombstoneGCSchedule.gcIntervalMs
        // Retention ms in the same 40-bit space:
        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        // Make the entry old: physical time well below the cutoff.
        let oldMs      = max(0, nowMs - retentionMs - 1_000)  // 1 s before cutoff

        try await insertTombstone(storage: storage, table: "items",
                                  key: UUID().uuidString, physicalMs: oldMs)

        let beforeCount = try await tombstoneCount(storage: storage)
        #expect(beforeCount == 1, "setup: one tombstone must be present before GC")

        try await actor.gcIfDue(storage: storage, nowMs: nowMs)

        let afterCount = try await tombstoneCount(storage: storage)
        #expect(afterCount == 0, "old tombstone must be deleted after GC runs")
    }

    // MARK: - Test 2: GC skipped when interval not yet elapsed

    @Test("gcIfDue is a no-op when the 24h interval has not elapsed")
    func gcSkippedWhenNotDue() async throws {
        let storage = try await makeStorage()
        let actor   = CloudKitStateActor(containerIdentifier: nil)

        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        let firstNowMs  = TombstoneGCSchedule.gcIntervalMs

        // First call: runs GC, persists firstNowMs as last-GC time.
        // (No tombstones yet, so nothing to compact — but the sentinel is written.)
        try await actor.gcIfDue(storage: storage, nowMs: firstNowMs)

        // Insert an old tombstone AFTER the first GC run.
        let oldMs = max(0, firstNowMs - retentionMs - 1_000)
        try await insertTombstone(storage: storage, table: "items",
                                  key: UUID().uuidString, physicalMs: oldMs)

        let countBefore = try await tombstoneCount(storage: storage)
        #expect(countBefore == 1, "tombstone must be present before second GC check")

        // Second call: only 1 second later — interval not elapsed.
        let secondNowMs = firstNowMs + 1_000
        try await actor.gcIfDue(storage: storage, nowMs: secondNowMs)

        let countAfter = try await tombstoneCount(storage: storage)
        #expect(countAfter == 1,
                "tombstone must survive: GC interval (24h) has not elapsed since last run")
    }

    // MARK: - Test 3: Tombstones inside retention window survive

    @Test("gcIfDue deletes old tombstones but keeps entries within the retention window")
    func tombstonesInsideRetentionWindowSurvive() async throws {
        let storage = try await makeStorage()
        let actor   = CloudKitStateActor(containerIdentifier: nil)

        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        // nowMs must be large enough that (nowMs - 0) >= gcIntervalMs AND the
        // cutoff = (nowMs - retentionMs) & mask is positive so old entries qualify.
        // Use nowMs = gcIntervalMs + retentionMs + 10_000 for clear separation.
        let nowMs   = TombstoneGCSchedule.gcIntervalMs + retentionMs + 10_000

        // OLD entry: physical time 1 s before the retention cutoff → gets deleted.
        // cutoff = (nowMs - retentionMs) & 0xFF_FFFF_FFFF = gcIntervalMs + 10_000
        let cutoffMs    = (nowMs - retentionMs) & 0xFF_FFFF_FFFF
        let oldMs       = max(0, cutoffMs - 1_000)
        let oldKey      = UUID().uuidString
        try await insertTombstone(storage: storage, table: "items",
                                  key: oldKey, physicalMs: oldMs)

        // FRESH entry: physical time 1 s after the cutoff → must survive.
        let freshMs  = cutoffMs + 1_000
        let freshKey = UUID().uuidString
        try await insertTombstone(storage: storage, table: "items",
                                  key: freshKey, physicalMs: freshMs)

        try await actor.gcIfDue(storage: storage, nowMs: nowMs)

        // Old entry is gone.
        let oldRows = try await storage.rowStore.query(
            table: "_ck_sync_meta",
            where: .and([
                .eq(Column(table: "_ck_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_ck_sync_meta", name: "primary_key"), .text(oldKey))
            ])
        )
        #expect(oldRows.isEmpty, "entry older than retention window must be deleted")

        // Fresh entry survives.
        let freshRows = try await storage.rowStore.query(
            table: "_ck_sync_meta",
            where: .and([
                .eq(Column(table: "_ck_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_ck_sync_meta", name: "primary_key"), .text(freshKey))
            ])
        )
        #expect(!freshRows.isEmpty,
                "entry inside retention window must survive GC")
    }
}

// MARK: - Retention/eviction invariant (Adams Wave B W3)

@Suite("TombstoneGC retention invariant")
struct TombstoneGCRetentionInvariantTests {
    /// The safety relationship itself, asserted as a test so a future
    /// constant change cannot silently break it: tombstone retention must
    /// STRICTLY exceed the slot-eviction long window, or a device evicted
    /// at the boundary could return, re-enroll, and miss deletes GC'd at
    /// the same boundary (stale-resurrect hazard).
    @Test("gcRetentionSeconds strictly exceeds SlotLongInactivityWindow")
    func retentionStrictlyExceedsEvictionWindow() {
        #expect(SyncTombstone.gcRetentionSeconds > Int64(SlotLongInactivityWindow),
                "tombstone retention must be strictly greater than the slot-eviction long window")
    }
}
