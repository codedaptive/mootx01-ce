// PersistenceKitBackendTests.swift
//
// Covers QUEUEKIT_SPEC §10. Uses PersistenceKitInMemory as the backing
// Storage; the contract under test is the QueueKit/PersistenceKit
// integration, not the InMemory implementation itself.

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

@Suite("PersistenceKitBackend (QUEUEKIT_SPEC §10)")
struct PersistenceKitBackendTests {

    func makeBackend() async throws -> PersistenceKitBackend {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory))
        try await PersistenceKitBackend.openSchema(on: storage)
        return PersistenceKitBackend(storage: storage)
    }

    @Test func writeThenDrain() async throws {
        let backend = try await makeBackend()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "s"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data("p".utf8),
            extensions: ["k": .string("v")])
        try await backend.write(job)
        let claimed = try await backend.drainAvailable()
        #expect(claimed.count == 1)
        #expect(claimed[0].0.id == job.id)
        #expect(claimed[0].0.extensions == job.extensions)
    }

    @Test func drainOnEmpty() async throws {
        let backend = try await makeBackend()
        let claimed = try await backend.drainAvailable()
        #expect(claimed.isEmpty)
    }

    @Test func completeMovesToDone() async throws {
        let backend = try await makeBackend()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "s"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        try await backend.write(job)
        _ = try await backend.drainAvailable()
        try await backend.complete(
            job.id, status: .done, artifacts: [])
        let completed = try await backend.completed(streamID: nil)
        #expect(completed.count == 1)
        #expect(completed[0].id == job.id)
    }

    @Test func completeJobNotFound() async throws {
        let backend = try await makeBackend()
        do {
            try await backend.complete(
                JobID(rawValue: "deadbeef000000000000000000000000"),
                status: .done, artifacts: [])
            Issue.record("expected throw")
        } catch QueueError.jobNotFound {
            // expected
        }
    }

    @Test func completeRejectsRunning() async throws {
        let backend = try await makeBackend()
        do {
            try await backend.complete(
                JobID(rawValue: "x"),
                status: .running, artifacts: [])
            Issue.record("expected throw")
        } catch QueueError.invalidTerminalStatus {
            // expected
        }
    }

    // MARK: - Single-pass claim + batch complete-by-session (O(N²)→O(N) fix)

    private func makeJob(_ i: Int) -> Job {
        Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "s"),
            submittedAt: HLC(physicalTime: 1_700_000_000_000 + Int64(i),
                             logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
    }

    /// Single-pass claim: every job claimed in one drain shares ONE batch session
    /// (the bulk new→cur update tags them all), so the batch completes in one
    /// session-scoped update. Mirrors Rust `drain_single_pass_shares_one_session`.
    @Test func drainSinglePassSharesOneSession() async throws {
        let backend = try await makeBackend()
        for i in 0..<5 { try await backend.write(makeJob(i)) }
        let claimed = try await backend.drainAvailable()
        #expect(claimed.count == 5)
        let s0 = claimed[0].1
        #expect(claimed.allSatisfy { $0.1 == s0 },
            "single-pass claim must tag the whole batch with one session")
        #expect(!s0.rawValue.isEmpty)
    }

    /// completeSession retires every still-"cur" job of a batch's session in one
    /// pass. Mirrors Rust `complete_session_retires_whole_batch`.
    @Test func completeSessionRetiresWholeBatch() async throws {
        let backend = try await makeBackend()
        for i in 0..<4 { try await backend.write(makeJob(i)) }
        let claimed = try await backend.drainAvailable()
        let session = claimed[0].1
        #expect(try await backend.inFlight().count == 4)

        let n = try await backend.completeSession(session, status: .done)
        #expect(n == 4, "completeSession must retire all 4 claimed jobs")
        #expect(try await backend.inFlight().isEmpty)
        #expect(try await backend.completed(streamID: nil).count == 4)
    }

    /// completeSession is session-scoped: completing one batch's session leaves a
    /// second batch (different session) in flight. Mirrors Rust
    /// `complete_session_leaves_other_sessions`.
    @Test func completeSessionLeavesOtherSessions() async throws {
        let backend = try await makeBackend()
        try await backend.write(makeJob(1))
        let first = try await backend.drainAvailable()
        let sessionA = first[0].1

        try await backend.write(makeJob(2))
        let second = try await backend.drainAvailable()
        let sessionB = second[0].1
        #expect(sessionA != sessionB, "distinct drains → distinct sessions")

        let n = try await backend.completeSession(sessionA, status: .done)
        #expect(n == 1)
        let inFlight = try await backend.inFlight()
        #expect(inFlight.count == 1, "session B job must remain in flight")
    }

    /// completeSession rejects a non-terminal status (parity with complete()).
    @Test func completeSessionRejectsNonTerminal() async throws {
        let backend = try await makeBackend()
        try await backend.write(makeJob(1))
        let claimed = try await backend.drainAvailable()
        do {
            _ = try await backend.completeSession(claimed[0].1, status: .running)
            Issue.record("expected throw")
        } catch QueueError.invalidTerminalStatus {
            // expected
        }
    }

    /// Concurrent drainers never double-claim a job. Eight tasks drain the same
    /// backend at once; the single-pass bulk update atomically flips new→cur, so
    /// each job is claimed by exactly one session and the drainers partition the
    /// frontier with zero overlap. PersistenceKit twin of the Rust
    /// `concurrent_drainers_no_double_claim`.
    @Test func concurrentDrainersNoDoubleClaim() async throws {
        let backend = try await makeBackend()
        for i in 0..<200 { try await backend.write(makeJob(i)) }

        let claimed = await withTaskGroup(of: [(job: Job, sessionID: SessionID)].self) { group in
            for _ in 0..<8 {
                group.addTask { (try? await backend.drainAvailable()) ?? [] }
            }
            var all: [(job: Job, sessionID: SessionID)] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }

        let ids = claimed.map { $0.job.id }
        #expect(ids.count == 200, "every job claimed exactly once")
        #expect(Set(ids).count == ids.count, "duplicate claim detected across drainers")
    }

    /// At volume, one drain pass claims the whole frontier in a single batch
    /// session and completeSession retires it in one update. Mirrors Rust
    /// `single_pass_claim_and_complete_at_volume`.
    @Test func singlePassClaimAndCompleteAtVolume() async throws {
        let backend = try await makeBackend()
        for i in 0..<1000 { try await backend.write(makeJob(i)) }
        let drained = try await backend.drainAvailable()
        #expect(drained.count == 1000, "one pass claims the whole frontier")
        let session = drained[0].1
        #expect(drained.allSatisfy { $0.1 == session }, "the whole batch shares one session")
        let n = try await backend.completeSession(session, status: .done)
        #expect(n == 1000, "one update retires the whole batch")
        #expect(try await backend.inFlight().isEmpty)
    }

    @Test func tableNotAppendOnly() {
        // Spec §10 v1.1: appendOnly MUST be false.
        let decl = QueueKitSchema.declaration()
        let table = decl.tables.first { $0.name == queueKitTableName }!
        #expect(!table.appendOnly,
            "spec §10 v1.1: jobs table must be mutable, not appendOnly")
    }

    @Test func requiredIndices() {
        let decl = QueueKitSchema.declaration()
        let names = Set(decl.indices.map { $0.name })
        #expect(names.contains("idx_queuekit_status"))
        #expect(names.contains("idx_queuekit_claim_order"))
        #expect(names.contains("idx_queuekit_stream"))
    }

    // MARK: - pendingCount() (TELEMETRY_QT)

    @Test func pendingCountOnEmptyQueue() async throws {
        let backend = try await makeBackend()
        #expect(try await backend.pendingCount() == 0)
    }

    @Test func pendingCountReflectsWrittenJobs() async throws {
        let backend = try await makeBackend()
        let hlc = HLC(physicalTime: 1, logicalCount: 0, nodeID: 1)
        let j1 = Job(id: JobID.generate(), streamID: StreamID(rawValue: "s"),
                     submittedAt: hlc, priority: 50, payload: Data(), extensions: [:])
        let j2 = Job(id: JobID.generate(), streamID: StreamID(rawValue: "s"),
                     submittedAt: hlc, priority: 50, payload: Data(), extensions: [:])
        try await backend.write(j1)
        try await backend.write(j2)
        #expect(try await backend.pendingCount() == 2)
    }

    @Test func pendingCountDropsToZeroAfterDrain() async throws {
        let backend = try await makeBackend()
        let hlc = HLC(physicalTime: 1, logicalCount: 0, nodeID: 1)
        let job = Job(id: JobID.generate(), streamID: StreamID(rawValue: "s"),
                      submittedAt: hlc, priority: 50, payload: Data(), extensions: [:])
        try await backend.write(job)
        #expect(try await backend.pendingCount() == 1)
        _ = try await backend.drainAvailable()
        #expect(try await backend.pendingCount() == 0)
    }
}
