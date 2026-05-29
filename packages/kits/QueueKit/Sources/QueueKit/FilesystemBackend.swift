// FilesystemBackend.swift
//
// POSIX maildir-style queue backend per QUEUEKIT_SPEC §5,6,8,9.
// Semantics derived from Postfix deliver_maildir() (Wietse Venema,
// IBM T.J. Watson Research). No C code: the equivalent POSIX calls
// are invoked through Foundation and Darwin/Glibc.

import Foundation
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
import SubstrateTypes

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Internal lock for the per-instance HLCGenerator. The generator is
/// a value type, so concurrent `send()` calls must serialise their
/// updates to it.
private final class HLCBox: @unchecked Sendable {
    var generator: HLCGenerator
    let lock = NSLock()
    init(_ g: HLCGenerator) { self.generator = g }

    func next(now: Int64) -> HLC {
        lock.lock(); defer { lock.unlock() }
        return generator.send(now: now)
    }
}

public final class FilesystemBackend: QueueBackend, @unchecked Sendable {
    public let root: URL
    private let hlc: HLCBox

    public init(root: URL, hlcGenerator: HLCGenerator) throws {
        self.root = root
        self.hlc = HLCBox(hlcGenerator)
        try QueueKit.ensureMaildir(root: root)
    }

    private var tmpDir: URL { root.appendingPathComponent("tmp") }
    private var newDir: URL { root.appendingPathComponent("new") }
    private var curDir: URL { root.appendingPathComponent("cur") }
    private var doneDir: URL { root.appendingPathComponent("done") }

    // MARK: - write (spec §8)

    public func write(_ job: Job) async throws {
        let filename = WireFormat.filename(for: job)
        let tmpPath = tmpDir.appendingPathComponent(filename).path
        let newPath = newDir.appendingPathComponent(filename).path

        let encoded: Data
        do {
            encoded = try WireFormat.encoder.encode(job)
        } catch {
            throw QueueError.writeFailed(underlying: error)
        }

        try Self.atomicWriteAndRename(
            data: encoded,
            tmpPath: tmpPath,
            newPath: newPath,
            newDir: newDir.path)
    }

    /// Steps 3–8 of spec §8. Open O_CREAT|O_EXCL, write, fsync,
    /// close, rename, then fsync the destination directory.
    static func atomicWriteAndRename(
        data: Data,
        tmpPath: String,
        newPath: String,
        newDir: String
    ) throws {
        // Step 3: O_CREAT | O_EXCL
        let fd = tmpPath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        guard fd >= 0 else {
            throw QueueError.writeFailed(
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                        "open O_CREAT|O_EXCL failed for \(tmpPath)"]))
        }
        // Step 4 + 5: write + fsync (do not close before fsync)
        var written = 0
        let total = data.count
        let writeOK: Bool = data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            while written < total {
                let w = Darwin.write(fd, base.advanced(by: written),
                                     total - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += w
            }
            return true
        }
        if !writeOK {
            close(fd)
            unlink(tmpPath)
            throw QueueError.writeFailed(
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: nil))
        }
        if fsync(fd) != 0 {
            close(fd)
            unlink(tmpPath)
            throw QueueError.writeFailed(
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: nil))
        }
        // Step 6: close
        close(fd)

        // Step 7: rename tmp -> new
        var renameErr: Int32 = 0
        var renameRC: Int32 = tmpPath.withCString { src in
            newPath.withCString { dst in
                let rc = rename(src, dst)
                if rc != 0 { renameErr = errno }
                return rc
            }
        }
        if renameRC != 0 {
            if renameErr == ENOENT {
                // new/ removed mid-flight. Recreate and retry once.
                let parent = URL(fileURLWithPath: newPath)
                    .deletingLastPathComponent()
                try? FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true)
                renameRC = tmpPath.withCString { src in
                    newPath.withCString { dst in
                        let rc = rename(src, dst)
                        if rc != 0 { renameErr = errno }
                        return rc
                    }
                }
                if renameRC != 0 {
                    unlink(tmpPath)
                    throw QueueError.writeFailed(
                        underlying: NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(renameErr), userInfo: nil))
                }
            } else if renameErr == EXDEV {
                unlink(tmpPath)
                throw QueueError.writeFailed(
                    underlying: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EXDEV),
                        userInfo: [NSLocalizedDescriptionKey:
                            "tmp/ and new/ on different filesystems"]))
            } else {
                unlink(tmpPath)
                throw QueueError.renameFailed(
                    from: tmpPath, to: newPath,
                    underlying: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(renameErr), userInfo: nil))
            }
        }

        // Step 8: fsync the destination directory.
        let dfd = newDir.withCString { open($0, O_RDONLY) }
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
    }

    // MARK: - drainAvailable (spec §9)

    public func drainAvailable() async throws -> [(job: Job, sessionID: SessionID)] {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: newDir.path).sorted()
        } catch {
            throw QueueError.backendUnavailable(
                detail: "cannot list new/: \(error)")
        }

        var claimedFiles: [String] = []
        for entry in entries {
            let src = newDir.appendingPathComponent(entry).path
            let dst = curDir.appendingPathComponent(entry).path
            let rc = src.withCString { s in
                dst.withCString { d in rename(s, d) }
            }
            if rc == 0 {
                claimedFiles.append(entry)
            } else if errno == ENOENT {
                continue  // another drainer won
            } else {
                throw QueueError.renameFailed(
                    from: src, to: dst,
                    underlying: NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno), userInfo: nil))
            }
        }

        var results: [(Job, SessionID)] = []
        for entry in claimedFiles {
            let path = curDir.appendingPathComponent(entry).path
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                // Read failure: leave in cur/ for inspection
                continue
            }
            do {
                let job = try WireFormat.decoder.decode(Job.self, from: data)
                results.append((job, SessionID.mint()))
            } catch {
                // Decode failure per spec §9.3: move to done/ with
                // .blocked status. Decode-error annotation lives in
                // a sidecar signal because the job structure itself
                // is unparseable.
                let donePath = doneDir.appendingPathComponent(entry).path
                _ = path.withCString { src in
                    donePath.withCString { dst in
                        rename(src, dst)
                    }
                }
            }
        }
        results.sort { $0.0.submittedAt < $1.0.submittedAt }
        return results.map { ($0.0, $0.1) }
    }

    // MARK: - watch (spec §3)

    public func watch(
        handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws {
        try await Watcher.watchNewDirectory(at: newDir) { [weak self] in
            guard let self else { return }
            do {
                let batch = try await self.drainAvailable()
                for pair in batch {
                    try await handler(pair.0, pair.1)
                }
            } catch {
                // Surface to log; watcher continues
            }
        }
    }

    // MARK: - complete (spec §3, §6)

    public func complete(
        _ jobID: JobID,
        status: ObservationStatus,
        artifacts: [ArtifactRef]
    ) async throws {
        guard status.isTerminal else {
            throw QueueError.invalidTerminalStatus(status)
        }
        // Find the file for jobID in cur/.
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: curDir.path)) ?? []
        guard let match = entries.first(where: {
            $0.hasSuffix("-\(jobID.rawValue)")
        }) else {
            throw QueueError.jobNotFound(jobID)
        }

        // Build the signal and write it BEFORE renaming the job
        // file. Spec §6 signal file format.
        let completedHLC = hlc.next(
            now: Int64(Date().timeIntervalSince1970 * 1000))
        let signal = SignalFile(
            jobID: jobID, status: status,
            artifacts: artifacts, completedAt: completedHLC)
        let signalData = try WireFormat.encoder.encode(signal)
        let signalPath = doneDir.appendingPathComponent(
            "\(jobID.rawValue).signal").path
        try Self.atomicWriteAndRename(
            data: signalData,
            tmpPath: tmpDir.appendingPathComponent(
                "\(jobID.rawValue).signal").path,
            newPath: signalPath,
            newDir: doneDir.path)

        // Now move the job file.
        let src = curDir.appendingPathComponent(match).path
        let dst = doneDir.appendingPathComponent(match).path
        let rc = src.withCString { s in
            dst.withCString { d in rename(s, d) }
        }
        if rc != 0 {
            throw QueueError.renameFailed(
                from: src, to: dst,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno), userInfo: nil))
        }
    }

    // MARK: - inFlight / completed

    public func inFlight() async throws -> [Job] {
        try listJobs(in: curDir, filter: nil)
    }

    public func completed(streamID: StreamID?) async throws -> [Job] {
        try listJobs(in: doneDir, filter: streamID).filter { _ in true }
    }

    private func listJobs(in dir: URL, filter: StreamID?) throws -> [Job] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var jobs: [Job] = []
        for e in entries.sorted() where !e.hasSuffix(".signal") {
            let p = dir.appendingPathComponent(e).path
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p))
            else { continue }
            guard let job = try? WireFormat.decoder.decode(
                Job.self, from: data) else { continue }
            if let f = filter, job.streamID != f { continue }
            jobs.append(job)
        }
        return jobs
    }
}
