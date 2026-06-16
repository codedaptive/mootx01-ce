// SyncEngineAPI.swift
//
// Per-estate sync engine registration and sync-state query surface.
//
// GeniusLocusKit stores at most one SyncEngine per open estate. Callers
// that want sync (CloudKit, Federation, or None) inject the concrete engine
// after `open(_:owner:)` via `registerSyncEngine(_:backendName:for:)`. ARIA
// surfaces query the state through `syncStateToken(for:)` so they can report
// the real backend identity and its current state rather than a fabricated
// constant.
//
// GLK imports only the base `ConvergenceKit` protocol module (not the backend-
// specific targets ConvergenceKitNone / CloudKit / Federation). The concrete
// engine type is erased behind `any SyncEngine`; the caller supplies the human-
// readable backend name ("none", "cloudkit", "federation") at registration time.
//
// Vocabulary contract (parity with Rust — both ports must emit identical tokens
// for the same backend + state combination):
//
//   sync: local-only                          — no engine registered
//   sync: none (idle)                         — NoSyncEngine, disabled
//   sync: none (enabled, zone: <zone>)        — NoSyncEngine, enabled
//   sync: cloudkit (idle)                     — CloudKit, disabled
//   sync: cloudkit (enabled, zone: <zone>)    — CloudKit, enabled
//   sync: cloudkit (syncing, direction: <d>)  — CloudKit, mid-sync
//   sync: cloudkit (error: <e>)               — CloudKit, error
//   sync: federation (idle)                   — Federation, disabled
//   sync: federation (in-process, zone: <z>)  — Federation enabled (v1.0 in-process)
//   sync: federation (syncing, direction: <d>)— Federation mid-sync
//   sync: federation (error: <e>)             — Federation error
//
// The token "connected" is NEVER valid. The fabricated "status: connected" literal
// that this mission replaces violated the no-fabrication rule.

import ConvergenceKit
import Foundation
import OSLog

// MARK: - SyncEngineEntry

/// A paired sync engine and its human-readable backend label.
///
/// Stored in `GeniusLocusKit.syncEngines[handle]`. The `backendName` is set
/// once at registration and is immutable for the engine's lifetime on that handle.
/// Re-registering replaces the entry entirely.
struct SyncEngineEntry {
    /// The active sync engine, erased to the `SyncEngine` existential.
    let engine: any SyncEngine
    /// Human-readable backend label: "none", "cloudkit", or "federation".
    /// Callers supply this because GLK cannot recover the concrete type name
    /// from `any SyncEngine` without importing the backend-specific modules.
    let backendName: String
}

// MARK: - State formatting

/// Convert a ConvergenceKit `SyncState` + backend name to the canonical sync token.
///
/// This is the single formatting function for the `sync:` field in
/// `moot_estate_status`. The Rust port mirrors this logic in
/// `format_sync_state_token` in `interface_tools.rs`. Any change to the
/// vocabulary here MUST be reflected in the Rust port and in
/// `ARIA_MCP_INTERFACE.md`.
///
/// - Parameters:
///   - state: The `SyncState` read from the registered engine.
///   - backendName: "none", "cloudkit", or "federation".
/// - Returns: A single-line token, e.g. `"cloudkit (enabled, zone: moot.default)"`.
func syncStateDescription(state: SyncState, backendName: String) -> String {
    switch state {
    case .disabled:
        return "\(backendName) (idle)"
    case .enabled(let zone, _, _):
        if backendName == "federation" {
            // Federation wire transport is in-process at v1.0 per architecture ruling.
            // Report "in-process" rather than "connected" to avoid over-promising
            // a network transport that does not yet exist in production.
            return "federation (in-process, zone: \(zone))"
        }
        return "\(backendName) (enabled, zone: \(zone))"
    case .syncing(let direction):
        return "\(backendName) (syncing, direction: \(direction))"
    case .error(let err, _):
        return "\(backendName) (error: \(err))"
    }
}

// MARK: - GeniusLocusKit extension

public extension GeniusLocusKit {

    // MARK: - registerSyncEngine

    /// Register a sync engine for the given estate handle.
    ///
    /// Replaces any previously registered engine + label for the handle. Call
    /// after `open(_:owner:)` to wire a ConvergenceKit backend. The engine's
    /// `state` property is read lazily on each `syncStateToken(for:)` call —
    /// GLK does not drive the engine's enable/disable/push/pull lifecycle.
    ///
    /// Callers that want local-only behaviour need NOT call this method.
    /// When no engine is registered, `syncStateToken(for:)` returns `"local-only"`.
    ///
    /// - Parameters:
    ///   - engine: Concrete sync engine conforming to `SyncEngine`.
    ///   - backendName: Human-readable label: `"none"`, `"cloudkit"`, or
    ///     `"federation"`. Callers supply this because GLK imports only the base
    ///     `ConvergenceKit` protocol module and cannot recover the concrete type name.
    ///   - handle: Open estate handle.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func registerSyncEngine(
        _ engine: some SyncEngine,
        backendName: String,
        for handle: EstateHandle
    ) throws {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        syncEngines[handle] = SyncEngineEntry(engine: engine, backendName: backendName)
    }

    // MARK: - syncStateToken

    /// Return the canonical sync-status token for `moot_estate_status`.
    ///
    /// Reads the registered engine's `state` property (async, actor-isolated in
    /// the backend) and formats it with `syncStateDescription`. Returns
    /// `"local-only"` when no engine is registered.
    ///
    /// Vocabulary table (parity with Rust — both ports emit identical tokens):
    /// ```
    /// local-only                              — no engine registered
    /// none (idle)                             — NoSyncEngine disabled
    /// none (enabled, zone: <zone>)            — NoSyncEngine enabled
    /// cloudkit (idle)                         — CloudKit disabled
    /// cloudkit (enabled, zone: <zone>)        — CloudKit enabled
    /// cloudkit (syncing, direction: <d>)      — CloudKit syncing
    /// cloudkit (error: <e>)                   — CloudKit error
    /// federation (idle)                       — Federation disabled
    /// federation (in-process, zone: <zone>)   — Federation enabled (in-process v1.0)
    /// federation (syncing, direction: <d>)    — Federation syncing
    /// federation (error: <e>)                 — Federation error
    /// ```
    ///
    /// The token `"connected"` is never returned. If you see `"connected"` in a
    /// status output, it is from a stale code path that must be updated.
    ///
    /// - Parameter handle: Open estate handle.
    /// - Returns: Canonical sync-status token string.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func syncStateToken(for handle: EstateHandle) async throws -> String {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let entry = syncEngines[handle] else {
            // No engine registered — estate is local-only (no sync configured).
            return "local-only"
        }
        let state = await entry.engine.state
        return syncStateDescription(state: state, backendName: entry.backendName)
    }
}
