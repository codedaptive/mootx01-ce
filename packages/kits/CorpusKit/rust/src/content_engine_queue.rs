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
use crate::index_state_store::CorpusIndexState;
use persistence_kit::inmemory::InMemoryStorage;
use persistence_kit::{BackendConfiguration, SqliteStorage};
use queuekit::{
    wall_now_secs, DrainLease, Job, JobId, ObservationStatus, PersistenceKitBackend, QueueBackend,
    QueueKit, StreamId, DRAIN_LEASE_HEARTBEAT_SECS,
};
use std::collections::HashSet;
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

        // Three-state auto-train (Kinsta-fix): once per batch, before per-document
        // work. Mirrors Swift `drainIndexBatch` Phase 0 `batchTrainIfNeeded`.
        // Prevents a degenerate rank-1 basis from freezing when the queue drain
        // fires per-document (impatient inline encoding path).
        let batch_now_millis = (drain_now() * 1000.0) as i64;
        self.batch_train_if_needed(batch_now_millis)?;

        // Pre-scan upsert jobs and batch-fetch all source records in one WHERE…IN
        // query instead of N serial source.record calls (Cause 4 fix). Over-
        // fetching (stale/deduped jobs) is harmless — unused entries are ignored.
        let mut seen_pre_ids = std::collections::HashSet::new();
        let upsert_ids: Vec<String> = batch
            .iter()
            .filter_map(|job| {
                let Ok(payload) = serde_json::from_slice::<ContentIndexJob>(&job.payload) else {
                    return None;
                };
                if payload.kind == ContentIndexJobKind::Upsert
                    && seen_pre_ids.insert(payload.content_id.clone())
                {
                    Some(payload.content_id)
                } else {
                    None
                }
            })
            .collect();
        // Convert owned Strings to &str slices for the batch fetch.
        let upsert_id_refs: Vec<&str> = upsert_ids.iter().map(|s| s.as_ref()).collect();
        let source_records = self.source_records_for(&upsert_id_refs)?;

        let mut encoded_ids: Vec<String> = Vec::new();
        let mut completions: Vec<(JobId, ObservationStatus)> = Vec::with_capacity(batch.len());
        let mut counts_updates: Vec<(String, i64, String, String)> = Vec::new();
        let mut checkpoints: Vec<CorpusIndexState> = Vec::new();
        let mut prepared_upserts: HashSet<(String, i64, String)> = HashSet::new();
        for job in &batch {
            let payload: ContentIndexJob = match serde_json::from_slice(&job.payload) {
                Ok(p) => p,
                Err(_) => {
                    completions.push((job.id.clone(), ObservationStatus::Blocked));
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
                let upsert_key = payload
                    .digest
                    .as_ref()
                    .map(|digest| (payload.content_id.clone(), payload.revision, digest.clone()));
                let content_already_prepared = upsert_key
                    .as_ref()
                    .map(|key| prepared_upserts.contains(key))
                    .unwrap_or(false);
                let prefetched = source_records.get(payload.content_id.as_str()).cloned();
                match self.prepare_queue_job(&payload, work_now, content_already_prepared, prefetched) {
                    Ok((job_checkpoints, job_counts_update)) => {
                        if payload.kind == ContentIndexJobKind::Upsert {
                            encoded_ids.push(payload.content_id.clone());
                        } else {
                            // Preserve queue order inside the deferred
                            // checkpoint set: a later remove cancels an
                            // earlier prepared upsert for the same content.
                            checkpoints
                                .retain(|checkpoint| checkpoint.content_id != payload.content_id);
                            prepared_upserts
                                .retain(|(content_id, _, _)| content_id != &payload.content_id);
                            counts_updates
                                .retain(|(content_id, _, _, _)| content_id != &payload.content_id);
                        }
                        if let Some(update) = job_counts_update {
                            counts_updates.push(update);
                        }
                        checkpoints.extend(job_checkpoints);
                        if let Some(key) = upsert_key {
                            prepared_upserts.insert(key);
                        }
                        completions.push((job.id.clone(), ObservationStatus::Done));
                        replied = true;
                        break;
                    }
                    Err(CorpusKitError::StaleRevision(_)) => {
                        // Obsolete by design — done, not blocked.
                        completions.push((job.id.clone(), ObservationStatus::Done));
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
                completions.push((job.id.clone(), ObservationStatus::Blocked));
            }
        }

        // Batch-boundary last write: maintained counts and the checkpoints
        // proving those folds are committed atomically (never per record —
        // that was O(N·vocab) write amplification). It MUST precede terminal
        // queue completion so any failure leaves recoverable references.
        if let Err(error) =
            self.commit_queue_batch(&checkpoints, &counts_updates, drain_now() as i64 * 1000)
        {
            return Err(match self.publish_vector_index() {
                Ok(()) => error,
                Err(publication_error) => CorpusKitError::StoreUnavailable(format!(
                    "{error:?}; resident-index publication after queue commit failure: \
                     {publication_error:?}"
                )),
            });
        }
        if let Err(error) = queue.reply_batch(&completions) {
            let error = CorpusKitError::StoreUnavailable(format!("content reply batch: {error:?}"));
            return Err(match self.publish_vector_index() {
                Ok(()) => error,
                Err(publication_error) => CorpusKitError::StoreUnavailable(format!(
                    "{error:?}; resident-index publication after queue completion failure: \
                     {publication_error:?}"
                )),
            });
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
                    match engine.publish_vector_index() {
                        Ok(()) => pending_publish = false,
                        Err(e) => {
                            // Keep the publication pending. The next idle pass
                            // retries instead of silently declaring the burst
                            // published after a transient storage failure.
                            eprintln!("mootx01 content resident-index publish failed: {e:?}");
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("mootx01 content drain loop error: {e:?}");
            }
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        content::CorpusContentStore, CorpusContentChange, CorpusContentConfiguration,
        CorpusDocumentStore, CorpusIndexUnitPolicy, CorpusOperatingMode, EmbeddingModelConfig,
    };
    use persistence_kit::Storage;
    use queuekit::backend::WatchHandler;
    use queuekit::{ArtifactRef, QueueError, SessionId, StreamId};
    use std::any::Any;

    struct FailCompleteBackend {
        inner: PersistenceKitBackend,
    }

    #[derive(Clone, Default)]
    struct RetryCountsProvider {
        documents: u64,
    }

    impl vectorkit::EmbeddingProvider for RetryCountsProvider {
        fn model_id(&self) -> &str {
            "retry-counts-v1"
        }

        fn model_version(&self) -> &str {
            "1.0.0"
        }

        fn embed(&self, _text: &str) -> Result<engram_lib::Engram, vectorkit::VectorKitError> {
            Ok(engram_lib::Engram::ZERO)
        }

        fn embed_float(&self, _text: &str) -> Result<Vec<f32>, vectorkit::VectorKitError> {
            Ok(vec![1.0])
        }
    }

    impl crate::TrainableEmbeddingBasis for RetryCountsProvider {
        fn train_on_corpus(&mut self, texts: &[&str]) {
            self.documents += texts.len() as u64;
        }

        fn accumulate_training(&mut self, texts: &[&str]) {
            self.documents += texts.len() as u64;
        }

        fn finalize_training(&mut self) {}

        fn serialize_basis(&self) -> Vec<u8> {
            self.documents.to_le_bytes().to_vec()
        }

        fn reconstruct_basis(
            &self,
            basis: &[u8],
        ) -> Result<Box<dyn vectorkit::EmbeddingProvider>, CorpusKitError> {
            Ok(Box::new(Self::from_bytes(basis)?))
        }

        fn release_basis(&mut self) {}

        fn reconstruct_trainable_basis(
            &self,
            basis: &[u8],
        ) -> Result<Box<dyn crate::TrainableEmbeddingBasis>, CorpusKitError> {
            Ok(Box::new(Self::from_bytes(basis)?))
        }

        fn add_to_counts(&mut self, _text: &str) {
            self.documents += 1;
        }

        fn serialize_counts(&self) -> Vec<u8> {
            self.documents.to_le_bytes().to_vec()
        }

        fn restore_counts(&mut self, bytes: &[u8]) -> Result<(), CorpusKitError> {
            *self = Self::from_bytes(bytes)?;
            Ok(())
        }

        fn counts_vocabulary_size(&self) -> usize {
            self.documents as usize
        }
    }

    impl RetryCountsProvider {
        fn from_bytes(bytes: &[u8]) -> Result<Self, CorpusKitError> {
            let raw: [u8; 8] = bytes
                .try_into()
                .map_err(|_| CorpusKitError::DecodingFailure("retry-counts fixture".to_string()))?;
            Ok(Self {
                documents: u64::from_le_bytes(raw),
            })
        }
    }

    impl QueueBackend for FailCompleteBackend {
        fn write(&self, job: &Job) -> Result<(), QueueError> {
            self.inner.write(job)
        }

        fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError> {
            self.inner.drain_available()
        }

        fn complete(
            &self,
            _job_id: &JobId,
            _status: ObservationStatus,
            _artifacts: Vec<ArtifactRef>,
        ) -> Result<(), QueueError> {
            Err(QueueError::BackendUnavailable(
                "injected terminal completion failure".to_string(),
            ))
        }

        fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
            self.inner.in_flight()
        }

        fn completed(&self, stream: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
            self.inner.completed(stream)
        }

        fn pending_count(&self) -> Result<usize, QueueError> {
            self.inner.pending_count()
        }

        fn drain_available_for_stream(
            &self,
            stream: &StreamId,
        ) -> Result<Vec<(Job, SessionId)>, QueueError> {
            self.inner.drain_available_for_stream(stream)
        }

        fn pending_count_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError> {
            self.inner.pending_count_for_stream(stream)
        }

        fn watch(&self, handler: WatchHandler) -> Result<(), QueueError> {
            self.inner.watch(handler)
        }

        fn as_any(&self) -> &dyn Any {
            self
        }
    }

    #[test]
    fn terminal_completion_error_propagates_and_leaves_reference_recoverable() {
        let storage: Arc<dyn Storage> =
            Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
        storage
            .migrate(&crate::standalone_declaration(false))
            .expect("content schema");
        let source = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
        let record = source
            .put("completion failure remains durable", "drawer-reply", 10)
            .expect("put source");
        let engine = CorpusContentEngine::open(
            Arc::clone(&storage),
            CorpusContentConfiguration::new(
                CorpusOperatingMode::Standalone,
                CorpusIndexUnitPolicy::WholeContent,
            )
            .expect("configuration"),
            Arc::clone(&source) as Arc<dyn crate::CorpusContentSource>,
            vec![EmbeddingModelConfig::Deterministic],
        )
        .expect("engine");

        let queue_storage: Arc<dyn Storage> =
            Arc::new(InMemoryStorage::with_estate(uuid::Uuid::new_v4()));
        PersistenceKitBackend::open_schema(queue_storage.as_ref()).expect("queue schema");
        let backend: Box<dyn QueueBackend> = Box::new(FailCompleteBackend {
            inner: PersistenceKitBackend::new(queue_storage),
        });
        let queue = QueueKit::new(backend);
        let payload = ContentIndexJob::from_change(
            &CorpusContentChange::Upsert {
                id: record.id,
                revision: record.revision,
                digest: record.digest,
            },
            Some("cursor-1".to_string()),
        );
        queue
            .send(&Job {
                id: JobId("reply-failure-job".to_string()),
                stream_id: content_encode_stream_id(),
                submitted_at: queuekit::HLC {
                    physical_time: 10,
                    logical_count: 0,
                    node_id: 1,
                },
                priority: 50,
                payload: serde_json::to_vec(&payload).expect("payload"),
                extensions: serde_json::Map::new(),
            })
            .expect("enqueue");

        let error = engine
            .drain_content_with_queue(&queue)
            .expect_err("terminal completion failure must surface");
        assert!(format!("{error:?}").contains("content reply batch"));
        assert_eq!(queue.in_flight().expect("in-flight").len(), 1);
        assert!(engine
            .float_nearest_per_signal("completion failure remains durable", 5)
            .iter()
            .any(|(model_id, outcome)| {
                model_id == "corpus-deterministic-v1"
                    && matches!(outcome, crate::FloatLaneOutcome::Hits(hits) if !hits.is_empty())
            }));
    }

    #[test]
    fn failed_last_write_does_not_double_fold_counts_on_retry() {
        use crate::corpus_provider_counts_store::CorpusProviderCountsStore;
        use persistence_kit::{EstateConfiguration, Storage};

        let path = std::env::temp_dir().join(format!(
            "corpus-content-counts-retry-{}.sqlite3",
            uuid::Uuid::new_v4()
        ));
        let path_string = path.to_string_lossy().into_owned();
        let storage: Arc<dyn Storage> = Arc::new(
            SqliteStorage::new(EstateConfiguration::new(
                uuid::Uuid::new_v4(),
                BackendConfiguration::Sqlite {
                    path: path_string.clone(),
                    busy_timeout_secs: 0.05,
                },
            ))
            .expect("open sqlite"),
        );
        storage
            .migrate(&crate::standalone_declaration(false))
            .expect("content schema");
        let source = Arc::new(CorpusDocumentStore::new(Arc::clone(&storage)));
        source
            .put("initial training vocabulary", "drawer-anchor", 10)
            .expect("put anchor");
        let engine = CorpusContentEngine::open(
            Arc::clone(&storage),
            CorpusContentConfiguration::new(
                CorpusOperatingMode::Standalone,
                CorpusIndexUnitPolicy::WholeContent,
            )
            .expect("configuration"),
            Arc::clone(&source) as Arc<dyn crate::CorpusContentSource>,
            vec![EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(RetryCountsProvider::default()),
            }],
        )
        .expect("engine");
        engine
            .train_trainable_slots(10, false)
            .expect("train anchor");

        let record = source
            .put("retry must fold this document once", "drawer-retry", 11)
            .expect("put retry record");
        let job = ContentIndexJob::from_change(
            &CorpusContentChange::Upsert {
                id: record.id,
                revision: record.revision,
                digest: record.digest,
            },
            Some("retry-cursor".to_string()),
        );
        let (first_checkpoints, first_counts) = engine
            .prepare_queue_job(&job, 11, false, None)
            .expect("prepare first attempt");
        let first_counts = vec![first_counts.expect("first counts update")];

        // Hold the SQLite writer lock across the last-write transaction. The
        // derived rows are already present, but neither counts nor checkpoints
        // can commit; the durable reference would therefore be retried.
        let blocker = rusqlite::Connection::open(&path_string).expect("open blocker");
        blocker
            .execute_batch("BEGIN EXCLUSIVE")
            .expect("hold writer lock");
        engine
            .commit_queue_batch(&first_checkpoints, &first_counts, 11)
            .expect_err("last-write must surface SQLITE_BUSY");
        blocker
            .execute_batch("ROLLBACK")
            .expect("release writer lock");

        let (retry_checkpoints, retry_counts) = engine
            .prepare_queue_job(&job, 12, false, None)
            .expect("prepare retry");
        let retry_counts = vec![retry_counts.expect("retry counts update")];
        engine
            .commit_queue_batch(&retry_checkpoints, &retry_counts, 12)
            .expect("commit retry");

        let persisted = CorpusProviderCountsStore::new(Arc::clone(&storage))
            .load("retry-counts-v1", "1.0.0")
            .expect("load counts")
            .expect("counts row");
        assert_eq!(
            persisted.document_count, 2,
            "the anchor columns advance transactionally; the base blob stays compact"
        );
        let references: Vec<_> = CorpusProviderCountsStore::new(Arc::clone(&storage))
            .references("retry-counts-v1", "1.0.0")
            .expect("load references")
            .into_iter()
            .filter(|reference| !reference.is_subsumed)
            .collect();
        assert_eq!(references.len(), 1, "retry must persist one exact delta");
        assert_eq!(engine.maintained_document_count(), 2);
        drop(engine);
        let reopened = CorpusContentEngine::open(
            Arc::clone(&storage),
            CorpusContentConfiguration::new(
                CorpusOperatingMode::Standalone,
                CorpusIndexUnitPolicy::WholeContent,
            )
            .expect("configuration"),
            Arc::clone(&source) as Arc<dyn crate::CorpusContentSource>,
            vec![EmbeddingModelConfig::RandomIndexing {
                provider: Box::new(RetryCountsProvider::default()),
            }],
        )
        .expect("reopen engine");
        assert_eq!(
            reopened.maintained_document_count(),
            2,
            "reopen must replay the durable reference exactly once"
        );
        reopened
            .train_trainable_slots(13, true)
            .expect("provider publication compacts reference deltas");
        let compacted_references = CorpusProviderCountsStore::new(Arc::clone(&storage))
            .references("retry-counts-v1", "1.0.0")
            .expect("load compacted references");
        assert!(
            compacted_references
                .iter()
                .all(|reference| reference.is_subsumed),
            "published base must subsume every ordinary delta; only a pending-admission marker may remain"
        );
        let compacted = CorpusProviderCountsStore::new(Arc::clone(&storage))
            .load("retry-counts-v1", "1.0.0")
            .expect("load compacted counts")
            .expect("compacted counts row");
        assert_eq!(compacted.document_count, 2);
        assert_eq!(reopened.maintained_document_count(), 2);
        drop(reopened);
        drop(source);
        drop(storage);
        let _ = std::fs::remove_file(&path);
    }
}
