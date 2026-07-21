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
            let contentKind: EideticContentKind = frame.kind == .code ? .code : .text
            let anchor = EideticLib.lookup(
                frame.content, contentKind: contentKind, recordNovel: false)
            guard !anchor.code.isEmpty else {
                // UNRESOLVED: content could not be classified. Leave sentinel.
                return frame
            }
            var classified = frame
            classified.latticeAnchor = LatticeAnchor(
                udcCode: anchor.code,
                udcFacets: frame.latticeAnchor.udcFacets,
                wikidataQID: anchor.wikidataQID,
                wikidataQidsSecondary: frame.latticeAnchor.wikidataQidsSecondary
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
            // Shared-content 1.1: enqueue a Drawer CHANGE REFERENCE — id,
            // revision, digest — never the text. The engine's drain worker
            // resolves the CURRENT content by ID through the LocusKit-backed
            // adapter at work time, then fires onEncoded → room rollup. Hint
            // drawers (AI_Charter_Hint room) are normal drawers and flow
            // through the same path.
            guard !drawer.content.isEmpty else { return drawer }
            try await corpus.enqueueChange(
                .upsert(
                    id: drawer.id,
                    revision: 1,
                    digest: CorpusContentDigest.digest(drawer.content)),
                cursor: nil,
                capturedAt: drawer.filedAt
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
            let contentKind: EideticContentKind = frame.kind == .code ? .code : .text
            let anchor = EideticLib.lookup(
                frame.content, contentKind: contentKind, recordNovel: false)
            guard !anchor.code.isEmpty else {
                // UNRESOLVED: content could not be classified. Leave sentinel.
                return frame
            }
            var classified = frame
            classified.latticeAnchor = LatticeAnchor(
                udcCode: anchor.code,
                udcFacets: frame.latticeAnchor.udcFacets,
                wikidataQID: anchor.wikidataQID,
                wikidataQidsSecondary: frame.latticeAnchor.wikidataQidsSecondary
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
    ///   - timeout: Upper bound on the wait WITHOUT observed progress — the
    ///     underlying QueueKit barrier resets the deadline each time the encode
    ///     stream's outstanding count decreases, so a slow-but-progressing
    ///     drain (CPU-starved by a fully parallel test suite) never
    ///     false-times-out while a genuine hang still fails fast. Defaults
    ///     to 30 s.
    /// - Throws: `QueueError.drainTimeout` if the queue makes no progress in
    ///   time.
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
    /// `reindexMissing` loops internally (enqueue a pass → drain it to idle →
    /// re-collect) to reach FULL coverage in a single call at any corpus size —
    /// this cap only bounds each pass, not the total. 10,000 keeps each pass's
    /// drain bounded (no memory blow-up from an unpublished vector window);
    /// enqueuing the whole corpus at once instead stalled the encode.
    ///
    /// `static` because Swift extension properties must be static or computed;
    /// `internal` (not `private`) so the security-hardening tests can assert the
    /// constant's value without a separate public accessor.
    /// Access as `GeniusLocusKit.reindexMaxJobs` or `Self.reindexMaxJobs`.
    static let reindexMaxJobs = 10_000

    /// A `reindexMissing` sweep whose missing set is under this percentage of
    /// the already-indexed sources is a SMALL DELTA: its drawers ride the
    /// encode stream (embedded through the live basis at drain, like any live
    /// capture) and the O(corpus) full-retrain tail is skipped. 5% of a 50k
    /// estate is 2,500 drawers — comfortably inside what the encode drain
    /// handles in near-realtime, while the skipped tail costs tens of minutes
    /// of full-corpus FDC re-encode. Basis freshness for the delta's new
    /// vocabulary arrives with the next large import, explicit `moot_reindex`,
    /// or scheduled maintenance. An empty corpus is never a small delta (cold
    /// initial loads always take the full train-once+embed-once path).
    /// Rust parity: `DELTA_REINDEX_THRESHOLD_PERCENT` in
    /// GeniusLocusKit/rust/src/intake.rs.
    static let deltaReindexThresholdPercent = 5

    /// Page size for `reindexMissing`'s upfront sweep of the drawers table
    /// via `Estate.activeDrawersAfter(id:limit:)`. Bounds how many full
    /// (content-hydrated) `Drawer` rows any single storage-tier query call
    /// materializes; the sweep walks the whole table in pages of this size
    /// rather than one unbounded `allDrawers()` call (MEDIUM perf fix —
    /// see `reindexMissing` below). Independent of `reindexMaxJobs`, which
    /// bounds how many jobs are ENQUEUED per pass, not how many rows are
    /// SCANNED per storage query.
    static let reindexScanPageSize = 2_000

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
    /// **Bounded per pass, auto-continued:** at most `reindexMaxJobs` (10,000)
    /// drawers are enqueued per pass; the internal loop drains each pass to idle
    /// and re-collects until every drawer is indexed, so ONE call reaches full
    /// coverage regardless of estate size. The per-pass cap prevents a single
    /// pass from starving live captures of encode capacity (secfix/c-glk-remaining
    /// Part 6 — local DoS hardening).
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
        let estate = try estate(for: handle)

        // Fetch the set of source IDs already indexed in the BundleStore — the
        // drawer IDs that already have chunks and can be skipped. A single
        // snapshot, not re-fetched per pass: the missing set below is
        // determined once, up front, and the per-pass loop only enqueues
        // slices of that already-known list — see the sweep comment below
        // for why a mid-sweep re-fetch is unnecessary.
        let indexedIDs = try await corpus.indexedSourceIDs()

        // MEDIUM perf fix (NT-reindex-sweep): walk the drawers table ONCE,
        // in bounded pages via `Estate.activeDrawersAfter(id:limit:)`,
        // instead of the previous design's `estate.allDrawers()` — an
        // unbounded, full-table, full-hydration load — called on EVERY one
        // of up to 1000 passes below. `reindexMissing` backfills drawers
        // captured before the encode pipeline was wired; that population
        // does not grow while this function runs (a normal live capture is
        // indexed via its OWN capture-time enqueue, not this backfill), so
        // one upfront sweep against the `indexedIDs` snapshot above is
        // sufficient — only the ENQUEUE below needs to repeat in bounded
        // passes. `id > cursor` is a portable, indexed cursor (the drawers
        // table's declared TEXT primary key, present on every backend), so
        // no single query call ever materializes more than
        // `reindexScanPageSize` full `Drawer` rows.
        // Shared-content 1.1: collect CHANGE REFERENCES (id/revision/digest),
        // never text — the drain resolves the current content at work time.
        var uncappedBatch: [(change: CorpusContentChange, cursor: String?, capturedAt: Date)] = []
        var scannedCount = 0
        var cursor: String?
        while true {
            let page = try await estate.activeDrawersAfter(id: cursor, limit: Self.reindexScanPageSize)
            if page.isEmpty { break }
            cursor = page.last?.id
            scannedCount += page.count
            for drawer in page {
                guard !drawer.content.isEmpty else { continue }          // nothing to encode
                guard !indexedIDs.contains(drawer.id) else { continue }  // already indexed (idempotent)
                uncappedBatch.append((
                    change: .upsert(
                        id: drawer.id,
                        revision: 1,
                        digest: CorpusContentDigest.digest(drawer.content)),
                    cursor: nil,
                    capturedAt: drawer.filedAt))
            }
            if page.count < Self.reindexScanPageSize { break }  // partial page: table exhausted
        }

        if uncappedBatch.isEmpty {
            Self.intakeLog.info(
                "reindexMissing: nothing to index for estate \(handle.estateUUID, privacy: .public) — reindex tail skipped")
            return 0
        }

        // The sweep above saw the WHOLE missing set — classify the import
        // size once, up front (previously decided on the loop's first pass,
        // whose `allDrawers()` collect also happened to see everything).
        // Small = the missing set is under deltaReindexThresholdPercent of
        // the sources already indexed. An EMPTY corpus is never small (a
        // cold initial load must take the full train-once+embed-once path).
        let smallDelta = !indexedIDs.isEmpty
            && uncappedBatch.count * 100
                < indexedIDs.count * Self.deltaReindexThresholdPercent

        // Auto-continuation loop: each pass enqueues at most reindexMaxJobs
        // drawers from the pre-computed missing list, then POLLS their drain
        // to idle before advancing to the next slice — repeating until the
        // list is exhausted. A large import reaches FULL coverage with no
        // operator follow-up, at any corpus size, while each pass stays
        // bounded. The actor interleaves awaits, so the daemon stays
        // responsive during the (possibly long) drain. The 1000-pass
        // ceiling is a backstop consistent with the previous design (covers
        // 10M drawers at the 10k cap).
        var total = 0
        var missingOffset = 0
        for _ in 0..<1000 {
            guard missingOffset < uncappedBatch.count else { break }  // every missing drawer enqueued — done

            // Cap this pass to reindexMaxJobs so a single pass cannot flood the
            // encode queue and starve live captures (Part 6 DoS bound).
            let passEnd = min(missingOffset + Self.reindexMaxJobs, uncappedBatch.count)
            let batch = Array(uncappedBatch[missingOffset..<passEnd])
            missingOffset = passEnd

            // Batch-enqueue in chunks so the backend commits new/ ONCE per chunk
            // instead of per job.
            //
            // Stream choice is the delta decision made above:
            //   • LARGE import → IMPORT stream: the discrete import drain worker
            //     ingests chunk + BM25 only — no bootstrap train, no embed. The
            //     encode drain's embed-now work would be pure repeated waste for
            //     a bulk import whose basis is retrained on the WHOLE corpus and
            //     whose chunks are embedded ONCE at the tail below.
            //   • SMALL delta → ENCODE stream: the encode drain embeds each
            //     chunk through the LIVE basis as it ingests (identical to a
            //     live capture), so no tail retrain/re-embed is needed at all.
            // Same durable queue.sqlite either way, so a crash mid-import
            // cold-starts: the drain worker reclaims orphaned rows and resumes.
            let enqueueChunk = 1024
            var offset = 0
            while offset < batch.count {
                let end = min(offset + enqueueChunk, batch.count)
                // One encode stream for both cases: jobs are references, so
                // the legacy copied-text import stream no longer exists. The
                // small-delta decision below only controls whether the
                // full-corpus retrain tail runs.
                try await corpus.enqueueChangeBatch(Array(batch[offset..<end]))
                offset = end
            }
            total += batch.count
            Self.intakeLog.info(
                "reindexMissing: enqueued \(batch.count, privacy: .public) drawers on the \(smallDelta ? "encode" : "import", privacy: .public) stream for estate \(handle.estateUUID, privacy: .public) (\(scannedCount, privacy: .public) scanned, \(indexedIDs.count, privacy: .public) already indexed at sweep time)")

            // Wait for THIS pass to reach TRUE idle before advancing to the next
            // slice, so an in-flight batch is never starved of drain capacity by
            // the next pass's enqueue.
            //
            // POLL, do not pump — the single lease-holding drain worker
            // (runImportDrainLoop / runIngestDrainLoop) owns the drain; this loop
            // only observes the read-only depth probe FOR THE STREAM the batch
            // was enqueued on.
            while true {
                let depth = (try? await corpus.ingestQueueDepth()) ?? (pending: 0, inFlight: 0)
                if depth.pending == 0 && depth.inFlight == 0 { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        // total == 0 is unreachable here: the empty-sweep case (nothing was
        // missing — no new chunks would enter the corpus, so the basis,
        // every embedding, and the Merkle tree are exactly as current as
        // before this call, and the O(corpus) tail below would be pure
        // waste, observed: an UNCHANGED vault reimport into a 50k estate
        // burned ~70 min of full retrain + re-embed for a no-op) already
        // returned early, right after the sweep, before `smallDelta` was
        // even classified. A previously interrupted import (chunks present
        // but basis stale) is repaired by the explicit `moot_reindex` tool,
        // which exists for exactly that.
        if smallDelta {
            // Small delta: every enqueued chunk was already embedded through the
            // LIVE basis by the encode drain. Await the barrier once — it
            // publishes the resident vector index, the searchability contract —
            // and skip the full retrain. New vocabulary enters the basis at the
            // next large import, explicit `moot_reindex`, or maintenance.
            try await corpus.awaitIngestDrain(timeout: .seconds(30))
            Self.intakeLog.info(
                "reindexMissing: small delta (\(total, privacy: .public) drawers) embedded via the live basis for estate \(handle.estateUUID, privacy: .public) — full retrain skipped (moot_reindex retrains on demand)")
        } else {
            // Full-corpus embedding-basis retrain, so the DENSE (semantic /
            // vector / RAG) recall lane is query-ready the moment the import
            // cycle completes.
            //
            // The loop above reaches full CHUNK coverage: every drawer is
            // chunked and BM25 (lexical) indexed — but import-stream ingest
            // deliberately does NOT embed. A query term that appears only in an
            // unembedded chunk reads dense_lane:dark:vocabMiss until the basis
            // is trained on the WHOLE corpus and every chunk embedded into that
            // space. Corpus.reindex does exactly that (train the basis over all
            // active chunks, then re-embed → one index rebuild). Lexical (BM25)
            // and structured (Locus) recall are already live from chunk
            // coverage; THIS is the step that lights up semantic recall, so it
            // belongs at the tail of the import cycle, not on a later cadence.
            try await corpus.reindex(now: now)
        }

        // NT_R1: deferred Merkle full-tree rollup, once, after full coverage. The
        // O(N) full-tree pass is safe on an already-current tree (idempotent).
        try await estate.rollupAllMerkleRoots(now: now)

        return total
    }

    // MARK: - Internals

    /// Wire the engine's `onEncoded` callback to roll up the touched
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
    internal func wireCorpusRoomRollup(_ corpus: CorpusContentEngine, for handle: EstateHandle) async {
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
        // The drawer row is already durably stored; the engine resolves it
        // through the LocusKit-backed adapter and indexes it under its own
        // Drawer ID (identity is direct — no chunk lane).
        try await corpus.indexContent(id: drawer.id, now: drawer.filedAt)
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
