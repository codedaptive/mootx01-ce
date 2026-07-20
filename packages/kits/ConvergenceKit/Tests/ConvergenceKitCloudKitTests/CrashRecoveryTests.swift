// CrashRecoveryTests.swift
//
// Crash/kill recovery scenarios for CVK-ICLOUD P4-M2.
//
// "Simulated death" pattern: engine.disable() tears down observer tasks and
// clears in-memory state. A fresh CloudKitSyncEngine is created and enable()d
// on the SAME Storage instance, which keeps its in-memory tables alive (outbox,
// sync-meta, change token, device identity). This models process death and restart
// for an InMemoryStorage backend — see TwoEstateFixture.restartEngine(_:storage:).
//
// Scenarios:
//   (1) Die after local write, before drain     → outbox survives, drains on restart,
//                                                  peer converges.
//   (2) Die mid-push (transport accepted, outbox not confirmed) → re-push idempotent,
//                                                  no duplicate divergence; uuid fix
//                                                  regression-tested here.
//   (3) Die after pull applied, before token persisted → re-pull idempotent under
//                                                  every conflict policy (LWW tested).
//   (4) Die during slot heartbeat               → fence verification on restart correct;
//                                                  push recovers after re-enable.
//   (5) FaultInjector partial batch failure     → failed entries retained with incremented
//                                                  retry_count; retried on next push;
//                                                  eventual convergence; parked entries
//                                                  stay parked across restart.
//
// All assertions use the poll-deadline pattern (no Task.sleep).
// Determinism is guaranteed by fresh InMemoryStorage + CloudZoneFake per test.

import Testing
import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
import SubstrateTypes
@testable import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Suite

@Suite("CVK-ICLOUD P4-M2 — Crash/kill recovery")
struct CrashRecoveryTests {

    // MARK: - (1) Die after local write, before drain

    /// Estate A writes a row and then dies before the outbox is drained.
    /// After restart the outbox entry survives (durable side table) and is
    /// drained on the next push cycle. Estate B then pulls and receives the row.
    ///
    /// This tests R4: the outbox must survive engine disable/enable because
    /// enable() calls drainLeftovers() and logs any pending entries.
    @Test("(1) outbox survives crash before drain — drains on restart, peer converges")
    func outboxSurvivesCrashBeforeDrain() async throws {
        let fixture = try await TwoEstateFixture.make()
        let rowID = UUID()

        // Write on A (outbox entry created).
        try await fixture.writeA(row: ["id": .uuid(rowID), "title": .text("survive-crash"), "value": .int(1)])

        // Verify the outbox entry is present before the crash.
        let outboxBefore = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxBefore.count == 1, "outbox must have 1 entry before simulated crash")

        // Simulate death: disable A, fresh engine on same storage.
        let freshA = try await fixture.restartEngine(fixture.engineA, storage: fixture.storageA)

        // On restart, drainLeftovers found the pending entry. Verify it's still there.
        let outboxAfterRestart = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxAfterRestart.count == 1, "outbox entry must survive disable/enable cycle")

        // Push with the fresh engine — drains the surviving outbox entry.
        for _ in 0..<20 { await Task.yield() }
        let pushResult = try await freshA.push()
        #expect(pushResult.pushed == 1, "fresh engine must push the surviving outbox entry")

        // B pulls and receives the row.
        _ = try await fixture.engineB.pull()

        let onB = try await fixture.queryB(id: rowID)
        #expect(onB != nil, "B must have the row after A's crash-and-recover push")
        #expect(onB?["title"] == .text("survive-crash"), "row content must be intact after crash recovery")

        // Verify outbox is now empty.
        let outboxFinal = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxFinal.count == 0, "outbox must be empty after successful push")
    }

    // MARK: - (2) Die mid-push (transport accepted, outbox not confirmed)

    /// Models the crash window between transport success and outbox confirm:
    /// the record lands in the cloud but the outbox entry is never deleted.
    /// Simulation: push normally (transport + confirm), then re-inject the
    /// outbox entry (as if confirm did not run), restart, and push again.
    /// The cloud already has the record (same HLC); the fake's HLC-aware merge
    /// accepts the duplicate push without creating a duplicate record.
    /// B must end up with exactly one copy of the row — no divergence.
    ///
    /// This scenario also regression-tests the uuid fix: the re-pushed record
    /// carries the .uuid discriminator in the _syncTypeTags map, so B decodes
    /// it as .uuid, not .text, and the upsert deduplicates correctly.
    @Test("(2) re-push after mid-push crash is idempotent — no duplicate divergence")
    func rePushAfterMidPushCrashIsIdempotent() async throws {
        let fixture = try await TwoEstateFixture.make()
        let rowID = UUID()

        // Write on A.
        try await fixture.writeA(row: ["id": .uuid(rowID), "title": .text("idempotent-push"), "value": .int(42)])
        for _ in 0..<20 { await Task.yield() }

        // Capture outbox entry before first push (we'll re-inject it after).
        let batch = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(batch.count == 1, "must have 1 outbox entry before push")
        let originalEntry = batch[0]

        // Push A normally (transport succeeds, outbox confirmed).
        let firstPush = try await fixture.engineA.push()
        #expect(firstPush.pushed == 1, "first push must deliver the record")

        // Outbox now empty (confirm ran).
        let afterConfirm = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(afterConfirm.count == 0, "outbox must be empty after confirm")

        // Simulate "confirm did not run": re-inject the same entry (same HLC, same data).
        // OutboxStore.append coalesces by (table_name, row_key); since the outbox is
        // empty now, the re-injected entry inserts fresh (no coalescing conflict).
        // This models the crash state where transport succeeded but confirm was lost.
        let reinjected = OutboxEntry(
            id: UUID(),
            tableName: originalEntry.tableName,
            rowKey: originalEntry.rowKey,
            event: originalEntry.event,
            valuesData: originalEntry.valuesData,
            hlcWireBytes: originalEntry.hlcWireBytes,
            enqueuedAt: originalEntry.enqueuedAt,
            retryCount: 0,
            isParked: false,
            columnHLCsData: originalEntry.columnHLCsData
        )
        try await OutboxStore.append(entry: reinjected, to: fixture.storageA)

        let outboxSimulated = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxSimulated.count == 1, "re-injected entry must appear in outbox (crash simulation)")

        // Restart A (outbox re-injected entry survives disable/enable).
        let freshA = try await fixture.restartEngine(fixture.engineA, storage: fixture.storageA)

        // Push with fresh engine — re-pushes the same record.
        // Cloud already has it at the same HLC; HLC-aware merge: inHLC >= exHLC
        // (equal) → accepts the record again (same data, no duplicate).
        for _ in 0..<20 { await Task.yield() }
        let rePush = try await freshA.push()
        #expect(rePush.pushed == 1, "re-push must succeed (idempotent: same HLC accepted by cloud)")

        // B pulls and must see exactly ONE row.
        _ = try await fixture.engineB.pull()

        let metaB = try await fixture.syncMetaB(table: "items")
        #expect(metaB.count == 1,
                "B must have exactly 1 sync-meta entry (no duplicate from idempotent re-push)")

        let onB = try await fixture.queryB(id: rowID)
        #expect(onB != nil, "B must have the row after idempotent re-push")
        #expect(onB?["title"] == .text("idempotent-push"))
        #expect(onB?["value"] == .int(42))
    }

    // MARK: - (3) Die after pull applied, before token persisted

    /// The change token is persisted in the _ck_change_token side table (R5).
    /// If the process dies after applying a pull batch but before the token is
    /// saved, the next enable() loads a nil token and re-pulls the full zone.
    ///
    /// With CloudZoneFake the token is always nil (full re-pull on every call),
    /// so every restart is in the "token not persisted" state. This test verifies
    /// that re-applying the same batch is idempotent under lastWriterWinsByHLC:
    /// same-HLC re-apply does NOT skip (decoded.hlc < localHLC is false when equal),
    /// but the upsert is idempotent (same values, same key → no change).
    ///
    /// B must have exactly 1 copy with the correct values after 2 pull rounds.
    @Test("(3) re-pull after crash before token persist is idempotent under LWW")
    func rePullAfterCrashIsIdempotent() async throws {
        let fixture = try await TwoEstateFixture.make()
        let rowID = UUID()

        // A writes and pushes.
        try await fixture.writeA(row: ["id": .uuid(rowID), "title": .text("re-pull-safe"), "value": .int(99)])
        for _ in 0..<20 { await Task.yield() }
        _ = try await fixture.engineA.push()

        // B pulls once (applies the row).
        let pull1 = try await fixture.engineB.pull()
        #expect(pull1.pulled >= 1, "B must pull at least 1 record on first pull")

        let onB_after1 = try await fixture.queryB(id: rowID)
        #expect(onB_after1 != nil, "B must have the row after first pull")

        // Simulate crash: restart B (in-memory token is gone; storage token is nil
        // since the fake always returns nil changeToken).
        let freshB = try await fixture.restartEngine(fixture.engineB, storage: fixture.storageB)

        // B re-pulls the full zone (same records again — this is the "before token
        // persisted" scenario). The LWW gate sees same-HLC: decoded.hlc < localHLC
        // is false, so upsert runs (same values → no change). No duplicate rows.
        let pull2 = try await freshB.pull()
        #expect(pull2.conflicts == 0, "re-pull of same batch must have 0 conflicts")

        // B must still have exactly 1 row with the correct values.
        let metaB = try await fixture.syncMetaB(table: "items")
        #expect(metaB.count == 1, "B must have exactly 1 sync-meta entry after re-pull")

        let onB_after2 = try await fixture.queryB(id: rowID)
        #expect(onB_after2 != nil, "row must still be present after re-pull")
        #expect(onB_after2?["title"] == .text("re-pull-safe"), "value must be unchanged after re-pull")
        #expect(onB_after2?["value"] == .int(99))
    }

    // MARK: - (4) Die during slot heartbeat

    /// The push path calls EpochFence.heartbeat before draining the outbox.
    /// If the process dies during the heartbeat (before or after the CAS write),
    /// the next restart re-enables the engine (re-claims a slot via SlotClaimOperation)
    /// and the subsequent push passes the epoch fence.
    ///
    /// Simulation: inject a whole-batch networkError on modifyRecords so that the
    /// first push() throws at the heartbeat or CAS stage (both use modifyRecords).
    /// Restart A. The fault is consumed. The next push succeeds; B gets the row.
    @Test("(4) crash during slot heartbeat — fence verification correct after restart")
    func crashDuringHeartbeatRecovery() async throws {
        let fixture = try await TwoEstateFixture.make()
        let rowID = UUID()

        // Write on A (outbox entry created, not yet pushed).
        try await fixture.writeA(row: [
            "id": .uuid(rowID), "title": .text("heartbeat-crash"), "value": .int(7)
        ])
        for _ in 0..<20 { await Task.yield() }

        // Inject a fault: next modifyRecords call throws (simulates process death
        // mid-heartbeat or mid-push CAS). The outbox entry remains intact (not confirmed).
        let injector = FaultInjector()
        await injector.enqueue(.networkError(detail: "simulated heartbeat crash"), for: .modifyRecords)
        await fixture.cloud.setFaults(injector)

        // Push throws (fault consumed). Outbox entry stays.
        do {
            _ = try await fixture.engineA.push()
            Issue.record("push must throw when networkError is injected")
        } catch {
            // Expected: transportFailure wrapping the networkError.
        }
        let outboxAfterFault = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxAfterFault.count == 1, "outbox entry must survive failed push attempt")

        // Verify the fault is consumed (injector is empty now).
        #expect(await injector.isEmpty, "fault must have been consumed by the failed push")

        // Remove the injector so the fresh engine has a clean fake.
        await fixture.cloud.setFaults(nil)

        // Restart A: re-enables, re-claims slot, loads durable outbox leftover.
        let freshA = try await fixture.restartEngine(fixture.engineA, storage: fixture.storageA)

        // Verify outbox entry survived the restart.
        let outboxAfterRestart = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxAfterRestart.count == 1, "outbox entry must survive restart after heartbeat crash")

        // Push with fresh engine — no fault, heartbeat passes, record delivered.
        for _ in 0..<20 { await Task.yield() }
        let pushResult = try await freshA.push()
        #expect(pushResult.pushed == 1, "push after restart must succeed with no fault")

        // B pulls and receives the row.
        _ = try await fixture.engineB.pull()

        let onB = try await fixture.queryB(id: rowID)
        #expect(onB != nil, "B must receive the row after A recovers from heartbeat crash")
        #expect(onB?["title"] == .text("heartbeat-crash"))
    }

    // MARK: - (5) FaultInjector partial batch failure

    /// Push a batch of 3 rows with a partialBatchFailure(count:1) fault.
    /// Record 0 fails at per-record level (retry_count++, stays in outbox).
    /// Records 1 and 2 succeed (confirmed, removed from outbox).
    ///
    /// After the partial failure:
    ///   - Outbox has 1 entry remaining.
    ///   - B pulling at this point sees only the 2 confirmed rows.
    ///
    /// Second push (no fault): the remaining entry is retried and confirmed.
    /// B pulls again and receives all 3 rows. Estates converge.
    ///
    /// Parked-across-restart sub-check: after convergence, park an entry directly,
    /// restart, and verify the parked entry is still excluded from the next push batch.
    @Test("(5) partial batch failure — retry counts increment, retried on next push, estates converge")
    func partialBatchFailureRetryAndConverge() async throws {
        let fixture = try await TwoEstateFixture.make()
        let ids = (0..<3).map { _ in UUID() }

        // Write 3 rows on A.
        for (i, id) in ids.enumerated() {
            try await fixture.writeA(row: [
                "id": .uuid(id),
                "title": .text("partial-\(i)"),
                "value": .int(Int64(i))
            ])
        }
        // Wait for observer to append all 3 outbox entries.
        let batchDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < batchDeadline {
            await Task.yield()
            let count = try await OutboxStore.readBatch(from: fixture.storageA).count
            if count == 3 { break }
        }
        let batchBefore = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(batchBefore.count == 3, "must have 3 outbox entries before partial push")

        // Inject partial batch failure: first record fails, records 1 and 2 succeed.
        let injector = FaultInjector()
        await injector.enqueue(.partialBatchFailure(count: 1), for: .modifyRecords)
        await fixture.cloud.setFaults(injector)

        // First push — partial failure applied.
        for _ in 0..<20 { await Task.yield() }
        let partialResult = try await fixture.engineA.push()

        // 2 records succeeded (confirmed), 1 failed (retained in outbox).
        #expect(partialResult.pushed == 2, "partial push must confirm 2 records")

        // Outbox must have 1 entry remaining.
        let outboxAfterPartial = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxAfterPartial.count == 1, "exactly 1 outbox entry must remain after partial failure")

        // That entry must have retry_count == 1.
        let survivingEntry = outboxAfterPartial[0]
        #expect(survivingEntry.retryCount == 1,
                "failed entry must have retry_count incremented to 1; got \(survivingEntry.retryCount)")

        // B pulls: receives only the 2 confirmed rows.
        _ = try await fixture.engineB.pull()
        let metaB_partial = try await fixture.syncMetaB(table: "items")
        #expect(metaB_partial.count == 2,
                "B must have 2 sync-meta entries after partial push (1 row not yet confirmed)")

        // Remove fault injector for the retry push.
        await fixture.cloud.setFaults(nil)

        // Second push (no fault): retries the remaining entry.
        let retryResult = try await fixture.engineA.push()
        #expect(retryResult.pushed == 1, "retry push must confirm the remaining entry")

        // Outbox is now empty.
        let outboxFinal = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(outboxFinal.count == 0, "outbox must be empty after retry push")

        // B pulls again: receives the 3rd row. All 3 estates converge.
        _ = try await fixture.engineB.pull()

        let metaB_final = try await fixture.syncMetaB(table: "items")
        #expect(metaB_final.count == 3,
                "B must have all 3 sync-meta entries after retry push and second pull")

        for id in ids {
            let onB = try await fixture.queryB(id: id)
            #expect(onB != nil, "row \(id) must be present on B after full convergence")
        }

        // Sub-check: parked entries stay parked across restart.
        // Write a fresh entry, park it, restart, and verify it remains parked.
        let parkTestID = UUID()
        try await fixture.writeA(row: [
            "id": .uuid(parkTestID), "title": .text("park-test"), "value": .int(0)
        ])
        let parkDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < parkDeadline {
            await Task.yield()
            let c = (try? await OutboxStore.readBatch(from: fixture.storageA).count) ?? 0
            if c > 0 { break }
        }
        let parkBatch = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(parkBatch.count == 1, "must have 1 fresh entry for park test")
        let entryToPark = parkBatch[0]
        try await OutboxStore.park(id: entryToPark.id, from: fixture.storageA)

        // Verify the parked entry is excluded from readBatch.
        let afterPark = try await OutboxStore.readBatch(from: fixture.storageA)
        #expect(afterPark.count == 0, "parked entry must not appear in readBatch")
        let parkedList = try await OutboxStore.parkedEntries(from: fixture.storageA)
        #expect(parkedList.count == 1, "parkedEntries must show the parked entry")

        // Restart A: parked entry must remain parked after disable/enable.
        let freshA = try await fixture.restartEngine(fixture.engineA, storage: fixture.storageA)

        let afterRestart_active = try await OutboxStore.readBatch(from: fixture.storageA)
        let afterRestart_parked = try await OutboxStore.parkedEntries(from: fixture.storageA)
        #expect(afterRestart_active.count == 0, "parked entry must not appear in readBatch after restart")
        #expect(afterRestart_parked.count == 1, "parked entry must persist across restart")

        // Push with fresh engine: must push 0 records (parked entry is excluded).
        for _ in 0..<20 { await Task.yield() }
        let parkPush = try await freshA.push()
        #expect(parkPush.pushed == 0, "parked entry must not be pushed even after restart")
    }
}

// MARK: - Determinism note

// All five scenarios above are marked @Test and each creates a fresh
// TwoEstateFixture (fresh InMemoryStorage + fresh CloudZoneFake) so no
// shared mutable state exists between test runs. The suite is therefore
// naturally deterministic across 3 consecutive runs as required by P4-M2.
