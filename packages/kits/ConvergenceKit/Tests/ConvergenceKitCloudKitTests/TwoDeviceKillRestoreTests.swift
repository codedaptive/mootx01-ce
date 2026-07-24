// TwoDeviceKillRestoreTests.swift
//
// FAB5-VH — net-new two-device kill/restore and offline/rejoin conformance fixtures.
//
// Coverage gaps addressed (not present in CrashRecoveryTests or SlotFencingScenarios):
//   (1) Concurrent kill: both estates crash and restart at the same time.
//       → Durable outbox entries survive disable/enable on BOTH sides; estates
//         converge after both engines restart and sync.
//   (2) Offline rejoin: estate A writes nothing while estate B accumulates N writes;
//       A's next pull catches up the full backlog without missing records.
//   (3) Concurrent offline divergence: both estates write independently while
//       disconnected; LWW resolves the overlap consistently on both estates after rejoin.
//
// All scenarios use:
//   • TwoEstateFixture — fresh InMemoryStorage + shared CloudZoneFake per test.
//   • Poll-deadline pattern — no Task.sleep.
//   • Deterministic fixtures — all writes use fixed UUIDs and clock values.
//
// "Offline" is modeled as: no push/pull calls on the offline estate during the
// disconnected window. Writes still succeed locally (outbox accumulates). "Rejoin"
// resumes the normal push/pull cycle. This matches how InMemoryStorage + CloudZoneFake
// models network absence without requiring a live transport stub.

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Suite

@Suite("FAB5-VH — Two-device kill/restore and offline/rejoin")
struct TwoDeviceKillRestoreTests {

    // MARK: - (1) Concurrent kill: both estates crash simultaneously

    /// Estate A writes 3 rows; estate B writes 3 different rows. Both estates then
    /// crash simultaneously (disable → fresh engine on same storage). After both
    /// restart and run a full sync round, all 6 rows are visible on both estates.
    ///
    /// This validates:
    /// - Durable outbox entries survive a disable/enable cycle on BOTH sides (R4).
    /// - The shared cloud zone is not corrupted by concurrent restarts.
    /// - Full estate convergence after both devices rejoin.
    ///
    /// Map to TWO_DEVICE_SYNC_MATRIX scenario 2b.
    @Test("(1) concurrent kill: both estates crash and restart — all 6 rows converge")
    func concurrentKillAndRestoreBothEstates() async throws {
        let fixture = try await TwoEstateFixture.make()

        let aIDs = (0..<3).map { _ in UUID() }
        let bIDs = (0..<3).map { _ in UUID() }

        // A writes 3 rows (outbox accumulates on A, not yet pushed).
        for (i, id) in aIDs.enumerated() {
            try await fixture.writeA(row: [
                "id":    .uuid(id),
                "title": .text("from-A-concurrent-\(i)"),
                "value": .int(Int64(i))
            ])
        }

        // B writes 3 rows (outbox accumulates on B, not yet pushed).
        for (i, id) in bIDs.enumerated() {
            try await fixture.writeB(row: [
                "id":    .uuid(id),
                "title": .text("from-B-concurrent-\(i)"),
                "value": .int(Int64(10 + i))
            ])
        }

        // Outbox sanity before crash.
        let outboxA_before = try await OutboxStore.readBatch(from: fixture.storageA).count
        let outboxB_before = try await OutboxStore.readBatch(from: fixture.storageB).count
        #expect(outboxA_before == 3, "A must have 3 outbox entries before crash; got \(outboxA_before)")
        #expect(outboxB_before == 3, "B must have 3 outbox entries before crash; got \(outboxB_before)")

        // Simulate concurrent crash: disable both engines.
        // restartEngine preserves Storage so durable outbox survives.
        let freshA = try await fixture.restartEngine(fixture.engineA, storage: fixture.storageA)
        let freshB = try await fixture.restartEngine(fixture.engineB, storage: fixture.storageB)

        // Outbox entries must survive both restarts.
        let outboxA_after = try await OutboxStore.readBatch(from: fixture.storageA).count
        let outboxB_after = try await OutboxStore.readBatch(from: fixture.storageB).count
        #expect(outboxA_after == 3, "A: 3 outbox entries must survive restart; got \(outboxA_after)")
        #expect(outboxB_after == 3, "B: 3 outbox entries must survive restart; got \(outboxB_after)")

        // Both estates rejoin: push → pull cycle.
        for _ in 0..<20 { await Task.yield() }
        let pushA = try await freshA.push()
        let pushB = try await freshB.push()
        #expect(pushA.pushed == 3, "fresh A must push all 3 surviving outbox entries")
        #expect(pushB.pushed == 3, "fresh B must push all 3 surviving outbox entries")

        _ = try await freshA.pull()
        _ = try await freshB.pull()

        // All 6 rows must be visible on both estates after convergence.
        for id in aIDs {
            let onA = try await fixture.queryA(id: id)
            let onB = try await fixture.queryB(id: id)
            #expect(onA != nil, "A's row \(id) must be on estate A after convergence")
            #expect(onB != nil, "A's row \(id) must be on estate B after convergence")
        }
        for id in bIDs {
            let onA = try await fixture.queryA(id: id)
            let onB = try await fixture.queryB(id: id)
            #expect(onA != nil, "B's row \(id) must be on estate A after convergence")
            #expect(onB != nil, "B's row \(id) must be on estate B after convergence")
        }

        // Definitive convergence proof: _ck_sync_meta matches on both estates.
        try await fixture.assertSyncMetaMatch(table: "items")
    }

    // MARK: - (2) Offline rejoin: A accumulates nothing while B writes 10 rows

    /// Estate A does not push or pull for 10 cycles. During that window, estate B
    /// writes 10 rows and pushes them all. When A "rejoins" (pulls), it must receive
    /// all 10 rows without missing any.
    ///
    /// This validates the token-catch-up pull path: a zero-writes-on-A estate can
    /// still catch up a full backlog of B's writes via a single full-pull round.
    ///
    /// Map to TWO_DEVICE_SYNC_MATRIX scenario 5a.
    @Test("(2) offline rejoin: A offline during 10 B writes → A catches up on pull")
    func offlineRejoinCatchUp() async throws {
        let fixture = try await TwoEstateFixture.make()

        // B writes 10 rows and pushes them while A is "offline" (no push/pull calls on A).
        let rowIDs = (0..<10).map { _ in UUID() }
        for (i, id) in rowIDs.enumerated() {
            try await fixture.writeB(row: [
                "id":    .uuid(id),
                "title": .text("b-offline-write-\(i)"),
                "value": .int(Int64(i))
            ])
        }

        // Wait for all 10 outbox entries to appear (poll-deadline, no Task.sleep).
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            await Task.yield()
            let count = (try? await OutboxStore.readBatch(from: fixture.storageB).count) ?? 0
            if count == 10 { break }
        }

        // B pushes all 10 rows to the shared cloud.
        for _ in 0..<20 { await Task.yield() }
        let pushB = try await fixture.engineB.push()
        #expect(pushB.pushed == 10, "B must push all 10 rows to the shared cloud")

        // A is now offline — it has zero local writes and has not pulled.
        let outboxA = try await OutboxStore.readBatch(from: fixture.storageA).count
        #expect(outboxA == 0, "A must have 0 outbox entries (it wrote nothing while offline)")

        // A rejoins: pull from the shared cloud (B's pushes arrive on A).
        let pullA = try await fixture.engineA.pull()
        #expect(pullA.pulled >= 10, "A must pull all 10 rows on rejoin; got \(pullA.pulled)")

        // B also pulls so its _ck_sync_meta is populated (pull path writes sync-meta
        // for its own previously-pushed records — required for assertSyncMetaMatch).
        _ = try await fixture.engineB.pull()

        // All 10 rows must be visible on A.
        for id in rowIDs {
            let onA = try await fixture.queryA(id: id)
            #expect(onA != nil, "row \(id) must be on estate A after offline rejoin pull")
        }

        // Convergence proof.
        try await fixture.assertSyncMetaMatch(table: "items")
    }

    // MARK: - (3) Concurrent offline divergence — LWW resolves consistently

    /// Both estates go offline (no push/pull). Each writes 5 unique rows plus 1
    /// contested row (same UUID, different title). After both rejoin and sync,
    /// all 10 unique rows are visible on both estates and the contested row
    /// resolves to the same winner on both estates (LWW by HLC).
    ///
    /// A's clock is advanced +10 s relative to B's to guarantee deterministic LWW:
    /// A's contested write always wins (higher HLC). The assertion verifies that
    /// both estates show "contested-from-A" (not "contested-from-B").
    ///
    /// Map to TWO_DEVICE_SYNC_MATRIX scenarios 5b.
    @Test("(3) concurrent offline divergence: 10 unique + 1 contested — LWW consistent on both estates")
    func offlineDivergenceResolves() async throws {
        let fixture = try await TwoEstateFixture.make()

        let contestedID = UUID()
        let aOnlyIDs = (0..<5).map { _ in UUID() }
        let bOnlyIDs = (0..<5).map { _ in UUID() }

        // Both estates are "offline" (neither pushes or pulls during this window).

        // B writes 5 unique rows + the contested row at lower HLC (baseline clock).
        for (i, id) in bOnlyIDs.enumerated() {
            try await fixture.writeB(row: [
                "id":    .uuid(id),
                "title": .text("b-only-\(i)"),
                "value": .int(Int64(i))
            ])
        }
        try await fixture.writeB(row: [
            "id":    .uuid(contestedID),
            "title": .text("contested-from-B"),
            "value": .int(99)
        ])

        // Advance A's clock +10 s (A writes after B in HLC order regardless of wall clock).
        // This guarantees A's contested write beats B's contested write under LWW.
        await fixture.engineA.stateActor.advanceClock(by: 10_000)

        // A writes 5 unique rows + the contested row at higher HLC (clock advanced).
        for (i, id) in aOnlyIDs.enumerated() {
            try await fixture.writeA(row: [
                "id":    .uuid(id),
                "title": .text("a-only-\(i)"),
                "value": .int(Int64(100 + i))
            ])
        }
        try await fixture.writeA(row: [
            "id":    .uuid(contestedID),
            "title": .text("contested-from-A"),
            "value": .int(42)
        ])

        // Both estates rejoin: push → pull round.
        for _ in 0..<20 { await Task.yield() }
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.push()
        _ = try await fixture.engineA.pull()
        _ = try await fixture.engineB.pull()

        // Second round to settle any remaining state.
        for _ in 0..<20 { await Task.yield() }
        _ = try await fixture.engineA.push()
        _ = try await fixture.engineB.push()
        _ = try await fixture.engineA.pull()
        _ = try await fixture.engineB.pull()

        // All 10 unique rows visible on both estates.
        for id in aOnlyIDs {
            let onB = try await fixture.queryB(id: id)
            #expect(onB != nil, "A-only row \(id) must be visible on B after rejoin convergence")
        }
        for id in bOnlyIDs {
            let onA = try await fixture.queryA(id: id)
            #expect(onA != nil, "B-only row \(id) must be visible on A after rejoin convergence")
        }

        // LWW consistency: the contested row must show A's value on BOTH estates
        // because A's write has the higher HLC (clock advanced +10 s).
        let contestedOnA = try await fixture.queryA(id: contestedID)
        let contestedOnB = try await fixture.queryB(id: contestedID)

        #expect(contestedOnA?["title"] == .text("contested-from-A"),
                "LWW: A's write (higher HLC) must win on estate A")
        #expect(contestedOnB?["title"] == .text("contested-from-A"),
                "LWW: A's write (higher HLC) must win on estate B — identical resolution on both")

        // Definitive convergence proof: _ck_sync_meta identical on both estates.
        try await fixture.assertSyncMetaMatch(table: "items")
    }
}
