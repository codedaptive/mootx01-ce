//! rem_cycle_table.rs — the shared REM-cycle dispatch table.
//!
//! Dreaming is ONE engine parameterised by four cadences (NEURONKIT_SPEC § 12.6).
//! This file defines the table that both drivers — the resident Autonomic Governor
//! (iterate every tick, run every due cycle in-process) and the `mootx01 dream`
//! dream_runner (iterate once, run every due cycle, exit) — share. Neither driver
//! re-defines the table; both call through it.
//!
//! Entry shape: `RemCycleEntry` names the cycle (for logging), records the cadence
//! in seconds (documentation/observability), and identifies the cycle via
//! `RemCycleKind` so drivers can call the right daemon method. The run-fn is NOT
//! stored as a closure (fn pointers and &mut self are awkward together; a simple
//! `match` on kind is cleaner). Mirrors Swift `RemCycleTable.swift`.
//!
//! T12 (BETA) is complete: `run_beta_cycle` is filled and the variant is
//! renamed `Beta` (was `BetaSeam` before T14). No re-plumbing of the governor
//! or dream_runner was needed. T13 (OMEGA) is complete — `Omega` is live.

/// Identifies one of the four REM consolidation cadences (NEURONKIT_SPEC § 12.6).
/// Both the governor tick and the dream_runner switch on this to call the matching
/// `DreamingDaemon` method, without storing daemon-mutating closures in the table.
/// Mirrors Swift `RemCycleKind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemCycleKind {
    /// 30-second queue-drain cycle: form fresh co-recall tunnels from the dreaming
    /// queue. Due iff the queue has pending items AND the timer interval has elapsed.
    /// Implemented in T9/T8; run-fn is `DreamingDaemon::pump`.
    Alpha,
    /// Daily consolidation: cross-event links over the last 24 h of recall_trace;
    /// EWC decay; bump attempts. Implemented in T11; run-fn is
    /// `DreamingDaemon::run_theta_cycle`.
    Theta,
    /// Weekly prune / GC of consolidated + co-recall-counts stores (memory-only).
    /// Implemented in T12; run-fn is `DreamingDaemon::run_beta_cycle`.
    Beta,
    /// Biweekly retire of dreamed tunnels no longer reinforced by recall.
    ///  / recall-driven dreaming — implemented; run-fn is `DreamingDaemon::run_omega_cycle`.
    Omega,
}

/// One row in the REM dispatch table.
///
/// `cadence_secs` is documentation / observability only — the actual due-check is
/// performed by the daemon via `theta_due` / `beta_due` / `omega_due`. The driver
/// reads `name` for log messages and switches on `kind` to fire the cycle.
/// Mirrors Swift `RemCycleEntry`.
pub struct RemCycleEntry {
    /// Human-readable name for log messages (e.g. "REM-ALPHA").
    pub name: &'static str,
    /// Default cadence in seconds (documentation; the daemon's due-check is
    /// authoritative). 30 s / 86400 s / 604800 s / 1209600 s.
    pub cadence_secs: f64,
    /// Discriminant the driver matches to call the right daemon method.
    pub kind: RemCycleKind,
}

/// The four REM-cycle entries, in firing-priority order: ALPHA (fastest, most
/// frequent) → THETA → BETA → OMEGA (slowest). Both the governor tick and the
/// dream_runner iterate this slice; neither defines its own cycle list.
///
/// ALPHA is listed first so it drains pending queue work before the longer-window
/// cycles run — correct because a fresh THETA run should see updated co-recall
/// counts that ALPHA has already bumped in the same invocation.
/// Mirrors Swift `remCycleTable`.
pub fn rem_cycle_table() -> [RemCycleEntry; 4] {
    [
        RemCycleEntry {
            name: "REM-ALPHA",
            cadence_secs: 30.0,
            kind: RemCycleKind::Alpha,
        },
        RemCycleEntry {
            name: "REM-THETA",
            cadence_secs: 86_400.0, // 24 h
            kind: RemCycleKind::Theta,
        },
        RemCycleEntry {
            name: "REM-BETA",
            cadence_secs: 604_800.0, // 7 days
            kind: RemCycleKind::Beta,
        },
        RemCycleEntry {
            name: "REM-OMEGA",
            cadence_secs: 1_209_600.0, // 14 days
            kind: RemCycleKind::Omega,
        },
    ]
}
