// FederationDurableOutboxTests.swift
//
// Five durable _fed_outbox contracts (CVK-WC2).
//
// These guard the invariants added when the in-memory pendingOutbound array
// was replaced with a persistent _fed_outbox SQLite side table. Each test
// names the contract it enforces, matches the Rust twin in
// federation_durable_outbox_tests.rs, and fails loudly if the contract
// regresses.
//
// CONTRACT SUMMARY (mirror of Rust twin):
//   DUR-1: durability across engine reopen
//           Outbox entries written before disable() survive to the next enable()
//           and are delivered by the subsequent push().
//   DUR-2: push-failure-retains (throwing relay)
//           If relay.send throws, push() does NOT confirm (delete) outbox
//           entries — they remain for the next push cycle's retry.
//   DUR-3: coalescing — same (table, row_key) collapses to newest-HLC entry
//           Two writes to the same row produce one outbox entry (the newer one).
//   DUR-4: drain-on-enable — leftover entries are visible after reload
//           enable() finds outbox entries that survived from the prior run and
//           logs them. The entries are not auto-delivered (host triggers push).
//   DUR-5: echo-still-suppressed-after-reload
//           Inbound sync records applied by B do not populate B's outbox even
//           after B is disabled and re-enabled (echo suppression is not
//           origin-field-based; it fires at observe time and is not re-evaluated
//           on reload because the outbox stores complete SyncRecords, not
//           TableChanges).

import Testing
import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Test fixtures

/// Relay conformer that throws on every send. Models a hosted relay failure
/// (e.g. network error) to verify retain-on-failure contract (DUR-2).
///
/// drain() always returns [] — no envelopes ever reach the recipient when
/// this relay is in use, so pull() on the paired engine finds nothing.
final class ThrowingRelay: Relay, @unchecked Sendable {
    struct SendFailure: Error {}
    func send(to recipient: Data, message: SignedEnvelope) throws {
        throw SendFailure()
    }
    func drain(for recipient: Data) -> [SignedEnvelope] { [] }
}

// MARK: - Suite

@Suite("Federation durable _fed_outbox contracts (CVK-WC2)")
struct FederationDurableOutboxTests {

    // MARK: - Shared helpers

    /// The side table name for direct-count queries in tests.
    /// Hardcoded rather than using the internal static to keep the assertion
    /// surface independent of the implementation constant.
    private let fedOutboxTableName = "_fed_outbox"

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
                    columns: [
                        .uuid("id"),
                        .text("note"),
                        .bitmap("flags"),
                    ],
                    primaryKey: ["id"]
                ),
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

    func outboxCount(_ storage: any Storage) async throws -> Int {
        try await FedOutboxStore.count(from: storage, table: fedOutboxTableName)
    }

    /// Busy-wait up to 2s for the outbox to reach at least `minCount`.
    /// The observer Task fires asynchronously; this loop gives it time.
    func waitForOutbox(_ storage: any Storage, minCount: Int) async throws {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let n = try await outboxCount(storage)
            if n >= minCount { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Push until at least one record is delivered, or deadline expires.
    func pushUntilNonzero(_ engine: FederationSyncEngine) async throws -> Int {
        let deadline = Date().addingTimeInterval(2.0)
        while true {
            let pushed = try await engine.push().pushed
            if pushed > 0 || Date() >= deadline { return pushed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - DUR-1: Durability across engine reopen

    @Test("DUR-1: outbox entries survive disable/enable cycle and deliver on next push")
    func outboxSurvivesReopen() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let relay = FederationRelay()

        // Initial enable and pair. Engines share the relay at init (WC6:
        // the relay is engine-level, supplied at construction time).
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)
        try await engineA.pair(with: engineB,
                               family: HyperplaneFamilySpec(seed: 0xABCD_1234))

        // Write a row on A — observer will populate outbox.
        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "before-reopen")
        try await waitForOutbox(storageA, minCount: 1)
        let countBeforeReopen = try await outboxCount(storageA)
        #expect(countBeforeReopen >= 1, "outbox must have at least one entry after write")

        // Disable A (entries remain — durability contract). Do NOT push.
        try await engineA.disable()
        let countAfterDisable = try await outboxCount(storageA)
        #expect(countAfterDisable == countBeforeReopen,
                "disable() must NOT clear the durable outbox (entries survive for next push)")

        // Re-enable A and re-pair with B on the same storage.
        let engineA2 = FederationSyncEngine(relay: relay)
        try await engineA2.enable(manifest: makeManifest(), storage: storageA)
        try await engineA2.pair(with: engineB,
                                family: HyperplaneFamilySpec(seed: 0xABCD_1234))

        // Push on reloaded engine: should deliver the surviving entry.
        let pushed = try await pushUntilNonzero(engineA2)
        #expect(pushed >= 1, "reloaded engine must deliver surviving outbox entry")

        // Verify B received the record.
        _ = try await engineB.pull()
        let note = try await rowNote(storageB, id: rowID)
        #expect(note == "before-reopen",
                "peer B must receive the record that survived the engine reopen")

        // Outbox must be empty after successful push (entries confirmed).
        let countAfterPush = try await outboxCount(storageA)
        #expect(countAfterPush == 0, "outbox must be empty after confirmed push")

        try? await engineA2.disable()
        try? await engineB.disable()
    }

    // MARK: - DUR-2: Push-failure retains outbox entries

    @Test("DUR-2: relay.send failure retains outbox entries for retry")
    func pushFailureRetainsEntries() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let throwingRelay = ThrowingRelay()

        // Pair A and B with a relay that always fails on send. The relay is
        // engine-level (WC6), so the failing transport is supplied at init.
        let engineA = FederationSyncEngine(relay: throwingRelay)
        let engineB = FederationSyncEngine(relay: throwingRelay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)
        try await engineA.pair(with: engineB,
                               family: HyperplaneFamilySpec(seed: 0xDEAD_BEEF))

        // Write a row — observer populates outbox.
        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "retry-me")
        try await waitForOutbox(storageA, minCount: 1)

        let countBefore = try await outboxCount(storageA)
        #expect(countBefore >= 1, "outbox must be populated before the failing push")

        // Push with the throwing relay. push() must not throw (it catches relay errors
        // internally) but must return pushed == 0 (no successful delivery).
        let receipt = try await engineA.push()
        #expect(receipt.pushed == 0,
                "push() must report 0 pushed when relay.send throws")

        // Entries must still be in the outbox — confirm() was NOT called.
        let countAfter = try await outboxCount(storageA)
        #expect(countAfter == countBefore,
                "outbox entries must survive a push-failure (retain-on-failure contract)")

        // Repair: switch to a working relay. Re-pair with a standard relay
        // and verify the entries are now delivered.
        let workingRelay = FederationRelay()
        let engineA2 = FederationSyncEngine(relay: workingRelay)
        let engineB2 = FederationSyncEngine(relay: workingRelay)
        // Start fresh engines but reuse storageA so outbox entries carry over.
        try? await engineA.disable()
        try? await engineB.disable()
        try await engineA2.enable(manifest: makeManifest(), storage: storageA)
        try await engineB2.enable(manifest: makeManifest(), storage: storageB)
        try await engineA2.pair(with: engineB2,
                                family: HyperplaneFamilySpec(seed: 0xDEAD_BEEF))

        let recoveredPushed = try await pushUntilNonzero(engineA2)
        #expect(recoveredPushed >= 1, "entries must deliver on retry with working relay")

        _ = try await engineB2.pull()
        let note = try await rowNote(storageB, id: rowID)
        #expect(note == "retry-me",
                "the retained entry must be delivered successfully after relay repair")

        try? await engineA2.disable()
        try? await engineB2.disable()
    }

    // MARK: - DUR-3: Coalescing

    @Test("DUR-3: two writes to same (table, row_key) coalesce to newest-HLC entry")
    func coalescingNewestHLCWins() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let relay = FederationRelay()

        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)
        try await engineA.pair(with: engineB,
                               family: HyperplaneFamilySpec(seed: 0xC0A1_E5CE))

        // Write v1 then immediately v2 to the same row.
        // Both observer tasks will fire; the second (higher HLC) should coalesce
        // over the first so the outbox carries exactly one entry.
        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "v1")
        try await writeRow(storageA, id: rowID, note: "v2")

        // Give both observer tasks time to fire and coalesce.
        try await Task.sleep(nanoseconds: 500_000_000)

        let count = try await outboxCount(storageA)
        #expect(count == 1,
                "two writes to the same (table, row_key) must coalesce to one outbox entry")

        // The single entry must represent the latest write (v2).
        // Push and verify the peer received v2, not v1.
        let pushed = try await engineA.push().pushed
        #expect(pushed >= 1)
        _ = try await engineB.pull()
        let note = try await rowNote(storageB, id: rowID)
        #expect(note == "v2",
                "after coalescing, peer must receive the newest value (v2)")

        try? await engineA.disable()
        try? await engineB.disable()
    }

    // MARK: - DUR-4: Drain-on-enable

    @Test("DUR-4: leftover outbox entries survive disable and are found by re-enable")
    func drainOnEnableFindsLeftovers() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let relay = FederationRelay()

        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)
        try await engineA.pair(with: engineB,
                               family: HyperplaneFamilySpec(seed: 0xFEED_CAFE))

        // Write WITHOUT pushing so entries accumulate in the outbox.
        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "leftover")
        try await waitForOutbox(storageA, minCount: 1)

        // Disable A — entries must remain (durable leave-in-place).
        try await engineA.disable()
        let countAfterDisable = try await outboxCount(storageA)
        #expect(countAfterDisable >= 1,
                "outbox entries must persist through disable() — drain-on-enable requires them")

        // Re-enable: FederationStateActor.enable() calls FedOutboxStore.count()
        // and logs leftover entries. Verify entries are still present (visible
        // to the drain-on-enable logic).
        let engineA2 = FederationSyncEngine(relay: relay)
        try await engineA2.enable(manifest: makeManifest(), storage: storageA)
        let countAfterEnable = try await outboxCount(storageA)
        #expect(countAfterEnable == countAfterDisable,
                "enable() must NOT consume outbox entries — host triggers push() separately")

        // Re-pair and push to drain the leftovers.
        try await engineA2.pair(with: engineB,
                                family: HyperplaneFamilySpec(seed: 0xFEED_CAFE))
        let pushed = try await pushUntilNonzero(engineA2)
        #expect(pushed >= 1, "push() must drain the leftover entries after re-enable")
        _ = try await engineB.pull()
        #expect(try await rowNote(storageB, id: rowID) == "leftover",
                "leftover entry must be delivered after drain-on-enable push cycle")

        try? await engineA2.disable()
        try? await engineB.disable()
    }

    // MARK: - DUR-5: Echo still suppressed after reload

    @Test("DUR-5: applied inbound records do not enter B's outbox after B's engine reload")
    func echoStillSuppressedAfterReload() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let relay = FederationRelay()

        let engineA = FederationSyncEngine(relay: relay)
        var engineB: FederationSyncEngine = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)
        try await engineA.pair(with: engineB,
                               family: HyperplaneFamilySpec(seed: 0xEC50_1234))

        // A writes a row and pushes to B.
        let rowID = UUID()
        try await writeRow(storageA, id: rowID, note: "echo-check")
        _ = try await pushUntilNonzero(engineA)

        // B applies the inbound record. Echo suppression (I-10) must prevent
        // the apply-write from populating B's outbox.
        _ = try await engineB.pull()
        try await Task.sleep(nanoseconds: 200_000_000)  // observer settle
        let bOutboxBefore = try await outboxCount(storageB)
        #expect(bOutboxBefore == 0,
                "inbound apply must not populate B's outbox (echo suppression I-10)")

        // Reload B: disable + re-enable on the same storage.
        try await engineB.disable()
        let engineB2 = FederationSyncEngine(relay: relay)
        try await engineB2.enable(manifest: makeManifest(), storage: storageB)
        try await engineA.pair(with: engineB2,
                               family: HyperplaneFamilySpec(seed: 0xEC50_1234))
        engineB = engineB2

        // A writes another record and pushes to B (reloaded).
        try await writeRow(storageA, id: rowID, note: "echo-check-v2")
        _ = try await pushUntilNonzero(engineA)
        _ = try await engineB.pull()
        try await Task.sleep(nanoseconds: 200_000_000)  // observer settle

        // B's outbox must remain empty after reload — echo suppression is not
        // origin-field-based (origins are local at observe time); the durable
        // outbox stores SyncRecords with no origin, but only local writes reach
        // recordOutbound. The apply-write fires with origin == .syncApply and
        // is suppressed at the guard in recordOutbound.
        let bOutboxAfterReload = try await outboxCount(storageB)
        #expect(bOutboxAfterReload == 0,
                "echo suppression must hold after engine reload (I-10 invariant)")

        // Confirm A's outbox is clean (pushed + confirmed).
        let aOutbox = try await outboxCount(storageA)
        #expect(aOutbox == 0, "A's outbox must be empty after confirmed pushes")

        try? await engineA.disable()
        try? await engineB.disable()
    }
}
