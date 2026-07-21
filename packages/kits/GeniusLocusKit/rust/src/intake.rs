// intake.rs — Dual-Path Intake (G7) Rust twin of the Swift EncodeIntake.swift
// capture→encode ORCHESTRATION.
//
// THE LOAD-BEARING CHANGE: before this wiring, a capture produced a LocusKit
// drawer row ONLY — never chunked, never BM25-indexed, never embedded — so the
// semantic (BM25 + vector) recall lanes were DARK for normally-captured
// content. This module connects capture to the estate's Corpus, which lights
// those lanes, via two paths:
//
//   • REGULAR (P3 + P4): capture returns immediately; the drawer is enqueued
//     onto the Corpus's OWN ingest queue (`Corpus::enqueue_ingest`); the
//     Corpus's drain worker pool ingests it. After the queue drains, the drawer
//     is BM25/vector searchable.
//
//   • IMPATIENT (P6): capture ingests the drawer into the Corpus INLINE before
//     returning, skipping the queue — searchable the instant the write returns.
//
// LAYERING: the encode QUEUE + DRAIN + WORKER POOL + retry + job payload live in
// CorpusKit (a Corpus queues, drains, and encodes itself — see corpus-kit's
// corpus_ingest_queue.rs). GeniusLocusKit is ONLY the orchestrator: it enqueues
// work into the Corpus, and — through the Corpus's `on_encoded` callback wired
// at provision — rolls up the touched LocusKit rooms for the encoded drawers.
// GLK never performs the encode itself.
//
// D-A: the write mode is an EXECUTION OPTION on the write verb (a parameter on
//      `capture_with_mode`), not a field on CaptureFrame.
// G4:  the drawer is ingested with `source_id = drawer.id` so BM25/vector hits
//      hydrate back to the real Drawer row.

use std::sync::Arc;

use corpus_kit::content::{
    CorpusContentChangeBatch, CorpusContentId, CorpusContentRecord, CorpusContentSource,
};
use corpus_kit::{content_digest, ContentIndexJob, ContentIndexJobKind, CorpusContentEngine};
use corpus_kit::error::CorpusKitError;
use locus_kit::estate::Estate;

/// The GLK-owned LocusKit-backed content source (shared-content 1.1, P3).
/// Rust twin of Swift `LocusDrawerCorpusContentSource`.
///
/// COMPOSITION RULE: `CorpusContentSource` is declared by corpus-kit; GLK
/// owns this adapter; locus-kit never depends on corpus-kit. A Drawer's
/// content is immutable per ID (revisions are new drawers via lineage), so
/// every live drawer reports revision 1 with digest = sha256(content).
/// The estate verbs ARE the change stream — the polling feed is empty.
pub struct LocusDrawerContentSource {
    estate: Estate,
}

impl LocusDrawerContentSource {
    pub fn new(estate: Estate) -> Self {
        LocusDrawerContentSource { estate }
    }
}

impl CorpusContentSource for LocusDrawerContentSource {
    fn record(&self, id: &str) -> Result<Option<CorpusContentRecord>, CorpusKitError> {
        let Some(drawer) = self
            .estate
            .drawer_by_id(id)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?
        else {
            return Ok(None);
        };
        if drawer.content.is_empty() {
            return Ok(None);
        }
        Ok(Some(CorpusContentRecord {
            id: drawer.id.clone(),
            revision: 1,
            digest: content_digest(&drawer.content),
            text: drawer.content,
        }))
    }

    fn changes(
        &self,
        _cursor: Option<&str>,
        _limit: usize,
    ) -> Result<CorpusContentChangeBatch, CorpusKitError> {
        Ok(CorpusContentChangeBatch::empty())
    }

    fn active_content_ids(&self) -> Result<Vec<CorpusContentId>, CorpusKitError> {
        let mut ids: Vec<String> = Vec::new();
        let mut cursor: Option<String> = None;
        let page_size = 2_000usize;
        loop {
            let page = self
                .estate
                .active_drawers_after(cursor.as_deref(), page_size)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("{e:?}")))?;
            if page.is_empty() {
                break;
            }
            cursor = page.last().map(|d| d.id.clone());
            for drawer in &page {
                if !drawer.content.is_empty() {
                    ids.push(drawer.id.clone());
                }
            }
            if page.len() < page_size {
                break;
            }
        }
        ids.sort();
        Ok(ids)
    }
}
use locus_kit::drawer::Drawer;

use crate::coordinator::{EstateCoordinator, VerbDispatchError};
use crate::handle::EstateHandle;

/// The execution mode for a write verb (D-A). Swift parity: `WriteMode`.
///
/// `Regular` is the default: the write returns as soon as the drawer row lands,
/// and semantic encoding happens asynchronously on the Corpus's drain worker.
/// `Impatient` trades write latency for immediate searchability: the drawer is
/// ingested into the Corpus inline before the write returns.
///
/// The raw-value strings (`"regular"` / `"impatient"`) match the Swift
/// `WriteMode: String` raw values exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteMode {
    /// Enqueue the drawer onto the Corpus ingest queue; the drain worker encodes
    /// it asynchronously.
    Regular,
    /// Encode inline before the write returns; immediately searchable.
    Impatient,
}

impl WriteMode {
    /// The raw-value string, byte-identical to the Swift `WriteMode` raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            WriteMode::Regular => "regular",
            WriteMode::Impatient => "impatient",
        }
    }
}

/// Wrap an intake failure reason in the verb-dispatch error domain. The intake
/// composition is a write-verb surface, so failures surface as
/// `VerbError::UnderlyingEstateFailure` under the `capture` verb — parity of the
/// Swift `VerbError.underlyingEstateFailure` the mode-aware capture throws.
fn verb_fail(reason: String) -> VerbDispatchError {
    VerbDispatchError::Verb(crate::verbs::lexicon::VerbError::UnderlyingEstateFailure {
        verb: "capture".to_string(),
        reason,
    })
}

impl EstateCoordinator {
    // MARK: - capture (mode-aware) — D-A

    /// File a new drawer into the estate addressed by `handle`, then encode it
    /// into the estate's Corpus per `mode` (Dual-Path Intake). Swift parity:
    /// `GeniusLocusKit.capture(_:_:mode:)`.
    ///
    ///   • `Regular` — enqueues the drawer onto the Corpus's own ingest queue
    ///     (P3). The Corpus drain worker (P4) ingests it and fires `on_encoded`
    ///     → room rollup. The write returns before encoding completes.
    ///   • `Impatient` — ingests the drawer into the Corpus inline (P6) before
    ///     returning, so the drawer is BM25/vector searchable immediately.
    ///
    /// Encoding is a no-op (both modes just store the drawer row) when no Corpus
    /// is registered for the estate (e.g. a LocusOnly estate). The row-only
    /// `capture(_:_:_)` is unchanged; this is purely additive.
    ///
    /// `now` is the capture instant in **epoch SECONDS** (NOT milliseconds),
    /// explicit per the Rust determinism convention. It is stored directly as the
    /// drawer's epoch-seconds `filed_at`/`event_time`; the ingest reuses it so
    /// vector filing timestamps reproduce capture time (no clock read inside the
    /// engine). Callers must pass seconds (e.g. `wall_now()`, not `wall_now_ms()`).
    pub fn capture_with_mode(
        &mut self,
        handle: &EstateHandle,
        frame: locus_kit::frames::CaptureFrame,
        now: i64,
        mode: WriteMode,
    ) -> Result<Drawer, VerbDispatchError> {
        // One-door classification: every capture path funnels through here.
        // When the incoming frame carries the unclassified sentinel "000" AND
        // the content is non-empty, classify via Fdc::encode_anchor before
        // filing so the drawer is lattice-anchored at the moment of capture —
        // regardless of which caller (file_memory, vault import, branch
        // promotion) reached this seam. When the frame already carries an
        // explicit non-sentinel anchor (e.g. vault frontmatter `udc`),
        // preserve it — the seam does not override explicit anchors.
        //
        // Fdc::encode_anchor is pure and deterministic over the pinned
        // LatticeLib artifacts. An empty return (UNRESOLVED content) leaves
        // the sentinel intact — the drawer files at "000" rather than failing.
        // Swift parity: GeniusLocusKit.capture(_:_:mode:) unclassified-sentinel
        // guard + EideticLib.lookup block.
        let classified_frame = if frame.lattice_anchor.udc_code == UNCLASSIFIED_SENTINEL
            && !frame.content.is_empty()
        {
            // secfix/fdc-pool: use the non-recording variant so novel tokens from
            // user-supplied memory content are NOT accumulated into the process-wide
            // SHARED_NOVEL_CACHE and do NOT flush to plaintext pool files under
            // LATTICE_POOL_DIR. The anchor result (code, qid) is byte-identical to
            // encode_anchor. Parity: Swift capture(_:_:mode:) calls
            // EideticLib.lookup(_:recordNovel:false). Even rejected captures (empty room,
            // unresolved content) spill nothing because classification runs here, before
            // the capture write, and accumulation is suppressed.
            let content_kind = if frame.kind == locus_kit::drawer_operational::ContentKind::Code {
                lattice_lib::FdcContentKind::Code
            } else {
                lattice_lib::FdcContentKind::Text
            };
            let (code_opt, qid_opt) =
                lattice_lib::Fdc::encode_anchor_for_content_no_record(&frame.content, content_kind);
            match code_opt {
                Some(code) if !code.is_empty() => {
                    let mut f = frame;
                    f.lattice_anchor = locus_kit::estate_types::LatticeAnchor {
                        udc_code: code,
                        udc_facets: f.lattice_anchor.udc_facets.clone(),
                        wikidata_qid: qid_opt,
                        wikidata_qids_secondary: f.lattice_anchor.wikidata_qids_secondary.clone(),
                    };
                    f
                }
                _ => frame, // UNRESOLVED: keep sentinel, still files cleanly
            }
        } else {
            frame // Explicit non-sentinel anchor: preserve as-is
        };

        // 1. Store the drawer row (identical to the row-only capture verb).
        let drawer = self.capture(handle, classified_frame, now)?;

        // 2. Encode per mode — only when a Corpus is registered for the estate.
        if !self.has_corpus(handle) {
            // No semantic lane to feed (e.g. LocusOnly). Both modes degrade to
            // row-only — the drawer row is stored; nothing to ingest.
            return Ok(drawer);
        }

        match mode {
            WriteMode::Impatient => {
                // P6: ingest inline before returning. source_id = drawer.id
                // (G4); now = drawer.filed_at (capture instant) so vector filing
                // timestamps reproduce capture time. The drawer row is already
                // durably stored, so an ingest failure surfaces to the caller
                // without losing content.
                self.ingest_drawer_into_corpus(handle, &drawer)?;
                // NT-L3: Impatient skips the encode queue, so it also rolls up
                // the drawer's room inline (one capture → one room, O(room) once)
                // rather than via the Corpus drain worker's on_encoded callback.
                if let Ok(estate) = self.estate_for(handle) {
                    let _ = estate.rollup_rooms_for_drawers(&[drawer.id.clone()]);
                }
            }
            WriteMode::Regular => {
                // P3: enqueue the drawer onto the Corpus's own ingest queue; the
                // Corpus drain worker (P4) ingests it and fires on_encoded → room
                // rollup. Empty content is skipped inside enqueue_ingest.
                // Hint drawers (AI_Charter_Hint room) are normal drawers and flow
                // through the normal encode path. Swift parity: capture(_:_:mode:) .regular.
                if !drawer.content.is_empty() {
                    if let Some(corpus) = self.corpus_for(handle) {
                        // Shared-content 1.1: enqueue a Drawer CHANGE REFERENCE
                        // — id/revision/digest — never the text. The drain
                        // worker resolves the CURRENT content by ID through
                        // the LocusKit-backed adapter at work time.
                        let job = ContentIndexJob {
                            kind: ContentIndexJobKind::Upsert,
                            content_id: drawer.id.clone(),
                            revision: 1,
                            digest: Some(content_digest(&drawer.content)),
                            cursor: None,
                        };
                        corpus
                            .enqueue_change(&job, drawer.filed_at)
                            .map_err(|e| verb_fail(format!("corpus enqueue_change failed: {e:?}")))?;
                    }
                }
            }
        }
        Ok(drawer)
    }

    // MARK: - awaitEncodeDrain (P5 consumer)

    /// Block until the estate's Corpus ingest queue has fully drained — every
    /// enqueued drawer ingested and replied — then return. Delegates to
    /// `Corpus::await_ingest_drain` (the encode pipeline lives in CorpusKit).
    /// Returns immediately if no Corpus is registered (e.g. a LocusOnly estate).
    /// Swift parity: `GeniusLocusKit.awaitEncodeDrain(for:)`.
    pub fn await_encode_drain(&mut self, handle: &EstateHandle) -> Result<(), VerbDispatchError> {
        match self.corpus_for(handle) {
            Some(corpus) => corpus
                .await_ingest_drain()
                .map_err(|e| verb_fail(format!("await_ingest_drain failed: {e:?}"))),
            None => Ok(()),
        }
    }

    // MARK: - reindexMissing

    /// Per-pass cap on the number of drawers `collect_reindex_jobs` collects in
    /// a single call (secfix/c-glk-remaining Part 6).
    ///
    /// This bounds one enqueue pass so a large estate cannot flood the encode
    /// queue and starve live captures in a single burst. The reindex INVOKER
    /// (`run_reindex_responsive`) loops — enqueue a pass, drain it to idle,
    /// re-collect — so full coverage is reached automatically at ANY corpus size
    /// without an operator repeating the call; the cap only bounds each pass.
    /// 10,000 keeps each pass's drain bounded (empirically ~90s and no memory
    /// blow-up from an unpublished vector window) — enqueuing the whole corpus at
    /// once instead stalled the encode; bounded passes drain cleanly.
    ///
    /// Swift parity: `reindexMaxJobs` in GeniusLocusKit/Sources/.../EncodeIntake.swift.
    #[cfg(not(feature = "test-seams"))]
    const REINDEX_MAX_JOBS: usize = 10_000;

    /// Test-seam visibility twin of `REINDEX_MAX_JOBS`: `pub` so the parity
    /// integration test (a separate crate) can assert the 10k cap. Private in
    /// normal builds — mirrors Swift's internal `reindexMaxJobs` reached through
    /// `@testable import`.
    #[cfg(feature = "test-seams")]
    pub const REINDEX_MAX_JOBS: usize = 10_000;

    /// Public accessor for `REINDEX_MAX_JOBS`, callable regardless of the
    /// `test-seams` feature flag. `run_reindex_responsive` (AriaMcpKit, a
    /// separate crate) uses this to slice `sweep_reindex_missing`'s
    /// uncapped missing-job list into bounded per-pass enqueue batches,
    /// now that the pass loop no longer relies on `collect_reindex_jobs`'s
    /// own internal truncation for its per-pass cap.
    pub fn reindex_max_jobs_cap() -> usize {
        Self::REINDEX_MAX_JOBS
    }

    /// A reindex sweep whose missing set is under this percentage of the
    /// already-indexed sources is a SMALL DELTA: its drawers ride the encode
    /// stream (embedded through the live basis at drain, like any live
    /// capture) and the O(corpus) full-retrain tail is skipped. 5% of a 50k
    /// estate is 2,500 drawers — comfortably inside what the encode drain
    /// handles in near-realtime, while the skipped tail costs tens of minutes
    /// of full-corpus FDC re-encode. Basis freshness for the delta's new
    /// vocabulary arrives with the next large import, explicit `moot_reindex`,
    /// or scheduled maintenance. An empty corpus is never a small delta (cold
    /// initial loads always take the full train-once+embed-once path).
    /// Swift parity: `deltaReindexThresholdPercent` in
    /// GeniusLocusKit/Sources/.../EncodeIntake.swift.
    pub const DELTA_REINDEX_THRESHOLD_PERCENT: usize = 5;

    /// Classify a reindex sweep as a SMALL DELTA (see
    /// `DELTA_REINDEX_THRESHOLD_PERCENT` for the policy and rationale).
    ///
    /// `missing_capped` is the FIRST pass's job count as returned by
    /// `collect_reindex_jobs`, which is already capped at `REINDEX_MAX_JOBS`:
    /// a full-cap pass means "at least 10k missing" and is never small, so the
    /// capped count classifies identically to Swift's uncapped count at every
    /// corpus size (wherever 5% of the corpus exceeds the cap, the capped
    /// count trips the `< REINDEX_MAX_JOBS` guard first).
    pub fn is_small_reindex_delta(missing_capped: usize, indexed: usize) -> bool {
        indexed > 0
            && missing_capped < Self::REINDEX_MAX_JOBS
            && missing_capped * 100 < indexed * Self::DELTA_REINDEX_THRESHOLD_PERCENT
    }

    /// Enqueue ingest jobs for every active drawer that is not yet present in
    /// the estate's Corpus (BM25/vector index). Returns the count enqueued.
    /// Idempotent: drawers already indexed are skipped. Empty-content,
    /// "none"-sentinel (charter), and tombstoned drawers are skipped.
    ///
    /// Used to backfill estates populated before the dual-path intake bug fix:
    /// content captured via the row-only path never reached the Corpus, so
    /// BM25/vector recall returned zero hits for it. Swift parity:
    /// `GeniusLocusKit.reindexMissing`.
    ///
    /// `now` is the enqueue instant in milliseconds since epoch — used for the
    /// deferred Merkle rollup (NT_R1); the per-drawer enqueue reuses each
    /// drawer's `filed_at` as the capture instant.
    ///
    /// **Cap:** at most `REINDEX_MAX_JOBS` (10,000) jobs are collected per call.
    /// When truncation occurs, a warning is logged with the total missing count.
    /// Callers that need to reindex more repeat the call; idempotency ensures
    /// convergence without an unbounded burst (Part 6 DoS hardening).
    ///
    /// Returns 0 immediately when no Corpus is registered for the estate (e.g. a
    /// LocusOnly estate).
    /// Snapshot the encode work a reindex must enqueue, so the caller can enqueue
    /// it WITHOUT holding the coordinator lock across the (potentially huge)
    /// loop. Returns the Corpus handle plus the `(content, source_id,
    /// filed_at_millis)` tuples for every active, not-yet-indexed drawer; `None`
    /// when no Corpus is registered. The caller enqueues these on the Corpus's
    /// own queue AFTER releasing the coord lock (see `run_reindex_responsive`),
    /// so HTTP handlers — which all lock the coordinator — stay responsive during
    /// a large reindex (e.g. a 49k-drawer palace import). Swift achieves the same
    /// responsiveness via actor-await interleaving inside `reindexMissing`; the
    /// Rust Mutex coordinator needs this explicit collect/enqueue/rollup split.
    pub fn collect_reindex_jobs(
        &mut self,
        handle: &EstateHandle,
    ) -> Result<Option<(Arc<CorpusContentEngine>, Vec<(String, String, i64)>)>, VerbDispatchError> {
        // Guard: only estates with a registered Corpus have a BM25/vector lane.
        let corpus = match self.corpus_for(handle) {
            Some(c) => c,
            None => return Ok(None),
        };

        // Snapshot which drawer IDs are already indexed so we enqueue only the
        // missing subset. indexed_source_ids() is a full-table scan on the chunks
        // table — acceptable for a maintenance/admin path, not a hot path.
        let indexed_ids = corpus
            .indexed_source_ids()
            .map_err(|e| verb_fail(format!("collect_reindex_jobs: indexed_source_ids failed: {e:?}")))?;

        // Read all drawers (including tombstoned) so we can filter active ones.
        let all_drawers = self.all_drawers(handle)?;

        let mut jobs: Vec<(String, String, i64)> = Vec::new();
        for drawer in all_drawers {
            // Skip tombstoned (intentionally removed) and empty-content drawers.
            if drawer.tombstoned_at.is_some() || drawer.content.is_empty() {
                continue;
            }
            // Hint drawers (AI_Charter_Hint room) are normal drawers — they
            // encode like any other content. Skip drawers already in the Corpus
            // (idempotent).
            if indexed_ids.contains(&drawer.id) {
                continue;
            }
            // G4: source_id = drawer.id so BM25/vector hits hydrate back to the
            // Drawer row. drawer.filed_at is epoch MILLISECONDS —
            // exactly the now_millis enqueue_ingest expects — so pass it directly.
            jobs.push((drawer.content, drawer.id, drawer.filed_at));
        }

        // Cap the collected jobs to REINDEX_MAX_JOBS to prevent a single large
        // estate from flooding the encode queue and starving live captures
        // (Part 6 DoS hardening). Log a warning when truncation occurs so the
        // HTTP handler knows to surface a "call again" advisory to the caller.
        // NOTE: REINDEX_MAX_JOBS is the total ceiling; enqueue_ingest_batch's
        // internal chunk size is a separate per-fsync unit, NOT this cap.
        let total_missing = jobs.len();
        if total_missing > Self::REINDEX_MAX_JOBS {
            eprintln!(
                "[GLK/reindexMissing] WARNING: truncated to REINDEX_MAX_JOBS={}; {} unindexed drawers remain — repeat call to continue backfill for estate {:?}",
                Self::REINDEX_MAX_JOBS,
                total_missing,
                handle.estate_uuid,
            );
            jobs.truncate(Self::REINDEX_MAX_JOBS);
        }

        Ok(Some((corpus, jobs)))
    }

    /// Sweeps the ENTIRE `drawers` table exactly once, in bounded pages via
    /// `active_drawers_after`, returning the COMPLETE missing-job list
    /// (uncapped, unlike `collect_reindex_jobs`, whose single-collect
    /// contract truncates at `REINDEX_MAX_JOBS` and is exercised by
    /// `encode_intake_parity.rs` — left untouched by this method).
    ///
    /// MEDIUM perf fix (Swift twin: `EncodeIntake.reindexMissing`'s upfront
    /// sweep). `run_reindex_responsive` (AriaMcpKit) previously called
    /// `collect_reindex_jobs` once PER PASS of its up-to-1000-pass loop,
    /// and `collect_reindex_jobs` internally called `all_drawers` — an
    /// unbounded, full-table load — every time, so a large backfill
    /// reloaded the whole table on every one of up to 1000 passes. This
    /// method performs that full-table determination exactly ONCE per
    /// `reindexMissing` invocation; the caller slices the returned list
    /// into `REINDEX_MAX_JOBS`-sized passes itself instead of re-scanning
    /// to find each pass's jobs (see `run_reindex_responsive`).
    ///
    /// Returns `(corpus, jobs, indexed_count)` — `indexed_count` is the
    /// size of the `indexed_source_ids()` snapshot taken at sweep start,
    /// needed by the caller's `is_small_reindex_delta` classification
    /// (previously computed from the first pass's `collect_reindex_jobs`
    /// call; now computed once here since there is only one sweep).
    pub fn sweep_reindex_missing(
        &mut self,
        handle: &EstateHandle,
    ) -> Result<Option<(Arc<CorpusContentEngine>, Vec<(String, String, i64)>, usize)>, VerbDispatchError> {
        let corpus = match self.corpus_for(handle) {
            Some(c) => c,
            None => return Ok(None),
        };

        // Snapshot which drawer IDs are already indexed so we enqueue only
        // the missing subset. A single snapshot, not re-fetched per page:
        // the missing set below is determined once, up front, against this
        // snapshot (mirrors the Swift twin's single `indexedIDs` fetch).
        let indexed_ids = corpus.indexed_source_ids().map_err(|e| {
            verb_fail(format!(
                "sweep_reindex_missing: indexed_source_ids failed: {e:?}"
            ))
        })?;

        // Page size for `active_drawers_after`: bounds how many full
        // (content-hydrated) Drawer rows any single storage-tier query
        // materializes. Independent of REINDEX_MAX_JOBS, which bounds how
        // many jobs the CALLER enqueues per pass, not how many rows this
        // sweep scans per page. Matches the Swift twin's
        // `reindexScanPageSize`.
        const SCAN_PAGE_SIZE: usize = 2_000;
        let mut jobs: Vec<(String, String, i64)> = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let page = self.active_drawers_after(handle, cursor.as_deref(), SCAN_PAGE_SIZE)?;
            if page.is_empty() {
                break;
            }
            let page_len = page.len();
            cursor = page.last().map(|d| d.id.clone());
            for drawer in page {
                // Skip empty-content drawers (nothing to encode).
                // active_drawers_after already excludes tombstoned rows.
                if drawer.content.is_empty() {
                    continue;
                }
                // Skip drawers already in the Corpus (idempotent).
                if indexed_ids.contains(&drawer.id) {
                    continue;
                }
                // G4: source_id = drawer.id so BM25/vector hits hydrate back
                // to the Drawer row. drawer.filed_at is epoch MILLISECONDS
                // — exactly what enqueue_ingest expects.
                jobs.push((drawer.content, drawer.id, drawer.filed_at));
            }
            if page_len < SCAN_PAGE_SIZE {
                break; // partial page: table exhausted
            }
        }

        Ok(Some((corpus, jobs, indexed_ids.len())))
    }

    /// The estate's registered `Corpus` — the semantic lane handle (BM25 + vector),
    /// or `None` for a locus-only estate. Exposed for the import cycle's tail-end
    /// full-corpus basis retrain (`run_reindex_responsive`), which calls
    /// `Corpus::reindex` on the shared `Arc` OUTSIDE the coordinator lock so the
    /// long full re-embed does not block other verbs while it runs. A thin public
    /// wrapper over the crate-internal `corpus_for`.
    pub fn corpus_handle(&self, handle: &EstateHandle) -> Option<Arc<CorpusContentEngine>> {
        self.corpus_for(handle)
    }

    /// The deferred Merkle full-tree rollup that follows a reindex (NT_R1).
    /// Batch-capture paths (e.g. moot_palace_import) skip per-drawer rollup to
    /// avoid O(N²) work; this O(N) full-tree pass runs once and is idempotent on
    /// an already-current tree. Re-acquire the coord lock briefly for this AFTER
    /// the lock-free enqueue.
    pub fn rollup_after_reindex(
        &mut self,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<(), VerbDispatchError> {
        let estate = self
            .estate_for(handle)
            .map_err(|_| VerbDispatchError::EstateNotOpen { estate_uuid: handle.estate_uuid })?;
        estate
            .rollup_all_merkle_roots(now)
            .map_err(|e| verb_fail(format!("rollup_after_reindex: rollup_all_merkle_roots failed: {e:?}")))?;
        Ok(())
    }

    // MARK: - Internals

    /// Ingest a single drawer into the estate's Corpus (the P6 inline path).
    /// Swift parity: `GeniusLocusKit.ingestDrawerIntoCorpus`.
    ///
    /// `source_id = drawer.id` (G4); `now = drawer.filed_at` for deterministic
    /// vector filing timestamps. A no-op when no Corpus is registered or the
    /// drawer content is empty.
    fn ingest_drawer_into_corpus(
        &self,
        handle: &EstateHandle,
        drawer: &Drawer,
    ) -> Result<(), VerbDispatchError> {
        let corpus = match self.corpus_for(handle) {
            Some(c) => c,
            None => return Ok(()),
        };
        if drawer.content.is_empty() {
            return Ok(());
        }
        // Shared-content 1.1: the drawer row is already durably stored; the
        // engine resolves it through the LocusKit-backed adapter and indexes
        // it under its own Drawer ID (identity is direct — no chunk lane).
        corpus
            .index_content(&drawer.id, drawer.filed_at)
            .map_err(|e| verb_fail(format!("corpus index_content failed: {e:?}")))?;
        Ok(())
    }
}

/// The canonical unclassified-content sentinel UDC code. Matches the Swift
/// `GeniusLocusKit.unclassifiedSentinel` ("000"). A frame carrying this code
/// at the `capture_with_mode` seam has not yet been classified; the seam
/// classifies via `Fdc::encode_anchor` when content is non-empty. A frame
/// carrying any other code (e.g. explicit vault frontmatter `udc`) is
/// preserved as-is — the seam does not override explicit anchors.
pub(crate) const UNCLASSIFIED_SENTINEL: &str = "000";
