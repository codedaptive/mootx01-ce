// Observer.swift
//
// The resident observer program (DEBT-3, Bob's ruling 2026-06-10).
//
// This is the live observer loop the IntellectusLib comments promised. It:
//   1. Decides whether monitoring is on, from config: the ARIA_MCP_OBSERVER
//      env var (explicit operator opt-in) OR the persisted stats-store
//      monitoring flag (moot-mgr's broadcast signal). Either being on enables.
//   2. Installs a RecentWindowSink (the bounded in-process recent window) that
//      forwards to the durable PersistenceStatsSink, then flips the global
//      IntellectusLib gate via Intellectus.setEnabled(_:).
//   3. Exposes the bounded recent window for inspection (the resident daemon's
//      health/status surface reads it to prove samples are flowing).
//   4. Has an explicit, crash-free OFF state: when disabled, Intellectus is
//      gated off, the window stops growing, and `isEnabled` reports false. Off
//      is observable, not silent.
//
// Scope (Bob's DEBT-3 ruling): a minimal live observer loop, NOT a telemetry
// platform. No aggregation, no alerting, no query surface — the window is a
// bounded recent buffer and nothing more.
//
// The bounded window is the contractual piece: it holds at most `windowCapacity`
// samples (default 256). On overflow the oldest is evicted (RecentWindowSink
// FIFO ring). Memory is O(capacity) regardless of emission volume.

import Foundation
import IntellectusLib
import ObserverSink

// MARK: - Observer

/// The resident observer program: drives the IntellectusLib gate from config,
/// retains a bounded recent window of observed samples, and forwards each
/// sample to the durable stats store.
///
/// One instance lives for the lifetime of the resident daemon. It is installed
/// once at startup (`AriaResident.installManagerTelemetry`) and its
/// `refreshEnabled(from:)` is called on the monitoring-gate poll interval so a
/// moot-mgr on/off flip takes effect without a daemon restart.
///
/// ## Thread safety
///
/// `Sendable`. The recent window (`RecentWindowSink`) is internally locked; the
/// enable decision routes through `Intellectus` (lock-free atomic gate). No
/// mutable state is held directly in this final class beyond the immutable
/// window reference.
public final class Observer: Sendable {

    // MARK: - Config

    /// Default bound for the in-process recent window. 256 samples is enough to
    /// prove liveness and show a recent slice on the status surface without
    /// retaining meaningful memory (each StatSample is a small value type).
    public static let defaultWindowCapacity = 256

    // MARK: - State

    /// The bounded recent window. Public so the daemon's status surface can read
    /// `snapshot()`, `count`, and `totalReceived`.
    public let window: RecentWindowSink

    // MARK: - Initialisation

    /// Build the observer program around a durable forward sink.
    ///
    /// - Parameters:
    ///   - forward:        The durable sink each observed sample is forwarded to
    ///                     (typically a `PersistenceStatsSink`). Nil keeps the
    ///                     window-only (used in tests).
    ///   - windowCapacity: Maximum samples retained in the recent window.
    ///                     Defaults to `defaultWindowCapacity` (256).
    public init(forward: (any StatsSink)?, windowCapacity: Int = Observer.defaultWindowCapacity) {
        self.window = RecentWindowSink(capacity: windowCapacity, forward: forward)
    }

    // MARK: - Install

    /// Install this observer's window as the global Intellectus sink.
    ///
    /// Call once at startup BEFORE `refreshEnabled(from:)`. After this, every
    /// `Intellectus.report(_:)` that passes the gate lands in the recent window
    /// (and is forwarded to the durable sink).
    public func install() {
        Intellectus.install(sink: window)
    }

    // MARK: - Enable decision

    /// Decide whether the observer should be enabled, from config.
    ///
    /// Enabled when EITHER:
    ///   - the `ARIA_MCP_OBSERVER` env var is set to a truthy value
    ///     ("1", "true", "yes", "on", case-insensitive), OR
    ///   - the persisted stats-store monitoring flag is on.
    ///
    /// The env var is the operator's explicit opt-in (forces the observer on even
    /// before moot-mgr sets the store flag); the store flag is moot-mgr's
    /// broadcast signal. Either being on enables monitoring.
    ///
    /// - Parameters:
    ///   - env:        Environment map (injectable for tests).
    ///   - storeFlag:  The current persisted store monitoring flag.
    /// - Returns: `true` if monitoring should be enabled.
    public static func shouldEnable(
        env: [String: String] = ProcessInfo.processInfo.environment,
        storeFlag: Bool
    ) -> Bool {
        if envObserverEnabled(env) { return true }
        return storeFlag
    }

    /// Parse `ARIA_MCP_OBSERVER` as a boolean opt-in.
    ///
    /// Truthy values (case-insensitive): "1", "true", "yes", "on". Anything else
    /// (including absent/empty) is false. Consistent with the ARIA_MCP_* env
    /// convention used elsewhere in the resident wiring.
    static func envObserverEnabled(_ env: [String: String]) -> Bool {
        guard let raw = env["ARIA_MCP_OBSERVER"]?.lowercased(), !raw.isEmpty else { return false }
        switch raw {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    /// Apply an enable decision to the global gate and report the resulting
    /// state. This is the explicit off-state path: passing `false` gates
    /// Intellectus off (the window stops receiving) — observable via `isEnabled`.
    ///
    /// - Parameter enabled: The decided monitoring state.
    public func setEnabled(_ enabled: Bool) {
        Intellectus.setEnabled(enabled)
    }

    /// Whether the observer is currently enabled (the live Intellectus gate).
    /// `false` is the explicit off state — not silent.
    public var isEnabled: Bool {
        Intellectus.isEnabled
    }
}
