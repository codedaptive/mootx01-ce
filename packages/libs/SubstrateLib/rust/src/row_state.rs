// row_state.rs
//
// Row-state finite-state automaton per cookbook § 9.
//
// Every row in an estate sits in exactly one state at any time.
// The automaton specifies which transitions are legal, which
// states are reachable, and which combinations of bitmap fields
// are forbidden (I-22). The cookbook proves three properties:
//
//   reachability: every state is reachable from the initial
//                 state `Pending` via some sequence of legal verbs.
//   liveness:     no state is a dead-end (every state has at
//                 least one outgoing transition or is terminal).
//   safety:       no legal sequence of verbs produces a forbidden
//                 combination of bitmap fields.
//
// CONSTITUTIONAL: every mutation routes through this automaton.
// v0.35 C1 (mutate_adjective bypassing the validator) is resolved
// in v0.36 by routing ALL mutate_adjective calls through
// transition() and rejecting any that don't have a legal
// (from, verb) → to entry.

use std::collections::HashMap;
use std::sync::OnceLock;

// Phase 6.4 (decision 2026-05-28 §6.6): RowState, RowVerb, and
// RowStateError moved to substrate-types. Re-exported here so
// the existing `crate::row_state::RowState` paths in verbs.rs,
// audit_gate.rs, etc. keep resolving unchanged. The transition
// table + validate/check_forbidden_combinations stay below — those
// are compute, not data, and live in substrate-lib (kernel layer).
pub use substrate_types::row_state::{RowState, RowStateError, RowVerb};

/// Composite key (from, verb) for the transition table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TransitionKey {
    pub from: RowState,
    pub verb: RowVerb,
}

impl TransitionKey {
    pub const fn new(from: RowState, verb: RowVerb) -> Self {
        Self { from, verb }
    }
}

/// Build the transition table on first access. The table itself
/// is immutable after initialization. Source: cookbook § 9.2.
fn transitions() -> &'static HashMap<TransitionKey, RowState> {
    static TABLE: OnceLock<HashMap<TransitionKey, RowState>> = OnceLock::new();
    TABLE.get_or_init(|| {
        use RowState::*;
        use RowVerb::*;
        let mut m = HashMap::new();

        // ---- from Pending ----
        m.insert(TransitionKey::new(Pending, Observe), Active);
        m.insert(TransitionKey::new(Pending, Reject), Rejected);
        m.insert(TransitionKey::new(Pending, Retract), Withdrawn);
        m.insert(TransitionKey::new(Pending, Expire), Expired);
        m.insert(TransitionKey::new(Pending, Contest), Contested);
        m.insert(TransitionKey::new(Pending, Tombstone), Tombstoned);

        // ---- from Active ----
        m.insert(TransitionKey::new(Active, Mutate), Active);
        m.insert(TransitionKey::new(Active, Promote), Accepted);
        m.insert(TransitionKey::new(Active, Retract), Withdrawn);
        m.insert(TransitionKey::new(Active, Supersede), Superseded);
        m.insert(TransitionKey::new(Active, Decay), Decayed);
        m.insert(TransitionKey::new(Active, Expire), Expired);
        m.insert(TransitionKey::new(Active, Contest), Contested);
        m.insert(TransitionKey::new(Active, Tombstone), Tombstoned);

        // ---- from Contested ----
        m.insert(TransitionKey::new(Contested, ResolveContest), Active);
        // A contested memory judged false is terminally rejectable. The
        // verb-string table (verbs.rs, §10 vocabulary) has always carried
        // this edge; this entry aligns the canonical §9 lifecycle table to
        // match. Cookbook §9.2: Contested → Reject → Rejected.
        m.insert(TransitionKey::new(Contested, Reject), Rejected);
        m.insert(TransitionKey::new(Contested, Retract), Withdrawn);
        m.insert(TransitionKey::new(Contested, Tombstone), Tombstoned);

        // ---- from Decayed ----
        // revive: re-observation restores a decayed row to active
        // (cookbook §9.3 "revived"). The four Cluster-B → active
        // transitions below are the complete `revive` verb surface.
        m.insert(TransitionKey::new(Decayed, Observe), Active);
        m.insert(TransitionKey::new(Decayed, Expire), Expired);
        m.insert(TransitionKey::new(Decayed, Tombstone), Tombstoned);

        // ---- from Superseded ----
        // revive: Superseded → Active is admitted at the automaton
        // level. The automaton is stateless on (from, verb) and cannot
        // see lineage; the lineage-conflict domain rule (a superseded
        // row may not revive while a living successor holds its lineage
        // head) is enforced one layer up, at LocusKit's Estate::mutate
        // revive guard, which has store access (cookbook §6.2 / §9.3).
        m.insert(TransitionKey::new(Superseded, Observe), Active);
        m.insert(TransitionKey::new(Superseded, Tombstone), Tombstoned);
        // Superseded → Decayed is the lineage_advance path (cookbook
        // §9.3); modeled in the §10 verb table, not the lifecycle table.

        // ---- from Withdrawn ----
        // revive: a withdrawn (explicitly retracted) row may be restored
        // to active — "unwithdraw" per cookbook §9.3.
        m.insert(TransitionKey::new(Withdrawn, Observe), Active);
        m.insert(TransitionKey::new(Withdrawn, Tombstone), Tombstoned);

        // ---- from Expired ----
        // revive: a TTL-expired row may be restored to active. The new
        // active row carries no fresh TTL until a subsequent mutation
        // sets one; until then it behaves as any active row.
        m.insert(TransitionKey::new(Expired, Observe), Active);
        m.insert(TransitionKey::new(Expired, Tombstone), Tombstoned);

        // ---- from Rejected ----
        m.insert(TransitionKey::new(Rejected, Tombstone), Tombstoned);
        // otherwise terminal

        // ---- from Accepted ----
        // accepted is terminal (audit-grade rows survive intact).
        // tombstone is intentionally NOT permitted from accepted;
        // see cookbook § 9.5 safety invariant S-3.

        // ---- from Tombstoned ----
        // tombstoned is absolute terminal.

        m
    })
}

/// Computes the resulting state of a legal transition, or returns
/// None if the transition is illegal.
pub fn transition(from: RowState, verb: RowVerb) -> Option<RowState> {
    transitions().get(&TransitionKey::new(from, verb)).copied()
}

/// The three bitmap fields whose interactions I-22 governs. Per
/// cookbook § 2.8/§2.9 (the bitmap-field verification table) and
/// § 9.5 safety invariants.
#[derive(Debug, Clone, Copy)]
pub struct BitmapFields {
    pub adjective: u64,
    pub operational: u64,
    pub provenance: u64,
}

/// Validate that `(state, verb) → next` is legal and that the
/// resulting field combinations satisfy I-22. Returns Err on any
/// violation. This is the substrate's single mutation gate;
/// bypassing it is forbidden (v0.36 resolves C1).
pub fn validate(
    state: RowState,
    verb: RowVerb,
    fields: BitmapFields,
) -> Result<RowState, RowStateError> {
    let next = transition(state, verb)
        .ok_or(RowStateError::IllegalTransition(state, verb))?;
    check_forbidden_combinations(next, fields)?;
    Ok(next)
}

/// Forbidden combinations per I-22 (cookbook § 2.8 + § 9.5).
///
/// These are bit patterns that are mathematically reachable in
/// the bitmap encoding but semantically incoherent. The v0.6
/// cookbook resolves the v0.35 ambiguity by enumerating every
/// forbidden combination here; any combination not listed is
/// legal.
///
/// F11 (2026-05-27): all field widths and raw values updated to
/// cookbook v0.6 §2.3 / §2.8. Adjective bitmap layout is six 6-bit
/// fields per i64: state at bits 0-5, sensitivity at 6-11,
/// exportability at 12-17, trust at 18-23, plus the state-extension
/// and lineage-clustering flags at bits 24-25.
pub fn check_forbidden_combinations(
    state: RowState,
    fields: BitmapFields,
) -> Result<(), RowStateError> {
    // I-22 (cookbook § 2.3 / federation): a secret row can never be
    // exportable. State-independent. Sensitivity bits 6-11 (secret=48),
    // exportability bits 12-17 (public=32). Centralized (M1/I-25) so the
    // write gate enforces it on every mutation. Mirror of Swift.
    let sensitivity = (fields.adjective >> 6) & 0x3F;
    let exportability = (fields.adjective >> 12) & 0x3F;
    if sensitivity == 48 && exportability == 32 {
        return Err(RowStateError::ViolatesInvariant(
            "I-22: secret row cannot be exportable (sensitivity=secret + exportability=public)"));
    }

    // S-1 (cookbook § 9.5.1): Accepted ⇒ trust ≥ Canonical.
    // Adjective bits 18-23 encode trust (6-bit per §2.3);
    // Canonical = raw 3 per the §2.8 verification table.
    if state == RowState::Accepted {
        let trust = (fields.adjective >> 18) & 0x3F;
        if trust < 3 {
            return Err(RowStateError::ViolatesInvariant(
                "S-1: accepted row must have trust >= canonical"));
        }
    }

    // S-2 (cookbook § 9.5.2): Withdrawn / Rejected encode distinct
    // state values; assert defensively against corrupted input.
    // Adjective bits 0-5 encode state per §2.3 scale-gapped layout:
    // withdrawn=18, rejected=32.
    if state == RowState::Withdrawn || state == RowState::Rejected {
        let raw = (fields.adjective & 0x3F) as u8;
        if state == RowState::Withdrawn && raw != RowState::Withdrawn as u8 {
            return Err(RowStateError::ViolatesInvariant(
                "S-2: withdrawn state must encode state=18"));
        }
        if state == RowState::Rejected && raw != RowState::Rejected as u8 {
            return Err(RowStateError::ViolatesInvariant(
                "S-2: rejected state must encode state=32"));
        }
    }

    // S-3: Accepted MUST NOT transition to Tombstoned — enforced
    // by the transition table; no field-level invariant to check.
    // (Closed in F14: the transition table no longer permits
    // (Accepted, "expunge") → Tombstoned, and the standalone
    // expunge() verb in verbs.rs checks for Accepted at the top.)

    // S-4 (cookbook § 9.5.4): Accepted ⇒ sensitivity ≤ Elevated.
    // Adjective bits 6-11 encode sensitivity (6-bit per §2.3);
    // Elevated = raw 16 per the §2.8 verification table (the
    // "shareable" tier).
    if state == RowState::Accepted {
        let sens = (fields.adjective >> 6) & 0x3F;
        if sens > 16 {
            return Err(RowStateError::ViolatesInvariant(
                "S-4: accepted row must have sensitivity <= elevated"));
        }
    }

    // S-5 (cookbook §9.5): "tombstoned ⇒ expunge_completed_flag = 1".
    // The previous implementation here invented a "tombstoned ⇒
    // adjective and operational bitmaps zero" check that goes beyond
    // what cookbook §9.5 specifies AND contradicts the expunge
    // architecture (bitmaps are audit substrate; the CONTENT BLOB is
    // what gets zeroed by the aging algorithm, not the metadata).
    // Defused 2026-05-27 during S-1 plumbing.
    //
    // F17 cascade (queued) will reinstate this check correctly once
    // the cookbook locates `expunge_completed_flag` in either §2.3
    // (adjective bit 24, currently labeled "state_extension flag")
    // or §2.4 (operational; reserved bits 19–23 area). See palace
    // drawer drawer_mootx01_decisions_8687ec5d613881a13c822dad for
    // the full expunge architecture design.
    //
    // Until F17 lands, tombstone transitions are gated by the
    // transition table alone (cookbook §9.2). S-3 (accepted cannot
    // expunge) is enforced there. The other safety invariants
    // S-1/S-2/S-4 above remain active.

    Ok(())
}

// RowStateError + Display + Error impls moved to substrate-types (Phase 6.4).

// Reachability proof (cookbook § 9.3)
//
// Every state is reachable from `Pending` (the initial state of
// every captured row) via some legal sequence. Proof by
// construction:
//
//   Pending    → ε (initial)
//   Active     → Pending --Observe--> Active
//   Accepted   → Pending --Observe--> Active --Promote--> Accepted
//   Contested  → Pending --Contest--> Contested
//   Decayed    → Pending --Observe--> Active --Decay--> Decayed
//   Superseded → Pending --Observe--> Active --Supersede--> Superseded
//   Withdrawn  → Pending --Retract--> Withdrawn
//   Expired    → Pending --Expire--> Expired
//   Rejected   → Pending --Reject--> Rejected
//   Tombstoned → any state EXCEPT Accepted --Tombstone--> Tombstoned (S-3)
//
// Liveness proof (cookbook § 9.4)
//
// No state is a dead-end before Tombstoned. Every non-terminal
// state has at least one outgoing transition. The Cluster-B
// historical states (Superseded, Withdrawn, Expired, Decayed) each
// carry a `revive` (Observe → Active) edge in addition to tombstone,
// so they are recoverable, not dead-ends. The Cluster-C terminal
// states (Rejected, Accepted) reach only tombstone (and Accepted is
// audit-grade: S-3 forbids even that). Tombstoned is the sole
// absolute terminal.
//
// C1 resolution (cookbook § 16.3)
//
// In v0.35, the LocusKit `mutate_adjective` operation set the
// adjective bitmap directly without consulting the validator,
// allowing forbidden combinations (notably state=Accepted with
// sensitivity > shareable). In v0.36, `mutate_adjective` is
// REQUIRED to call `validate(state, verb, fields)` before
// committing; this module IS that validator. v0.35 audit-log
// entries that violate the new invariants are flagged (not
// rejected) during migration so the estate owner can resolve
// them manually.

#[cfg(test)]
mod tests {
    use super::*;

    fn fields_with_state(state_raw: u64, trust_raw: u64, sens_raw: u64) -> BitmapFields {
        // Cookbook v0.6 §2.3 packing: state bits 0-5, sensitivity bits 6-11,
        // exportability bits 12-17, trust bits 18-23.
        let adj = state_raw | (sens_raw << 6) | (trust_raw << 18);
        BitmapFields { adjective: adj, operational: 0, provenance: 0 }
    }

    #[test]
    fn pending_to_active_via_observe() {
        let next = transition(RowState::Pending, RowVerb::Observe);
        assert_eq!(next, Some(RowState::Active));
    }

    #[test]
    fn accepted_cannot_be_tombstoned() {
        // S-3: enforced by absence from transition table.
        let next = transition(RowState::Accepted, RowVerb::Tombstone);
        assert_eq!(next, None);
    }

    #[test]
    fn accepted_requires_canonical_trust() {
        // S-1: accepted with trust = verbatim (raw 0) must fail.
        // §2.3 raw values: accepted=3, trust.verbatim=0, trust.canonical=3.
        let fields = fields_with_state(RowState::Accepted as u64, 0, 0);
        let r = check_forbidden_combinations(RowState::Accepted, fields);
        assert!(r.is_err());

        // Same row with trust = canonical (raw 3) must pass.
        let fields_ok = fields_with_state(RowState::Accepted as u64, 3, 0);
        let r_ok = check_forbidden_combinations(RowState::Accepted, fields_ok);
        assert!(r_ok.is_ok());
    }

    #[test]
    fn tombstoned_preserves_bitmaps_pending_f17() {
        // S-5 defused 2026-05-27: the previous "tombstoned ⇒ bitmaps
        // zero" semantics were incorrect per cookbook §9.5 and Bob's
        // expunge architecture design. Bitmaps are audit substrate
        // and MUST persist; the content blob is what gets zeroed by
        // the aging algorithm. Test now asserts non-zero bitmaps are
        // ACCEPTED on tombstone until F17 reinstates the correct
        // `expunge_completed_flag=1` check.
        let with_metadata = BitmapFields { adjective: 1, operational: 0, provenance: 0 };
        let r = check_forbidden_combinations(RowState::Tombstoned, with_metadata);
        assert!(r.is_ok(), "tombstone must not scrub bitmaps; F17 will reinstate expunge_completed_flag check");

        let clean = BitmapFields { adjective: 0, operational: 0, provenance: 0xCAFE };
        let r_ok = check_forbidden_combinations(RowState::Tombstoned, clean);
        assert!(r_ok.is_ok());
    }

    #[test]
    fn mutate_active_stays_active() {
        let next = transition(RowState::Active, RowVerb::Mutate);
        assert_eq!(next, Some(RowState::Active));
    }

    #[test]
    fn decayed_can_revive_on_observe() {
        let next = transition(RowState::Decayed, RowVerb::Observe);
        assert_eq!(next, Some(RowState::Active));
    }

    #[test]
    fn all_cluster_b_states_revive_on_observe() {
        // revive surface (cookbook §9.3): every Cluster-B historical state
        // restores to Active via Observe. Superseded is admitted here; the
        // lineage-conflict rule is enforced at LocusKit's revive guard.
        for from in [
            RowState::Decayed,
            RowState::Withdrawn,
            RowState::Expired,
            RowState::Superseded,
        ] {
            assert_eq!(
                transition(from, RowVerb::Observe),
                Some(RowState::Active),
                "{from:?} should revive to Active via Observe"
            );
        }
    }

    #[test]
    fn terminal_cluster_c_states_do_not_revive() {
        // Rejected/Tombstoned have no Observe→Active edge; revive is refused
        // at the automaton (LocusKit's guard names the domain rule on top).
        assert_eq!(transition(RowState::Rejected, RowVerb::Observe), None);
        assert_eq!(transition(RowState::Tombstoned, RowVerb::Observe), None);
        // Accepted is live audit-grade, not historical — no revive edge.
        assert_eq!(transition(RowState::Accepted, RowVerb::Observe), None);
    }

    #[test]
    fn validate_rejects_illegal_transitions() {
        let fields = BitmapFields { adjective: 0, operational: 0, provenance: 0 };
        // Pending --Promote--> is illegal (must Observe first).
        let r = validate(RowState::Pending, RowVerb::Promote, fields);
        assert!(matches!(r, Err(RowStateError::IllegalTransition(_, _))));
    }

    // ---- contested → rejected (the fix) ----

    #[test]
    fn contested_can_be_rejected() {
        // Cookbook §9.2: Contested --Reject--> Rejected is legal.
        // A contested memory judged false must be terminally rejectable.
        let next = transition(RowState::Contested, RowVerb::Reject);
        assert_eq!(next, Some(RowState::Rejected));
    }

    #[test]
    fn accepted_cannot_be_rejected() {
        // Accepted is an audit-grade terminal state. Rejection from Accepted
        // is not in the cookbook §9.2 transition table and must be blocked.
        let next = transition(RowState::Accepted, RowVerb::Reject);
        assert_eq!(next, None);
    }
}

#[cfg(test)]
mod i22_tests {
    use super::*;
    #[test]
    fn i22_secret_cannot_be_exportable() {
        // sensitivity=secret(48) bits 6-11, exportability=public(32) bits 12-17
        let adj = (48i64 << 6) | (32i64 << 12);
        let fields = BitmapFields { adjective: adj as u64, operational: 0, provenance: 0 };
        let r = check_forbidden_combinations(RowState::Active, fields);
        assert!(matches!(r, Err(RowStateError::ViolatesInvariant(_))), "expected I-22 violation");
    }
    #[test]
    fn i22_secret_non_public_ok() {
        let adj = 48i64 << 6; // secret, exportability=private(0)
        let fields = BitmapFields { adjective: adj as u64, operational: 0, provenance: 0 };
        assert!(check_forbidden_combinations(RowState::Active, fields).is_ok());
    }
}
