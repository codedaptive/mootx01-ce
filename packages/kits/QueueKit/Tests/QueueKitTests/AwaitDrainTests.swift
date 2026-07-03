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
        makeJob(stream: "encode", tag)
    }

    private func makeJob(stream: String, _ tag: String) -> Job {
        Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: stream),
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

    // MARK: - Stream-scoped barrier ignores other streams (Bug A: encode-stall)

    // On a SHARED queue carrying more than one stream, awaitDrain(stream:) must
    // release once the TARGET stream is clear and must NOT block on other
    // streams' pending jobs (e.g. dreaming enqueued on recall) that a
    // stream-scoped drainer never processes. The GLOBAL awaitDrain WOULD block
    // on them — the post-T4/T6 encode-stall where every capture's encode barrier
    // hung on pending dreaming jobs. Rust twin:
    // await_drain_for_stream_ignores_other_streams.
    @Test func awaitDrainStreamIgnoresOtherStreams() async throws {
        let kit = try makeKit()
        // One encode job + two dreaming jobs on the same (shared) queue.
        try await kit.send(makeJob(stream: "encode", "e"))
        try await kit.send(makeJob(stream: "dreaming", "d1"))
        try await kit.send(makeJob(stream: "dreaming", "d2"))

        // Drain + reply ONLY the encode stream.
        let batch = try await kit.drain(stream: StreamID(rawValue: "encode"))
        #expect(batch.count == 1)
        for pair in batch {
            try await kit.reply(to: pair.job.id, status: .done, artifacts: [])
        }

        // The encode stream is clear; dreaming still has 2 pending. The
        // stream-scoped barrier must release promptly anyway.
        let start = ContinuousClock.now
        try await kit.awaitDrain(
            stream: StreamID(rawValue: "encode"),
            pollInterval: .milliseconds(20), timeout: .seconds(5))
        #expect((ContinuousClock.now - start) < .seconds(1))

        // Sanity: the GLOBAL barrier WOULD time out — proving the bug the
        // stream-scoped barrier fixes (dreaming jobs still pending).
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

    // MARK: - Progress resets the no-progress deadline (GLK full-suite fix)

    // A slow-but-progressing drain must NOT time out even when the TOTAL wait
    // exceeds `timeout`: the deadline resets each time the outstanding count
    // (pending + in-flight) drops below its lowest observed value. This is the
    // regression test for the GLK full-suite drainTimeout fragility, where
    // CPU-starved encode workers drained slowly but steadily and a wall-clock
    // cap false-timed-out a correct drain. Rust twin:
    // await_drain_progress_resets_deadline.
    @Test func awaitDrainProgressResetsDeadline() async throws {
        let kit = try makeKit()
        for tag in ["a", "b", "c", "d"] { try await kit.send(makeJob(tag)) }

        // Worker: claim all four up front (pending → in-flight), then reply
        // one every 200 ms. Total drain ≈ 800 ms — double the 400 ms timeout —
        // but every completion lands well inside a fresh 400 ms window.
        let worker = Task {
            let batch = try await kit.drain()
            for pair in batch {
                try await Task.sleep(for: .milliseconds(200))
                try await kit.reply(
                    to: pair.job.id, status: .done, artifacts: [])
            }
        }

        // A wall-clock cap would throw at 400 ms with jobs still in flight;
        // the progress-based deadline must ride the resets to completion.
        try await kit.awaitDrain(
            pollInterval: .milliseconds(10), timeout: .milliseconds(400))
        try await worker.value
        #expect(try await kit.completed().count == 4)
    }

    // Partial progress then a stall must STILL time out: replying one of three
    // jobs resets the deadline once, but the remaining two never move, so the
    // no-progress deadline fires. Proves progress-based ≠ never-times-out.
    // Rust twin: await_drain_times_out_when_progress_stalls.
    @Test func awaitDrainTimesOutWhenProgressStalls() async throws {
        let kit = try makeKit()
        for tag in ["a", "b", "c"] { try await kit.send(makeJob(tag)) }
        // Claim all three (new/ → cur/), reply exactly ONE, then stall.
        let batch = try await kit.drain()
        try await kit.reply(to: batch[0].job.id, status: .done, artifacts: [])

        var threwTimeout = false
        do {
            try await kit.awaitDrain(
                pollInterval: .milliseconds(10), timeout: .milliseconds(150))
        } catch QueueError.drainTimeout(let pending, let inFlight) {
            threwTimeout = true
            #expect(pending == 0)
            #expect(inFlight == 2)
        }
        #expect(threwTimeout)
    }
}
