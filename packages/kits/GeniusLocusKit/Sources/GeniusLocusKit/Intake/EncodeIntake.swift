// EncodeIntake.swift
//
// Dual-Path Intake P3 / P4 / P6 — the capture→encode wiring.
//
// THE LOAD-BEARING CHANGE: before this wiring, a `moot_file_memory` write
// produced a LocusKit drawer row ONLY — never chunked, never BM25-indexed,
// never embedded — so the semantic (BM25 + vector) recall lanes were DARK for
// normally-captured content. This file connects capture to `Corpus.ingest`, the
// one call that lights those lanes, via two paths:
//
//   • REGULAR (P3 + P4): capture returns immediately; an EncodeJob is enqueued
//     onto the estate's dedicated encode queue; a background drain worker (P4)
//     ingests it into the Corpus and replies terminal. After the queue drains,
//     the drawer is BM25/vector searchable.
//
//   • IMPATIENT (P6): capture ingests the drawer into the Corpus INLINE before
//     returning, skipping the queue — the drawer is searchable the instant the
//     write returns, at the cost of a slower write.
//
// D-A: the write mode is an EXECUTION OPTION on the write verb (a GLK param),
//      not a field on CaptureFrame — mirroring how `scoring` is an option on the
//      recall verb. CaptureFrame's schema is untouched.
// D-B: ONE QueueKit per estate (dedicated, not the Brain scheduler's queue),
//      mounted at provision alongside the corpus/vector registration.
//
// G4: the worker ingests with `sourceID = drawer.id` so BM25/vector hits hydrate
//     back to the real Drawer row (RecallDirector hydration by drawer id).

import Foundation
import CorpusKit
import LocusKit
import OSLog
import PersistenceKit
import PersistenceKitInMemory
import QueueKit
import SubstrateTypes

/// The execution mode for a write verb (D-A).
///
/// `regular` is the default: the write returns as soon as the drawer row lands,
/// and semantic encoding happens asynchronously on the encode drain worker.
/// `impatient` trades write latency for immediate searchability: the drawer is
/// ingested into the Corpus inline before the write returns.
public enum WriteMode: String, Sendable, Codable, CaseIterable {
    /// Enqueue the encode job; the drain worker encodes it asynchronously.
    case regular
    /// Encode inline before the write returns; the drawer is immediately
    /// semantically searchable.
    case impatient
}

public extension GeniusLocusKit {

    private static var intakeLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - capture (mode-aware) — D-A

    /// File a new drawer into the estate addressed by `handle`, then encode it
    /// into the estate's Corpus per `mode` (Dual-Path Intake).
    ///
    /// This is the mode-aware capture verb. It dispatches the same
    /// `Estate.capture` as the legacy `capture(_:_:)`, then:
    ///
    ///   • `.regular` — enqueues an `EncodeJob` onto the estate's encode queue
    ///     (P3). The background drain worker (P4) ingests it. The write returns
    ///     before encoding completes; callers that need to know encoding
    ///     finished use `awaitEncodeDrain(for:)`.
    ///   • `.impatient` — ingests the drawer into the Corpus inline (P6) before
    ///     returning, so the drawer is BM25/vector searchable immediately. No
    ///     queue job is enqueued.
    ///
    /// Encoding is a no-op (and `.regular`/`.impatient` behave identically — both
    /// just store the drawer row) when no Corpus is registered for the estate
    /// (e.g. a `.locusOnly` estate). The legacy `capture(_:_:)` is unchanged and
    /// continues to store the drawer row only; this overload is purely additive.
    ///
    /// - Parameters:
    ///   - handle: The estate to capture into. Must be open.
    ///   - frame: The capture frame (content, room, lattice anchor, …).
    ///   - mode: `.regular` (enqueue) or `.impatient` (inline encode).
    /// - Returns: The stored `Drawer`.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   `VerbError.underlyingEstateFailure` on a LocusKit failure; or an ingest
    ///   error in `.impatient` mode (the drawer row is already durably stored).
    @discardableResult
    func capture(
        _ handle: EstateHandle,
        _ frame: CaptureFrame,
        mode: WriteMode
    ) async throws -> Drawer {
        // 1. Store the drawer row (identical to the legacy capture verb).
        let drawer = try await capture(handle, frame)

        // 2. Encode per mode — only when a Corpus is registered for the estate.
        guard corpusKits[handle] != nil else {
            // No semantic lane to feed (e.g. .locusOnly). The drawer row is
            // stored; nothing to ingest. Both modes degrade to row-only.
            return drawer
        }

        switch mode {
        case .impatient:
            // P6: ingest inline before returning. sourceID = drawer.id (G4).
            // now = drawer.filedAt — the capture instant — so vector filing
            // timestamps reproduce capture time deterministically (no Date()
            // inside the engine). The drawer row is already durably stored, so
            // an ingest failure surfaces to the caller without losing content.
            try await ingestDrawerIntoCorpus(handle: handle, drawer: drawer)
        case .regular:
            // P3: enqueue an EncodeJob; the drain worker (P4) ingests it.
            try await enqueueEncodeJob(handle: handle, drawer: drawer)
        }
        return drawer
    }

    // MARK: - mountEncodeQueue — D-B (called at provision)

    /// Mount the estate's dedicated encode queue and start its drain worker.
    ///
    /// D-B: ONE QueueKit per estate, distinct from the Brain scheduler's queue.
    /// Backed by a transient in-memory PersistenceKitBackend (the same substrate
    /// the scheduler uses) so it needs no estate file directory and works for
    /// in-memory estates. Idempotent: re-mounting an already-mounted estate is a
    /// no-op (the existing queue and worker are kept).
    ///
    /// Called from `provision` for `.glk`/`.corpusOnly` estates (those with a
    /// Corpus to feed). `.locusOnly` estates do not mount an encode queue.
    ///
    /// - Parameter handle: The estate to mount the encode queue for. Must be open.
    /// - Throws: A storage/schema error if the queue backend cannot be opened.
    func mountEncodeQueue(for handle: EstateHandle) async throws {
        guard encodeQueues[handle] == nil else { return }  // idempotent
        // Transient in-memory queue substrate — mirrors StandingSignalScheduler.
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: handle.estateUUID,
            backend: .inMemory))
        try await PersistenceKitBackend.openSchema(on: storage)
        let backend = PersistenceKitBackend(storage: storage)
        let queue = QueueKit(backend: backend)
        queue.estateTag = handle.estateUUID.uuidString
        encodeQueues[handle] = queue
        encodeHLCs[handle] = HLCGenerator(nodeID: 1)

        // P4: spawn the background drain worker (near-realtime, load-robust). It
        // runs on the actor, draining the whole available batch each pass and
        // ingesting into the Corpus, so awaitEncodeDrain can observe completion.
        // Cancelled in dropEncodeQueue/close(). See runEncodeDrainLoop for why a
        // poll worker (not watch) is the correct claimer on the actor.
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.runEncodeDrainLoop(for: handle)
        }
        encodeDrainWorkers[handle] = worker
        Self.intakeLog.debug(
            "mounted encode queue for estate \(handle.estateUUID, privacy: .public)")
    }

    /// Tear down the estate's encode queue and drain worker.
    ///
    /// Cancels the background worker and drops the queue/HLC/worker registry
    /// entries. Called from `close` so a torn-down estate leaves no orphan
    /// worker task. Idempotent.
    ///
    /// - Parameter handle: The estate whose encode queue to drop.
    func dropEncodeQueue(for handle: EstateHandle) {
        encodeDrainWorkers[handle]?.cancel()
        encodeDrainWorkers[handle] = nil
        encodeQueues[handle] = nil
        encodeHLCs[handle] = nil
    }

    // MARK: - awaitEncodeDrain (P5 consumer)

    /// Block until the estate's encode queue has fully drained — every enqueued
    /// `EncodeJob` has been ingested and replied — then return.
    ///
    /// Delegates to `QueueKit.awaitDrain()` (P5). Returns promptly when the queue
    /// is already empty and does not hang on an empty queue. This is the signal a
    /// bulk caller (importer, gauntlet) or an acceptance test uses to know that a
    /// batch of regular writes has become semantically searchable.
    ///
    /// Returns immediately if no encode queue is mounted for the estate (e.g. a
    /// `.locusOnly` estate, or an estate provisioned before the intake wiring) —
    /// there is nothing to drain.
    ///
    /// - Parameters:
    ///   - handle: The estate whose encode queue to await.
    ///   - timeout: Upper bound on the wait. Defaults to 30 s.
    /// - Throws: `QueueError.drainTimeout` if the queue does not empty in time.
    func awaitEncodeDrain(
        for handle: EstateHandle,
        timeout: Duration = .seconds(30)
    ) async throws {
        guard let queue = encodeQueues[handle] else { return }
        // The watch-driven background worker is the SOLE drainer of this queue
        // (running two concurrent claimers over one queue can wedge a job
        // claimed-but-unreplied if a claim transaction commits the new→cur move
        // but its consumer never sees the row). This barrier therefore only
        // OBSERVES the frontiers — it does not claim. It returns once both are
        // clear (every enqueued job ingested and replied by the worker), and the
        // worker's drain-until-empty-per-wake guarantees no committed job is left
        // behind, so a pure frontier wait converges.
        try await queue.awaitDrain(timeout: timeout)
    }

    // MARK: - reindexMissing (backfill for pre-wiring drawers)

    /// Enqueue encode jobs for every active drawer in the estate that is NOT
    /// already present in the Corpus BundleStore.
    ///
    /// Use this after deploying the dual-path intake fix to backfill the existing
    /// drawers that were captured before the encode pipeline was wired. Each
    /// missing drawer is enqueued as a `.regular` EncodeJob — the background drain
    /// worker ingests them into the Corpus (BM25 + vector) asynchronously, so this
    /// call returns quickly regardless of estate size.
    ///
    /// **Idempotent:** drawers already in the BundleStore (identified by
    /// `Corpus.indexedSourceIDs()`) are skipped. Calling this multiple times is
    /// safe — already-indexed drawers are never double-enqueued.
    ///
    /// **No Corpus, no-op:** if no Corpus is registered for the estate (e.g. a
    /// `.locusOnly` estate), the call returns 0 immediately.
    ///
    /// - Parameters:
    ///   - handle: The estate to reindex. Must be open.
    ///   - now: The operation instant used as the capture timestamp for enqueued
    ///     jobs. Pass the current date; the caller never reads the clock inside an
    ///     engine (determinism rule).
    /// - Returns: The number of drawers enqueued for re-encoding.
    /// - Throws: An estate-not-open error if the handle is stale; a corpus query
    ///   error if the indexed-source-IDs query fails; an estate recall error.
    public func reindexMissing(
        handle: EstateHandle,
        now: Date
    ) async throws -> Int {
        // No Corpus → no semantic lane to feed. Return immediately.
        guard let corpus = corpusKits[handle] else { return 0 }

        // Fetch the set of source IDs already indexed in the BundleStore.
        // These are the drawer IDs that already have chunks and can be skipped.
        let indexedIDs = try await corpus.indexedSourceIDs()

        // Recall all active (non-tombstoned) drawers from the estate.
        // .full hydration is required because we need the drawer content to
        // enqueue the EncodeJob payload. (.structured returns content = "")
        let estate = try estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        let activeDrawers = allDrawers.filter { $0.tombstonedAt == nil }

        var enqueued = 0
        for drawer in activeDrawers {
            // Skip drawers with empty content — nothing to encode (matches the
            // guard in enqueueEncodeJob).
            guard !drawer.content.isEmpty else { continue }
            // Skip drawers already in the BundleStore — idempotence.
            guard !indexedIDs.contains(drawer.id) else { continue }
            // Enqueue using the existing P3 path. The drain worker picks it up
            // near-realtime. The draw's filedAt is used as the capture instant
            // so vector filing timestamps are deterministic (not now).
            try await enqueueEncodeJob(handle: handle, drawer: drawer)
            enqueued += 1
        }
        Self.intakeLog.info(
            "reindexMissing: enqueued \(enqueued, privacy: .public) drawers for estate \(handle.estateUUID, privacy: .public) (\(activeDrawers.count, privacy: .public) active, \(indexedIDs.count, privacy: .public) already indexed)")
        return enqueued
    }

    // MARK: - Internals

    /// Enqueue an `EncodeJob` for a captured drawer (P3).
    ///
    /// Mounts the encode queue on demand if it is absent (an estate opened via
    /// the legacy `open` path rather than `provision` still gets a queue on its
    /// first regular write). Skips drawers with empty content — there is nothing
    /// to encode.
    private func enqueueEncodeJob(
        handle: EstateHandle,
        drawer: Drawer
    ) async throws {
        guard !drawer.content.isEmpty else { return }
        if encodeQueues[handle] == nil {
            try await mountEncodeQueue(for: handle)
        }
        guard let queue = encodeQueues[handle] else { return }

        let job = EncodeJob(
            drawerID: drawer.id,
            estateUUID: handle.estateUUID,
            text: drawer.content,
            embeddingModelID: drawer.embeddingModelID,
            capturedAt: drawer.filedAt
        )
        // Stamp the queue submission on the estate's per-estate HLC. The HLC
        // physical clock is milliseconds since the Unix epoch, derived from the
        // drawer's capture instant (deterministic — no Date() in the engine).
        var hlc = encodeHLCs[handle] ?? HLCGenerator(nodeID: 1)
        let physMillis = Int64((drawer.filedAt.timeIntervalSince1970 * 1000).rounded())
        let submittedAt = hlc.send(now: physMillis)
        encodeHLCs[handle] = hlc
        let streamID = Self.encodeStreamID(for: handle)
        let queueJob = try job.toJob(streamID: streamID, submittedAt: submittedAt)
        try await queue.send(queueJob)
    }

    /// Ingest a single drawer into the estate's Corpus (P4/P6 shared call).
    ///
    /// `sourceID = drawer.id` (G4) so BM25/vector hits hydrate to this drawer.
    /// `now = drawer.filedAt` for deterministic vector filing timestamps. A
    /// no-op when no Corpus is registered.
    private func ingestDrawerIntoCorpus(
        handle: EstateHandle,
        drawer: Drawer
    ) async throws {
        guard let corpus = corpusKits[handle] else { return }
        guard !drawer.content.isEmpty else { return }
        try await corpus.ingest(
            drawer.content,
            sourceID: drawer.id,
            now: drawer.filedAt
        )
    }

    /// The background drain loop for an estate's encode queue (P4).
    ///
    /// NEAR-REALTIME, LOAD-ROBUST poll worker. Each pass drains the WHOLE
    /// currently-available batch (`drainEncodeQueueOnce`) and ingests it, then
    /// sleeps a short interval before polling again. Because each pass drains the
    /// entire claimable batch — not one job — a burst of N captures is processed
    /// in a single pass, so the worker never starves under burst; the latency
    /// floor is the ~15 ms idle interval, not a per-job cadence.
    ///
    /// Why a poll and not `QueueKit.watch` here: the drain runs on the
    /// `GeniusLocusKit` actor, serialised with the capture path that writes the
    /// queue. A watch worker would claim rows off-actor, concurrently with the
    /// on-actor enqueue writes, contending on the in-memory backend's
    /// serializable claim transaction — which can strand a row claimed-but-
    /// unseen under burst. Keeping the sole claimer on the actor makes the lane
    /// load-robust by construction. (The Rust port, whose coordinator is not an
    /// actor, uses the observer-driven `watch` worker for the same near-realtime
    /// effect.)
    ///
    /// Cancelled in `dropEncodeQueue`/`close`. Ingest failures are logged and the
    /// job is still replied `.blocked` (via `ingestAndReply`) so it does not
    /// wedge the queue; the drawer row remains durably stored regardless.
    private func runEncodeDrainLoop(for handle: EstateHandle) async {
        while !Task.isCancelled {
            do {
                try await drainEncodeQueueOnce(for: handle)
            } catch {
                Self.intakeLog.error(
                    "encode drain loop error for estate \(handle.estateUUID, privacy: .public): \(error, privacy: .public)")
            }
            // Idle poll cadence. Short so newly-enqueued jobs encode promptly
            // (near-realtime floor); long enough that an idle estate does not
            // spin a core.
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Drain the encode queue once: ingest every currently-available job, then
    /// reply terminal for each (P4).
    ///
    /// Internal (not private) so tests can drive the drain deterministically
    /// without waiting on the background loop's poll cadence. Returns the number
    /// of jobs processed.
    ///
    /// - Parameter handle: The estate whose encode queue to drain.
    /// - Returns: The number of encode jobs ingested in this pass.
    /// - Throws: A queue error from `drain`/`reply`. Ingest errors are caught
    ///   per-job (logged, replied `.blocked`) and do not abort the pass.
    @discardableResult
    func drainEncodeQueueOnce(for handle: EstateHandle) async throws -> Int {
        guard let queue = encodeQueues[handle] else { return 0 }
        let batch = try await queue.drain()
        var processed = 0
        for (job, _) in batch {
            await ingestAndReply(job: job, on: queue, handle: handle)
            processed += 1
        }
        return processed
    }

    /// The bounded at-least-once retry budget for a single encode job's ingest.
    ///
    /// AT-LEAST-ONCE DELIVERY: a job is ACKed (replied terminal) only AFTER its
    /// ingest succeeds. A transient ingest failure does NOT silently drop the
    /// job — it is retried in place, up to this many attempts, before the job is
    /// finally replied `.blocked`. Corpus ingest is idempotent (chunk IDs are
    /// content-addressed — re-ingesting the same drawer overwrites the same
    /// postings, never duplicates), so an in-place retry is safe and does not
    /// violate QueueKit B-7 (which forbids the QUEUE from auto-requeuing a
    /// half-applied job; here the CONSUMER retries an idempotent op, the spec-
    /// sanctioned pattern). 8 attempts comfortably outlasts any realistic
    /// transient hiccup while bounding a permanently-failing job's cost.
    private static let encodeIngestMaxAttempts = 8

    /// Ingest one drained encode job into the estate's Corpus and reply terminal
    /// (the shared per-job body of both the watch-driven worker and the
    /// `drainEncodeQueueOnce` pump).
    ///
    /// G4: `sourceID = drawer.id`; `now = capture instant`. AT-LEAST-ONCE: the
    /// job is replied `.done` only AFTER ingest succeeds; a transient ingest
    /// failure is retried in place (up to `encodeIngestMaxAttempts`) so no
    /// successfully-captured drawer is silently lost. A permanently-failing
    /// ingest, or a job that cannot be decoded at all, is finally replied
    /// `.blocked` after the budget is spent (the drawer row is already durably
    /// stored, so the queue never wedges and `awaitEncodeDrain` can still
    /// release).
    private func ingestAndReply(
        job: Job,
        on queue: QueueKit,
        handle: EstateHandle
    ) async {
        // A decode failure is PERMANENT — retrying re-parses the same bytes to
        // the same error. Reply `.blocked` immediately (no retry budget spent).
        guard let encodeJob = try? EncodeJob.from(job: job) else {
            Self.intakeLog.error(
                "encode job decode failed in estate \(handle.estateUUID, privacy: .public); replying blocked")
            try? await queue.reply(to: job.id, status: .blocked, artifacts: [])
            return
        }
        // Nothing to ingest (empty text, or a .locusOnly estate with no Corpus):
        // the job is complete the moment it is acknowledged.
        guard let corpus = corpusKits[handle], !encodeJob.text.isEmpty else {
            try? await queue.reply(to: job.id, status: .done, artifacts: [])
            return
        }
        // AT-LEAST-ONCE: retry the (idempotent) ingest until it lands or the
        // bounded budget is spent. ACK `.done` only after a successful ingest.
        var lastError: (any Error)?
        for attempt in 1...Self.encodeIngestMaxAttempts {
            do {
                // Test seam: a non-nil hook can simulate a transient ingest
                // failure (nil in production — zero overhead).
                try encodeIngestFailureHook?(encodeJob.drawerID)
                try await corpus.ingest(
                    encodeJob.text,
                    sourceID: encodeJob.drawerID,
                    now: encodeJob.capturedAt
                )
                try await queue.reply(to: job.id, status: .done, artifacts: [])
                return
            } catch {
                lastError = error
                Self.intakeLog.error(
                    "encode ingest attempt \(attempt, privacy: .public)/\(Self.encodeIngestMaxAttempts, privacy: .public) failed for drawer \(encodeJob.drawerID, privacy: .public) in estate \(handle.estateUUID, privacy: .public): \(error, privacy: .public)")
            }
        }
        // Budget spent — the ingest is permanently failing. Reply `.blocked` so
        // the queue does not wedge; the drawer row remains durably stored.
        Self.intakeLog.error(
            "encode ingest gave up after \(Self.encodeIngestMaxAttempts, privacy: .public) attempts for drawer \(encodeJob.drawerID, privacy: .public) in estate \(handle.estateUUID, privacy: .public); last error: \(String(describing: lastError), privacy: .public)")
        try? await queue.reply(to: job.id, status: .blocked, artifacts: [])
    }

    /// The estate-scoped encode stream id. Distinct from the Brain scheduler's
    /// `glk_scheduler_<uuid>` stream so encode jobs never mix with signal jobs.
    static func encodeStreamID(for handle: EstateHandle) -> StreamID {
        StreamID(rawValue: "glk_encode_\(handle.estateUUID.uuidString.lowercased())")
    }
}
