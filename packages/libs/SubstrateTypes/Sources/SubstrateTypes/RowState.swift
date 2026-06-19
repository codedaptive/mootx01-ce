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

/// The three lifecycle clusters a `RowState` belongs to, per the
/// scale-gapped raw layout above. Membership is a single
/// shift-and-mask on the state raw: `cluster(s) = (s >> 4) & 0x3`.
/// This is the canonical partition every consumer that needs an
/// active-vs-retired view must derive from — never a hand-rolled
/// raw-value boundary (the gap states 4–15 / 20–31 / 34+ are
/// undefined and a magic boundary misclassifies any state added
/// there).
///
///   A — active / becoming   (currently believed: active, pending,
///                            contested, accepted)
///   B — superseded / historical (retired but revivable: superseded,
///                            decayed, withdrawn, expired)
///   C — terminal             (retired, non-revivable: rejected,
///                            tombstoned)
public enum RowStateCluster: UInt8, Sendable, Codable, CaseIterable {
    case a = 0   // active / becoming — the currently-believed cluster
    case b = 1   // superseded / historical — retired, revivable
    case c = 2   // terminal — retired, non-revivable

    /// `true` when this is the believed/active cluster (A). Every
    /// other cluster is a retired lifecycle stage.
    public var isActive: Bool { self == .a }
}

extension RowState {
    /// The exclusive upper bound (in raw 6-bit state space, 0–63) of
    /// the active cluster (A): every defined active state — active=0,
    /// pending=1, contested=2, accepted=3 — has a raw strictly below
    /// this value, and every retired state (cluster B from 16, cluster
    /// C from 32) has a raw at or above it. It is exactly the cluster-B
    /// floor (`superseded`.rawValue == 16), which the scale-gapped
    /// layout fixes so that "raw < bound" is equivalent to
    /// `cluster(ofRawState:)?.isActive == true` for every defined raw.
    ///
    /// This is the single named boundary a storage-layer predicate uses
    /// to select the active set on the persisted 6-bit state field
    /// (e.g. SQL `WHERE g_state_cluster < activeClusterUpperBoundRaw`),
    /// where it cannot call `cluster(ofRawState:)`. Code paths that hold
    /// a decoded raw must prefer `cluster(ofRawState:)?.isActive`; this
    /// constant exists so the predicate that cannot call a function
    /// still derives from the same automaton, never a bare magic number.
    public static let activeClusterUpperBoundRaw: UInt8 = RowState.superseded.rawValue

    /// The lifecycle cluster this state belongs to, computed by the
    /// canonical `(raw >> 4) & 0x3` shift-and-mask. Cluster A is the
    /// currently-believed/active partition; clusters B and C are
    /// retired. This is the single source of the active/retired
    /// partition — consumers must not re-derive it from a raw-value
    /// boundary.
    public var cluster: RowStateCluster {
        // Boundaries 0/16/32 make the cluster a pure shift-and-mask;
        // every defined raw maps into 0...2, so force-unwrap is total.
        RowStateCluster(rawValue: (rawValue >> 4) & 0x3)!
    }

    /// `true` when this state is in the believed/active cluster (A).
    /// Equivalent to `cluster.isActive`; provided for call sites that
    /// only need the active/retired bit.
    public var isActiveCluster: Bool { cluster.isActive }

    /// Classify a raw 6-bit state value (as stored in adjective-bitmap
    /// bits 0–5) into its lifecycle cluster, or `nil` if `raw` is not
    /// one of the ten defined scale-gapped states. Callers reading the
    /// state field out of a persisted bitmap use this to derive the
    /// active/retired partition from the same automaton the rest of
    /// the system uses, rather than a hand-rolled boundary.
    public static func cluster(ofRawState raw: UInt8) -> RowStateCluster? {
        RowState(rawValue: raw)?.cluster
    }
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

extension RowState: CustomStringConvertible {
    /// English lowercase name matching RowVerb.rawValue casing.
    /// Parity with Rust RowState::Display (lowercase English).
    ///
    /// Explicit switch rather than String(describing:) because
    /// String(describing: self) calls back into CustomStringConvertible.description
    /// causing infinite recursion. The explicit switch is the only safe pattern
    /// for CustomStringConvertible on an enum without String raw value.
    public var description: String {
        switch self {
        case .active:     return "active"
        case .pending:    return "pending"
        case .contested:  return "contested"
        case .accepted:   return "accepted"
        case .superseded: return "superseded"
        case .decayed:    return "decayed"
        case .withdrawn:  return "withdrawn"
        case .expired:    return "expired"
        case .rejected:   return "rejected"
        case .tombstoned: return "tombstoned"
        }
    }
}

extension RowStateError: CustomStringConvertible {
    /// Compact state-and-verb descriptor without "illegal" prefix.
    /// GateViolation.description wraps this as "illegal state transition: {self}"
    /// to produce the canonical form the AriaMcpKit describe_gate_rejection
    /// parser expects: "illegal state transition: active --reject-->".
    ///
    /// Parity with Rust RowStateError::Display for the IllegalTransition arm.
    public var description: String {
        switch self {
        case .illegalTransition(let state, let verb):
            // English lowercase via RowState.description and RowVerb.rawValue,
            // matching the ARIA verb surface tokens.
            return "\(state) --\(verb.rawValue)-->"
        case .violatesInvariant(let msg):
            return "safety invariant violation: \(msg)"
        }
    }
}
