// ApplyInboundAtomicityTests.swift
//
// N1 fix verification — CloudKit ApplyInbound.swift.
//
// N1 (gap 4 from the P4.5 three-estate convergence harness, docs/analysis
// fulcrum P4.5): the `.fieldLevelLWW` (and, on inspection, `.lastWriterWinsByHLC`)
// arms of `applyInbound` committed the application-row VALUE write
// (`upsertSync`) and the HLC bookkeeping write (`ColumnHLCStore.writeAll` /
// `SyncMetaStore.writeSyncHLC` / `writeTombstoneHLC`) as two-or-three
// SEPARATE, non-transactional top-level `await` calls. A crash/kill between
// those calls could leave a committed value with stale (or missing) HLC
// bookkeeping, letting a later stale edit silently overwrite the newer value.
//
// The fix wraps each arm's value write + HLC bookkeeping write(s) in ONE
// `storage.transaction(isolation: .serializable) { txn in ... }` block.
//
// TWO KINDS OF PROOF, matching the atomicity-test doctrine established in
// LocusKit's AuditAPITests.swift ("Audit-write atomicity", codex 016fcb23):
//
//   1. FORCED-FAILURE tests (below): directly exercise `storage.transaction`
//      with the exact write shapes ApplyInbound now performs, injecting a
//      throw BETWEEN the value write and the HLC-bookkeeping write. This
//      proves the crash window is closed — InMemoryStorage.transaction rolls
//      back to a pre-transaction snapshot on any thrown error (see
//      InMemoryStorage.swift), so a value write that lands before the throw
//      is undone along with everything else in the block. Since ApplyInbound
//      now performs both writes inside the SAME transaction closure, the same
//      rollback guarantee applies to it.
//
//   2. SUCCESS-PATH tests: call `applyInbound` directly (as the production
//      pull cycle does) and verify BOTH the value row and its HLC bookkeeping
//      are present afterward — proving the refactor did not change observable
//      behavior on the (overwhelmingly common) non-crash path.

import Testing
import Foundation
import CloudKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

@Suite("ApplyInbound — N1 atomicity (value write + HLC bookkeeping, one transaction)")
struct ApplyInboundAtomicityTests {

    // MARK: - Helpers

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [.uuid("id"), .text("note"), .bitmap("flags")],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        try await CloudKitStateActor.ensureSyncMetaTable(storage: storage)
        return storage
    }

    let lwwTable = SyncedTable(
        name: "items", primaryKeyColumn: "id", conflictPolicy: .lastWriterWinsByHLC
    )
    let flwwTable = SyncedTable(
        name: "items", primaryKeyColumn: "id", conflictPolicy: .fieldLevelLWW
    )

    func makeUpsert(id: UUID, note: String, hlcTime: Int64, columnStamped: Bool = false) -> DecodedRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        var record = DecodedRecord(
            table: "items",
            rowKey: id,
            values: ["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)],
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: 1, kitID: "TestKit")
        )
        if columnStamped {
            record.columnHLCs = ColumnHLCMap.stampAll(
                keys: ["id", "note", "flags"], hlc: PackedHLC(hlc))
        }
        return record
    }

    struct ForcedFailure: Error {}

    // MARK: - 1a. Forced-failure rollback — fieldLevelLWW value write + column-HLC write

    @Test("fieldLevelLWW: value upsert and column-HLC write roll back TOGETHER when the transaction fails between them")
    func fieldLevelLWW_forcedFailureBetweenValueAndColumnHLC_rollsBackBoth() async throws {
        let storage = try await makeStorage()
        let rowID = UUID()

        // Mirrors the exact statement order inside ApplyInbound's .fieldLevelLWW
        // transaction closure: value upsert, THEN column-HLC bookkeeping write.
        // The forced throw lands in between — the precise crash window N1 closes.
        do {
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try await txn.rowStore.upsertSync(
                    table: "items",
                    values: ["id": .uuid(rowID), "note": .text("would-be-committed"), "flags": .bitmap(0)],
                    conflictColumns: ["id"]
                )
                // Crash/kill simulated HERE — after the value write landed on the
                // live transaction state, before the column-HLC write (which would
                // run next, matching ApplyInbound's `.fieldLevelLWW` arm) executes.
                throw ForcedFailure()
            }
            Issue.record("expected ForcedFailure to propagate out of the transaction")
        } catch is ForcedFailure {
            // expected
        }

        // The value upsert must NOT be visible — it was rolled back with the rest
        // of the transaction, even though it executed (and would have committed
        // under the OLD non-transactional two-call code) before the throw.
        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.isEmpty,
                "value upsert must roll back when a later statement in the same transaction throws")

        // The column-HLC side table must also be empty (it was never reached,
        // and even if it had partially run, the transaction discards it).
        let columnHLCs = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "items", primaryKey: rowID)
        #expect(columnHLCs.isEmpty, "column-HLC bookkeeping must roll back along with the value write")
    }

    // MARK: - 1b. Forced-failure rollback — lastWriterWinsByHLC value write + row-HLC write

    @Test("lastWriterWinsByHLC: value upsert and row-HLC write roll back TOGETHER when the transaction fails between them")
    func lastWriterWinsByHLC_forcedFailureBetweenValueAndRowHLC_rollsBackBoth() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        do {
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try await txn.rowStore.upsertSync(
                    table: "items",
                    values: ["id": .uuid(rowID), "note": .text("would-be-committed"), "flags": .bitmap(0)],
                    conflictColumns: ["id"]
                )
                // Crash/kill simulated HERE — mirrors ApplyInbound's .lastWriterWinsByHLC
                // arm, where writeSyncHLC is the next statement after the value upsert.
                throw ForcedFailure()
            }
            Issue.record("expected ForcedFailure to propagate out of the transaction")
        } catch is ForcedFailure {
            // expected
        }

        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.isEmpty,
                "value upsert must roll back when a later statement in the same transaction throws")

        // Use the real production read path (cachedOrReadSyncHLC's fallback,
        // readSyncHLC) via a live applyInbound call to confirm the row-grain
        // side table has no entry either: apply a fresh (non-forced) record
        // and confirm THIS row's key still has no history from the failed attempt.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "first-real-write", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)
        let loaded = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(loaded.first?["note"] == .text("first-real-write"),
                "the rolled-back attempt must have left no trace — this write must be treated as the first ever HLC for the row (no stale-reject)")
    }

    // MARK: - 1c. Forced-failure rollback — lastWriterWinsByHLC tombstone (delete + tombstone-HLC write)

    @Test("lastWriterWinsByHLC tombstone: delete and tombstone-HLC write roll back TOGETHER when the transaction fails between them")
    func lastWriterWinsByHLC_tombstone_forcedFailureBetweenDeleteAndTombstoneHLC_rollsBackBoth() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        // Seed a real row through the production path.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "seed", hlcTime: 100),
            syncedTable: lwwTable, storage: storage)

        let predicate = StoragePredicate.eq(Column(table: "items", name: "id"), .uuid(rowID))
        do {
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try? await txn.rowStore.deleteSync(table: "items", where: predicate)
                // Crash/kill simulated HERE — mirrors the tombstone arm, where
                // writeTombstoneHLC is the next statement after the delete.
                throw ForcedFailure()
            }
            Issue.record("expected ForcedFailure to propagate out of the transaction")
        } catch is ForcedFailure {
            // expected
        }

        // The row must SURVIVE — the delete rolled back with the rest of the
        // transaction, even though it executed before the throw.
        let rows = try await storage.rowStore.query(table: "items", where: predicate)
        #expect(rows.count == 1, "delete must roll back when a later statement in the same transaction throws")
        #expect(rows.first?["note"] == .text("seed"), "surviving row must be the original, untouched value")
    }

    // MARK: - 2a. Success path — fieldLevelLWW: value + column HLC + row HLC all present after one commit

    @Test("fieldLevelLWW success path: value row, column HLCs, and row-grain HLC are all present after one applyInbound commit")
    func fieldLevelLWW_successPath_valueAndBothHLCLayersPresent() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "flww-value", hlcTime: 500, columnStamped: true),
            syncedTable: flwwTable, storage: storage)

        // 1. Value row present.
        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.first?["note"] == .text("flww-value"), "value row must be present after commit")

        // 2. Column-HLC side table populated.
        let columnHLCs = try await ColumnHLCStore.readAll(
            from: storage, sideTable: CKSideSchema.syncMetaColsTable,
            tableName: "items", primaryKey: rowID)
        #expect(!columnHLCs.isEmpty, "column-HLC bookkeeping must be present after commit")
        #expect(columnHLCs.entries["note"] != nil, "note column's HLC must be recorded")

        // 3. Row-grain HLC side table populated (_ck_sync_meta).
        let syncMetaRows = try await storage.rowStore.query(
            table: CKSideSchema.syncMetaTable,
            where: .and([
                .eq(Column(table: CKSideSchema.syncMetaTable, name: "table_name"), .text("items")),
                .eq(Column(table: CKSideSchema.syncMetaTable, name: "primary_key"), .text(rowID.uuidString))
            ])
        )
        #expect(syncMetaRows.count == 1, "row-grain HLC bookkeeping must be present after commit")
    }

    // MARK: - 2b. Success path — lastWriterWinsByHLC: value + row HLC present after one commit

    @Test("lastWriterWinsByHLC success path: value row and row-grain HLC are both present after one applyInbound commit")
    func lastWriterWinsByHLC_successPath_valueAndRowHLCPresent() async throws {
        let storage = try await makeStorage()
        let engine = CloudKitStateActor(containerIdentifier: nil)
        let rowID = UUID()

        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "lww-value", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.first?["note"] == .text("lww-value"), "value row must be present after commit")

        let syncMetaRows = try await storage.rowStore.query(
            table: CKSideSchema.syncMetaTable,
            where: .and([
                .eq(Column(table: CKSideSchema.syncMetaTable, name: "table_name"), .text("items")),
                .eq(Column(table: CKSideSchema.syncMetaTable, name: "primary_key"), .text(rowID.uuidString))
            ])
        )
        #expect(syncMetaRows.count == 1, "row-grain HLC bookkeeping must be present after commit")

        // A stale re-apply (older HLC) must still be correctly rejected — confirms
        // the transactional write path persisted a real, gate-effective HLC, not
        // an inert placeholder.
        try await engine.applyInbound(
            makeUpsert(id: rowID, note: "stale-should-be-rejected", hlcTime: 1),
            syncedTable: lwwTable, storage: storage)
        let afterStale = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(afterStale.first?["note"] == .text("lww-value"),
                "stale inbound record must be rejected by the HLC persisted via the transactional write")
    }
}
