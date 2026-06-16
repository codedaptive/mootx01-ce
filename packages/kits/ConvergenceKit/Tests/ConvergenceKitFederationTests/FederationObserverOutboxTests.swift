// FederationObserverOutboxTests.swift
//
// Parity force-tests for the observer-driven outbox auto-population.
//
// These mirror federation_observer_outbox_tests.rs and assert IDENTICAL
// behavior across both ports:
//   1. write-auto-populates-outbox: an insert/update/delete to a
//      federation-enabled estate auto-populates the outbox WITHOUT any
//      explicit enqueue — push then delivers the record to the peer.
//   3. disable-stops-auto-population: after disable, a later write does NOT
//      auto-populate the outbox (lifecycle: observer tasks cancelled, no leak).
//
// Case 2 of the Rust file (explicit-enqueue regression) has no Swift analogue:
// the Swift engine has always been observer-only and exposes no public
// `enqueue`. The Rust port keeps an explicit `enqueue` for direct-record
// callers (no-removal), so its regression test guards that extra path; the
// auto-population and lifecycle behavior asserted here is identical on both
// ports.
//
// The observer maps each storage write to a SyncRecord on a background Task,
// so a short yield precedes each push — the same shape as the Rust test's
// bounded poll.

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Federation observer-outbox parity force-tests")
struct FederationObserverOutboxTests {

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
            ]
        ))
        return storage
    }

    func makeManifest() -> SyncManifest {
        SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "zone-test",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id",
                                 conflictPolicy: .lastWriterWinsByHLC)]
        )
    }

    /// Pair two enabled engines over a shared relay.
    func makePair(
        storageA: any Storage,
        storageB: any Storage
    ) async throws -> (FederationSyncEngine, FederationSyncEngine) {
        let engineA = FederationSyncEngine()
        let engineB = FederationSyncEngine()
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)
        let relay = FederationRelay()
        try await engineA.pair(with: engineB, via: relay,
                               family: HyperplaneFamilySpec(seed: 0xBEEF_CAFE))
        return (engineA, engineB)
    }

    func writeRow(_ storage: any Storage, id: UUID, note: String) async throws {
        _ = try await storage.rowStore.upsert(
            table: "items",
            values: ["id": .uuid(id), "note": .text(note), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )
    }

    func rowNote(_ storage: any Storage, id: UUID) async throws -> String? {
        let rows = try await storage.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(id))
        )
        guard case .text(let s) = rows.first?["note"] ?? .null else { return nil }
        return s
    }

    func rowExists(_ storage: any Storage, id: UUID) async throws -> Bool {
        let n = try await storage.rowStore.count(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(id))
        )
        return n > 0
    }

    /// Push until a non-zero pushed count is observed or the deadline passes.
    /// The observer Task populates the outbox asynchronously, so the first
    /// push can race ahead of it — bounded retry mirrors the Rust test's poll.
    func pushUntilNonzero(_ engine: FederationSyncEngine) async throws -> Int {
        let deadline = Date().addingTimeInterval(2.0)
        while true {
            let pushed = try await engine.push().pushed
            if pushed > 0 || Date() >= deadline { return pushed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. auto-population

    @Test("a write auto-populates the outbox for insert (no explicit enqueue)")
    func writeAutoPopulatesOutboxForInsert() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        // No enqueue API exists; the observer is the only capture path. Write
        // directly to storage and confirm the outbox auto-populated.
        try await writeRow(storageA, id: rowID, note: "auto-captured")

        let pushed = try await pushUntilNonzero(engineA)
        #expect(pushed >= 1, "observer must auto-populate the outbox on a write")
        _ = try await engineB.pull()
        #expect(try await rowNote(storageB, id: rowID) == "auto-captured")
    }

    @Test("a write auto-populates the outbox for update")
    func writeAutoPopulatesOutboxForUpdate() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "v1")
        #expect(try await pushUntilNonzero(engineA) >= 1)
        _ = try await engineB.pull()

        try await writeRow(storageA, id: rowID, note: "v2")
        #expect(try await pushUntilNonzero(engineA) >= 1, "update must auto-populate")
        _ = try await engineB.pull()
        #expect(try await rowNote(storageB, id: rowID) == "v2")
    }

    @Test("a delete auto-populates the outbox")
    func writeAutoPopulatesOutboxForDelete() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "to-delete")
        #expect(try await pushUntilNonzero(engineA) >= 1)
        _ = try await engineB.pull()
        #expect(try await rowExists(storageB, id: rowID), "row must seed on peer first")

        _ = try await storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(try await pushUntilNonzero(engineA) >= 1, "delete must auto-populate")
        _ = try await engineB.pull()
        #expect(try await rowExists(storageB, id: rowID) == false,
                "delete must propagate to peer")
    }

    // MARK: - 3. lifecycle: disable stops auto-population

    @Test("disable stops auto-population (no leaked observer)")
    func disableStopsAutoPopulation() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineB.disable() } }

        // Disable A — its observer tasks must be cancelled.
        try await engineA.disable()

        // A write after disable must not be captured.
        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "after-disable")
        // Give any (incorrectly) surviving observer task a chance to run.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Re-enable and push: the outbox must be empty — the pre-disable state
        // was cleared and the post-disable write was never captured.
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        let relay = FederationRelay()
        try await engineA.pair(with: engineB, via: relay,
                               family: HyperplaneFamilySpec(seed: 0xBEEF_CAFE))
        let pushed = try await engineA.push().pushed
        #expect(pushed == 0, "no write should remain captured across a disable boundary")
        let receipt = try await engineB.pull()
        #expect(receipt.pulled == 0, "peer must receive nothing after A disabled")
    }
}
