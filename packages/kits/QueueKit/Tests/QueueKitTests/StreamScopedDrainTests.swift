// StreamScopedDrainTests.swift
//
// Tests for the recall-driven dreaming /  stream-scoped drain capability.
// Covers drainAvailable(stream:) and pendingCount(stream:) on both
// PersistenceKitBackend and FilesystemBackend, plus facade passthroughs,
// and back-compat of the all-streams paths.
//
// Success criteria:
//   1. Stream isolation: drain(stream:"a") claims ONLY "a" jobs, leaves
//      "b" jobs claimable by a subsequent drain(stream:"b").
//   2. pendingCount(stream:) returns the per-stream count, not the total.
//   3. Back-compat: the existing all-streams drain() and pendingCount()
//      are unchanged.

import Testing
import Foundation
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import PersistenceKit
import PersistenceKitInMemory
@testable import QueueKit

// MARK: - PersistenceKitBackend stream-scoped drain

@Suite("Stream-scoped drain — PersistenceKitBackend")
struct StreamScopedDrainPKTests {

    func makeBackend() async throws -> PersistenceKitBackend {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory))
        try await PersistenceKitBackend.openSchema(on: storage)
        return PersistenceKitBackend(storage: storage)
    }

    private func job(
        _ i: Int,
        stream: String
    ) -> Job {
        Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: stream),
            submittedAt: HLC(
                physicalTime: 1_700_000_000_000 + Int64(i),
                logicalCount: 0, nodeID: 1),
            priority: 50,
            payload: Data(),
            extensions: [:])
    }

    // ── Isolation ───────────────────────────────────────────────────────────

    /// drainAvailable(stream:"a") returns ONLY stream-a jobs and leaves
    /// stream-b jobs unclaimed (claimable by a subsequent drain for "b").
    @Test func pkStreamIsolationDrain() async throws {
        let backend = try await makeBackend()
        let a1 = job(1, stream: "a")
        let a2 = job(2, stream: "a")
        let b1 = job(3, stream: "b")
        let b2 = job(4, stream: "b")

        try await backend.write(a1)
        try await backend.write(b1)
        try await backend.write(a2)
        try await backend.write(b2)

        // Drain stream "a" — must return only a's jobs.
        let drainedA = try await backend.drainAvailable(stream: StreamID(rawValue: "a"))
        #expect(drainedA.count == 2, "stream-a drain must return exactly 2 jobs")
        let idsA = Set(drainedA.map { $0.job.id })
        #expect(idsA.contains(a1.id))
        #expect(idsA.contains(a2.id))
        #expect(!idsA.contains(b1.id))
        #expect(!idsA.contains(b2.id))

        // Stream "b" jobs are still claimable.
        let drainedB = try await backend.drainAvailable(stream: StreamID(rawValue: "b"))
        #expect(drainedB.count == 2, "stream-b drain must return exactly 2 jobs")
        let idsB = Set(drainedB.map { $0.job.id })
        #expect(idsB.contains(b1.id))
        #expect(idsB.contains(b2.id))
    }

    /// Draining "a" leaves "b" pendingCount unchanged.
    @Test func pkStreamIsolationPendingCount() async throws {
        let backend = try await makeBackend()
        try await backend.write(job(1, stream: "a"))
        try await backend.write(job(2, stream: "a"))
        try await backend.write(job(3, stream: "b"))

        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "a")) == 2)
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "b")) == 1)

        // Drain "a" — "b" pending count must remain 1.
        _ = try await backend.drainAvailable(stream: StreamID(rawValue: "a"))
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "a")) == 0)
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "b")) == 1)
    }

    /// pendingCount(stream:) returns only that stream's count, never the total.
    @Test func pkPendingCountIsPerStream() async throws {
        let backend = try await makeBackend()
        for i in 0..<3 { try await backend.write(job(i, stream: "encode")) }
        for i in 3..<7 { try await backend.write(job(i, stream: "dreaming")) }

        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "encode")) == 3)
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "dreaming")) == 4)
        // Total is 7; neither stream count should equal 7.
        #expect(try await backend.pendingCount() == 7)
    }

    // ── Back-compat ─────────────────────────────────────────────────────────

    /// The all-streams drain() still claims everything, unaffected by the
    /// new per-stream methods.
    @Test func pkBackCompatAllStreamsDrain() async throws {
        let backend = try await makeBackend()
        try await backend.write(job(1, stream: "a"))
        try await backend.write(job(2, stream: "b"))
        try await backend.write(job(3, stream: "c"))

        let all = try await backend.drainAvailable()
        #expect(all.count == 3, "all-streams drain must return all 3 jobs")
    }

    /// The all-streams pendingCount() still counts everything.
    @Test func pkBackCompatPendingCount() async throws {
        let backend = try await makeBackend()
        try await backend.write(job(1, stream: "a"))
        try await backend.write(job(2, stream: "b"))

        #expect(try await backend.pendingCount() == 2)
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "a")) == 1)
    }

    // ── Empty streams ────────────────────────────────────────────────────────

    /// Draining a stream with no jobs returns empty without error.
    @Test func pkDrainEmptyStream() async throws {
        let backend = try await makeBackend()
        try await backend.write(job(1, stream: "other"))

        let result = try await backend.drainAvailable(stream: StreamID(rawValue: "nojobs"))
        #expect(result.isEmpty)
    }

    /// pendingCount for a stream with no jobs returns 0.
    @Test func pkPendingCountEmptyStream() async throws {
        let backend = try await makeBackend()
        let count = try await backend.pendingCount(stream: StreamID(rawValue: "nojobs"))
        #expect(count == 0)
    }
}

// MARK: - FilesystemBackend stream-scoped drain

@Suite("Stream-scoped drain — FilesystemBackend", .serialized)
final class StreamScopedDrainFSTests {

    let root: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        root = tmp
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBackend() throws -> FilesystemBackend {
        try FilesystemBackend(root: root, hlcGenerator: HLCGenerator(nodeID: 1))
    }

    private func job(_ i: Int, stream: String) -> Job {
        Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: stream),
            submittedAt: HLC(
                physicalTime: 1_700_000_000_000 + Int64(i),
                logicalCount: 0, nodeID: 1),
            priority: 50,
            payload: Data(),
            extensions: [:])
    }

    // ── Isolation ───────────────────────────────────────────────────────────

    /// drainAvailable(stream:"a") returns ONLY "a" jobs; "b" jobs remain
    /// claimable in new/ and are returned by a subsequent drain for "b".
    @Test func fsStreamIsolationDrain() async throws {
        let backend = try makeBackend()
        let a1 = job(1, stream: "a")
        let a2 = job(2, stream: "a")
        let b1 = job(3, stream: "b")
        let b2 = job(4, stream: "b")

        try await backend.write(a1)
        try await backend.write(b1)
        try await backend.write(a2)
        try await backend.write(b2)

        // Drain stream "a".
        let drainedA = try await backend.drainAvailable(stream: StreamID(rawValue: "a"))
        #expect(drainedA.count == 2, "stream-a drain must return exactly 2 jobs")
        let idsA = Set(drainedA.map { $0.job.id })
        #expect(idsA.contains(a1.id))
        #expect(idsA.contains(a2.id))
        #expect(!idsA.contains(b1.id))
        #expect(!idsA.contains(b2.id))

        // Stream "b" files were un-claimed back to new/ and are still drainable.
        let drainedB = try await backend.drainAvailable(stream: StreamID(rawValue: "b"))
        #expect(drainedB.count == 2, "stream-b drain must return exactly 2 jobs")
        let idsB = Set(drainedB.map { $0.job.id })
        #expect(idsB.contains(b1.id))
        #expect(idsB.contains(b2.id))
    }

    /// pendingCount(stream:) counts only that stream's new/ files.
    @Test func fsStreamIsolationPendingCount() async throws {
        let backend = try makeBackend()
        try await backend.write(job(1, stream: "encode"))
        try await backend.write(job(2, stream: "encode"))
        try await backend.write(job(3, stream: "dreaming"))

        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "encode")) == 2)
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "dreaming")) == 1)

        // Drain "encode" — "dreaming" pending count must remain 1.
        _ = try await backend.drainAvailable(stream: StreamID(rawValue: "encode"))
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "encode")) == 0)
        #expect(try await backend.pendingCount(stream: StreamID(rawValue: "dreaming")) == 1)
    }

    // ── Back-compat ─────────────────────────────────────────────────────────

    /// The all-streams drain() still works unchanged.
    @Test func fsBackCompatAllStreamsDrain() async throws {
        let backend = try makeBackend()
        try await backend.write(job(1, stream: "a"))
        try await backend.write(job(2, stream: "b"))

        let all = try await backend.drainAvailable()
        #expect(all.count == 2)
    }
}

// MARK: - QueueKit facade stream-scoped passthroughs

@Suite("Stream-scoped drain — QueueKit facade")
struct StreamScopedDrainFacadeTests {

    func makeKit() async throws -> QueueKit {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory))
        let backend = PersistenceKitBackend(storage: storage)
        try await PersistenceKitBackend.openSchema(on: storage)
        return QueueKit(backend: backend)
    }

    private func job(_ i: Int, stream: String) -> Job {
        Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: stream),
            submittedAt: HLC(physicalTime: 1_700_000_000_000 + Int64(i),
                             logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
    }

    @Test func facadeDrainStreamPassthrough() async throws {
        let kit = try await makeKit()
        try await kit.send(job(1, stream: "encode"))
        try await kit.send(job(2, stream: "dreaming"))

        let encoded = try await kit.drain(stream: StreamID(rawValue: "encode"))
        #expect(encoded.count == 1)
        #expect(encoded[0].job.streamID.rawValue == "encode")

        // "dreaming" job is still pending.
        #expect(try await kit.pendingCount() == 1)
    }

    @Test func facadePendingCountStreamPassthrough() async throws {
        let kit = try await makeKit()
        try await kit.send(job(1, stream: "encode"))
        try await kit.send(job(2, stream: "encode"))
        try await kit.send(job(3, stream: "dreaming"))

        #expect(try await kit.pendingCount(stream: StreamID(rawValue: "encode")) == 2)
        #expect(try await kit.pendingCount(stream: StreamID(rawValue: "dreaming")) == 1)
    }
}
