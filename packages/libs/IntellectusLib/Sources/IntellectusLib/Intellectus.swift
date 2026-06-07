// Intellectus.swift
//
// The global telemetry facade: installed sink, enabled flag, and the
// short-circuit `report(_:)` API that is the library's primary call site.
//
// Threading model:
//   - `_IntellectusHolder` is a final class marked `@unchecked Sendable`.
//   - `_enabled` is a `Synchronization.Atomic<Bool>`. Reads are lock-free
//     (single atomic load). Writes use `.releasing` ordering; reads use
//     `.acquiring` ordering to establish a happens-before edge between
//     `setEnabled(true)` and the subsequent `isEnabled` reads. This mirrors
//     the Rust port's `AtomicBool::store(Release)` / `load(Acquire)` pair.
//   - `_sink` is NSLock-protected. The lock is acquired only to snapshot
//     the sink reference (an `any StatsSink` existential). This is the same
//     pattern as the Rust port's `Mutex<Arc<dyn StatsSink>>`: brief critical
//     section during install and during the on-path snapshot, then the sink's
//     `receive` runs outside the lock (SPEC I-7).
//   - The OFF-path (`report(_:)` when disabled) touches ONLY the atomic gate:
//     a single `Atomic<Bool>.load(.acquiring)` + branch. No lock. No
//     `@autoclosure` evaluation. No allocation.
//
// Off-path cost: one Atomic<Bool> load(.acquiring) + branch (~1 ns, lock-free).
// On-path cost: atomic load + NSLock acquire (brief) + sink snapshot + NSLock
//   release + autoclosure evaluation + receive(). Contention on the write path
//   (install/setEnabled) is rare by design.
//
// Why Synchronization.Atomic and not NSLock for the enabled flag:
//   The enabled gate is the hot path. NSLock — even uncontended — costs
//   ~6 ns per acquire+release on Apple Silicon. A single Atomic<Bool> load
//   is ~1 ns (compiler may even optimize to a register load in tight loops).
//   The platform floor is macOS 26 / iOS 26, which makes Synchronization
//   available unconditionally. The sink still uses NSLock because `any
//   StatsSink` is not atomically swappable — it requires a mutual-exclusion
//   section during install to prevent a torn existential read.

import Foundation
import Synchronization

// MARK: - _IntellectusHolder (internal)

/// Internal state holder for the global telemetry system.
///
/// Not exposed publicly. Callers use the `Intellectus` enum facade.
final class _IntellectusHolder: @unchecked Sendable {

    // Lock-free enabled gate using Synchronization.Atomic<Bool>.
    // Default false (monitoring off).
    //
    // Load ordering: .acquiring — pairs with the .releasing store in
    // setEnabled(_:) to establish a happens-before edge. Any state
    // written before setEnabled(true) is visible after isEnabled returns
    // true. This mirrors AtomicBool::load(Acquire) in the Rust port.
    //
    // Atomic<Bool> is ~Copyable (move-only); storing it as a `let`
    // property of this final class is safe — the class is the unique owner.
    private let _enabled: Atomic<Bool> = Atomic(false)

    // NSLock serialises reads and writes to _sink only. Acquisition is
    // on the on-path only (when monitoring is enabled). The off-path
    // (disabled) never acquires this lock — it returns after the atomic
    // load above.
    private let _sinkLock = NSLock()

    // The currently-installed sink. Starts as the no-op default.
    // Replaced by install(sink:). Holding it as `any StatsSink`
    // allows any conforming concrete type.
    private var _sink: any StatsSink = NoOpSink.shared

    // MARK: - Host API (rare, write path)

    /// Install a new sink. Thread-safe. The previous sink is replaced
    /// atomically from the perspective of callers.
    ///
    /// Installation is expected to be rare (once at startup). It holds
    /// the sink lock briefly; in-flight `report(_:)` calls on other threads
    /// will either use the old sink or the new one — never both.
    func install(sink: any StatsSink) {
        _sinkLock.lock()
        _sink = sink
        _sinkLock.unlock()
    }

    /// Enable or disable the telemetry gate.
    ///
    /// When `enabled` is `false` (the default), `report(_:)` is a
    /// no-op and the payload autoclosure is never evaluated. Set to
    /// `true` only when an observer is ready to consume samples.
    ///
    /// Uses `.releasing` store ordering so subsequent `isEnabled` reads
    /// (`.acquiring`) correctly observe the update (mirrors the Rust port).
    func setEnabled(_ enabled: Bool) {
        _enabled.store(enabled, ordering: .releasing)
    }

    /// Current enabled state. Lock-free atomic load.
    ///
    /// Uses `.acquiring` load ordering to pair with the `.releasing` store
    /// in `setEnabled`. Establishes a happens-before edge so any state
    /// written before `setEnabled(true)` is visible after this returns true.
    var isEnabled: Bool {
        _enabled.load(ordering: .acquiring)
    }

    // MARK: - Emission (hot path)

    /// Emit a sample if monitoring is enabled.
    ///
    /// The `make` autoclosure is evaluated **only** when enabled is `true`.
    /// When disabled, this function returns after a single `Atomic<Bool>`
    /// load + branch with no allocation, no lock, and no payload build.
    ///
    /// The OFF-path touches only `_enabled` (the atomic). The sink lock is
    /// never acquired on the off-path. Parity with the Rust `report!` macro
    /// which expands to `if _enabled.load(Acquire) { report_sample(make()) }`.
    ///
    /// - Parameter make: Autoclosure that constructs the `StatSample`.
    ///                   Not evaluated when monitoring is disabled.
    @inline(__always)
    func report(_ make: @autoclosure () -> StatSample) {
        // OFF-path gate: single atomic load. No lock, no allocation.
        // If disabled, the autoclosure argument is never evaluated.
        guard _enabled.load(ordering: .acquiring) else { return }

        // ON-path: snapshot the sink under the lock so a concurrent
        // install() cannot change the existential between our check and
        // our call.
        _sinkLock.lock()
        let sink = _sink
        _sinkLock.unlock()

        // Evaluate the payload OUTSIDE the lock. The autoclosure runs
        // only when enabled. The sink receives the sample unlocked —
        // the sink is Sendable and handles its own internal synchronisation.
        sink.receive(make())
    }
}

// MARK: - Global holder

/// The singleton `_IntellectusHolder` instance. Module-private.
/// All public API routes through the `Intellectus` enum below.
let _intellectus = _IntellectusHolder()

// MARK: - Intellectus (public facade)

/// The global telemetry facade for IntellectusLib.
///
/// `Intellectus` is a stateless namespace (caseless enum). All state
/// lives in the module-internal `_intellectus` singleton.
///
/// ## Basic usage
///
/// ```swift
/// // At startup: install a real sink and enable monitoring.
/// Intellectus.install(sink: MyObserverSink())
/// Intellectus.setEnabled(true)
///
/// // In hot-path code: emit a metric.
/// // If monitoring is off, the closure is NEVER evaluated.
/// Intellectus.report(.metric(
///     name: "locus.capture.latency_ms",
///     value: elapsed * 1000,
///     tags: ["kit": "LocusKit"],
///     ts: Date().timeIntervalSince1970
/// ))
/// ```
///
/// ## Default state
///
/// Monitoring is **OFF** by default. The installed sink is `NoOpSink`.
/// No `report(_:)` call will construct a payload or call any sink
/// until the host calls `setEnabled(true)`.
public enum Intellectus {

    // MARK: - Host API

    /// Replace the installed sink with `sink`.
    ///
    /// Thread-safe. Takes effect for all subsequent `report(_:)` calls.
    /// The previous sink is discarded immediately.
    ///
    /// Install before calling `setEnabled(true)` to avoid a window
    /// where monitoring is on but the real sink is not yet installed.
    ///
    /// - Parameter sink: Any `StatsSink`-conforming type.
    public static func install(sink: any StatsSink) {
        _intellectus.install(sink: sink)
    }

    /// Enable or disable the global telemetry gate.
    ///
    /// When `false` (the default), every `report(_:)` call is a
    /// no-op — the payload autoclosure is never evaluated. Set to
    /// `true` when the host has installed a real sink and is ready
    /// to receive samples.
    ///
    /// The observer program (a later mission) drives this from its
    /// broadcast signal: it calls `setEnabled(true)` when an observer
    /// subscribes and `setEnabled(false)` when the last observer drops.
    ///
    /// - Parameter enabled: `true` to start receiving samples; `false`
    ///   to stop (samples are discarded from this call forward).
    public static func setEnabled(_ enabled: Bool) {
        _intellectus.setEnabled(enabled)
    }

    /// Whether monitoring is currently enabled. Lock-free atomic load.
    public static var isEnabled: Bool {
        _intellectus.isEnabled
    }

    // MARK: - Emission

    /// Emit a telemetry sample — with short-circuit evaluation.
    ///
    /// The `@autoclosure` is evaluated **only** if `isEnabled` is
    /// `true`. When monitoring is disabled the payload is never
    /// constructed, no allocation occurs, and the sink is never called.
    ///
    /// Off-path cost when disabled: one lock-free `Atomic<Bool>` load +
    /// branch (~1 ns on Apple Silicon). No lock acquisition on the off-path.
    ///
    /// ```swift
    /// // The .metric(...) expression is never evaluated when off.
    /// Intellectus.report(.metric(
    ///     name: "vector.search.hits",
    ///     value: Double(hits),
    ///     tags: [:],
    ///     ts: now
    /// ))
    /// ```
    ///
    /// - Parameter make: Autoclosure constructing the `StatSample`.
    ///                   Not evaluated when `isEnabled` is `false`.
    @inline(__always)
    public static func report(_ make: @autoclosure () -> StatSample) {
        _intellectus.report(make())
    }
}
