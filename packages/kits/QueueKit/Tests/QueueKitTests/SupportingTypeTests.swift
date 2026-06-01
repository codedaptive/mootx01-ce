// SupportingTypeTests.swift
//
// Covers QUEUEKIT_SPEC §6 wire format and §7 supporting types.

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

@Suite("Supporting types (QUEUEKIT_SPEC §6/§7)")
struct SupportingTypeTests {

    @Test func observationStatusRawValues() {
        #expect(ObservationStatus.running.rawValue == "running")
        #expect(ObservationStatus.done.rawValue == "done")
        #expect(
            ObservationStatus.doneWithConcerns.rawValue ==
            "done_with_concerns")
        #expect(
            ObservationStatus.needsContext.rawValue == "needs_context")
        #expect(ObservationStatus.blocked.rawValue == "blocked")
    }

    @Test func observationStatusTerminalDiscrimination() {
        #expect(!ObservationStatus.running.isTerminal)
        #expect(ObservationStatus.done.isTerminal)
        #expect(ObservationStatus.doneWithConcerns.isTerminal)
        #expect(ObservationStatus.needsContext.isTerminal)
        #expect(ObservationStatus.blocked.isTerminal)
    }

    @Test func jobIDIs32LowercaseHex() {
        let id = JobID.generate()
        #expect(id.rawValue.count == 32)
        #expect(id.rawValue.allSatisfy {
            ($0.isNumber || ($0 >= "a" && $0 <= "f"))
        })
    }

    @Test func sortableHLCFormat() {
        // Spec §6: {physicalTime:016d}-{logicalCount:08d}-
        //          {nodeID_unsigned:010d}
        let hlc = HLC(
            physicalTime: 1747526400000,
            logicalCount: 0,
            nodeID: Int32(bitPattern: 3735928559))  // 0xDEADBEEF
        let s = WireFormat.sortableHLC(hlc)
        #expect(s == "0001747526400000-00000000-3735928559")
    }

    @Test func filenameMatchesSpecExample() {
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
        #expect(filename ==
            "0001747526400000-00000000-3735928559-my-stream-deadbeef000000000000000000000000")
    }

    @Test func jobJSONRoundTrip() throws {
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
        #expect(decoded.id == original.id)
        #expect(decoded.streamID == original.streamID)
        #expect(decoded.submittedAt == original.submittedAt)
        #expect(decoded.priority == original.priority)
        #expect(decoded.payload == original.payload)
        #expect(decoded.extensions == original.extensions)
    }

    @Test func base64URLNoPadding() {
        let cases: [(Data, String)] = [
            (Data(), ""),
            (Data([0xff]), "_w"),
            (Data([0xfb, 0xff]), "-_8"),
        ]
        for (data, expected) in cases {
            #expect(Job.base64urlEncode(data) == expected)
            #expect(Job.base64urlDecode(expected) == data)
        }
    }

    @Test func signalFileJSONShape() throws {
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
        #expect(s.contains("\"status\":\"done\""))
        #expect(s.contains("\"job_id\":\"deadbeef000000000000000000000000\""))
        #expect(s.contains("\"physical_time\":1747526400000"))
    }

    @Test func artifactRefRoundTrip() throws {
        let arts: [ArtifactRef] = [
            .filePath("/tmp/x"),
            .commitHash("abc"),
            .signalFile("/x.signal"),
            .trajectoryStepID("step-1"),
        ]
        let data = try WireFormat.encoder.encode(arts)
        let decoded = try WireFormat.decoder.decode(
            [ArtifactRef].self, from: data)
        #expect(decoded == arts)
    }
}
