// FilesystemBackendTests.swift
//
// Covers QUEUEKIT_SPEC §5, §6, §8, §9 — the FilesystemBackend
// reference implementation in Swift.

import Testing
import Foundation
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
@testable import QueueKit

@Suite("FilesystemBackend (QUEUEKIT_SPEC §5/§6/§8/§9)", .serialized)
final class FilesystemBackendTests {

    let root: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        root = tmp
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeKit(nodeID: Int32 = 1) throws -> QueueKit {
        try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: nodeID))
    }

    @Test func maildirInitCreatesFourDirs() throws {
        _ = try makeKit()
        for sub in ["tmp", "new", "cur", "done"] {
            var isDir: ObjCBool = false
            let p = root.appendingPathComponent(sub).path
            #expect(FileManager.default.fileExists(
                atPath: p, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    @Test func sendThenDrainRoundTrip() async throws {
        let kit = try makeKit()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "stream-a"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50,
            payload: Data("hello".utf8),
            extensions: ["k": .string("v")])
        try await kit.send(job)
        let claimed = try await kit.drain()
        #expect(claimed.count == 1)
        #expect(claimed[0].job.id == job.id)
        #expect(claimed[0].job.extensions == job.extensions)
    }

    @Test func transitionsAreAtomic() async throws {
        let kit = try makeKit()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "x"),
            submittedAt: HLC(physicalTime: 2, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(),
            extensions: [:])
        try await kit.send(job)
        #expect(filesIn("new").count == 1)
        #expect(filesIn("cur").count == 0)
        let claimed = try await kit.drain()
        #expect(claimed.count == 1)
        #expect(filesIn("new").count == 0)
        #expect(filesIn("cur").count == 1)
        try await kit.reply(
            to: job.id, status: .done, artifacts: [])
        #expect(filesIn("cur").count == 0)
        // done/ contains the job file + the signal file
        let done = filesIn("done")
        #expect(done.contains { $0.hasSuffix(".signal") })
    }

    @Test func signalWrittenBeforeJobMoved() async throws {
        let kit = try makeKit()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "x"),
            submittedAt: HLC(physicalTime: 3, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(),
            extensions: [:])
        try await kit.send(job)
        _ = try await kit.drain()
        try await kit.reply(
            to: job.id, status: .done, artifacts: [])
        let signalPath = root.appendingPathComponent(
            "done/\(job.id.rawValue).signal").path
        #expect(FileManager.default.fileExists(atPath: signalPath))
    }

    @Test func replyRejectsNonTerminalStatus() async throws {
        let kit = try makeKit()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "x"),
            submittedAt: HLC(physicalTime: 4, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        try await kit.send(job)
        _ = try await kit.drain()
        do {
            try await kit.reply(
                to: job.id, status: .running, artifacts: [])
            Issue.record("expected throw")
        } catch QueueError.invalidTerminalStatus {
            // expected
        }
    }

    @Test func replyJobNotFound() async throws {
        let kit = try makeKit()
        do {
            try await kit.reply(
                to: JobID(rawValue: "deadbeef000000000000000000000000"),
                status: .done, artifacts: [])
            Issue.record("expected throw")
        } catch QueueError.jobNotFound {
            // expected
        }
    }

    @Test func staleTmpCleanup() async throws {
        _ = try makeKit()
        let stale = root.appendingPathComponent("tmp/stale-file").path
        FileManager.default.createFile(
            atPath: stale, contents: Data("stale".utf8))
        // Backdate it
        let ancient = Date(timeIntervalSinceNow: -10 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: ancient],
            ofItemAtPath: stale)
        // Re-init: this should clean it up
        _ = try makeKit()
        #expect(!FileManager.default.fileExists(atPath: stale))
    }

    @Test func drainOnEmpty() async throws {
        let kit = try makeKit()
        let claimed = try await kit.drain()
        #expect(claimed.isEmpty)
    }

    @Test func hlcOrderInDrain() async throws {
        let kit = try makeKit()
        // Insert in reverse order; expect drain to return in HLC order.
        let later = Job(
            id: JobID(rawValue: "bb" + String(repeating: "0", count: 30)),
            streamID: StreamID(rawValue: "x"),
            submittedAt: HLC(physicalTime: 200, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        let earlier = Job(
            id: JobID(rawValue: "aa" + String(repeating: "0", count: 30)),
            streamID: StreamID(rawValue: "x"),
            submittedAt: HLC(physicalTime: 100, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        try await kit.send(later)
        try await kit.send(earlier)
        let claimed = try await kit.drain()
        #expect(claimed.count == 2)
        #expect(claimed[0].job.submittedAt.physicalTime == 100)
        #expect(claimed[1].job.submittedAt.physicalTime == 200)
    }

    // MARK: - helpers

    private func filesIn(_ sub: String) -> [String] {
        let dir = root.appendingPathComponent(sub).path
        return (try? FileManager.default.contentsOfDirectory(
            atPath: dir)) ?? []
    }
}
