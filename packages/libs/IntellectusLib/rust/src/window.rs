// window.rs
//
// RecentWindowSink — a StatsSink that keeps a BOUNDED recent window of the
// samples it receives, and optionally forwards each to a wrapped inner sink.
//
// Parity with Swift's `RecentWindowSink`:
//   RecentWindowSink(capacity:forward:)  ↔  RecentWindowSink::new(capacity, forward)
//   .snapshot()                          ↔  .snapshot()
//   .count                               ↔  .count()
//   .totalReceived                       ↔  .total_received()
//
// This is the in-process "recent window" the observer program exposes: a
// fixed-capacity ring buffer of the most recent StatSamples. It is the live
// proof that emitted samples are not dead letters — a caller can read the
// window back and see the last N samples that crossed the gate.
//
// Design notes:
//   - Bounded by construction: `capacity` is fixed and enforced on every
//     receive. When full, the OLDEST sample is evicted (FIFO ring). Memory is
//     O(capacity) regardless of emission volume. The bound is contractual
//     (SPEC I-8).
//   - Decorator: an optional `forward` sink receives every sample AFTER it is
//     recorded, letting the observer program keep a recent window AND persist
//     to a durable sink from a single installed sink.
//   - Thread-safe: `receive` is called from any thread. A Mutex guards the ring;
//     the forward sink runs OUTSIDE the lock (SPEC I-7 discipline — no lock
//     inversion against a forward sink that locks).
//   - Zero dependencies: std only (Mutex, Arc, VecDeque).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use crate::sample::StatSample;
use crate::sink::StatsSink;

/// Inner state behind the Mutex: the ring buffer plus the monotonic receive
/// counter.
struct WindowState {
    /// FIFO ring of retained samples, oldest at the front. Length never exceeds
    /// `capacity`.
    ring: VecDeque<StatSample>,
    /// Monotonic count of every sample received since construction, regardless
    /// of eviction. Distinguishes "window empty" from "nothing ever arrived".
    total_received: usize,
}

/// A `StatsSink` that retains a bounded ring buffer of the most recent samples
/// and optionally forwards each sample to a wrapped sink.
///
/// Mirrors Swift's `RecentWindowSink`.
///
/// ## Bound
///
/// The window holds at most `capacity` samples. On overflow the oldest sample
/// is evicted (FIFO). `capacity` is fixed at construction and clamped to a
/// minimum of 1.
///
/// ## Example
///
/// ```rust
/// use intellectus_lib::{RecentWindowSink, StatSample, StatsSink};
///
/// let window = RecentWindowSink::new(256, None);
/// window.receive(StatSample::metric("x".into(), 1.0, Default::default(), 0.0));
/// assert_eq!(window.count(), 1);
/// assert_eq!(window.snapshot().len(), 1);
/// ```
pub struct RecentWindowSink {
    capacity: usize,
    forward: Option<Arc<dyn StatsSink>>,
    state: Mutex<WindowState>,
}

impl RecentWindowSink {
    /// Create a bounded recent-window sink.
    ///
    /// - `capacity`: Maximum samples retained. Clamped to a minimum of 1 — a
    ///   zero capacity would make the window useless and is corrected to 1.
    /// - `forward`:  Optional downstream sink. Receives every sample after it is
    ///   recorded in the window. `None` means window-only.
    pub fn new(capacity: usize, forward: Option<Arc<dyn StatsSink>>) -> Self {
        let cap = capacity.max(1);
        RecentWindowSink {
            capacity: cap,
            forward,
            state: Mutex::new(WindowState {
                ring: VecDeque::with_capacity(cap),
                total_received: 0,
            }),
        }
    }

    /// Maximum number of samples retained. Fixed at construction.
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// A point-in-time copy of the window contents, oldest sample first.
    ///
    /// Returns at most `capacity` samples. The returned vector is a snapshot —
    /// unaffected by subsequent `receive` calls.
    pub fn snapshot(&self) -> Vec<StatSample> {
        let guard = self.state.lock().expect("RecentWindowSink state lock poisoned");
        guard.ring.iter().cloned().collect()
    }

    /// The number of samples currently retained in the window (0..=capacity).
    pub fn count(&self) -> usize {
        let guard = self.state.lock().expect("RecentWindowSink state lock poisoned");
        guard.ring.len()
    }

    /// The total number of samples received since construction, ignoring
    /// eviction. Greater than or equal to `count()`. A value of 0 means no
    /// sample has ever arrived at this sink — the explicit "nothing observed
    /// yet" signal. Counts every direct `receive` call, including those not
    /// routed through the global Intellectus gate.
    pub fn total_received(&self) -> usize {
        let guard = self.state.lock().expect("RecentWindowSink state lock poisoned");
        guard.total_received
    }
}

impl StatsSink for RecentWindowSink {
    /// Record `sample` in the window (evicting the oldest if full), then forward
    /// it to the wrapped sink if one is installed.
    ///
    /// Records every direct call regardless of the global gate. The gate
    /// lives in `report!` / `Intellectus::report_sample`; callers going
    /// through that facade only reach this method when enabled, but the
    /// sink is also callable directly. The ring mutation is O(1) under
    /// the lock; the forward call runs outside the lock.
    fn receive(&self, sample: StatSample) {
        {
            let mut guard = self.state.lock().expect("RecentWindowSink state lock poisoned");
            if guard.ring.len() == self.capacity {
                // Window full — evict the oldest (FIFO) to make room.
                guard.ring.pop_front();
            }
            guard.ring.push_back(sample.clone());
            guard.total_received += 1;
        }
        // Forward outside the lock (SPEC I-7 discipline).
        if let Some(ref fwd) = self.forward {
            fwd.receive(sample);
        }
    }
}
