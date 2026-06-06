// GeniusLocusKitTelemetry.swift
//
// Per-estate rollup telemetry for GeniusLocusKit — GLK_ROLLUPS_001.
//
// WHAT THIS FILE DOES
// Declares the metric name constants for the `geniuslocus.estate.*` namespace
// and the shared inline helper `glkEmit` that wraps Intellectus.report with
// the correct construction. Actual emit call sites live in EstateCoordinator,
// EstateLifecycle, and VerbSurface — this file is the canonical source of
// metric names so they cannot drift across files.
//
// DESIGN: OFF-PATH IS FREE
// All emit calls use `Intellectus.report(@autoclosure)`. When monitoring is
// disabled (the default), the autoclosure is NEVER evaluated — cost is a
// single Atomic<Bool> load (~1 ns, lock-free). Estate coordination results
// are byte-identical whether monitoring is on or off.
//
// METRIC NAMESPACE
// All metrics are under `geniuslocus.estate.*` to distinguish these per-estate
// rollups from per-kit metrics emitted by LocusKit, VectorKit, and CorpusKit
// (which use `locus.*`, `vector.*`, `corpus.*` respectively).
//
// CALLER-SUPPLIED TIMESTAMPS
// All emit sites receive `now: Date` as a parameter per the fleet determinism
// rule (CLAUDE.md: never call Date() inside an engine). The `ts` field is
// `now.timeIntervalSince1970`.
//
// METRICS EMITTED (one sample set per estate, tagged by estate_id):
//
//   geniuslocus.estate.mount_state_transition
//     value = 1.0 (one transition)
//     tags: estate_id, state (mounted | quiesced | draining | unmounted)
//
//   geniuslocus.estate.provision
//     value = 1.0 (one provision event)
//     tags: estate_id, kind (GLK | CorpusOnly | LocusOnly)
//
//   geniuslocus.estate.noun_count
//     value = drawer count (Double)
//     tags: estate_id
//     emitted at open() if monitoring is on — snapshot of the estate's
//     drawer count at admission time (zero for fresh estates, non-zero
//     for re-opened existing ones).
//
//   geniuslocus.estate.verb_error
//     value = 1.0 (one error event)
//     tags: estate_id, verb
//     emitted when a verb call crosses the error boundary in remap().

import Foundation
import IntellectusLib

// MARK: - Metric name constants

/// Canonical metric names for the `geniuslocus.estate.*` telemetry namespace.
///
/// Every emit site imports this enum so names cannot drift. Adding a new
/// metric here is the only place the name is authored.
enum GLKMetricName {

    /// A per-estate mount state transition (mounted/quiesced/draining/unmounted).
    /// Tagged: `estate_id`, `state`.
    static let mountStateTransition = "geniuslocus.estate.mount_state_transition"

    /// A provisioning event (create + open + wiring) for a new estate.
    /// Tagged: `estate_id`, `kind`.
    static let provision = "geniuslocus.estate.provision"

    /// Snapshot of the estate's active drawer count at admission time.
    /// Tagged: `estate_id`.
    static let nounCount = "geniuslocus.estate.noun_count"

    /// A verb error crossing the GLK estate boundary in `remap()`.
    /// Tagged: `estate_id`, `verb`.
    static let verbError = "geniuslocus.estate.verb_error"
}

// MARK: - Shared emit helper

/// Emit a `geniuslocus.estate.*` metric through `Intellectus`.
///
/// Wraps `Intellectus.report` so each call site is a single line. The
/// `@autoclosure` on the `Intellectus.report` call means this helper is
/// itself an ordinary (non-autoclosure) call — the autoclosure optimisation
/// lives inside `Intellectus.report(_:)`. The caller supplies `now` so no
/// clock is read inside this helper (fleet determinism rule).
///
/// - Parameters:
///   - name:  Metric name from `GLKMetricName.*`.
///   - value: The measured quantity.
///   - tags:  String key-value context. Must always include `estate_id`.
///   - now:   Caller-supplied timestamp. Converted to epoch seconds for `ts`.
@inline(__always)
func glkEmit(name: String, value: Double, tags: [String: String], now: Date) {
    Intellectus.report(.metric(
        name: name,
        value: value,
        tags: tags,
        ts: now.timeIntervalSince1970
    ))
}
