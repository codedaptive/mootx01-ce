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
// docs/engineering/HARNESS_REFERENCE.md. If you
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

    @Test func reclaimInFlightMovesCurBackToNew() async throws {
        // Crash-recovery: a job claimed (new → cur) by a process that exits before
        // completing it must be re-drivable after restart. reclaimInFlight() moves
        // it cur → new so the next drain returns it.
        let fs = try FilesystemBackend(root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "recover"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data("recover-me".utf8), extensions: [:])
        try await fs.write(job)
        // Claim it — simulates an in-flight job at crash time.
        let claimed = try await fs.drainAvailable()
        #expect(claimed.count == 1)
        #expect(filesIn("cur").count == 1)
        #expect(filesIn("new").count == 0)
        // Restart recovery.
        let reclaimed = try await fs.reclaimInFlight()
        #expect(reclaimed == 1)
        #expect(filesIn("new").count == 1)
        #expect(filesIn("cur").count == 0)
        // The reclaimed job is re-drivable.
        let again = try await fs.drainAvailable()
        #expect(again.count == 1)
        #expect(again[0].job.id == job.id)
        // Nothing left to reclaim once it is back in cur and there are no orphans.
        let none = try await fs.reclaimInFlight()
        #expect(none == 1)  // it is back in cur after the re-drain; reclaim returns it again
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

    // MARK: - pendingCount() (TELEMETRY_QT)

    @Test func pendingCountOnEmptyQueue() async throws {
        let kit = try makeKit()
        #expect(try await kit.backend.pendingCount() == 0)
    }

    @Test func pendingCountReflectsSentJobs() async throws {
        let kit = try makeKit()
        let j1 = Job(id: JobID.generate(), streamID: StreamID(rawValue: "s"),
                     submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
                     priority: 50, payload: Data(), extensions: [:])
        let j2 = Job(id: JobID.generate(), streamID: StreamID(rawValue: "s"),
                     submittedAt: HLC(physicalTime: 2, logicalCount: 0, nodeID: 1),
                     priority: 50, payload: Data(), extensions: [:])
        try await kit.send(j1)
        try await kit.send(j2)
        #expect(try await kit.backend.pendingCount() == 2)
    }

    @Test func pendingCountDropsToZeroAfterDrain() async throws {
        let kit = try makeKit()
        let job = Job(id: JobID.generate(), streamID: StreamID(rawValue: "s"),
                      submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
                      priority: 50, payload: Data(), extensions: [:])
        try await kit.send(job)
        #expect(try await kit.backend.pendingCount() == 1)
        _ = try await kit.drain()
        #expect(try await kit.backend.pendingCount() == 0)
    }

    // ──────────────────────────────────────────────────────────────────────
    // File-mode verification
    // ──────────────────────────────────────────────────────────────────────

    /// Queue files must be created with mode 0600 (owner read/write only).
    /// Queue files carry encoded job payloads that may include sensitive
    /// estate content, so world-readable (0644) permissions are a
    /// defense-in-depth failure. This test sends one job and verifies that
    /// the resulting file in the `new/` maildir slot has exactly mode 0600.
    ///
    /// Note: this test is Unix-only; Windows has no equivalent octal
    /// permission model. The `#if canImport(Darwin)` guard ensures
    /// it is only compiled and run on Apple platforms.
    #if canImport(Darwin)
    @Test func queueFilesCreatedWithMode0600() async throws {
        let kit = try makeKit()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "mode-check"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50,
            payload: Data("mode-test".utf8),
            extensions: [:])
        try await kit.send(job)

        // Exactly one file should be in new/ after a single send.
        let newDir = root.appendingPathComponent("new").path
        let names = (try FileManager.default.contentsOfDirectory(atPath: newDir))
        #expect(names.count == 1, "Expected exactly one file in new/ after send")
        guard let name = names.first else { return }

        let filePath = (newDir as NSString).appendingPathComponent(name)
        // stat(2) the file to read POSIX permission bits.
        var st = stat()
        let rc = stat(filePath, &st)
        #expect(rc == 0, "stat(\(filePath)) failed: \(errno)")
        // Mask off the file-type bits — keep only the 12 permission bits.
        let mode = st.st_mode & 0o7777
        #expect(
            mode == 0o600,
            "Queue file mode was \(String(mode, radix: 8)) — expected 0600 (owner r/w only)"
        )
    }
    #endif

    // MARK: - Identifier validation (CAND-023 planned security hardening)

    /// Helper: build a minimal Job using the given rawStreamID and rawJobID.
    private func makeJob(streamID: String, jobID: String) -> Job {
        Job(
            id: JobID(rawValue: jobID),
            streamID: StreamID(rawValue: streamID),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
    }

    @Test func rejectsDotDotStreamID() async throws {
        // ".." as a stream_id would allow escaping the queue root via path
        // traversal when embedded in the job filename.
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(streamID: "..", jobID: JobID.generate().rawValue)
        await #expect(throws: QueueError.self) {
            try await fs.write(job)
        }
    }

    @Test func rejectsDotDotJobID() async throws {
        // ".." as a job id would allow escaping the queue root in signal
        // file names (e.g. "..".signal resolved against done/).
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(
            streamID: "encode", jobID: "..")
        await #expect(throws: QueueError.self) {
            try await fs.write(job)
        }
    }

    @Test func rejectsForwardSlashInStreamID() async throws {
        // A stream_id containing "/" would inject a directory separator
        // into the job filename component, allowing path escape.
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(streamID: "evil/stream", jobID: JobID.generate().rawValue)
        await #expect(throws: QueueError.self) {
            try await fs.write(job)
        }
    }

    @Test func rejectsBackslashInJobID() async throws {
        // A job id containing "\" would inject a Windows path separator
        // into the signal filename.
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(
            streamID: "encode", jobID: "bad\\id")
        await #expect(throws: QueueError.self) {
            try await fs.write(job)
        }
    }

    @Test func rejectsAbsolutePathAsStreamID() async throws {
        // An absolute path as stream_id starts with "/" — caught by the
        // path-separator check (any "/" makes it unsafe, including a leading one).
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(streamID: "/etc/passwd", jobID: JobID.generate().rawValue)
        await #expect(throws: QueueError.self) {
            try await fs.write(job)
        }
    }

    @Test func rejectsControlCharacterInJobID() async throws {
        // Control characters (0x00–0x1F) in a job id could produce filenames
        // that are difficult to inspect and may trigger OS-level issues.
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(
            streamID: "encode", jobID: "bad\u{01}id")
        await #expect(throws: QueueError.self) {
            try await fs.write(job)
        }
    }

    @Test func acceptsLegitimateIdentifiers() async throws {
        // Hex job ids and kebab-case stream names must not be rejected.
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        let job = makeJob(
            streamID: "encode-corpus",
            jobID: JobID.generate().rawValue)
        // Must not throw — legitimate identifiers pass through cleanly.
        try await fs.write(job)
        let claimed = try await fs.drainAvailable()
        #expect(claimed.count == 1)
    }

    @Test func rejectsDotDotJobIDOnComplete() async throws {
        // Validation in complete() prevents a bad job id from reaching
        // the signal file path construction in done/.
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        await #expect(throws: QueueError.self) {
            try await fs.complete(
                JobID(rawValue: ".."),
                status: .done, artifacts: [])
        }
    }

    @Test func rejectsForwardSlashJobIDOnComplete() async throws {
        let fs = try FilesystemBackend(
            root: root, hlcGenerator: HLCGenerator(nodeID: 1))
        await #expect(throws: QueueError.self) {
            try await fs.complete(
                JobID(rawValue: "a/b"),
                status: .done, artifacts: [])
        }
    }

    // MARK: - helpers

    private func filesIn(_ sub: String) -> [String] {
        let dir = root.appendingPathComponent(sub).path
        return (try? FileManager.default.contentsOfDirectory(
            atPath: dir)) ?? []
    }
}
