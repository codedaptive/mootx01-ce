// QueueKit facade per QUEUEKIT_SPEC §3.
//
// Four permanent method names (send, drain, watch, reply) that delegate
// to a mounted backend. drain() emits queue.* telemetry via IntellectusLib
// matching the Swift QueueKit.drain() metric surface exactly.
//
// Metric namespace: queue.*
//   queue.depth              — pending job count at snapshot time
//   queue.depth_unavailable  — 1.0 when pending_count errors (gap sentinel)
//   queue.drain_count        — jobs claimed in the last drain call
//   queue.idle_nonempty      — 1.0 when depth>0 but drain returned 0
//   queue.latency_p50_ms     — median drain latency (ms) over recent window
//   queue.latency_p95_ms     — 95th-pct drain latency (ms) over recent window
//   queue.head_of_line_age_s — age of oldest pending/drained job (seconds);
//                              0.0 sentinel when depth>0 but age is unknown

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use intellectus_lib::{Intellectus, StatSample};

use crate::backend::QueueBackend;
use crate::error::QueueError;
use crate::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};
#[cfg(feature = "persistencekit")]
use crate::persistencekit::PersistenceKitBackend;

/// Rolling latency window for drain percentile telemetry.
/// Mirrors Swift's `QueueLatencyWindow`.
pub struct QueueLatencyWindow {
    samples: Vec<f64>,
    capacity: usize,
}

impl QueueLatencyWindow {
    pub fn new(capacity: usize) -> Self {
        QueueLatencyWindow {
            samples: Vec::with_capacity(capacity),
            capacity,
        }
    }

    pub fn append(&mut self, ms: f64) {
        self.samples.push(ms);
        if self.samples.len() > self.capacity {
            self.samples.remove(0);
        }
    }

    /// Returns the p-th percentile (0–100) of the current window.
    /// Returns 0 when empty or when `p` is non-finite / out of range.
    ///
    /// P7-secfix: a NaN or out-of-range `p` caused `as usize` to saturate
    /// or wrap (UB in debug). Guard added before the index computation mirrors
    /// the Swift P7 guard (`p.isFinite && p >= 0 && p <= 100`).
    pub fn percentile(&self, p: f64) -> f64 {
        if !p.is_finite() || p < 0.0 || p > 100.0 {
            return 0.0;
        }
        if self.samples.is_empty() {
            return 0.0;
        }
        let mut sorted = self.samples.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let idx = ((p / 100.0) * (sorted.len() as f64 - 1.0)) as usize;
        sorted[idx.min(sorted.len() - 1)]
    }
}

impl Default for QueueLatencyWindow {
    fn default() -> Self {
        QueueLatencyWindow::new(100)
    }
}

/// Public facade per QUEUEKIT_SPEC §3.
///
/// Wraps a concrete `QueueBackend` and adds drain telemetry. Mirrors
/// Swift's `QueueKit` class (four permanent methods + awaitDrain + telemetry).
///
/// Generic over `B: QueueBackend` because the trait's `watch` method carries
/// a generic handler parameter, making it not dyn-compatible. Rust semantics:
/// monomorphize at the call site rather than type-erase. For the common case
/// use `QueueKit<FilesystemBackend>`.
pub struct QueueKit<B: QueueBackend> {
    backend: B,
    latency_window: Mutex<QueueLatencyWindow>,
    /// Estate tag for queue.* telemetry metrics. Set via `set_estate_tag`.
    estate_tag: Mutex<String>,
}

impl<B: QueueBackend> QueueKit<B> {
    /// Mount the given backend. Caller is responsible for directory setup
    /// (maildir dirs for FilesystemBackend) before constructing this facade.
    pub fn new(backend: B) -> Self {
        QueueKit {
            backend,
            latency_window: Mutex::new(QueueLatencyWindow::default()),
            estate_tag: Mutex::new("unknown".to_string()),
        }
    }

    /// Set the estate tag used in queue.* telemetry metrics. Should be set
    /// at mount time by the composition layer.
    pub fn set_estate_tag(&self, tag: &str) {
        if let Ok(mut t) = self.estate_tag.lock() {
            *t = tag.to_string();
        }
    }

    // MARK: - The four public methods (spec §3)

    /// Enqueue a job. Mirrors Swift `QueueKit.send(_:)`.
    pub fn send(&self, job: &Job) -> Result<(), QueueError> {
        self.backend.write(job)
    }

    /// Enqueue a batch of jobs in one pass — the bulk twin of `send`. Routes to
    /// the backend's `write_batch`, which for the filesystem backend writes all
    /// files and fsyncs `new/` ONCE instead of per job. Used by the bulk reindex.
    /// Mirrors Swift `QueueKit.send(batch:)`.
    pub fn send_batch(&self, jobs: &[Job]) -> Result<usize, QueueError> {
        self.backend.write_batch(jobs)
    }

    /// Drain all available jobs and emit telemetry. Mirrors Swift `QueueKit.drain()`.
    pub fn drain(&self, now_epoch_secs: f64) -> Result<Vec<(Job, SessionId)>, QueueError> {
        let start = Instant::now();
        let result = self.backend.drain_available()?;
        let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;

        self.report_drain_stats(&result, elapsed_ms, now_epoch_secs);

        Ok(result)
    }

    /// Drain only the jobs belonging to `stream` (ADR-021 Decision 7 / T1).
    ///
    /// Routes to the backend's `drain_available_for_stream`, which on
    /// PersistenceKitBackend uses the `(stream_id, status)` index (one
    /// predicated bulk UPDATE) and on FilesystemBackend decodes-and-filters
    /// `new/`. Telemetry mirrors `drain()`: same estate tag, same latency window.
    /// Swift twin: `QueueKit.drain(stream:)`.
    pub fn drain_for_stream(
        &self,
        stream: &StreamId,
        now_epoch_secs: f64,
    ) -> Result<Vec<(Job, SessionId)>, QueueError> {
        let start = Instant::now();
        let result = self.backend.drain_available_for_stream(stream)?;
        let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;

        self.report_drain_stats(&result, elapsed_ms, now_epoch_secs);

        Ok(result)
    }

    /// Watch for arriving jobs. Mirrors Swift `QueueKit.watch(handler:)`. The
    /// closure is boxed here so the backend's `watch` stays non-generic (which is
    /// what keeps `QueueBackend` dyn-compatible).
    pub fn watch<F>(&self, handler: F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync + 'static,
    {
        self.backend.watch(Box::new(handler))
    }

    /// Complete a job with a terminal status. Mirrors Swift `QueueKit.reply(to:status:artifacts:)`.
    pub fn reply(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError> {
        if !status.is_terminal() {
            return Err(QueueError::InvalidTerminalStatus(status.raw().to_string()));
        }
        self.backend.complete(job_id, status, artifacts)
    }

    /// Complete every in-flight job claimed under `session` in one pass — the
    /// batch twin of `reply`. Returns the number completed; returns 0 for a
    /// backend without the fast path, and the caller then falls back to per-job
    /// `reply`. Mirrors Swift `QueueKit.reply(session:status:)`, including the
    /// downcast to the PersistenceKit batch path (`backend as? PersistenceKitBackend`
    /// in Swift → `as_any().downcast_ref::<PersistenceKitBackend>()` here).
    #[must_use = "a return of 0 means the caller must fall back to per-job reply"]
    pub fn reply_session(
        &self,
        session: &SessionId,
        status: ObservationStatus,
    ) -> Result<usize, QueueError> {
        if !status.is_terminal() {
            return Err(QueueError::InvalidTerminalStatus(status.raw().to_string()));
        }
        // The PersistenceKit batch fast path is only present when that backend is
        // compiled in (feature-gated module). Without it, fall through to 0 so the
        // caller does per-job completion.
        #[cfg(feature = "persistencekit")]
        if let Some(pk) = self.backend.as_any().downcast_ref::<PersistenceKitBackend>() {
            return pk.complete_session(session, status);
        }
        let _ = session;
        Ok(0)
    }

    /// Complete a batch of jobs by id in one pass — the job-list twin of
    /// `reply_session`. Routes to the backend's `complete_batch`, which for the
    /// filesystem backend collapses the per-job `cur/` scan + per-job fsync into
    /// one scan and one durability barrier. Returns the number completed. Used by
    /// the corpus drain to retire a drained batch on backends (FilesystemBackend)
    /// that have no session fast path. Mirrors Swift `QueueKit.reply(batch:status:)`.
    pub fn reply_batch(
        &self,
        completions: &[(JobId, ObservationStatus)],
    ) -> Result<usize, QueueError> {
        self.backend.complete_batch(completions)
    }

    /// List in-flight jobs. Mirrors Swift `QueueKit.inFlight()`.
    pub fn in_flight(&self) -> Result<Vec<Job>, QueueError> {
        self.backend.in_flight()
    }

    /// The number of jobs waiting in the queue's `new/` frontier — submitted
    /// but not yet claimed. Public passthrough to the backend's `pending_count`,
    /// mirroring the public `in_flight()` probe so a status reader can observe
    /// queue depth without claiming or draining. `pending_count() +
    /// in_flight().len()` is the total outstanding work a drain has left.
    /// Mirrors Swift `QueueKit.pendingCount()`.
    pub fn pending_count(&self) -> Result<usize, QueueError> {
        self.backend.pending_count()
    }

    /// Count pending jobs belonging to `stream` only (ADR-021 Decision 7 / T1).
    ///
    /// Routes to the backend's `pending_count_for_stream`. Non-claiming.
    /// Swift twin: `QueueKit.pendingCount(stream:)`.
    pub fn pending_count_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError> {
        self.backend.pending_count_for_stream(stream)
    }

    /// Reset every stale in-flight ("cur") job for `stream` back to "new",
    /// clearing the `session_id`. Returns the count of reclaimed rows.
    ///
    /// # Safety
    ///
    /// Must only be called immediately after the caller has successfully
    /// acquired the stream's `DrainLease` via `try_acquire`. The freshly-
    /// acquired lease guarantees the prior holder is dead — so every "cur"
    /// row for this stream is an orphan. The lease-TTL gate (15 s) prevents a
    /// false reclaim against a live drainer.
    ///
    /// Routes to `PersistenceKitBackend::reclaim_in_flight_for_stream` when
    /// that backend is compiled in; returns `Ok(0)` for all other backends
    /// (Filesystem maildir has no shared inter-process cur state; the on-mount
    /// reclaim is handled by the filesystem's own per-dir `claim` semantics).
    ///
    /// Swift twin: `QueueKit.reclaimInFlight(stream:)`.
    pub fn reclaim_in_flight_for_stream(&self, stream: &StreamId) -> Result<usize, QueueError> {
        #[cfg(feature = "persistencekit")]
        if let Some(pk) = self.backend.as_any().downcast_ref::<PersistenceKitBackend>() {
            return pk.reclaim_in_flight_for_stream(stream);
        }
        Ok(0)
    }

    /// List completed jobs, optionally filtered by stream. Mirrors Swift `QueueKit.completed(streamID:)`.
    pub fn completed(&self, stream_id: Option<&StreamId>) -> Result<Vec<Job>, QueueError> {
        self.backend.completed(stream_id)
    }

    /// Block until the queue has no pending and no in-flight work.
    /// Mirrors Swift `QueueKit.awaitDrain(pollInterval:timeout:)`.
    pub fn await_drain(
        &self,
        poll_interval: Duration,
        timeout: Duration,
    ) -> Result<(), QueueError> {
        self.backend.await_drain(poll_interval, timeout)
    }

    /// Block until `stream` has no pending and no in-flight work (ADR-021
    /// Decision 7 / T1). Stream-scoped twin of `await_drain`: a per-stream
    /// drainer on the shared per-estate queue must not wait on other streams'
    /// jobs it never processes. Swift twin: `QueueKit.awaitDrain(stream:...)`.
    pub fn await_drain_for_stream(
        &self,
        stream: &StreamId,
        poll_interval: Duration,
        timeout: Duration,
    ) -> Result<(), QueueError> {
        self.backend.await_drain_for_stream(stream, poll_interval, timeout)
    }

    /// Access the underlying backend directly (for tests or advanced use).
    pub fn backend(&self) -> &B {
        &self.backend
    }

    // MARK: - Telemetry

    fn report_drain_stats(
        &self,
        drained: &[(Job, SessionId)],
        drain_latency_ms: f64,
        now: f64,
    ) {
        if !Intellectus::is_enabled() {
            return;
        }

        let estate_tag = self.estate_tag.lock()
            .map(|t| t.clone())
            .unwrap_or_else(|_| "unknown".to_string());

        let tags: HashMap<String, String> = [
            ("estate".to_string(), estate_tag),
            ("kit".to_string(), "QueueKit".to_string()),
        ]
        .into_iter()
        .collect();

        // Depth probe — if it fails, emit gap sentinel instead of fabricated zero.
        match self.backend.pending_count() {
            Ok(depth) => {
                Intellectus::report_sample(StatSample::metric(
                    "queue.depth".into(),
                    depth as f64,
                    tags.clone(),
                    now,
                ));

                // idle_nonempty: only honest when depth is known.
                let idle = if depth > 0 && drained.is_empty() {
                    1.0
                } else {
                    0.0
                };
                Intellectus::report_sample(StatSample::metric(
                    "queue.idle_nonempty".into(),
                    idle,
                    tags.clone(),
                    now,
                ));

                // Head-of-line age when idle+nonempty.
                if depth > 0 && drained.is_empty() {
                    Intellectus::report_sample(StatSample::metric(
                        "queue.head_of_line_age_s".into(),
                        0.0,
                        tags.clone(),
                        now,
                    ));
                }
            }
            Err(_) => {
                Intellectus::report_sample(StatSample::metric(
                    "queue.depth_unavailable".into(),
                    1.0,
                    tags.clone(),
                    now,
                ));
            }
        }

        // Drain count.
        Intellectus::report_sample(StatSample::metric(
            "queue.drain_count".into(),
            drained.len() as f64,
            tags.clone(),
            now,
        ));

        // Latency percentiles.
        if let Ok(mut window) = self.latency_window.lock() {
            window.append(drain_latency_ms);
            Intellectus::report_sample(StatSample::metric(
                "queue.latency_p50_ms".into(),
                window.percentile(50.0),
                tags.clone(),
                now,
            ));
            Intellectus::report_sample(StatSample::metric(
                "queue.latency_p95_ms".into(),
                window.percentile(95.0),
                tags.clone(),
                now,
            ));
        }

        // Head-of-line age from drained jobs (proxy for pipeline latency).
        // HLC physical_time is milliseconds since epoch.
        if !drained.is_empty() {
            if let Some(oldest) = drained.iter().min_by_key(|(j, _)| j.submitted_at.physical_time) {
                let submit_epoch_s = oldest.0.submitted_at.physical_time as f64 / 1000.0;
                let age_s = (now - submit_epoch_s).max(0.0);
                Intellectus::report_sample(StatSample::metric(
                    "queue.head_of_line_age_s".into(),
                    age_s,
                    tags,
                    now,
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::QueueLatencyWindow;

    // P7-secfix: NaN / infinity / out-of-range p must return 0.0 without
    // panic or saturation. The old impl did `as usize` directly on the
    // f64 index which is UB-adjacent behavior for NaN/inf inputs.
    #[test]
    fn percentile_nan_and_infinity_return_zero() {
        let mut w = QueueLatencyWindow::new(100);
        w.append(10.0);
        w.append(20.0);

        // Non-finite inputs.
        assert_eq!(w.percentile(f64::NAN), 0.0, "percentile(NaN) must return 0");
        assert_eq!(w.percentile(f64::INFINITY), 0.0, "percentile(+inf) must return 0");
        assert_eq!(w.percentile(f64::NEG_INFINITY), 0.0, "percentile(-inf) must return 0");

        // Out-of-range inputs.
        assert_eq!(w.percentile(-1.0), 0.0, "percentile(-1) must return 0");
        assert_eq!(w.percentile(101.0), 0.0, "percentile(101) must return 0");

        // Boundary values must still work correctly.
        assert_eq!(w.percentile(0.0), 10.0, "percentile(0) must return the minimum sample");
        assert_eq!(w.percentile(100.0), 20.0, "percentile(100) must return the maximum sample");
    }

    #[test]
    fn percentile_empty_window_returns_zero_regardless_of_p() {
        let w = QueueLatencyWindow::new(100);
        assert_eq!(w.percentile(50.0), 0.0);
        assert_eq!(w.percentile(f64::NAN), 0.0);
    }
}
