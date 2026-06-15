// TraceRewardWiringTests.swift
//
// Coverage for trace-reward wiring (TASK-F2) and B-10a enforcement.
//
// Tests:
//  1. markRecallUsed flips used bits — recall then markRecallUsed; reward sweep sees 1.0
//  2. Unused recall-trace row returns reward 0.0 from reward sweep
//  3. markRecallUsed on an unknown target returns 0 (no crash)
//  4. B-10a conformance — internal GLKRecallRequest writes ZERO trace rows
//     (SQLite-backed estate; NeuronKit recentRecallTraces returns empty)
//  5. External-origin GLKRecallRequest does write trace rows
//  6. countRecallTraces returns the accumulated trace count across recalls
//  7. markRecallUsed + reward sweep: 1.0 for used, 0.0 for unused (mixed case)

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import GeniusLocusKit

// MARK: - Helpers

/// Open an estate on an InMemory backend (fast; covers most round-trips).
private func openInMemory() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "owner-trace-reward-wiring")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle)
}

/// Open an estate on a SQLite-backed temporary file (required for B-10a test
/// because InMemory recall traces are ephemeral and test 4 needs a real
/// persistent store to confirm zero rows).
private func openSQLite() async throws -> (GeniusLocusKit, EstateHandle, URL) {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("trace-reward-test-\(UUID().uuidString).sqlite")
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "owner-trace-reward-sqlite")
    let config = EstateConfiguration(estateID: UUID(), backend: .sqlite(url: tmp))
    let storage = try SQLiteStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle, tmp)
}

/// Capture one drawer into the estate and return the resulting Drawer.
private func captureOne(
    kit: GeniusLocusKit,
    handle: EstateHandle,
    content: String = "trace reward test content"
) async throws -> Drawer {
    let frame = CaptureFrame(
        content: content,
        channel: .typed,
        room: "trace-reward-room",
        latticeAnchor: .udc("000.000"),
        addedBy: "trace-reward-tests",
        embeddingModelID: "test-model-v1"
    )
    return try await kit.capture(handle, frame)
}

// MARK: - Suite

@Suite("Trace-reward wiring (TASK-F2)")
struct TraceRewardWiringTests {

    // MARK: §1 markRecallUsed flips used bits

    @Test("markRecallUsed: reward sweep sees 1.0 for a used trace row")
    func markRecallUsedFlipsUsedBit() async throws {
        let (kit, handle) = try await openInMemory()
        let drawer = try await captureOne(kit: kit, handle: handle)
        // Capture `before` prior to the recall so `recalledAt` falls in [before, now].
        let before = Date()

        // Recall with external origin so trace rows are written.
        let frame = RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured, limit: 10, traceLimit: 10)
        let req = GLKRecallRequest(frame: frame, mode: .locusOnly, origin: .external)
        _ = try await kit.recall(handle, req)

        // `now` is after the recall so the trace's recalledAt falls in the window.
        let now = Date()

        // Confirm at least one trace row exists.
        let countBefore = try await kit.countRecallTraces(handle)
        #expect(countBefore > 0, "expected trace rows after external recall")

        // Mark the drawer as used.
        let marked = try await kit.markRecallUsed(handle, target: drawer.id, now: now)
        #expect(marked > 0, "expected at least one row to be marked used")

        // The reward sweep reads recent traces; used rows should yield reward 1.0.
        let since = before.addingTimeInterval(-(30 * 24 * 60 * 60))
        let traces = try await kit.recentRecallTraces(in: handle, since: since, now: now)
        let relevant = traces.filter { $0.target == drawer.id }
        #expect(!relevant.isEmpty, "expected at least one trace for the recalled drawer")
        for trace in relevant {
            #expect(trace.used, "all traces for a used drawer must have used=true")
        }
    }

    // MARK: §2 Unused trace row yields reward 0.0

    @Test("markRecallUsed: unacted drawer trace remains used=false")
    func unusedTraceRemainsUnused() async throws {
        let (kit, handle) = try await openInMemory()
        let drawer = try await captureOne(kit: kit, handle: handle)
        let before = Date()

        // Recall with external origin so trace rows are written.
        let frame = RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured, limit: 10, traceLimit: 10)
        let req = GLKRecallRequest(frame: frame, mode: .locusOnly, origin: .external)
        _ = try await kit.recall(handle, req)

        // `now` after recall so recalledAt falls in the query window.
        let now = Date()
        // Do NOT call markRecallUsed — the trace stays unused.
        let since = before.addingTimeInterval(-(30 * 24 * 60 * 60))
        let traces = try await kit.recentRecallTraces(in: handle, since: since, now: now)
        let relevant = traces.filter { $0.target == drawer.id }
        #expect(!relevant.isEmpty, "expected trace rows for the recalled drawer")
        for trace in relevant {
            #expect(!trace.used, "unused drawer traces must have used=false (reward 0.0)")
        }
    }

    // MARK: §3 Unknown target returns 0

    @Test("markRecallUsed: unknown target returns 0 rows, no crash")
    func unknownTargetReturnsZero() async throws {
        let (kit, handle) = try await openInMemory()
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let marked = try await kit.markRecallUsed(handle, target: "no-such-drawer-id", now: now)
        #expect(marked == 0)
    }

    // MARK: §4 B-10a conformance — internal recall writes ZERO trace rows

    @Test("B-10a: internal GLKRecallRequest writes zero recall-trace rows (SQLite-backed)")
    func internalRecallWritesZeroTraceRows() async throws {
        let (kit, handle, tmp) = try await openSQLite()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let now = Date(timeIntervalSinceReferenceDate: 4_000_000)

        // Capture one drawer so recall has something to return.
        _ = try await captureOne(kit: kit, handle: handle)

        // Recall with default (internal) origin — must not write trace rows.
        let frame = RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured, limit: 10)
        let req = GLKRecallRequest(frame: frame, mode: .locusOnly) // origin defaults to .internal
        let results = try await kit.recall(handle, req)
        #expect(!results.hits.isEmpty, "internal recall should still return rows")

        // Confirmed: no trace rows written.
        let count = try await kit.countRecallTraces(handle)
        #expect(count == 0, "B-10a violation: internal recall wrote \(count) trace rows (expected 0)")
    }

    // MARK: §5 External origin does write trace rows

    @Test("External GLKRecallRequest writes recall-trace rows")
    func externalRecallWritesTraceRows() async throws {
        let (kit, handle) = try await openInMemory()
        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)

        _ = try await captureOne(kit: kit, handle: handle)

        let frame = RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured, limit: 10, traceLimit: 10)
        let req = GLKRecallRequest(frame: frame, mode: .locusOnly, origin: .external)
        let results = try await kit.recall(handle, req)
        #expect(!results.hits.isEmpty, "external recall should return rows")

        let count = try await kit.countRecallTraces(handle)
        #expect(count > 0, "external recall must write trace rows (count=\(count))")
    }

    // MARK: §6 countRecallTraces accumulates

    @Test("countRecallTraces increases with each external recall")
    func countRecallTracesAccumulates() async throws {
        let (kit, handle) = try await openInMemory()

        _ = try await captureOne(kit: kit, handle: handle)

        let frame = RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured, limit: 10, traceLimit: 10)
        let req = GLKRecallRequest(frame: frame, mode: .locusOnly, origin: .external)

        // Two separate external recalls — should accumulate trace rows.
        _ = try await kit.recall(handle, req)
        let countAfterFirst = try await kit.countRecallTraces(handle)
        _ = try await kit.recall(handle, req)
        let countAfterSecond = try await kit.countRecallTraces(handle)

        #expect(countAfterFirst > 0)
        #expect(countAfterSecond >= countAfterFirst,
            "trace row count must not decrease: first=\(countAfterFirst) second=\(countAfterSecond)")
    }

    // MARK: §7 Mixed used/unused reward signals

    @Test("Reward sweep: 1.0 for used drawer, 0.0 for unused drawer (mixed estate)")
    func mixedRewardSignals() async throws {
        let (kit, handle) = try await openInMemory()
        let before = Date()

        let used = try await captureOne(kit: kit, handle: handle, content: "used drawer content")
        let unused = try await captureOne(kit: kit, handle: handle, content: "unused drawer content")

        // Recall both drawers with external origin.
        let frame = RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured, limit: 10, traceLimit: 10)
        let req = GLKRecallRequest(frame: frame, mode: .locusOnly, origin: .external)
        _ = try await kit.recall(handle, req)

        // `now` after the recall so all recalledAt timestamps fall in the window.
        let now = Date()
        // Mark only `used` as acted-upon.
        let markedCount = try await kit.markRecallUsed(handle, target: used.id, now: now)
        #expect(markedCount > 0)

        // Verify reward signals.
        let since = before.addingTimeInterval(-(30 * 24 * 60 * 60))
        let traces = try await kit.recentRecallTraces(in: handle, since: since, now: now)

        let usedTraces = traces.filter { $0.target == used.id }
        let unusedTraces = traces.filter { $0.target == unused.id }

        #expect(!usedTraces.isEmpty, "must have traces for the used drawer")
        #expect(!unusedTraces.isEmpty, "must have traces for the unused drawer")

        for trace in usedTraces {
            #expect(trace.used, "used drawer traces must have used=true (reward 1.0)")
        }
        for trace in unusedTraces {
            #expect(!trace.used, "unused drawer traces must have used=false (reward 0.0)")
        }
    }
}
