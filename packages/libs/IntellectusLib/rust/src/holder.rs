// holder.rs
//
// IntellectusHolder — the per-instance telemetry state container.
//
// Parity with Swift's `_IntellectusHolder`:
//   - `install(sink:)`  ↔  install(&self, sink: Arc<dyn StatsSink>)
//   - `set_enabled(_:)` ↔  set_enabled(&self, enabled: bool)
//   - `is_enabled`      ↔  is_enabled(&self) -> bool
//   - `report(_:)`      ↔  report(&self, make: impl FnOnce() -> StatSample)
//
// Threading model:
//   - `_enabled` is an AtomicBool. Reads use Acquire ordering (both
//     is_enabled() and the report() gate); writes use Release ordering
//     to establish the happens-before edge with subsequent is_enabled()
//     reads.
//     This gives the hot path a true single-atomic-load cost when
//     monitoring is disabled — no Mutex, no contention.
//   - `_sink` is a Mutex<Arc<dyn StatsSink>>. The Mutex is held only
//     during install() and during the brief snapshot in report() when
//     enabled. The sink is cloned (Arc clone) under the lock and then
//     released; `receive()` runs outside the lock.
//
// Off-path cost when disabled: one AtomicBool::load(Relaxed) + branch.
// No Mutex acquisition, no allocation, no payload evaluation.

use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering};
use crate::sink::{StatsSink, NoOpSink};
use crate::sample::StatSample;

/// Per-instance telemetry holder. The global singleton is `_INTELLECTUS`
/// in `global.rs`; this struct is also usable directly in unit tests
/// that need isolated state.
pub struct IntellectusHolder {
    // The atomic enabled gate. Default false (monitoring off).
    // Load ordering: Relaxed — we don't need a full fence for the
    // hot disabled path. The only correctness requirement is that
    // a set_enabled(true) call eventually becomes visible; Relaxed
    // is sufficient for a single flag on coherent hardware.
    pub(crate) _enabled: AtomicBool,

    // The installed sink. Mutex-protected so install() is safe to
    // call from any thread. The Arc lets us clone the sink reference
    // out of the lock before calling receive().
    pub(crate) _sink: Mutex<Arc<dyn StatsSink>>,
}

// IntellectusHolder is manually Send + Sync because:
//   - _enabled: AtomicBool is Send + Sync.
//   - _sink: Mutex<Arc<dyn StatsSink + Send + Sync>> is Send + Sync
//     because StatsSink: Send + Sync.
unsafe impl Send for IntellectusHolder {}
unsafe impl Sync for IntellectusHolder {}

impl IntellectusHolder {
    /// Create a new holder with monitoring disabled and NoOpSink installed.
    pub fn new() -> Self {
        IntellectusHolder {
            _enabled: AtomicBool::new(false),
            _sink: Mutex::new(Arc::new(NoOpSink)),
        }
    }

    // MARK: - Host API (rare, write path)

    /// Install a new sink. Thread-safe via Mutex. The previous sink is
    /// replaced atomically from the perspective of callers; in-flight
    /// `report` calls on other threads will use the old or new sink, never
    /// a torn state.
    pub fn install(&self, sink: Arc<dyn StatsSink>) {
        let mut guard = self._sink.lock().expect("IntellectusHolder sink lock poisoned");
        *guard = sink;
    }

    /// Enable or disable the telemetry gate.
    ///
    /// Uses Release ordering so that subsequent `is_enabled()` loads
    /// (Acquire) observe the update correctly.
    pub fn set_enabled(&self, enabled: bool) {
        self._enabled.store(enabled, Ordering::Release);
    }

    /// Whether monitoring is currently enabled.
    ///
    /// Uses Acquire ordering to pair with the Release store in
    /// `set_enabled`. This establishes a happens-before edge so any
    /// state written before `set_enabled(true)` is visible after
    /// `is_enabled()` returns true.
    pub fn is_enabled(&self) -> bool {
        self._enabled.load(Ordering::Acquire)
    }

    // MARK: - Emission (hot path)

    /// Emit a sample if monitoring is enabled.
    ///
    /// The closure `make` is evaluated **only** when `is_enabled()`
    /// returns `true`. When disabled, this method returns after a single
    /// `AtomicBool::load(Acquire) + branch` with no allocation and no
    /// payload construction.
    ///
    /// `make` is `impl FnOnce() -> StatSample`: any closure that produces
    /// a sample. The `report!` macro wraps block expressions with this.
    ///
    /// - Off-path (disabled) cost: one Acquire atomic load + branch.
    /// - On-path cost: atomic load + Mutex acquire (brief) + Arc clone +
    ///   Mutex release + closure evaluation + `receive()`.
    #[inline]
    pub fn report(&self, make: impl FnOnce() -> StatSample) {
        // Hot-path gate: single atomic load. No lock, no allocation.
        if !self._enabled.load(Ordering::Acquire) {
            return;
        }
        // Snapshot the sink Arc under the Mutex so install() cannot
        // race with our receive() call.
        let sink = {
            let guard = self._sink.lock().expect("IntellectusHolder sink lock poisoned");
            Arc::clone(&*guard)
        };
        // Evaluate the payload OUTSIDE the lock. The closure may be
        // arbitrary; we must not hold the sink mutex while it runs.
        sink.receive(make());
    }
}

impl Default for IntellectusHolder {
    fn default() -> Self {
        Self::new()
    }
}
