// RowStateAutomaton.swift
//
// Row-state finite-state automaton per cookbook § 9.
//
// Every row in an estate sits in exactly one state at any time.
// The automaton specifies which transitions are legal, which
// states are reachable, and which combinations of bitmap fields
// are forbidden (I-22). The cookbook proves three properties:
//
//   reachability: every state is reachable from the initial
//                 state `pending` via some sequence of legal verbs.
//   liveness:     no state is a dead-end (every state has at
//                 least one outgoing transition or is terminal).
//   safety:       no legal sequence of verbs produces a forbidden
//                 combination of bitmap fields.
//
// CONSTITUTIONAL: every mutation routes through this automaton.
// v0.35 C1 (mutateAdjective bypassing the validator) is resolved
// in v0.36 by routing ALL mutateAdjective calls through
// transition() and rejecting any that don't have a legal
// (from, verb) → to entry.
//
// DrawerStateValidator (cookbook § 9.7) is the interface that
// LocusKit's mutation API consults before committing. The
// reference implementation here IS the validator.

import Foundation

/// The ten row states per cookbook § 9.1.
public enum RowState: String, Sendable, Codable, CaseIterable {
    case pending       // freshly captured, awaiting first observation
    case active        // visible and current
    case contested     // multiple replicas disagree
    case superseded    // replaced by a successor row
    case decayed       // matrix decay reduced confidence below threshold
    case withdrawn     // explicit retraction by user/agent
    case expired       // TTL elapsed
    case rejected      // captured but explicitly rejected on review
    case accepted      // captured AND explicitly accepted (audit-grade)
    case tombstoned    // hard-deleted (rare; only for legal compliance)
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

/// The transition table. `((from, verb), to)`. Any combination
/// not in this table is illegal and the validator rejects it.
///
/// Source: cookbook § 9.2.
public enum RowStateAutomaton {

    // MARK: - § 10 verb-vocabulary adapter
    //
    // The verbs reference (`glref-swift-Verbs.swift`) encodes the
    // § 10 verb vocabulary (withdraw, expunge, confirm, supersede,
    // ...) rather than the § 9 lifecycle vocabulary (observe,
    // promote, retract, tombstone, ...). Both vocabularies share
    // the same state set but apply different transition tables.
    // This adapter exposes the § 10 transitions; new consumers
    // should use the canonical `transition(from:on:)` below.

    /// Bridge for Block 2a/2b verb dispatch. Returns true iff
    /// `(from, viaVerb) → to` is a legal § 10 transition.
    public static func canTransition(from: RowStateValue,
                                      to: RowStateValue,
                                      viaVerb verb: String) -> Bool {
        return verbTable[VerbKey(from, verb)] == to
    }

    fileprivate struct VerbKey: Hashable {
        let s: RowStateValue
        let v: String
        init(_ s: RowStateValue, _ v: String) { self.s = s; self.v = v }
    }

    fileprivate static let verbTable: [VerbKey: RowStateValue] = [
        VerbKey(.active, "contest"):            .contested,
        VerbKey(.active, "supersede"):          .superseded,
        VerbKey(.active, "withdraw"):           .withdrawn,
        VerbKey(.active, "expunge"):            .tombstoned,
        VerbKey(.active, "decay"):              .decayed,
        VerbKey(.active, "expire"):             .expired,
        VerbKey(.pending, "confirm"):           .accepted,
        VerbKey(.pending, "reject"):            .rejected,
        VerbKey(.pending, "contest"):           .contested,
        VerbKey(.pending, "automated_confirm"): .accepted,
        VerbKey(.pending, "actuator_confirm"):  .accepted,
        VerbKey(.pending, "withdraw"):          .withdrawn,
        VerbKey(.pending, "expunge"):           .tombstoned,
        VerbKey(.contested, "confirm"):         .accepted,
        VerbKey(.contested, "reject"):          .rejected,
        VerbKey(.contested, "supersede"):       .superseded,
        VerbKey(.contested, "withdraw"):        .withdrawn,
        VerbKey(.accepted, "contest"):          .contested,
        VerbKey(.accepted, "supersede"):        .superseded,
        VerbKey(.accepted, "withdraw"):         .withdrawn,
        VerbKey(.accepted, "expunge"):          .tombstoned,
        VerbKey(.accepted, "decay"):            .decayed,
        VerbKey(.superseded, "withdraw"):       .withdrawn,
        VerbKey(.superseded, "expunge"):        .tombstoned,
        VerbKey(.superseded, "lineage_advance"):.decayed,
        VerbKey(.decayed, "withdraw"):          .withdrawn,
        VerbKey(.decayed, "expunge"):           .tombstoned,
        VerbKey(.decayed, "confirm"):           .active,
        VerbKey(.withdrawn, "confirm"):         .active,
        VerbKey(.withdrawn, "expunge"):         .tombstoned,
        VerbKey(.expired, "withdraw"):          .withdrawn,
        VerbKey(.expired, "expunge"):           .tombstoned,
        VerbKey(.rejected, "confirm"):          .accepted,
        VerbKey(.rejected, "expunge"):          .tombstoned,
    ]

    /// Legal transitions. Keys are (from, verb); values are the
    /// resulting state. Absence from this map means "illegal".
    public static let transitions: [TransitionKey: RowState] = [
        // ---- from pending ----
        TransitionKey(.pending, .observe):       .active,
        TransitionKey(.pending, .reject):        .rejected,
        TransitionKey(.pending, .retract):       .withdrawn,
        TransitionKey(.pending, .expire):        .expired,
        TransitionKey(.pending, .contest):       .contested,
        TransitionKey(.pending, .tombstone):     .tombstoned,

        // ---- from active ----
        TransitionKey(.active, .mutate):         .active,
        TransitionKey(.active, .promote):        .accepted,
        TransitionKey(.active, .retract):        .withdrawn,
        TransitionKey(.active, .supersede):      .superseded,
        TransitionKey(.active, .decay):          .decayed,
        TransitionKey(.active, .expire):         .expired,
        TransitionKey(.active, .contest):        .contested,
        TransitionKey(.active, .tombstone):      .tombstoned,

        // ---- from contested ----
        TransitionKey(.contested, .resolveContest): .active,
        TransitionKey(.contested, .retract):        .withdrawn,
        TransitionKey(.contested, .tombstone):      .tombstoned,

        // ---- from decayed ----
        TransitionKey(.decayed, .observe):       .active,    // re-observation revives
        TransitionKey(.decayed, .expire):        .expired,
        TransitionKey(.decayed, .tombstone):     .tombstoned,

        // ---- from superseded ----
        TransitionKey(.superseded, .tombstone):  .tombstoned,
        // superseded is otherwise terminal (kept for lineage)

        // ---- from withdrawn ----
        TransitionKey(.withdrawn, .tombstone):   .tombstoned,
        // withdrawn is otherwise terminal

        // ---- from expired ----
        TransitionKey(.expired, .tombstone):     .tombstoned,
        // expired is otherwise terminal

        // ---- from rejected ----
        TransitionKey(.rejected, .tombstone):    .tombstoned,
        // rejected is otherwise terminal

        // ---- from accepted ----
        // accepted is terminal (audit-grade rows survive intact)
        // tombstone is intentionally NOT permitted from accepted;
        // see cookbook § 9.5 safety invariant S-3.

        // ---- from tombstoned ----
        // tombstoned is absolute terminal.
    ]

    /// Computes the resulting state of a legal transition, or
    /// returns nil if the transition is illegal.
    public static func transition(from state: RowState,
                                   on verb: RowVerb) -> RowState? {
        return transitions[TransitionKey(state, verb)]
    }

    /// Validate that `(state, verb) → next` is legal and that
    /// the resulting field combinations satisfy I-22. Throws on
    /// any violation. This is the substrate's single mutation
    /// gate; bypassing it is forbidden (v0.36 resolves C1).
    public static func validate(
        from state: RowState,
        on verb: RowVerb,
        targetingFields fields: BitmapFields
    ) throws -> RowState {
        guard let next = transition(from: state, on: verb) else {
            throw RowStateError.illegalTransition(state, verb)
        }
        try ForbiddenCombinations.check(state: next, fields: fields)
        return next
    }
}

/// Composite key (from, verb) for the transition table.
public struct TransitionKey: Hashable, Sendable {
    public let from: RowState
    public let verb: RowVerb

    public init(_ from: RowState, _ verb: RowVerb) {
        self.from = from
        self.verb = verb
    }
}

/// The three bitmap fields whose interactions I-22 governs.
/// Per cookbook § 2.8/§2.9 (the bitmap-field verification table)
/// and § 9.5 safety invariants.
public struct BitmapFields: Sendable {
    public let adjective: UInt64
    public let operational: UInt64
    public let provenance: UInt64

    public init(adjective: UInt64, operational: UInt64,
                provenance: UInt64) {
        self.adjective = adjective
        self.operational = operational
        self.provenance = provenance
    }
}

/// Forbidden combinations per I-22 (cookbook § 2.8 + § 9.5).
///
/// These are the bit patterns that are mathematically reachable
/// in the bitmap encoding but semantically incoherent. The v0.36
/// cookbook resolves the v0.35 ambiguity by enumerating every
/// forbidden combination here; any combination not listed is
/// legal.
public enum ForbiddenCombinations {

    /// Check whether the supplied (state, fields) tuple is legal.
    /// Throws on violation. Cookbook § 9.5 (safety invariants).
    public static func check(state: RowState,
                              fields: BitmapFields) throws {
        // S-1 (cookbook § 9.5.1): accepted ⇒ trust ≥ canonical
        // Adjective bitmap bits 12-15 encode trust (per v0.35);
        // canonical = raw 3 per Adjectives.swift Trust enum.
        if state == .accepted {
            let trust = (fields.adjective >> 12) & 0xF
            if trust < 3 {
                throw RowStateError.violatesInvariant(
                    "S-1: accepted row must have trust ≥ canonical")
            }
        }

        // S-2 (cookbook § 9.5.2): withdrawn ⇒ NOT also rejected
        // The state field cannot encode two terminal verdicts.
        // Adjective bitmap bits 0-3 encode state; withdrawn=5,
        // rejected=7. They are distinct enum values — this
        // invariant is structural (the encoding ensures it) but
        // we assert defensively in case of corrupted input.
        if state == .withdrawn || state == .rejected {
            let raw = fields.adjective & 0xF
            if state == .withdrawn && raw != 5 {
                throw RowStateError.violatesInvariant(
                    "S-2: withdrawn state must encode state=5")
            }
            if state == .rejected && raw != 7 {
                throw RowStateError.violatesInvariant(
                    "S-2: rejected state must encode state=7")
            }
        }

        // S-3 (cookbook § 9.5.3): accepted MUST NOT transition to
        // tombstoned — but this is enforced by the transition
        // table; no field-level invariant to check.

        // S-4 (cookbook § 9.5.4): sensitivity floor for accepted.
        // Adjective bits 4-7 encode sensitivity; accepted rows
        // must have sensitivity ≤ 8 (the "shareable" tier).
        if state == .accepted {
            let sens = (fields.adjective >> 4) & 0xF
            if sens > 8 {
                throw RowStateError.violatesInvariant(
                    "S-4: accepted row must have sensitivity ≤ shareable")
            }
        }

        // S-5 (cookbook § 9.5.5): tombstoned ⇒ all detail bitmaps
        // zeroed. The substrate must scrub on tombstone.
        if state == .tombstoned {
            if fields.adjective != 0 || fields.operational != 0 {
                throw RowStateError.violatesInvariant(
                    "S-5: tombstoned row must zero adjective and operational bitmaps")
            }
            // Provenance is preserved on tombstone for audit
            // continuity (cookbook § 9.5.5 footnote).
        }
    }
}

public enum RowStateError: Error, Sendable, Equatable {
    case illegalTransition(RowState, RowVerb)
    case violatesInvariant(String)
}

// MARK: - Reachability proof (cookbook § 9.3)
//
// Every state is reachable from `pending` (the initial state of
// every captured row) via some legal sequence. Proof by
// construction:
//
//   pending  → ε (initial)
//   active   → pending --observe--> active
//   accepted → pending --observe--> active --promote--> accepted
//   contested→ pending --contest--> contested
//   decayed  → pending --observe--> active --decay--> decayed
//   superseded→ pending --observe--> active --supersede--> superseded
//   withdrawn→ pending --retract--> withdrawn
//   expired  → pending --expire--> expired
//   rejected → pending --reject--> rejected
//   tombstoned→ pending --tombstone--> tombstoned   (any state can tombstone EXCEPT accepted, per S-3)
//
// MARK: - Liveness proof (cookbook § 9.4)
//
// No state is a dead-end before tombstoned. Every non-terminal
// state has at least one outgoing transition. Terminal states
// (superseded, withdrawn, expired, rejected, accepted, tombstoned)
// are intentional dead-ends except for the final tombstone path.
//
// MARK: - C1 resolution (cookbook § 16.3)
//
// In v0.35, the LocusKit `mutateAdjective` operation set the
// adjective bitmap directly without consulting the validator,
// allowing forbidden combinations (notably state=accepted with
// sensitivity > shareable). In v0.36, `mutateAdjective` is
// REQUIRED to call `RowStateAutomaton.validate(from:on:targetingFields:)`
// before committing; the reference implementation here is that
// validator. v0.35 audit-log entries that violate the new
// invariants are flagged (not rejected) during migration so the
// estate owner can resolve them manually.
