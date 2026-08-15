// CorpusReindexLatchDedupeTests.swift
//
// Discriminating tests for the manifest-flag dedupe fix in
// `reindexRequired(queue:storage:now:)`.
//
// Finding E (commit bc0e989): `pendingCount(stream:)` counts only
// `status = 'new'` rows. Once the drainer claims the marker job
// ('new' → 'cur'), the count returns 0 and the old code enqueued a
// second rebuild job. The fix reads the durable manifest flag before
// touching the queue — returning early when a rebuild is already owed.
//
// Covered windows:
//   (i)  job is 'cur' (claimed, not yet completed) — pendingCount == 0
//   (ii) job is 'done' (completed, flag not yet cleared) — pendingCount == 0
//
// Window (iii) — two concurrent callers racing between check and send —
// is outside the documented contract (sequential migration train) and is
// not tested here.

import Testing
import Foundation
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes

// MARK: - Helpers (shared with CorpusReindexLatchTests, duplicated to keep
// this file self-contained — no module-level shared state between test files)

/// Minimal manifest-only SQLite storage. SQLite is required so the
/// manifest row survives the read-back in `reindexRequired`.
private func dedupeManifestScratch() async throws -> any Storage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("latch-dedupe-\(UUID().uuidString).sqlite3")
    let st = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
    try await st.open(schema: SchemaDeclaration(
        kitID: "LatchDedupeManifest",
        version: 1,
        tables: [
            TableDeclaration(
                name: "manifest",
                columns: [
                    .text("key", nullable: false),
                    .text("value", nullable: false)
                ],
                primaryKey: ["key"]
            )
        ],
        indices: [],
        migrations: []
    ))
    return st
}

/// Fresh in-memory QueueKit.
private func dedupeInMemoryQueue() async throws -> QueueKit {
    let st = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory))
    try await PersistenceKitBackend.openSchema(on: st)
    let backend = PersistenceKitBackend(storage: st)
    return QueueKit(backend: backend)
}

// MARK: - Test suite

@Suite("CorpusReindexLatchDedupe", .serialized)
struct CorpusReindexLatchDedupeTests {

    /// Deterministic `now` — never `Date()`.
    private let now = Date(timeIntervalSince1970: 1_755_100_000)

    // MARK: Window (i): job is claimed ('cur'), pendingCount returns 0

    /// Discriminating test for window (i).
    ///
    /// Without the fix, calling `reindexRequired` after the marker job is
    /// drained ('new' → 'cur') enqueues a SECOND rebuild job because
    /// `pendingCount(stream:)` returns 0 for in-flight rows.
    ///
    /// With the fix, the manifest flag check fires on the second call and
    /// returns early — no second job is enqueued.
    @Test("window-i: second call after claim does not enqueue a second job")
    func secondCallAfterClaimProducesOneJob() async throws {
        let storage = try await dedupeManifestScratch()
        let queue = try await dedupeInMemoryQueue()

        // First call: enqueues the marker job and sets the manifest flag.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        let afterFirst = try await queue.pendingCount(stream: reindexStreamID)
        #expect(afterFirst == 1, "exactly one pending job after the first latch call")

        // Drain the job — transitions 'new' → 'cur'. pendingCount now returns 0.
        let claimed = try await queue.drain(stream: reindexStreamID)
        #expect(claimed.count == 1, "the reindex marker job must be drainable")

        let pendingAfterDrain = try await queue.pendingCount(stream: reindexStreamID)
        #expect(pendingAfterDrain == 0,
            "pendingCount must be 0 after the job is claimed — this is the vulnerability window")

        // Without the fix, this second call sees pendingCount == 0 and enqueues
        // a new job. With the fix, it sees the manifest flag and returns early.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        // Assert total outstanding work: the one in-flight job, no new pending job.
        let pendingAfterSecond = try await queue.pendingCount(stream: reindexStreamID)
        #expect(pendingAfterSecond == 0,
            "second latch call must not enqueue a second job — manifest flag dedupe closes window (i)")

        let inFlight = try await queue.inFlight()
        let reindexInFlight = inFlight.filter { $0.streamID == reindexStreamID }
        #expect(reindexInFlight.count == 1,
            "exactly one reindex job must exist in total (the original, still in-flight)")
    }

    // MARK: Window (ii): job is 'done', manifest flag not yet cleared

    /// Discriminating test for window (ii).
    ///
    /// Without the fix, a second latch call after the marker job completes
    /// ('done') but BEFORE the flag is cleared enqueues a new job.
    ///
    /// With the fix, the manifest flag check fires and returns early.
    @Test("window-ii: second call after job completion does not enqueue a second job")
    func secondCallAfterJobCompletionProducesOneJob() async throws {
        let storage = try await dedupeManifestScratch()
        let queue = try await dedupeInMemoryQueue()

        // First call: enqueues the marker job and sets the manifest flag.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        let afterFirst = try await queue.pendingCount(stream: reindexStreamID)
        #expect(afterFirst == 1, "exactly one pending job after the first latch call")

        // Drain then complete the job: 'new' → 'cur' → 'done'.
        let claimed = try await queue.drain(stream: reindexStreamID)
        #expect(claimed.count == 1, "the reindex marker job must be drainable")

        let jobID = claimed[0].job.id
        // Mark the job done — simulating a drain worker that processed it.
        // The manifest flag is NOT cleared here (clearing is not latch scope).
        try await queue.reply(to: jobID, status: .done, artifacts: [])

        // Verify: no pending, no in-flight — only a 'done' row.
        let pendingAfterComplete = try await queue.pendingCount(stream: reindexStreamID)
        #expect(pendingAfterComplete == 0,
            "no pending jobs after the marker job completes")

        let inFlightAfterComplete = try await queue.inFlight()
        let reindexInflight = inFlightAfterComplete.filter { $0.streamID == reindexStreamID }
        #expect(reindexInflight.isEmpty,
            "no in-flight jobs after the marker job completes")

        // Without the fix, this second call sees pendingCount == 0 and enqueues
        // a new job. With the fix, it sees the manifest flag and returns early.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        // Total jobs: one 'done' row, zero new pending.
        let pendingAfterSecond = try await queue.pendingCount(stream: reindexStreamID)
        #expect(pendingAfterSecond == 0,
            "second latch call must not enqueue a new job — manifest flag dedupe closes window (ii)")

        let completed = try await queue.completed(streamID: reindexStreamID)
        #expect(completed.count == 1,
            "exactly one completed reindex job must exist — no duplicate was added")
    }
}
