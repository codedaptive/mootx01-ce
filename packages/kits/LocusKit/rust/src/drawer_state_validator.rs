//! Validates row state transitions against cookbook §9.2 via
//! `substrate_lib::row_state` — the single canonical implementation
//! of the row-state finite-state automaton (mandate M1: SubstrateLib
//! owns substrate math; LocusKit consumes).
//!
//! F14 cascade (2026-05-27): replaced LocusKit's parallel `TransitionVerb`
//! enum and `is_legal` table (which permitted 4 transitions cookbook §9
//! disallows — `contested → superseded`, `withdrawn/expired/superseded → active`,
//! `any → accepted`, and `any → tombstoned` including the S-3 violation
//! `accepted → tombstoned`). All four tighten under SubstrateLib's
//! transition map, which encodes the cookbook §9.2 spec exactly.
//!
//! Pure function — no I/O, no side effects. Called by
//! `DrawerStore::mutate_state` before any storage write so an illegal
//! transition surfaces as a returned error and zero rows change. S-3
//! (cookbook §9.5: Accepted MUST NOT transition to Tombstoned) is
//! enforced by SubstrateLib's transition table omitting the entry.

use crate::adjectives::State;
use crate::error::LocusKitError;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_lib::row_state::{
    transition, validate as sl_validate, BitmapFields, RowState, RowStateError, RowVerb,
};

/// Validate a proposed state transition.
///
/// - `from`: current state of the row.
/// - `to`: proposed new state. Must equal the state produced by applying
///   `via` to `from` per cookbook §9.2's transition map.
/// - `via`: the verb initiating the transition. Use `RowVerb` cases
///   directly (cookbook canonical verb namespace).
///
/// Returns `Err(LocusKitError::DisciplineViolation)` if the `(from, via)`
/// pair has no entry in cookbook §9.2 OR if the entry's target state
/// differs from the passed `to`.
pub fn validate(from: State, to: State, via: RowVerb) -> Result<(), LocusKitError> {
    // Bridge LocusKit::State → substrate_lib::RowState (raws identical
    // per cookbook §2.3; both share the F11 scale-gapped layout).
    let prior_row_state = match RowState::from_raw(from.raw_value() as u8) {
        Some(s) => s,
        None => {
            return Err(LocusKitError::DisciplineViolation {
                from: from.raw_value(),
                to: to.raw_value(),
                reason: format!(
                    "internal: cannot bridge State::{:?} (raw {}) to RowState",
                    from,
                    from.raw_value()
                ),
            });
        }
    };
    // Cookbook §9.2 transition lookup.
    let next_row_state = match transition(prior_row_state, via) {
        Some(s) => s,
        None => {
            return Err(LocusKitError::DisciplineViolation {
                from: from.raw_value(),
                to: to.raw_value(),
                reason: format!(
                    "no legal transition {:?} via {:?} in cookbook §9.2",
                    from, via
                ),
            });
        }
    };
    // Verb determines target; the caller's `to` must agree.
    if (next_row_state as u8 as i64) != to.raw_value() {
        return Err(LocusKitError::DisciplineViolation {
            from: from.raw_value(),
            to: to.raw_value(),
            reason: format!(
                "verb {:?} from {:?} produces {:?} (raw {}), not {:?}",
                via, from, next_row_state, next_row_state as u8, to
            ),
        });
    }
    Ok(())
}

/// S-1 cascade (2026-05-27): validate transition AND field-level
/// invariants in one shot. Routes through SubstrateLib's
/// `row_state::validate` which composes `transition()` with
/// `check_forbidden_combinations`, enforcing cookbook §9.5.1
/// (accepted ⇒ trust ≥ canonical) and §9.5.2 (withdrawn/rejected
/// raw-value invariants). Note: S-5 (tombstoned bitmap-scrub) was
/// defused in SubstrateLib on 2026-05-27 — see palace drawer
/// drawer_mootx01_decisions_8687ec5d613881a13c822dad for the F17
/// expunge-architecture cascade that will reinstate it correctly.
///
/// `DrawerStore::mutate_state` calls this overload; legality-only
/// callers (e.g. unit tests) continue using `validate` above.
///
/// `fields`: POST-WRITE BitmapFields (caller MUST pass the adjective
/// bitmap with the new state already encoded in bits 0-5; SubstrateLib's
/// S-2 check reads back the state from the bitmap and asserts it matches
/// the next state).
pub fn validate_with_fields(
    from: State,
    to: State,
    via: RowVerb,
    fields: BitmapFields,
) -> Result<(), LocusKitError> {
    let prior_row_state = match RowState::from_raw(from.raw_value() as u8) {
        Some(s) => s,
        None => {
            return Err(LocusKitError::DisciplineViolation {
                from: from.raw_value(),
                to: to.raw_value(),
                reason: format!(
                    "internal: cannot bridge State::{:?} (raw {}) to RowState",
                    from,
                    from.raw_value()
                ),
            });
        }
    };

    let next_row_state = match sl_validate(prior_row_state, via, fields) {
        Ok(next) => next,
        Err(RowStateError::IllegalTransition(s, v)) => {
            return Err(LocusKitError::DisciplineViolation {
                from: from.raw_value(),
                to: to.raw_value(),
                reason: format!("no legal transition {:?} via {:?} in cookbook §9.2", s, v),
            });
        }
        Err(RowStateError::ViolatesInvariant(msg)) => {
            return Err(LocusKitError::DisciplineViolation {
                from: from.raw_value(),
                to: to.raw_value(),
                reason: format!("invariant violation: {}", msg),
            });
        }
    };

    if (next_row_state as u8 as i64) != to.raw_value() {
        return Err(LocusKitError::DisciplineViolation {
            from: from.raw_value(),
            to: to.raw_value(),
            reason: format!(
                "verb {:?} from {:?} produces {:?} (raw {}), not {:?}",
                via, from, next_row_state, next_row_state as u8, to
            ),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_lib::row_state::RowVerb::*;

    // F14 cascade: tests cover the legal-transitions surface as exercised
    // through SubstrateLib's transition map. Per M1, LocusKit does not
    // re-test cookbook §9.2 itself — that's SubstrateLib's job — but
    // verifies the LocusKit-side adapter (verb mapping, state bridge,
    // error conversion) works end-to-end.

    // --- Legal transitions (verb determines target) ---

    #[test]
    fn pending_to_active_via_observe() {
        assert!(validate(State::Pending, State::Active, Observe).is_ok());
    }

    #[test]
    fn pending_to_rejected_via_reject() {
        assert!(validate(State::Pending, State::Rejected, Reject).is_ok());
    }

    #[test]
    fn pending_to_withdrawn_via_retract() {
        // F14: direct retraction is legal per cookbook §9.2 (was illegal
        // in LocusKit v0.35 which required pending → active → withdrawn).
        assert!(validate(State::Pending, State::Withdrawn, Retract).is_ok());
    }

    #[test]
    fn active_to_contested_via_contest() {
        assert!(validate(State::Active, State::Contested, Contest).is_ok());
    }

    #[test]
    fn contested_to_active_via_resolve_contest() {
        assert!(validate(State::Contested, State::Active, ResolveContest).is_ok());
    }

    #[test]
    fn active_to_decayed_via_decay() {
        assert!(validate(State::Active, State::Decayed, Decay).is_ok());
    }

    #[test]
    fn active_to_withdrawn_via_retract() {
        assert!(validate(State::Active, State::Withdrawn, Retract).is_ok());
    }

    #[test]
    fn active_to_expired_via_expire() {
        assert!(validate(State::Active, State::Expired, Expire).is_ok());
    }

    #[test]
    fn decayed_to_active_via_observe() {
        // Re-observation revives a decayed row per cookbook §9.2.
        assert!(validate(State::Decayed, State::Active, Observe).is_ok());
    }

    #[test]
    fn active_to_accepted_via_promote() {
        assert!(validate(State::Active, State::Accepted, Promote).is_ok());
    }

    #[test]
    fn active_to_tombstoned_via_tombstone() {
        assert!(validate(State::Active, State::Tombstoned, Tombstone).is_ok());
    }

    // --- Illegal transitions (cookbook §9.2 tightening) ---

    #[test]
    fn illegal_contested_to_superseded() {
        // F14: cookbook §9.2 only permits active → superseded, not contested → superseded.
        assert!(validate(State::Contested, State::Superseded, Supersede).is_err());
    }

    #[test]
    fn legal_withdrawn_to_active_revive() {
        // revive (cookbook §9.3): withdrawn → active via Observe — unwithdraw.
        assert!(validate(State::Withdrawn, State::Active, Observe).is_ok());
    }

    #[test]
    fn legal_expired_to_active_revive() {
        // revive (cookbook §9.3): expired → active via Observe — TTL revive.
        assert!(validate(State::Expired, State::Active, Observe).is_ok());
    }

    #[test]
    fn legal_superseded_to_active_revive() {
        // revive (cookbook §9.3): the automaton admits superseded → active; the
        // lineage-conflict rule is enforced at Estate::mutate's revive guard,
        // not in this stateless transition check.
        assert!(validate(State::Superseded, State::Active, Observe).is_ok());
    }

    #[test]
    fn illegal_tombstoned_to_accepted() {
        // F14: tombstoned is absolute terminal.
        assert!(validate(State::Tombstoned, State::Accepted, Promote).is_err());
    }

    #[test]
    fn illegal_accepted_to_tombstoned_s3() {
        // S-3 (cookbook §9.5): Accepted MUST NOT transition to Tombstoned.
        // SubstrateLib's transition map omits the entry; this is the
        // safety-invariant fix F14 was designed to deliver.
        assert!(validate(State::Accepted, State::Tombstoned, Tombstone).is_err());
    }

    #[test]
    fn illegal_rejected_to_active() {
        assert!(validate(State::Rejected, State::Active, Observe).is_err());
    }

    #[test]
    fn illegal_accepted_to_active() {
        assert!(validate(State::Accepted, State::Active, Observe).is_err());
    }

    // ---- contested → rejected (the fix) ----

    #[test]
    fn contested_to_rejected_via_reject() {
        // Cookbook §9.2: a contested memory judged false is terminally
        // rejectable. Both Pending and Contested may transition via Reject.
        assert!(validate(State::Contested, State::Rejected, Reject).is_ok());
    }

    #[test]
    fn accepted_to_rejected_illegal() {
        // Accepted is an audit-grade terminal; reject from Accepted must fail.
        // This pinned the S-3-class invariant for the reject verb: only
        // Pending and Contested are legal sources.
        assert!(validate(State::Accepted, State::Rejected, Reject).is_err());
    }

    #[test]
    fn active_to_rejected_illegal() {
        // Active → Reject is not in the §9.2 transition table.
        // Only Pending and Contested may be rejected.
        assert!(validate(State::Active, State::Rejected, Reject).is_err());
    }

    // --- Error message carries the relevant context ---

    #[test]
    fn error_carries_raw_values_and_cookbook_reference() {
        let err = validate(State::Active, State::Pending, Observe).unwrap_err();
        match err {
            LocusKitError::DisciplineViolation { from, to, reason } => {
                assert_eq!(from, State::Active.raw_value());
                assert_eq!(to, State::Pending.raw_value());
                assert!(
                    reason.contains("§9.2"),
                    "reason should reference cookbook §9.2: got {:?}",
                    reason
                );
            }
            other => panic!("expected DisciplineViolation, got {:?}", other),
        }
    }
}
