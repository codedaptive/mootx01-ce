// IntegrityHookTests.swift
//
// Four required tests for the post-apply integrity hook (R3, CVK-ICLOUD P2-M3).
//
// All tests use a two-engine, shared-relay rig identical to the pattern in
// FederationObserverOutboxTests — InMemoryStorage, FederationRelay, standard
// SyncManifest with the "items" table. The hook is installed on the RECEIVING
// engine's manifest; the sending engine uses a plain manifest without a hook.
//
// Behavioral contract verified:
//   R3-1  hook invoked once per pull batch with correct AppliedBatch contents
//   R3-2  hook writes carry origin == .local and flow into the outbox (ship)
//   R3-3  hook throw counts as ONE additional conflict; pull cycle does NOT abort
//   R3-4  empty-batch rule: hook NOT invoked when zero records are applied

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Thread-safe invocation tracker

/// Actor used to count hook calls and capture the last batch from the closure.
/// Storing AppliedBatch is safe: Storage is Sendable by protocol constraint and
/// the struct is @unchecked Sendable.
private actor HookTracker: Sendable {
    private(set) var invocationCount = 0
    private(set) var capturedAppliedByTable: [String: [UUID]] = [:]
    private(set) var capturedDeletedByTable: [String: [UUID]] = [:]

    func record(batch: AppliedBatch) {
        invocationCount += 1
        capturedAppliedByTable = batch.appliedByTable
        capturedDeletedByTable = batch.deletedByTable
    }
}

@Suite("Integrity hook — R3 post-apply behavioral contract")
struct IntegrityHookTests {

    // MARK: - Rig helpers

    static let schema = SchemaDeclaration(
        kitID: "HookTestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("note"), .bitmap("flags")],
                primaryKey: ["id"]
            )
        ]
    )

    func makeStorage() async throws -> any Storage {
        let s = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await s.open(schema: IntegrityHookTests.schema)
        return s
    }

    func plainManifest() -> SyncManifest {
        SyncManifest(
            kitID: "HookTestKit",
            schemaVersion: 1,
            zoneIdentifier: "hook-test-zone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id",
                                 conflictPolicy: .lastWriterWinsByHLC)]
        )
    }

    func manifestWithHook(_ hook: @Sendable @escaping (AppliedBatch) async throws -> Void) -> SyncManifest {
        var m = plainManifest()
        m.postApplyIntegrityHook = hook
        return m
    }

    /// Push until a non-zero pushed count or the 2 s deadline passes.
    /// The observer Task populates the outbox asynchronously; the retry loop
    /// mirrors the Rust test's bounded poll.
    func pushUntilNonzero(_ engine: FederationSyncEngine) async throws -> Int {
        let deadline = Date().addingTimeInterval(2.0)
        while true {
            let pushed = try await engine.push().pushed
            if pushed > 0 || Date() >= deadline { return pushed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - R3-1: hook invoked once per batch with correct AppliedBatch contents

    @Test("R3-1: hook invoked once per pull batch with correct applied/deleted keys")
    func hookInvokedOnceWithCorrectContents() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()

        let tracker = HookTracker()
        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: plainManifest(), storage: storageA)
        try await engineB.enable(
            manifest: manifestWithHook { batch in await tracker.record(batch: batch) },
            storage: storageB
        )
        try await engineA.pair(with: engineB, family: HyperplaneFamilySpec(seed: 0x1234_5678))
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        // Engine A inserts a row — the observer populates A's outbox.
        let insertedID = UUID()
        _ = try await storageA.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(insertedID), "note": .text("hello"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )

        // Engine A pushes; engine B pulls — hook fires exactly once.
        let pushed = try await pushUntilNonzero(engineA)
        #expect(pushed >= 1, "A must push at least one record")
        _ = try await engineB.pull()

        let callCount = await tracker.invocationCount
        #expect(callCount == 1, "hook must be invoked exactly once per pull batch")

        let appliedByTable = await tracker.capturedAppliedByTable
        let appliedIDs = appliedByTable["items"] ?? []
        #expect(appliedIDs.contains(insertedID),
                "applied batch must include the inserted row key under 'items'")

        let deletedByTable = await tracker.capturedDeletedByTable
        #expect(deletedByTable.isEmpty || (deletedByTable["items"] ?? []).isEmpty,
                "no deletes were sent, so deletedByTable must be empty")
    }

    // MARK: - R3-2: hook writes carry origin == .local and ship on next push

    /// Kong Q2 adjudication (hook-writes-must-ship): writes made through
    /// AppliedBatch.storage use the non-sync-tagged paths and carry origin
    /// == .local. The storage observer fires, populates the outbox, and a
    /// subsequent push delivers the repair record to the peer.
    @Test("R3-2: hook writes carry origin == .local and flow into the outbox")
    func hookWritesShipOnNextPush() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()

        // The repair row that the hook writes.
        let repairID = UUID()

        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: plainManifest(), storage: storageA)
        // B's hook: when a batch arrives, write a repair row to storage.
        // The repair write uses the non-sync-tagged upsert path, so origin == .local.
        try await engineB.enable(
            manifest: manifestWithHook { batch in
                _ = try await batch.storage.rowStore.upsert(
                    table: "items",
                    values: ["id": .uuid(repairID), "note": .text("repaired"), "flags": .bitmap(0xFF)],
                    conflictColumns: ["id"]
                )
            },
            storage: storageB
        )
        try await engineA.pair(with: engineB, family: HyperplaneFamilySpec(seed: 0xABCD_EF01))
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        // A inserts → B pulls → hook fires → hook writes repairID into storageB.
        let seedID = UUID()
        _ = try await storageA.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(seedID), "note": .text("seed"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )
        let pushed = try await pushUntilNonzero(engineA)
        #expect(pushed >= 1)
        _ = try await engineB.pull()

        // Verify the repair row exists in B's storage before any push.
        let repairRows = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(repairID))
        )
        #expect(repairRows.count == 1, "hook must have written the repair row to storageB")

        // Give the storage observer Task time to enqueue the repair write into B's
        // outbox. The observer fires asynchronously; under parallel test load the
        // cooperative thread pool needs an explicit yield window before the push
        // attempt (mirrors the 100ms sleep in FederationStubTests push regression).
        try await Task.sleep(nanoseconds: 200_000_000)

        // Push B → A: the repair row must propagate (hook-writes-must-ship).
        let repairPushed = try await pushUntilNonzero(engineB)
        #expect(repairPushed >= 1, "repair row must flow into B's outbox and ship to A")
        _ = try await engineA.pull()

        let repairOnA = try await storageA.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(repairID))
        )
        #expect(repairOnA.count == 1, "repair row must arrive at A via push/pull")
    }

    // MARK: - R3-3: hook throw counts as one conflict, pull does not abort

    @Test("R3-3: hook throw counts as one conflict and does not abort the pull cycle")
    func hookThrowCountsAsConflict() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()

        struct HookError: Error {}

        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: plainManifest(), storage: storageA)
        // B's hook always throws.
        try await engineB.enable(
            manifest: manifestWithHook { _ in throw HookError() },
            storage: storageB
        )
        try await engineA.pair(with: engineB, family: HyperplaneFamilySpec(seed: 0xDEAD_BEEF))
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        // A inserts → B pulls (hook throws).
        let rowID = UUID()
        _ = try await storageA.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(rowID), "note": .text("trigger"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )
        let pushed = try await pushUntilNonzero(engineA)
        #expect(pushed >= 1)
        let receipt = try await engineB.pull()

        // The record was applied (pulled == 1); hook throw added one conflict.
        #expect(receipt.pulled >= 1,
                "pull must have applied the record before the hook ran")
        #expect(receipt.conflicts == 1,
                "hook throw must count as exactly one conflict in the receipt")

        // Confirm the row reached B despite the hook failure.
        let rows = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "record must be present even though the hook threw")
    }

    // MARK: - R3-4: empty-batch rule — hook NOT invoked when zero records applied

    @Test("R3-4: hook is not invoked when zero records were applied (empty-batch rule)")
    func hookNotInvokedForEmptyBatch() async throws {
        let storageB = try await makeStorage()

        let tracker = HookTracker()
        let engineB = FederationSyncEngine()
        try await engineB.enable(
            manifest: manifestWithHook { batch in await tracker.record(batch: batch) },
            storage: storageB
        )
        defer { Task { try? await engineB.disable() } }

        // Pull with nothing in the relay: zero records applied.
        _ = try await engineB.pull()

        let callCount = await tracker.invocationCount
        #expect(callCount == 0,
                "hook must NOT be invoked when the pull batch applied zero records")
    }
}
