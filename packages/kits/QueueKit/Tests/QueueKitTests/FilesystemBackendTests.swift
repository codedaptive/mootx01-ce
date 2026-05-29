// FilesystemBackendTests.swift
//
// Covers QUEUEKIT_SPEC §5, §6, §8, §9 — the FilesystemBackend
// reference implementation in Swift.

import XCTest
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
import SubstrateLib
@testable import QueueKit

final class FilesystemBackendTests: XCTestCase {

    var root: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        root = tmp
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeKit(nodeID: Int32 = 1) throws -> QueueKit {
        try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: nodeID))
    }

    func testMaildirInitCreatesFourDirs() throws {
        _ = try makeKit()
        for sub in ["tmp", "new", "cur", "done"] {
            var isDir: ObjCBool = false
            let p = root.appendingPathComponent(sub).path
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: p, isDirectory: &isDir))
            XCTAssertTrue(isDir.boolValue)
        }
    }

    func testSendThenDrainRoundTrip() async throws {
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
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed[0].job.id, job.id)
        XCTAssertEqual(claimed[0].job.extensions, job.extensions)
    }

    func testTransitionsAreAtomic() async throws {
        let kit = try makeKit()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "x"),
            submittedAt: HLC(physicalTime: 2, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(),
            extensions: [:])
        try await kit.send(job)
        XCTAssertEqual(filesIn("new").count, 1)
        XCTAssertEqual(filesIn("cur").count, 0)
        let claimed = try await kit.drain()
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(filesIn("new").count, 0)
        XCTAssertEqual(filesIn("cur").count, 1)
        try await kit.reply(
            to: job.id, status: .done, artifacts: [])
        XCTAssertEqual(filesIn("cur").count, 0)
        // done/ contains the job file + the signal file
        let done = filesIn("done")
        XCTAssertTrue(done.contains { $0.hasSuffix(".signal") })
    }

    func testSignalWrittenBeforeJobMoved() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: signalPath))
    }

    func testReplyRejectsNonTerminalStatus() async throws {
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
            XCTFail("expected throw")
        } catch QueueError.invalidTerminalStatus {
            // expected
        }
    }

    func testReplyJobNotFound() async throws {
        let kit = try makeKit()
        do {
            try await kit.reply(
                to: JobID(rawValue: "deadbeef000000000000000000000000"),
                status: .done, artifacts: [])
            XCTFail("expected throw")
        } catch QueueError.jobNotFound {
            // expected
        }
    }

    func testStaleTmpCleanup() async throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
    }

    func testDrainOnEmpty() async throws {
        let kit = try makeKit()
        let claimed = try await kit.drain()
        XCTAssertTrue(claimed.isEmpty)
    }

    func testHLCOrderInDrain() async throws {
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
        XCTAssertEqual(claimed.count, 2)
        XCTAssertEqual(claimed[0].job.submittedAt.physicalTime, 100)
        XCTAssertEqual(claimed[1].job.submittedAt.physicalTime, 200)
    }

    // MARK: - helpers

    private func filesIn(_ sub: String) -> [String] {
        let dir = root.appendingPathComponent(sub).path
        return (try? FileManager.default.contentsOfDirectory(
            atPath: dir)) ?? []
    }
}
