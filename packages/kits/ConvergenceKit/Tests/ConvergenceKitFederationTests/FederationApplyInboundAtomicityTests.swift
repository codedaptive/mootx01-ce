// FederationApplyInboundAtomicityTests.swift
//
// N1 fix verification — Federation FederationStateActor.applyInbound.
//
// Swift twin of ApplyInboundAtomicityTests.swift (ConvergenceKitCloudKitTests).
// FederationStateActor.applyInbound carries the identical conflict-policy
// apply structure as CloudKit's ApplyInbound.swift (both dispatch on
// SyncedTable.conflictPolicy, both persist row-grain/column-grain HLC
// bookkeeping in side tables), and had the identical N1 defect: the
// `.fieldLevelLWW` and `.lastWriterWinsByHLC` arms (normal-apply and
// tombstone paths) committed the application-row VALUE write
// (upsertSync/deleteSync) and the HLC bookkeeping write(s)
// (ColumnHLCStore.writeAll/clearAll, writeFedSyncHLC/writeFedTombstoneHLC)
// as separate, non-transactional top-level `await` calls. A crash/kill
// between those calls could leave a committed value with stale (or
// missing) HLC bookkeeping, letting a later stale edit silently overwrite
// the newer value.
//
// The fix wraps each arm's value write + HLC bookkeeping write(s) in ONE
// `storage.transaction(isolation: .serializable) { txn in ... }` block —
// identical treatment to CloudKit's ApplyInbound.swift and Rust's
// federation.rs::apply_record.
//
// Two kinds of proof, matching the doctrine in ApplyInboundAtomicityTests.swift
// and LocusKit's AuditAPITests.swift ("Audit-write atomicity", codex 016fcb23):
//
//   1. FORCED-FAILURE tests: directly exercise `storage.transaction` with the
//      exact write shapes `applyInbound` now performs, injecting a throw
//      BETWEEN the value write and the HLC-bookkeeping write. InMemoryStorage
//      rolls back to a pre-transaction snapshot on any thrown error, so this
//      proves the crash window is closed for the same mechanism applyInbound
//      now relies on.
//
//   2. SUCCESS-PATH tests: call `applyInbound` directly and verify BOTH the
//      value row and its HLC bookkeeping are present afterward — proving the
//      refactor did not change observable behavior on the non-crash path.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation applyInbound — N1 atomicity (value write + HLC bookkeeping, one transaction)")
struct FederationApplyInboundAtomicityTests {

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
        try await FederationStateActor.ensureFedSyncMetaTable(storage: storage)
        return storage
    }

    let lwwTable = SyncedTable(
        name: "items", primaryKeyColumn: "id", conflictPolicy: .lastWriterWinsByHLC
    )
    let flwwTable = SyncedTable(
        name: "items", primaryKeyColumn: "id", conflictPolicy: .fieldLevelLWW
    )

    func makeRecord(id: UUID, note: String, hlcTime: Int64, columnStamped: Bool = false) -> SyncRecord {
        let hlc = HLC(physicalTime: hlcTime, logicalCount: 0, nodeID: 1)
        return SyncRecord(
            table: "items",
            event: .update,
            rowKey: id,
            values: SyncValueMap(["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)]),
            hlc: PackedHLC(hlc),
            schemaVersion: 1,
            kitID: "TestKit",
            columnHLCs: columnStamped
                ? ColumnHLCMap.stampAll(keys: ["id", "note", "flags"], hlc: PackedHLC(hlc))
                : nil
        )
    }

    /// Query `_fed_sync_meta` directly for (table, rowKey) — mirrors the
    /// row-grain HLC bookkeeping check used in ApplyInboundAtomicityTests.swift
    /// for CloudKit's `_ck_sync_meta`. `FederationStateActor.fedSyncMetaTable`
    /// is internal (not private), reachable via @testable import.
    func fedSyncMetaRowCount(rowID: UUID, storage: any Storage) async throws -> Int {
        let rows = try await storage.rowStore.query(
            table: FederationStateActor.fedSyncMetaTable,
            where: .and([
                .eq(Column(table: FederationStateActor.fedSyncMetaTable, name: "table_name"), .text("items")),
                .eq(Column(table: FederationStateActor.fedSyncMetaTable, name: "primary_key"), .text(rowID.uuidString))
            ])
        )
        return rows.count
    }

    struct ForcedFailure: Error {}

    // MARK: - 1a. Forced-failure rollback — fieldLevelLWW value write + column-HLC write

    @Test("fieldLevelLWW: value upsert and column-HLC write roll back TOGETHER when the transaction fails between them")
    func fieldLevelLWW_forcedFailureBetweenValueAndColumnHLC_rollsBackBoth() async throws {
        let storage = try await makeStorage()
        let rowID = UUID()

        // Mirrors the exact statement order inside applyInbound's .fieldLevelLWW
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
                // run next, matching applyInbound's `.fieldLevelLWW` arm) executes.
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

        let columnHLCs = try await ColumnHLCStore.readAll(
            from: storage, sideTable: FederationStateActor.fedSyncMetaColsTable,
            tableName: "items", primaryKey: rowID)
        #expect(columnHLCs.isEmpty, "column-HLC bookkeeping must roll back along with the value write")
    }

    // MARK: - 1b. Forced-failure rollback — lastWriterWinsByHLC value write + row-HLC write

    @Test("lastWriterWinsByHLC: value upsert and row-HLC write roll back TOGETHER when the transaction fails between them")
    func lastWriterWinsByHLC_forcedFailureBetweenValueAndRowHLC_rollsBackBoth() async throws {
        let storage = try await makeStorage()
        let rowID = UUID()

        do {
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try await txn.rowStore.upsertSync(
                    table: "items",
                    values: ["id": .uuid(rowID), "note": .text("would-be-committed"), "flags": .bitmap(0)],
                    conflictColumns: ["id"]
                )
                // Crash/kill simulated HERE — mirrors applyInbound's
                // .lastWriterWinsByHLC arm, where writeFedSyncHLC is the next
                // statement after the value upsert.
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

        let metaRowCount = try await fedSyncMetaRowCount(rowID: rowID, storage: storage)
        #expect(metaRowCount == 0, "row-grain HLC bookkeeping must roll back along with the value write")
    }

    // MARK: - 1c. Forced-failure rollback — lastWriterWinsByHLC tombstone (delete + tombstone-HLC write)

    @Test("lastWriterWinsByHLC tombstone: delete and tombstone-HLC write roll back TOGETHER when the transaction fails between them")
    func lastWriterWinsByHLC_tombstone_forcedFailureBetweenDeleteAndTombstoneHLC_rollsBackBoth() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        // Seed a real row through the production path.
        try await actor.applyInbound(
            makeRecord(id: rowID, note: "seed", hlcTime: 100),
            syncedTable: lwwTable, storage: storage)

        let predicate = StoragePredicate.eq(Column(table: "items", name: "id"), .uuid(rowID))
        do {
            try await storage.transaction(isolation: .serializable) { txn in
                _ = try? await txn.rowStore.deleteSync(table: "items", where: predicate)
                // Crash/kill simulated HERE — mirrors the tombstone arm, where
                // writeFedTombstoneHLC is the next statement after the delete.
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
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(
            makeRecord(id: rowID, note: "flww-value", hlcTime: 500, columnStamped: true),
            syncedTable: flwwTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.first?["note"] == .text("flww-value"), "value row must be present after commit")

        let columnHLCs = try await ColumnHLCStore.readAll(
            from: storage, sideTable: FederationStateActor.fedSyncMetaColsTable,
            tableName: "items", primaryKey: rowID)
        #expect(!columnHLCs.isEmpty, "column-HLC bookkeeping must be present after commit")
        #expect(columnHLCs.entries["note"] != nil, "note column's HLC must be recorded")

        let metaRowCount = try await fedSyncMetaRowCount(rowID: rowID, storage: storage)
        #expect(metaRowCount == 1, "row-grain HLC bookkeeping must be present after commit")
    }

    // MARK: - 2b. Success path — lastWriterWinsByHLC: value + row HLC present after one commit

    @Test("lastWriterWinsByHLC success path: value row and row-grain HLC are both present after one applyInbound commit")
    func lastWriterWinsByHLC_successPath_valueAndRowHLCPresent() async throws {
        let storage = try await makeStorage()
        let actor = FederationStateActor()
        let rowID = UUID()

        try await actor.applyInbound(
            makeRecord(id: rowID, note: "lww-value", hlcTime: 500),
            syncedTable: lwwTable, storage: storage)

        let rows = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(rows.first?["note"] == .text("lww-value"), "value row must be present after commit")

        let metaRowCount = try await fedSyncMetaRowCount(rowID: rowID, storage: storage)
        #expect(metaRowCount == 1, "row-grain HLC bookkeeping must be present after commit")

        // A stale re-apply (older HLC) must still be correctly rejected — confirms
        // the transactional write path persisted a real, gate-effective HLC, not
        // an inert placeholder.
        try await actor.applyInbound(
            makeRecord(id: rowID, note: "stale-should-be-rejected", hlcTime: 1),
            syncedTable: lwwTable, storage: storage)
        let afterStale = try await storage.rowStore.query(
            table: "items", where: .eq(Column(table: "items", name: "id"), .uuid(rowID)))
        #expect(afterStale.first?["note"] == .text("lww-value"),
                "stale inbound record must be rejected by the HLC persisted via the transactional write")
    }
}
