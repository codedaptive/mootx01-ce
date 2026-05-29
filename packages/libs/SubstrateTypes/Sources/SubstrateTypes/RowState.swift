// RowState.swift
//
// Phase 6.4 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.6)
// Moved from SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift.
//
// The three pure-data types that describe row lifecycle:
//   - RowState — the ten cookbook §2.3 / §9.1 scale-gapped states
//   - RowVerb  — the twelve cookbook §10 verbs the automaton accepts
//   - RowStateError — typed error variant returned by automaton validation
//
// The transition table itself and the validate/check-forbidden
// logic stay in SubstrateLib's RowStateAutomaton.swift — that's
// compute, not data, so it belongs in the kernel layer until the
// algebra/kernel split lands.

import Foundation

/// The ten row states per cookbook §9.1 / §2.3 with explicit
/// scale-gapped raw values per the §2.8 verification table. The
/// cluster boundaries at 0 / 16 / 32 are chosen so cluster
/// membership is a single shift-and-mask:
/// `cluster(s) = (s >> 4) & 0x3`.
///
///   Cluster A (active / becoming):       active=0, pending=1,
///                                        contested=2, accepted=3
///   Cluster B (superseded / historical): superseded=16, decayed=17,
///                                        withdrawn=18, expired=19
///   Cluster C (terminal):                rejected=32, tombstoned=33
///
/// F11 (2026-05-27) consolidation: this enum was previously
/// String-backed with auto-incremented integer raws and shared a
/// module with a duplicate `RowState` in `Verbs.swift` that
/// already carried the correct values. F11 deletes the duplicate
/// and pivots `RowState` to the canonical UInt8 encoding.
public enum RowState: UInt8, Sendable, Codable, CaseIterable {
    case active      = 0     // visible and current (most rows start here)
    case pending     = 1     // freshly captured proposal awaiting confirmation
    case contested   = 2     // multiple replicas disagree
    case accepted    = 3     // captured AND explicitly accepted (audit-grade)
    case superseded  = 16    // replaced by a successor row
    case decayed     = 17    // matrix decay reduced confidence below threshold
    case withdrawn   = 18    // explicit retraction by user/agent
    case expired     = 19    // TTL elapsed
    case rejected    = 32    // captured but explicitly rejected on review
    case tombstoned  = 33    // hard-deleted (rare; only for legal compliance)
}

/// Mutations recognized by the automaton. Maps onto cookbook
/// § 10 verbs plus a few internal events.
public enum RowVerb: String, Sendable, Codable, CaseIterable {
    case capture        // initial creation
    case observe        // first read after capture
    case mutate         // edit existing row
    case retract        // user/agent withdraws
    case promote        // pending → active or active → accepted
    case reject         // mark as rejected
    case supersede      // replaced by successor
    case decay          // matrix decay below threshold
    case expire         // TTL elapsed
    case contest        // replica disagreement detected
    case resolveContest // disagreement resolved
    case tombstone      // legal-compliance hard delete
}

public enum RowStateError: Error, Sendable, Equatable {
    case illegalTransition(RowState, RowVerb)
    case violatesInvariant(String)
}
