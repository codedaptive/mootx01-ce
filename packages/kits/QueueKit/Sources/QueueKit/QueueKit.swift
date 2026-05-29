// QueueKit.swift
//
// Public facade per QUEUEKIT_SPEC §3. Four permanent method names
// (send, drain, watch, reply) that delegate to a mounted backend.
//
// QueueKit.init(root:backend:) creates the maildir directories on
// disk and prunes stale tmp files per spec §5 when the
// FilesystemBackend is in use.

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

/// Stale `tmp/` files older than this on init are deleted per spec
/// §5. A file stranded in `tmp/` indicates a crash between write and
/// rename; it was never visible in `new/` so removal is safe.
public let staleTmpThreshold: TimeInterval = 5 * 60  // 5 minutes

public final class QueueKit: Sendable {
    public let backend: any QueueBackend
    public let root: URL?

    /// Mount the filesystem backend at `root`. Creates the four
    /// maildir subdirectories per spec §5 if absent. Scans `tmp/`
    /// and removes any file older than the stale threshold.
    public init(
        root: URL,
        hlcGenerator: HLCGenerator
    ) throws {
        self.root = root
        let backend = try FilesystemBackend(
            root: root, hlcGenerator: hlcGenerator)
        self.backend = backend
        try Self.cleanStaleTmpFiles(root: root)
    }

    /// Mount an explicit backend. Used for PersistenceKitBackend and for
    /// tests.
    public init(backend: any QueueBackend, root: URL? = nil) {
        self.backend = backend
        self.root = root
    }

    // MARK: - The four public methods (spec §3)

    public func send(_ job: Job) async throws {
        try await backend.write(job)
    }

    public func drain() async throws -> [(job: Job, sessionID: SessionID)] {
        try await backend.drainAvailable()
    }

    public func watch(
        handler: @escaping @Sendable (Job, SessionID) async throws -> Void
    ) async throws {
        try await backend.watch(handler: handler)
    }

    public func reply(
        to jobID: JobID,
        status: ObservationStatus,
        artifacts: [ArtifactRef]
    ) async throws {
        guard status.isTerminal else {
            throw QueueError.invalidTerminalStatus(status)
        }
        try await backend.complete(
            jobID, status: status, artifacts: artifacts)
    }

    public func inFlight() async throws -> [Job] {
        try await backend.inFlight()
    }

    public func completed(
        streamID: StreamID? = nil
    ) async throws -> [Job] {
        try await backend.completed(streamID: streamID)
    }

    // MARK: - Maildir directory management (spec §5)

    public static let maildirSubdirs = ["tmp", "new", "cur", "done"]

    public static func ensureMaildir(root: URL) throws {
        let fm = FileManager.default
        for sub in maildirSubdirs {
            let dir = root.appendingPathComponent(sub)
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(
                        at: dir,
                        withIntermediateDirectories: true)
                } catch {
                    throw QueueError.directoryCreationFailed(
                        path: dir.path, underlying: error)
                }
            }
        }
    }

    public static func cleanStaleTmpFiles(root: URL) throws {
        let fm = FileManager.default
        let tmp = root.appendingPathComponent("tmp")
        if !fm.fileExists(atPath: tmp.path) { return }
        let now = Date()
        let entries = try fm.contentsOfDirectory(
            atPath: tmp.path)
        for entry in entries {
            let path = tmp.appendingPathComponent(entry).path
            let attrs = try? fm.attributesOfItem(atPath: path)
            if let mtime = attrs?[.modificationDate] as? Date {
                if now.timeIntervalSince(mtime) > staleTmpThreshold {
                    try? fm.removeItem(atPath: path)
                }
            }
        }
    }
}
