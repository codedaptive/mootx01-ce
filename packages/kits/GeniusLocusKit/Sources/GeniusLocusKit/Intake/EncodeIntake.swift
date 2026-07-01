// EncodeIntake.swift
//
// Dual-Path Intake — the capture→encode ORCHESTRATION.
//
// THE LOAD-BEARING CHANGE: before this wiring, a `moot_file_memory` write
// produced a LocusKit drawer row ONLY — never chunked, never BM25-indexed,
// never embedded — so the semantic (BM25 + vector) recall lanes were DARK for
// normally-captured content. This file connects capture to the estate's Corpus,
// which lights those lanes, via two paths:
//
//   • REGULAR (P3 + P4): capture returns immediately; the drawer is enqueued
//     onto the Corpus's OWN ingest queue (`Corpus.enqueueIngest`); the Corpus's
//     drain worker pool ingests it. After the queue drains, the drawer is
//     BM25/vector searchable.
//
//   • IMPATIENT (P6): capture ingests the drawer into the Corpus INLINE before
//     returning, skipping the queue — searchable the instant the write returns.
//
// LAYERING: the encode QUEUE + DRAIN + WORKER POOL live in CorpusKit (a Corpus
// queues, drains, and encodes itself — see CorpusKit's CorpusIngestQueue.swift).
// GeniusLocusKit is ONLY the orchestrator: it enqueues work into the Corpus, and
// — through the Corpus's `onEncoded` callback wired at provision — rolls up the
// touched LocusKit rooms for the encoded drawers. GLK never performs the encode.
//
// D-A: the write mode is an EXECUTION OPTION on the write verb (a GLK param),
//      not a field on CaptureFrame — mirroring how `scoring` is an option on the
//      recall verb. CaptureFrame's schema is untouched.
//
// G4: the drawer is ingested with `sourceID = drawer.id` so BM25/vector hits
//     hydrate back to the real Drawer row (RecallDirector hydration by drawer id).

import CorpusKit
import EideticLib
import Foundation
import LocusKit
import OSLog

/// The execution mode for a write verb (D-A).
///
/// `regular` is the default: the write returns as soon as the drawer row lands,
/// and semantic encoding happens asynchronously on the Corpus's drain worker.
/// `impatient` trades write latency for immediate searchability: the drawer is
/// ingested into the Corpus inline before the write returns.
public enum WriteMode: String, Sendable, Codable, CaseIterable {
    /// Enqueue the drawer onto the Corpus ingest queue; the drain worker encodes
    /// it asynchronously.
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
    ///   • `.regular` — enqueues the drawer onto the Corpus's own ingest queue
    ///     (P3). The Corpus drain worker (P4) ingests it. The write returns
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
        // One-door classification: every capture path funnels through here.
        // When the incoming frame carries the unclassified sentinel "000" AND
        // the content is non-empty, classify via EideticLib before filing so
        // the drawer is lattice-anchored at the moment of capture — regardless
        // of which caller (file_memory, vault import, branch promotion) reached
        // this seam. When the frame already carries an explicit non-sentinel
        // anchor (e.g. vault frontmatter `udc`), preserve it — do not override.
        //
        // EideticLib.lookup delegates to FDC.encodeAnchor (deterministic,
        // network-free, pinned to bundled LatticeLib artifacts). An empty code
        // from the classifier (UNRESOLVED content) leaves the sentinel intact —
        // the drawer files with "000" rather than failing.
        let classifiedFrame: CaptureFrame = {
            guard frame.latticeAnchor.udcCode == Self.unclassifiedSentinel,
                  !frame.content.isEmpty else {
                return frame
            }
            // recordNovel: false — user-memory content must not leak novel tokens
            // into the plaintext pool pipeline (secfix/fdc-pool). The FDC code and
            // Q-ID are byte-identical to the recording path; only pool accumulation
            // is suppressed. Even a rejected or sensitivity-gated capture (content
            // that fails validation after this point) leaks nothing because
            // classification runs before the write and recording is suppressed here.
            // Rust parity: capture_with_mode calls Fdc::encode_anchor_no_record.
            let anchor = EideticLib.lookup(frame.content, recordNovel: false)
            guard !anchor.code.isEmpty else {
                // UNRESOLVED: content could not be classified. Leave sentinel.
                return frame
            }
            var classified = frame
            classified.latticeAnchor = LatticeAnchor(
                udcCode: anchor.code,
                wikidataQID: anchor.wikidataQID
            )
            return classified
        }()

        // 1. Store the drawer row (identical to the legacy capture verb).
        let drawer = try await capture(handle, classifiedFrame)

        // 2. Encode per mode — only when a Corpus is registered for the estate.
        guard let corpus = corpusKits[handle] else {
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
            // NT-L3: Impatient skips the encode queue, so it also rolls up the
            // drawer's room inline (one capture → one room, O(room) once) rather
            // than via the Corpus drain worker's onEncoded callback.
            let estate = try estate(for: handle)
            try await estate.rollupRoomsForDrawers([drawer.id])
        case .regular:
            // P3: enqueue the drawer onto the Corpus's own ingest queue; the
            // Corpus drain worker (P4) ingests it and fires onEncoded → room
            // rollup. Hint drawers (AI_Charter_Hint room) are normal drawers
            // and flow through the normal encode path. Empty content is
            // skipped inside enqueueIngest.
            try await corpus.enqueueIngest(
                drawer.content,
                sourceID: drawer.id,
                now: drawer.filedAt
            )
        }
        return drawer
    }

    // MARK: - captureBatch — GLK_BATCH1

    /// File a batch of drawers into the estate addressed by `handle` inside a
    /// single SQLite transaction.
    ///
    /// ## Performance contract
    ///
    /// All frames are FDC-classified upfront (one pass). Then a single
    /// `BEGIN IMMEDIATE` is opened on the estate's row store, every drawer row
    /// is inserted without per-row fsync, and the transaction is committed once.
    /// For a ~40 K-drawer palace import this reduces wall-clock time from
    /// ~34 min (per-item autocommit) to ~30 sec.
    ///
    /// ## Encode queue
    ///
    /// `captureBatch` intentionally skips the encode queue. The caller (VaultKit
    /// import) is a bulk-import path; semantic indexing of the imported corpus
    /// is expected to run via a subsequent `moot_reindex` + `moot_dream` cycle.
    ///
    /// ## Atomicity
    ///
    /// If any single insert fails, the transaction is rolled back and no drawers
    /// are persisted. The error is re-thrown to the caller.
    ///
    /// - Parameters:
    ///   - handle: The estate to capture into. Must be open.
    ///   - frames: The capture frames to insert.
    /// - Returns: The stored drawers in insertion order.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` for a stale handle;
    ///   `VerbError.underlyingEstateFailure` on any LocusKit failure;
    ///   `StorageError.transactionConflict` if a transaction is already open.
    @discardableResult
    func captureBatch(
        _ handle: EstateHandle,
        _ frames: [CaptureFrame]
    ) async throws -> [Drawer] {
        // Quiesce gate: reject captureBatch on quiesced or draining estates
        // before touching the transaction. This mirrors the Rust coordinator's
        // estate_for_verb check that precedes begin_transaction (planned
        // security hardening — B1). Without this guard a batch on a quiesced
        // estate would silently proceed to the LocusKit insertFreshBatch
        // transaction, bypassing the estate lifecycle fence.
        try requireMounted(handle, verb: "captureBatch")
        guard !frames.isEmpty else { return [] }

        // Batch capture must preserve the same lattice anchoring guarantee as
        // the normal capture path: classifiable sentinel frames are anchored
        // before storage so latticeSubtree grants never authorize them under
        // the wrong UDC scope. Explicit non-sentinel anchors are preserved.
        // Parallel FDC classify — Pattern B (encode-perf #31, Phase 1).
        //
        // 49k-drawer palace import pegged one core for many minutes because this
        // classify loop was purely serial and string/hashmap bound. Fan it across
        // cap workers: each frame is independent, and
        // EideticLib.lookup(recordNovel:false) is a pure read over the immutable
        // pinned codebook — concurrent calls are safe.
        //
        // CaptureFrame is Sendable. Results yielded as (Int, CaptureFrame) tuples
        // and gathered by index, giving byte-identical output to the serial version.
        //
        // Shape mirrors CorpusKit.boundedConcurrentMap: chunked withTaskGroup,
        // cap = activeProcessorCount, serial fast-path for small batches.
        let cap = ProcessInfo.processInfo.activeProcessorCount

        // Single classify step as a @Sendable closure so it can be used by both
        // the serial fast-path and the concurrent addTask body without logic
        // duplication. Logic is identical to the serial path; only calling
        // structure changes.
        let classifyOneFrame: @Sendable (CaptureFrame) -> CaptureFrame = { frame in
            guard frame.latticeAnchor.udcCode == GeniusLocusKit.unclassifiedSentinel,
                  !frame.content.isEmpty else {
                return frame
            }
            // recordNovel: false — batch import content must not leak novel tokens
            // into the plaintext pool pipeline (secfix/fdc-pool, same rationale as
            // the single-frame capture path above).
            let anchor = EideticLib.lookup(frame.content, recordNovel: false)
            guard !anchor.code.isEmpty else {
                // UNRESOLVED: content could not be classified. Leave sentinel.
                return frame
            }
            var classified = frame
            classified.latticeAnchor = LatticeAnchor(
                udcCode: anchor.code,
                wikidataQID: anchor.wikidataQID
            )
            return classified
        }

        let classifiedFrames: [CaptureFrame]
        if frames.count <= cap {
            // Serial fast-path: avoid TaskGroup overhead for batches no larger
            // than the worker cap.
            classifiedFrames = frames.map { classifyOneFrame($0) }
        } else {
            // Fan-out across cap workers, chunked. Chunk size == cap keeps exactly
            // cap tasks in flight per barrier — identical shape to CorpusKit's
            // boundedConcurrentMap. Results gathered by index so output order is
            // byte-identical to the serial version.
            var results = [CaptureFrame?](repeating: nil, count: frames.count)
            var start = 0
            while start < frames.count {
                let end = min(start + cap, frames.count)
                await withTaskGroup(of: (Int, CaptureFrame).self) { group in
                    for i in start..<end {
                        let frame = frames[i]
                        group.addTask { (i, classifyOneFrame(frame)) }
                    }
                    for await (i, classified) in group {
                        results[i] = classified
                    }
                }
                start = end
            }
            classifiedFrames = results.map { $0! }
        }
        let estateObj = try estate(for: handle)
        return try await estateObj.captureBatch(classifiedFrames)
    }

    // MARK: - awaitEncodeDrain (P5 consumer)

    /// Block until the estate's Corpus ingest queue has fully drained — every
    /// enqueued drawer has been ingested and replied — then return.
    ///
    /// Delegates to `Corpus.awaitIngestDrain()` (the encode pipeline lives in
    /// CorpusKit). Returns promptly when the queue is already empty and does not
    /// hang on an empty queue. This is the signal a bulk caller (importer,
    /// gauntlet) or an acceptance test uses to know that a batch of regular
    /// writes has become semantically searchable.
    ///
    /// Returns immediately if no Corpus is registered for the estate (e.g. a
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
        try await corpusKits[handle]?.awaitIngestDrain(timeout: timeout)
    }

    // MARK: - reindexMissing (backfill for pre-wiring drawers)

    /// Hard cap on the total number of drawers `reindexMissing` will enqueue
    /// in a single call (secfix/c-glk-remaining Part 6).
    ///
    /// Without this cap, a sufficiently large estate (e.g. a 200k-drawer palace
    /// import) causes `reindexMissing` to enqueue all missing drawers atomically,
    /// flooding the encode queue and starving live captures of encode capacity
    /// for minutes. 10,000 drawers ≈ 10 MiB of typical content — enough to make
    /// a meaningful dent in a backfill while keeping the queue drain bounded.
    ///
    /// Rust parity: `REINDEX_MAX_JOBS` in GeniusLocusKit/rust/src/intake.rs.
    ///
    /// Callers that need to reindex more than 10,000 drawers call `reindexMissing`
    /// multiple times; each call skips already-indexed drawers (idempotent), so
    /// repeated calls converge to full coverage without a single unbounded burst.
    ///
    /// `static` because Swift extension properties must be static or computed;
    /// `internal` (not `private`) so the security-hardening tests can assert the
    /// constant's value without a separate public accessor.
    /// Access as `GeniusLocusKit.reindexMaxJobs` or `Self.reindexMaxJobs`.
    static let reindexMaxJobs = 10_000

    /// Enqueue ingest jobs for every active drawer in the estate that is NOT
    /// already present in the Corpus BundleStore, up to `reindexMaxJobs` total.
    ///
    /// Use this after deploying the dual-path intake fix to backfill the existing
    /// drawers that were captured before the encode pipeline was wired. Each
    /// missing drawer is enqueued onto the Corpus ingest queue — the Corpus
    /// drain worker ingests them (BM25 + vector) asynchronously, so this call
    /// returns quickly regardless of estate size.
    ///
    /// **Idempotent:** drawers already in the BundleStore (identified by
    /// `Corpus.indexedSourceIDs()`) are skipped. Calling this multiple times is
    /// safe — already-indexed drawers are never double-enqueued.
    ///
    /// **Cap:** at most `reindexMaxJobs` (10,000) drawers are enqueued per call.
    /// When truncation occurs, a structured warning is logged with the total
    /// missing count so the caller knows to repeat the call. The cap prevents
    /// a single large backfill from starving live captures of encode capacity
    /// (secfix/c-glk-remaining Part 6 — local DoS hardening).
    ///
    /// **No Corpus, no-op:** if no Corpus is registered for the estate (e.g. a
    /// `.locusOnly` estate), the call returns 0 immediately.
    ///
    /// - Parameters:
    ///   - handle: The estate to reindex. Must be open.
    ///   - now: The operation instant used for the deferred Merkle rollup; the
    ///     per-drawer enqueue uses each drawer's `filedAt` as the capture
    ///     timestamp. Pass the current date; the caller never reads the clock
    ///     inside an engine (determinism rule).
    /// - Returns: The number of drawers enqueued for re-encoding (≤ reindexMaxJobs).
    /// - Throws: An estate-not-open error if the handle is stale; a corpus query
    ///   error if the indexed-source-IDs query fails; an estate recall error.
    func reindexMissing(
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
        // enqueue the ingest payload. (.structured returns content = "")
        let estate = try estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        let activeDrawers = allDrawers.filter { $0.tombstonedAt == nil }

        // Collect the active, not-yet-indexed, non-empty drawers.
        // The drawer's filedAt is the capture instant so vector filing timestamps
        // are deterministic (not now). Hint drawers (AI_Charter_Hint room) are
        // normal drawers — they encode like any other.
        var uncappedBatch: [(text: String, sourceID: String, now: Date)] = []
        for drawer in activeDrawers {
            guard !drawer.content.isEmpty else { continue }          // nothing to encode
            guard !indexedIDs.contains(drawer.id) else { continue }  // already indexed (idempotent)
            uncappedBatch.append((text: drawer.content, sourceID: drawer.id, now: drawer.filedAt))
        }

        // Cap the batch to reindexMaxJobs to prevent a single large estate from
        // flooding the encode queue and starving live captures (Part 6 DoS fix).
        // Log a warning when truncation occurs so the caller knows to repeat.
        let totalMissing = uncappedBatch.count
        let batch: [(text: String, sourceID: String, now: Date)]
        if totalMissing > Self.reindexMaxJobs {
            batch = Array(uncappedBatch.prefix(Self.reindexMaxJobs))
            Self.intakeLog.warning(
                "reindexMissing: truncated to reindexMaxJobs=\(Self.reindexMaxJobs, privacy: .public); \(totalMissing, privacy: .public) unindexed drawers remain — call again to continue backfill for estate \(handle.estateUUID, privacy: .public)")
        } else {
            batch = uncappedBatch
        }

        // Batch-enqueue in chunks so the filesystem backend fsyncs new/ ONCE per
        // chunk instead of per job (the per-job fsync was the last full-core
        // bottleneck of a bulk import), while the chunk bounds the single fsync
        // window against concurrent live captures.
        // NOTE: enqueueChunk (1024) is the per-batch fsync unit, NOT the total
        // ceiling — that ceiling is reindexMaxJobs applied above.
        let enqueueChunk = 1024
        var enqueued = 0
        var offset = 0
        while offset < batch.count {
            let end = min(offset + enqueueChunk, batch.count)
            try await corpus.enqueueIngestBatch(Array(batch[offset..<end]))
            enqueued += end - offset
            offset = end
        }
        Self.intakeLog.info(
            "reindexMissing: enqueued \(enqueued, privacy: .public) drawers for estate \(handle.estateUUID, privacy: .public) (\(activeDrawers.count, privacy: .public) active, \(indexedIDs.count, privacy: .public) already indexed)")

        // NT_R1: deferred Merkle rollup. Batch-capture paths (e.g. moot_palace_import)
        // skip per-drawer rollupMerkleRoots to avoid O(N²) work. The full-tree pass
        // here is O(N) and runs once regardless of whether this reindex triggered any
        // new encode jobs — it is safe to call on an already-current tree (idempotent).
        try await estate.rollupAllMerkleRoots(now: now)

        return enqueued
    }

    // MARK: - Internals

    /// Wire the estate's Corpus `onEncoded` callback to roll up the touched
    /// LocusKit rooms for each drained batch.
    ///
    /// CorpusKit owns the encode pipeline and fires this callback with the
    /// encoded drawer ids after its drain worker ingests a batch. GLK's only
    /// role is to coordinate the LocusKit-side deferred room rollup — off the
    /// encode path, coalesced per batch. GLK never performs the encode itself.
    /// Best-effort: a rollup failure is non-fatal — the drawer rows are durable
    /// and the next reindex full-tree pass reconciles the Merkle tree.
    ///
    /// Called from `wireSubstores` at provision (for `.glk`/`.corpusOnly`
    /// estates). The closure captures the GLK actor weakly so a torn-down estate
    /// leaves no retain cycle through the Corpus.
    internal func wireCorpusRoomRollup(_ corpus: Corpus, for handle: EstateHandle) async {
        await corpus.setOnEncoded { [weak self] drawerIDs in
            guard let self else { return }
            guard let estate = try? await self.estate(for: handle) else { return }
            try? await estate.rollupRoomsForDrawers(drawerIDs)
        }
    }

    /// Ingest a single drawer into the estate's Corpus (the P6 inline path),
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

    /// The canonical unclassified-content sentinel UDC code. A drawer that
    /// carries this code arrived at the capture seam without a real
    /// classification. The seam attempts FDC classification on the content
    /// and replaces this sentinel with the resolved code; when the content is
    /// unresolvable the sentinel remains so the drawer still files cleanly.
    ///
    /// "000" is the three-digit root per the FDC code grammar (see LatticeLib
    /// Code.swift): all subject-matter spine codes descend from it. Using the
    /// root (not a child like "000.000") as the sentinel is correct because
    /// a classified drawer never resolves to the bare root — every resolved
    /// code is a spine code or a decimal extension thereof, always more
    /// specific than "000". This gives callers a reliable way to detect
    /// unclassified content without a separate boolean flag.
    ///
    /// Rust parity: `UNCLASSIFIED_SENTINEL` in `intake.rs`.
    static let unclassifiedSentinel: String = "000"
}
