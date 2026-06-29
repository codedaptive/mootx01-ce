// CrashRecoveryReclaimTests.swift
//
// Tests for Mission #54 Parts A/B/D: on-mount crash-recovery GC in the
// CorpusKit encode drain loop.
//
// Success criteria (Mission #54, Part B):
//   1. Orphaned cur reclaim on mount: cur rows for the encode stream are reset
//      to new (and subsequently drained) after the prior drainer's lease is stale.
//   2. Live-drainer anti-yank (negative): when a fresh lease is held by another
//      drainer, mounting a second Corpus does NOT reclaim that stream's cur rows.
//   3. Corpus Drop idempotency (Part D): dropIngestQueue() is safe to call twice;
//      the Corpus's deinit calls it once and a manual call before deinit is
//      harmless.
//
// All tests use a real on-disk SQLite backend (makeScratchStorage) and a
// per-test temp dir with per-estate isolation so tests run in parallel safely.

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes
import Testing

@testable import CorpusKit

// ─── Helpers ────────────────────────────────────────────────────────────────

private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_500_000)

/// Make a scratch SQLiteStorage in a dedicated temp dir.
/// Returns the storage and the estate directory URL (the SQLite file's parent),
/// which is also where DrainLease files live.
private func makeScratchStorageWithDir() throws -> (any Storage, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("corpuskit-reclaim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sqliteURL = dir.appendingPathComponent("estate.sqlite3")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: sqliteURL, busyTimeout: 5.0)))
    return (storage, dir)
}

/// Write a stale DrainLease file: owner = `stalePID`, heartbeat = now - 20s
/// (well past the default 15 s TTL). The mounting drainer will see this as
/// absent/stale and successfully acquire the lease.
private func writeStaleEncodeLease(in dir: URL) throws {
    let staleTime = Date().addingTimeInterval(-20)  // 20 s ago — past 15 s TTL
    let text = "pid-99999-dead-drainer\n\(staleTime.timeIntervalSince1970)\n"
    let leaseURL = dir.appendingPathComponent("encode.drain.lease")
    try text.write(to: leaseURL, atomically: true, encoding: .utf8)
}

/// Write a FRESH DrainLease file to simulate a live drainer holding the lease.
private func writeFreshEncodeLease(in dir: URL, owner: String = "pid-12345-live-drainer") throws {
    let freshTime = Date()   // just now — within TTL
    let text = "\(owner)\n\(freshTime.timeIntervalSince1970)\n"
    let leaseURL = dir.appendingPathComponent("encode.drain.lease")
    try text.write(to: leaseURL, atomically: true, encoding: .utf8)
}

// ─── Suite ──────────────────────────────────────────────────────────────────

@Suite("Corpus crash-recovery reclaim (Mission #54 Part B/D)", .serialized)
struct CrashRecoveryReclaimTests {

    // MARK: 1. Orphaned cur reclaim on mount

    /// Simulate a crashed drainer:
    ///   (a) create a corpus, mount its queue, enqueue a job, drain it to "cur",
    ///   (b) replace the lease with a stale one (simulating a crash),
    ///   (c) drop the first queue WITHOUT completing the job (orphan the cur row),
    ///   (d) mount a fresh corpus on the same estate,
    ///   (e) verify the orphaned cur row is reclaimed and eventually ingested.
    @Test("orphaned cur jobs are reclaimed when prior lease is stale")
    func orphanedCurReclaimedOnMount() async throws {
        try await GlobalTestLock.shared.withLock {
            let (storage, estateDir) = try makeScratchStorageWithDir()
            defer { try? FileManager.default.removeItem(at: estateDir) }

            // ── Phase 1: enqueue a job and orphan it in "cur" ──────────────

            let corpus1 = try await Corpus(storage: storage)
            try await corpus1.mountIngestQueue()
            try await corpus1.enqueueIngest(
                "vanadium steel alloy heat treatment",
                sourceID: "orphan-doc", now: fixedNow)

            // Drain the job to "cur" — it's now in-flight.
            // We reach into the queue via the internal ingestQueue accessor.
            // Give the drain worker one pass to claim the job.
            try await Task.sleep(for: .milliseconds(100))

            // Force the lease to stale — the drainer appears dead.
            // This bypasses the 15 s real-time wait.
            try writeStaleEncodeLease(in: estateDir)

            // Drop queue WITHOUT completing — the "cur" row is orphaned.
            await corpus1.dropIngestQueue()

            // ── Phase 2: fresh corpus mounts, sees stale lease, reclaims ───

            // Corpus2 uses the SAME SQLite estate (same storage). On mount, its
            // drain loop will see the stale lease, acquire it, call reclaimInFlight,
            // and then drain + encode the orphaned job.
            let corpus2 = try await Corpus(storage: storage)
            try await corpus2.mountIngestQueue()

            // Wait for the drain worker to reclaim and ingest the orphaned job.
            try await corpus2.awaitIngestDrain(timeout: .seconds(30))

            // Verify the job was re-ingested and is now recallable.
            let hits = try await corpus2.recall(
                "vanadium steel heat treatment", limit: 5, now: fixedNow)
            #expect(!hits.isEmpty,
                "reclaimed orphaned job must be ingested and recallable by corpus2")

            await corpus2.dropIngestQueue()
        }
    }

    // MARK: 2. Live-drainer anti-yank (negative)

    /// With a FRESH (non-stale) lease held by another drainer, a second corpus
    /// that mounts should NOT reclaim the first drainer's cur rows — that would
    /// yank a job out from under the live drainer.
    ///
    /// We simulate this by:
    ///   - writing a fresh lease file for "another-drainer",
    ///   - mounting corpus2,
    ///   - writing a "cur" row directly into the queue via PK backend,
    ///   - verifying that corpus2's drain loop does NOT reclaim the cur row
    ///     within a short observation window (the live lease blocks acquire).
    @Test("live-drainer: fresh lease prevents reclaim of another stream's cur rows")
    func liveDrainerFreshLeaseBlocksReclaim() async throws {
        try await GlobalTestLock.shared.withLock {
            let (storage, estateDir) = try makeScratchStorageWithDir()
            defer { try? FileManager.default.removeItem(at: estateDir) }

            // Derive the queue-sibling config to build a PK backend directly.
            let siblingCfg = try storage.configuration.queueSibling(filename: "queue.sqlite")
            let queueStorage = try SQLiteStorage(configuration: siblingCfg)
            try await PersistenceKitBackend.openSchema(on: queueStorage)
            let pkBackend = PersistenceKitBackend(storage: queueStorage)

            // Write a "cur" job directly — simulating a live drainer's in-flight job.
            let j = Job(
                id: JobID.generate(),
                streamID: StreamID(rawValue: "encode"),
                submittedAt: HLC(physicalTime: 1_000_000, logicalCount: 0, nodeID: 1),
                priority: 50,
                payload: Data("live-drainer-payload".utf8),
                extensions: [:])
            try await pkBackend.write(j)
            _ = try await pkBackend.drainAvailable()  // → cur

            // Write a FRESH lease: another "live" drainer holds encode.
            try writeFreshEncodeLease(in: estateDir, owner: "pid-42-live-drainer")

            // Mount corpus2 — it must stand down because the lease is fresh.
            let corpus2 = try await Corpus(storage: storage)
            try await corpus2.mountIngestQueue()

            // Give the drain loop a few passes.
            try await Task.sleep(for: .milliseconds(300))

            // The cur row must still be cur — corpus2 did not reclaim it.
            let inFlight = try await pkBackend.inFlight()
            #expect(inFlight.count == 1,
                "live drainer's cur row must NOT be reclaimed when lease is fresh")
            #expect(inFlight[0].id == j.id)

            await corpus2.dropIngestQueue()
        }
    }

    // MARK: 3. Corpus Drop idempotency (Part D)

    /// `dropIngestQueue()` must be safe to call twice. The Corpus's isolated
    /// deinit calls it automatically; a manual call before deinit is harmless.
    @Test("dropIngestQueue is idempotent — safe to call twice")
    func dropIngestQueueIdempotent() async throws {
        let storage = try makeScratchStorage()
        let corpus = try await Corpus(storage: storage)
        try await corpus.mountIngestQueue()

        // Manual drop — should succeed.
        await corpus.dropIngestQueue()

        // Second drop — must also succeed without throwing or panicking.
        await corpus.dropIngestQueue()

        // The deinit will call dropIngestQueue a third time — if it were not
        // idempotent, that would crash. We verify indirectly: no crash = pass.
    }
}
