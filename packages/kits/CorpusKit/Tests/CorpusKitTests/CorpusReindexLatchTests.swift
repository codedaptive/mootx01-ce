// CorpusReindexLatchTests.swift
//
// Unit tests for `reindexRequired(queue:storage:now:)`.
//
// Three scenarios:
//   1. fires-once: happy path — enqueue succeeds, manifest flag is set.
//   2. second-call no-op: second call finds the existing job on the stream,
//      sets the manifest flag again (idempotent), does not enqueue a second job.
//   3. enqueue-fail: enqueue fails silently; read-back returns 0; manifest
//      flag is NOT set; deferral line is printed to stdout.

import Testing
import Foundation
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes

// MARK: - Test helpers

/// Minimal schema containing only the `manifest` table — the key-value store
/// the reindex latch writes to. Not a complete estate schema, but sufficient
/// for unit testing the latch in isolation.
private let manifestSchema = SchemaDeclaration(
    kitID: "LatchTestManifest",
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
)

/// Open a fresh on-disk SQLite storage with only the manifest table.
/// SQLite is required (InMemory backend preserves semantic TypedValues on
/// read rather than returning primitive .text/.int values, masking real
/// round-trip bugs — same rationale as TestScratchStorage.swift).
private func manifestScratch() async throws -> any Storage {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("latch-manifest-\(UUID().uuidString).sqlite3")
    let st = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url, busyTimeout: 5.0)))
    try await st.open(schema: manifestSchema)
    return st
}

/// Open a fresh in-memory storage whose schema includes the QueueKit jobs
/// table. Returns a ready-to-use `QueueKit` facade backed by an in-memory
/// `PersistenceKitBackend`.
///
/// In-memory is acceptable here: the latch tests verify the LOGIC of
/// reindexRequired, not on-disk crash recovery. The test that checks the
/// manifest bit still uses on-disk SQLite storage.
private func inMemoryQueue() async throws -> QueueKit {
    let st = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory))
    try await PersistenceKitBackend.openSchema(on: st)
    let backend = PersistenceKitBackend(storage: st)
    return QueueKit(backend: backend)
}

// MARK: - Fail-write backend

/// A QueueBackend whose `write` always throws so the latch's read-back step
/// receives 0 and prints the deferral line. All other methods return empty /
/// zero so `pendingCount(stream:)` is non-throwing.
private actor FailWriteBackend: QueueBackend {
    func write(_ job: Job) async throws {
        struct WriteRefused: Error {}
        throw WriteRefused()
    }
    func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)] { [] }
    func pendingCount() async throws -> Int { 0 }
    func watch(handler: @escaping @Sendable (Job, SessionID) async throws -> Void) async throws {}
    func complete(_ jobID: JobID, status: ObservationStatus, artifacts: [ArtifactRef]) async throws {}
    func inFlight() async throws -> [Job] { [] }
    func completed(streamID: StreamID?) async throws -> [Job] { [] }
}

// MARK: - Test suite

@Suite("CorpusReindexLatch", .serialized)
struct CorpusReindexLatchTests {

    /// Canonical `now` used across all tests. Deterministic — never `Date()`.
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    // MARK: Test 1: happy path — fires once, sets the manifest bit

    @Test("fires-once: enqueue succeeds and manifest flag is set")
    func firesOnce() async throws {
        let storage = try await manifestScratch()
        let queue = try await inMemoryQueue()

        // Verify no job exists before the call.
        let before = try await queue.pendingCount(stream: reindexStreamID)
        #expect(before == 0, "no reindex job should exist before the first latch call")

        // Call the latch.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        // The reindex stream should carry exactly one pending job.
        let after = try await queue.pendingCount(stream: reindexStreamID)
        #expect(after == 1, "one reindex job must be pending after the latch fires")

        // The manifest flag must be set to "1".
        let rows = try await storage.rowStore.query(
            table: "manifest",
            where: .eq(Column(table: "manifest", name: "key"), .text(reindexManifestKey)),
            orderBy: [], limit: 1, offset: nil)
        #expect(rows.count == 1, "manifest must carry the reindex-required flag")
        if let row = rows.first, case let .text(v) = row["value"] ?? .null {
            #expect(v == "1", "manifest flag value must be '1', got '\(v)'")
        }
    }

    // MARK: Test 2: second call is a no-op via stream key

    @Test("second-call no-op: stream key deduplicates; manifest flag remains set")
    func secondCallIsNoOp() async throws {
        let storage = try await manifestScratch()
        let queue = try await inMemoryQueue()

        // First call: enqueues the job and sets the manifest flag.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        let afterFirst = try await queue.pendingCount(stream: reindexStreamID)
        #expect(afterFirst == 1, "one job after the first latch call")

        // Second call: finds the existing job, sets the manifest flag (idempotent
        // upsert), and does NOT enqueue a second job.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        let afterSecond = try await queue.pendingCount(stream: reindexStreamID)
        #expect(afterSecond == 1,
            "second latch call must not produce a second job — stream key deduplicates")

        // Manifest flag must still be set.
        let rows = try await storage.rowStore.query(
            table: "manifest",
            where: .eq(Column(table: "manifest", name: "key"), .text(reindexManifestKey)),
            orderBy: [], limit: 1, offset: nil)
        #expect(rows.count == 1, "manifest flag must still be present after second call")
    }

    // MARK: Test 3: enqueue fails — bit stays clear, deferral is printed

    @Test("enqueue-fail: write error leaves manifest clear; no latch bit set")
    func enqueueFailLeavesManifestClear() async throws {
        let storage = try await manifestScratch()
        // Use the fail-write backend so every `send` call errors out silently.
        let queue = QueueKit(backend: FailWriteBackend())

        // The latch must not throw — errors from `send` are absorbed.
        try await reindexRequired(queue: queue, storage: storage, now: now)

        // No pending job should exist (write failed, read-back returns 0).
        let jobCount = try await queue.pendingCount(stream: reindexStreamID)
        #expect(jobCount == 0,
            "no job should be pending when the write backend fails")

        // The manifest flag must NOT be set — the bit is written only when a
        // job is confirmed by the read-back.
        let rows = try await storage.rowStore.query(
            table: "manifest",
            where: .eq(Column(table: "manifest", name: "key"), .text(reindexManifestKey)),
            orderBy: [], limit: 1, offset: nil)
        #expect(rows.isEmpty,
            "manifest must not carry the latch flag when the enqueue did not take")
    }
}
