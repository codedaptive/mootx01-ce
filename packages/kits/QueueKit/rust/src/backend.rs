// QueueBackend trait per QUEUEKIT_SPEC §4.

use crate::error::QueueError;
use crate::job::{ArtifactRef, Job, JobId, ObservationStatus, SessionId, StreamId};
use std::time::{Duration, Instant};

pub trait QueueBackend: Send + Sync {
    fn write(&self, job: &Job) -> Result<(), QueueError>;
    fn drain_available(&self) -> Result<Vec<(Job, SessionId)>, QueueError>;
    fn complete(
        &self,
        job_id: &JobId,
        status: ObservationStatus,
        artifacts: Vec<ArtifactRef>,
    ) -> Result<(), QueueError>;
    fn in_flight(&self) -> Result<Vec<Job>, QueueError>;
    fn completed(&self, stream_id: Option<&StreamId>)
        -> Result<Vec<Job>, QueueError>;

    /// Count jobs in the `new/` frontier — pending, not yet claimed.
    ///
    /// A single depth read that does not advance the cursor (no claim). Swift
    /// parity: `QueueBackend.pendingCount()`. Used by `await_drain` to detect an
    /// empty `new/` frontier, and available to telemetry as a depth probe.
    ///
    /// The default returns `BackendUnavailable` so a backend that has not
    /// implemented the probe fails cleanly rather than at link time. Conforming
    /// backends override.
    fn pending_count(&self) -> Result<usize, QueueError> {
        Err(QueueError::BackendUnavailable(
            "pending_count() not implemented for this backend".to_string()))
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

    /// Watch for arriving jobs. Calls `handler` on each (Job, SessionId)
    /// pair as jobs become available. Blocks the calling thread until
    /// `handler` returns an error or until the watcher encounters a
    /// fatal error. Conforms to QUEUEKIT_SPEC §3 watch() semantics.
    ///
    /// The default implementation returns `BackendUnavailable` so that
    /// backends that have not yet implemented `watch()` fail cleanly
    /// rather than at link time. Conforming backends override.
    fn watch<F>(&self, _handler: F) -> Result<(), QueueError>
    where
        F: Fn(Job, SessionId) -> Result<(), QueueError> + Send + Sync,
    {
        Err(QueueError::BackendUnavailable(
            "watch() not implemented for this backend".to_string()))
    }
}
