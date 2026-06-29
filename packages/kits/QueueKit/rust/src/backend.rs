// QueueBackend trait per QUEUEKIT_SPEC §4.

use crate::error::QueueError;
use crate::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};
use std::any::Any;
use std::time::{Duration, Instant};

/// The `watch` handler, as a boxed closure rather than a generic type parameter.
/// A boxed (non-generic) handler is what keeps `QueueBackend` dyn-compatible, so
/// a backend can be held behind `Box<dyn QueueBackend>` and driven through the
/// `QueueKit` facade — mirroring Swift, whose `watch` takes a closure-typed
/// parameter (not a generic) and whose `any QueueBackend` is held by the facade.
pub type WatchHandler = Box<dyn Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync>;

pub trait QueueBackend: Send + Sync {
    fn write(&self, job: &Job) -> Result<(), QueueError>;

    /// Enqueue many jobs in one pass — the batch twin of `write`, for a bulk
    /// producer (e.g. the post-import reindex enqueuing tens of thousands of
    /// encode jobs). FilesystemBackend's per-job `write` fsyncs each file and the
    /// `new/` directory; over a bulk enqueue that serial-fsyncs a full core. The
    /// default loops `write` (correct for every backend); FilesystemBackend
    /// overrides it to write all files and fsync `new/` ONCE. This is a SEPARATE
    /// method, so the per-job `write` keeps its per-job durability for streaming
    /// capture — only the bulk caller, whose jobs are reconstructable from the
    /// estate (re-derived by reindex on the next resume), opts into the relaxed
    /// batched barrier.
    fn write_batch(&self, jobs: &[Job]) -> Result<usize, QueueError> {
        let mut written = 0usize;
        for job in jobs {
            self.write(job)?;
            written += 1;
        }
        Ok(written)
    }

    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError>;
    fn complete(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError>;

    /// Complete many in-flight jobs in one pass — the batch twin of `complete`.
    ///
    /// Retires a whole drained batch without the per-job overhead `complete`
    /// pays: FilesystemBackend's per-job `complete` does a full `read_dir(cur/)`
    /// scan to locate each job's file (O(N²) over a batch) and an fsync per job.
    /// The default loops `complete` (correct for every backend, including
    /// PersistenceKit, which has no directory to scan); FilesystemBackend
    /// overrides it with one `cur/` scan and a single batched durability barrier.
    /// Completions carry no artifacts — a drain replies terminal with none.
    fn complete_batch(
        &self,
        completions: &[(JobId, ObservationStatus)],
    ) -> Result<usize, QueueError> {
        let mut completed = 0usize;
        for (job_id, status) in completions {
            self.complete(job_id, *status, Vec::new())?;
            completed += 1;
        }
        Ok(completed)
    }

    fn in_flight(&self) -> Result<Vec<Job>, QueueError>;
    fn completed(&self, stream_id: Option<&StreamId>)
        -> Result<Vec<Job>, QueueError>;

    /// Count jobs in the `new/` frontier — pending, not yet claimed.
    ///
    /// A single depth read that does not advance the cursor (no claim). Swift
    /// parity: `QueueBackend.pendingCount()`. Used by `await_drain` to detect an
    /// empty `new/` frontier, and available to telemetry as a depth probe.
    ///
    /// Required, no default: an SDK backend that forgets the probe must fail to
    /// COMPILE rather than at runtime. Every conforming backend implements it.
    fn pending_count(&self) -> Result<usize, QueueError>;

    // ── Stream-scoped drain (ADR-021 Decision 7 / T1) ──────────────────────

    /// Claim and return only the pending jobs that belong to `stream`.
    ///
    /// Allows multiple consumers (encode, dreaming, signals) to share one
    /// per-estate queue without stealing each other's jobs. The
    /// `(stream_id, status)` index makes the predicated claim cheap on the PK
    /// backend; the Filesystem backend filters by decoding each `new/` file and
    /// matching `job.stream_id`. Backends that host a single stream may leave
    /// the default: it delegates to `drain_available()` then filters results —
    /// correct when only one stream is present. Swift twin:
    /// `QueueBackend.drainAvailable(stream:)`.
    fn drain_available_for_stream(
        &self,
        stream: &StreamId,
    ) -> Result<Vec<(Job, SessionId)>, QueueError> {
        // Default: delegate to all-streams drain and filter. Concrete backends
        // MUST override this to avoid cross-stream claiming in multi-stream
        // deployments (the default claims ALL new jobs and drops non-matching ones,
        // which is incorrect in a shared queue).
        let all = self.drain_available()?;
        Ok(all.into_iter().filter(|(j, _)| &j.stream_id == stream).collect())
    }

    /// Count pending jobs (status = "new") belonging to `stream` only.
    ///
    /// Safe for single-stream backends; PersistenceKitBackend and
    /// FilesystemBackend override with an exact per-stream count. The default
    /// delegates to `pending_count()` (conservative: may over-count in
    /// multi-stream queues). Swift twin: `QueueBackend.pendingCount(stream:)`.
    fn pending_count_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError> {
        let _ = stream;
        self.pending_count()
    }

    /// Block until the queue has no pending and no in-flight work, then return.
    ///
    /// "Empty" means both frontiers are clear: `pending_count() == 0` (nothing
    /// waiting in `new/` to be claimed) AND `in_flight().is_empty()` (nothing
    /// claimed-but-not-yet-completed in `cur/`). A job is off both frontiers
    /// only once a consumer has drained it and called `complete(...)`, which
    /// moves it to `done/`. So this latch returns only after every enqueued job
    /// has been fully processed by a drain worker — the signal a bulk caller
    /// needs before it issues a recall. Swift parity: `QueueKit.awaitDrain`.
    ///
    /// Returns PROMPTLY when the queue is already empty: the first poll sees
    /// zero on both frontiers and returns without sleeping. It does not hang on
    /// an empty queue.
    ///
    /// Polling, not a push latch: neither maildir nor the SQLite backend has a
    /// native completion event, so this polls the two depth probes on a fixed
    /// cadence. A drain worker running concurrently makes progress between
    /// polls; each poll re-reads the live frontier counts so that progress is
    /// observed on the next tick.
    ///
    /// `Instant`-based deadline (not an injected engine clock): this is a
    /// wall-clock wait latch, NOT a deterministic engine — exactly as the Swift
    /// twin uses `ContinuousClock.now` internally rather than an injected `now`.
    /// The determinism rule (pass `now` in) applies to computation engines, not
    /// to a real-time await primitive whose entire job is to wait on wall time.
    ///
    /// - Parameters:
    ///   - `poll_interval`: Sleep between frontier polls. 20 ms in Swift — short
    ///     enough that the latch releases promptly after the last `complete`,
    ///     long enough that the poll loop does not spin a core.
    ///   - `timeout`: Upper bound on total wait. 30 s in Swift. If both frontiers
    ///     have not cleared by then, returns `QueueError::DrainTimeout` rather
    ///     than blocking forever — a stuck drain worker surfaces as an error,
    ///     never a hang.
    /// - Returns: `Ok(())` once both frontiers clear; `Err(DrainTimeout {..})`
    ///   on timeout; any backend error from the frontier probes.
    fn await_drain(
        &self,
        poll_interval: Duration,
        timeout: Duration,
    ) -> Result<(), QueueError> {
        let deadline = Instant::now() + timeout;
        loop {
            // Re-read both frontiers each iteration so concurrent drain-worker
            // progress (a job moving new/ → cur/ → done/) is observed live.
            let pending = self.pending_count()?;
            let in_flight = self.in_flight()?.len();
            if pending == 0 && in_flight == 0 {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(QueueError::DrainTimeout { pending, in_flight });
            }
            std::thread::sleep(poll_interval);
        }
    }

    /// Block until `stream` has no pending and no in-flight work.
    ///
    /// Stream-scoped twin of `await_drain` (ADR-021 Decision 7 / T1). On the
    /// shared per-estate `queue.sqlite` a single drainer (e.g. the encode pump)
    /// only processes its own stream; the global `await_drain` would block
    /// forever on OTHER streams' jobs (e.g. `dreaming` enqueued on recall) that
    /// this drainer never claims. The barrier must therefore be stream-scoped,
    /// exactly as `drain_for_stream` scopes the claim. Default impl polls
    /// `pending_count_for_stream` plus the stream's slice of `in_flight`; both
    /// backends carry `stream_id` on every job so the filter is exact. Swift
    /// twin: `QueueKit.awaitDrain(stream:pollInterval:timeout:)`.
    fn await_drain_for_stream(
        &self,
        stream: &StreamId,
        poll_interval: Duration,
        timeout: Duration,
    ) -> Result<(), QueueError> {
        let deadline = Instant::now() + timeout;
        loop {
            // Re-read both frontiers each iteration so concurrent drain-worker
            // progress is observed live. Count only THIS stream's jobs.
            let pending = self.pending_count_for_stream(stream)?;
            let in_flight = self
                .in_flight()?
                .iter()
                .filter(|j| &j.stream_id == stream)
                .count();
            if pending == 0 && in_flight == 0 {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(QueueError::DrainTimeout { pending, in_flight });
            }
            std::thread::sleep(poll_interval);
        }
    }

    /// Watch for arriving jobs. Calls `handler` on each (Job, SessionId)
    /// pair as jobs become available. Blocks the calling thread until
    /// `handler` returns an error or until the watcher encounters a
    /// fatal error. Conforms to QUEUEKIT_SPEC §3 watch() semantics.
    ///
    /// Required, no default: an SDK backend that forgets `watch()` must fail to
    /// COMPILE rather than at runtime. Every conforming backend implements it.
    fn watch(&self, handler: WatchHandler) -> Result<(), QueueError>;

    /// Downcast hook so a facade can specialise on a concrete backend — the Rust
    /// translation of Swift's `backend as? PersistenceKitBackend`. Used by
    /// `QueueKit::reply(session:)` to take the PersistenceKit batch fast path when
    /// available, falling back to per-job completion otherwise.
    fn as_any(&self) -> &dyn Any;
}

/// Blanket forwarding impl so a boxed backend is itself a `QueueBackend`. This is
/// what lets the `QueueKit<B>` facade be parameterised as
/// `QueueKit<Box<dyn QueueBackend>>` and hold EITHER concrete backend behind one
/// type — the Rust equivalent of Swift's facade holding `any QueueBackend`.
/// `as_any` forwards to the inner concrete backend (not the box) so the facade's
/// downcast resolves to `PersistenceKitBackend`, not `Box<…>`.
impl QueueBackend for Box<dyn QueueBackend> {
    fn write(&self, job: &Job) -> Result<(), QueueError> {
        (**self).write(job)
    }
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError> {
        (**self).drain_available()
    }
    fn complete(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError> {
        (**self).complete(job_id, status, artifacts)
    }
    fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
        (**self).in_flight()
    }
    fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        (**self).completed(stream_id)
    }
    fn pending_count(&self) -> Result<usize, QueueError> {
        (**self).pending_count()
    }
    fn drain_available_for_stream(
        &self,
        stream: &StreamId,
    ) -> Result<Vec<(Job, SessionId)>, QueueError> {
        (**self).drain_available_for_stream(stream)
    }
    fn pending_count_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError> {
        (**self).pending_count_for_stream(stream)
    }
    fn watch(&self, handler: WatchHandler) -> Result<(), QueueError> {
        (**self).watch(handler)
    }
    fn as_any(&self) -> &dyn Any {
        (**self).as_any()
    }
}
