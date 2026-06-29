// ReclaimInFlightTests.swift
//
// Tests for crash-recovery GC: PersistenceKitBackend.reclaimInFlight(stream:)
// and the QueueKit facade passthrough.
//
// Success criteria (Mission #54, Part A):
//   1. reclaim count: reclaimInFlight returns the exact count of cur rows reset.
//   2. state after reclaim: reclaimed rows become "new" and are claimable again.
//   3. stream isolation: reclaiming stream A does NOT affect stream B's cur rows.
//   4. empty queue: returns 0 when no cur rows exist for the stream.
//   5. facade passthrough: QueueKit.reclaimInFlight(stream:) delegates to
//      PersistenceKitBackend and returns the correct count.
//   6. done rows untouched: reclaimInFlight does not reset "done" rows.

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

// MARK: - Helpers

private let streamEncode = StreamID(rawValue: "encode")
private let streamDreaming = StreamID(rawValue: "dreaming")

private func makeBackend() async throws -> PersistenceKitBackend {
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory))
    try await PersistenceKitBackend.openSchema(on: storage)
    return PersistenceKitBackend(storage: storage)
}

private func job(stream: StreamID, seq: Int = 0) -> Job {
    Job(
        id: JobID.generate(),
        streamID: stream,
        submittedAt: HLC(
            physicalTime: 1_700_000_000_000 + Int64(seq),
            logicalCount: 0, nodeID: 1),
        priority: 50,
        payload: Data("payload-\(seq)".utf8),
        extensions: [:])
}

// MARK: - PersistenceKitBackend.reclaimInFlight(stream:)

@Suite("PersistenceKitBackend.reclaimInFlight (Mission #54 Part A)")
struct ReclaimInFlightTests {

    // MARK: 1. Reclaim count

    @Test("returns count of cur rows reset for the stream")
    func reclaimCountAccurate() async throws {
        let backend = try await makeBackend()

        // Write two encode jobs and one dreaming job; drain all to cur.
        let j1 = job(stream: streamEncode, seq: 1)
        let j2 = job(stream: streamEncode, seq: 2)
        let j3 = job(stream: streamDreaming, seq: 3)
        try await backend.write(j1)
        try await backend.write(j2)
        try await backend.write(j3)
        _ = try await backend.drainAvailable()  // claims all three → cur

        // Reclaim only the encode stream.
        let reclaimed = try await backend.reclaimInFlight(stream: streamEncode)
        #expect(reclaimed == 2)
    }

    // MARK: 2. State after reclaim — rows become new and are re-claimable

    @Test("reclaimed rows are re-claimable from drainAvailable")
    func reclaimedRowsAreNewAndClaimable() async throws {
        let backend = try await makeBackend()

        let j = job(stream: streamEncode, seq: 1)
        try await backend.write(j)
        _ = try await backend.drainAvailable()     // → cur

        // Nothing pending before reclaim.
        let pendingBefore = try await backend.pendingCount(stream: streamEncode)
        #expect(pendingBefore == 0)

        try await backend.reclaimInFlight(stream: streamEncode)

        // After reclaim the row is back in "new" — pendingCount sees it.
        let pendingAfter = try await backend.pendingCount(stream: streamEncode)
        #expect(pendingAfter == 1)

        // drainAvailable picks it up again.
        let claimed = try await backend.drainAvailable(stream: streamEncode)
        #expect(claimed.count == 1)
        #expect(claimed[0].0.id == j.id)
    }

    // MARK: 3. Stream isolation — reclaiming encode must not affect dreaming

    @Test("reclaiming encode stream leaves dreaming stream cur rows intact")
    func streamIsolation() async throws {
        let backend = try await makeBackend()

        let encodeJob = job(stream: streamEncode, seq: 1)
        let dreamJob  = job(stream: streamDreaming, seq: 2)
        try await backend.write(encodeJob)
        try await backend.write(dreamJob)
        _ = try await backend.drainAvailable()   // both → cur

        // Reclaim only encode.
        let count = try await backend.reclaimInFlight(stream: streamEncode)
        #expect(count == 1)

        // Dreaming row is still cur — not in pending.
        let dreamPending = try await backend.pendingCount(stream: streamDreaming)
        #expect(dreamPending == 0)

        // Dreaming row is still in-flight.
        let inFlight = try await backend.inFlight()
        #expect(inFlight.count == 1)
        #expect(inFlight[0].streamID == streamDreaming)
    }

    // MARK: 4. Empty queue returns 0

    @Test("returns 0 when no cur rows exist for the stream")
    func emptyQueueReturnsZero() async throws {
        let backend = try await makeBackend()
        let count = try await backend.reclaimInFlight(stream: streamEncode)
        #expect(count == 0)
    }

    // MARK: 5. Done rows are NOT reset by reclaimInFlight

    @Test("done rows are untouched by reclaimInFlight")
    func doneRowsUntouched() async throws {
        let backend = try await makeBackend()

        let j = job(stream: streamEncode, seq: 1)
        try await backend.write(j)
        let claimed = try await backend.drainAvailable()
        let (claimedJob, _) = claimed[0]
        try await backend.complete(claimedJob.id, status: .done, artifacts: [])

        // One done row; zero cur rows.
        let reclaimed = try await backend.reclaimInFlight(stream: streamEncode)
        #expect(reclaimed == 0)

        // Done count is still 1.
        let done = try await backend.completed(streamID: streamEncode)
        #expect(done.count == 1)
    }
}

// MARK: - QueueKit facade passthrough

@Suite("QueueKit.reclaimInFlight facade (Mission #54 Part A)")
struct QueueKitReclaimFacadeTests {

    private func makeKit() async throws -> QueueKit {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory))
        try await PersistenceKitBackend.openSchema(on: storage)
        let backend = PersistenceKitBackend(storage: storage)
        return QueueKit(backend: backend)
    }

    @Test("facade delegates to PersistenceKitBackend and returns count")
    func facadeDelegatesCorrectly() async throws {
        let kit = try await makeKit()

        // Write two encode jobs via the facade; drain them to cur.
        for i in 0..<2 {
            let j = job(stream: streamEncode, seq: i)
            try await kit.send(j)
        }
        _ = try await kit.drain(stream: streamEncode)

        let reclaimed = try await kit.reclaimInFlight(stream: streamEncode)
        #expect(reclaimed == 2)
    }

    @Test("facade returns 0 when backend is not PersistenceKitBackend")
    func facadeReturnsZeroForFilesystemBackend() async throws {
        // FilesystemBackend does not implement stream-scoped reclaimInFlight;
        // the facade should return 0 gracefully for that backend.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-reclaim-fs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let kit = try QueueKit(root: tmp, hlcGenerator: HLCGenerator(nodeID: 1))

        let count = try await kit.reclaimInFlight(stream: streamEncode)
        #expect(count == 0)
    }
}
