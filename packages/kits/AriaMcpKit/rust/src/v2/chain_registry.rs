//! Production chain registrations for the ARIA v2 call chain.
//!
//! This module holds the position constants and the per-call factories that
//! build the [`crate::v2::call_chain::V2CallChain`] registrations wired at
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
//! decode so a hook can remove or add a key before the strict decoder sees it.
//!
//! ## Arc requirement
//!
//! [`IngressHook`] and the transform variant of [`V2EgressHook`] are
//! `Box<dyn Fn(...) + Send + Sync>` (implicitly `'static`).  A closure
//! capturing `&mode_session_state` (non-Clone, non-`'static`) fails to
//! compile.  The solution is [`Arc<ModeSessionState>`] — the struct uses
//! `Mutex` for interior mutability, so `Arc<T>` suffices.  Clone one `Arc`
//! per call in the factory functions.

use std::sync::Arc;

use crate::jsonrpc::JsonValue;
use crate::mode_registry::ModeDeclaration;
use crate::mode_session_state::ModeSessionState;
use crate::surface::SurfaceRequest;
use crate::v2::call_chain::{IngressHook, PreDecodeHook, TransformHook, V2ChainRegistration, V2EgressHook};

// MARK: - Position constants

/// Transform position 1: used by the mode concern to strip the `mode` global
/// modifier and inject the sticky recall `answer` arg before decode.
///
/// The transform phase runs before `AriaSurfaceDecoder` so a hook can remove
/// or add a key before the strict decoder sees the arguments.  The mode concern
/// occupies this position in production via `aria_v2_pre_decode_registrations`.
pub const TRANSFORM_RESERVED: i32 = 1;

/// Mode concern reads the pending declaration at ingress position 5, before
/// coaching at position 10 clears it.
///
/// Returns the `unknown_hint` text as per-concern ingress state so the mode
/// egress hook at position 20 can append the hint without re-reading mutex state.
pub const INGRESS_MODE: i32 = 5;

/// Ingress (record) position for the session-accounting (coaching) concern.
///
/// Counting runs here because a refused or decode-failed call is not a call.
/// The transform phase runs before decode and must not advance the counter.
pub const INGRESS_COACHING: i32 = 10;

/// Egress position 1 is the exit-gate slot, reserved for HammerGuard.
///
/// Nothing registers here in this module.  The GATE 1 integration test proves
/// the slot semantics: a gate at position 1 alongside the production
/// registrations runs before coaching and, when it fires, coaching never runs.
pub const EGRESS_GATE_RESERVED: i32 = 1;

/// Coaching hint and periodic-block transform run at egress position 10.
pub const EGRESS_COACHING: i32 = 10;

/// Mode hint egress runs at position 20, after the coaching hint at position 10.
///
/// Appends an `unknown_hint` line when the transform phase parsed a mode
/// declaration whose name or variant is not recognised.  Recognised modes
/// (e.g. `Recall=Auto`) produce no hint here.
pub const EGRESS_MODE: i32 = 20;

// MARK: - Pre-decode registration factory

/// Build the pre-decode (transform-phase) chain registration for one v2 call.
///
/// Called per call from `Dispatcher::tools_call` before the surface decoder
/// runs. These registrations carry ONLY transform hooks; no ingress or egress
/// hooks are present.
///
/// The mode concern's transform hook performs two jobs, in order:
///   1. **Recall answer injection:** when `answer` is absent and the tool is
///      `moot_memory_search` and the session has a sticky Recall variant, injects
///      the variant's answer-mode raw value as the `answer` arg before decode.
///      Per-call explicit `answer` always wins — injection only fires when absent.
///   2. **Mode arg stripping:** strips the `mode` global modifier so the strict
///      decoder never sees it, unless the operation owns `mode` in its
///      `input_schema` (collision).  Parses the declaration and stashes it in
///      `mss.set_pending_declaration` for the post-decode ingress/egress hooks.
///
/// # Parameters
///
/// * `mss` — Shared session state.  An `Arc`-clone per registration satisfies the
///   `'static` bound on the hook function pointer.
pub(crate) fn aria_v2_pre_decode_registrations(
    mss: Arc<ModeSessionState>,
) -> Vec<V2ChainRegistration> {

    // MARK: Mode transform hook (position 1)
    //
    // Two responsibilities (in order):
    //   1. Recall answer injection for moot_memory_search.
    //   2. Mode arg stripping and pending-declaration stash.
    let mss_transform = Arc::clone(&mss);
    let transform: PreDecodeHook = Arc::new(move |tool_name: &str, mut arguments| {
        // --- Recall answer injection ---
        // Per-call explicit `answer` always wins.  Only inject when the key is
        // absent, the tool is moot_memory_search, and a sticky Recall variant is set.
        if tool_name == "moot_memory_search" {
            // Mutate the in-house JsonValue::Object map directly via pattern match.
            // JsonValue does not expose as_object_mut(); we destructure instead.
            if let JsonValue::Object(ref mut args_obj) = arguments {
                if !args_obj.contains_key("answer") {
                    if let Some(answer_mode) = mss_transform.sticky_recall_answer_mode() {
                        args_obj.insert(
                            "answer".to_owned(),
                            JsonValue::String(answer_mode.to_owned()),
                        );
                    }
                }
            }
        }

        // --- Mode arg stripping ---
        // Ownership is read at runtime from crate::v2::catalog::selected_registry() —
        // the v2 registry, not the v1 projected-tool list.  Currently three operations declare
        // `mode` in their v2 input_schema: moot_reclassify_fdc, moot_palace_import,
        // moot_vault_import.  An operation added later that declares `mode` is excluded here
        // automatically, without a code change.  Keys for owning operations are left untouched.
        let mut pending_decl: Option<ModeDeclaration> = None;
        let mode_value = arguments
            .as_object()
            .and_then(|m| m.get("mode"))
            .cloned();

        if let Some(mode_value) = mode_value {
            let registry = crate::v2::catalog::selected_registry();
            let operation_owns_mode = registry
                .operation(tool_name)
                .and_then(|op| op.input_schema.get("properties"))
                .and_then(|props| props.as_object())
                .map(|props_obj| props_obj.contains_key("mode"))
                .unwrap_or(false);

            if !operation_owns_mode {
                // Strip the global modifier so the strict decoder never sees it.
                // Pattern-match directly on JsonValue::Object — no as_object_mut().
                if let JsonValue::Object(ref mut args_obj) = arguments {
                    args_obj.remove("mode");
                }
                // Parse the declaration; stash for the post-decode ingress hooks.
                if let Some(mode_str) = mode_value.as_str() {
                    pending_decl = Some(ModeDeclaration::parse(mode_str));
                }
            }
        }

        // Write the stash whether or not `mode` was present.  A None stash means
        // "no mode declared this call" — the ingress hooks treat None as a no-op.
        mss_transform.set_pending_declaration(pending_decl);
        Ok(arguments)
    });

    vec![
        V2ChainRegistration::new("mode")
            .with_transform(TRANSFORM_RESERVED, transform),
        V2ChainRegistration::new("report_withheld").with_transform(2, Arc::new(|_, mut arguments| {
            if let JsonValue::Object(ref mut args) = arguments {
                super::report_withheld::configure(args.remove("report_withheld"));
            }
            Ok(arguments)
        })),
    ]
}

// MARK: - Production registration factory

/// Build the post-decode production chain registrations for one v2 call.
///
/// Called per call: the egress hook captures the decoded request and an
/// `Arc`-clone of the session state, both of which vary per call.
///
/// Three registrations are returned:
///   - `"mode"`: ingress at position 5, egress at position 20.
///   - `"coaching"`: ingress at position 10, egress at position 10.
///   - `"report_withheld"`: conditional metadata egress at position 30.
///
/// **Ingress order** (5 before 10): the mode ingress reads `pending_declaration`
/// and returns its `unknown_hint` as per-concern state, before coaching at
/// position 10 reads the same stash and calls `record_call`.
///
/// **Egress order** (10 before 20): coaching hint fires first; mode hint appends
/// after it.
///
/// Construction can only fail on a duplicate concern name or a duplicate
/// position, both programmer errors in this hard-coded list.  Use
/// `V2CallChain::new(...).expect(...)` at the call site.
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

    // MARK: Mode ingress hook (position 5)
    //
    // Reads `pending_declaration` set by the transform hook and returns the
    // declaration's `unknown_hint` text as per-concern ingress state.  The mode
    // egress hook at position 20 receives this state and calls `apply_hint`.
    //
    // Does NOT clear `pending_declaration` — the coaching ingress at position 10
    // clears it after reading it for `record_call`.
    let mss_mode_ingress = Arc::clone(&mss);
    let mode_ingress: IngressHook = Box::new(move |_tool_name, arguments| {
        let decl = mss_mode_ingress.pending_declaration();
        // Per-concern state: bare unknown_hint text as an in-house JsonValue::String,
        // or None.  render::apply_hint adds the "hint: " prefix — pass bare text here.
        // IngressHook returns Option<crate::jsonrpc::JsonValue>, not serde_json::Value.
        let state: Option<JsonValue> = decl
            .as_ref()
            .and_then(|d| d.unknown_hint())
            .map(JsonValue::String);
        Ok((arguments, state))
    });

    // MARK: Mode egress hook (position 20)
    //
    // Applies the unknown-mode hint to the result when per-concern state is
    // present.  Recognised modes (e.g. Recall=Auto) have no unknown_hint so
    // this hook is a no-op for them.  Never fires on error results
    // (render::apply_hint re-checks isError for safety).
    let mode_egress: TransformHook = Box::new(|_tool_name, result, state| {
        let hint = state
            .and_then(|s| s.as_str())
            .map(|s| s.to_owned());
        let result = match hint {
            Some(h) => crate::v2::render::apply_hint(result, &h),
            None => result,
        };
        Ok(result)
    });

    // MARK: Coaching ingress (record) hook (position 10)
    //
    // Reads `pending_declaration` (already consumed by the mode ingress at
    // position 5), then clears it and calls `record_call` with the declaration
    // so the sticky state and call counters are updated for this call.
    //
    // Counting runs here because a refused or decode-failed call is not a call.
    // The transform phase runs before decode and must not advance the counter.
    let mss_ingress = Arc::clone(&mss);
    let ingress: IngressHook = Box::new(move |tool_name, arguments| {
        let decl = mss_ingress.pending_declaration();
        mss_ingress.clear_pending_declaration();
        mss_ingress.record_call(tool_name, decl.as_ref());
        Ok((arguments, None))
    });

    // MARK: Coaching egress hook (position 10, transform — not a gate)
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
        V2ChainRegistration::new("mode")
            .with_ingress(INGRESS_MODE, mode_ingress)
            .with_egress(EGRESS_MODE, V2EgressHook::Transform(mode_egress)),
        V2ChainRegistration::new("coaching")
            .with_ingress(INGRESS_COACHING, ingress)
            .with_egress(EGRESS_COACHING, V2EgressHook::Transform(egress)),
        V2ChainRegistration::new("report_withheld").with_egress(30,
            V2EgressHook::Transform(Box::new(|_, result, _| Ok(super::report_withheld::egress(result))))),
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

        // Build chain: production (mode at egress 20, coaching at egress 10) + gate at egress 1.
        let all: Vec<V2ChainRegistration> = production.into_iter()
            .chain(std::iter::once(gate_double))
            .collect();
        let chain = V2CallChain::new(all)
            .expect("chain construction must succeed for a valid registration set");

        // Run ingress (mode ingress reads pending_declaration = None; coaching ingress
        // calls record_call → total_calls = 1).
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
