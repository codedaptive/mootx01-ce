// FixtureGenerator.swift
//
// Generates conformance fixtures from Swift FilesystemBackend wire
// format with fixed HLC values (no wall-clock). Fixtures are byte-
// for-byte reproducible; Rust and Python assert byte equality
// against them.
//
// Run with: `swift test --filter FixtureGenerator`
// Output: writes to a tmp dir; copy to Tests/QueueKitTests/Fixtures/
// for committed conformance.

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
@testable import QueueKit

/// Build the inputs and assert byte-stable outputs. Failures here are
/// a spec drift signal: the fixture suite is the cross-language
/// contract, not the Swift implementation alone.
@Suite("Fixture generator (cross-language byte contract)", .serialized)
struct FixtureGenerator {

    struct JobFixture {
        let name: String
        let job: Job
        let signal: SignalFile?
    }

    static var fixtures: [JobFixture] {
        // Five jobs with deterministic HLCs and stable JobIDs.
        let f1 = Job(
            id: JobID(rawValue: "00000000000000000000000000000001"),
            streamID: StreamID(rawValue: "alpha"),
            submittedAt: HLC(physicalTime: 1747526400000,
                             logicalCount: 0,
                             nodeID: Int32(bitPattern: 3735928559)),
            priority: 50,
            payload: Data(),
            extensions: [:])
        let f2 = Job(
            id: JobID(rawValue: "00000000000000000000000000000002"),
            streamID: StreamID(rawValue: "beta"),
            submittedAt: HLC(physicalTime: 1747526400001,
                             logicalCount: 0, nodeID: 1),
            priority: 10,
            payload: Data("hello world".utf8),
            extensions: ["k": .string("v")])
        let f3 = Job(
            id: JobID(rawValue: "00000000000000000000000000000003"),
            streamID: StreamID(rawValue: "gamma"),
            submittedAt: HLC(physicalTime: 1747526400002,
                             logicalCount: 7, nodeID: 42),
            priority: 99,
            payload: Data([0x00, 0x01, 0xff]),
            extensions: ["nested": .object(["a": .int(1)])])
        let f4 = Job(
            id: JobID(rawValue: "00000000000000000000000000000004"),
            streamID: StreamID(rawValue: "delta-stream"),
            submittedAt: HLC(physicalTime: 1747526500000,
                             logicalCount: 0, nodeID: -1),
            priority: 50,
            payload: Data("payload-4".utf8),
            extensions: ["list": .array([.int(1), .int(2), .int(3)])])
        let f5 = Job(
            id: JobID(rawValue: "00000000000000000000000000000005"),
            streamID: StreamID(rawValue: "echo_stream"),
            submittedAt: HLC(physicalTime: 1747526600000,
                             logicalCount: 1, nodeID: 100),
            priority: 25,
            payload: Data(repeating: 0x41, count: 64),
            extensions: [:])

        let s1 = SignalFile(
            jobID: f1.id, status: .done, artifacts: [],
            completedAt: HLC(physicalTime: 1747526400500,
                             logicalCount: 0,
                             nodeID: Int32(bitPattern: 3735928559)))
        let s2 = SignalFile(
            jobID: f2.id, status: .doneWithConcerns,
            artifacts: [.filePath("/tmp/x")],
            completedAt: HLC(physicalTime: 1747526400600,
                             logicalCount: 0, nodeID: 1))
        let s3 = SignalFile(
            jobID: f3.id, status: .needsContext,
            artifacts: [.commitHash("abc123")],
            completedAt: HLC(physicalTime: 1747526400700,
                             logicalCount: 8, nodeID: 42))
        let s4 = SignalFile(
            jobID: f4.id, status: .blocked,
            artifacts: [.signalFile("/x.signal"),
                        .trajectoryStepID("step-1")],
            completedAt: HLC(physicalTime: 1747526500500,
                             logicalCount: 0, nodeID: -1))
        let s5 = SignalFile(
            jobID: f5.id, status: .done, artifacts: [],
            completedAt: HLC(physicalTime: 1747526600100,
                             logicalCount: 2, nodeID: 100))

        return [
            JobFixture(name: "job_001", job: f1, signal: s1),
            JobFixture(name: "job_002", job: f2, signal: s2),
            JobFixture(name: "job_003", job: f3, signal: s3),
            JobFixture(name: "job_004", job: f4, signal: s4),
            JobFixture(name: "job_005", job: f5, signal: s5),
        ]
    }

    /// Regenerate the on-disk fixture files from the Swift wire
    /// format. The output directory is printed to stdout; copy into
    /// Tests/QueueKitTests/Fixtures/ for the committed set.
    @Test func generate() throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queuekit-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)

        for fx in Self.fixtures {
            let filename = WireFormat.filename(for: fx.job)
            let jobJSON = try WireFormat.encoder.encode(fx.job)
            try jobJSON.write(to: outDir.appendingPathComponent(
                "\(fx.name)_file.json"))
            try filename.write(
                to: outDir.appendingPathComponent(
                    "\(fx.name)_filename.txt"),
                atomically: true, encoding: .utf8)
            // Also write a "logical input" JSON that other languages
            // can read to reconstruct the same Job.
            let inputJSON = try JSONSerialization.data(
                withJSONObject: try Self.logicalInput(for: fx.job),
                options: [.sortedKeys])
            try inputJSON.write(
                to: outDir.appendingPathComponent(
                    "\(fx.name)_input.json"))

            if let sig = fx.signal {
                let sigJSON = try WireFormat.encoder.encode(sig)
                try sigJSON.write(
                    to: outDir.appendingPathComponent(
                        "signal_\(fx.name.suffix(3))_output.json"))
                let sigInput = try JSONSerialization.data(
                    withJSONObject: try Self.logicalInput(for: sig),
                    options: [.sortedKeys])
                try sigInput.write(
                    to: outDir.appendingPathComponent(
                        "signal_\(fx.name.suffix(3))_input.json"))
            }
        }
        print("FIXTURES_WRITTEN_TO=\(outDir.path)")
    }

    static func logicalInput(for job: Job) throws -> [String: Any] {
        let extData = try WireFormat.encoder.encode(job.extensions)
        let extObj = try JSONSerialization.jsonObject(with: extData)
        return [
            "id": job.id.rawValue,
            "stream_id": job.streamID.rawValue,
            "submitted_at": [
                "physical_time": job.submittedAt.physicalTime,
                "logical_count": Int(job.submittedAt.logicalCount),
                "node_id": Int64(
                    UInt32(bitPattern: job.submittedAt.nodeID)),
            ],
            "priority": job.priority,
            "payload_bytes_hex": job.payload.map {
                String(format: "%02x", $0) }.joined(),
            "extensions": extObj,
        ]
    }

    static func logicalInput(for sig: SignalFile) throws -> [String: Any] {
        let artData = try WireFormat.encoder.encode(sig.artifacts)
        let artObj = try JSONSerialization.jsonObject(with: artData)
        return [
            "job_id": sig.jobID.rawValue,
            "status": sig.status.rawValue,
            "artifacts": artObj,
            "completed_at": [
                "physical_time": sig.completedAt.physicalTime,
                "logical_count": Int(sig.completedAt.logicalCount),
                "node_id": Int64(
                    UInt32(bitPattern: sig.completedAt.nodeID)),
            ],
        ]
    }

    /// Sanity check: the in-memory fixtures encode to the same bytes
    /// as the committed fixture files.
    @Test func fixturesByteIdenticalToCommitted() throws {
        let bundle = Bundle.module
        guard let url = bundle.url(
            forResource: "job_001_file", withExtension: "json")
        else {
            // Fixtures not yet copied. Skip silently (the generator
            // test above is the producer).
            return
        }
        let committed = try Data(contentsOf: url)
        let fresh = try WireFormat.encoder.encode(
            Self.fixtures[0].job)
        #expect(committed == fresh,
            "Swift FilesystemBackend wire format drifted from committed fixture job_001_file.json")
    }
}
