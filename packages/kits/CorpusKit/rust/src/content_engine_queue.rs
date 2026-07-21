//! The content-reference encode pipeline (GLK shared-content 1.1, P3).
//! Rust twin of Swift `CorpusContentEngineQueue.swift`.
//!
//! Same shared per-estate queue.sqlite, same "encode" stream, same
//! single-drainer lease + on-mount crash reclaim as the legacy pipeline —
//! but the job payload is a `ContentIndexJob` (id/revision/digest/cursor):
//! Drawer change references, never text. The drain worker resolves the
//! CURRENT text by ID from the engine's `CorpusContentSource` at work
//! time.
//!
//! Stale handling: a job whose (revision, digest) no longer matches the
//! current record is DROPPED as done — the newer revision has (or will
//! have) its own job. Other failures retry in place up to
//! `CONTENT_INGEST_MAX_ATTEMPTS`, then reply `Blocked` so the queue never
//! wedges (AT-LEAST-ONCE; `process_job` is idempotent on checkpoints).

use crate::content_engine::{ContentIndexJob, ContentIndexJobKind, CorpusContentEngine};
use crate::error::{CorpusKitError, CorpusKitResult};
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, SqliteStorage};
use queuekit::{
    DrainLease, Job, JobId, ObservationStatus, PersistenceKitBackend, QueueBackend, QueueKit,
    StreamId, DRAIN_LEASE_HEARTBEAT_SECS, wall_now_secs,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;
use substrate_types::hlc::HLCGenerator;

type ContentQueue = QueueKit<Box<dyn QueueBackend>>;

/// The encode stream id — the SAME stream the legacy pipeline used, so one
/// estate has one encode drainer regardless of engine generation.
pub fn content_encode_stream_id() -> StreamId {
    StreamId("encode".to_string())
}

/// Retry budget for a transiently-failing content index job. Mirrors Swift
/// `CorpusContentEngine.contentIngestMaxAttempts`.
pub const CONTENT_INGEST_MAX_ATTEMPTS: usize = 3;

/// Fixed store UUID for the in-memory queue backend (deterministic).
fn content_queue_store_id() -> uuid::Uuid {
    uuid::Uuid::parse_str("3D1FB0A5-52C6-4E7A-9B1B-6E1D5C0A7A42").unwrap()
}

fn drain_now() -> f64 {
    wall_now_secs()
}

/// Engine-owned queue state (mirrors the legacy `IngestQueueState`).
pub(crate) struct ContentQueueState {
    queue: Arc<ContentQueue>,
    hlc: HLCGenerator,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl CorpusContentEngine {
    /// Mount the engine's ingest queue and start its drain worker.
    /// Idempotent. SQLite estates share the encrypted sibling queue.sqlite;
    /// in-memory estates get a transient queue.
    pub fn mount_ingest_queue(self: &Arc<Self>) -> CorpusKitResult<()> {
        let mut guard = self
            .queue_state()
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("content queue lock poisoned".into()))?;
        if guard.is_some() {
            return Ok(());
        }

        let mut drain_lease: Option<DrainLease> = None;
        let backend: Box<dyn QueueBackend> = match &self.storage_ref().configuration().backend {
            BackendConfiguration::Sqlite { path, .. } => {
                let sibling_cfg = self
                    .storage_ref()
                    .configuration()
                    .queue_sibling("queue.sqlite")
                    .map_err(|e| {
                        CorpusKitError::StoreUnavailable(format!("queue_sibling: {e:?}"))
                    })?;
                let estate_dir = std::path::Path::new(path)
                    .parent()
                    .map(|p| p.to_path_buf())
                    .unwrap_or_else(|| std::path::PathBuf::from("."));
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
                let storage = Arc::new(InMemoryStorage::with_estate(content_queue_store_id()));
                PersistenceKitBackend::open_schema(storage.as_ref()).map_err(|e| {
                    CorpusKitError::StoreUnavailable(format!("content queue open_schema: {e:?}"))
                })?;
                Box::new(PersistenceKitBackend::new(storage))
            }
        };
        let queue = Arc::new(QueueKit::new(backend));

        let stop = Arc::new(AtomicBool::new(false));
        let worker_queue = Arc::clone(&queue);
        let worker_stop = Arc::clone(&stop);
        let worker_engine = Arc::clone(self);
        let handle = std::thread::Builder::new()
            .name("corpus-content-drain".to_string())
            .spawn(move || {
                run_content_drain_loop(worker_engine, worker_queue, worker_stop, drain_lease);
            })
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("content drain spawn: {e}")))?;

        *guard = Some(ContentQueueState {
            queue,
            hlc: HLCGenerator::new(1),
            stop,
            worker: Some(handle),
        });
        Ok(())
    }

    /// Tear down the queue and drain worker (set stop, join). Idempotent.
    pub fn drop_ingest_queue(&self) {
        let taken = {
            let mut guard = match self.queue_state().lock() {
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

    /// Enqueue one content change reference. Mounts on demand.
    pub fn enqueue_change(
        self: &Arc<Self>,
        job: &ContentIndexJob,
        captured_at_millis: i64,
    ) -> CorpusKitResult<()> {
        self.enqueue_change_batch(&[(job.clone(), captured_at_millis)])
    }

    /// Enqueue many change references in ONE backend transaction.
    pub fn enqueue_change_batch(
        self: &Arc<Self>,
        items: &[(ContentIndexJob, i64)],
    ) -> CorpusKitResult<()> {
        if items.is_empty() {
            return Ok(());
        }
        let mounted = self
            .queue_state()
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("content queue lock poisoned".into()))?
            .is_some();
        if !mounted {
            self.mount_ingest_queue()?;
        }
        let mut guard = self
            .queue_state()
            .lock()
            .map_err(|_| CorpusKitError::StoreUnavailable("content queue lock poisoned".into()))?;
        let state = match guard.as_mut() {
            Some(s) => s,
            None => return Ok(()),
        };
        let mut jobs = Vec::with_capacity(items.len());
        for (payload, captured_at_millis) in items {
            let submitted_at = state.hlc.send(*captured_at_millis);
            let bytes = serde_json::to_vec(payload).map_err(|e| {
                CorpusKitError::StoreUnavailable(format!("content job encode: {e}"))
            })?;
            jobs.push(Job {
                id: JobId(uuid::Uuid::new_v4().simple().to_string()),
                stream_id: content_encode_stream_id(),
                submitted_at,
                priority: 50,
                payload: bytes,
                extensions: serde_json::Map::new(),
            });
        }
        state
            .queue
            .send_batch(&jobs)
            .map(|_| ())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("content enqueue batch: {e:?}")))
    }

    /// Block until the encode stream fully drains, then publish the resident
    /// vector index.
    pub fn await_ingest_drain(&self) -> CorpusKitResult<()> {
        let queue = {
            let guard = self.queue_state().lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("content queue lock poisoned".into())
            })?;
            match guard.as_ref() {
                Some(s) => Arc::clone(&s.queue),
                None => return Ok(()),
            }
        };
        queue
            .await_drain_for_stream(
                &content_encode_stream_id(),
                Duration::from_millis(50),
                Duration::from_secs(30),
            )
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("content drain await: {e:?}")))?;
        self.publish_vector_index()
    }

    /// The encode drain's outstanding work: (pending, in_flight),
    /// stream-scoped.
    pub fn ingest_queue_depth(&self) -> CorpusKitResult<(usize, usize)> {
        let queue = {
            let guard = self.queue_state().lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("content queue lock poisoned".into())
            })?;
            match guard.as_ref() {
                Some(s) => Arc::clone(&s.queue),
                None => return Ok((0, 0)),
            }
        };
        let pending = queue
            .pending_count_for_stream(&content_encode_stream_id())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("content depth: {e:?}")))?;
        let in_flight = queue
            .in_flight()
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("content in_flight: {e:?}")))?
            .into_iter()
            .filter(|j| j.stream_id == content_encode_stream_id())
            .count();
        Ok((pending, in_flight))
    }

    /// Drain the encode stream once: claim available jobs, process each,
    /// fire `on_encoded` with the affected content IDs. Returns the count.
    pub fn drain_content_queue_once(&self) -> CorpusKitResult<usize> {
        let queue = {
            let guard = self.queue_state().lock().map_err(|_| {
                CorpusKitError::StoreUnavailable("content queue lock poisoned".into())
            })?;
            match guard.as_ref() {
                Some(s) => Arc::clone(&s.queue),
                None => return Ok(0),
            }
        };
        self.drain_content_with_queue(&queue)
    }

    fn drain_content_with_queue(&self, queue: &ContentQueue) -> CorpusKitResult<usize> {
        let claimed = queue
            .drain_for_stream(&content_encode_stream_id(), drain_now())
            .map_err(|e| CorpusKitError::StoreUnavailable(format!("content drain: {e:?}")))?;
        if claimed.is_empty() {
            return Ok(0);
        }
        let batch: Vec<Job> = claimed.into_iter().map(|(job, _session)| job).collect();

        // One resident-index rebuild per burst.
        self.begin_deferred_vector_index()?;

        let mut encoded_ids: Vec<String> = Vec::new();
        for job in &batch {
            let payload: ContentIndexJob = match serde_json::from_slice(&job.payload) {
                Ok(p) => p,
                Err(_) => {
                    let _ = queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
                    continue;
                }
            };
            // The work instant: the submission HLC physical time (the capture
            // instant) — deterministic, no clock read in the engine.
            let work_now = job.submitted_at.physical_time;
            let mut replied = false;
            for _attempt in 0..CONTENT_INGEST_MAX_ATTEMPTS {
                // Test seam: simulated transient failure for the named ID.
                if let Err(_e) = self.fire_ingest_failure_hook(&payload.content_id) {
                    continue;
                }
                match self.process_job(&payload, work_now) {
                    Ok(()) => {
                        if payload.kind == ContentIndexJobKind::Upsert {
                            encoded_ids.push(payload.content_id.clone());
                        }
                        let _ = queue.reply(&job.id, ObservationStatus::Done, vec![]);
                        replied = true;
                        break;
                    }
                    Err(CorpusKitError::StaleRevision(_)) => {
                        // Obsolete by design — done, not blocked.
                        let _ = queue.reply(&job.id, ObservationStatus::Done, vec![]);
                        replied = true;
                        break;
                    }
                    Err(e) => {
                        eprintln!(
                            "CorpusKit: content index attempt failed for {}: {e:?}",
                            payload.content_id
                        );
                    }
                }
            }
            if !replied {
                let _ = queue.reply(&job.id, ObservationStatus::Blocked, vec![]);
            }
        }

        if !encoded_ids.is_empty() {
            self.fire_on_encoded(&encoded_ids);
        }
        Ok(batch.len())
    }
}

fn run_content_drain_loop(
    engine: Arc<CorpusContentEngine>,
    queue: Arc<ContentQueue>,
    stop: Arc<AtomicBool>,
    lease: Option<DrainLease>,
) {
    let mut pending_publish = false;
    let mut held_lease_at: Option<f64> = None;
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
                    if !reclaimed_on_mount {
                        reclaimed_on_mount = true;
                        match queue.reclaim_in_flight_for_stream(&content_encode_stream_id()) {
                            Ok(n) if n > 0 => {
                                eprintln!(
                                    "mootx01 content drain: reclaimed {n} orphaned in-flight job(s)"
                                );
                            }
                            Ok(_) => {}
                            Err(e) => {
                                eprintln!(
                                    "mootx01 content drain: reclaim_in_flight_for_stream failed: {e:?}"
                                );
                            }
                        }
                    }
                } else {
                    held_lease_at = None;
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
            } else if let Some(held) = held_lease_at {
                if wall_now_secs() - held >= DRAIN_LEASE_HEARTBEAT_SECS {
                    lease.heartbeat(wall_now_secs());
                    held_lease_at = Some(wall_now_secs());
                }
            }
        }
        match engine.drain_content_with_queue(&queue) {
            Ok(n) if n > 0 => {
                pending_publish = true;
                continue;
            }
            Ok(_) => {
                if pending_publish {
                    let _ = engine.publish_vector_index();
                    pending_publish = false;
                }
            }
            Err(e) => {
                eprintln!("mootx01 content drain loop error: {e:?}");
            }
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}
