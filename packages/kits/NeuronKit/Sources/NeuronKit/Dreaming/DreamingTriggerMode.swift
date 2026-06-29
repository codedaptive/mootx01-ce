// DreamingTriggerMode.swift
//
// The dreaming daemon's trigger-mode seam (NEURONKIT_SPEC § 3.1 +
// § 3.4). The spec routes the dreaming trigger mode through SolverBandit
// (§ 3.4 decision 2: "Dreaming trigger mode — timer vs event vs
// hybrid"). SolverBandit is built — see SolverBandit.swift.
//
// The bandit selects the mode per estate from observed dreaming-cycle
// reward; the daemon exposes the bandit-selected mode via
// `currentTriggerMode()`.
//
// ── ARIA boundary ────────────────────────────────────────────────────────
// `.timer`, `.event`, and `.hybrid` are RESIDENT-SCHEDULER modes, not
// caller-selectable ARIA tool arguments. The `moot_dream` ARIA tool is
// on-demand only — calling it triggers one dream cycle immediately; the
// scheduling cadence (timer / event-threshold / hybrid) is the autonomic
// governor's responsibility, selected by SolverBandit per estate. A
// caller invoking `moot_dream` has no lever over which internal mode the
// resident scheduler is currently in; those are internal substrate decisions.
//
// ── Mode wiring ─────────────────────────────────────────────────────────
// `.timer`  — `pump(now:)` fires on the configured `tickIntervalMs`
//             cadence. `pumpOnEvent` returns nil.
// `.event`  — `pumpOnEvent(observationCount:now:)` fires when the
//             dreaming queue depth (drained co-recall windows) meets
//             `DreamingPolicy.eventObservationThreshold`. `pump`
//             returns nil so the timer path cannot accidentally fire.
// `.hybrid` — both paths are active. `pump` fires on the timer cadence;
//             `pumpOnEvent` also fires on the event threshold. The host
//             loop calls both; either may produce a cycle independently.
//
// Event source: the dreaming queue depth — the count of co-recall windows
// drained from the estate's dreaming queue per cycle — is the activity signal.
// External-origin recalls enqueue windows; the daemon drains them each cycle
// and gates against `DreamingPolicy.eventObservationThreshold`.

import Foundation

/// How the dreaming daemon decides when to run a cycle.
///
/// Three distinct behaviours — no mode is an alias for another:
///
/// - `.timer`: fires on the configured `tickIntervalMs` cadence via
///   `pump(now:)`. The event path (`pumpOnEvent`) is inactive.
/// - `.event`: fires when the dreaming queue depth (drained co-recall windows)
///   meets `DreamingPolicy.eventObservationThreshold` via `pumpOnEvent`. The
///   timer path (`pump`) is inactive.
/// - `.hybrid`: both paths active — `pump` fires on cadence and
///   `pumpOnEvent` fires on the activity threshold. The host loop calls
///   both; either may produce a cycle independently.
///
/// The `SolverBandit` selects the mode each cycle via Thompson Sampling
/// based on observed dreaming-cycle reward.
public enum DreamingTriggerMode: String, Sendable, Codable, CaseIterable, Equatable {

    /// Tick purely on the configured interval. The v1 default.
    case timer

    /// Tick in response to estate activity: a dreaming queue depth
    /// at or above `DreamingPolicy.eventObservationThreshold` fires
    /// a cycle via `pumpOnEvent(observationCount:now:)`. The timer path
    /// is inactive in this mode.
    case event

    /// Combine timer cadence with event triggers. Both `pump(now:)` and
    /// `pumpOnEvent(observationCount:now:)` are active; the host loop
    /// calls both so neither signal is missed.
    case hybrid

    /// The initial trigger mode. The bandit re-selects each cycle via
    /// Thompson Sampling once sufficient reward is observed.
    public static let `default`: DreamingTriggerMode = .timer
}
