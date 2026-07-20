// FederationTombstoneGCTests.swift
//
// Tests for the Federation-backend tombstone GC scheduling seam (CVK-WB7).
//
// These tests exercise FederationStateActor.gcIfDue(storage:nowMs:) directly
// with a fake clock so the "due / not due" decision is fully deterministic.
//
// COVERED CASES:
//   1. gcRunsWhenDue: when no prior GC has run (lastGCMs = 0) and nowMs
//      >= gcIntervalMs, gcIfDue compacts eligible _fed_sync_meta tombstones.
//   2. gcSkippedWhenNotDue: after a GC run, a second call within the 24h
//      window is a no-op — tombstones inserted after the first run survive.
//   3. tombstonesInsideRetentionWindowSurvive: GC runs but entries whose
//      physical time is within SyncTombstone.gcRetentionSeconds are kept.
//
// INVARIANT verified in test 3: the retention window (30 d) must exceed the
// slot-eviction long window (P1-M3 constant, not yet shipped). An entry
// within the cutoff survives the GC sweep regardless of when the sweep fires.
//
// Setup: InMemoryStorage + FederationStateActor.ensureFedSyncMetaTable.
// FederationStateActor.gcIfDue(storage:nowMs:) is called directly — no
// pairing, peers, or network stack needed.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

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
    // Ensure _fed_sync_meta exists (GC reads/writes the GC sentinel there).
    try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
    return storage
}

/// Insert a tombstone entry (is_deleted=1) into _fed_sync_meta.
///
/// Gap 6 (D38.1): writes the full-width `sync_hlc_wire` BLOB (HLC.wireBytes)
/// — the column `TombstoneGC.compact` now reads. No bit-packing, no 40-bit
/// masking; see that function's gap-6 doc comment.
private func insertFedTombstone(
    storage: any Storage,
    table: String,
    key: String,
    physicalMs: Int64
) async throws {
    let hlc = HLC(physicalTime: physicalMs, logicalCount: 0, nodeID: 1)
    _ = try await storage.rowStore.upsert(
        table: "_fed_sync_meta",
        values: [
            "table_name":     .text(table),
            "primary_key":    .text(key),
            "sync_hlc_wire":  .blob(Data(hlc.wireBytes)),
            "schema_version": .int(1),
            "kit_id":         .text("TestKit"),
            "is_deleted":     .int(1),
        ],
        conflictColumns: ["table_name", "primary_key"]
    )
}

/// Count tombstone rows in _fed_sync_meta (is_deleted=1 AND table_name != sentinel).
private func tombstoneCount(storage: any Storage) async throws -> Int {
    // Exclude the GC sentinel row (_gc_state) which also lives in _fed_sync_meta.
    let rows = try await storage.rowStore.query(
        table: "_fed_sync_meta",
        where: .eq(Column(table: "_fed_sync_meta", name: "is_deleted"), .int(1))
    )
    // Filter out sentinel rows (underscore-prefixed table names).
    return rows.filter { row in
        guard case .text(let tname) = row["table_name"] else { return false }
        return !tname.hasPrefix("_")
    }.count
}

// MARK: - Test suite

@Suite("TombstoneGC scheduler — Federation (CVK-WB7)")
struct FederationTombstoneGCTests {

    // MARK: - Test 1: GC runs when due

    @Test("gcIfDue compacts eligible fed tombstones when no prior GC has run")
    func gcRunsWhenDue() async throws {
        let storage = try await makeStorage()
        let actor   = FederationStateActor()

        let nowMs       = TombstoneGCSchedule.gcIntervalMs
        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        // Gap 6 (D38.1): TombstoneGC.compact's cutoff (nowMs - retentionMs) is
        // no longer 40-bit-masked, so with this test's deliberately-tiny
        // synthetic `nowMs` the cutoff is genuinely negative — do NOT clamp
        // to 0 (see CloudKit TombstoneGCSchedulerTests.swift's identical fix).
        let oldMs       = nowMs - retentionMs - 1_000

        try await insertFedTombstone(storage: storage, table: "items",
                                     key: UUID().uuidString, physicalMs: oldMs)

        let beforeCount = try await tombstoneCount(storage: storage)
        #expect(beforeCount == 1, "setup: one tombstone must be present before GC")

        try await actor.gcIfDue(storage: storage, nowMs: nowMs)

        let afterCount = try await tombstoneCount(storage: storage)
        #expect(afterCount == 0, "old tombstone must be deleted after GC runs")
    }

    // MARK: - Test 2: GC skipped when interval not yet elapsed

    @Test("gcIfDue is a no-op for Federation when the 24h interval has not elapsed")
    func gcSkippedWhenNotDue() async throws {
        let storage = try await makeStorage()
        let actor   = FederationStateActor()

        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        let firstNowMs  = TombstoneGCSchedule.gcIntervalMs

        // First call: runs GC (writes sentinel, nothing to compact yet).
        try await actor.gcIfDue(storage: storage, nowMs: firstNowMs)

        // Insert old tombstone after first GC.
        let oldMs = max(0, firstNowMs - retentionMs - 1_000)
        try await insertFedTombstone(storage: storage, table: "items",
                                     key: UUID().uuidString, physicalMs: oldMs)

        let countBefore = try await tombstoneCount(storage: storage)
        #expect(countBefore == 1, "tombstone must be present before second GC check")

        // Second call: 1 s later — interval not elapsed.
        try await actor.gcIfDue(storage: storage, nowMs: firstNowMs + 1_000)

        let countAfter = try await tombstoneCount(storage: storage)
        #expect(countAfter == 1,
                "tombstone must survive: 24h GC interval has not elapsed since last run")
    }

    // MARK: - Test 3: Tombstones inside retention window survive

    @Test("gcIfDue keeps Federation entries within the retention window")
    func tombstonesInsideRetentionWindowSurvive() async throws {
        let storage = try await makeStorage()
        let actor   = FederationStateActor()

        let retentionMs = SyncTombstone.gcRetentionSeconds * 1_000
        let nowMs       = TombstoneGCSchedule.gcIntervalMs + retentionMs + 10_000

        // Gap 6 (D38.1): cutoff = nowMs - retentionMs, NO masking
        // (TombstoneGC.compact no longer bit-masks — sync_hlc_wire is full-width).
        let cutoffMs    = nowMs - retentionMs
        let oldMs       = max(0, cutoffMs - 1_000)
        let oldKey      = UUID().uuidString
        try await insertFedTombstone(storage: storage, table: "items",
                                     key: oldKey, physicalMs: oldMs)

        let freshMs  = cutoffMs + 1_000
        let freshKey = UUID().uuidString
        try await insertFedTombstone(storage: storage, table: "items",
                                     key: freshKey, physicalMs: freshMs)

        try await actor.gcIfDue(storage: storage, nowMs: nowMs)

        let oldRows = try await storage.rowStore.query(
            table: "_fed_sync_meta",
            where: .and([
                .eq(Column(table: "_fed_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_fed_sync_meta", name: "primary_key"), .text(oldKey))
            ])
        )
        #expect(oldRows.isEmpty, "entry older than retention window must be deleted")

        let freshRows = try await storage.rowStore.query(
            table: "_fed_sync_meta",
            where: .and([
                .eq(Column(table: "_fed_sync_meta", name: "table_name"), .text("items")),
                .eq(Column(table: "_fed_sync_meta", name: "primary_key"), .text(freshKey))
            ])
        )
        #expect(!freshRows.isEmpty,
                "entry inside retention window must survive GC")
    }
}
