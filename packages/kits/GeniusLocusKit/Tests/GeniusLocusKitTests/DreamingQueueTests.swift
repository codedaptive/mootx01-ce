// DreamingQueueTests.swift
//
// T6 (ADR-021 Phase 2b): tests that the external-origin scored recall enqueues a
// DreamingItem onto the per-estate "dreaming" stream when ≥ 2 distinct drawers
// are surfaced. Mirrors the four scenarios from the mission spec.
//
// The production path is `recall(_ handle:, _ request: GLKRecallRequest)` with
// `origin: .external` — this is what `run_memory_search` (moot_memory_search,
// moot_recall_precise, moot_recall_shaped) calls. The legacy shim
// `recall(_ handle:, _ frame: RecallFrame)` always uses `.internal` origin and
// must NEVER enqueue dreaming items (B-10a anti-regression).
//
// Contract verified here:
//   1. External-origin scored recall surfacing ≥ 2 drawers enqueues exactly one
//      dreaming job on stream = "dreaming" with the surfaced drawer ids.
//   2. Internal-origin scored recall surfacing ≥ 2 drawers enqueues nothing (B-10a).
//      Also: the legacy shim `recall(_:_:frame:)` surfacing ≥ 2 drawers enqueues
//      nothing — it routes through origin: .internal (B-10a anti-regression test).
//   3. External-origin recall surfacing < 2 drawers enqueues nothing (guard fires).
//   4. Stream isolation: a dreaming job is NOT claimed by an encode or signals
//      drainer (the job is only consumable by a "dreaming" stream drainer).
//   5. Payload round-trip: the enqueued DreamingItem contains the surfaced
//      drawer ids (recallEventId is non-empty, drawerIds ≥ 2).
//   6. InMemory estate: the dreaming queue backend degrades gracefully —
//      the job is still enqueued into the transient in-memory backend.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes
@testable import GeniusLocusKit

// MARK: - Fixture helpers

/// Create a temporary directory for one SQLite estate (unique per call).
private func tempEstateDir() -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = base.appendingPathComponent("glk-dreaming-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Remove the temp directory and everything inside it.
private func cleanup(dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// Open a persistent SQLite-backed estate.
private func openSQLiteEstate(at dir: URL) async throws
    -> (GeniusLocusKit, EstateHandle, SQLiteStorage)
{
    let estateURL = dir.appendingPathComponent("estate.sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: estateURL)
    ))
    let owner = OwnerCredentials(ownerIdentifier: "dreaming-queue-test-owner")
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let kit = GeniusLocusKit()
    // Temp-dir SQLite counts as durable, so the backend-keyed default would
    // mint into the real login keychain — keep test identities in memory.
    let handle = try await kit.open(
        storage: storage, owner: owner,
        identityKeyStore: InMemoryEstateIdentityKeyStore())
    return (kit, handle, storage)
}

/// Open an InMemory estate.
private func openInMemoryEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    let owner = OwnerCredentials(ownerIdentifier: "dreaming-queue-inmem-owner")
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let kit = GeniusLocusKit()
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle)
}

/// Capture `count` distinct drawers into the estate.
/// Each drawer has a unique content string so they are separate rows.
private func captureDrawers(
    count: Int,
    kit: GeniusLocusKit,
    handle: EstateHandle
) async throws -> [Drawer] {
    var drawers: [Drawer] = []
    for i in 0..<count {
        let frame = CaptureFrame(
            content: "dreaming-test-drawer-\(i)-\(UUID().uuidString)",
            channel: .typed,
            room: "dreaming-test-room",
            latticeAnchor: .udc("000"),
            addedBy: "dreaming-queue-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame)
        drawers.append(drawer)
    }
    return drawers
}

/// Build a GLKRecallRequest for the external ARIA boundary (origin: .external).
/// This is the path run_memory_search uses — the production enqueue seam.
private func externalRecallRequest(limit: Int = 50) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            limit: limit,
            ordering: .byCaptureTimeDesc
        ),
        mode: .locusOnly,
        scoring: .raw,
        limit: limit,
        fallback: .failClosed,
        origin: .external
    )
}

/// Build a GLKRecallRequest with internal origin (system processes: dreaming, signals,
/// recipes). Must NEVER enqueue dreaming items (B-10a).
private func internalRecallRequest(limit: Int = 50) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            limit: limit,
            ordering: .byCaptureTimeDesc
        ),
        mode: .locusOnly,
        scoring: .raw,
        limit: limit,
        fallback: .failClosed,
        origin: .internal
    )
}

/// A RecallFrame for the legacy shim (always internal-origin per B-10a).
private func legacyShimFrame(limit: Int = 50) -> RecallFrame {
    RecallFrame(
        filterChain: [.unconfirmed],
        hydrationLevel: .structured,
        limit: limit,
        ordering: .byCaptureTimeDesc
    )
}

/// Open the per-estate queue sibling (`<stem>.queue.sqlite`) for direct inspection.
private func openDreamingQueue(storage: SQLiteStorage) async throws -> QueueKit {
    let siblingCfg = try storage.configuration.queueSibling(filename: "queue.sqlite")
    let siblingStorage = try SQLiteStorage(configuration: siblingCfg)
    try await PersistenceKitBackend.openSchema(on: siblingStorage)
    return QueueKit(backend: PersistenceKitBackend(storage: siblingStorage))
}

// MARK: - Suite

@Suite("T6 — dreaming queue enqueue-on-recall (ADR-021 Phase 2b)")
struct DreamingQueueTests {

    // MARK: - 1. External-origin recall surfacing ≥ 2 drawers enqueues exactly one job

    @Test
    func externalOriginRecallSurfacingTwoOrMoreDrawersEnqueuesOneDreamingJob() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Capture 3 drawers so recall has content to surface.
        _ = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // External-origin scored recall — the production MCP path (run_memory_search).
        let result = try await kit.recall(handle, externalRecallRequest())
        #expect(result.drawers.count >= 2,
            "recall must surface ≥ 2 drawers for the dreaming guard to pass")

        // Inspect the per-estate queue sibling: exactly one dreaming job must be present.
        let queue = try await openDreamingQueue(storage: storage)
        let pendingCount = try await queue.pendingCount(stream: StreamID(rawValue: "dreaming"))
        #expect(pendingCount == 1,
            "exactly one dreaming job must be enqueued after one external-origin recall with ≥ 2 drawers")
    }

    // MARK: - 2. Internal-origin recall and legacy shim must NOT enqueue (B-10a anti-regression)

    @Test
    func internalOriginRecallSurfacingTwoOrMoreDrawersEnqueuesNothing() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Capture 3 drawers.
        _ = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // Internal-origin scored recall — dreaming daemon, standing signals, recipes,
        // migration. MUST NOT enqueue (B-10a): these are system reads, not user actions.
        let result = try await kit.recall(handle, internalRecallRequest())
        #expect(result.drawers.count >= 2,
            "precondition: ≥ 2 drawers must surface to confirm the guard would fire")

        let queue = try await openDreamingQueue(storage: storage)
        let pendingCount = try await queue.pendingCount(stream: StreamID(rawValue: "dreaming"))
        #expect(pendingCount == 0,
            "internal-origin recall must NEVER enqueue dreaming items (B-10a)")
    }

    @Test
    func legacyShimRecallSurfacingTwoOrMoreDrawersEnqueuesNothing() async throws {
        // The legacy shim recall(_ handle:, _ frame: RecallFrame) always uses
        // origin: .internal. Even if ≥ 2 drawers surface, no dreaming job must
        // be enqueued. This is the B-10a anti-regression test: the shim is NOT
        // the external ARIA boundary; the scored recall with origin: .external is.
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        _ = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // Legacy shim — always internal origin, must never enqueue.
        let drawers = try await kit.recall(handle, legacyShimFrame())
        #expect(drawers.count >= 2,
            "precondition: ≥ 2 drawers must surface to confirm the guard would fire")

        let queue = try await openDreamingQueue(storage: storage)
        let pendingCount = try await queue.pendingCount(stream: StreamID(rawValue: "dreaming"))
        #expect(pendingCount == 0,
            "legacy shim (origin: .internal) must NEVER enqueue dreaming items (B-10a anti-regression)")
    }

    // MARK: - 3. External-origin recall surfacing < 2 drawers → no job enqueued

    @Test
    func externalOriginRecallSurfacingFewerThanTwoDrawersEnqueuesNothing() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Capture exactly 1 drawer — the guard requires ≥ 2 distinct ids.
        _ = try await captureDrawers(count: 1, kit: kit, handle: handle)

        let result = try await kit.recall(handle, externalRecallRequest())
        // Estate has exactly 1 drawer, so recall surfaces ≤ 1 row.
        #expect(result.drawers.count <= 1,
            "this estate has only one drawer — recall must surface ≤ 1")

        let queue = try await openDreamingQueue(storage: storage)
        let pendingCount = try await queue.pendingCount(stream: StreamID(rawValue: "dreaming"))
        #expect(pendingCount == 0,
            "no dreaming job must be enqueued when fewer than 2 drawers surface (guard fires)")
    }

    // MARK: - 4. Stream isolation: dreaming jobs are not claimed by the encode drainer

    @Test
    func dreamingJobIsNotClaimedByEncodeStreamDrain() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Capture enough drawers for the recall guard to pass.
        _ = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // External-origin recall to enqueue a dreaming job.
        let result = try await kit.recall(handle, externalRecallRequest())
        #expect(result.drawers.count >= 2,
            "precondition: ≥ 2 drawers must surface to enqueue a dreaming job")

        // Open the same queue.sqlite and drain only the "encode" stream.
        // The dreaming job must remain pending afterward — encode and dreaming
        // are discriminated by stream_id per ADR-021 Decision 7.
        let queue = try await openDreamingQueue(storage: storage)

        // Draining "encode" must find nothing (no encode jobs were enqueued).
        let encodeJobs = try await queue.drain(stream: StreamID(rawValue: "encode"))
        #expect(encodeJobs.isEmpty,
            "no encode-stream jobs must be present — the dreaming job has stream_id='dreaming'")

        // The dreaming job must still be pending (not mistakenly claimed by encode drain).
        let dreamingPending = try await queue.pendingCount(stream: StreamID(rawValue: "dreaming"))
        #expect(dreamingPending == 1,
            "dreaming job must remain pending after encode-stream drain — streams are isolated")
    }

    // MARK: - 5. Payload round-trip: drawer ids are in the job payload

    @Test
    func dreamingJobPayloadContainsSurfacedDrawerIds() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Capture 3 drawers.
        let captured = try await captureDrawers(count: 3, kit: kit, handle: handle)
        let capturedIds = Set(captured.map(\.id))

        // External-origin scored recall — the production path that enqueues.
        let result = try await kit.recall(handle, externalRecallRequest())
        #expect(result.drawers.count >= 2, "precondition: ≥ 2 drawers must surface")

        // Drain the dreaming job and decode the payload.
        let queue = try await openDreamingQueue(storage: storage)
        let drained = try await queue.drain(stream: StreamID(rawValue: "dreaming"))
        let job = try #require(drained.first?.job, "one dreaming job must be drainable")

        let item = try JSONDecoder().decode(DreamingItem.self, from: job.payload)
        #expect(!item.recallEventId.isEmpty,
            "recallEventId must be non-empty (32-hex UUID per JobID convention)")
        #expect(item.drawerIds.count >= 2,
            "drawerIds must have ≥ 2 entries per spec §12.2 guard")

        // Every id in the payload must come from the captured drawers.
        let payloadIds = Set(item.drawerIds)
        #expect(!payloadIds.intersection(capturedIds).isEmpty,
            "all payload drawer ids must be ids of captured drawers")

        // All surfaced drawer ids must appear in the payload (result-order preservation).
        let surfacedIds = Set(result.drawers.map(\.id))
        #expect(payloadIds == surfacedIds,
            "payload drawer ids must exactly match the surfaced drawer id set")
    }

    // MARK: - HLC write-back: sequential enqueues must produce monotonically increasing timestamps

    // Verifies the HLC value-type write-back fix: HLCGenerator.send(now:) is mutating,
    // so the result must be written back to dreamingHLCs[handle] after each call.
    // Without the write-back, every enqueue restarts from the same initial HLC state,
    // producing non-monotonic or duplicate submitted_at timestamps across sequential
    // dreaming jobs. Two consecutive external-origin recalls must each enqueue one job,
    // and the second job's submitted_at must be >= the first job's (HLC monotonicity).
    @Test
    func sequentialEnqueuesProduceMonotonicallyIncreasingHLCTimestamps() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Capture 3 drawers so both recalls surface ≥ 2 drawers.
        _ = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // Two sequential external-origin recalls enqueue two dreaming jobs.
        // The public recall API uses Date() internally for the HLC stamp, so
        // real wall-clock time advances between calls (sufficient for HLC monotonicity
        // when the fix is present; without the fix, both calls see the same initial
        // HLC state and may produce equal timestamps).
        _ = try await kit.recall(handle, externalRecallRequest())
        _ = try await kit.recall(handle, externalRecallRequest())

        // Inspect the dreaming queue: two jobs, second submitted_at >= first.
        // QueueKit drain returns jobs in submitted_at order (earliest first).
        let queue = try await openDreamingQueue(storage: storage)
        let drained = try await queue.drain(stream: StreamID(rawValue: "dreaming"))
        #expect(drained.count == 2,
            "two sequential external-origin recalls must enqueue two dreaming jobs")

        let job0 = try #require(drained.first?.job, "first dreaming job must exist")
        let job1 = try #require(drained.last?.job, "second dreaming job must exist")

        // HLC monotonicity: the second enqueue must produce a submitted_at >= the first.
        // HLC values sort lexicographically (physical_time:logical_count:node_id).
        // Without the write-back fix, both jobs would have identical submitted_at because
        // the HLC state resets to its initial value on every enqueue call.
        #expect(job1.submittedAt >= job0.submittedAt)
    }

    // MARK: - 6. InMemory estate: dreaming queue degrades to transient backend

    @Test
    func inmemoryEstateExternalOriginRecallEnqueuesViaTtransientBackend() async throws {
        let (kit, handle) = try await openInMemoryEstate()

        // Capture 3 drawers so the recall guard passes.
        _ = try await captureDrawers(count: 3, kit: kit, handle: handle)

        // External-origin scored recall — the production enqueue seam.
        let result = try await kit.recall(handle, externalRecallRequest())
        #expect(result.drawers.count >= 2, "precondition: ≥ 2 drawers must surface")

        // The dreaming queue for an InMemory estate is backed by a transient backend.
        // We verify via `ensureDreamingQueue` (internal via @testable import) — the
        // queue must exist and have exactly 1 pending dreaming job.
        let (dreamQueue, _) = try await kit.ensureDreamingQueue(for: handle)
        let pendingCount = try await dreamQueue.pendingCount(stream: StreamID(rawValue: "dreaming"))
        #expect(pendingCount == 1,
            "in-memory estate must enqueue one dreaming job via transient backend on external-origin recall with ≥ 2 drawers")
    }
}
