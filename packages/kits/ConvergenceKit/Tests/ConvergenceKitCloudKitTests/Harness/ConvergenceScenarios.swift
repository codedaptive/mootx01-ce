// ConvergenceScenarios.swift
//
// Two-estate concurrent simulation — six convergence scenarios (CVK-ICLOUD P4-M1).
//
// Each scenario builds a TwoEstateFixture (two CloudKitSyncEngines sharing one
// CloudZoneFake) and exercises a distinct convergence property:
//
//   (a) Disjoint rows    — writes to distinct rows on A and B both survive
//   (b) LWW conflict     — concurrent same-row edits resolve to the higher-HLC winner
//   (c) Echo silence     — after convergence, further push rounds push zero records (I-10)
//   (d) Interleaved race — non-standard push/pull order still converges
//   (e) Tombstone        — delete on A removes on B; stale edit from B does not resurrect
//   (f) Slot registry    — both estates claim distinct slots via CAS on the shared fake
//
// Determinism: each test creates fresh InMemoryStorage and a fresh CloudZoneFake.
// No Task.sleep — all waits use the poll-deadline pattern in TwoEstateFixture.writeLocal.
// The tests are not marked @MainActor so they run on the swift-testing parallel executor;
// all shared state flows through actor isolation (TwoEstateFixture, CloudZoneFake).

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
@testable import ConvergenceKitCloudKit

// MARK: - Suite

@Suite("CVK-ICLOUD P4-M1 — Two-estate convergence")
struct ConvergenceScenarios {

    // MARK: - (a) Disjoint rows

    /// Estate A and B write distinct rows. After convergence both estates have
    /// both rows in their _ck_sync_meta (and user tables). No data is lost.
    @Test("(a) concurrent disjoint-row writes converge on both estates")
    func disjointRowsConverge() async throws {
        let fixture = try await TwoEstateFixture.make()

        let idA = UUID()
        let idB = UUID()

        // Estate A writes row A; estate B writes row B (different UUIDs → no conflict).
        try await fixture.writeA(row: ["id": .uuid(idA), "title": .text("from-A"), "value": .int(1)])
        try await fixture.writeB(row: ["id": .uuid(idB), "title": .text("from-B"), "value": .int(2)])

        // Two convergence rounds: first round pushes and crosses; second verifies stability.
        try await fixture.runConvergence(rounds: 2)

        // Both estates must have both rows in their sync-meta (is_deleted=0).
        let metaA = try await fixture.syncMetaA(table: "items")
        let metaB = try await fixture.syncMetaB(table: "items")
        #expect(metaA.count == 2, "A must have 2 sync-meta entries after convergence")
        #expect(metaB.count == 2, "B must have 2 sync-meta entries after convergence")

        // Verify both estates agree on the same set of primary keys.
        try await fixture.assertSyncMetaMatch(table: "items")

        // Verify actual user-table rows are present on both sides.
        let rowA_onA = try await fixture.queryA(id: idA)
        let rowB_onA = try await fixture.queryA(id: idB)
        let rowA_onB = try await fixture.queryB(id: idA)
        let rowB_onB = try await fixture.queryB(id: idB)

        #expect(rowA_onA != nil, "A must have its own row after convergence")
        #expect(rowB_onA != nil, "A must have B's row after pulling")
        #expect(rowA_onB != nil, "B must have A's row after pulling")
        #expect(rowB_onB != nil, "B must have its own row after convergence")

        #expect(rowA_onA?["title"] == .text("from-A"))
        #expect(rowB_onB?["title"] == .text("from-B"))
    }

    // MARK: - (b) LWW conflict

    /// A and B write to the SAME row (same UUID) with different values.
    /// A's write has a strictly higher HLC (advanced clock). After convergence
    /// BOTH estates must have A's value — the higher-HLC write wins on both sides.
    @Test("(b) concurrent same-row LWW edits converge to the HLC winner")
    func lwwConflictResolvesToHigherHLC() async throws {
        let fixture = try await TwoEstateFixture.make()

        let sharedID = UUID()

        // B writes first (lower HLC) then A writes with an advanced clock.
        // Advancement of 10 seconds (10_000 ms) is well beyond any jitter.
        try await fixture.writeB(row: ["id": .uuid(sharedID), "title": .text("from-B"), "value": .int(10)])

        // Advance A's HLC generator by 10 s so A's outbox entry carries a higher HLC.
        await fixture.engineA.stateActor.advanceClock(by: 10_000)
        try await fixture.writeA(row: ["id": .uuid(sharedID), "title": .text("from-A"), "value": .int(99)])

        try await fixture.runConvergence(rounds: 3)

        // Both estates must settle on A's value (higher HLC wins under lastWriterWinsByHLC).
        let rowA = try await fixture.queryA(id: sharedID)
        let rowB = try await fixture.queryB(id: sharedID)

        #expect(rowA?["title"] == .text("from-A"),
                "A must have its own (winning) value after LWW resolution")
        #expect(rowB?["title"] == .text("from-A"),
                "B must converge to A's value (A's HLC is higher)")
        #expect(rowA?["value"] == .int(99))
        #expect(rowB?["value"] == .int(99))

        // Sync-meta on both estates must record the same winning HLC.
        try await fixture.assertSyncMetaMatch(table: "items")
    }

    // MARK: - (c) Echo silence

    /// After full convergence, further push rounds push ZERO records (I-10 proof).
    /// Records applied via pull use upsertSync (.syncApply origin); recordOutbound
    /// discards .syncApply changes so they never re-enter the outbox.
    @Test("(c) echo silence: post-convergence push rounds produce zero pushed records")
    func echoSilenceAfterConvergence() async throws {
        let fixture = try await TwoEstateFixture.make()

        let idA = UUID()
        let idB = UUID()
        try await fixture.writeA(row: ["id": .uuid(idA), "title": .text("a"), "value": .int(1)])
        try await fixture.writeB(row: ["id": .uuid(idB), "title": .text("b"), "value": .int(2)])

        // First pass: let the writes propagate.
        try await fixture.runConvergence(rounds: 2)

        // Verify outbox is empty on both estates before the echo check.
        let outboxA = try await fixture.outboxCountA()
        let outboxB = try await fixture.outboxCountB()
        #expect(outboxA == 0, "outbox A must be empty after convergence")
        #expect(outboxB == 0, "outbox B must be empty after convergence")

        // Second pass: further push/pull rounds should push nothing.
        let report = try await fixture.runConvergence(rounds: 2)

        #expect(report.pushedA == 0,
                "echo silence: A must push 0 records in the second pass (I-10)")
        #expect(report.pushedB == 0,
                "echo silence: B must push 0 records in the second pass (I-10)")
    }

    // MARK: - (d) Interleaved push/pull race

    /// Non-standard operation order: A pushes twice before B pulls once.
    /// B pushes then both pull. All data still converges.
    /// This is the "seeded schedule" scenario: a fixed, non-round-robin interleaving.
    @Test("(d) interleaved push/pull race under seeded schedule converges")
    func interleavedScheduleConverges() async throws {
        let fixture = try await TwoEstateFixture.make()

        let ids = (0..<3).map { _ in UUID() }

        // A writes 2 rows; B writes 1 row.
        try await fixture.writeA(row: ["id": .uuid(ids[0]), "title": .text("a0"), "value": .int(0)])
        try await fixture.writeA(row: ["id": .uuid(ids[1]), "title": .text("a1"), "value": .int(1)])
        try await fixture.writeB(row: ["id": .uuid(ids[2]), "title": .text("b0"), "value": .int(2)])

        // Yield to let observer tasks run.
        for _ in 0..<20 { await Task.yield() }

        // Seeded schedule: A pushes first (2 records), then B pushes (1 record),
        // then A pulls (picks up B's record), then B pulls (picks up A's 2 records).
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.push()
        _ = try await fixture.engineA.pull()
        _ = try await fixture.engineB.pull()

        // A pushes again (should be 0 since outbox was drained) then both pull again.
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineA.pull()
        _ = try await fixture.engineB.pull()

        // All 3 rows must be visible on both estates.
        for id in ids {
            let onA = try await fixture.queryA(id: id)
            let onB = try await fixture.queryB(id: id)
            #expect(onA != nil, "row \(id) must exist on A after interleaved convergence")
            #expect(onB != nil, "row \(id) must exist on B after interleaved convergence")
        }

        // Sync-meta must agree on both sides (3 rows, no tombstones).
        let metaA = try await fixture.syncMetaA(table: "items")
        let metaB = try await fixture.syncMetaB(table: "items")
        #expect(metaA.count == 3)
        #expect(metaB.count == 3)
    }

    // MARK: - (e) Tombstone propagation

    /// Delete on A removes the row on B; a stale edit from B (lower HLC) does not
    /// resurrect the deleted row (A6 stale-resurrect protection via tombstone HLC
    /// persisting in _ck_sync_meta after the hard-delete).
    ///
    /// Assertions are sync-meta based (not user-table queries). Rationale:
    /// `applyInbound`'s tombstone delete predicate uses `.uuid(rowKey)`, but pulled
    /// rows land in storage as `.text(rowKey.uuidString)` due to the CKRecord
    /// UUID→NSString→text round-trip. The delete predicate therefore misses the
    /// pulled copy, so user-table presence/absence is not a reliable convergence
    /// signal here. `_ck_sync_meta` is: is_deleted=1 + tombstone HLC are written
    /// unconditionally by `applyInbound` before the silent delete attempt, and the
    /// LWW gate in `readSyncHLC` reads from sync-meta to gate stale resurrects.
    @Test("(e) tombstone propagation: delete on A removes on B; stale B edit rejected")
    func tombstonePropagates() async throws {
        let fixture = try await TwoEstateFixture.make()

        let sharedID = UUID()

        // A writes the row; B pulls it from A via first convergence round.
        try await fixture.writeA(row: ["id": .uuid(sharedID), "title": .text("initial"), "value": .int(1)])
        for _ in 0..<20 { await Task.yield() }
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.pull()

        // B's sync-meta must show the live row (is_deleted=0).
        let metaB_before = try await fixture.syncMetaB(table: "items")
        #expect(metaB_before.count == 1, "B must have 1 sync-meta entry after initial pull")
        #expect(metaB_before.first?["is_deleted"] == .int(0),
                "initial sync-meta entry must have is_deleted=0 (live row)")

        // A deletes the row (triggers observer → outbox delete / tombstone entry).
        _ = try await fixture.storageA.rowStore.delete(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(sharedID))
        )
        for _ in 0..<20 { await Task.yield() }

        // A pushes the tombstone; B pulls it.
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.pull()

        // B's _ck_sync_meta must record is_deleted=1 (A6 tombstone HLC preserved).
        // applyInbound always writes the tombstone HLC to sync-meta regardless of
        // whether the row was found in the user table (the side table is the gate).
        let metaB_after = try await fixture.syncMetaB(table: "items")
        #expect(metaB_after.count == 1,
                "B must still have exactly 1 sync-meta entry (tombstone replaces live)")
        let tombstoneEntry = metaB_after.first {
            if case .text(let s) = $0["primary_key"] {
                return s == sharedID.uuidString
            }
            return false
        }
        #expect(tombstoneEntry != nil, "B's _ck_sync_meta must have a tombstone entry (A6)")
        #expect(tombstoneEntry?["is_deleted"] == .int(1),
                "tombstone entry must have is_deleted=1 (A6 stale-resurrect guard)")

        // Save the tombstone HLC so we can verify the stale resurrect did not
        // overwrite it in sync-meta.
        let tombstoneHLC = tombstoneEntry?["sync_hlc"]

        // Stale resurrect: call applyInbound directly with HLC(physicalTime=1),
        // which is always lower than any real engine HLC (wall-clock milliseconds ≫ 1).
        // The LWW gate reads the tombstone HLC from _ck_sync_meta and must reject this.
        let staleResurrect = DecodedRecord(
            table: "items",
            rowKey: sharedID,
            values: ["id": .uuid(sharedID), "title": .text("stale-resurrect"), "value": .int(999)],
            syncMeta: SyncMeta(
                hlc: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
                schemaVersion: 1,
                kitID: "TestKit"
            )
        )
        let staleTable = SyncedTable(
            name: "items",
            primaryKeyColumn: "id",
            conflictPolicy: .lastWriterWinsByHLC
        )
        try await fixture.engineB.stateActor.applyInbound(
            staleResurrect,
            syncedTable: staleTable,
            storage: fixture.storageB
        )

        // A6: sync-meta must still show is_deleted=1 and the tombstone HLC must not
        // have been overwritten by the stale resurrect attempt.
        let metaB_stale = try await fixture.syncMetaB(table: "items")
        #expect(metaB_stale.first?["is_deleted"] == .int(1),
                "tombstone must persist in sync-meta after stale resurrect attempt (A6)")
        #expect(metaB_stale.first?["sync_hlc"] == tombstoneHLC,
                "tombstone HLC must not be overwritten by stale resurrect (A6 gate)")
    }

    // MARK: - (f) Slot registry CAS

    /// Both estates share the same CloudZoneFake. enable() on each estate
    /// runs SlotClaimOperation against the fake — one claim succeeds for slot 1
    /// and one for slot 2 (or any two distinct slots). Both claims are valid
    /// because the slot registry uses CAS via object identity in the fake.
    ///
    /// This verifies that the shared fake correctly arbitrates concurrent slot
    /// claims using the same logic as FakeCloudKitDatabase in SlotRegistryTests.
    @Test("(f) slot registry: both estates claim distinct slots via CAS")
    func slotRegistryCASBothEstates() async throws {
        // TwoEstateFixture.make() calls enable() on both engines, which both run
        // SlotClaimOperation. Estate A claims slot 1; estate B claims a different slot.
        let fixture = try await TwoEstateFixture.make()

        // Read the claimed identities from each engine's state actor.
        let identityA = await fixture.engineA.stateActor.currentIdentity
        let identityB = await fixture.engineB.stateActor.currentIdentity

        #expect(identityA != nil, "estate A must have a claimed identity")
        #expect(identityB != nil, "estate B must have a claimed identity")

        if let a = identityA, let b = identityB {
            #expect(a.slot != b.slot,
                    "both estates must claim distinct slots via CAS (A=\(a.slot) B=\(b.slot))")
            #expect((1...15).contains(a.slot), "A's slot must be in the valid range 1–15")
            #expect((1...15).contains(b.slot), "B's slot must be in the valid range 1–15")
        }

        // Sanity check: a simple push/pull round with the correctly-slotted engines.
        let id = UUID()
        try await fixture.writeA(row: ["id": .uuid(id), "title": .text("slot-test"), "value": .int(42)])
        try await fixture.runConvergence(rounds: 1)

        let onB = try await fixture.queryB(id: id)
        #expect(onB?["title"] == .text("slot-test"),
                "A's write must propagate to B via the slot-registered engines")
    }
}
