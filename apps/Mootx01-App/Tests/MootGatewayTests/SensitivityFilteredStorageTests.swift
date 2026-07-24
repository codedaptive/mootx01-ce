// SensitivityFilteredStorageTests.swift
//
// Perkins Gate tests — CVK-ICLOUD P5-M1
//
// Verifies the two invariants the Perkins security review mandates:
//
//   OUTBOUND: Above-ceiling TableChange events are suppressed from the
//   filtered observer stream. The engine's outbound observer never sees them,
//   so they never enter the outbox and never cross the CloudKit wire.
//
//   INBOUND: insertSync / upsertSync for above-ceiling rows throw
//   SensitivityCeilingError. PullCycle's per-record catch counts the throw as
//   a conflict. The row is not written locally.
//
// All tests use a fake backing storage (FakeSyncStorage) with a manually-
// pumpable observer, so the tests are fully deterministic and do not require
// a running estate. The fake is sized to exactly the surface this file tests.

import Testing
import Foundation
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
import LocusKit
@testable import MootGateway

// MARK: - Test-local fake infrastructure

/// A RowStore that records calls and returns no-op handles.
/// Used for below-ceiling pass-through tests where the base must not throw.
private struct FakeRowStore: RowStore {
    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        RowHandle(table: table, key: UUID())
    }
    @discardableResult
    func upsert(table: String, values: [String: TypedValue],
                conflictColumns: [String]) async throws -> RowHandle {
        RowHandle(table: table, key: UUID())
    }
    @discardableResult
    func update(table: String, values: [String: TypedValue],
                where predicate: StoragePredicate) async throws -> Int { 0 }
    func delete(table: String, where predicate: StoragePredicate) async throws -> Int { 0 }
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?) async throws -> [StorageRow] { [] }
    func count(table: String, where predicate: StoragePredicate?) async throws -> Int { 0 }
    func querySkipCorrupt(table: String, where predicate: StoragePredicate?,
                          orderBy: [OrderClause], limit: Int?, offset: Int?,
                          columns: [String]?) async throws -> (rows: [StorageRow], skipped: Int) {
        ([], 0)
    }
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?,
               columns: [String]?) async throws -> [StorageRow] { [] }
}

/// A BlobStore stub that does nothing. Required for Storage conformance.
private struct FakeBlobStore: BlobStore {
    func put(key: BlobKey, bytes: Data) async throws {}
    func get(key: BlobKey) async throws -> Data? { nil }
    func delete(key: BlobKey) async throws {}
    func exists(key: BlobKey) async throws -> Bool { false }
    func size(key: BlobKey) async throws -> Int? { nil }
    func listKeys() async throws -> [BlobKey] { [] }
}

/// An AuditLog stub that discards all events. Required for Storage conformance.
private struct FakeAuditLog: AuditLog {
    func append(_ event: AuditEvent) async throws {}
    func appendBatch(_ events: [AuditEvent]) async throws {}
    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent] { [] }
    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent] { [] }
    func count() async throws -> Int { 0 }
}

/// A StorageObserver built from a fixed pre-seeded array of TableChange events.
/// Delivers all events to the first observe() subscriber, then finishes.
///
/// Used to deterministically test the filter's outbound gate: seed with a
/// mix of above- and below-ceiling events, verify only below-ceiling events
/// emerge from the filtered observer.
private struct SeededStorageObserver: StorageObserver {
    let changes: [TableChange]

    func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        let matching = changes.filter { $0.table == table }
        return AsyncStream { continuation in
            for change in matching { continuation.yield(change) }
            continuation.finish()
        }
    }

    func observeBlobs() -> AsyncStream<BlobChange> { AsyncStream { $0.finish() } }
    func observeDirtyChain() -> AsyncStream<DirtyChainEvent> { AsyncStream { $0.finish() } }
}

/// Minimal Storage conformer for testing SensitivityFilteredStorage.
/// The rowStore is FakeRowStore; the observer is SeededStorageObserver.
private struct FakeSyncStorage: Storage {
    let seededChanges: [TableChange]

    var configuration: EstateConfiguration {
        EstateConfiguration(estateID: UUID(), backend: .inMemory)
    }
    var rowStore: any RowStore { FakeRowStore() }
    var blobStore: any BlobStore { FakeBlobStore() }
    var auditLog: any AuditLog { FakeAuditLog() }
    var observer: any StorageObserver { SeededStorageObserver(changes: seededChanges) }

    func open(schema: SchemaDeclaration) async throws {}
    func close() async {}
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        // Minimal: no real transaction boundary, just execute the block.
        // None of the filter tests use transactions.
        fatalError("FakeSyncStorage does not support transactions")
    }
    func currentSchemaVersion() async throws -> Int { 0 }
    func currentSchemaVersion(for kitID: String) async throws -> Int { 0 }
    func migrate(to schema: SchemaDeclaration) async throws {}
}

/// A RowStore that returns a fixed set of rows from query() and a fixed count from delete().
///
/// Used for CVK-WB1 deleteSync guard tests that need the guard to see a local row
/// with known sensitivity (FixedQueryRowStore.query returns the rows you seed; the
/// default FakeRowStore always returns []). The deleteResult controls what
/// base.delete() returns so tests can distinguish "guard blocked (returns 0)" from
/// "guard forwarded (returns deleteResult)".
private struct FixedQueryRowStore: RowStore {
    let queryResult: [StorageRow]
    let deleteResult: Int

    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        RowHandle(table: table, key: UUID())
    }
    @discardableResult
    func upsert(table: String, values: [String: TypedValue],
                conflictColumns: [String]) async throws -> RowHandle {
        RowHandle(table: table, key: UUID())
    }
    @discardableResult
    func update(table: String, values: [String: TypedValue],
                where predicate: StoragePredicate) async throws -> Int { 0 }
    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        deleteResult
    }
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?) async throws -> [StorageRow] {
        queryResult
    }
    func count(table: String, where predicate: StoragePredicate?) async throws -> Int { 0 }
    func querySkipCorrupt(table: String, where predicate: StoragePredicate?,
                          orderBy: [OrderClause], limit: Int?, offset: Int?,
                          columns: [String]?) async throws -> (rows: [StorageRow], skipped: Int) {
        (queryResult, 0)
    }
    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?,
               columns: [String]?) async throws -> [StorageRow] { queryResult }
}

/// Storage wrapper that substitutes a FixedQueryRowStore for the rowStore.
///
/// Identical to FakeSyncStorage except the caller controls the rowStore used by
/// SensitivityFilteredStorage, so deleteSync guard tests can seed a local row.
private struct FixedQueryStorage: Storage {
    let fixedRowStore: FixedQueryRowStore
    let seededChanges: [TableChange]

    var configuration: EstateConfiguration {
        EstateConfiguration(estateID: UUID(), backend: .inMemory)
    }
    var rowStore: any RowStore { fixedRowStore }
    var blobStore: any BlobStore { FakeBlobStore() }
    var auditLog: any AuditLog { FakeAuditLog() }
    var observer: any StorageObserver { SeededStorageObserver(changes: seededChanges) }

    func open(schema: SchemaDeclaration) async throws {}
    func close() async {}
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        fatalError("FixedQueryStorage does not support transactions")
    }
    func currentSchemaVersion() async throws -> Int { 0 }
    func currentSchemaVersion(for kitID: String) async throws -> Int { 0 }
    func migrate(to schema: SchemaDeclaration) async throws {}
}

// MARK: - Helpers

/// Build an adjectiveBitmap Int64 encoding the given sensitivity tier.
/// Bits 6–11 carry the sensitivity raw value (normal=0, elevated=16,
/// restricted=32, secret=48), matching LocusKit/Adjectives.swift.
private func adjBitmap(sensitivity: AdjectiveSensitivity) -> TypedValue {
    .bitmap(Int64(sensitivity.rawValue) << 6)
}

/// Build a TableChange for the drawers table with the given sensitivity tier.
private func drawerChange(
    sensitivity: AdjectiveSensitivity,
    event: StorageEvent = .insert,
    rowKey: UUID = UUID()
) -> TableChange {
    // Column name matches LocusKitSchema: .bitmap("adjectiveBitmap") (camelCase).
    TableChange(
        table: "drawers",
        event: event,
        rowKey: rowKey,
        values: ["adjectiveBitmap": adjBitmap(sensitivity: sensitivity)],
        origin: .local
    )
}

/// Build a StorageRow for the drawers table with the given sensitivity tier.
private func drawerRow(sensitivity: AdjectiveSensitivity, id: UUID = UUID()) -> StorageRow {
    StorageRow(values: ["id": .uuid(id), "adjectiveBitmap": adjBitmap(sensitivity: sensitivity)])
}

// MARK: - Tests

@Suite("SensitivityFilteredStorage — Perkins Gate (CVK-ICLOUD P5-M1)")
struct SensitivityFilteredStorageTests {

    // MARK: Outbound observer filtering

    @Test("Above-ceiling (restricted) events suppressed from filtered observer stream")
    func observerSuppressesRestrictedRow() async {
        // One restricted-sensitivity insert in the seeded upstream observer.
        let upstream = [drawerChange(sensitivity: .restricted, event: .insert)]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        // Collect all events from the filtered observer.
        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        // Restricted (raw 32) > elevated ceiling (raw 16) → suppressed.
        #expect(received.isEmpty, "restricted row must not reach the filtered observer stream")
    }

    @Test("Above-ceiling (secret) events suppressed from filtered observer stream")
    func observerSuppressesSecretRow() async {
        let upstream = [drawerChange(sensitivity: .secret, event: .insert)]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        // Secret (raw 48) > elevated ceiling (raw 16) → suppressed.
        #expect(received.isEmpty, "secret row must not reach the filtered observer stream")
    }

    @Test("At-ceiling (elevated) events pass through filtered observer stream")
    func observerPassesElevatedRow() async {
        let upstream = [drawerChange(sensitivity: .elevated, event: .insert)]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        // Elevated (raw 16) == ceiling (raw 16) → passes (strict greater-than gate).
        #expect(received.count == 1, "at-ceiling elevated row must pass through the observer")
    }

    @Test("Below-ceiling (normal) events pass through filtered observer stream")
    func observerPassesNormalRow() async {
        let upstream = [drawerChange(sensitivity: .normal, event: .insert)]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        // Normal (raw 0) < elevated ceiling (raw 16) → passes.
        #expect(received.count == 1, "normal row must pass through the observer")
    }

    @Test("Mixed-sensitivity events: only below-ceiling pass through")
    func observerFiltersMixedBatch() async {
        // Four events: normal, elevated, restricted, secret.
        let upstream = [
            drawerChange(sensitivity: .normal),
            drawerChange(sensitivity: .elevated),
            drawerChange(sensitivity: .restricted),
            drawerChange(sensitivity: .secret),
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        // Normal (0) and elevated (16) pass; restricted (32) and secret (48) are gated.
        #expect(received.count == 2, "only normal and elevated events should pass; got \(received.count)")
    }

    @Test("Events without adjective_bitmap (non-drawer tables) always pass through")
    func observerPassesEventsWithoutSensitivity() async {
        // A tunnel TableChange has no adjective_bitmap.
        let upstream = [
            TableChange(
                table: "tunnels",
                event: .insert,
                rowKey: UUID(),
                values: ["tunnel_id": .uuid(UUID()), "label": .text("test-tunnel")],
                origin: .local
            )
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "tunnels", events: [.insert]) {
            received.append(change)
        }
        // No adjective_bitmap → no sensitivity check → always passes.
        #expect(received.count == 1, "tunnel event without adjective_bitmap must pass through")
    }

    // MARK: Inbound rowStore gating

    @Test("insertSync above ceiling (restricted) throws SensitivityCeilingError")
    func insertSyncRestrictedThrows() async throws {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .restricted),
        ]
        await #expect(throws: SensitivityCeilingError.self) {
            _ = try await filtered.rowStore.insertSync(table: "drawers", values: values)
        }
    }

    @Test("insertSync above ceiling (secret) throws SensitivityCeilingError")
    func insertSyncSecretThrows() async throws {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .secret),
        ]
        await #expect(throws: SensitivityCeilingError.self) {
            _ = try await filtered.rowStore.insertSync(table: "drawers", values: values)
        }
    }

    @Test("insertSync at ceiling (elevated) passes — not thrown, delegates to base")
    func insertSyncElevatedPasses() async throws {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .elevated),
        ]
        // Should NOT throw — at-ceiling rows are permitted.
        let handle = try await filtered.rowStore.insertSync(table: "drawers", values: values)
        #expect(handle.table == "drawers", "at-ceiling insert should return a valid handle")
    }

    @Test("insertSync below ceiling (normal) passes — delegates to base")
    func insertSyncNormalPasses() async throws {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .normal),
        ]
        let handle = try await filtered.rowStore.insertSync(table: "drawers", values: values)
        #expect(handle.table == "drawers", "normal-sensitivity insert should return a valid handle")
    }

    @Test("upsertSync above ceiling (restricted) throws — hook-repair write suppressed")
    func upsertSyncRestrictedThrows() async throws {
        // This test covers Perkins Amendment 1: even if an integrity-hook repair
        // calls upsertSync on a restricted row, the wrapper throws. The hook repair
        // cannot leak above-ceiling content into the outbox through the upsert path.
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .restricted),
            "content": .text("restricted-content"),
        ]
        await #expect(throws: SensitivityCeilingError.self) {
            _ = try await filtered.rowStore.upsertSync(
                table: "drawers", values: values, conflictColumns: ["id"])
        }
    }

    @Test("upsertSync above ceiling (secret) throws — hook-repair write suppressed")
    func upsertSyncSecretThrows() async throws {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .secret),
        ]
        await #expect(throws: SensitivityCeilingError.self) {
            _ = try await filtered.rowStore.upsertSync(
                table: "drawers", values: values, conflictColumns: ["id"])
        }
    }

    @Test("deleteSync with no local row — passes through (peer deletion for non-local row)")
    func deleteSyncNoLocalRowPassesThrough() async throws {
        // When the row targeted by a tombstone is not present in local storage
        // (FakeRowStore.query() always returns []), the guard finds no local row
        // and forwards to base.deleteSync(). This covers the normal peer-deletion
        // path: a peer deletes a below-ceiling row and the tombstone arrives here
        // after the local copy was already gone.
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let predicate = StoragePredicate.eq(
            Column(table: "drawers", name: "id"),
            .uuid(UUID())
        )
        // Guard finds no local row → falls through → FakeRowStore.delete() → 0.
        let count = try await filtered.rowStore.deleteSync(table: "drawers", where: predicate)
        #expect(count == 0, "fake rowStore returns 0 deletes (row absent); must not throw")
    }

    @Test("insertSync on table without adjective_bitmap passes — not sensitivity-gated")
    func insertSyncNoSensitivityColumnPasses() async throws {
        // kg_facts and diary tables have no adjective_bitmap column.
        // Absent bitmap → no sensitivity check → always passes through to base.
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let values: [String: TypedValue] = [
            "fact_id": .uuid(UUID()),
            "subject": .text("test-subject"),
        ]
        let handle = try await filtered.rowStore.insertSync(table: "kg_facts", values: values)
        #expect(handle.table == "kg_facts", "kg_facts insert without adjective_bitmap must pass through")
    }

    // MARK: CVK-WB1: Tier-rise retraction — observer tombstone emission

    @Test("Above-ceiling UPDATE emits exactly one retraction tombstone (delete event, nil values, local origin)")
    func observerEmitsTombstoneForAboveCeilingUpdate() async {
        // Tier-rise scenario: a row's sensitivity was elevated (below ceiling) on a
        // prior write. The user raises it to restricted (above ceiling). The UPDATE
        // event arrives at the observer. Expected: observer emits a synthetic delete
        // (tombstone intent) with nil values and origin .local, keyed on the same
        // rowKey. The outbox picks it up and sends a tombstone CKRecord to peers.
        let rowKey = UUID()
        let upstream = [
            TableChange(table: "drawers", event: .update, rowKey: rowKey,
                        values: ["adjectiveBitmap": adjBitmap(sensitivity: .restricted)],
                        origin: .local),
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.update, .delete]) {
            received.append(change)
        }

        // Exactly one tombstone — the original UPDATE content must not leak.
        #expect(received.count == 1, "expected exactly one retraction tombstone; got \(received.count)")
        let tombstone = received[0]
        #expect(tombstone.event == .delete, "tombstone must be a delete event")
        #expect(tombstone.rowKey == rowKey, "tombstone must carry the same rowKey as the UPDATE")
        #expect(tombstone.values == nil, "tombstone must not carry content (nil values)")
        #expect(tombstone.origin == .local, "tombstone must be origin .local so outbox picks it up")
        #expect(tombstone.table == "drawers", "tombstone must carry the same table name")
    }

    @Test("Above-ceiling INSERT does not emit retraction tombstone — row was never below-ceiling")
    func observerNoTombstoneForAboveCeilingInsert() async {
        // An INSERT with restricted sensitivity means the row was created above-ceiling.
        // Peers never received it, so no tombstone is needed. This also covers the
        // existing P5-M1 suppression invariant — INSERT above-ceiling is suppressed.
        let upstream = [drawerChange(sensitivity: .restricted, event: .insert)]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert, .delete]) {
            received.append(change)
        }
        #expect(received.isEmpty, "above-ceiling INSERT must not emit a tombstone or any event")
    }

    @Test("Above-ceiling DELETE does not emit retraction tombstone — peers already retracted")
    func observerNoTombstoneForAboveCeilingDelete() async {
        // A DELETE event with above-ceiling values means the user explicitly deleted a
        // restricted row. Peers either never received it (case: row was always above-ceiling)
        // or already received the tier-rise tombstone (case: row was promoted then deleted).
        // In neither case is an additional tombstone needed; the DELETE is suppressed.
        let upstream = [drawerChange(sensitivity: .restricted, event: .delete)]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.delete]) {
            received.append(change)
        }
        #expect(received.isEmpty, "above-ceiling DELETE must not emit a tombstone or any event")
    }

    @Test("Below-ceiling UPDATE passes through as UPDATE — not converted to tombstone")
    func observerPassesThroughBelowCeilingUpdate() async {
        // An UPDATE event for an elevated (at-ceiling) row must pass through unchanged,
        // not be converted to a tombstone. Only above-ceiling UPDATEs trigger retraction.
        let rowKey = UUID()
        let upstream = [
            TableChange(table: "drawers", event: .update, rowKey: rowKey,
                        values: ["adjectiveBitmap": adjBitmap(sensitivity: .elevated)],
                        origin: .local),
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.update, .delete]) {
            received.append(change)
        }

        #expect(received.count == 1, "at-ceiling UPDATE must pass through; got \(received.count) events")
        #expect(received[0].event == .update, "event must remain .update, not converted to .delete")
        #expect(received[0].rowKey == rowKey)
    }

    @Test("Demotion edge case: above-ceiling UPDATE then below-ceiling UPDATE passes through as UPDATE")
    func observerDemotionEdgeCase() async {
        // Sequence: tier-rise UPDATE (restricted) → demotion UPDATE (elevated).
        // Expected stream: [tombstone DELETE, UPDATE(elevated)].
        // This verifies the natural re-sync path: after demotion back below-ceiling,
        // the next local write produces a normal UPDATE that goes to the outbox and
        // peers receive the row content again.
        let rowKey = UUID()
        let upstream = [
            // First: tier-rise UPDATE (restricted) → must produce tombstone
            TableChange(table: "drawers", event: .update, rowKey: rowKey,
                        values: ["adjectiveBitmap": adjBitmap(sensitivity: .restricted)],
                        origin: .local),
            // Second: demotion UPDATE (elevated) → must pass through as UPDATE
            TableChange(table: "drawers", event: .update, rowKey: rowKey,
                        values: ["adjectiveBitmap": adjBitmap(sensitivity: .elevated)],
                        origin: .local),
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.update, .delete]) {
            received.append(change)
        }

        #expect(received.count == 2, "expected [tombstone, UPDATE]; got \(received.count) events")
        // First event: tombstone from tier-rise
        #expect(received[0].event == .delete, "first event must be retraction tombstone")
        #expect(received[0].rowKey == rowKey)
        #expect(received[0].values == nil, "tombstone must carry no content")
        // Second event: demotion re-sync (passes through unchanged)
        #expect(received[1].event == .update, "second event must be the demotion UPDATE")
        #expect(received[1].rowKey == rowKey)
        #expect(received[1].values?["adjectiveBitmap"] == adjBitmap(sensitivity: .elevated),
                "demotion UPDATE must carry elevated sensitivity")
    }

    // MARK: CVK-WB1: Tier-rise retraction — deleteSync self-delivery guard

    @Test("deleteSync blocked when local row is above-ceiling — self-delivery guard")
    func deleteSyncBlockedWhenAboveCeilingRowExists() async throws {
        // When the tier-rise tombstone is self-delivered on the next pull cycle,
        // applyInbound calls deleteSync on the local restricted row. The guard must
        // detect the above-ceiling local row and return 0 without forwarding to base.
        // Base.delete() returns deleteResult=1; guard returns 0 if it blocks correctly.
        let restrictedRow = drawerRow(sensitivity: .restricted)
        let fixedRowStore = FixedQueryRowStore(queryResult: [restrictedRow], deleteResult: 1)
        let base = FixedQueryStorage(fixedRowStore: fixedRowStore, seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let predicate = StoragePredicate.eq(
            Column(table: "drawers", name: "id"),
            .uuid(UUID())
        )
        let count = try await filtered.rowStore.deleteSync(table: "drawers", where: predicate)
        // Guard must block: return 0, not the base's deleteResult=1.
        #expect(count == 0, "deleteSync must be blocked for above-ceiling local row (self-delivery guard)")
    }

    @Test("deleteSync passes through when local row is at-ceiling — peer deletion honored")
    func deleteSyncPassesThroughWhenAtCeilingRowExists() async throws {
        // When a peer deletes a below-ceiling (elevated) row and sends a tombstone,
        // the guard must NOT block it. The elevated row is within the sync ceiling;
        // peer deletion semantics apply. Base.delete() returns 1 to signal it deleted.
        let elevatedRow = drawerRow(sensitivity: .elevated)
        let fixedRowStore = FixedQueryRowStore(queryResult: [elevatedRow], deleteResult: 1)
        let base = FixedQueryStorage(fixedRowStore: fixedRowStore, seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        let predicate = StoragePredicate.eq(
            Column(table: "drawers", name: "id"),
            .uuid(UUID())
        )
        let count = try await filtered.rowStore.deleteSync(table: "drawers", where: predicate)
        // Guard must forward: return base's deleteResult=1.
        #expect(count == 1, "deleteSync must forward for at-ceiling local row (peer deletion honored)")
    }

    // MARK: SensitivityCeilingError properties

    @Test("SensitivityCeilingError carries correct table, sensitivityRaw, ceilingRaw")
    func errorCarriesCorrectPayload() async {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        // restricted = rawValue 32; bits 6–11 → Int64(32) << 6
        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjectiveBitmap": adjBitmap(sensitivity: .restricted),
        ]

        var caught: SensitivityCeilingError? = nil
        do {
            _ = try await filtered.rowStore.insertSync(table: "drawers", values: values)
        } catch let err as SensitivityCeilingError {
            caught = err
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(caught != nil, "SensitivityCeilingError must be thrown for restricted insert")
        #expect(caught?.table == "drawers")
        #expect(caught?.sensitivityRaw == 32, "sensitivity raw must be 32 (restricted tier)")
        #expect(caught?.ceilingRaw == 16, "ceiling raw must be 16 (elevated tier)")
    }

    // MARK: FAB5-ST Part 2: Dynamic ceiling — ceiling matrix

    @Test("syncCeiling reflects construction-time ceiling")
    func syncCeilingReflectsConstruction() {
        let storage = SensitivityFilteredStorage(wrapping: FakeSyncStorage(seededChanges: []),
                                                 ceiling: .restricted)
        #expect(storage.syncCeiling == .restricted)
    }

    @Test("Dynamic ceiling: observer uses updated ceiling after retractAndLowerCeiling")
    func dynamicCeilingObserverUsesUpdatedCeiling() async {
        // Create with .restricted ceiling so restricted rows PASS through.
        let base = FakeSyncStorage(seededChanges: [drawerChange(sensitivity: .restricted)])
        let storage = SensitivityFilteredStorage(wrapping: base, ceiling: .restricted)

        // Verify restricted row passes with .restricted ceiling.
        var beforeUpdate: [TableChange] = []
        for await change in storage.observer.observe(table: "drawers", events: [.insert]) {
            beforeUpdate.append(change)
        }
        #expect(beforeUpdate.count == 1, "restricted row must pass when ceiling is .restricted")

        // Lower ceiling to .elevated — verify syncCeiling updated.
        await storage.retractAndLowerCeiling(to: .elevated, tables: ["drawers"])
        #expect(storage.syncCeiling == .elevated, "syncCeiling must reflect lowered ceiling")

        // New observer with fresh upstream — restricted row now blocked.
        let base2 = FakeSyncStorage(seededChanges: [drawerChange(sensitivity: .restricted)])
        let storage2 = SensitivityFilteredStorage(wrapping: base2, ceiling: .restricted)
        await storage2.retractAndLowerCeiling(to: .elevated, tables: ["drawers"])
        var afterUpdate: [TableChange] = []
        for await change in storage2.observer.observe(table: "drawers", events: [.insert]) {
            afterUpdate.append(change)
        }
        #expect(afterUpdate.isEmpty, "restricted row must be blocked after ceiling lowered to .elevated")
    }

    // MARK: FAB5-ST Part 2: Ceiling matrix (sensitivity × ceiling gate outcomes)

    @Test("Ceiling matrix: restricted ceiling — restricted row passes, secret blocked")
    func ceilingMatrixRestrictedCeiling() async {
        // Ceiling = .restricted → restricted rows pass (raw 32 == ceiling raw 32),
        // secret rows are blocked (raw 48 > ceiling raw 32).
        let upstream = [
            drawerChange(sensitivity: .restricted, event: .insert),
            drawerChange(sensitivity: .secret, event: .insert),
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .restricted)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        #expect(received.count == 1, "restricted passes at .restricted ceiling; secret blocked")
    }

    @Test("Ceiling matrix: secret ceiling — all tiers pass")
    func ceilingMatrixSecretCeiling() async {
        // Ceiling = .secret → all tiers pass (raw 48 == ceiling raw 48, nothing above).
        let upstream = [
            drawerChange(sensitivity: .normal),
            drawerChange(sensitivity: .elevated),
            drawerChange(sensitivity: .restricted),
            drawerChange(sensitivity: .secret),
        ]
        let base = FakeSyncStorage(seededChanges: upstream)
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .secret)

        var received: [TableChange] = []
        for await change in filtered.observer.observe(table: "drawers", events: [.insert]) {
            received.append(change)
        }
        #expect(received.count == 4, "all tiers pass at .secret ceiling")
    }

    // MARK: FAB5-ST Part 2: Revocation retraction

    @Test("retractAndLowerCeiling emits tombstones for above-new-ceiling rows in base storage")
    func retractAndLowerCeilingEmitsTombstones() async {
        // Seed base with one restricted row (row is above new ceiling .elevated).
        let restrictedID = UUID()
        let restrictedRow = drawerRow(sensitivity: .restricted, id: restrictedID)
        let fixedRowStore = FixedQueryRowStore(queryResult: [restrictedRow], deleteResult: 0)
        let base = FixedQueryStorage(fixedRowStore: fixedRowStore, seededChanges: [])

        // Start with .restricted ceiling so the row was permitted.
        let storage = SensitivityFilteredStorage(wrapping: base, ceiling: .restricted)

        // Collect tombstones from the retraction stream, returning them from the Task
        // so no mutable state is shared across isolation domains (Swift 6).
        let collector = Task<[TableChange], Never> {
            var collected: [TableChange] = []
            for await tombstone in storage._retractionStream {
                collected.append(tombstone)
                if collected.count >= 1 { break }
            }
            return collected
        }

        // Lower ceiling to .elevated — restricted row is now above-ceiling.
        await storage.retractAndLowerCeiling(to: .elevated, tables: ["drawers"])
        let tombstones = await collector.value

        #expect(tombstones.count == 1, "one tombstone per above-ceiling row")
        #expect(tombstones[0].event == .delete, "tombstone must be a delete event")
        #expect(tombstones[0].table == "drawers")
        #expect(tombstones[0].rowKey == restrictedID, "tombstone rowKey must match the row's id")
        #expect(tombstones[0].values == nil, "tombstone must carry no content")
        #expect(tombstones[0].origin == .local, "tombstone must be .local origin for outbox pickup")
        #expect(storage.syncCeiling == .elevated, "ceiling updated after retraction scan")
    }

    @Test("retractAndLowerCeiling emits no tombstones when no rows exceed new ceiling")
    func retractAndLowerCeilingNoTombstonesWhenBelowCeiling() async {
        // All rows are elevated — none exceed the new .elevated ceiling.
        let elevatedRow = drawerRow(sensitivity: .elevated, id: UUID())
        let fixedRowStore = FixedQueryRowStore(queryResult: [elevatedRow], deleteResult: 0)
        let base = FixedQueryStorage(fixedRowStore: fixedRowStore, seededChanges: [])
        let storage = SensitivityFilteredStorage(wrapping: base, ceiling: .secret)

        // Return count from Task to avoid sharing mutable state across isolation domains (Swift 6).
        let collector = Task<Int, Never> {
            var count = 0
            // Read with a short timeout to confirm no tombstones arrive.
            // Since makeStream uses bufferingNewest, tombstones yielded before
            // Task starts are buffered. A count of 0 after retract confirms none emitted.
            for await _ in storage._retractionStream { count += 1 }
            return count
        }
        await storage.retractAndLowerCeiling(to: .elevated, tables: ["drawers"])
        // Give collector a brief window to see any buffered events.
        try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        collector.cancel()
        let tombstoneCount = await collector.value

        #expect(tombstoneCount == 0, "no tombstones when all rows are within the new ceiling")
        #expect(storage.syncCeiling == .elevated)
    }

    @Test("retractAndLowerCeiling ceiling raise emits no tombstones and updates ceiling")
    func retractAndLowerCeilingRaiseEmitsNothing() async {
        // Raising ceiling: .elevated → .restricted. No rows above new ceiling (no tombstones).
        let base = FixedQueryStorage(
            fixedRowStore: FixedQueryRowStore(queryResult: [], deleteResult: 0),
            seededChanges: [])
        let storage = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        await storage.retractAndLowerCeiling(to: .restricted, tables: ["drawers"])
        #expect(storage.syncCeiling == .restricted, "ceiling updated even when no retraction needed")
    }
}
