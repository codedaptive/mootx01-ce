// RemCycleTable.swift
//
// The shared REM-cycle dispatch table (ADR-021 Phase 6, T11).
//
// Dreaming is ONE engine parameterized by four cadences (NEURONKIT_SPEC § 12.6).
// This file defines the table that both drivers — the resident Autonomic Governor
// (.timer: iterate every tick, run every due cycle in-process) and the
// `mootx01 dream` dream_runner (.event: iterate once, run every due cycle,
// exit) — share. Neither driver re-defines the table; both call through it.
//
// Entry shape: `RemCycleEntry` names the cycle (for logging), records the cadence
// in seconds (for comments/docs), and identifies the cycle via `RemCycleKind` so
// drivers can call the right daemon method. The due-check and run-fn are
// intentionally NOT stored as closures: actor isolation prevents capturing
// actor-isolated `DreamingDaemon` state in an escaping closure without complex
// Sendable gymnastics. Instead, `RemCycleKind` is the discriminant; the driver
// switches on it to call the appropriate `DreamingDaemon` method.
//
// T12 (BETA) is complete: `runBetaCycle` is filled and the variant is
// renamed `.beta` (was `.betaSeam` before T14). No re-plumbing of the governor
// or dream_runner was needed. T13 (OMEGA) is complete — `.omega` is live.
//
// Mirror: Rust `rem_cycle_table.rs` (same entry shape, same four entries).

import Foundation

// MARK: - REM cycle kinds

/// Identifies one of the four REM consolidation cadences (NEURONKIT_SPEC § 12.6).
/// Both the governor and the dream_runner switch on this to call the matching
/// `DreamingDaemon` method, without storing actor-crossing closures in the table.
public enum RemCycleKind: Sendable, Equatable, CaseIterable {
    /// 30-second queue-drain cycle: form fresh co-recall tunnels from the
    /// dreaming queue. Due iff the queue has pending items AND the timer
    /// interval has elapsed. Implemented in T9/T8; run-fn is `DreamingDaemon.pump`.
    case alpha
    /// Daily consolidation: cross-event links over the last 24 h of recall_trace;
    /// EWC decay; bump attempts. Implemented in T11; run-fn is
    /// `DreamingDaemon.runThetaCycle`.
    case theta
    /// Weekly prune / GC of consolidated + co-recall-counts stores (memory-only).
    /// Implemented in T12; run-fn is `DreamingDaemon.runBetaCycle`.
    case beta
    /// Biweekly retire of dreamed tunnels no longer reinforced by recall.
    /// T13 / ADR-021 Phase 7 — implemented; run-fn is `DreamingDaemon.runOmegaCycle`.
    case omega
}

// MARK: - REM cycle entry

/// One row in the REM dispatch table.
///
/// `cadenceSecs` is documentation / observability only — the actual due-check
/// is performed by the daemon via `timerDue`, `thetaDue`, `betaDue`, or
/// `omegaDue`. The driver reads `name` for log messages and switches on `kind`
/// to fire the cycle.
public struct RemCycleEntry: Sendable {
    /// Human-readable name for log messages (e.g. "REM-ALPHA").
    public let name: String
    /// Default cadence in seconds (documentation; the daemon's due-check is
    /// authoritative). 30 s / 86400 s / 604800 s / 1209600 s.
    public let cadenceSecs: Double
    /// Discriminant the driver switches on to call the right daemon method.
    public let kind: RemCycleKind
}

// MARK: - Shared table (defined once, consumed by both drivers)

/// The four REM-cycle entries, in firing-priority order: ALPHA (fastest, most
/// frequent) → THETA → BETA → OMEGA (slowest). Both the governor tick and the
/// dream_runner iterate this slice; neither defines its own cycle list.
///
/// ALPHA is listed first so it drains pending queue work before the longer-window
/// cycles run — correct because a fresh THETA run should see updated co-recall
/// counts that ALPHA has already bumped in the same invocation.
public let remCycleTable: [RemCycleEntry] = [
    RemCycleEntry(
        name: "REM-ALPHA",
        cadenceSecs: 30,
        kind: .alpha
    ),
    RemCycleEntry(
        name: "REM-THETA",
        cadenceSecs: 86_400, // 24 h
        kind: .theta
    ),
    RemCycleEntry(
        name: "REM-BETA",
        cadenceSecs: 604_800, // 7 days (T12 / ADR-021 Phase 7)
        kind: .beta
    ),
    RemCycleEntry(
        name: "REM-OMEGA",
        cadenceSecs: 1_209_600, // 14 days (T13 / ADR-021 Phase 7)
        kind: .omega
    ),
]
