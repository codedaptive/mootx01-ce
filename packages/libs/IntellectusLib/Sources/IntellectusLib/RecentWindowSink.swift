// RecentWindowSink.swift
//
// A StatsSink that keeps a BOUNDED recent window of the samples it receives,
// and optionally forwards each sample to a wrapped inner sink.
//
// This is the in-process "recent window" the observer program exposes: a
// fixed-capacity ring buffer of the most recent StatSamples. It is the live
// proof that emitted samples are not dead letters — a caller can read the
// window back and see the last N samples that crossed the gate.
//
// Design notes:
//   - Bounded by construction: `capacity` is fixed at init and enforced on
//     every receive. When the window is full, the OLDEST sample is evicted to
//     make room (FIFO ring). The window never grows past `capacity`, so memory
//     is O(capacity) regardless of how many samples are emitted. This bound is
//     contractual (SPEC I-8): an observer program must not accumulate unbounded
//     in-process state.
//   - Decorator, not a replacement: an optional `forward` sink receives every
//     sample AFTER it is recorded in the window. This lets the observer program
//     keep a recent window AND persist to a durable sink (PersistenceStatsSink)
//     from a single installed sink. When `forward` is nil, the window is the
//     only consumer.
//   - Thread-safe: `receive(_:)` is called from any thread (the gate is global).
//     An NSLock guards the ring buffer. The lock is held only for the O(1)
//     buffer mutation; the forward sink's `receive` runs OUTSIDE the lock so a
//     forward sink that itself locks cannot invert against this lock (mirrors
//     the Intellectus holder's sink-outside-the-lock discipline, SPEC I-7).
//   - Zero dependencies: this is the floor library. Foundation (NSLock) only.

import Foundation

// MARK: - RecentWindowSink

/// A `StatsSink` that retains a bounded ring buffer of the most recent samples
/// and optionally forwards each sample to a wrapped sink.
///
/// Install this as the `Intellectus` sink when the host wants a live, readable
/// window of recent telemetry in addition to (or instead of) durable storage:
///
/// ```swift
/// // Window-only: keep the last 256 samples in memory.
/// let window = RecentWindowSink(capacity: 256)
/// Intellectus.install(sink: window)
/// Intellectus.setEnabled(true)
/// // ... later ...
/// let recent = window.snapshot()   // up to 256 most-recent samples, oldest first
///
/// // Window + durable: record recent AND persist to a StatsStore-backed sink.
/// let window = RecentWindowSink(capacity: 256, forward: persistenceSink)
/// Intellectus.install(sink: window)
/// ```
///
/// ## Bound
///
/// The window holds at most `capacity` samples. On overflow the oldest sample
/// is evicted (FIFO). `capacity` is fixed at construction and clamped to a
/// minimum of 1.
///
/// ## Thread safety
///
/// `receive(_:)` is safe to call concurrently. The forward sink (if any) is
/// invoked outside the internal lock.
public final class RecentWindowSink: StatsSink, @unchecked Sendable {

    // MARK: - State

    /// Maximum number of samples retained. Fixed at init; enforced on every
    /// receive. The window's memory footprint is O(capacity).
    public let capacity: Int

    /// Optional downstream sink. Every received sample is forwarded here AFTER
    /// it is recorded in the window. Nil means the window is the only consumer.
    private let forward: (any StatsSink)?

    /// The ring buffer guard. Held only for the O(1) buffer mutation; the
    /// forward sink runs outside it.
    private let lock = NSLock()

    /// Backing storage for the ring. Sized to `capacity`; `count` tracks how
    /// many slots are populated and `head` the insertion point.
    private var ring: [StatSample?]
    private var head: Int = 0
    private var filled: Int = 0
    /// Monotonic count of every sample received since construction, regardless
    /// of eviction. Lets a caller distinguish "window empty" from "nothing ever
    /// arrived" — the observer program's explicit liveness signal.
    private var _totalReceived: Int = 0

    // MARK: - Initialisation

    /// Create a bounded recent-window sink.
    ///
    /// - Parameters:
    ///   - capacity: Maximum samples retained. Clamped to a minimum of 1 — a
    ///               zero or negative capacity would make the window useless and
    ///               is treated as a programming error corrected to 1.
    ///   - forward:  Optional downstream sink. Receives every sample after it is
    ///               recorded in the window. Default nil (window-only).
    public init(capacity: Int, forward: (any StatsSink)? = nil) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.forward = forward
        self.ring = Array(repeating: nil, count: cap)
    }

    // MARK: - StatsSink

    /// Record `sample` in the window (evicting the oldest if full), then forward
    /// it to the wrapped sink if one is installed.
    ///
    /// Called only when `Intellectus.isEnabled` is true (the gate short-circuits
    /// otherwise). The ring mutation is O(1) under the lock; the forward call
    /// runs outside the lock.
    public func receive(_ sample: StatSample) {
        lock.lock()
        ring[head] = sample
        head = (head + 1) % capacity
        if filled < capacity { filled += 1 }
        _totalReceived += 1
        lock.unlock()

        // Forward outside the lock (SPEC I-7 discipline — never hold our lock
        // while the downstream sink runs, which may take its own lock).
        forward?.receive(sample)
    }

    // MARK: - Read API (observer program inspection)

    /// A point-in-time copy of the window contents, oldest sample first.
    ///
    /// Returns at most `capacity` samples. The returned array is a snapshot —
    /// safe to read without holding any lock and unaffected by subsequent
    /// `receive(_:)` calls.
    public func snapshot() -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        guard filled > 0 else { return [] }
        var out: [StatSample] = []
        out.reserveCapacity(filled)
        // Oldest element is at (head - filled) modulo capacity.
        let start = (head - filled + capacity) % capacity
        for i in 0..<filled {
            let idx = (start + i) % capacity
            if let s = ring[idx] { out.append(s) }
        }
        return out
    }

    /// The number of samples currently retained in the window (0...capacity).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }

    /// The total number of samples received since construction, ignoring
    /// eviction. Greater than or equal to `count`. A value of 0 means no sample
    /// has ever crossed the gate into this sink — the explicit "nothing observed
    /// yet" signal the observer program reports when off.
    public var totalReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalReceived
    }
}
