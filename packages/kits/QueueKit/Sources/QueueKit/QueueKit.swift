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
// docs/engineering/HARNESS_REFERENCE.md. If you
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

    /// Rolling latency window for drain percentile telemetry.
    /// nonisolated(unsafe): drain() is always called from a single serialised
    /// context (the GLK scheduler is an actor; test callers are serial). Marking
    /// unsafe here documents that the caller owns exclusivity; Swift cannot verify
    /// it statically because QueueKit is not an actor.
    nonisolated(unsafe) private var latencyWindow = QueueLatencyWindow()

    /// Estate tag for queue.* telemetry metrics. Set to the estate UUID string
    /// by the composition layer (e.g. GeniusLocusKit when mounting QueueKit for
    /// an estate). Defaults to "unknown" so telemetry fires even when not set —
    /// callers should wire this at mount time.
    /// nonisolated(unsafe): set once before any drain() calls, never written
    /// again during concurrent use.
    nonisolated(unsafe) public var estateTag: String = "unknown"

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
        let start = Date().timeIntervalSince1970
        let result = try await backend.drainAvailable()
        let now = Date().timeIntervalSince1970
        await reportQueueStats(
            backend: backend,
            drained: result,
            drainStart: start,
            now: now,
            estateTag: estateTag,
            window: &latencyWindow
        )
        return result
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

    // MARK: - awaitDrain (await-empty latch — Dual-Path Intake P5)

    /// Block until the queue has no pending and no in-flight work, then return.
    ///
    /// "Empty" means both maildir frontiers are clear: `pendingCount() == 0`
    /// (nothing waiting in `new/` to be claimed) AND `inFlight().isEmpty`
    /// (nothing claimed-but-not-yet-replied in `cur/`). A job is only off both
    /// frontiers once a consumer has drained it and called `reply(...)`, which
    /// moves it to `done/`. So this latch returns only after every enqueued
    /// encode job has been fully processed by the drain worker — the signal a
    /// bulk caller (importer, gauntlet, acceptance test) needs to know encoding
    /// finished before it issues a recall.
    ///
    /// Returns PROMPTLY when the queue is already empty: the first poll sees
    /// zero on both frontiers and returns without sleeping. It does not hang on
    /// an empty queue.
    ///
    /// Polling, not a push latch: the maildir backend has no native completion
    /// event, so this polls the two depth probes on a fixed cadence. The
    /// drain worker runs concurrently; each poll re-reads the live frontier
    /// counts, so progress made between polls is observed on the next tick.
    ///
    /// - Parameters:
    ///   - pollInterval: Sleep between frontier polls. Defaults to 20 ms — short
    ///     enough that the latch releases promptly after the last `reply`, long
    ///     enough that the poll loop does not spin a core.
    ///   - timeout: Upper bound on total wait. Defaults to 30 s. If both
    ///     frontiers have not cleared by then, throws
    ///     `QueueError.drainTimeout` rather than blocking forever — a stuck or
    ///     crashed drain worker surfaces as an error, never a hang.
    /// - Throws: `QueueError.drainTimeout` if the queue does not empty within
    ///   `timeout`; any backend error from the frontier probes; or
    ///   `CancellationError` if the task is cancelled while sleeping.
    public func awaitDrain(
        pollInterval: Duration = .milliseconds(20),
        timeout: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            // Re-read both frontiers each iteration so concurrent drain-worker
            // progress (a job moving new/ → cur/ → done/) is observed live.
            let pending = try await backend.pendingCount()
            let inFlightCount = try await backend.inFlight().count
            if pending == 0 && inFlightCount == 0 {
                return
            }
            if ContinuousClock.now >= deadline {
                throw QueueError.drainTimeout(
                    pending: pending, inFlight: inFlightCount)
            }
            try await Task.sleep(for: pollInterval)
        }
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
