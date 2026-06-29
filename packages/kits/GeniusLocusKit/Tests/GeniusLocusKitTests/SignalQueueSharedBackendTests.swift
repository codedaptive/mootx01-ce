// SignalQueueSharedBackendTests.swift
//
// T5 (ADR-021 Decision 7): tests that the standing-signal scheduler uses the
// shared per-estate queue.sqlite under stream_id = "signals".
//
// Contract verified here:
//   1. Persistent estate → signals are drained correctly (the shared
//      queue.sqlite exists on disk after mount, and signals fire as expected).
//   2. Foreign-stream isolation: a job enqueued under a different stream_id
//      ("encode") is NOT claimed by the signal drainer.
//   3. Durability: the queue.sqlite sibling file exists on disk after the
//      scheduler is minted for a persistent estate, confirming the durable
//      backing is in place. (A full two-process restart test is not possible
//      in-process; we assert file existence + deterministic sibling path.)
//   4. InMemory estate → scheduler still works correctly with the transient
//      in-memory backend.
//   5. stream_id is "signals" (not the old per-estate UUID slug) — verified
//      indirectly: wrong stream_id would leave jobs permanently pending and
//      the drain history empty, so a non-zero emissionCount confirms correctness.

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
    let dir = base.appendingPathComponent("glk-signal-queue-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Remove the temp directory and everything inside it.
private func cleanup(dir: URL) {
    try? FileManager.default.removeItem(at: dir)
}

/// Open a persistent SQLite-backed estate and return the kit, handle, and storage.
/// Uses `LocusKit.Estate.create + kit.open` — the same pattern as
/// `StandingSignalSchedulerTests.openOneEstate` but on a SQLite backend.
private func openSQLiteEstate(at dir: URL) async throws
    -> (GeniusLocusKit, EstateHandle, SQLiteStorage)
{
    let estateURL = dir.appendingPathComponent("estate.sqlite")
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: estateURL)
    ))
    let owner = OwnerCredentials(ownerIdentifier: "signal-queue-test-owner")
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let kit = GeniusLocusKit()
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle, storage)
}

/// Open an InMemory estate — mirrors the fixture in StandingSignalSchedulerTests.
private func openInMemoryEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    let owner = OwnerCredentials(ownerIdentifier: "signal-queue-inmem-owner")
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let kit = GeniusLocusKit()
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle)
}

/// Deterministic reference time — matches the Swift scheduler tests' t0.
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - Suite

@Suite("T5 — signal queue on shared per-estate queue.sqlite")
struct SignalQueueSharedBackendTests {

    // MARK: - 1. Persistent estate: signals fire and drain correctly

    @Test
    func persistentEstateSignalsDrainCorrectly() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, _) = try await openSQLiteEstate(at: dir)

        // Register one interval signal and tick once past its cadence.
        let spec = SignalSpec(
            name: "stream-check",
            trigger: .interval(seconds: 10),
            emit: { ctx in
                [.diagnostic(DiagnosticReport(
                    title: "stream-check-tick",
                    detail: "at \(ctx.now.timeIntervalSince1970)",
                    observedAt: ctx.now))]
            })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(11))

        // The emission must have been queued, drained, and surfaced in status.
        let reports = try await kit.signalStatus(in: handle)
        let report = try #require(reports.first(where: { $0.signalID == id }),
            "report for registered signal must be present")
        #expect(report.emissionCount == 1,
            "signal must fire once on a persistent estate")
        #expect(report.recentDiagnostics.count == 1,
            "diagnostic emission must be surfaced via status")
        #expect(report.recentDiagnostics.first?.title == "stream-check-tick")
    }

    // MARK: - 2. Foreign-stream isolation

    @Test
    func foreignStreamJobIsNotClaimedBySignalDrainer() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Mint the scheduler (and therefore the queue.sqlite sibling).
        _ = try await kit.ensureScheduler(for: handle)

        // Open the same queue.sqlite directly and enqueue a foreign-stream job.
        let siblingCfg = try storage.configuration.queueSibling(filename: "queue.sqlite")
        let siblingStorage = try SQLiteStorage(configuration: siblingCfg)
        try await PersistenceKitBackend.openSchema(on: siblingStorage)
        let foreignQueue = QueueKit(backend: PersistenceKitBackend(storage: siblingStorage))

        // Stamp with a valid HLC (physicalTime = milliseconds since epoch, logicalCount,
        // nodeID all match SubstrateTypes conventions).
        let physMs = Int64(t0.timeIntervalSince1970 * 1_000)
        let fakeHLC = HLC(physicalTime: physMs, logicalCount: 0, nodeID: 0)
        let foreignPayload = try JSONEncoder().encode(["source": "encode-test"])
        let foreignJob = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "encode"),
            submittedAt: fakeHLC,
            priority: 50,
            payload: foreignPayload)
        try await foreignQueue.send(foreignJob)

        // Tick the scheduler — it must drain only "signals" jobs, not "encode".
        try await kit.signalTick(in: handle, now: t0)

        // The foreign job must remain pending in the "encode" stream.
        let encodeDepth = try await foreignQueue.pendingCount(stream: StreamID(rawValue: "encode"))
        #expect(encodeDepth == 1,
            "the signal drainer must NOT claim the 'encode' stream job — it should still be pending")

        // No scheduler drain history: no signal was due at t0 exactly
        // (t0 == registration time, so the interval is not yet elapsed).
        let scheduler = try await kit.ensureScheduler(for: handle)
        let history = await scheduler.drainHistory()
        #expect(history.isEmpty,
            "no signal emissions in drain history when no signal is due")
    }

    // MARK: - 3. Durability: queue.sqlite exists on disk for persistent estates

    @Test
    func persistentEstateQueueSQLiteExistsOnDisk() async throws {
        let dir = tempEstateDir()
        defer { cleanup(dir: dir) }

        let (kit, handle, storage) = try await openSQLiteEstate(at: dir)

        // Mint the scheduler — this triggers queue.sqlite creation.
        _ = try await kit.ensureScheduler(for: handle)

        // Derive the expected queue.sqlite path the same way ensureScheduler does.
        let siblingCfg = try storage.configuration.queueSibling(filename: "queue.sqlite")
        guard case let .sqlite(queueURL, _) = siblingCfg.backend else {
            Issue.record("queueSibling backend must be .sqlite for a SQLite estate")
            return
        }

        #expect(FileManager.default.fileExists(atPath: queueURL.path),
            "queue.sqlite must exist on disk after the scheduler is mounted for a persistent estate")

        // Verify determinism: calling queueSibling again yields the same path.
        let siblingCfg2 = try storage.configuration.queueSibling(filename: "queue.sqlite")
        guard case let .sqlite(queueURL2, _) = siblingCfg2.backend else {
            Issue.record("queueSibling backend must be .sqlite on second call")
            return
        }
        #expect(queueURL == queueURL2,
            "queueSibling must be deterministic — same estate → same queue.sqlite path")
    }

    // MARK: - 4. InMemory estate: scheduler works with transient backend

    @Test
    func inMemoryEstateSchedulerWorksWithTransientBackend() async throws {
        let (kit, handle) = try await openInMemoryEstate()

        let spec = SignalSpec(
            name: "inmemory-signal",
            trigger: .interval(seconds: 5),
            emit: { ctx in
                [.diagnostic(DiagnosticReport(
                    title: "inmemory-tick",
                    detail: "ok",
                    observedAt: ctx.now))]
            })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(6))

        let reports = try await kit.signalStatus(in: handle)
        let report = try #require(reports.first(where: { $0.signalID == id }))
        #expect(report.emissionCount == 1,
            "InMemory estate scheduler must still fire and drain signals correctly")
        #expect(report.recentDiagnostics.first?.title == "inmemory-tick")
    }

    // MARK: - 5. stream_id is "signals" (verified indirectly via drain count)

    @Test
    func signalStreamIDIsSignalsString() async throws {
        // If the stream_id were wrong (e.g. "glk_scheduler_<uuid>"), drain(stream:)
        // would claim nothing and emissionCount would stay 0. A non-zero
        // emissionCount confirms the drain is claiming jobs from the correct stream.
        let (kit, handle) = try await openInMemoryEstate()

        let spec = SignalSpec(
            name: "stream-id-probe",
            trigger: .interval(seconds: 1),
            emit: { ctx in
                [.diagnostic(DiagnosticReport(
                    title: "stream-id-diag",
                    detail: "",
                    observedAt: ctx.now))]
            })
        let id = try await kit.registerStandingSignal(spec, in: handle, now: t0)
        try await kit.signalTick(in: handle, now: t0.addingTimeInterval(2))

        let reports = try await kit.signalStatus(in: handle)
        let report = try #require(reports.first(where: { $0.signalID == id }))
        // Wrong stream_id → drain(stream:) claims 0 jobs → emissionCount stays 0.
        #expect(report.emissionCount == 1,
            "stream_id must be 'signals' so drain(stream:) claims the job — wrong stream_id → emissionCount=0")
    }
}
