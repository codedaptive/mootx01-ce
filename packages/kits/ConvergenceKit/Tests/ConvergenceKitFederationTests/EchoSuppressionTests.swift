// EchoSuppressionTests.swift
//
// Verifies the echo-suppression contract (I-10, CVK-ICLOUD P1-M1).
//
// The bug: applyInbound writes through rowStore → StorageObserver fires
// → recordOutbound appends to pendingOutbound → pushed back to sending peer.
// Two live machines ping-pong forever, never converging.
//
// The fix: applyInbound uses the sync-tagged write paths (upsertSync /
// insertSync / deleteSync) which stamp the resulting TableChange with
// origin: .syncApply. recordOutbound discards .syncApply changes.
//
// These tests assert the complete contract:
//   1. applyInbound writes do NOT appear in the outbox
//   2. local writes DO appear in the outbox (suppression must not over-fire)
//   3. a full push→pull cycle does not produce a push on the receiving side

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

@Suite("Echo suppression — origin tag prevents inbound→outbox re-entry (I-10)")
struct EchoSuppressionTests {

    // MARK: - Helpers

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "EchoTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "notes",
                    columns: [.uuid("id"), .text("body"), .bitmap("flags")],
                    primaryKey: ["id"]
                )
            ]
        ))
        return storage
    }

    func makeManifest() -> SyncManifest {
        SyncManifest(
            kitID: "EchoTestKit",
            schemaVersion: 1,
            zoneIdentifier: "echo-test-zone",
            tables: [
                SyncedTable(name: "notes", primaryKeyColumn: "id",
                            conflictPolicy: .appendOnly)
            ]
        )
    }

    func makePair(
        storageA: any Storage,
        storageB: any Storage
    ) async throws -> (FederationSyncEngine, FederationSyncEngine) {
        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        let manifest = makeManifest()
        try await engineA.enable(manifest: manifest, storage: storageA)
        try await engineB.enable(manifest: manifest, storage: storageB)
        try await engineA.pair(with: engineB, family: HyperplaneFamilySpec(seed: 0xDEAD_C0DE))
        return (engineA, engineB)
    }

    /// Push and return the pushed record count. Does NOT retry — caller
    /// drives timing. Observer tasks populate the outbox asynchronously;
    /// use a brief sleep before calling this when testing "no entries after
    /// applyInbound" to let the observer Task run.
    func pushOnce(_ engine: FederationSyncEngine) async throws -> Int {
        try await engine.push().pushed
    }

    /// Push until a non-zero pushed count is seen or the deadline passes.
    /// Used to confirm a local write DID make it into the outbox.
    func pushUntilNonzero(_ engine: FederationSyncEngine, deadline: TimeInterval = 2.0) async throws -> Int {
        let cutoff = Date().addingTimeInterval(deadline)
        while true {
            let pushed = try await engine.push().pushed
            if pushed > 0 || Date() >= cutoff { return pushed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 1. applyInbound writes must NOT enter the outbox

    @Test("applyInbound does not re-enter the outbox — echo suppression active")
    func applyInbound_doesNotReEnterOutbox() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        // A writes a row and pushes it to B.
        let rowID = UUID()
        _ = try await storageA.rowStore.upsert(
            table: "notes",
            values: ["id": .uuid(rowID), "body": .text("hello from A"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )
        let aPushed = try await pushUntilNonzero(engineA)
        #expect(aPushed >= 1, "A must push at least one record to B")

        // B receives A's record via pull (this calls applyInbound internally).
        let pullReceipt = try await engineB.pull()
        #expect(pullReceipt.pulled >= 1, "B must pull A's record")

        // Immediately after pull, give the observer Task a moment to run.
        // If echo suppression is broken, the applyInbound write would have
        // fired the observer, which would have appended to B's outbox.
        // Yield for 150ms to let any rogue observer Task complete.
        try await Task.sleep(nanoseconds: 150_000_000)

        // B's outbox must be empty. A local write from B would populate it;
        // the applyInbound write must NOT have done so.
        let bOutboxPushed = try await pushOnce(engineB)
        #expect(bOutboxPushed == 0,
            "applyInbound writes must NOT appear in B's outbox — echo suppression broken")
    }

    // MARK: - 2. local writes DO appear in the outbox (non-suppression)

    @Test("local writes still appear in outbox after applyInbound (no over-suppression)")
    func localWrites_appearInOutboxAfterPull() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        // A writes and pushes.
        let rowFromA = UUID()
        _ = try await storageA.rowStore.upsert(
            table: "notes",
            values: ["id": .uuid(rowFromA), "body": .text("from A"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )
        _ = try await pushUntilNonzero(engineA)

        // B pulls A's record.
        _ = try await engineB.pull()
        try await Task.sleep(nanoseconds: 100_000_000) // let observer settle

        // B now writes a LOCAL row. This must populate B's outbox.
        let rowFromB = UUID()
        _ = try await storageB.rowStore.upsert(
            table: "notes",
            values: ["id": .uuid(rowFromB), "body": .text("from B"), "flags": .bitmap(0)],
            conflictColumns: ["id"]
        )

        let bPushed = try await pushUntilNonzero(engineB)
        #expect(bPushed >= 1,
            "B's local write must appear in its outbox — echo suppression must not suppress local writes")

        // A pulls B's record.
        _ = try await engineA.pull()
        let count = try await storageA.rowStore.count(
            table: "notes",
            where: .eq(Column(table: "notes", name: "id"), .uuid(rowFromB))
        )
        #expect(count == 1, "A must receive B's locally-written row via pull")
    }

    // MARK: - 3. full push→pull cycle — no echo on the receiving side

    @Test("push-pull cycle: receiving side produces zero outbox entries after applying inbound")
    func pushPullCycle_receiverHasEmptyOutboxAfterApply() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let (engineA, engineB) = try await makePair(storageA: storageA, storageB: storageB)
        defer { Task { try? await engineA.disable(); try? await engineB.disable() } }

        // A writes several rows. Each write fires an observer Task asynchronously,
        // so the outbox is populated across multiple async hops. Accumulate by
        // pushing repeatedly until all records have shipped.
        let rowIDs = (0..<3).map { _ in UUID() }
        for (i, rowID) in rowIDs.enumerated() {
            _ = try await storageA.rowStore.upsert(
                table: "notes",
                values: ["id": .uuid(rowID), "body": .text("item-\(i)"), "flags": .bitmap(0)],
                conflictColumns: ["id"]
            )
        }

        // Push-accumulate until all 3 records have left A's outbox.
        var totalPushedByA = 0
        let cutoff = Date().addingTimeInterval(3.0)
        while totalPushedByA < 3, Date() < cutoff {
            let pushed = try await engineA.push().pushed
            totalPushedByA += pushed
            if totalPushedByA < 3 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        #expect(totalPushedByA >= 3, "A must push all 3 rows (got \(totalPushedByA))")

        // B applies all records via pull (applyInbound uses sync-tagged writes).
        let pullReceipt = try await engineB.pull()
        #expect(pullReceipt.pulled >= 3, "B must pull all 3 rows from A (got \(pullReceipt.pulled))")

        // Yield to let any rogue observer Tasks from applyInbound writes settle.
        try await Task.sleep(nanoseconds: 200_000_000)

        // B's outbox must be empty — none of the applyInbound writes should
        // have re-entered the outbox.
        let bOutboxPushed = try await pushOnce(engineB)
        #expect(bOutboxPushed == 0,
            "B must have 0 outbox entries after applying 3 inbound records — echo suppression broken")
    }
}
