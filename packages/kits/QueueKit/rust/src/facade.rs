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
// Minimum seconds between queue.* metric emissions per estate stream.
//
// A busy queue drains 100+ times per second; without rate-limiting every drain
// tick emits five metrics, flooding metric_samples at ~116 rows/sec (observed
// at 6 M rows in 3 h in production). 30 s is long enough to keep the dashboard
// responsive without producing millions of rows per day.
//
// The latency window accumulates on every tick regardless (Swift twin constant
// `EMISSION_INTERVAL_S`).
const EMISSION_INTERVAL_S: f64 = 30.0;

pub struct QueueKit<B: QueueBackend> {
    backend: B,
    latency_window: Mutex<QueueLatencyWindow>,
    /// Estate tag for queue.* telemetry metrics. Set via `set_estate_tag`.
    estate_tag: Mutex<String>,
    /// Epoch-seconds of the last Intellectus metric emission for this stream.
    /// Starts at 0.0 (guaranteed to fire on first call for any real clock since
    /// `now - 0 >> 30`). Guards the 30-second emission throttle.
    /// Mirrors Swift `QueueLatencyWindowBox.Inner.lastEmissionEpoch`.
    last_emission_epoch: Mutex<f64>,
}

impl<B: QueueBackend> QueueKit<B> {
    /// Mount the given backend. Caller is responsible for directory setup
    /// (maildir dirs for FilesystemBackend) before constructing this facade.
    pub fn new(backend: B) -> Self {
        QueueKit {
            backend,
            latency_window: Mutex::new(QueueLatencyWindow::default()),
            estate_tag: Mutex::new("unknown".to_string()),
            last_emission_epoch: Mutex::new(0.0),
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
        // Off-path gate: single atomic bool check. ~1 ns when disabled.
        if !Intellectus::is_enabled() {
            return;
        }

        // Sample the latency window on every drain tick (window accumulates
        // between emissions). Check the throttle gate atomically.
        //
        // Mirrors Swift: QueueLatencyWindowBox.sample(_:now:interval:).
        let (p50, p95, should_emit) = {
            let Ok(mut window) = self.latency_window.lock() else { return };
            window.append(drain_latency_ms);
            let p50 = window.percentile(50.0);
            let p95 = window.percentile(95.0);
            let Ok(mut last_epoch) = self.last_emission_epoch.lock() else { return };
            let should_emit = now - *last_epoch >= EMISSION_INTERVAL_S;
            if should_emit { *last_epoch = now; }
            (p50, p95, should_emit)
        };

        // Rate-limit: skip all emission until the interval elapses.
        if !should_emit {
            return;
        }

        // All Intellectus::report_sample calls below fire at most once per EMISSION_INTERVAL_S.
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
        // A fabricated zero is indistinguishable from a genuinely empty queue.
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

        // Drain count (reflects this drain call, at emission time).
        Intellectus::report_sample(StatSample::metric(
            "queue.drain_count".into(),
            drained.len() as f64,
            tags.clone(),
            now,
        ));

        // Latency percentiles from the rolling window — already computed above.
        // Both values reflect ALL drain ticks since the last emission.
        Intellectus::report_sample(StatSample::metric(
            "queue.latency_p50_ms".into(),
            p50,
            tags.clone(),
            now,
        ));
        Intellectus::report_sample(StatSample::metric(
            "queue.latency_p95_ms".into(),
            p95,
            tags.clone(),
            now,
        ));

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
    use super::{QueueLatencyWindow, EMISSION_INTERVAL_S};
    use std::sync::Mutex;

    // ─── Emission-throttle tests (mirrors Swift QueueLatencyWindowBox tests) ────

    /// Simulates the throttle logic inline by sharing the same state fields.
    ///
    /// Helper: run the window+throttle logic N times with controlled `now` values
    /// and return a Vec<bool> of `should_emit` results.
    fn run_throttle(
        samples: &[(f64, f64)], // (drain_latency_ms, now)
        interval: f64,
    ) -> Vec<bool> {
        let window = Mutex::new(QueueLatencyWindow::new(100));
        let last_epoch = Mutex::new(0.0_f64);
        samples
            .iter()
            .map(|(latency, now)| {
                let mut w = window.lock().unwrap();
                w.append(*latency);
                let mut last = last_epoch.lock().unwrap();
                let should = now - *last >= interval;
                if should { *last = *now; }
                should
            })
            .collect()
    }

    #[test]
    fn throttle_n_ticks_within_interval_emit_once() {
        // Ticks at t=1000..1009 (1s apart) within a 30s interval.
        // First tick (t=1000): last_epoch=0, 1000-0=1000>=30 → emit=true.
        // Subsequent ticks: now - 1000 < 30 → emit=false.
        let samples: Vec<(f64, f64)> = (0..10).map(|i| (5.0, 1000.0 + i as f64)).collect();
        let results = run_throttle(&samples, EMISSION_INTERVAL_S);
        let emit_count = results.iter().filter(|&&e| e).count();
        assert_eq!(emit_count, 1,
            "10 ticks within 30s interval must emit exactly once; got {emit_count}");
        assert!(results[0], "first tick must be the emission");
    }

    #[test]
    fn throttle_boundary_fires_second_emission() {
        // t=1000 → first emission.
        // t=1029.9 → 29.9 < 30 → no emit.
        // t=1030.1 → 30.1 >= 30 → second emission.
        let samples = vec![(5.0, 1000.0), (5.0, 1029.9), (5.0, 1030.1)];
        let results = run_throttle(&samples, EMISSION_INTERVAL_S);
        assert!(results[0], "t=1000 must fire first emission");
        assert!(!results[1], "t=1029.9 is within the 30s window (29.9 elapsed)");
        assert!(results[2], "t=1030.1 crosses the 30s boundary — second emission");
    }

    #[test]
    fn throttle_window_accumulates_on_non_emitting_ticks() {
        // Accumulate 10 samples of 0ms (non-emitting) + 1 sample of 100ms (emitting).
        // At second emission (t=1031), p50 should be < 100 because the 10 zeros
        // dominate the window.
        let window = Mutex::new(QueueLatencyWindow::new(100));
        let last_epoch = Mutex::new(0.0_f64);

        // First emission at t=1000 with 100ms sample.
        {
            let mut w = window.lock().unwrap();
            w.append(100.0);
            let mut last = last_epoch.lock().unwrap();
            *last = 1000.0; // mark as emitted
        }
        // Non-emitting ticks at t=1001..1010 with 0ms samples.
        for _i in 1..=10u64 {
            let mut w = window.lock().unwrap();
            w.append(0.0);
            drop(w);
        }
        // Second emission at t=1031.
        let (p50, emit) = {
            let mut w = window.lock().unwrap();
            w.append(0.0);
            let p50 = w.percentile(50.0);
            let mut last = last_epoch.lock().unwrap();
            let should = 1031.0 - *last >= EMISSION_INTERVAL_S;
            if should { *last = 1031.0; }
            (p50, should)
        };
        assert!(emit, "t=1031 must cross the 30s boundary and fire");
        assert!(p50 < 100.0,
            "p50 must reflect the 10 accumulated 0ms samples; expected < 100, got {p50}");
    }

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
