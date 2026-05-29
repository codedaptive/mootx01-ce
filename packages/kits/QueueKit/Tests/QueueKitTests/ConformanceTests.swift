// ConformanceTests.swift
//
// Full conformance per QUEUEKIT_SPEC §12. Six areas. Area 4
// (concurrent claim) is the acceptance gate. Any duplicate claim is
// a blocking failure.

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

final class ConformanceTests: XCTestCase {

    var root: URL!

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-conf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        root = tmp
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Area 1: Schema round-trip

    func testArea1Schema() async throws {
        let kit = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 1))
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "round"),
            submittedAt: HLC(physicalTime: 100, logicalCount: 1, nodeID: 7),
            priority: 42,
            payload: Data([0x01, 0x02, 0x03]),
            extensions: [
                "k": .string("v"),
                "n": .int(99),
                "nest": .object(["a": .array([.int(1), .int(2)])]),
            ])
        try await kit.send(job)
        let claimed = try await kit.drain()
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed[0].job.id, job.id)
        XCTAssertEqual(claimed[0].job.streamID, job.streamID)
        XCTAssertEqual(claimed[0].job.submittedAt, job.submittedAt)
        XCTAssertEqual(claimed[0].job.priority, job.priority)
        XCTAssertEqual(claimed[0].job.payload, job.payload)
        XCTAssertEqual(claimed[0].job.extensions, job.extensions)
    }

    // MARK: - Area 2: Transition correctness

    func testArea2Transitions() async throws {
        let kit = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 1))
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "t"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        try await kit.send(job)
        XCTAssertEqual(countIn("new"), 1)
        XCTAssertEqual(countIn("cur"), 0)
        XCTAssertEqual(countIn("done"), 0)
        _ = try await kit.drain()
        XCTAssertEqual(countIn("new"), 0)
        XCTAssertEqual(countIn("cur"), 1)
        XCTAssertEqual(countIn("done"), 0)
        try await kit.reply(
            to: job.id, status: .done, artifacts: [])
        XCTAssertEqual(countIn("cur"), 0)
        // done contains 2 entries: job file + signal
        XCTAssertEqual(countIn("done"), 2)
    }

    // MARK: - Area 3: Signal before rename

    func testArea3SignalCorrectness() async throws {
        let kit = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 1))
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "s"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        try await kit.send(job)
        _ = try await kit.drain()
        try await kit.reply(
            to: job.id, status: .doneWithConcerns, artifacts: [])
        let signalPath = root.appendingPathComponent(
            "done/\(job.id.rawValue).signal").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: signalPath))
        let data = try Data(contentsOf:
            URL(fileURLWithPath: signalPath))
        let sig = try WireFormat.decoder.decode(
            SignalFile.self, from: data)
        XCTAssertEqual(sig.status, .doneWithConcerns)
        XCTAssertEqual(sig.jobID, job.id)
    }

    // MARK: - Area 4 (ACCEPTANCE GATE): Concurrent claim

    func testArea4ConcurrentClaimFilesystem() async throws {
        let kit = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 1))
        // 100 jobs
        for i in 0..<100 {
            let job = Job(
                id: JobID(rawValue:
                    String(format: "%032x", i)),
                streamID: StreamID(rawValue: "c"),
                submittedAt: HLC(
                    physicalTime: Int64(i),
                    logicalCount: 0, nodeID: 1),
                priority: 50, payload: Data(),
                extensions: [:])
            try await kit.send(job)
        }
        XCTAssertEqual(countIn("new"), 100)

        // 10 concurrent drainers
        let drainerCount = 10
        let collected = AtomicArray<JobID>()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<drainerCount {
                group.addTask {
                    do {
                        let claimed = try await kit.drain()
                        for c in claimed {
                            await collected.append(c.job.id)
                        }
                    } catch {
                        XCTFail("drain failed: \(error)")
                    }
                }
            }
            await group.waitForAll()
        }
        let all = await collected.snapshot()
        XCTAssertEqual(all.count, 100,
            "expected 100 claimed, got \(all.count)")
        XCTAssertEqual(Set(all).count, all.count,
            "Area 4 BLOCKING: duplicate claim detected")
    }

    // MARK: - Area 5: Extension preservation

    func testArea5Extensions() async throws {
        let kit = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 1))
        let extensions: [String: CodableValue] = [
            "string": .string("hello"),
            "int": .int(42),
            "bool": .bool(true),
            "null": .null,
            "nested": .object(["a": .array([.int(1), .int(2)])]),
        ]
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "e"),
            submittedAt: HLC(physicalTime: 5, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data("p".utf8),
            extensions: extensions)
        try await kit.send(job)
        let claimed = try await kit.drain()
        XCTAssertEqual(claimed[0].job.extensions, extensions)
        try await kit.reply(
            to: job.id, status: .done, artifacts: [])
        let done = try await kit.completed(streamID: StreamID(rawValue: "e"))
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done[0].extensions, extensions)
    }

    // MARK: - Area 6: Stale tmp recovery

    func testArea6StaleTmpRecovery() async throws {
        _ = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 1))
        let stale = root.appendingPathComponent("tmp/stale").path
        FileManager.default.createFile(
            atPath: stale, contents: Data("x".utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: stale)
        // Re-init — Area 6 says: on reinit, stale gone, no job lost.
        _ = try QueueKit(
            root: root,
            hlcGenerator: HLCGenerator(nodeID: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
    }

    // MARK: - helpers

    private func countIn(_ sub: String) -> Int {
        let dir = root.appendingPathComponent(sub).path
        return ((try? FileManager.default.contentsOfDirectory(
            atPath: dir)) ?? []).count
    }
}

/// Actor providing thread-safe accumulation for the concurrent
/// claim test (Area 4).
actor AtomicArray<Element> {
    private var items: [Element] = []
    func append(_ e: Element) { items.append(e) }
    func snapshot() -> [Element] { items }
}
