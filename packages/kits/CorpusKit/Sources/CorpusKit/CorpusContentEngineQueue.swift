// CorpusContentEngineQueue.swift
//
// The content-reference encode pipeline (GLK shared-content 1.1, P3).
//
// The engine owns its encode queue, drain worker, and lease exactly as the
// legacy Corpus pipeline did (same shared per-estate queue.sqlite, same
// "encode" stream, same single-drainer lease discipline) — but the job
// payload is a `ContentIndexJob`: a Drawer CHANGE REFERENCE
// (id/revision/digest/cursor). The drain worker resolves the CURRENT text
// by ID from the engine's `CorpusContentSource` at work time. Verbatim
// content never rides the queue.
//
// Stale handling: a job whose (revision, digest) no longer matches the
// current record is DROPPED as done — the newer revision has (or will
// have) its own job, so retrying the stale one is pointless and retrying
// could never succeed. All other failures retry in place up to
// `contentIngestMaxAttempts`, then reply `.blocked` so the queue never
// wedges (AT-LEAST-ONCE; `processJob` is idempotent on checkpoints).
//
// Rust twin: the queue integration lands with the Rust coordinator cutover.

import Foundation
import OSLog
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes

private let contentEngineLog = Logger(subsystem: "com.mootx01.kit", category: "CorpusKit")

public extension CorpusContentEngine {

    /// The encode stream id — the SAME stream the legacy pipeline used, so
    /// one estate has one encode drainer regardless of engine generation.
    static var encodeStreamID: StreamID { StreamID(rawValue: "encode") }

    /// Retry budget for a transiently-failing content index job.
    static let contentIngestMaxAttempts = 3

    /// Fixed store UUID for the in-memory queue backend (deterministic).
    private static var contentQueueStoreID: UUID {
        UUID(uuidString: "3D1FB0A5-52C6-4E7A-9B1B-6E1D5C0A7A42")!
    }

    // MARK: - Mount / drop

    /// Mount the engine's ingest queue and start its drain worker.
    /// Idempotent. Backend selection mirrors the legacy pipeline: SQLite
    /// estates share the encrypted sibling queue.sqlite; in-memory estates
    /// get a transient queue.
    func mountIngestQueue() async throws {
        guard ingestQueue == nil else { return }
        let backend: any QueueBackend
        var newLease: DrainLease? = nil

        let cfg = storage.configuration
        if case .sqlite = cfg.backend {
            let siblingCfg = try cfg.queueSibling(filename: "queue.sqlite")
            let qs = try SQLiteStorage(configuration: siblingCfg)
            try await PersistenceKitBackend.openSchema(on: qs)
            backend = PersistenceKitBackend(storage: qs)
            let estateDir = siblingCfg.backend.sqliteURLForShards!.deletingLastPathComponent()
            newLease = DrainLease(
                directory: estateDir,
                stream: "encode",
                instanceToken: "\(ObjectIdentifier(self))")
        } else {
            let qs = InMemoryStorage(configuration: EstateConfiguration(
                estateID: Self.contentQueueStoreID,
                backend: .inMemory))
            try await PersistenceKitBackend.openSchema(on: qs)
            backend = PersistenceKitBackend(storage: qs)
        }
        let queue = QueueKit(backend: backend)
        queue.estateTag = "corpus_encode"
        ingestQueue = queue
        drainLease = newLease

        ingestDrainWorker = Task { [weak self] in
            guard let self else { return }
            await self.runContentDrainLoop()
        }
    }

    /// Tear down the queue and drain worker; awaits worker exit before
    /// releasing the lease (a successor process must not race the SQLite
    /// connection). Idempotent.
    func dropIngestQueue() async {
        ingestDrainWorker?.cancel()
        _ = await ingestDrainWorker?.value
        ingestDrainWorker = nil
        drainLease?.release()
        drainLease = nil
        ingestQueue = nil
    }

    /// Install (or clear) the `onEncoded` coordination callback.
    func setOnEncoded(_ callback: (@Sendable ([String]) async -> Void)?) {
        onEncoded = callback
    }

    // MARK: - Enqueue

    /// Enqueue one content change reference. Mounts the queue on demand.
    /// `capturedAt` stamps the submission HLC deterministically.
    func enqueueChange(
        _ change: CorpusContentChange, cursor: String?, capturedAt: Date
    ) async throws {
        try await enqueueChangeBatch([(change, cursor, capturedAt)])
    }

    /// Enqueue many change references in ONE backend transaction (the bulk
    /// twin — reindex backfills use this).
    func enqueueChangeBatch(
        _ items: [(change: CorpusContentChange, cursor: String?, capturedAt: Date)]
    ) async throws {
        guard !items.isEmpty else { return }
        if ingestQueue == nil { try await mountIngestQueue() }
        guard let queue = ingestQueue else { return }

        var jobs: [Job] = []
        jobs.reserveCapacity(items.count)
        for item in items {
            let payload = ContentIndexJob(change: item.change, cursor: item.cursor)
            let physMillis = Int64((item.capturedAt.timeIntervalSince1970 * 1000).rounded())
            let submittedAt = ingestHLC.send(now: physMillis)
            jobs.append(Job(
                id: JobID.generate(),
                streamID: Self.encodeStreamID,
                submittedAt: submittedAt,
                priority: 50,
                payload: try JSONEncoder().encode(payload)))
        }
        _ = try await queue.send(batch: jobs)
    }

    // MARK: - Barrier / depth

    /// Block until the encode stream fully drains, then publish the resident
    /// vector index (the bulk caller's searchability contract).
    func awaitIngestDrain(timeout: Duration = .seconds(30)) async throws {
        guard let queue = ingestQueue else { return }
        try await queue.awaitDrain(stream: Self.encodeStreamID, timeout: timeout)
        try await publishVectorIndex()
    }

    /// The encode drain's outstanding work: (pending, inFlight), stream-scoped.
    func ingestQueueDepth() async throws -> (pending: Int, inFlight: Int) {
        guard let queue = ingestQueue else { return (0, 0) }
        let pending = try await queue.pendingCount(stream: Self.encodeStreamID)
        let inFlight = try await queue.inFlight()
            .filter { $0.streamID == Self.encodeStreamID }
            .count
        return (pending, inFlight)
    }

    // MARK: - Drain worker

    private func runContentDrainLoop() async {
        var pendingPublish = false
        var heldLeaseAt: Date? = nil
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
                        if !reclaimedOnMount, let queue = ingestQueue {
                            do {
                                let n = try await queue.reclaimInFlight(stream: Self.encodeStreamID)
                                if n > 0 {
                                    contentEngineLog.info(
                                        "content drain mount: reclaimed \(n) orphaned in-flight job(s)")
                                }
                            } catch {
                                contentEngineLog.error(
                                    "content drain mount: reclaimInFlight failed: \(error, privacy: .public)")
                            }
                            reclaimedOnMount = true
                        }
                    } else {
                        heldLeaseAt = nil
                        try? await Task.sleep(for: .seconds(3))
                        continue
                    }
                } else if let held = heldLeaseAt,
                          now.timeIntervalSince(held) >= DrainLease.heartbeatInterval {
                    lease.heartbeat(now: now)
                    heldLeaseAt = now
                }
            }
            do {
                let drained = try await drainContentQueueOnce()
                if drained > 0 {
                    pendingPublish = true
                    continue
                }
                if pendingPublish {
                    try await publishVectorIndex()
                    pendingPublish = false
                }
            } catch {
                contentEngineLog.error("content drain loop error: \(error, privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Drain the encode stream once, embedding all upsert jobs in bounded
    /// parallel (≤ activeProcessorCount tasks concurrently) and firing
    /// `onEncoded` with the affected content IDs. Returns the claimed count.
    ///
    /// The pipeline is implemented by `drainIndexBatch(_:)` in
    /// CorpusContentEngine.swift (which has access to the engine's private
    /// stores). This wrapper owns only the queue interaction: drain, batch
    /// commit, and reply.
    @discardableResult
    func drainContentQueueOnce() async throws -> Int {
        guard let queue = ingestQueue else { return 0 }
        let claimed = try await queue.drain(stream: Self.encodeStreamID)
        guard !claimed.isEmpty else { return 0 }
        let jobs = claimed.map { $0.0 }

        // One resident-index rebuild per burst.
        try await beginDeferredVectorIndex()

        // Delegate the indexing pipeline to the engine (which owns the private
        // stores). Returns pre-assembled completions, checkpoints, countsUpdates,
        // encodedIDs, and the batchNow used for the commit timestamp.
        let result = try await drainIndexBatch(jobs)

        // Batch-boundary last write: maintained counts and the checkpoints
        // proving those folds commit atomically. It MUST precede terminal queue
        // completion so any failure leaves recoverable content references.
        do {
            try await commitQueueBatch(
                checkpoints: result.checkpoints,
                countsUpdates: result.countsUpdates,
                now: result.batchNow)
        } catch {
            do { try await publishVectorIndex() }
            catch let publicationError {
                throw CorpusKitError.storeUnavailable(
                    "\(error); resident-index publication after queue commit failure: "
                    + "\(publicationError)")
            }
            throw error
        }
        // Post-encode coordination fires BEFORE the terminal queue reply so
        // the callback's work is covered by drain-completion accounting:
        // `awaitIngestDrain` waits for pending+inFlight == 0, and jobs stay
        // in-flight until the reply below. GLK wires room rollup AND
        // drain-stage distillation into this callback
        // (SPEC_DISTILLATION_STORAGE §7.1) — this ordering is what makes
        // "a fully drained estate is a fully distilled estate" a real
        // barrier instead of a race. The callback is non-throwing; a hung
        // callback is bounded by the same lease-reclaim discipline that
        // covers a hung encode.
        if !result.encodedIDs.isEmpty, let callback = onEncoded {
            await callback(result.encodedIDs)
        }
        // Post-ingest young-basis settle: fires only when nothing further is
        // pending (this batch is committed above; it may still be in-flight
        // until the reply below, which keeps the settle's embedding work
        // inside drain-completion accounting — same rationale as the
        // onEncoded ordering). See settleYoungBasisIfGrown.
        try await settleYoungBasisIfGrown(now: result.batchNow, requireIdleInFlight: false)
        do {
            _ = try await queue.reply(batch: result.completions)
        } catch {
            do { try await publishVectorIndex() }
            catch let publicationError {
                throw CorpusKitError.storeUnavailable(
                    "content reply batch failed: \(error); resident-index publication failed: "
                    + "\(publicationError)")
            }
            throw error
        }
        return jobs.count
    }
}
