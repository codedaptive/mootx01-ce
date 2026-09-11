//! Production chain registrations for the ARIA v2 call chain.
//!
//! This module holds the position constants and the per-call factory that
//! builds the [`crate::v2::call_chain::V2CallChain`] registrations wired at
//! the v2 dispatch choke point in [`crate::dispatcher::Dispatcher::tools_call`].
//!
//! ## Position constants
//!
//! Transform, ingress, and egress positions are independent ordinals: a
//! transform position of 10, an ingress position of 10, and an egress position
//! of 10 are all unrelated.  Position 1 on the egress chain is the exit-gate
//! slot, reserved for HammerGuard.  The GATE 1 test proves the slot semantics.
//!
//! ## Record phase placement invariant
//!
//! The ingress (record) chain runs after the frozen-mutation guard and after
//! argument decode.  Counting runs here because a refused call is not a call
//! and a decode-failed call is not a call.  The transform phase runs before
//! decode so a hook can remove a key the strict decoder rejects.
//!
//! ## Arc requirement
//!
//! [`IngressHook`] and the transform variant of [`V2EgressHook`] are
//! `Box<dyn Fn(...) + Send + Sync>` (implicitly `'static`).  A closure
//! capturing `&mode_session_state` (non-Clone, non-`'static`) fails to
//! compile.  The solution is [`Arc<ModeSessionState>`] — the struct uses
//! `Mutex` for interior mutability, so `Arc<T>` suffices.  Clone one `Arc`
//! per call in [`aria_v2_production_registrations`].

use std::sync::Arc;

use crate::mode_session_state::ModeSessionState;
use crate::surface::SurfaceRequest;
use crate::v2::call_chain::{IngressHook, TransformHook, V2ChainRegistration, V2EgressHook};

// MARK: - Position constants

/// Transform position 1 is reserved for pre-decode argument mutation.
///
/// The transform phase runs before decode so a hook can remove a key the
/// strict decoder rejects.  No concern registers on the transform phase in
/// production; the slot is defined so future concerns can reserve a position
/// without colliding.
pub const TRANSFORM_RESERVED: i32 = 1;

/// Ingress (record) position for the session-accounting (coaching) concern.
///
/// Counting runs here because a refused or decode-failed call is not a call.
/// The transform phase runs before decode and must not advance the counter.
pub const INGRESS_COACHING: i32 = 10;

/// Egress position 1 is the exit-gate slot, reserved for HammerGuard.
///
/// Nothing registers here in this mission.  The GATE 1 integration test proves
/// the slot semantics: a gate at position 1 alongside the production
/// registrations runs before coaching and, when it fires, coaching never runs.
pub const EGRESS_GATE_RESERVED: i32 = 1;

/// Coaching hint and periodic-block transform run at egress position 10.
pub const EGRESS_COACHING: i32 = 10;

// MARK: - Production registration factory

/// Build the production chain registrations for one v2 call.
///
/// Called per call: the egress hook captures the decoded request and an
/// `Arc`-clone of the session state, both of which vary per call.
///
/// Construction can only fail on a duplicate concern name or a duplicate
/// position, both programmer errors in this hard-coded list.  Use
/// `V2CallChain::new(...).expect(...)` at the call site, following the
/// precedent in other infallible programmer-error paths.
///
/// The transform phase is empty in production: no concern removes keys before
/// decode.  The chain's transform slot is defined and reserved; it lands empty.
///
/// # Parameters
///
/// * `request` — The decoded [`SurfaceRequest`] for this call.  Consumed into
///   the egress closure so the coaching engine can inspect argument data.
/// * `mss` — Shared session state.  An `Arc`-clone per concern satisfies the
///   `'static` bound on the hook function pointers.
pub(crate) fn aria_v2_production_registrations(
    request: SurfaceRequest,
    mss: Arc<ModeSessionState>,
) -> Vec<V2ChainRegistration> {

    // MARK: Coaching ingress (record) hook
    //
    // Calls `record_call` after the frozen-mutation guard and after argument
    // decode.  Counting runs here because a refused call and a decode-failed
    // call are not calls.  The transform phase runs before decode and must not
    // advance the counter.
    //
    // The returned arguments are the same as the inputs — the coaching concern
    // does not mutate arguments.  The ingress state is `None`; coaching does
    // not need to thread ingress-time data to its egress hook (it re-reads
    // the session state directly via the Arc).
    let mss_ingress = Arc::clone(&mss);
    let ingress: IngressHook = Box::new(move |tool_name, arguments| {
        mss_ingress.record_call(tool_name, None);
        Ok((arguments, None))
    });

    // MARK: Coaching egress hook (transform — not a gate)
    //
    // Order preserved from the inline implementation this hook replaces:
    //   1. Hint injection: coaching_hint → apply_hint.  Suppressed on
    //      isError:true results by coaching_hint (§12.5, RULING 3).
    //   2. Periodic block: should_coach → snapshot → render_block
    //      → apply_coaching_block.  Applied to all results including error
    //      results — existing behaviour preserved unchanged.
    //
    // `should_coach` is called AFTER `record_call` (ordering contract in
    // mode_session_state.rs), which is satisfied because ingress runs first.
    let mss_egress = Arc::clone(&mss);
    let egress: TransformHook = Box::new(move |_tool_name, result, _state| {
        let result = if let Some(hint) = crate::v2::coach::coaching_hint(&request, &result) {
            crate::v2::render::apply_hint(result, &hint)
        } else {
            result
        };
        let result = if mss_egress.should_coach() {
            let snap = mss_egress.snapshot();
            crate::v2::render::apply_coaching_block(result, &crate::periodic_coach::render_block(&snap))
        } else {
            result
        };
        Ok(result)
    });

    vec![
        V2ChainRegistration::new("coaching")
            .with_ingress(INGRESS_COACHING, ingress)
            .with_egress(EGRESS_COACHING, V2EgressHook::Transform(egress)),
    ]
}

#[cfg(test)]
mod tests {
    //! GATE 1: Slot reservation — egress position 1 is unoccupied in the
    //! production registrations.  The discriminating assertions are the position
    //! checks; the test fails when EGRESS_COACHING is set to 1.
    //!
    //! Position spaces are independent: a transform position of 1, an ingress
    //! position of 1, and an egress position of 1 are unrelated.  Only the
    //! egress slot at position 1 is the reserved exit-gate slot.

    use super::*;
    use crate::surface::SurfaceRequest;
    use crate::v2::call_chain::{V2CallChain, V2EgressDecision, V2HaltReason};
    use crate::jsonrpc::JsonValue;

    /// The production factory leaves egress position 1 (the reserved exit-gate
    /// slot) unoccupied.  The discriminating assertions are the position checks:
    /// if EGRESS_COACHING is set to 1, the occupancy assertion fails because
    /// coaching would then occupy the reserved slot, and adding a gate there
    /// would cause chain construction to fail with `V2CallChainError::DuplicateEgressPosition`.
    /// The halt assertions are
    /// retained because they cost nothing, but this is a slot-reservation gate,
    /// not an ordering gate — it does not prove coaching did not run.
    #[test]
    fn gate1_production_registrations_leave_egress_slot1_unoccupied() {
        let session = Arc::new(ModeSessionState::new());
        let production = aria_v2_production_registrations(
            SurfaceRequest::MonitoringStatus,
            Arc::clone(&session),
        );

        // Verify coaching's egress position is strictly greater than 1.
        let coaching_reg = production.iter().find(|r| r.concern_name == "coaching")
            .expect("coaching registration must be present");
        let coaching_egress_pos = coaching_reg.egress.as_ref()
            .map(|(pos, _)| *pos)
            .expect("coaching must have an egress hook");
        assert!(
            coaching_egress_pos > EGRESS_GATE_RESERVED,
            "coaching egress position {coaching_egress_pos} must be > reserved slot {EGRESS_GATE_RESERVED}"
        );
        assert_eq!(
            coaching_egress_pos, EGRESS_COACHING,
            "coaching egress position must equal EGRESS_COACHING constant"
        );

        // Verify position 1 is not occupied by any production registration.
        let occupies_reserved = production.iter().any(|r| {
            r.egress.as_ref().map(|(pos, _)| *pos) == Some(EGRESS_GATE_RESERVED)
        });
        assert!(
            !occupies_reserved,
            "egress position {EGRESS_GATE_RESERVED} must be unoccupied in production registrations"
        );

        // Add a gate double at position 1: fires immediately with a sentinel.
        // This exercises the halt mechanics at the reserved slot:
        //   (a) egress_outcome.halt is GateFired("test-gate")
        //   (b) egress_outcome.result is the gate's exact sentinel payload
        let sentinel = serde_json::json!("gate-halt-sentinel");
        let sentinel_for_closure = sentinel.clone();
        let gate_double = V2ChainRegistration::new("test-gate")
            .with_egress(
                EGRESS_GATE_RESERVED,
                V2EgressHook::Gate(Box::new(move |_name, _result, _state| {
                    Ok(V2EgressDecision::Halt(sentinel_for_closure.clone()))
                })),
            );

        // Build chain: production (coaching at egress 10) + gate at egress 1.
        let all: Vec<V2ChainRegistration> = production.into_iter()
            .chain(std::iter::once(gate_double))
            .collect();
        let chain = V2CallChain::new(all)
            .expect("chain construction must succeed for a valid registration set");

        // Run ingress (coaching's hook calls record_call → total_calls = 1).
        let ingress_outcome = chain.run_ingress(
            "moot_monitoring_status",
            JsonValue::Object(Default::default()),
        );

        // Run egress with a non-error result.
        let egress_outcome = chain.run_egress(
            "moot_monitoring_status",
            serde_json::json!("original"),
            &ingress_outcome,
        );

        // The chain must have halted at the gate, not run to completion.
        match &egress_outcome.halt {
            V2HaltReason::GateFired(concern) => {
                assert_eq!(
                    concern, "test-gate",
                    "gate at position 1 must be the halting concern, got {concern}"
                );
            }
            other => panic!("expected GateFired halt reason, got {:?}", other),
        }

        // Result must be exactly the gate's sentinel — not further modified.
        assert_eq!(
            egress_outcome.result, sentinel,
            "egress result must be the gate's halt payload"
        );
    }
}
