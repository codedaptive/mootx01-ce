// SupportingTypeTests.swift
//
// Covers QUEUEKIT_SPEC §6 wire format and §7 supporting types.

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

final class SupportingTypeTests: XCTestCase {

    func testObservationStatusRawValues() {
        XCTAssertEqual(ObservationStatus.running.rawValue, "running")
        XCTAssertEqual(ObservationStatus.done.rawValue, "done")
        XCTAssertEqual(
            ObservationStatus.doneWithConcerns.rawValue,
            "done_with_concerns")
        XCTAssertEqual(
            ObservationStatus.needsContext.rawValue, "needs_context")
        XCTAssertEqual(ObservationStatus.blocked.rawValue, "blocked")
    }

    func testObservationStatusTerminalDiscrimination() {
        XCTAssertFalse(ObservationStatus.running.isTerminal)
        XCTAssertTrue(ObservationStatus.done.isTerminal)
        XCTAssertTrue(ObservationStatus.doneWithConcerns.isTerminal)
        XCTAssertTrue(ObservationStatus.needsContext.isTerminal)
        XCTAssertTrue(ObservationStatus.blocked.isTerminal)
    }

    func testJobIDIs32LowercaseHex() {
        let id = JobID.generate()
        XCTAssertEqual(id.rawValue.count, 32)
        XCTAssertTrue(id.rawValue.allSatisfy {
            ($0.isNumber || ($0 >= "a" && $0 <= "f"))
        })
    }

    func testSortableHLCFormat() {
        // Spec §6: {physicalTime:016d}-{logicalCount:08d}-
        //          {nodeID_unsigned:010d}
        let hlc = HLC(
            physicalTime: 1747526400000,
            logicalCount: 0,
            nodeID: Int32(bitPattern: 3735928559))  // 0xDEADBEEF
        let s = WireFormat.sortableHLC(hlc)
        XCTAssertEqual(s, "0001747526400000-00000000-3735928559")
    }

    func testFilenameMatchesSpecExample() {
        // Spec §6 concrete example:
        // 0001747526400000-00000000-3735928559-deadbeef00...
        let job = Job(
            id: JobID(rawValue: "deadbeef000000000000000000000000"),
            streamID: StreamID(rawValue: "my-stream"),
            submittedAt: HLC(
                physicalTime: 1747526400000,
                logicalCount: 0,
                nodeID: Int32(bitPattern: 3735928559)),
            priority: 50,
            payload: Data(),
            extensions: [:])
        let filename = WireFormat.filename(for: job)
        XCTAssertEqual(filename,
            "0001747526400000-00000000-3735928559-my-stream-deadbeef000000000000000000000000")
    }

    func testJobJSONRoundTrip() throws {
        let original = Job(
            id: JobID(rawValue: "deadbeef000000000000000000000000"),
            streamID: StreamID(rawValue: "my-stream"),
            submittedAt: HLC(
                physicalTime: 1747526400000,
                logicalCount: 0,
                nodeID: Int32(bitPattern: 3735928559)),
            priority: 50,
            payload: Data("hello".utf8),
            extensions: ["k": .string("v")])
        let encoded = try WireFormat.encoder.encode(original)
        let decoded = try WireFormat.decoder.decode(
            Job.self, from: encoded)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.streamID, original.streamID)
        XCTAssertEqual(decoded.submittedAt, original.submittedAt)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(decoded.extensions, original.extensions)
    }

    func testBase64URLNoPadding() {
        let cases: [(Data, String)] = [
            (Data(), ""),
            (Data([0xff]), "_w"),
            (Data([0xfb, 0xff]), "-_8"),
        ]
        for (data, expected) in cases {
            XCTAssertEqual(Job.base64urlEncode(data), expected)
            XCTAssertEqual(Job.base64urlDecode(expected), data)
        }
    }

    func testSignalFileJSONShape() throws {
        let sig = SignalFile(
            jobID: JobID(rawValue: "deadbeef000000000000000000000000"),
            status: .done,
            artifacts: [],
            completedAt: HLC(
                physicalTime: 1747526400000,
                logicalCount: 1,
                nodeID: Int32(bitPattern: 3735928559)))
        let data = try WireFormat.encoder.encode(sig)
        let s = String(data: data, encoding: .utf8)!
        // Keys appear sorted: artifacts, completed_at, job_id, status
        XCTAssertTrue(s.contains("\"status\":\"done\""))
        XCTAssertTrue(s.contains("\"job_id\":\"deadbeef000000000000000000000000\""))
        XCTAssertTrue(s.contains("\"physical_time\":1747526400000"))
    }

    func testArtifactRefRoundTrip() throws {
        let arts: [ArtifactRef] = [
            .filePath("/tmp/x"),
            .commitHash("abc"),
            .signalFile("/x.signal"),
            .trajectoryStepID("step-1"),
        ]
        let data = try WireFormat.encoder.encode(arts)
        let decoded = try WireFormat.decoder.decode(
            [ArtifactRef].self, from: data)
        XCTAssertEqual(decoded, arts)
    }
}
