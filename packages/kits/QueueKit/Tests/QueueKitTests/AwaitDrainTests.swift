// AwaitDrainTests.swift
//
// Covers the await-empty latch added for the Dual-Path Intake wiring
// (P5): `QueueKit.awaitDrain(...)` blocks until both maildir frontiers
// (pending `new/` and in-flight `cur/`) are clear, returns promptly on an
// already-empty queue, and times out rather than hanging when work never
// completes.

import Testing
import Foundation
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md.
// ─────────────────────────────────────────────────────────────────
@testable import QueueKit

@Suite("awaitDrain await-empty latch (Dual-Path Intake P5)", .serialized)
final class AwaitDrainTests {

    let root: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-awaitdrain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        root = tmp
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeKit() throws -> QueueKit {
        try QueueKit(root: root, hlcGenerator: HLCGenerator(nodeID: 1))
    }

    private func makeJob(_ tag: String) -> Job {
        Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "encode"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50,
            payload: Data(tag.utf8))
    }

    // MARK: - Returns promptly on an already-empty queue

    @Test func awaitDrainReturnsPromptlyWhenAlreadyEmpty() async throws {
        let kit = try makeKit()
        // Nothing sent — both frontiers are already clear. The first poll
        // must see zero/zero and return without sleeping or timing out.
        let start = ContinuousClock.now
        try await kit.awaitDrain()
        let elapsed = ContinuousClock.now - start
        // Far below the 20 ms poll interval: it returned on the first probe.
        #expect(elapsed < .milliseconds(15))
    }

    // MARK: - Releases only after the last job is drained AND replied

    @Test func awaitDrainReleasesAfterFullProcessing() async throws {
        let kit = try makeKit()
        try await kit.send(makeJob("a"))
        try await kit.send(makeJob("b"))

        // A concurrent "worker": drain both, then reply terminal for each so
        // they move new/ → cur/ → done/. awaitDrain must not release until
        // both replies have landed.
        let worker = Task {
            // Small stagger so awaitDrain observes a non-empty frontier first.
            try await Task.sleep(for: .milliseconds(30))
            let batch = try await kit.drain()
            for pair in batch {
                try await kit.reply(
                    to: pair.job.id, status: .done, artifacts: [])
            }
        }

        try await kit.awaitDrain()
        try await worker.value

        // Post-condition: both frontiers empty.
        #expect(try await kit.inFlight().isEmpty)
        let pending = try await kit.backend.pendingCount()
        #expect(pending == 0)
        // Both jobs landed in done/.
        #expect(try await kit.completed().count == 2)
    }

    // MARK: - Does NOT release while a job is claimed but not replied

    @Test func awaitDrainBlocksWhileInFlight() async throws {
        let kit = try makeKit()
        try await kit.send(makeJob("a"))
        // Claim the job (new/ → cur/) but never reply — it stays in-flight.
        _ = try await kit.drain()
        #expect(try await kit.inFlight().count == 1)

        // awaitDrain with a short timeout must throw drainTimeout, proving it
        // treats an unreplied in-flight job as "not yet drained" and does not
        // release early.
        await #expect(throws: QueueError.self) {
            try await kit.awaitDrain(
                pollInterval: .milliseconds(10), timeout: .milliseconds(120))
        }
    }

    // MARK: - Times out rather than hanging when pending never clears

    @Test func awaitDrainTimesOutOnStuckPending() async throws {
        let kit = try makeKit()
        try await kit.send(makeJob("a"))
        // No worker drains it — the job sits in new/ forever. awaitDrain must
        // surface a bounded drainTimeout, never hang.
        var threwTimeout = false
        do {
            try await kit.awaitDrain(
                pollInterval: .milliseconds(10), timeout: .milliseconds(100))
        } catch QueueError.drainTimeout(let pending, let inFlight) {
            threwTimeout = true
            #expect(pending == 1)
            #expect(inFlight == 0)
        }
        #expect(threwTimeout)
    }
}
