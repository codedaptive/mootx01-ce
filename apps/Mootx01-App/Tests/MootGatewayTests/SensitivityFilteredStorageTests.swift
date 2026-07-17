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

// MARK: - Helpers

/// Build an adjective_bitmap Int64 encoding the given sensitivity tier.
/// Bits 6–11 carry the sensitivity raw value (normal=0, elevated=16,
/// restricted=32, secret=48), matching LocusKit/Adjectives.swift.
private func adjBitmap(sensitivity: AdjectiveSensitivity) -> TypedValue {
    .bitmap(Int64(sensitivity.rawValue) << 6)
}

/// Build a TableChange for the drawers table with the given sensitivity tier.
private func drawerChange(
    sensitivity: AdjectiveSensitivity,
    event: StorageEvent = .insert
) -> TableChange {
    TableChange(
        table: "drawers",
        event: event,
        rowKey: UUID(),
        values: ["adjective_bitmap": adjBitmap(sensitivity: sensitivity)],
        origin: .local
    )
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
            "adjective_bitmap": adjBitmap(sensitivity: .restricted),
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
            "adjective_bitmap": adjBitmap(sensitivity: .secret),
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
            "adjective_bitmap": adjBitmap(sensitivity: .elevated),
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
            "adjective_bitmap": adjBitmap(sensitivity: .normal),
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
            "adjective_bitmap": adjBitmap(sensitivity: .restricted),
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
            "adjective_bitmap": adjBitmap(sensitivity: .secret),
        ]
        await #expect(throws: SensitivityCeilingError.self) {
            _ = try await filtered.rowStore.upsertSync(
                table: "drawers", values: values, conflictColumns: ["id"])
        }
    }

    @Test("deleteSync above ceiling passes — tombstone propagation preserved")
    func deleteSyncRestrictedPasses() async throws {
        // Tombstone CKRecords carry only row identity (UUID), not content.
        // Filtering tombstones would prevent restricted-row deletion signals from
        // reaching local storage. deleteSync is always forwarded.
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        // A tombstone delete predicate carries no adjective_bitmap — just the UUID.
        let predicate = StoragePredicate.eq(
            Column(table: "drawers", name: "id"),
            .uuid(UUID())
        )
        // Should NOT throw — tombstone deletes are always forwarded.
        let count = try await filtered.rowStore.deleteSync(table: "drawers", where: predicate)
        #expect(count == 0, "fake rowStore returns 0 deletes but must not throw")
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

    // MARK: SensitivityCeilingError properties

    @Test("SensitivityCeilingError carries correct table, sensitivityRaw, ceilingRaw")
    func errorCarriesCorrectPayload() async {
        let base = FakeSyncStorage(seededChanges: [])
        let filtered = SensitivityFilteredStorage(wrapping: base, ceiling: .elevated)

        // restricted = rawValue 32; bits 6–11 → Int64(32) << 6
        let values: [String: TypedValue] = [
            "id": .uuid(UUID()),
            "adjective_bitmap": adjBitmap(sensitivity: .restricted),
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
}
