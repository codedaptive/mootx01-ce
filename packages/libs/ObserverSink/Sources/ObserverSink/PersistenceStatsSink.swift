// PersistenceStatsSink.swift
//
// StatsSink conformance backed by a StatsStore (SQLiteStorage).
//
// Design (MANAGER_1.0_PLAN.md §1, confirmed defaults 2026-06-06):
//
//   1. The sink receives StatSample values from Intellectus.report(_:).
//   2. On each receive(_:), it checks the store's monitoring flag row.
//      If the flag is "0", the sample is silently discarded. This is
//      the signal mechanism (flag-row variant, Bob's confirmed choice).
//   3. If the flag is "1", the sample is serialised into the correct
//      table via StatsStore.insertMetric / insertEvent.
//
// Threading model:
//   - `receive(_:)` is called from any thread/task. PersistenceStatsSink
//     dispatches each insert to a Task. The store is an actor-isolated
//     SQLiteStorage, so concurrent inserts are safely serialised there.
//   - receive(_:) itself is synchronous and returns immediately (hot-path
//     requirement per StatsSink protocol docs). The async insert work
//     runs in an unstructured Task; if the task queue is full the OS will
//     schedule it when capacity allows. For the stats-recording use case
//     (off the hot substrate path) this is acceptable — dropped stats
//     samples are not catastrophic.
//
// Buffering note:
//   No in-process ring buffer is implemented at v1.0. Each sample
//   launches one Task. SQLite WAL mode handles concurrent writers
//   efficiently; monitoring off/on is enforced per-sample via the flag
//   row. A buffer + batch-flush implementation (e.g. 100-sample batch
//   on a 1 s timer) is a straightforward v1.1 improvement if benchmarks
//   show Task overhead is measurable in practice.
//
// Drop policy:
//   If the store's monitoring flag read throws, the sample is discarded
//   (logged at .debug level). Store errors on insert are logged at
//   .error level but do not propagate — the sink must never crash the
//   substrate.

import Foundation
import OSLog
import IntellectusLib
import PersistenceKit

// MARK: - PersistenceStatsSink

/// A `StatsSink` that persists each `StatSample` to a `StatsStore`.
///
/// Install this sink in `Intellectus` before enabling monitoring:
///
/// ```swift
/// let store = try StatsStore(url: statsDBURL)
/// try await store.open()
/// let sink = PersistenceStatsSink(store: store, dropboxID: "my-app")
/// Intellectus.install(sink: sink)
/// Intellectus.setEnabled(true)
/// ```
///
/// ## On/off signal
///
/// The sink reads the monitoring flag row from the store on each
/// `receive(_:)` call. If the flag is `"0"`, the sample is discarded
/// without any I/O. The manager sets the flag to `"1"` when it is
/// ready to receive data. This is the flag-row signal mechanism
/// (confirmed by Bob, 2026-06-06, MANAGER_1.0_PLAN.md §5 item 3).
///
/// ## Buffering
///
/// `receive(_:)` is synchronous and non-blocking. Each sample is
/// dispatched to an unstructured Swift `Task` for async store I/O.
/// No ring buffer at v1.0 — see buffering note above.
///
/// ## Thread safety
///
/// Conforms to `Sendable` (required by `StatsSink`). All mutable state
/// is inside `StatsStore`, which is a `Sendable` actor-backed type.
/// No mutable state is held directly in this struct.
public struct PersistenceStatsSink: StatsSink {

    // MARK: - State

    /// The store to which samples are persisted.
    private let store: StatsStore

    /// The dropbox identifier for this consumer.
    ///
    /// Included in every inserted row so the manager can attribute rows
    /// to their source process. Typically the process name + estate ID,
    /// e.g. `"aria-mcp-a7f2e914"`.
    private let dropboxID: String

    private let logger = Logger(subsystem: "com.mootx01.kit", category: "ObserverSink")

    // MARK: - Initialisation

    /// Create a `PersistenceStatsSink`.
    ///
    /// - Parameters:
    ///   - store:      The `StatsStore` to write samples to. Must already
    ///                 be opened (`store.open()` called) before samples arrive.
    ///   - dropboxID:  Identifies this consumer in the stats store rows.
    ///                 Use a stable, unique string (e.g. process name + UUID).
    public init(store: StatsStore, dropboxID: String) {
        self.store = store
        self.dropboxID = dropboxID
    }

    // MARK: - StatsSink

    /// Deliver one sample to the store.
    ///
    /// Checks the store's monitoring flag row first. Discards silently if
    /// the flag is `"0"` (monitoring off). If `"1"`, dispatches an async
    /// Task to serialise the sample into the appropriate table.
    ///
    /// This method is synchronous and returns immediately. Store I/O happens
    /// in the dispatched Task. Errors from Task I/O are logged (never thrown).
    ///
    /// Called only when `Intellectus.isEnabled` is `true` (the protocol
    /// guarantees no call when monitoring is disabled at the IntellectusLib
    /// level). The store-level flag provides a second layer: the manager
    /// can turn off the store flag without requiring every consumer to be
    /// restarted.
    public func receive(_ sample: StatSample) {
        // Capture values for the async Task (Sendable crossing).
        let capturedStore = store
        let capturedDropboxID = dropboxID
        let capturedLogger = logger

        Task {
            do {
                // Check store-level monitoring flag before any write.
                // This is the flag-row signal: the manager sets it to "1"
                // when it is ready; the sink reads it per-sample.
                let monitoringOn = try await capturedStore.isMonitoringEnabled()
                guard monitoringOn else {
                    // Monitoring is off at the store level — discard silently.
                    // Debug-level: this fires on every receive when off and would
                    // flood the log at info/error.
                    capturedLogger.debug("PersistenceStatsSink: monitoring off, sample discarded")
                    return
                }

                // Serialise the sample into the correct table.
                switch sample {
                case let .metric(name, value, tags, ts):
                    try await capturedStore.insertMetric(
                        name: name,
                        value: value,
                        tags: tags,
                        ts: ts,
                        dropboxID: capturedDropboxID
                    )

                case let .event(kind, nounType, rowID, estate, ts):
                    try await capturedStore.insertEvent(
                        kind: kind.rawValue,
                        nounType: nounType,
                        rowID: rowID,
                        estate: estate,
                        ts: ts,
                        dropboxID: capturedDropboxID
                    )
                }
            } catch {
                // Store errors must not propagate or crash the substrate.
                // Log at error level so the operator can diagnose write failures.
                capturedLogger.error("PersistenceStatsSink: store write failed: \(error)")
            }
        }
    }
}
