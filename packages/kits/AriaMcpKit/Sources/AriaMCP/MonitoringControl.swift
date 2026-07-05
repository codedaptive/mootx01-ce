// MonitoringControl.swift
//
// Injection seam for daemon monitoring state. AriaMcpKit defines the protocol;
// the serve host layer (AriaResident in Swift, runtime.rs in Rust) provides
// the concrete implementation wrapping the StatsStore. This keeps AriaMcpKit
// free of ObserverSink / IntellectusLib — the separation established in the
// resident-mode architecture.
//
// The read-write split maps to the two call paths of `moot_monitoring_status`:
//   - absent `enabled` arg  → read()  → reports current effective state
//   - present `enabled` arg → set(_:) → writes flag, reports new effective state
//
// Nil from read() means the store is present but the flag cannot be read
// (transient error). Return nil from a nil-monitoringControl means no store
// is wired at all. Both cases report "unavailable" in the tool response so
// state is never fabricated — never invent "disabled" when the true answer
// is "unknown".

import Foundation

/// Injection seam for daemon telemetry monitoring state.
///
/// The concrete implementation lives in the serve host layer (AriaResident)
/// wrapping a `StatsStore`. AriaMcpKit stores only this protocol reference —
/// no ObserverSink import, no IntellectusLib import.
///
/// - `read()` returns `nil` on transient store error or when no store is wired.
/// - `set(_:)` persists the flag; best-effort (errors are logged by the
///   implementation, not surfaced to the caller).
///
/// Both methods are `async` because `StatsStore` is an actor and its API is
/// `async throws`. The Rust mirror uses sync equivalents.
public protocol MonitoringControl: Sendable {
    /// Return the current monitoring-enabled flag, or `nil` if it cannot be
    /// read (transient store error). `nil` ≠ `false` — do not substitute one
    /// for the other in any response.
    func read() async -> Bool?

    /// Persist `enabled` as the new monitoring flag. Best-effort: errors are
    /// logged by the implementation and do not throw. Callers may follow with
    /// `read()` to confirm the persisted value when accuracy matters.
    func set(_ enabled: Bool) async
}
