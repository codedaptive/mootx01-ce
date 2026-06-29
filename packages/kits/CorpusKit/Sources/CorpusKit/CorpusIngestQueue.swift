// CorpusIngestQueue.swift
//
// The Corpus-owned ingest pipeline: queue + drain worker + bounded worker pool.
//
// CorpusKit is a standalone database substrate. A Corpus queues, drains, and
// encodes its own content with no orchestrator: `enqueueIngest` puts an
// IngestJob on the corpus's dedicated encode stream, and a foreground drain
// worker pulls every currently-available job each pass and ingests the whole
// batch via `ingestBatch` (cross-document parallel compute, serial batched
// writes — the bounded worker pool). This is the encode pipeline that
// previously lived in GeniusLocusKit's EncodeIntake; it belongs here so every
// SDK consumer (CorpusKit-direct, no GLK) gets multi-core encode, and so
// GeniusLocusKit is pure orchestration.
//
// T4 (ADR-021 Decision 7): the encode queue is now the SHARED per-estate
// encrypted queue — a PersistenceKitBackend over `queue.sqlite` beside the
// estate (derived via `EstateConfiguration.queueSibling("queue.sqlite")`). This
// replaces the old `FilesystemBackend` maildir (`corpus_ingest_queue/`) that
// was plaintext even when the estate was encrypted — a security hole. The encode
// stream is isolated by `stream_id = "encode"` so a future dreaming drainer can
// share the same queue.sqlite without claiming encode jobs (ADR-021 Decision 7:
// one per-estate queue, per-(estate, stream) drainers). The private CorpusKit
// `DrainLease` is replaced by the QueueKit-provided `DrainLease` (T2), keyed on
// `stream = "encode"`.
//
// Perf parity (required by T4 spec): the bulk enqueue path (`enqueueIngestBatch`)
// wraps all inserts in ONE transaction via the overridden `writeBatch` (added to
// `PersistenceKitBackend` in T4). The drain's fast completion path retires the
// whole batch in one `reply(session:)` → `completeSession` update, not N per-job
// replies. Both wins are preserved on the encrypted SQLite backend.

import Foundation
import OSLog
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes

/// CorpusKit ingest-pipeline logger (category "CorpusKit"). Declared at file
/// scope so the drain worker does not reconstruct a Logger on every pass.
private let corpusIngestLog = Logger(subsystem: "com.mootx01.kit", category: "CorpusKit")

public extension Corpus {

    // MARK: - Mount / drop

    /// Mount the corpus's dedicated ingest queue and start its drain worker.
    ///
    /// Idempotent: re-mounting an already-mounted corpus is a no-op (the
    /// existing queue and worker are kept). An orchestrator calls this at
    /// provision; otherwise `enqueueIngest` mounts it lazily on first use.
    ///
    /// Backend selection follows the estate's durability (T4 — ADR-021 Decision 7):
    ///   - SQLite estate → the SHARED encrypted `queue.sqlite` beside the estate.
    ///     `storage.configuration.queueSibling("queue.sqlite")` derives the sibling
    ///     config (same path directory, same encryption key). A `PersistenceKitBackend`
    ///     over this sibling is the encode queue for all streams. No maildir is
    ///     created; the old `corpus_ingest_queue/` maildir is gone.
    ///   - InMemory estate → a transient in-memory PersistenceKit-backed queue.
    ///     The estate itself is ephemeral, so there is nothing to persist or recover.
    ///     A fixed estate UUID keeps the engine free of UUID() nondeterminism.
    ///
    /// - Throws: A storage/schema error if the queue backend cannot be opened.
    func mountIngestQueue() async throws {
        guard ingestQueue == nil else { return }  // idempotent
        let backend: any QueueBackend
        var newLease: DrainLease? = nil

        let cfg = storage.configuration
        if case .sqlite = cfg.backend {
            // Derive the sibling config: same directory, same encryption key.
            // `queueSibling` is deterministic — same estate → same sibling UUID
            // and path — so all processes that open the estate share one queue.sqlite.
            let siblingCfg = try cfg.queueSibling(filename: "queue.sqlite")
            let qs = try SQLiteStorage(configuration: siblingCfg)
            try await PersistenceKitBackend.openSchema(on: qs)
            backend = PersistenceKitBackend(storage: qs)

            // Stream-keyed drain lease beside the estate directory (T2): keyed on
            // `"encode"` so a future dreaming drainer can hold its own lease on the
            // same queue.sqlite concurrently — both streams drain independently.
            // Instance token = PID + this Corpus's ObjectIdentifier, preventing PID-
            // reuse impersonation after a crash.
            let estateDir = siblingCfg.backend.sqliteURL!.deletingLastPathComponent()
            newLease = DrainLease(
                directory: estateDir,
                stream: "encode",
                instanceToken: "\(ObjectIdentifier(self))"
            )
        } else {
            // In-memory estate: transient queue, no crash recovery, no cross-process
            // lease. A fixed estate UUID keeps the engine deterministic (no UUID()).
            let qs = InMemoryStorage(configuration: EstateConfiguration(
                estateID: Self.ingestQueueStoreID,
                backend: .inMemory))
            try await PersistenceKitBackend.openSchema(on: qs)
            backend = PersistenceKitBackend(storage: qs)
            // In-memory estates are single-process — no cross-process lease needed.
        }
        let queue = QueueKit(backend: backend)
        queue.estateTag = "corpus_encode"
        ingestQueue = queue
        drainLease = newLease

        // Poll worker (near-realtime, load-robust). Each pass drains ONLY the
        // `encode` stream (T1 stream-scoped drain) so it never claims dreaming or
        // signal jobs that share the queue.sqlite in the future. The pass only
        // drains while this process holds the encode drain lease (T2). Cancelled in
        // `dropIngestQueue`.
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.runIngestDrainLoop()
        }
        ingestDrainWorker = worker
    }

    /// Tear down the corpus's ingest queue and drain worker.
    ///
    /// Cancels the background worker and drops the queue so a torn-down corpus
    /// leaves no orphan worker task. Idempotent. Called from the lifecycle teardown
    /// (an orchestrator's `close`) before releasing the corpus.
    func dropIngestQueue() {
        ingestDrainWorker?.cancel()
        ingestDrainWorker = nil
        // Release the lease so another process can take over without waiting out
        // the TTL. No-op if we do not hold it (or there is no lease).
        drainLease?.release()
        drainLease = nil
        ingestQueue = nil
    }

    /// Set (or clear) the `onEncoded` coordination callback. An actor's property
    /// cannot be assigned from outside the actor, so the orchestrator
    /// (GeniusLocusKit) installs the room-rollup callback through this isolated
    /// setter. Mirrors the Rust `Corpus::set_on_encoded`.
    func setOnEncoded(_ callback: (@Sendable ([String]) async -> Void)?) {
        onEncoded = callback
    }

    // MARK: - Enqueue / await

    /// Enqueue text for asynchronous ingest onto the corpus's encode stream.
    ///
    /// Mounts the queue on demand if it is absent. Empty text is skipped (nothing
    /// to encode). The drain worker picks the job up near-realtime and ingests it
    /// via the parallel `ingestBatch`. `sourceID` is the stable source handle
    /// (drawer id in the GLK context) so BM25/vector hits hydrate back to it;
    /// `now` is the capture instant (used as the deterministic vector filing
    /// timestamp, reproducing capture time rather than the later drain time).
    ///
    /// Jobs are stamped with `stream_id = "encode"` (T4) so the drain worker can
    /// claim only the encode stream without disturbing other streams that may share
    /// the same queue.sqlite in the future (ADR-021 Decision 7 / T1).
    ///
    /// - Parameters:
    ///   - text: The verbatim text to encode.
    ///   - sourceID: Stable identifier for the source document.
    ///   - now: The capture instant; never call `Date()` in the engine.
    /// - Throws: A queue send/schema error.
    func enqueueIngest(_ text: String, sourceID: String, now: Date) async throws {
        guard !text.isEmpty else { return }
        if ingestQueue == nil { try await mountIngestQueue() }
        guard let queue = ingestQueue else { return }

        let job = IngestJob(sourceID: sourceID, text: text, capturedAt: now)
        // Stamp the queue submission on the corpus's ingest HLC. The HLC physical
        // clock is milliseconds since the Unix epoch, derived from the capture
        // instant (deterministic — no Date() in the engine).
        let physMillis = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let submittedAt = ingestHLC.send(now: physMillis)
        let queueJob = try job.toJob(streamID: Self.encodeStreamID, submittedAt: submittedAt)
        try await queue.send(queueJob)
    }

    /// Enqueue many ingest jobs in one pass — the bulk twin of `enqueueIngest`,
    /// for the post-import reindex. Stamps each on the corpus's ingest HLC in
    /// sequence (deterministic) and hands the whole batch to `send(batch:)` so the
    /// PersistenceKit backend wraps all inserts in ONE transaction instead of N
    /// autocommits — the per-job autocommit was the last full-core bottleneck of a
    /// bulk import on the encrypted SQLite backend. Empty-text items are skipped.
    /// The caller chunks the input so the single transaction window stays bounded
    /// against concurrent live captures. Rust twin: `Corpus.enqueue_ingest_batch`.
    func enqueueIngestBatch(_ items: [(text: String, sourceID: String, now: Date)]) async throws {
        guard !items.isEmpty else { return }
        if ingestQueue == nil { try await mountIngestQueue() }
        guard let queue = ingestQueue else { return }

        var jobs: [Job] = []
        jobs.reserveCapacity(items.count)
        for item in items where !item.text.isEmpty {
            let job = IngestJob(sourceID: item.sourceID, text: item.text, capturedAt: item.now)
            let physMillis = Int64((item.now.timeIntervalSince1970 * 1000).rounded())
            let submittedAt = ingestHLC.send(now: physMillis)
            jobs.append(try job.toJob(streamID: Self.encodeStreamID, submittedAt: submittedAt))
        }
        // writeBatch on PersistenceKitBackend wraps all inserts in ONE transaction
        // (overridden from the default per-job loop — T4 perf parity).
        _ = try await queue.send(batch: jobs)
    }

    /// Block until the corpus's ingest queue has fully drained — every enqueued
    /// job ingested and replied — then return. Returns promptly on an empty
    /// queue and immediately when no queue is mounted (nothing to drain). The
    /// signal a bulk caller (importer, acceptance test) uses to know a batch of
    /// enqueued writes has become semantically searchable.
    ///
    /// - Parameter timeout: Upper bound on the wait. Defaults to 30 s.
    /// - Throws: `QueueError.drainTimeout` if the queue does not empty in time.
    func awaitIngestDrain(timeout: Duration = .seconds(30)) async throws {
        guard let queue = ingestQueue else { return }
        // Stream-scoped barrier: OBSERVE only the ENCODE stream's frontiers
        // (pending + in-flight), never claiming. The shared per-estate queue.sqlite
        // also carries dreaming (and signals) jobs this encode drainer never
        // processes; a GLOBAL awaitDrain would block on them forever (the
        // post-T4/T6 encode-stall — dreaming jobs enqueued on recall would hang
        // every subsequent capture's encode barrier). The claim (drain(stream:))
        // and the barrier must scope to the SAME stream.
        try await queue.awaitDrain(stream: Self.encodeStreamID, timeout: timeout)
        // Every enqueued job is now ingested (vectors appended under the deferred
        // window). Publish the resident index once so the writes are searchable
        // before this barrier returns — the bulk caller's searchability contract.
        try await publishVectorIndex()
    }

    // MARK: - Depth (read-only status probe)

    /// The corpus ingest drain's outstanding work, as a point-in-time snapshot
    /// for status reporting. Returns `(pending, inFlight)`: `pending` is jobs
    /// submitted but not yet claimed (encode stream only), `inFlight` is jobs
    /// claimed and mid-encode (encode stream in "cur"). Their sum is the encode
    /// work the drain has left; both zero means the drain is idle — everything
    /// enqueued has been encoded and replied.
    ///
    /// Read-only: observes the encode-stream frontiers only, never claims.
    /// Returns `(0, 0)` when no queue is mounted. Mirrors Swift's
    /// `Corpus.ingestQueueDepth()`.
    func ingestQueueDepth() async throws -> (pending: Int, inFlight: Int) {
        guard let queue = ingestQueue else { return (0, 0) }
        // Use stream-scoped pending count (T1) — counts only encode jobs.
        let pending = try await queue.pendingCount(stream: Self.encodeStreamID)
        // in-flight across ALL streams (encode jobs already claimed are "cur" rows)
        let inFlight = try await queue.inFlight().count
        return (pending, inFlight)
    }

    // MARK: - Drain (internal — drivable by tests)

    /// Drain the ingest queue once: claim every currently-available encode job,
    /// ingest the batch, reply terminal for each, then fire the `onEncoded`
    /// coordination callback.
    ///
    /// Uses the T1 stream-scoped `drain(stream: .encode)` so it never claims
    /// dreaming or signal jobs that may share the queue.sqlite in the future.
    /// Returns the number of jobs in the pass. Reachable for tests to drive the
    /// drain deterministically. Mirrors Swift's `Corpus.drainIngestQueueOnce`.
    @discardableResult
    func drainIngestQueueOnce() async throws -> Int {
        guard let queue = ingestQueue else { return 0 }
        // T1 stream-scoped drain: claim only encode jobs.
        let batch = try await queue.drain(stream: Self.encodeStreamID)
        guard !batch.isEmpty else { return 0 }

        // Single-pass claim tags the whole batch with ONE session; capture it so
        // the fast path can retire the whole batch in one reply(session:) call.
        let batchSession = batch[0].sessionID

        // Enter deferred-index mode for this burst (idempotent across passes): the
        // batch's vector writes append to the resident array but defer the index
        // rebuild to publishVectorIndex(), called once when the burst drains to
        // empty (the loop) or at the awaitIngestDrain barrier — O(N), not O(N²).
        try await beginDeferredVectorIndex()

        if _ingestFailureHook == nil {
            // Parallel fast path: decode the batch into ingest items, run the
            // concurrent batch ingest, then reply terminal per job.
            var items: [(text: String, sourceID: String, now: Date)] = []
            var itemJobs: [Job] = []
            items.reserveCapacity(batch.count)
            itemJobs.reserveCapacity(batch.count)
            for (job, _) in batch {
                guard let ij = try? IngestJob.from(job: job) else {
                    // Undecodable is permanent → blocked (no retry budget spent).
                    try? await queue.reply(to: job.id, status: .blocked, artifacts: [])
                    continue
                }
                guard !ij.text.isEmpty else {
                    // Nothing to ingest → done immediately.
                    try? await queue.reply(to: job.id, status: .done, artifacts: [])
                    continue
                }
                items.append((ij.text, ij.sourceID, ij.capturedAt))
                itemJobs.append(job)
            }
            if !items.isEmpty {
                do {
                    try await ingestBatch(items)
                    // Single-pass complete: retire every still-"cur" job of this
                    // batch's session in ONE update instead of N per-job replies
                    // (each an O(N) scan). Undecodable/empty jobs were already
                    // replied above, so the guard (status="cur") flips exactly the
                    // ingested batch. Fall back to per-job only if the backend has
                    // no batch fast path (reply(session:) returns 0).
                    let completed = try await queue.reply(session: batchSession, status: .done)
                    if completed == 0 {
                        // No session fast path (FilesystemBackend): retire the whole
                        // batch in ONE pass — one cur/ scan + one durability barrier
                        // — instead of per-job reply, whose FilesystemBackend complete
                        // was O(N²) (a full cur/ scan per job) plus a per-job fsync.
                        let completions = itemJobs.map {
                            (jobID: $0.id, status: ObservationStatus.done)
                        }
                        _ = try? await queue.reply(batch: completions)
                    }
                } catch {
                    // Batch failed — fall back to the per-job path so the
                    // idempotent AT-LEAST-ONCE retry still lands each item.
                    corpusIngestLog.error(
                        "ingestBatch failed: \(error, privacy: .public) — falling back to per-job ingest")
                    for job in itemJobs {
                        await ingestOneAndReply(job: job, on: queue)
                    }
                }
            }
        } else {
            // Serial path: test failure-injection active. Exercises the
            // bounded at-least-once retry per job.
            for (job, _) in batch {
                await ingestOneAndReply(job: job, on: queue)
            }
        }

        // Coordination callback (off the encode path): hand the encoded sourceIDs
        // to the orchestrator so it can roll up the touched LocusKit rooms. nil
        // when standalone. CorpusKit never reaches into LocusKit itself.
        if let onEncoded {
            let sourceIDs: [String] = batch.compactMap { try? IngestJob.from(job: $0.0).sourceID }
            if !sourceIDs.isEmpty { await onEncoded(sourceIDs) }
        }
        return batch.count
    }

    // MARK: - Internals

    /// The foreground drain loop for the corpus's ingest queue.
    ///
    /// Each pass drains the whole available encode batch (`drainIngestQueueOnce`)
    /// and ingests it, then sleeps a short interval before polling again. The
    /// short idle cadence is the near-realtime latency floor; long enough that an
    /// idle corpus does not spin a core. Cancelled in `dropIngestQueue`.
    private func runIngestDrainLoop() async {
        // Publish the deferred resident index once a burst drains to empty, not
        // per pass: while jobs keep arriving the loop spin-drains (no sleep, no
        // publish) so the index is rebuilt ONCE per burst — O(N) bulk import. A
        // single steady-state capture drains in one pass, then the next empty pass
        // publishes it, so near-realtime searchability is preserved.
        var pendingPublish = false
        // Single-drainer lease bookkeeping (T2): the instant of our last confirmed
        // hold. We refresh the heartbeat at most every `leaseHeartbeat` while
        // holding (not on every 15 ms pass) to avoid needless lease-file writes;
        // the interval is well inside the lease TTL so the hold never lapses. No
        // lease (in-memory estate) → always drain.
        var heldLeaseAt: Date? = nil
        // Crash-recovery: reclaim stale "cur" jobs once — and only once — when
        // this drainer FIRST acquires the encode lease. A successful tryAcquire
        // means the prior holder is dead (lease absent or stale > TTL = 15 s), so
        // every "cur" row for the encode stream is an orphan from the prior crash.
        // We reset them to "new" before the first drain pass so they are reprocessed.
        // Safety: tryAcquire succeeds iff no OTHER drainer holds a fresh lease,
        // so this call never yanks a "cur" job out from under a live drainer.
        var reclaimedOnMount = false
        while !Task.isCancelled {
            if let lease = drainLease {
                let now = Date()
                let refreshDue = heldLeaseAt.map {
                    now.timeIntervalSince($0) >= DrainLease.heartbeatInterval
                } ?? true
                if refreshDue {
                    if lease.tryAcquire(now: now) {
                        heldLeaseAt = now
                        // On-mount crash recovery: reclaim orphaned "cur" jobs the
                        // FIRST time this process acquires the lease. tryAcquire
                        // succeeds only when the prior holder is dead or absent;
                        // reclaimInFlight resets its stale "cur" rows to "new" so
                        // the drain re-drives them — the encode stream's AT-LEAST-ONCE
                        // guarantee after a drainer crash.
                        if !reclaimedOnMount, let queue = ingestQueue {
                            do {
                                let n = try await queue.reclaimInFlight(stream: Self.encodeStreamID)
                                if n > 0 {
                                    corpusIngestLog.info(
                                        "encode drain mount: reclaimed \(n) orphaned in-flight job(s) — prior drainer died mid-encode")
                                }
                            } catch {
                                corpusIngestLog.error(
                                    "encode drain mount: reclaimInFlight failed: \(error, privacy: .public)")
                            }
                            reclaimedOnMount = true
                        }
                    } else {
                        // Another process holds a fresh lease — stand down as a warm
                        // standby and re-check well within the TTL so we take over
                        // promptly if it dies. (Idempotent ingest makes a rare brief
                        // two-drainer overlap during takeover harmless.)
                        heldLeaseAt = nil
                        try? await Task.sleep(for: .seconds(3))
                        continue
                    }
                } else if let held = heldLeaseAt, now.timeIntervalSince(held) >= DrainLease.heartbeatInterval {
                    // Heartbeat: refresh while we hold without re-acquiring.
                    lease.heartbeat(now: now)
                    heldLeaseAt = now
                }
            }
            do {
                let drained = try await drainIngestQueueOnce()
                if drained > 0 {
                    pendingPublish = true
                    continue  // drain the rest of the burst before publishing
                }
                if pendingPublish {
                    try await publishVectorIndex()
                    pendingPublish = false
                }
            } catch {
                corpusIngestLog.error("ingest drain loop error: \(error, privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Ingest one drained job and reply terminal (the serial per-job body shared
    /// by the failure-injection path and the batch fallback).
    ///
    /// AT-LEAST-ONCE: the job is replied `.done` only AFTER ingest succeeds; a
    /// transient ingest failure is retried in place (up to `ingestMaxAttempts`)
    /// so no enqueued source is silently lost. `ingest` is idempotent
    /// (content-addressed chunk ids), so in-place retry is safe and never
    /// duplicates. A permanently-failing ingest, or an undecodable job, is
    /// finally replied `.blocked` so the queue never wedges.
    private func ingestOneAndReply(job: Job, on queue: QueueKit) async {
        guard let ij = try? IngestJob.from(job: job) else {
            corpusIngestLog.error("ingest job decode failed; replying blocked")
            try? await queue.reply(to: job.id, status: .blocked, artifacts: [])
            return
        }
        guard !ij.text.isEmpty else {
            try? await queue.reply(to: job.id, status: .done, artifacts: [])
            return
        }
        var lastError: (any Error)?
        for attempt in 1...Self.ingestMaxAttempts {
            do {
                // Test seam: a non-nil hook simulates a transient ingest failure
                // (nil in production — zero overhead).
                try _ingestFailureHook?(ij.sourceID)
                try await ingest(ij.text, sourceID: ij.sourceID, now: ij.capturedAt)
                try await queue.reply(to: job.id, status: .done, artifacts: [])
                return
            } catch {
                lastError = error
                corpusIngestLog.error(
                    "ingest attempt \(attempt, privacy: .public)/\(Self.ingestMaxAttempts, privacy: .public) failed for \(ij.sourceID, privacy: .public): \(error, privacy: .public)")
            }
        }
        corpusIngestLog.error(
            "ingest gave up after \(Self.ingestMaxAttempts, privacy: .public) attempts for \(ij.sourceID, privacy: .public); last error: \(String(describing: lastError), privacy: .public)")
        try? await queue.reply(to: job.id, status: .blocked, artifacts: [])
    }

    // MARK: - Test seam

    /// Arm (or clear) the test-only ingest failure hook. Never called in
    /// production. Reachable in-module for the at-least-once retry tests.
    func _armIngestFailureHook(_ hook: (@Sendable (String) throws -> Void)?) {
        _ingestFailureHook = hook
    }

    // MARK: - Constants

    /// The bounded at-least-once retry budget for a single ingest. Corpus ingest
    /// is idempotent (content-addressed chunk ids), so an in-place retry is the
    /// spec-sanctioned consumer-retry pattern (QueueKit B-7 forbids the QUEUE
    /// auto-requeuing a half-applied job, not the CONSUMER retrying an idempotent
    /// op). 8 attempts outlast any realistic transient hiccup while bounding a
    /// permanently-failing job's cost.
    private static var ingestMaxAttempts: Int { 8 }

    /// The encode stream id (T4 / ADR-021 Decision 7). One stream per encode
    /// drain; the queue.sqlite can host other streams (e.g. "dreaming") alongside
    /// without cross-contamination — each consumer drains only its own stream_id.
    static var encodeStreamID: StreamID { StreamID(rawValue: "encode") }

    /// Fixed estate identity for the transient in-memory ingest-queue backend.
    /// The backend is per-Corpus and never shared, so the id is cosmetic; a
    /// constant avoids UUID() nondeterminism in the engine. Same UUID as before
    /// (InMemory estates do not persist, so cross-session identity is irrelevant).
    private static var ingestQueueStoreID: UUID {
        // swiftlint:disable:next force_unwrapping — compile-time constant UUID literal
        UUID(uuidString: "C0B0C0DE-0000-0000-0000-000000000000")!
    }
}

// MARK: - BackendConfiguration helper

private extension BackendConfiguration {
    /// Extract the SQLite URL from a `.sqlite` backend. Returns nil for other backends.
    var sqliteURL: URL? {
        if case let .sqlite(url, _) = self { return url }
        return nil
    }
}

// MARK: - IngestJob

/// The work item the corpus ingest queue carries: everything the drain worker
/// needs to ingest one source into the corpus deterministically.
///
/// Simpler than GeniusLocusKit's former `EncodeJob`: the corpus encodes under
/// its own configured providers, so the payload carries only `(sourceID, text,
/// capturedAt)` — no estate UUID, no embedding-model tag (those were GLK
/// orchestration concerns). A plain Codable value (no behavior) encoded into
/// QueueKit's opaque `Job.payload`, so the Swift and Rust queue wire formats
/// agree on it (parity). The JSON field names (`sourceID`, `text`,
/// `capturedAtISO8601`) are stable and must match the Rust twin's serde fields
/// exactly — they are the cross-port wire contract.
struct IngestJob: Sendable, Codable, Hashable {
    /// The stable source identifier (drawer id in the GLK context), used as
    /// `sourceID` for `ingest` so BM25/vector hits hydrate back to it.
    let sourceID: String
    /// The verbatim text to encode.
    let text: String
    /// The capture instant, ISO8601. Passed back into `ingest(now:)` so vector
    /// filing timestamps reproduce capture time, not the later drain time.
    let capturedAtISO8601: String

    /// Build an IngestJob from a source's fields.
    init(sourceID: String, text: String, capturedAt: Date) {
        self.sourceID = sourceID
        self.text = text
        self.capturedAtISO8601 = Self.makeISO8601().string(from: capturedAt)
    }

    /// The capture instant decoded back from `capturedAtISO8601`, or the Unix
    /// epoch if the stored string is unparseable (defensive — a malformed
    /// timestamp must not crash the worker; epoch keeps ingest deterministic).
    var capturedAt: Date {
        Self.makeISO8601().date(from: capturedAtISO8601) ?? Date(timeIntervalSince1970: 0)
    }

    /// A fresh ISO8601 formatter. `internetDateTime` + fractional seconds so
    /// sub-second capture instants round-trip exactly. Built per call rather
    /// than cached as a static: `ISO8601DateFormatter` is not `Sendable`, so a
    /// shared mutable static would break strict concurrency; encode/decode here
    /// is not hot (one call per enqueue/drain).
    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// Encode this payload into a QueueKit `Job` ready to `send`.
    func toJob(streamID: StreamID, submittedAt: HLC, priority: Int = 50) throws -> Job {
        let data = try JSONEncoder().encode(self)
        return Job(
            id: JobID.generate(),
            streamID: streamID,
            submittedAt: submittedAt,
            priority: priority,
            payload: data
        )
    }

    /// Decode an IngestJob back from a drained QueueKit `Job`.
    static func from(job: Job) throws -> IngestJob {
        try JSONDecoder().decode(IngestJob.self, from: job.payload)
    }
}
