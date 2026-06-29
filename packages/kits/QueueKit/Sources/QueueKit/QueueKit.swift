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

    /// Enqueue a batch of jobs in one pass — the bulk twin of `send`. Routes to
    /// the backend's `writeBatch`, which for the filesystem backend writes all
    /// files and fsyncs `new/` ONCE instead of per job. Used by the bulk reindex.
    /// Rust twin: `QueueKit::send_batch`.
    @discardableResult
    public func send(batch jobs: [Job]) async throws -> Int {
        try await backend.writeBatch(jobs)
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

    /// Drain only the jobs belonging to `stream` (ADR-021 Decision 7 / T1).
    ///
    /// Routes to the backend's `drainAvailable(stream:)`, which on
    /// PersistenceKitBackend uses the `(stream_id, status)` index (one
    /// predicated bulk UPDATE) and on FilesystemBackend decodes-and-filters
    /// `new/`. Telemetry mirrors `drain()`: same estate tag, same latency
    /// window, drain count reflects only this stream's jobs. Rust twin:
    /// `QueueKit::drain_for_stream`.
    public func drain(stream: StreamID) async throws -> [(job: Job, sessionID: SessionID)] {
        let start = Date().timeIntervalSince1970
        let result = try await backend.drainAvailable(stream: stream)
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

    /// Complete every in-flight job claimed under `session` in one pass — the
    /// batch twin of `reply(to:status:)`. Returns the number completed. A drain
    /// worker that claimed a whole batch under one session (single-pass claim)
    /// retires the batch with one backend update instead of N per-job replies
    /// (each an O(N) scan → O(N²) per batch). Returns 0 for a backend without the
    /// fast path; the caller then falls back to per-job `reply`.
    @discardableResult
    public func reply(
        session: SessionID,
        status: ObservationStatus
    ) async throws -> Int {
        guard status.isTerminal else {
            throw QueueError.invalidTerminalStatus(status)
        }
        // Only the PersistenceKit backend (the encode-drain backend) carries the
        // single-pass batch completion; other backends fall back to per-job.
        if let pk = backend as? PersistenceKitBackend {
            return try await pk.completeSession(session, status: status)
        }
        return 0
    }

    /// Complete a batch of jobs by id in one pass — the job-list twin of
    /// `reply(session:status:)`. Routes to the backend's `completeBatch`, which
    /// for the filesystem backend collapses the per-job `cur/` scan + per-job
    /// fsync into one scan and one durability barrier. Returns the number
    /// completed. Used by the corpus drain to retire a drained batch on backends
    /// (FilesystemBackend) that have no session fast path. Mirrors the Rust twin's
    /// `QueueKit::reply_batch`.
    @discardableResult
    public func reply(
        batch completions: [(jobID: JobID, status: ObservationStatus)]
    ) async throws -> Int {
        try await backend.completeBatch(completions)
    }

    /// Reset every stale in-flight ("cur") job for `stream` back to "new", so the
    /// next `drain(stream:)` re-claims and re-drives them. Returns the count reclaimed.
    ///
    /// Gate: call this ONLY when `DrainLease.tryAcquire` SUCCEEDED for `stream`.
    /// A freshly-acquired lease means the prior holder is dead; every "cur" row for
    /// this stream is an orphan from the crashed drainer. `tryAcquire` succeeds only
    /// when the prior lease is absent or stale (heartbeat older than TTL = 15 s), so
    /// no live drainer can hold a fresh lease at the same time — the gate guarantees
    /// this method never yanks a "cur" job out from under a running drainer.
    ///
    /// Only the `PersistenceKitBackend` carries this fast path (the shared encrypted
    /// `queue.sqlite` is the only backend whose "cur" rows survive a crash). The
    /// `FilesystemBackend` already provides an all-streams `reclaimInFlight()` at
    /// mount time (its "cur/" directory is stream-unscoped — there is only one drainer
    /// per maildir). Returns 0 on a backend without the fast path. Rust twin:
    /// `QueueKit::reclaim_in_flight_for_stream`.
    @discardableResult
    public func reclaimInFlight(stream: StreamID) async throws -> Int {
        // Only the PersistenceKit backend (the shared per-estate queue.sqlite drainer)
        // carries stream-scoped "cur" state that can persist across process crashes.
        // The FilesystemBackend's reclaimInFlight() is called directly at mount time
        // and is not stream-scoped; callers of this method are SQLite-estate drainers.
        if let pk = backend as? PersistenceKitBackend {
            return try await pk.reclaimInFlight(stream: stream)
        }
        return 0
    }

    public func inFlight() async throws -> [Job] {
        try await backend.inFlight()
    }

    /// The number of jobs waiting in the queue's `new/` frontier — submitted
    /// but not yet claimed by a consumer. Public passthrough to the backend's
    /// `pendingCount()`, mirroring the public `inFlight()` probe so a status
    /// reader can observe queue depth without claiming or draining. Together,
    /// `pendingCount() + inFlight().count` is the total outstanding work a
    /// drain has left to do.
    public func pendingCount() async throws -> Int {
        try await backend.pendingCount()
    }

    /// Count pending jobs belonging to `stream` only (ADR-021 Decision 7 / T1).
    ///
    /// Routes to the backend's `pendingCount(stream:)`. PersistenceKitBackend
    /// uses the `(stream_id, status)` index; FilesystemBackend scans `new/` and
    /// decodes each file. Non-claiming: files/rows remain in `new`/`"new"`. Rust
    /// twin: `QueueKit::pending_count_for_stream`.
    public func pendingCount(stream: StreamID) async throws -> Int {
        try await backend.pendingCount(stream: stream)
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

    /// Block until `stream` has no pending and no in-flight work, then return.
    ///
    /// Stream-scoped twin of `awaitDrain` (ADR-021 Decision 7 / T1). On the
    /// shared per-estate `queue.sqlite` a single drainer (e.g. the encode pump)
    /// processes only its own stream; the global `awaitDrain` would block forever
    /// on OTHER streams' jobs (e.g. `dreaming` enqueued on recall) that this
    /// drainer never claims. The barrier must therefore be stream-scoped, exactly
    /// as `drain(stream:)` scopes the claim. Counts `pendingCount(stream:)` plus
    /// the stream's slice of `inFlight()`; every job carries `streamID` so the
    /// filter is exact. Rust twin: `QueueKit::await_drain_for_stream`.
    public func awaitDrain(
        stream: StreamID,
        pollInterval: Duration = .milliseconds(20),
        timeout: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            // Re-read both frontiers each iteration; count only THIS stream.
            let pending = try await backend.pendingCount(stream: stream)
            let inFlightCount = try await backend.inFlight()
                .filter { $0.streamID == stream }.count
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
