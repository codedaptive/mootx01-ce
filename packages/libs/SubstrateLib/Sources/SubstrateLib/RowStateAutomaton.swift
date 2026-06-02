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
import SubstrateTypes

/// The ten row states per cookbook § 9.1 / § 2.3 with explicit
/// scale-gapped raw values per the § 2.8 verification table. The
/// cluster boundaries at 0 / 16 / 32 are chosen so cluster
/// membership is a single shift-and-mask:
/// `cluster(s) = (s >> 4) & 0x3`.
///
///   Cluster A (active / becoming):   active=0, pending=1, contested=2, accepted=3
///   Cluster B (superseded / historical): superseded=16, decayed=17, withdrawn=18, expired=19
///   Cluster C (terminal):            rejected=32, tombstoned=33
///
// Phase 6.4 (decision 2026-05-28 §6.6): RowState, RowVerb, and
// RowStateError moved to SubstrateTypes. They remain visible
// here via `import SubstrateTypes`. The transition table,
// `validate`, and `check_forbidden_combinations` (all compute)
// stay in this file.

/// The transition table. `((from, verb), to)`. Any combination
/// not in this table is illegal and the validator rejects it.
///
/// Source: cookbook § 9.2.
public enum RowStateAutomaton {

    // MARK: - § 10 verb-vocabulary adapter
    //
    // The verbs reference (`Verbs.swift`) encodes the § 10 verb
    // vocabulary (withdraw, expunge, confirm, supersede, ...)
    // rather than the § 9 lifecycle vocabulary (observe, promote,
    // retract, tombstone, ...). Both vocabularies share the same
    // state set (the canonical `RowState` enum above, F11-consolidated
    // 2026-05-27) but apply different transition tables. This
    // adapter exposes the § 10 transitions; new consumers should
    // use the canonical `transition(from:on:)` below.
    //
    // S-3 enforcement: `(.accepted, "expunge")` is intentionally
    // absent from `verbTable`. Cookbook § 9.5 S-3 forbids the
    // accepted → tombstoned transition (audit-grade rows survive
    // intact). The canonical enum-keyed `transitions` table below
    // has always been correct; the verb-string table was aligned
    // in F14.

    /// Bridge for Block 2a/2b verb dispatch. Returns true iff
    /// `(from, viaVerb) → to` is a legal § 10 transition.
    public static func canTransition(from: RowState,
                                      to: RowState,
                                      viaVerb verb: String) -> Bool {
        return verbTable[VerbKey(from, verb)] == to
    }

    fileprivate struct VerbKey: Hashable {
        let s: RowState
        let v: String
        init(_ s: RowState, _ v: String) { self.s = s; self.v = v }
    }

    fileprivate static let verbTable: [VerbKey: RowState] = [
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
    ///
    /// F11 (2026-05-27): all field widths and raw values updated
    /// to cookbook v0.6 §2.3 / §2.8. Adjective bitmap layout is
    /// six 6-bit fields per Int64: state at bits 0-5, sensitivity
    /// at 6-11, exportability at 12-17, trust at 18-23, plus the
    /// state-extension and lineage-clustering flags at bits 24-25.
    public static func check(state: RowState,
                              fields: BitmapFields) throws {
        // I-22 (cookbook § 2.3 / federation): a secret row can never be
        // exportable. State-independent — holds for every row. Sensitivity
        // at bits 6-11 (secret = raw 48), exportability at 12-17 (public =
        // raw 32). Centralized here (M1/I-25) so the write gate enforces it
        // on every mutation, not only where a consumer remembers to call a
        // separate validator.
        // raw 48 = AdjectiveSensitivity.secret; raw 32 =
        // AdjectiveExportability.public_; LocusKit/Adjectives.swift is the
        // source of truth (cannot import: SubstrateLib sits below LocusKit).
        let sensitivity = (fields.adjective >> 6) & 0x3F
        let exportability = (fields.adjective >> 12) & 0x3F
        if sensitivity == 48 && exportability == 32 {
            throw RowStateError.violatesInvariant(
                "I-22: secret row cannot be exportable (sensitivity=secret + exportability=public)")
        }

        // S-1 (cookbook § 9.5.1): accepted ⇒ trust ≥ canonical.
        // Adjective bits 18-23 encode trust (6-bit per §2.3);
        // canonical = raw 3 per the §2.8 verification table.
        if state == .accepted {
            // raw 3 = Trust.canonical; LocusKit/Adjectives.swift is the
            // source of truth (cannot import: layer below LocusKit).
            let trust = (fields.adjective >> 18) & 0x3F
            if trust < 3 {
                throw RowStateError.violatesInvariant(
                    "S-1: accepted row must have trust ≥ canonical")
            }
        }

        // S-2 (cookbook § 9.5.2): withdrawn / rejected encode
        // distinct state values; assert defensively against
        // corrupted input. Adjective bits 0-5 encode state per
        // §2.3 scale-gapped layout: withdrawn=18, rejected=32.
        if state == .withdrawn || state == .rejected {
            let raw = fields.adjective & 0x3F
            if state == .withdrawn && raw != RowState.withdrawn.rawValue {
                throw RowStateError.violatesInvariant(
                    "S-2: withdrawn state must encode state=\(RowState.withdrawn.rawValue)")
            }
            if state == .rejected && raw != RowState.rejected.rawValue {
                throw RowStateError.violatesInvariant(
                    "S-2: rejected state must encode state=\(RowState.rejected.rawValue)")
            }
        }

        // S-3 (cookbook § 9.5.3): accepted MUST NOT transition to
        // tombstoned — enforced by the transition table; no
        // field-level invariant to check. (KNOWN GAP: verbTable
        // currently permits (.accepted, "expunge") → .tombstoned;
        // F14 closes this safety violation.)

        // S-4 (cookbook § 9.5.4): sensitivity floor for accepted.
        // Adjective bits 6-11 encode sensitivity (6-bit per §2.3);
        // accepted rows must have sensitivity ≤ elevated (raw 16
        // per the §2.8 verification table; the "shareable" tier).
        if state == .accepted {
            // raw 16 = AdjectiveSensitivity.elevated; LocusKit/Adjectives.swift
            // is the source of truth (cannot import: layer below LocusKit).
            let sens = (fields.adjective >> 6) & 0x3F
            if sens > 16 {
                throw RowStateError.violatesInvariant(
                    "S-4: accepted row must have sensitivity ≤ elevated")
            }
        }

        // S-5 (cookbook §9.5): "tombstoned ⇒ expunge_completed_flag = 1".
        // The previous implementation here invented a "tombstoned ⇒
        // adjective and operational bitmaps zero" check that goes
        // beyond what cookbook §9.5 specifies AND contradicts the
        // expunge architecture (bitmaps are audit substrate; the
        // CONTENT BLOB is what gets zeroed by the aging algorithm,
        // not the metadata). Defused 2026-05-27 during S-1 plumbing.
        //
        // F17 cascade (queued) will reinstate this check correctly
        // once cookbook locates `expunge_completed_flag` in either
        // §2.3 (adjective bit 24, currently labeled "state_extension
        // flag") or §2.4 (operational; reserved bits 19–23 area).
        // See palace drawer drawer_mootx01_decisions_8687ec5d613881a13c822dad
        // for the full expunge architecture design.
        //
        // Until F17 lands, tombstone transitions are gated by the
        // transition table alone (cookbook §9.2). S-3 (accepted
        // cannot expunge) is enforced there. The other safety
        // invariants S-1/S-2/S-4 below remain active.
    }
}

// RowStateError moved to SubstrateTypes (Phase 6.4).

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
