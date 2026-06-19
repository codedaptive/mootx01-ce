// intake.rs — Dual-Path Intake (G7) Rust twin of the Swift
// EncodeJob.swift + EncodeIntake.swift composition wiring.
//
// THE LOAD-BEARING CHANGE: before this wiring, a capture produced a LocusKit
// drawer row ONLY — never chunked, never BM25-indexed, never embedded — so the
// semantic (BM25 + vector) recall lanes were DARK for normally-captured
// content. This module connects capture to `Corpus::ingest`, the one call that
// lights those lanes, via two paths:
//
//   • REGULAR (P3 + P4): capture returns immediately; an EncodeJob is enqueued
//     onto the estate's dedicated encode queue; the drain worker (P4) ingests
//     it into the Corpus and replies terminal. After the queue drains, the
//     drawer is BM25/vector searchable.
//
//   • IMPATIENT (P6): capture ingests the drawer into the Corpus INLINE before
//     returning, skipping the queue — the drawer is searchable the instant the
//     write returns, at the cost of a slower write.
//
// D-A: the write mode is an EXECUTION OPTION on the write verb (a parameter on
//      `capture_with_mode`), not a field on CaptureFrame.
// D-B: ONE QueueKit per estate (dedicated, not the Brain scheduler's queue),
//      mounted at provision alongside the corpus/vector registration.
// G4:  the worker ingests with `source_id = drawer.id` so BM25/vector hits
//      hydrate back to the real Drawer row.
//
// ── NEAR-REALTIME ENCODE DRAIN (both ports) ───────────────────────────────
// The Swift port runs the drain worker as a background `Task` spawned at mount
// time. The Rust port runs an equivalent WATCH-DRIVEN background OS thread
// (`std::thread`, NOT an async runtime — `tokio` is still not a dependency)
// spawned at mount time. The worker blocks on `PersistenceKitBackend::watch`
// (the storage observer wakes it the instant an EncodeJob is committed), drains
// the batch, ingests each into the Corpus, and replies terminal — so a
// `.regular` capture becomes BM25/vector searchable in NEAR-REALTIME, bounded by
// the observer wake latency, not by any governor tick or poll cadence. This
// supersedes the prior governor-tick (5 s) drain (cookbook §1.3/§2.2 rewrite:
// the queue is the realtime mechanism; the latency floor is the worker's wake).
//
// The background worker shares the SAME `Arc<dyn Storage>` (a cloned backend
// handle) and the SAME `Arc<Corpus>` as the enqueue side. `Corpus` is internally
// Mutex-guarded (Send + Sync), so concurrent ingest from the worker thread and
// reads from the HTTP/governor thread are safe. The worker is cancelled at
// `drop_encode_queue`: a stop flag is set and one wake job is enqueued to
// release the parked `watch`, then the thread joins.
//
// `await_encode_drain` and `drain_encode_queue_once` remain as the synchronous
// PUMP primitives: bulk callers / acceptance tests that need a deterministic
// "encoding finished" barrier drive the drain to completion themselves, exactly
// as the Swift `awaitDrain` consumer does. The background worker and the pump
// path are idempotent against each other (both go through the same claim-then-
// reply maildir transitions; a job is processed at most once).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use corpus_kit::Corpus;
use locus_kit::drawer::Drawer;
use persistence_kit::inmemory::InMemoryStorage;
use queuekit::{
    Job, JobId, ObservationStatus, PersistenceKitBackend, QueueBackend, QueueError, StreamId,
};
use serde::{Deserialize, Serialize};
use substrate_types::hlc::{HLCGenerator, HLC};

use crate::coordinator::{EstateCoordinator, VerbDispatchError};
use crate::handle::EstateHandle;

/// The execution mode for a write verb (D-A). Swift parity: `WriteMode`.
///
/// `Regular` is the default: the write returns as soon as the drawer row lands,
/// and semantic encoding happens on the encode drain (pumped by
/// `await_encode_drain`). `Impatient` trades write latency for immediate
/// searchability: the drawer is ingested into the Corpus inline before the
/// write returns.
///
/// The raw-value strings (`"regular"` / `"impatient"`) match the Swift
/// `WriteMode: String` raw values exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteMode {
    /// Enqueue the encode job; the drain ingests it on the next pump.
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

/// The work item the encode queue carries: everything the drain needs to ingest
/// one captured drawer into the estate's Corpus. Swift parity: `EncodeJob`.
///
/// `source_id` is intentionally the DRAWER id (not a chunk id): `Corpus::ingest`
/// keys its internal vectors by chunk id but `bm25_top_k_by_source` aggregates
/// chunk scores back to `source_id`, and recall hydrates non-locus hits by
/// drawer id. Passing the drawer id as `source_id` is what makes a recall hit
/// join back to a real `Drawer` row (G4).
///
/// The serde field names match the Swift `Codable` keys exactly so the JSON
/// payload byte-agrees across ports (the load-bearing cross-port wire contract,
/// item #3): `drawerID`, `estateUUID`, `text`, `embeddingModelID`,
/// `capturedAtISO8601`. `estateUUID` is the UPPERCASE UUID string Swift's
/// `UUID` Codable emits.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncodeJob {
    /// The captured drawer's id — used as `source_id` for `Corpus::ingest`.
    #[serde(rename = "drawerID")]
    pub drawer_id: String,
    /// The estate the drawer belongs to, as the uppercase UUID string Swift
    /// emits, so the JSON byte-agrees with the Swift payload.
    #[serde(rename = "estateUUID")]
    pub estate_uuid: String,
    /// The verbatim text to encode (the drawer's content).
    pub text: String,
    /// The embedding model id the drawer was captured under.
    #[serde(rename = "embeddingModelID")]
    pub embedding_model_id: String,
    /// The capture instant, ISO8601. Passed back into `Corpus::ingest(now)` so
    /// vector filing timestamps reproduce capture time deterministically.
    #[serde(rename = "capturedAtISO8601")]
    pub captured_at_iso8601: String,
}

impl EncodeJob {
    /// Build an EncodeJob from a freshly captured drawer's fields.
    ///
    /// `estate_uuid_bytes` is rendered as the uppercase UUID string (Swift
    /// parity). `captured_at_millis` is the drawer's capture instant in
    /// milliseconds since the Unix epoch; it is encoded ISO8601 with fractional
    /// seconds so the sub-second instant round-trips exactly.
    pub fn new(
        drawer_id: String,
        estate_uuid_bytes: &[u8; 16],
        text: String,
        embedding_model_id: String,
        captured_at_millis: i64,
    ) -> Self {
        EncodeJob {
            drawer_id,
            estate_uuid: uuid::Uuid::from_bytes(*estate_uuid_bytes)
                .to_string()
                .to_uppercase(),
            text,
            embedding_model_id,
            captured_at_iso8601: millis_to_iso8601(captured_at_millis),
        }
    }

    /// The capture instant in milliseconds since the Unix epoch, decoded back
    /// from `captured_at_iso8601`, or 0 (epoch) if the stored string is
    /// unparseable — defensive: a malformed timestamp must not crash the drain;
    /// epoch keeps ingest deterministic. Swift parity: `EncodeJob.capturedAt`.
    pub fn captured_at_millis(&self) -> i64 {
        iso8601_to_millis(&self.captured_at_iso8601).unwrap_or(0)
    }

    /// Encode this payload into a QueueKit `Job` ready to enqueue.
    ///
    /// The payload is JSON-encoded into `Job.payload`. `stream_id` is the
    /// estate-scoped encode stream so a drained job correlates to its estate;
    /// `submitted_at` is the supplied HLC. Swift parity: `EncodeJob.toJob`.
    pub fn to_job(&self, stream_id: StreamId, submitted_at: HLC) -> Result<Job, serde_json::Error> {
        let payload = serde_json::to_vec(self)?;
        Ok(Job {
            id: JobId(generate_job_id()),
            stream_id,
            submitted_at,
            priority: 50,
            payload,
            extensions: serde_json::Map::new(),
        })
    }

    /// Decode an EncodeJob back from a drained QueueKit `Job`. Swift parity:
    /// `EncodeJob.from(job:)`.
    pub fn from_job(job: &Job) -> Result<EncodeJob, serde_json::Error> {
        serde_json::from_slice(&job.payload)
    }
}

/// A fresh 32-hex-char job id with no hyphens — matches `JobID.generate`'s shape
/// in QueueKit (Swift) and the scheduler's `generate` helper.
fn generate_job_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

/// Render milliseconds-since-epoch as an ISO8601 instant with fractional
/// seconds (e.g. `2023-11-14T22:13:20.500Z`), matching the Swift
/// `ISO8601DateFormatter` with `.withInternetDateTime` + `.withFractionalSeconds`.
///
/// Implemented by hand (no chrono dependency — kits carry zero external Swift/
/// Rust deps beyond the approved set) using the civil-from-days algorithm
/// (Howard Hinnant's `days_from_civil` inverse). UTC only; the Swift formatter
/// also emits UTC (`Z`).
fn millis_to_iso8601(millis: i64) -> String {
    let secs = millis.div_euclid(1000);
    let frac_millis = millis.rem_euclid(1000);
    let days = secs.div_euclid(86_400);
    let secs_of_day = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let hh = secs_of_day / 3600;
    let mm = (secs_of_day % 3600) / 60;
    let ss = secs_of_day % 60;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y, m, d, hh, mm, ss, frac_millis
    )
}

/// Parse an ISO8601 instant of the exact shape `millis_to_iso8601` produces
/// (`YYYY-MM-DDThh:mm:ss.sssZ`) back to milliseconds since the Unix epoch.
/// Returns `None` if the string does not match that shape.
fn iso8601_to_millis(s: &str) -> Option<i64> {
    // Expected layout: YYYY-MM-DDThh:mm:ss.sssZ (24 chars).
    let b = s.as_bytes();
    if b.len() != 24 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T'
        || b[13] != b':' || b[16] != b':' || b[19] != b'.' || b[23] != b'Z'
    {
        return None;
    }
    let y: i64 = s.get(0..4)?.parse().ok()?;
    let m: i64 = s.get(5..7)?.parse().ok()?;
    let d: i64 = s.get(8..10)?.parse().ok()?;
    let hh: i64 = s.get(11..13)?.parse().ok()?;
    let mm: i64 = s.get(14..16)?.parse().ok()?;
    let ss: i64 = s.get(17..19)?.parse().ok()?;
    let frac: i64 = s.get(20..23)?.parse().ok()?;
    let days = days_from_civil(y, m, d);
    let secs = days * 86_400 + hh * 3600 + mm * 60 + ss;
    Some(secs * 1000 + frac)
}

/// Days from 1970-01-01 for a civil (y, m, d) date — Howard Hinnant's
/// `days_from_civil`. Valid for the proleptic Gregorian calendar.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as i64; // [0, 399]
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146_097 + doe - 719_468
}

/// Civil (y, m, d) date from days-since-1970 — Howard Hinnant's
/// `civil_from_days` (inverse of `days_from_civil`).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

/// Per-estate encode-queue state (D-B): the dedicated QueueKit, its HLC
/// generator, the encode stream id, and the WATCH-DRIVEN background drain
/// worker (near-realtime). Held parallel to the coordinator's estate registries.
pub(crate) struct EncodeQueue {
    pub(crate) queue: PersistenceKitBackend,
    pub(crate) hlc: HLCGenerator,
    pub(crate) stream_id: StreamId,
    /// Stop flag for the background watch worker. Set true at teardown; the
    /// worker's handler checks it on each wake and exits the watch loop.
    worker_stop: Arc<AtomicBool>,
    /// The background worker thread handle. `take`-n and joined at teardown.
    worker: Option<JoinHandle<()>>,
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

/// The estate-scoped encode stream id. Distinct from the Brain scheduler's
/// `glk_scheduler_<uuid>` stream so encode jobs never mix with signal jobs.
/// Swift parity: `GeniusLocusKit.encodeStreamID(for:)`.
pub(crate) fn encode_stream_id(handle: &EstateHandle) -> StreamId {
    StreamId(format!(
        "glk_encode_{}",
        uuid::Uuid::from_bytes(handle.estate_uuid).to_string().to_lowercase()
    ))
}

impl EstateCoordinator {
    // MARK: - capture (mode-aware) — D-A

    /// File a new drawer into the estate addressed by `handle`, then encode it
    /// into the estate's Corpus per `mode` (Dual-Path Intake). Swift parity:
    /// `GeniusLocusKit.capture(_:_:mode:)`.
    ///
    ///   • `Regular` — enqueues an `EncodeJob` onto the estate's encode queue
    ///     (P3). The drain ingests it on the next pump
    ///     (`await_encode_drain` / `drain_encode_queue_once`). The write returns
    ///     before encoding completes.
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
            let (code_opt, qid_opt) = lattice_lib::fdc_runtime::Fdc::encode_anchor(&frame.content);
            match code_opt {
                Some(code) if !code.is_empty() => {
                    let mut f = frame;
                    f.lattice_anchor = locus_kit::estate_types::LatticeAnchor {
                        udc_code: code,
                        udc_facets: None,
                        wikidata_qid: qid_opt,
                        wikidata_qids_secondary: None,
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
            }
            WriteMode::Regular => {
                // P3: enqueue an EncodeJob; the drain ingests it on the next pump.
                self.enqueue_encode_job(handle, &drawer)?;
            }
        }
        Ok(drawer)
    }

    // MARK: - mountEncodeQueue — D-B (called at provision)

    /// Mount the estate's dedicated encode queue and start its WATCH-DRIVEN
    /// background drain worker (near-realtime). Swift parity:
    /// `GeniusLocusKit.mountEncodeQueue(for:)`.
    ///
    /// D-B: ONE QueueKit per estate, distinct from the Brain scheduler's queue.
    /// Backed by a transient in-memory PersistenceKit backend so it needs no
    /// estate file directory and works for in-memory estates. Idempotent:
    /// re-mounting an already-mounted estate is a no-op.
    ///
    /// The background worker (an OS thread, not an async task) blocks on
    /// `backend.watch`: the storage observer wakes it the instant an EncodeJob is
    /// committed, it drains the batch, ingests each into the Corpus, and replies
    /// terminal. Latency floor = observer wake, not a tick. If no Corpus is
    /// registered yet (e.g. a LocusOnly estate), no worker is spawned — there is
    /// nothing to encode into.
    pub fn mount_encode_queue(&mut self, handle: &EstateHandle) -> Result<(), VerbDispatchError> {
        if self.encode_queues.contains_key(handle) {
            return Ok(()); // idempotent
        }
        let storage = Arc::new(InMemoryStorage::with_estate(uuid::Uuid::from_bytes(
            handle.estate_uuid,
        )));
        PersistenceKitBackend::open_schema(storage.as_ref())
            .map_err(|e| verb_fail(format!("encode queue open_schema failed: {e:?}")))?;
        let backend = PersistenceKitBackend::new(storage);

        // Spawn the watch-driven background drain worker when a Corpus is
        // registered for the estate (it is, in the provision path: the corpus is
        // inserted before mount; on-demand mounts happen from a `.regular`
        // capture which guards `has_corpus`). The worker holds a CLONED backend
        // handle over the same storage and a clone of the `Arc<Corpus>`.
        let stop = Arc::new(AtomicBool::new(false));
        let worker = if let Some(corpus) = self.corpus_for(handle) {
            let worker_backend = backend.clone();
            let worker_stop = Arc::clone(&stop);
            let est = uuid::Uuid::from_bytes(handle.estate_uuid);
            let h = std::thread::Builder::new()
                .name(format!("glk-encode-drain-{est}"))
                .spawn(move || {
                    encode_drain_watch_loop(worker_backend, corpus, worker_stop, est);
                })
                .map_err(|e| verb_fail(format!("encode drain worker spawn failed: {e}")))?;
            Some(h)
        } else {
            None
        };

        self.encode_queues.insert(
            *handle,
            EncodeQueue {
                queue: backend,
                hlc: HLCGenerator::new(1),
                stream_id: encode_stream_id(handle),
                worker_stop: stop,
                worker,
            },
        );
        Ok(())
    }

    /// Tear down the estate's encode queue and cancel its background drain
    /// worker. Idempotent. Swift parity: `GeniusLocusKit.dropEncodeQueue(for:)`.
    ///
    /// Cancellation: set the stop flag, then enqueue one wake job so the worker's
    /// parked `watch` releases, sees the flag, and exits the loop; then join the
    /// thread. The wake job is a no-op marker the worker drains-and-replies like
    /// any other (it carries empty content, so `ingest_one` skips it).
    pub fn drop_encode_queue(&mut self, handle: &EstateHandle) {
        if let Some(mut eq) = self.encode_queues.remove(handle) {
            eq.worker_stop.store(true, Ordering::SeqCst);
            if let Some(worker) = eq.worker.take() {
                // Wake the parked watch with a marker job (any INSERT fires the
                // observer). Best-effort: if the enqueue fails the join below
                // still completes once the worker next wakes or the channel
                // closes on storage drop.
                let _ = enqueue_wake_job(&eq.queue, &eq.stream_id);
                let _ = worker.join();
            }
        }
    }

    // MARK: - awaitEncodeDrain (P5 consumer)

    /// Block until the estate's encode queue has fully drained — every enqueued
    /// `EncodeJob` has been ingested and replied — then return. Swift parity:
    /// `GeniusLocusKit.awaitEncodeDrain(for:)`.
    ///
    /// SYNCHRONOUS PUMP barrier: a bulk caller / acceptance test that needs a
    /// deterministic "encoding finished" point drives the drain loop itself —
    /// drain a batch, ingest each, reply terminal, repeat until the queue is
    /// empty — then confirms both frontiers are clear via the await-empty latch.
    /// This runs ALONGSIDE the watch-driven background worker (both go through
    /// the same claim-then-reply transitions, so a job is processed at most once
    /// regardless of which path drains it). Returns promptly on an already-empty
    /// queue and returns immediately if no encode queue is mounted (e.g. a
    /// LocusOnly estate).
    pub fn await_encode_drain(&mut self, handle: &EstateHandle) -> Result<(), VerbDispatchError> {
        if !self.encode_queues.contains_key(handle) {
            return Ok(());
        }
        // Pump the drain until a pass processes nothing, i.e. the queue is empty.
        loop {
            let processed = self.drain_encode_queue_once(handle)?;
            if processed == 0 {
                break;
            }
        }
        // Confirm both frontiers are clear (parity with QueueKit.awaitDrain).
        // With the synchronous pump above, the queue is already empty here, so
        // the latch returns on its first probe; the bounded timeout guards
        // against a wedged job (one that could not be replied).
        let eq = self.encode_queues.get(handle).expect("queue present");
        eq.queue
            .await_drain(Duration::from_millis(20), Duration::from_secs(30))
            .map_err(|e| verb_fail(format!("await_encode_drain latch failed: {e:?}")))
    }

    // MARK: - reindexMissing

    /// Enqueue encode jobs for every active drawer that is not yet present in
    /// the estate's Corpus (BM25/vector index). Returns the count of drawers
    /// enqueued. Idempotent: drawers already indexed are skipped. Empty-content
    /// drawers are skipped (nothing to encode). Tombstoned drawers are skipped.
    ///
    /// Used to backfill estates populated before the dual-path intake bug fix:
    /// content captured via the row-only path (pre-G7 fix) never reached the
    /// Corpus, so BM25/vector recall returned zero hits for that content. This
    /// method surfaces the missing population and re-enqueues it as if the
    /// content were freshly captured. Swift parity: `GeniusLocusKit.reindexMissing`.
    ///
    /// `now` is the enqueue instant in milliseconds since epoch (deterministic —
    /// no wall-clock read inside the engine, matching the Swift convention).
    ///
    /// Returns 0 immediately when no Corpus is registered for the estate (e.g. a
    /// LocusOnly estate), matching the Swift guard `guard let corpus = corpusKits[handle]`.
    pub fn reindex_missing(
        &mut self,
        handle: &EstateHandle,
        // `_now` is retained for Swift parity (Swift passes `now` for deterministic
        // timestamps; Rust reuses drawer.filed_at inside enqueue_encode_job, which
        // already carries the capture instant). The parameter is present so callers
        // can be written symmetrically across both ports.
        _now: i64,
    ) -> Result<usize, VerbDispatchError> {
        // Guard: only estates with a registered Corpus have a BM25/vector lane.
        let corpus = match self.corpus_for(handle) {
            Some(c) => c,
            None => return Ok(0),
        };

        // Snapshot which drawer IDs are already indexed so we enqueue only the
        // missing subset. indexed_source_ids() is a full-table scan on the chunks
        // table — acceptable for a maintenance/admin path, not a hot path.
        let indexed_ids = corpus
            .indexed_source_ids()
            .map_err(|e| verb_fail(format!("reindex_missing: indexed_source_ids failed: {e:?}")))?;

        // Read all drawers (including tombstoned) so we can filter active ones.
        let all_drawers = self.all_drawers(handle)?;

        let mut enqueued = 0;
        for drawer in all_drawers {
            // Skip tombstoned drawers — they were intentionally removed.
            if drawer.tombstoned_at.is_some() {
                continue;
            }
            // Skip drawers with no content (nothing to encode).
            if drawer.content.is_empty() {
                continue;
            }
            // Skip drawers already present in the Corpus (idempotent).
            if indexed_ids.contains(&drawer.id) {
                continue;
            }
            // Enqueue via the same path as capture_with_mode(Regular) — G4:
            // source_id = drawer.id so BM25/vector hits hydrate back to the Drawer row.
            self.enqueue_encode_job(handle, &drawer)?;
            enqueued += 1;
        }
        Ok(enqueued)
    }

    // MARK: - Internals

    /// Enqueue an `EncodeJob` for a captured drawer (P3). Swift parity:
    /// `GeniusLocusKit.enqueueEncodeJob`.
    ///
    /// Mounts the encode queue on demand if absent. Skips drawers with empty
    /// content — there is nothing to encode.
    fn enqueue_encode_job(
        &mut self,
        handle: &EstateHandle,
        drawer: &Drawer,
    ) -> Result<(), VerbDispatchError> {
        if drawer.content.is_empty() {
            return Ok(());
        }
        if !self.encode_queues.contains_key(handle) {
            self.mount_encode_queue(handle)?;
        }
        let job = EncodeJob::new(
            drawer.id.clone(),
            &handle.estate_uuid,
            drawer.content.clone(),
            drawer.embedding_model_id.clone(),
            // `drawer.filed_at` is epoch SECONDS; `EncodeJob::new` expects
            // `captured_at_millis` in MILLISECONDS (it runs the value through
            // millis_to_iso8601, which divides by 1000). Convert here — without
            // the ×1000 the encode job's captured_at, and the vector filing
            // timestamp Corpus::ingest derives from it, land in 1970.
            drawer.filed_at * 1000,
        );
        let eq = self.encode_queues.get_mut(handle).expect("queue present");
        // Stamp the submission on the estate's per-estate HLC. The HLC physical
        // clock is the drawer's capture instant in milliseconds (deterministic —
        // no clock read in the engine). Swift uses the same derivation.
        // drawer.filed_at is epoch seconds; HLC.send() requires milliseconds.
        let submitted_at = eq.hlc.send(drawer.filed_at * 1000);
        let stream_id = eq.stream_id.clone();
        let queue_job = job
            .to_job(stream_id, submitted_at)
            .map_err(|e| verb_fail(format!("encode job encode failed: {e}")))?;
        eq.queue
            .write(&queue_job)
            .map_err(|e| verb_fail(format!("encode job enqueue failed: {e:?}")))
    }

    /// Ingest a single drawer into the estate's Corpus (P4/P6 shared call).
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
        corpus
            // `Corpus::ingest` expects `now_millis` (MILLISECONDS — it divides by
            // 1000 internally); `drawer.filed_at` is epoch SECONDS, so ×1000.
            // Without this the inline (impatient) path files vectors at 1970,
            // mirroring the drain-path EncodeJob fix above.
            .ingest(&drawer.content, &drawer.id, drawer.filed_at * 1000)
            .map_err(|e| verb_fail(format!("corpus ingest failed: {e:?}")))
    }

    /// Drain the encode queue once: ingest every currently-available job, then
    /// reply terminal for each (P4). Returns the number of jobs processed.
    /// Swift parity: `GeniusLocusKit.drainEncodeQueueOnce`.
    ///
    /// Ingest failures are caught per-job (logged-equivalent: the drawer row is
    /// already stored) and the job is still replied `Blocked` so it leaves the
    /// in-flight frontier and the await-empty latch can release.
    pub fn drain_encode_queue_once(
        &mut self,
        handle: &EstateHandle,
    ) -> Result<usize, VerbDispatchError> {
        if !self.encode_queues.contains_key(handle) {
            return Ok(0);
        }
        // Drain the batch first (immutable borrow of the queue), collecting the
        // jobs, so the subsequent corpus ingest (which borrows the coordinator's
        // corpus registry) does not overlap a mutable queue borrow.
        let batch: Vec<Job> = {
            let eq = self.encode_queues.get(handle).expect("queue present");
            eq.queue
                .drain_available()
                .map_err(|e| verb_fail(format!("encode drain failed: {e:?}")))?
                .into_iter()
                .map(|(job, _session)| job)
                .collect()
        };

        let corpus = self.corpus_for(handle);
        let mut processed = 0;
        for job in &batch {
            // AT-LEAST-ONCE: a job is acknowledged (completed terminal) only
            // AFTER its ingest succeeds. A transient ingest failure is retried in
            // place (bounded) so no successfully-captured drawer is silently
            // lost; only a permanently-failing ingest, or an undecodable job, is
            // finally replied Blocked (the drawer row is already durably stored,
            // so the queue never wedges and `await_encode_drain` can release).
            let terminal = match self.ingest_one_with_retry(&corpus, job) {
                Ok(()) => ObservationStatus::Done,
                Err(()) => ObservationStatus::Blocked,
            };
            let eq = self.encode_queues.get(handle).expect("queue present");
            let _ = eq.queue.complete(&job.id, terminal, vec![]);
            processed += 1;
        }
        Ok(processed)
    }

    /// Decode one drained job, then ingest it into the (optional) corpus with a
    /// bounded at-least-once retry. G4: source_id = drawer id; now = capture
    /// instant.
    ///
    /// A DECODE failure is permanent (re-parsing the same bytes yields the same
    /// error) → `Err(())` immediately, no retry budget spent. An INGEST failure
    /// is retried up to `ENCODE_INGEST_MAX_ATTEMPTS` times because Corpus ingest
    /// is idempotent (content-addressed chunk ids — re-ingest overwrites the same
    /// postings, never duplicates), so retrying an idempotent op is safe and does
    /// not violate QueueKit B-7 (which forbids the QUEUE from auto-requeuing a
    /// half-applied job; here the CONSUMER retries). Returns `Ok(())` on the
    /// first success, `Err(())` if the budget is exhausted.
    fn ingest_one_with_retry(&self, corpus: &Option<Arc<Corpus>>, job: &Job) -> Result<(), ()> {
        // Decode once (permanent on failure).
        let encode_job = EncodeJob::from_job(job).map_err(|_| ())?;
        if encode_job.text.is_empty() || corpus.is_none() {
            return Ok(()); // nothing to ingest (wake marker / .locusOnly)
        }
        let corpus = corpus.as_ref().expect("corpus present");
        for _attempt in 0..ENCODE_INGEST_MAX_ATTEMPTS {
            // Test seam: fail this drawer's FIRST attempt once (transient fault).
            #[cfg(any(test, feature = "test-seams"))]
            {
                let mut seam = self.test_force_encode_ingest_transient.borrow_mut();
                if let Some(failed) = seam.as_mut() {
                    if failed.insert(encode_job.drawer_id.clone()) {
                        continue; // first time for this drawer → simulate transient failure
                    }
                }
            }
            match corpus.ingest(
                &encode_job.text,
                &encode_job.drawer_id,
                encode_job.captured_at_millis(),
            ) {
                Ok(()) => return Ok(()),
                Err(_) => continue,
            }
        }
        Err(())
    }
}

/// The bounded at-least-once retry budget for a single encode job's ingest.
/// Mirrors the Swift `encodeIngestMaxAttempts`. 8 attempts outlasts a realistic
/// transient hiccup while bounding a permanently-failing job's cost.
const ENCODE_INGEST_MAX_ATTEMPTS: usize = 8;

/// The canonical unclassified-content sentinel UDC code. Matches the Swift
/// `GeniusLocusKit.unclassifiedSentinel` ("000"). A frame carrying this code
/// at the `capture_with_mode` seam has not yet been classified; the seam
/// classifies via `Fdc::encode_anchor` when content is non-empty. A frame
/// carrying any other code (e.g. explicit vault frontmatter `udc`) is
/// preserved as-is — the seam does not override explicit anchors.
pub(crate) const UNCLASSIFIED_SENTINEL: &str = "000";

/// Ingest one drained job into the corpus from the background WATCH worker, with
/// the same bounded at-least-once retry as the pump path. G4: source_id = drawer
/// id; now = capture instant. Returns `Err(())` only after a decode failure
/// (permanent) or an ingest that fails every attempt, so the caller replies
/// `Blocked`. An empty-text payload (e.g. the teardown wake marker) ingests
/// nothing and succeeds. The watch worker has no test seam — it runs in
/// production; the pump path (`ingest_one_with_retry`) carries the injectable
/// failure seam.
fn ingest_one_into(corpus: Option<&Arc<Corpus>>, job: &Job) -> Result<(), ()> {
    // Decode once (permanent on failure).
    let encode_job = EncodeJob::from_job(job).map_err(|_| ())?;
    let corpus = match corpus {
        Some(c) if !encode_job.text.is_empty() => c,
        _ => return Ok(()), // nothing to ingest (wake marker / .locusOnly)
    };
    // AT-LEAST-ONCE: retry the idempotent ingest until it lands or the bounded
    // budget is spent (see `ingest_one_with_retry` for the idempotency / B-7
    // rationale).
    for _attempt in 0..ENCODE_INGEST_MAX_ATTEMPTS {
        if corpus
            .ingest(
                &encode_job.text,
                &encode_job.drawer_id,
                encode_job.captured_at_millis(),
            )
            .is_ok()
        {
            return Ok(());
        }
    }
    Err(())
}

/// The WATCH-DRIVEN background drain worker body (near-realtime). Blocks on
/// `backend.watch`: the storage observer wakes it the instant an EncodeJob is
/// committed; the handler ingests each drained job into the Corpus and replies
/// terminal. Exits when the stop flag is set (checked at the top of each batch)
/// — `drop_encode_queue` sets the flag and enqueues a wake marker to release the
/// parked watch.
fn encode_drain_watch_loop(
    backend: PersistenceKitBackend,
    corpus: Arc<Corpus>,
    stop: Arc<AtomicBool>,
    estate: uuid::Uuid,
) {
    let handler = |job: Job, _session: queuekit::SessionId| -> Result<(), QueueError> {
        // Stop requested: break the watch loop. Returning Err is the documented
        // way to exit `watch` (QUEUEKIT_SPEC §3); the wake marker that released
        // us is left replied below first so the queue does not wedge.
        if stop.load(Ordering::SeqCst) {
            return Err(QueueError::BackendUnavailable(
                "encode drain worker stopping".to_string(),
            ));
        }
        let terminal = match ingest_one_into(Some(&corpus), &job) {
            Ok(()) => ObservationStatus::Done,
            // The drawer row is already durably stored; a failed encode must not
            // wedge the queue. Reply Blocked so the job leaves the in-flight
            // frontier and `await_encode_drain` can release.
            Err(()) => ObservationStatus::Blocked,
        };
        let _ = backend.complete(&job.id, terminal, vec![]);
        Ok(())
    };
    // watch() returns when the handler errors (stop) or the storage observer
    // channel closes (storage dropped). Either way the worker thread ends.
    if let Err(e) = backend.watch(handler) {
        // BackendUnavailable("...stopping") is the normal stop path — not logged.
        let msg = format!("{e:?}");
        if !msg.contains("stopping") {
            eprintln!("GeniusLocusKit: encode drain worker for estate {estate} exited: {msg}");
        }
    }
}

/// Enqueue a tiny wake marker job to release a parked `watch` at teardown. The
/// marker carries empty content, so the worker drains-and-replies it without
/// ingesting (then sees the stop flag and exits). Best-effort.
fn enqueue_wake_job(
    backend: &PersistenceKitBackend,
    stream_id: &StreamId,
) -> Result<(), QueueError> {
    let marker = EncodeJob::new(
        "wake".to_string(),
        &[0u8; 16],
        String::new(), // empty text → ingest skips it
        String::new(),
        0,
    );
    // A deterministic-enough HLC for a throwaway marker; the worker is exiting.
    let job = marker
        .to_job(stream_id.clone(), HLC::new(0, 0, 1))
        .map_err(|e| QueueError::WriteFailed(e.to_string()))?;
    backend.write(&job)
}

