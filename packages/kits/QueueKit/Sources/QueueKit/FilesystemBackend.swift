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
// docs/engineering/HARNESS_REFERENCE.md. If you
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
    private var claimDir: URL { root.appendingPathComponent("claim") }
    private var doneDir: URL { root.appendingPathComponent("done") }

    /// Length of the claim-name prefix: 32 lowercase hex chars (a hyphenless
    /// UUIDv4) plus one `-` separator. A claim-in-progress file is named
    /// `claim/<32hex>-<original filename>`; stripping exactly this many
    /// characters recovers the original name. Cross-port protocol constant
    /// (a Swift producer and a Rust drainer may share one maildir), mirrored
    /// by Rust `CLAIM_PREFIX_LEN`. See QUEUEKIT_SPEC I-3.
    static let claimPrefixLength = 33

    /// Atomically claim `new/<entry>`, returning true if THIS caller won.
    ///
    /// A direct `rename(new/X → cur/X)` is NOT a safe claim: POSIX mandates
    /// that when `old` and `new` resolve to the same existing file, rename
    /// returns success and performs no action. In the concurrent-drain race a
    /// losing drainer can resolve `src` before the winner's rename commits and
    /// `dst` after it — both then reference the same inode and the loser gets
    /// a success no-op, i.e. a duplicate claim (observed deterministically on
    /// external APFS volumes; QUEUEKIT-CONCURRENT-CLAIM).
    ///
    /// So the claim is two renames:
    ///   1. `new/<entry>` → `claim/<32hex>-<entry>` — the destination is
    ///      unique to this claim attempt and does not pre-exist, so the
    ///      same-file rule can never manufacture a second success; exactly one
    ///      caller wins, every loser gets ENOENT.
    ///   2. `claim/<32hex>-<entry>` → `cur/<entry>` — uncontended (the winner
    ///      exclusively owns the claim file); keeps `cur/` names unchanged for
    ///      `complete`/`inFlight`/`reclaimInFlight`.
    ///
    /// A crash between the two renames strands the file in `claim/`; the
    /// mount-time `reclaimInFlight` sweeps it back to `new/`. Rust twin:
    /// `FilesystemBackend::claim_entry`.
    private func claimEntry(_ entry: String) throws -> Bool {
        let src = newDir.appendingPathComponent(entry).path
        let token = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let claimPath = claimDir.appendingPathComponent("\(token)-\(entry)").path
        var err: Int32 = 0
        var rc = src.withCString { s in
            claimPath.withCString { d -> Int32 in
                let r = rename(s, d)
                if r != 0 { err = errno }
                return r
            }
        }
        if rc != 0 {
            // A concurrent drainer moved it out of new/ first — it won.
            if err == ENOENT { return false }
            throw QueueError.renameFailed(
                from: src, to: claimPath,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        }
        let dst = curDir.appendingPathComponent(entry).path
        // Fail-closed (SPEC §5 B-3): if the publish rename fails, the job is
        // safe in claim/ and the next mount's reclaim recovers it.
        rc = claimPath.withCString { s in
            dst.withCString { d -> Int32 in
                let r = rename(s, d)
                if r != 0 { err = errno }
                return r
            }
        }
        if rc != 0 {
            throw QueueError.renameFailed(
                from: claimPath, to: dst,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        }
        return true
    }

    // MARK: - Identifier validation (planned security hardening, CAND-023)

    /// Validates that `id` is a safe single filesystem path component.
    ///
    /// An identifier used to build a queue path (stream_id, job id, or any
    /// caller-influenced component) must not contain characters that could
    /// escape the queue root via path traversal. Specifically, rejects:
    ///   - empty strings
    ///   - `.` or `..` (dot directory components)
    ///   - `/` or `\` (POSIX and Windows path separators)
    ///   - ASCII control characters 0x00–0x1F and 0x7F
    ///
    /// Legitimate identifiers — 32-char hex job ids generated by
    /// `JobID.generate()`, stream names like "encode" or "dreaming" — all
    /// pass this check. Applied at every write and completion seam, before
    /// any filesystem path is constructed. Swift/Rust/Python ports enforce
    /// identical rules. Throws `QueueError.invalidIdentifier` on rejection.
    private static func validateIdentifier(_ id: String) throws {
        guard !id.isEmpty else {
            throw QueueError.invalidIdentifier(id: id, reason: "empty")
        }
        guard id != "." && id != ".." else {
            throw QueueError.invalidIdentifier(id: id, reason: "dot component")
        }
        for scalar in id.unicodeScalars {
            let v = scalar.value
            // Path separators: '/' (0x2F) on POSIX, '\' (0x5C) on Windows.
            if v == 0x2F || v == 0x5C {
                throw QueueError.invalidIdentifier(id: id, reason: "path separator")
            }
            // ASCII control characters, including null byte (0x00).
            if v <= 0x1F || v == 0x7F {
                throw QueueError.invalidIdentifier(id: id, reason: "control character")
            }
        }
    }

    // MARK: - write (spec §8)

    public func write(_ job: Job) async throws {
        // Validate before any filesystem path construction.
        try Self.validateIdentifier(job.streamID.rawValue)
        try Self.validateIdentifier(job.id.rawValue)
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

    // Batch enqueue: write all job files, then fsync new/ ONCE. The per-job
    // `write` fsyncs each file and the new/ directory; a bulk reindex enqueuing
    // tens of thousands of jobs serial-fsyncs a full core. Each file is still
    // written O_EXCL + renamed into new/, but the durability barrier is a single
    // new/ fsync for the whole batch.
    //
    // Safe durability: a crash before the final fsync may lose some just-enqueued
    // jobs, but the bulk producer (reindex) derives its jobs from the durable
    // estate, so the next resume's reindex re-enqueues any drawer still missing
    // its index (AT-LEAST-ONCE via the estate as source of truth). Streaming
    // capture keeps per-job durability via the unchanged `write`. Rust twin.
    public func writeBatch(_ jobs: [Job]) async throws -> Int {
        guard !jobs.isEmpty else { return 0 }
        var written = 0
        for job in jobs {
            // Validate before any filesystem path construction.
            try Self.validateIdentifier(job.streamID.rawValue)
            try Self.validateIdentifier(job.id.rawValue)
            let filename = WireFormat.filename(for: job)
            let encoded: Data
            do {
                encoded = try WireFormat.encoder.encode(job)
            } catch {
                throw QueueError.writeFailed(underlying: error)
            }
            try Self.writeAndRenameNoFsync(
                data: encoded,
                tmpPath: tmpDir.appendingPathComponent(filename).path,
                newPath: newDir.appendingPathComponent(filename).path)
            written += 1
        }
        // Single durability barrier for the whole batch.
        let dfd = newDir.path.withCString { open($0, O_RDONLY) }
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
        return written
    }

    /// Steps 3–8 of spec §8. Open O_CREAT|O_EXCL, write, fsync,
    /// close, rename, then fsync the destination directory.
    static func atomicWriteAndRename(
        data: Data,
        tmpPath: String,
        newPath: String,
        newDir: String
    ) throws {
        // Step 3: O_CREAT | O_EXCL. Mode 0600 (owner r/w only) — queue files
        // carry encoded job payloads that may include sensitive content from
        // the estate. Restrict access to the owning process (defense in depth).
        let fd = tmpPath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
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

    /// Write `data` to `tmpPath` (O_CREAT|O_EXCL) and rename to `newPath`, WITHOUT
    /// any fsync. Used by `completeBatch`, which fsyncs the destination directory
    /// ONCE for the whole batch instead of per file. Crash before that single
    /// barrier leaves the job in cur/ for an at-least-once re-ingest, so deferring
    /// the fsync is safe. The rename retry-on-ENOENT mirrors atomicWriteAndRename.
    static func writeAndRenameNoFsync(
        data: Data,
        tmpPath: String,
        newPath: String
    ) throws {
        // Mode 0600 (owner r/w only) — queue files carry job payloads that may
        // include sensitive estate content. Mirrors atomicWriteAndRename.
        let fd = tmpPath.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        guard fd >= 0 else {
            throw QueueError.writeFailed(
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                        "open O_CREAT|O_EXCL failed for \(tmpPath)"]))
        }
        var written = 0
        let total = data.count
        let writeOK: Bool = data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return false }
            while written < total {
                let w = Darwin.write(fd, base.advanced(by: written), total - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += w
            }
            return true
        }
        close(fd)
        if !writeOK {
            unlink(tmpPath)
            throw QueueError.writeFailed(
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil))
        }
        var renameErr: Int32 = 0
        var renameRC: Int32 = tmpPath.withCString { src in
            newPath.withCString { dst in
                let rc = rename(src, dst)
                if rc != 0 { renameErr = errno }
                return rc
            }
        }
        if renameRC != 0, renameErr == ENOENT {
            let parent = URL(fileURLWithPath: newPath).deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
            renameRC = tmpPath.withCString { src in
                newPath.withCString { dst in
                    let rc = rename(src, dst)
                    if rc != 0 { renameErr = errno }
                    return rc
                }
            }
        }
        if renameRC != 0 {
            unlink(tmpPath)
            throw QueueError.renameFailed(
                from: tmpPath, to: newPath,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(renameErr), userInfo: nil))
        }
    }

    // MARK: - pendingCount (telemetry depth probe)

    public func pendingCount() async throws -> Int {
        // Count files in `new/` — each file is one pending job not yet claimed.
        // Non-existent directory means zero pending.
        let fm = FileManager.default
        guard fm.fileExists(atPath: newDir.path) else { return 0 }
        return (try? fm.contentsOfDirectory(atPath: newDir.path).count) ?? 0
    }

    // MARK: - Stream-scoped drain

    /// Claim and return only the pending jobs that belong to `stream`.
    ///
    /// The maildir filename is `{hlc}-{stream}-{jobid}` and `Job.streamID`
    /// carries the stream. We scan `new/`, attempt rename on EACH file, decode
    /// it, and keep the job only if `job.streamID == stream`. Files belonging to
    /// other streams that were successfully renamed to `cur/` are renamed BACK to
    /// `new/` before returning — they must remain available for their own drain
    /// caller. This preserves the at-most-once claim guarantee for each stream:
    /// a stream-a drainer never permanently claims stream-b files.
    ///
    /// Ordering and determinism are identical to `drainAvailable()`: sorted
    /// entries, rename-per-file, HLC ascending sort on results. Rust twin:
    /// `FilesystemBackend::drain_available_for_stream`.
    public func drainAvailable(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)] {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: newDir.path).sorted()
        } catch {
            throw QueueError.backendUnavailable(
                detail: "cannot list new/ for stream drain: \(error)")
        }

        // Decode each file WHILE it is still in new/ — a read does not claim it —
        // and claim ONLY matching-stream files (two-step, via claimEntry).
        // Non-matching files are never touched, so concurrent drainers of
        // different streams (encode + dreaming) cannot steal or race on each
        // other's jobs. (The earlier claim-all-then-unclaim form transiently
        // moved every stream's files into cur/, which collided under concurrent
        // stream drains — recall-driven dreaming requires that one stream's
        // drain never disturbs another's.)
        var results: [(Job, SessionID)] = []
        for entry in entries {
            let newPath = newDir.appendingPathComponent(entry).path
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: newPath))
            } catch {
                continue  // gone (claimed by another drainer) or unreadable — skip
            }
            do {
                let job = try WireFormat.decoder.decode(Job.self, from: data)
                guard job.streamID == stream else {
                    continue  // belongs to another stream — leave it in new/
                }
                // Two-step exclusive claim (see claimEntry): a same-stream
                // drainer that won the race moved it out of new/ first →
                // claimEntry returns false → skip.
                if try claimEntry(entry) {
                    results.append((job, SessionID.mint()))
                }
            } catch let e as QueueError {
                throw e
            } catch {
                // Undecodable poison: dispose to done/ (mirrors the all-streams
                // drain) so it does not accumulate across stream-scoped drains.
                let donePath = doneDir.appendingPathComponent(entry).path
                _ = newPath.withCString { src in
                    donePath.withCString { dst in rename(src, dst) }
                }
            }
        }
        results.sort { $0.0.submittedAt < $1.0.submittedAt }
        return results.map { ($0.0, $0.1) }
    }

    /// Count pending jobs in `new/` that belong to `stream`.
    ///
    /// Scans `new/`, decodes each file, and counts those whose
    /// `job.streamID == stream`. Non-claiming: files stay in `new/`. Rust twin:
    /// `FilesystemBackend::pending_count_for_stream`.
    public func pendingCount(stream: StreamID) async throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: newDir.path) else { return 0 }
        let entries = (try? fm.contentsOfDirectory(atPath: newDir.path)) ?? []
        var count = 0
        for entry in entries {
            let path = newDir.appendingPathComponent(entry).path
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let job = try? WireFormat.decoder.decode(Job.self, from: data)
            else { continue }
            if job.streamID == stream { count += 1 }
        }
        return count
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

        // Two-step exclusive claim per file (see claimEntry): a losing
        // concurrent drainer gets false, never a duplicate success.
        var claimedFiles: [String] = []
        for entry in entries {
            if try claimEntry(entry) {
                claimedFiles.append(entry)
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

    // MARK: - reclaim (crash recovery)

    /// Move every job left in `cur/` (claimed by a prior process that exited
    /// before completing it) back to `new/`, and sweep any file stranded in
    /// `claim/` (a crash between the two claim renames — see `claimEntry`)
    /// back to `new/` under its original name, so the next `drainAvailable`
    /// re-drives all of them.
    ///
    /// Safe to call ONLY at mount, when no drain session is live: a freshly
    /// started process owns no in-flight work, so every entry in `cur/` and
    /// `claim/` is a crash orphan from a previous run. With one writer per
    /// estate, that precondition holds. Returns the number of jobs reclaimed
    /// (both slots). Rust twin: `FilesystemBackend::reclaim_in_flight`.
    @discardableResult
    public func reclaimInFlight() async throws -> Int {
        let fm = FileManager.default
        var reclaimed = 0

        // claim/ sweep first: strip the fixed `<32hex>-` prefix to recover the
        // original filename. A name too short to carry the prefix is not ours
        // (only claimEntry writes here) and is left in place.
        let claimEntries: [String]
        do {
            claimEntries = try fm.contentsOfDirectory(atPath: claimDir.path).sorted()
        } catch {
            throw QueueError.backendUnavailable(
                detail: "cannot list claim/: \(error)")
        }
        for entry in claimEntries {
            guard entry.count > Self.claimPrefixLength,
                  Array(entry)[Self.claimPrefixLength - 1] == "-"
            else { continue }
            let original = String(entry.dropFirst(Self.claimPrefixLength))
            try renameForReclaim(
                from: claimDir.appendingPathComponent(entry).path,
                to: newDir.appendingPathComponent(original).path,
                reclaimed: &reclaimed)
        }

        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: curDir.path).sorted()
        } catch {
            throw QueueError.backendUnavailable(
                detail: "cannot list cur/: \(error)")
        }
        for entry in entries {
            try renameForReclaim(
                from: curDir.appendingPathComponent(entry).path,
                to: newDir.appendingPathComponent(entry).path,
                reclaimed: &reclaimed)
        }
        return reclaimed
    }

    /// One reclaim rename: success counts, ENOENT (already moved by a
    /// concurrent caller — not expected at mount) is skipped, anything else
    /// propagates fail-closed.
    private func renameForReclaim(
        from src: String, to dst: String, reclaimed: inout Int
    ) throws {
        var err: Int32 = 0
        let rc = src.withCString { s in
            dst.withCString { d -> Int32 in
                let r = rename(s, d)
                if r != 0 { err = errno }
                return r
            }
        }
        if rc == 0 {
            reclaimed += 1
        } else if err == ENOENT {
            return
        } else {
            throw QueueError.renameFailed(
                from: src, to: dst,
                underlying: NSError(
                    domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        }
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
        // Validate before signal file path construction.
        try Self.validateIdentifier(jobID.rawValue)
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

    // Batch completion: ONE cur/ scan + ONE durability barrier for the whole
    // drained batch. Per-job `complete` rescans cur/ to find each job's file
    // (O(N²) over a batch) and fsyncs per job — observed live as the dominant
    // cost of a bulk-import drain. Here we scan cur/ once into a jobID→filename
    // index, write each signal + rename without a per-file fsync, and fsync the
    // done/ directory ONCE at the end.
    //
    // Safe durability: a crash before the final dir fsync leaves the not-yet-
    // renamed jobs in cur/, so they are re-claimed on restart and re-ingested —
    // the AT-LEAST-ONCE contract holds (ingest is idempotent). The index keys on
    // the filename suffix after the last '-', which is the jobID: QueueKit job
    // ids are 32 dashless hex (JobID.generate, spec §6), so the last '-' is
    // always the separator before the id. Mirrors the Rust twin.
    public func completeBatch(
        _ completions: [(jobID: JobID, status: ObservationStatus)]
    ) async throws -> Int {
        guard !completions.isEmpty else { return 0 }
        // Validate all identifiers before touching the filesystem.
        for c in completions {
            try Self.validateIdentifier(c.jobID.rawValue)
        }
        for c in completions where !c.status.isTerminal {
            throw QueueError.invalidTerminalStatus(c.status)
        }

        // One scan: jobID (filename suffix) → filename.
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: curDir.path)) ?? []
        var byID: [String: String] = [:]
        byID.reserveCapacity(entries.count)
        for name in entries {
            if let dash = name.lastIndex(of: "-") {
                byID[String(name[name.index(after: dash)...])] = name
            }
        }

        var completed = 0
        for c in completions {
            // Not in cur/ → already retired (or never claimed); skip.
            guard let match = byID[c.jobID.rawValue] else { continue }
            let completedHLC = hlc.next(
                now: Int64(Date().timeIntervalSince1970 * 1000))
            let signal = SignalFile(
                jobID: c.jobID, status: c.status,
                artifacts: [], completedAt: completedHLC)
            let signalData = try WireFormat.encoder.encode(signal)
            // Write + rename WITHOUT a per-file/dir fsync (batched below).
            try Self.writeAndRenameNoFsync(
                data: signalData,
                tmpPath: tmpDir.appendingPathComponent("\(c.jobID.rawValue).signal").path,
                newPath: doneDir.appendingPathComponent("\(c.jobID.rawValue).signal").path)
            // Move the job file cur/ -> done/.
            let src = curDir.appendingPathComponent(match).path
            let dst = doneDir.appendingPathComponent(match).path
            let rc = src.withCString { s in dst.withCString { d in rename(s, d) } }
            if rc != 0 {
                throw QueueError.renameFailed(
                    from: src, to: dst,
                    underlying: NSError(
                        domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil))
            }
            completed += 1
        }

        // Single durability barrier for the whole batch.
        let dfd = doneDir.path.withCString { open($0, O_RDONLY) }
        if dfd >= 0 {
            _ = fsync(dfd)
            close(dfd)
        }
        return completed
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
