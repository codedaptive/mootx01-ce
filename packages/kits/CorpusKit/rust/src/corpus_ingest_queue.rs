// corpus_ingest_queue.rs — the Corpus-owned ingest pipeline (Rust twin of the
// Swift CorpusIngestQueue.swift).
//
// CorpusKit is a standalone database substrate. A Corpus queues, drains, and
// encodes its own content with no orchestrator: `enqueue_ingest` puts an
// IngestJob on the corpus's dedicated QueueKit, and a foreground poll worker
// pulls every currently-available job each pass and ingests the whole batch via
// `ingest_batch` (cross-document parallel compute, serial batched writes — the
// bounded worker pool). This is the encode pipeline that previously lived in
// GeniusLocusKit's intake.rs; it belongs here so every SDK consumer
// (CorpusKit-direct, no GLK) gets multi-core encode, and so GeniusLocusKit is
// pure orchestration: it enqueues work and, via `on_encoded`, coordinates the
// LocusKit room rollup for the encoded drawers — it never performs the encode.
//
// T4 (ADR-021 Decision 7): the encode queue is now the SHARED per-estate
// encrypted queue — a PersistenceKitBackend over `queue.sqlite` beside the
// estate (derived via `EstateConfiguration.queue_sibling("queue.sqlite")`). This
// replaces the old `FilesystemBackend` maildir (`corpus_ingest_queue/`) that was
// plaintext even when the estate was encrypted — a security hole. The encode
// stream is isolated by `stream_id = "encode"` so a future dreaming drainer can
// share the same queue.sqlite without claiming encode jobs (ADR-021 Decision 7:
// one per-estate queue, per-(estate, stream) drainers). The private CorpusKit
// `DrainLease` is replaced by the QueueKit-provided `DrainLease` (T2), keyed on
// `stream = "encode"`. Drain uses the T1 stream-scoped `drain_for_stream`.
//
// Both ports use a POLL drain loop (drain the whole available batch →
// ingest_batch → reply terminal → sleep), so the latency floor is the ~15 ms
// idle interval and the parallelism is cross-document. The 1.0 worker pool is
// per-corpus; the process-global cross-estate cap is the 1.1 central drain
// master (DECISION_CENTRAL_DRAIN_MASTER_2026-06-23) — ~70% of this (the
// `ingest_batch` concurrent compute) carries forward unchanged.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use queuekit::{
    DrainLease, Job, JobId, ObservationStatus, PersistenceKitBackend, QueueBackend,
    QueueKit, StreamId, DRAIN_LEASE_HEARTBEAT_SECS, wall_now_secs,
};
use serde::{Deserialize, Serialize};
use substrate_types::hlc::{HLCGenerator, HLC};

use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::sqlite::SqliteStorage;
use persistence_kit::storage::BackendConfiguration;

use crate::corpus::Corpus;
use crate::error::{CorpusKitError, CorpusKitResult};

/// The ingest queue facade type: a `QueueKit` over either backend held as
/// `Box<dyn QueueBackend>`. Aliased for readability at the many use sites.
type IngestQueue = QueueKit<Box<dyn QueueBackend>>;

/// Wall-clock epoch seconds for the QueueKit drain telemetry (head-of-line age).
/// This is queue INFRASTRUCTURE telemetry, not the deterministic ingest engine —
/// it mirrors Swift's `QueueKit.drain()` reading `ContinuousClock` internally, so
/// a wall-clock read here is consistent with the Swift port and does not violate
/// the engine-determinism rule (which governs `ingest_batch`, not the drain loop).
fn drain_telemetry_now() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// The orchestrator coordination callback: invoked after a drained batch
/// finishes ingesting, with the encoded sourceIDs. Mirrors Swift's
/// `onEncoded: (@Sendable ([String]) async -> Void)?`.
pub(crate) type OnEncoded = Box<dyn Fn(&[String]) + Send + Sync>;

/// Test-only ingest failure hook: returns `Err(())` to simulate a transient
/// ingest failure for the named sourceID, exercising the at-least-once retry.
/// Mirrors Swift's `_ingestFailureHook`.
#[cfg(any(test, feature = "test-seams"))]
pub(crate) type IngestFailureHook = Box<dyn Fn(&str) -> Result<(), ()> + Send + Sync>;

/// The Corpus-owned ingest queue state: the QueueKit-backed encode queue, the
/// submission HLC, the drain-worker stop flag, and the worker thread handle.
/// Held behind a Mutex on the Corpus.
/// Mirrors Swift's `Corpus.ingestQueue` + `ingestHLC` + `ingestDrainWorker`.
pub(crate) struct IngestQueueState {
    /// The QueueKit FACADE over the estate's encode queue — the shared encrypted
    /// `queue.sqlite` PersistenceKitBackend (file-backed estates, T4) or the
    /// transient in-memory `PersistenceKitBackend` (in-memory estates), held as
    /// `Box<dyn QueueBackend>`. The Corpus drives the queue THROUGH the facade
    /// (send / drain_for_stream / reply / reply_session / await_drain) rather
    /// than reaching to the raw backend — structurally matching the Swift
    /// `Corpus.ingestQueue: QueueKit`. `Arc` so the drain worker shares the facade.
    queue: Arc<IngestQueue>,
    /// Per-corpus HLC for stamping queue submissions, derived from each item's
    /// capture instant so submission stamps are deterministic.
    hlc: HLCGenerator,
    /// Stop flag for the background poll worker. Set true at teardown; the
    /// worker checks it each pass and exits.
    stop: Arc<AtomicBool>,
    /// The background worker thread handle. `take`-n and joined at teardown.
    worker: Option<JoinHandle<()>>,
}


/// The corpus encode stream id (T4 / ADR-021 Decision 7). The shared
/// `queue.sqlite` can host other streams (e.g. `"dreaming"`) concurrently;
/// this drainer claims only `"encode"` jobs via `drain_for_stream`.
fn encode_stream_id() -> StreamId {
    StreamId("encode".to_string())
}

/// Fixed estate identity for the transient in-memory ingest-queue backend. The
/// backend is per-Corpus and never shared (each `InMemoryStorage` owns its own
/// independent state — no global registry), so the id is cosmetic; a constant
/// avoids UUID nondeterminism in the engine. Matches the Swift fixed UUID.
fn ingest_queue_store_id() -> uuid::Uuid {
    uuid::Uuid::from_u128(0xC0B0_C0DE_0000_0000_0000_0000_0000_0000)
}

/// The bounded at-least-once retry budget for a single ingest. Corpus ingest is
/// idempotent (content-addressed chunk ids), so in-place retry is the
/// spec-sanctioned consumer-retry pattern (QueueKit B-7 forbids the QUEUE
/// auto-requeuing, not the CONSUMER retrying an idempotent op). Mirrors Swift's
/// `ingestMaxAttempts`.
const INGEST_MAX_ATTEMPTS: usize = 8;

impl Corpus {
    // MARK: - Mount / drop

    /// Mount the corpus's dedicated ingest queue and start its foreground poll
    /// drain worker. Idempotent: re-mounting is a no-op. Takes `&Arc<Self>`
    /// because the worker thread holds a cloned `Arc<Corpus>` to call
    /// `ingest_batch`. Mirrors Swift's `Corpus.mountIngestQueue()`.
    ///
    /// Backend selection follows the estate's durability (T4 — ADR-021 Decision 7):
    ///   - SQLite estate → the SHARED encrypted `queue.sqlite` beside the estate.
    ///     `storage.configuration().queue_sibling("queue.sqlite")` derives the
    ///     sibling config (same directory, same encryption key). A
    ///     `PersistenceKitBackend` over this sibling is the encode queue for all
    ///     streams. No maildir is created; the old `corpus_ingest_queue/` is gone.
    ///   - InMemory estate → a transient in-memory PersistenceKit-backed queue:
    ///     the estate itself is ephemeral, so there is nothing to persist or recover.
    pub fn mount_ingest_queue(self: &Arc<Self>) -> CorpusKitResult<()> {
        let mut guard = self
            .ingest_queue
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into()))?;
        if guard.is_some() {
            return Ok(()); // idempotent
        }

        // Choose the backend by estate durability, then wrap it in the QueueKit
        // FACADE — the Corpus drives the queue through the facade, never the raw
        // backend (mirrors Swift's `QueueKit(backend:)`). `Box<dyn QueueBackend>`
        // lets one facade type hold either backend.
        // Single-drainer lease (T2): non-None only for a durable SQLite estate (several
        // processes may open it); in-memory estates are single-process.
        let mut drain_lease: Option<DrainLease> = None;
        let backend: Box<dyn QueueBackend> = match &self.storage.configuration().backend {
            BackendConfiguration::Sqlite { path, .. } => {
                // Derive the sibling config: same directory, same encryption key.
                // `queue_sibling` is deterministic — same estate → same sibling UUID
                // and path — so all processes that open the estate share one queue.sqlite.
                let sibling_cfg = self
                    .storage
                    .configuration()
                    .queue_sibling("queue.sqlite")
                    .map_err(|e| {
                        CorpusKitError::StoreUnavailable(format!("queue_sibling: {e:?}"))
                    })?;

                // The estate directory: parent of the estate path. The T2 DrainLease
                // file lands here as `encode.drain.lease`, keyed on stream="encode" so
                // a future dreaming drainer can hold its own lease concurrently.
                let estate_dir = std::path::Path::new(path)
                    .parent()
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| std::path::PathBuf::from("."));

                // Owner token = PID + this Corpus instance's Arc address, so a reused
                // PID cannot impersonate a prior holder (mirrors Swift's instanceToken).
                let owner = format!("pid-{}-{:p}", std::process::id(), Arc::as_ptr(self));
                drain_lease = Some(DrainLease::new(&estate_dir, "encode", owner));

                let qs = SqliteStorage::new(sibling_cfg).map_err(|e| {
                    CorpusKitError::StoreUnavailable(format!("queue.sqlite open: {e:?}"))
                })?;
                let qs = Arc::new(qs);
                PersistenceKitBackend::open_schema(qs.as_ref()).map_err(|e| {
                    CorpusKitError::StoreUnavailable(format!("queue.sqlite open_schema: {e:?}"))
                })?;
                Box::new(PersistenceKitBackend::new(qs))
            }
            _ => {
                // In-memory estate: transient queue, no crash recovery, no cross-process
                // lease. A fixed estate UUID keeps the engine deterministic (no UUID()).
                let storage = Arc::new(InMemoryStorage::with_estate(ingest_queue_store_id()));
                PersistenceKitBackend::open_schema(storage.as_ref()).map_err(|e| {
                    CorpusKitError::StoreUnavailable(format!("ingest queue open_schema: {e:?}"))
                })?;
                Box::new(PersistenceKitBackend::new(storage))
            }
        };
        let queue = Arc::new(QueueKit::new(backend));

        // Foreground poll worker (an OS thread, not an async task — corpus-kit
        // carries no async runtime). It shares the one facade via `Arc` and a clone
        // of the `Arc<Corpus>`. Foreground priority: the encode drain serves
        // user-facing capture/import. Cancelled in `drop_ingest_queue`.
        let stop = Arc::new(AtomicBool::new(false));
        let worker_queue = Arc::clone(&queue);
        let worker_stop = Arc::clone(&stop);
        let worker_corpus = Arc::clone(self);
        let handle = std::thread::Builder::new()
            .name("corpus-ingest-drain".to_string())
            .spawn(move || {
                run_ingest_drain_loop(worker_corpus, worker_queue, worker_stop, drain_lease);
            })
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest drain spawn: {e}")))?;

        *guard = Some(IngestQueueState {
            queue,
            hlc: HLCGenerator::new(1),
            stop,
            worker: Some(handle),
        });
        Ok(())
    }

    /// Tear down the corpus's ingest queue and cancel its drain worker.
    /// Idempotent. Cancellation: set the stop flag, then join the worker (it
    /// observes the flag on its next pass and exits). Mirrors Swift's
    /// `Corpus.dropIngestQueue()`.
    pub fn drop_ingest_queue(&self) {
        let taken = {
            let mut guard = match self.ingest_queue.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            guard.take()
        };
        if let Some(mut state) = taken {
            state.stop.store(true, Ordering::SeqCst);
            if let Some(worker) = state.worker.take() {
                let _ = worker.join();
            }
        }
    }

    // MARK: - Enqueue / await

    /// Enqueue text for asynchronous ingest onto the corpus's ingest queue.
    /// Mounts the queue on demand if absent (hence `&Arc<Self>`, matching the
    /// Swift lazy-mount). Empty text is skipped. `source_id` is the stable source
    /// handle (drawer id in the GLK context); `now_millis` is the capture instant
    /// in milliseconds since epoch (deterministic — no clock read in the engine).
    /// Mirrors Swift's `Corpus.enqueueIngest`.
    pub fn enqueue_ingest(
        self: &Arc<Self>,
        text: &str,
        source_id: &str,
        now_millis: i64,
    ) -> CorpusKitResult<()> {
        if text.is_empty() {
            return Ok(());
        }
        // Lazy mount (drops the borrow before re-locking inside mount).
        let mounted = self
            .ingest_queue
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into()))?
            .is_some();
        if !mounted {
            self.mount_ingest_queue()?;
        }

        let job = IngestJob::new(source_id.to_string(), text.to_string(), now_millis);
        let mut guard = self
            .ingest_queue
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into()))?;
        let state = match guard.as_mut() {
            Some(s) => s,
            None => return Ok(()),
        };
        // Stamp the submission on the corpus's ingest HLC (milliseconds physical
        // clock derived from the capture instant — deterministic).
        let submitted_at = state.hlc.send(now_millis);
        let queue_job = job
            .to_job(encode_stream_id(), submitted_at)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest job encode: {e}")))?;
        state
            .queue
            .send(&queue_job)
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest enqueue: {e:?}")))
    }

    /// Enqueue many ingest jobs in one pass — the bulk twin of `enqueue_ingest`,
    /// for the post-import reindex. Builds every job under ONE ingest-queue lock,
    /// stamping each on the corpus's ingest HLC in sequence (deterministic), then
    /// hands the whole batch to `send_batch` so the filesystem backend writes all
    /// files and fsyncs `new/` ONCE instead of per job — the per-job fsync was the
    /// last full-core bottleneck of a bulk import (the reindex thread pinned in
    /// File::sync_all). Empty-text items are skipped. The caller chunks the input
    /// so the brief lock and the single fsync window stay bounded against
    /// concurrent live captures. Mirrors Swift's `Corpus.enqueueIngestBatch`.
    pub fn enqueue_ingest_batch(
        self: &Arc<Self>,
        items: &[(String, String, i64)],
    ) -> CorpusKitResult<()> {
        if items.is_empty() {
            return Ok(());
        }
        let mounted = self
            .ingest_queue
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into()))?
            .is_some();
        if !mounted {
            self.mount_ingest_queue()?;
        }

        let mut guard = self
            .ingest_queue
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into()))?;
        let state = match guard.as_mut() {
            Some(s) => s,
            None => return Ok(()),
        };
        let mut jobs = Vec::with_capacity(items.len());
        for (text, source_id, now_millis) in items {
            if text.is_empty() {
                continue;
            }
            let submitted_at = state.hlc.send(*now_millis);
            let job = IngestJob::new(source_id.clone(), text.clone(), *now_millis);
            let queue_job = job
                .to_job(encode_stream_id(), submitted_at)
                .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest job encode: {e}")))?;
            jobs.push(queue_job);
        }
        state
            .queue
            .send_batch(&jobs)
            .map(|_| ())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest enqueue batch: {e:?}")))
    }

    /// Block until the corpus's ingest queue has fully drained — every enqueued
    /// job ingested and replied — then return. Returns immediately when no queue
    /// is mounted. SYNCHRONOUS PUMP barrier (runs alongside the background
    /// worker; both go through the same claim-then-reply transitions, so a job is
    /// processed at most once). Mirrors Swift's `Corpus.awaitIngestDrain`.
    pub fn await_ingest_drain(&self) -> CorpusKitResult<()> {
        // Share the facade handle (drops the lock before pumping).
        let queue = {
            let guard = self.ingest_queue.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into())
            })?;
            match guard.as_ref() {
                Some(s) => Arc::clone(&s.queue),
                None => return Ok(()),
            }
        };
        // Pump until a pass processes nothing, then confirm both frontiers clear.
        loop {
            if self.drain_with_queue(&queue)? == 0 {
                break;
            }
        }
        // Stream-scoped barrier: wait only for the ENCODE stream to clear. The
        // shared per-estate queue.sqlite also carries dreaming (and signals) jobs
        // this encode drainer never processes; a GLOBAL await_drain would block on
        // them forever (the post-T4/T6 encode-stall — dreaming jobs enqueued on
        // recall would hang every subsequent capture's encode barrier). The claim
        // (drain_for_stream) and the barrier must scope to the SAME stream.
        queue
            .await_drain_for_stream(
                &encode_stream_id(),
                Duration::from_millis(20),
                Duration::from_secs(30),
            )
            .map_err(|e| {
                CorpusKitError::StoreUnavailable(format!("await_ingest_drain latch: {e:?}"))
            })?;
        // Every enqueued job is now ingested (vectors appended under the deferred
        // window). Publish the resident index once so the writes are searchable
        // before this barrier returns — the bulk caller's searchability contract.
        self.publish_vector_index()
    }

    // MARK: - Depth (read-only status probe)

    /// The corpus ingest drain's outstanding work, as a point-in-time snapshot
    /// for status reporting. Returns `(pending, in_flight)`: `pending` is jobs
    /// submitted but not yet claimed (the `new/` frontier), `in_flight` is jobs
    /// claimed and mid-encode (the `cur/` frontier). Their sum is the encode
    /// work the drain has left; both zero means the drain is idle — everything
    /// enqueued has been encoded and replied.
    ///
    /// Read-only: this OBSERVES the queue frontiers, it never claims or drains,
    /// so it is safe to poll from any thread while the drain worker runs.
    /// Returns `(0, 0)` when no queue is mounted — an unmounted queue has had
    /// nothing enqueued this session, so it has no outstanding work. Mirrors
    /// Swift `Corpus.ingestQueueDepth()`.
    pub fn ingest_queue_depth(&self) -> CorpusKitResult<(usize, usize)> {
        let queue = {
            let guard = self.ingest_queue.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into())
            })?;
            match guard.as_ref() {
                Some(s) => Arc::clone(&s.queue),
                None => return Ok((0, 0)),
            }
        };
        // T1 stream-scoped pending count — counts only encode jobs, not other
        // streams that may share the same queue.sqlite in the future.
        let pending = queue
            .pending_count_for_stream(&encode_stream_id())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest depth pending: {e:?}")))?;
        let in_flight = queue
            .in_flight()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest depth in_flight: {e:?}")))?
            .len();
        Ok((pending, in_flight))
    }

    // MARK: - Drain

    /// Drain the ingest queue once: ingest every currently-available job, reply
    /// terminal for each, then fire the `on_encoded` coordination callback.
    /// Returns the number of jobs in the pass. Reachable for tests to drive the
    /// drain deterministically. Mirrors Swift's `Corpus.drainIngestQueueOnce`.
    pub fn drain_ingest_queue_once(&self) -> CorpusKitResult<usize> {
        let queue = {
            let guard = self.ingest_queue.lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("ingest queue lock poisoned".into())
            })?;
            match guard.as_ref() {
                Some(s) => Arc::clone(&s.queue),
                None => return Ok(0),
            }
        };
        self.drain_with_queue(&queue)
    }

    /// The shared drain body, parameterised by the backend handle so both the
    /// background worker and the synchronous pump drive the same logic.
    /// Uses the T1 stream-scoped `drain_for_stream` so it claims only `"encode"`
    /// jobs — future dreaming or signal jobs on the same queue.sqlite are never
    /// disturbed (ADR-021 Decision 7).
    fn drain_with_queue(&self, queue: &IngestQueue) -> CorpusKitResult<usize> {
        let claimed = queue
            .drain_for_stream(&encode_stream_id(), drain_telemetry_now())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("ingest drain: {e:?}")))?;
        if claimed.is_empty() {
            return Ok(0);
        }
        // Single-pass claim tags the whole batch with ONE session; capture it so
        // the fast path can retire the whole batch in one complete_session call.
        let batch_session = claimed[0].1.clone();
        let batch: Vec<Job> = claimed.into_iter().map(|(job, _session)| job).collect();

        // Enter deferred-index mode for this burst (idempotent across passes): the
        // batch's vector writes append to the resident array but defer the index
        // rebuild to publish_vector_index(), called once when the burst drains to
        // empty (the loop) or at the await_ingest_drain barrier — O(N), not O(N²).
        self.begin_deferred_vector_index()?;

        if !self.ingest_failure_active() {
            // Parallel fast path: decode the batch, run the concurrent batch
            // ingest, then reply terminal per job.
            let mut items: Vec<(String, String, i64)> = Vec::with_capacity(batch.len());
            let mut item_jobs: Vec<&Job> = Vec::with_capacity(batch.len());
            for job in &batch {
                match IngestJob::from_job(job) {
                    Err(_) => {
                        // Undecodable is permanent → blocked.
                        let _ = queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
                    }
                    Ok(ij) if ij.text.is_empty() => {
                        // Nothing to ingest → done immediately.
                        let _ = queue.reply(&job.id, ObservationStatus::Done, vec![]);
                    }
                    Ok(ij) => {
                        // Compute the capture instant before moving the String
                        // fields out of `ij` (avoids a partial-move borrow).
                        let captured = ij.captured_at_millis();
                        items.push((ij.text, ij.source_id, captured));
                        item_jobs.push(job);
                    }
                }
            }
            if !items.is_empty() {
                match self.ingest_batch(&items) {
                    Ok(()) => {
                        // Single-pass complete: retire every still-"cur" job of
                        // this batch's session in ONE bulk update instead of N
                        // per-job completes (each an O(N) scan). Undecodable/empty
                        // jobs were already completed individually above, so the
                        // guard (status="cur") flips exactly the ingested batch.
                        // On a zero count or error (a backend without the batch
                        // fast path, or a completion fault) fall back to per-job
                        // completion so no `cur` row is stranded — parity with the
                        // Swift drain's `if completed == 0 { per-job }` guard.
                        let completed = queue
                            .reply_session(&batch_session, ObservationStatus::Done)
                            .unwrap_or(0);
                        if completed == 0 {
                            // No session fast path (FilesystemBackend): retire the
                            // whole batch in ONE pass — one cur/ scan + one
                            // durability barrier — instead of per-job reply, whose
                            // FilesystemBackend complete was O(N²) (a full cur/
                            // scan per job) plus a per-job fsync.
                            let completions: Vec<(JobId, ObservationStatus)> = item_jobs
                                .iter()
                                .map(|j| (j.id.clone(), ObservationStatus::Done))
                                .collect();
                            let _ = queue.reply_batch(&completions);
                        }
                    }
                    Err(e) => {
                        // Batch failed — fall back to the per-job path so the
                        // idempotent AT-LEAST-ONCE retry still lands each item.
                        eprintln!(
                            "CorpusKit: ingest_batch failed: {e:?} — falling back to per-job ingest"
                        );
                        for job in &item_jobs {
                            self.ingest_one_and_reply(queue, job);
                        }
                    }
                }
            }
        } else {
            // Serial path: test failure-injection active.
            for job in &batch {
                self.ingest_one_and_reply(queue, job);
            }
        }

        // Coordination callback (off the encode path): hand the encoded sourceIDs
        // to the orchestrator so it can roll up the touched LocusKit rooms. `None`
        // when standalone. CorpusKit never reaches into LocusKit itself.
        if let Ok(guard) = self.on_encoded.lock() {
            if let Some(cb) = guard.as_ref() {
                let source_ids: Vec<String> = batch
                    .iter()
                    .filter_map(|j| IngestJob::from_job(j).ok().map(|ij| ij.source_id))
                    .collect();
                if !source_ids.is_empty() {
                    cb(&source_ids);
                }
            }
        }
        Ok(batch.len())
    }

    /// Ingest one drained job and reply terminal (the serial per-job body shared
    /// by the failure-injection path and the batch fallback). AT-LEAST-ONCE: the
    /// job is replied `Done` only AFTER ingest succeeds; a transient failure is
    /// retried in place (bounded), `ingest` being idempotent. A permanently
    /// failing or undecodable job is finally replied `Blocked`.
    fn ingest_one_and_reply(&self, queue: &IngestQueue, job: &Job) {
        let ij = match IngestJob::from_job(job) {
            Ok(ij) => ij,
            Err(_) => {
                let _ = queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
                return;
            }
        };
        if ij.text.is_empty() {
            let _ = queue.reply(&job.id, ObservationStatus::Done, vec![]);
            return;
        }
        for _attempt in 0..INGEST_MAX_ATTEMPTS {
            // Test seam: a transient failure for the named sourceID.
            #[cfg(any(test, feature = "test-seams"))]
            {
                if let Ok(guard) = self.ingest_failure_hook.lock() {
                    if let Some(hook) = guard.as_ref() {
                        if hook(&ij.source_id).is_err() {
                            continue;
                        }
                    }
                }
            }
            if self
                .ingest(&ij.text, &ij.source_id, ij.captured_at_millis())
                .is_ok()
            {
                let _ = queue.reply(&job.id, ObservationStatus::Done, vec![]);
                return;
            }
        }
        let _ = queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
    }

    // MARK: - Coordination + test seams

    /// Set (or replace) the `on_encoded` coordination callback. The orchestrator
    /// (GeniusLocusKit) installs this to roll up the touched LocusKit rooms after
    /// a batch encodes. Mirrors Swift assigning `corpus.onEncoded`.
    pub fn set_on_encoded<F>(&self, callback: F)
    where
        F: Fn(&[String]) + Send + Sync + 'static,
    {
        if let Ok(mut guard) = self.on_encoded.lock() {
            *guard = Some(Box::new(callback));
        }
    }

    /// Whether the test ingest-failure hook is armed (always `false` in
    /// production builds — the field does not exist there).
    #[cfg(any(test, feature = "test-seams"))]
    fn ingest_failure_active(&self) -> bool {
        self.ingest_failure_hook
            .lock()
            .map(|g| g.is_some())
            .unwrap_or(false)
    }

    #[cfg(not(any(test, feature = "test-seams")))]
    fn ingest_failure_active(&self) -> bool {
        false
    }

    /// Arm (or clear) the test-only ingest failure hook. Never used in
    /// production. Mirrors Swift's `_armIngestFailureHook`.
    #[cfg(any(test, feature = "test-seams"))]
    pub fn arm_ingest_failure_hook(&self, hook: Option<IngestFailureHook>) {
        if let Ok(mut guard) = self.ingest_failure_hook.lock() {
            *guard = hook;
        }
    }
}

/// Join the ingest drain worker and release the drain lease when a `Corpus` is
/// dropped. Mirrors Swift's `isolated deinit { dropIngestQueue() }`.
///
/// This handles the case where the orchestrator (GeniusLocusKit / the ARIA MCP
/// host) does not call `drop_ingest_queue()` explicitly before releasing the
/// corpus reference. In production the orchestrator does call it during
/// `close_estate`; the `Drop` impl is the safety net for edge cases (tests that
/// do not tear down cleanly, early returns, etc.).
///
/// `drop_ingest_queue` is idempotent: calling it on a corpus that was never
/// mounted, or one that was already explicitly dropped, is a no-op.
impl Drop for Corpus {
    fn drop(&mut self) {
        self.drop_ingest_queue();
    }
}

/// The foreground poll drain loop body. Each pass drains the whole available
/// encode batch via `drain_for_stream("encode")` and ingests it, then sleeps a
/// short interval before polling again. The short idle cadence is the near-
/// realtime latency floor; long enough that an idle corpus does not spin a core.
/// Exits when the stop flag is set, releasing the drain lease.
/// Mirrors Swift's `runIngestDrainLoop`.
fn run_ingest_drain_loop(
    corpus: Arc<Corpus>,
    queue: Arc<IngestQueue>,
    stop: Arc<AtomicBool>,
    lease: Option<DrainLease>,
) {
    // Publish the deferred resident index once a burst drains to empty, not per
    // pass: while jobs keep arriving the loop spin-drains (no sleep, no publish)
    // so the index is rebuilt ONCE per burst — O(N) bulk import. A single
    // steady-state capture drains in one pass, then the next empty pass publishes
    // it, so near-realtime searchability is preserved.
    let mut pending_publish = false;
    // T2 single-drainer lease bookkeeping: epoch-seconds of our last confirmed
    // hold. Refresh at most every DRAIN_LEASE_HEARTBEAT_SECS while holding (not
    // on every 15 ms pass) — well inside the lease TTL so the hold never lapses.
    // No lease (in-memory estate) → always drain.
    let mut held_lease_at: Option<f64> = None;
    // On-mount crash recovery flag (Mission #54): reclaim stale "encode" cur
    // jobs the first time we successfully acquire the lease. A prior drain
    // process that crashed mid-job leaves its claimed rows in "cur"; a
    // freshly-acquired lease proves the prior holder is dead, so every "cur"
    // row is an orphan. Reset them to "new" so this drainer re-processes them.
    // Idempotent: content-addressed ingest makes re-processing harmless.
    let mut reclaimed_on_mount = false;
    while !stop.load(Ordering::SeqCst) {
        if let Some(lease) = &lease {
            let now = wall_now_secs();
            let refresh_due = held_lease_at
                .map(|t| now - t >= DRAIN_LEASE_HEARTBEAT_SECS)
                .unwrap_or(true);
            if refresh_due {
                if lease.try_acquire(now) {
                    held_lease_at = Some(now);
                    // On-mount reclaim: first successful acquire after starting the
                    // loop means the prior holder is dead. Reclaim any cur rows it
                    // left behind. The flag guards against repeating on heartbeats.
                    if !reclaimed_on_mount {
                        reclaimed_on_mount = true;
                        let encode_stream = StreamId("encode".to_string());
                        match queue.reclaim_in_flight_for_stream(&encode_stream) {
                            Ok(n) if n > 0 => {
                                eprintln!(
                                    "mootx01 encode drain: reclaimed {} orphaned in-flight job(s) — prior drainer died mid-encode",
                                    n
                                );
                            }
                            Ok(_) => {}
                            Err(e) => {
                                eprintln!(
                                    "mootx01 encode drain: reclaim_in_flight_for_stream failed: {:?}",
                                    e
                                );
                            }
                        }
                    }
                } else {
                    // Another process holds a fresh lease — stand down as a warm
                    // standby and re-check well within the TTL so we take over
                    // promptly if it dies. (Idempotent ingest makes a rare brief
                    // two-drainer overlap during takeover harmless.)
                    held_lease_at = None;
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
            } else if let Some(held_at) = held_lease_at {
                // Heartbeat: refresh while we hold without re-acquiring.
                if now - held_at >= DRAIN_LEASE_HEARTBEAT_SECS {
                    lease.heartbeat(now);
                    held_lease_at = Some(now);
                }
            }
        }
        // Errors are non-fatal: the next pass / reindex reconciles.
        match corpus.drain_with_queue(&queue) {
            Ok(n) if n > 0 => {
                pending_publish = true;
                continue; // drain the rest of the burst before publishing
            }
            _ => {}
        }
        if pending_publish {
            let _ = corpus.publish_vector_index();
            pending_publish = false;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    // Release the lease on clean exit so another process can take over without
    // waiting out the TTL.
    if let Some(lease) = &lease {
        lease.release();
    }
}

// MARK: - IngestJob

/// The work item the corpus ingest queue carries: everything the drain needs to
/// ingest one source deterministically. Rust twin of the Swift `IngestJob`.
///
/// Simpler than GeniusLocusKit's former `EncodeJob`: the corpus encodes under
/// its own configured providers, so the payload carries only `(source_id, text,
/// captured_at)` — no estate UUID, no embedding-model tag (those were GLK
/// orchestration concerns). The serde field names match the Swift `Codable`
/// keys exactly (`sourceID`, `text`, `capturedAtISO8601`) so the JSON payload
/// byte-agrees across ports — the cross-port wire contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct IngestJob {
    /// The stable source identifier (drawer id in the GLK context), used as
    /// `source_id` for `ingest` so BM25/vector hits hydrate back to it.
    #[serde(rename = "sourceID")]
    source_id: String,
    /// The verbatim text to encode.
    text: String,
    /// The capture instant, ISO8601. Passed back into `ingest(now_millis)` so
    /// vector filing timestamps reproduce capture time, not the drain time.
    #[serde(rename = "capturedAtISO8601")]
    captured_at_iso8601: String,
}

impl IngestJob {
    /// Build an IngestJob from a source's fields. `now_millis` is the capture
    /// instant in milliseconds since epoch, encoded ISO8601 with fractional
    /// seconds so the sub-second instant round-trips exactly.
    fn new(source_id: String, text: String, now_millis: i64) -> Self {
        IngestJob {
            source_id,
            text,
            captured_at_iso8601: millis_to_iso8601(now_millis),
        }
    }

    /// The capture instant in milliseconds since epoch, decoded back from
    /// `captured_at_iso8601`, or 0 (epoch) if the stored string is unparseable
    /// (defensive — a malformed timestamp must not crash the drain).
    fn captured_at_millis(&self) -> i64 {
        iso8601_to_millis(&self.captured_at_iso8601).unwrap_or(0)
    }

    /// Encode this payload into a QueueKit `Job` ready to enqueue.
    fn to_job(&self, stream_id: StreamId, submitted_at: HLC) -> Result<Job, serde_json::Error> {
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

    /// Decode an IngestJob back from a drained QueueKit `Job`.
    fn from_job(job: &Job) -> Result<IngestJob, serde_json::Error> {
        serde_json::from_slice(&job.payload)
    }
}

/// A fresh 32-hex-char job id with no hyphens — matches `JobID.generate`'s shape
/// in QueueKit (Swift).
fn generate_job_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

// The ISO8601 helpers below mirror the Swift `ISO8601DateFormatter` with
// `.withInternetDateTime` + `.withFractionalSeconds` (UTC, millisecond
// precision). Implemented by hand (no chrono dependency — kits carry zero
// external deps beyond the approved set), using Howard Hinnant's civil-date
// algorithms. They are byte-identical to the equivalents in GeniusLocusKit's
// intake.rs; CorpusKit cannot depend on GLK (layering), so the small,
// deterministic helpers are ported here rather than shared.

/// Render milliseconds-since-epoch as `YYYY-MM-DDThh:mm:ss.sssZ`.
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

/// Parse `YYYY-MM-DDThh:mm:ss.sssZ` back to milliseconds since epoch, or `None`
/// if the string does not match that exact shape.
fn iso8601_to_millis(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() != 24
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
        || b[19] != b'.'
        || b[23] != b'Z'
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

/// Days from 1970-01-01 for a civil (y, m, d) date — Howard Hinnant.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Civil (y, m, d) from days-since-1970 — Howard Hinnant (inverse).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use queuekit::StreamId;
    use substrate_types::hlc::HLC;

    /// The IngestJob payload survives a QueueKit Job encode/decode round-trip,
    /// preserving the sourceID, text, and (sub-second) capture instant. Mirrors
    /// the Swift `ingestJobRoundTripsThroughJob`.
    #[test]
    fn ingest_job_round_trips_through_job() {
        let captured_millis = 1_700_000_000_500_i64; // .5 s past the second
        let payload = IngestJob::new(
            "drawer-123".to_string(),
            "round-trip payload text".to_string(),
            captured_millis,
        );
        let stream_id = StreamId("encode".to_string());
        let hlc = HLC { physical_time: 42, logical_count: 0, node_id: 1 };
        let job = payload.to_job(stream_id.clone(), hlc).expect("to_job");
        let decoded = IngestJob::from_job(&job).expect("from_job");

        assert_eq!(decoded.source_id, "drawer-123");
        assert_eq!(decoded.text, "round-trip payload text");
        // Capture instant round-trips exactly (millisecond precision).
        assert_eq!(decoded.captured_at_millis(), captured_millis);
        assert_eq!(job.stream_id, stream_id);
    }

    /// The IngestJob JSON keys match the Swift `Codable` property names exactly
    /// (`sourceID`, `text`, `capturedAtISO8601`) so the queue wire format
    /// byte-agrees across ports — the cross-port wire contract.
    #[test]
    fn ingest_job_json_shape_matches_swift() {
        let job = IngestJob::new("drawer-1".to_string(), "hello".to_string(), 1_700_000_000_000);
        let json: serde_json::Value =
            serde_json::from_slice(&serde_json::to_vec(&job).unwrap()).unwrap();
        assert_eq!(json["sourceID"], "drawer-1");
        assert_eq!(json["text"], "hello");
        // ISO8601 with fractional seconds and a trailing Z.
        assert_eq!(json["capturedAtISO8601"], "2023-11-14T22:13:20.000Z");
        // Exactly three keys — no estate uuid / model id (those were GLK concerns).
        assert_eq!(json.as_object().unwrap().len(), 3);
    }
}
