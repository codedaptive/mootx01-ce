// DreamingTriggerMode.swift
//
// The dreaming daemon's trigger-mode seam (NEURONKIT_SPEC § 3.1 +
// § 3.4). The spec routes the dreaming trigger mode through SolverBandit
// (§ 3.4 decision 2: "Dreaming trigger mode — timer vs event vs
// hybrid"). SolverBandit is not built yet (mission NK-BANDIT), so this
// enum is the fixed seam the later mission attaches to: the daemon reads
// its trigger mode from here, defaulting to `.timer`, and carries NO
// dependency on a SolverBandit type that does not exist.
//
// When NK-BANDIT lands, the bandit becomes the source that selects the
// mode per estate from observed reward; the daemon keeps consuming this
// same enum, so the attachment is additive and nothing here changes.

import Foundation

/// How the dreaming daemon decides when to run a cycle.
///
/// v1 default is `.timer`: the daemon ticks on the policy's
/// `tickIntervalMs` cadence (and on demand via `triggerDreamingCycle`).
/// `.event` and `.hybrid` are declared so the trigger taxonomy is
/// complete and the future SolverBandit (NK-BANDIT) has concrete arms to
/// select between; the daemon treats any non-`.timer` mode as
/// timer-equivalent until that mission wires the event source, because
/// no substrate event stream is reachable through the estate surface
/// today.
public enum DreamingTriggerMode: String, Sendable, Codable, CaseIterable, Equatable {

    /// Tick purely on the configured interval. The v1 default.
    case timer

    /// Tick in response to substrate events (e.g. new RecallTrace
    /// ingest). Seam for NK-BANDIT; not event-driven in v1.
    case event

    /// Combine timer cadence with event triggers. Seam for NK-BANDIT;
    /// behaves as `.timer` in v1.
    case hybrid

    /// The v1 default trigger mode. Fixed to `.timer` until NK-BANDIT
    /// supplies a learned selection.
    public static let `default`: DreamingTriggerMode = .timer
}
