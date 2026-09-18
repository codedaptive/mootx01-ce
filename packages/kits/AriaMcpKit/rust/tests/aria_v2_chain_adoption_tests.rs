//! Integration-level adoption tests for the V2CallChain wiring.
//!
//! The call chain has three phases with independent position spaces:
//! transform (pre-decode), ingress/record (post-guard, post-decode), egress.
//!
//! The GATE 1 slot-reservation proof (egress position 1 unoccupied in the
//! production registrations) lives in the in-crate unit test at
//! `src/v2/chain_registry.rs #[cfg(test)]` because it requires access to the
//! `pub(crate)` production factory.
//!
//! The GATE 2 record-phase proofs live in the in-crate module at
//! `src/dispatcher.rs #[cfg(test)]::frozen_command_tests`.
//!
//! This file proves the chain is WIRED into the running Dispatcher through
//! observable behaviour at the integration level, using the public API only.
//!
//! ## What these tests prove
//!
//! GATE 5 (wiring): A `moot_monitoring_status` call on its 25th invocation
//! returns a coaching block in the response text.  Without the egress
//! transform the block never fires.
//!
//! GATE 2 (record-phase placement): The 24th `moot_monitoring_status` call does
//! NOT carry a coaching block; the 25th DOES.  This proves `record_call`
//! advanced the counter exactly once per admitted call — if the record phase
//! were never running, the counter stays at 0 and should_coach never fires.
//! If the record phase were running twice per call, coaching would fire at
//! call 13, not 25.
//!
//! GATE 6 (transform wiring): A hook registered on the transform phase strips
//! a decoder-rejected key before decode runs, and the call succeeds.  This
//! test fails if the transform phase is not wired before decode.

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::estate_posture::EstatePosture;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::jsonrpc::JSONRPCRequest;

fn tools_call(dispatcher: &Dispatcher, tool: &str, args: serde_json::Value) -> serde_json::Value {
    let raw = serde_json::json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": { "name": tool, "arguments": args }
    });
    let request = JSONRPCRequest::decode(&raw).expect("request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

fn make_live_dispatcher() -> Dispatcher {
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None)
}

/// Returns true if the response carries a periodic coaching block.
///
/// The block is identified by the rendered block marker `[Moot coaching`,
/// which is the prefix emitted by `periodic_coach::render_block` on every
/// coaching invocation.  Using the full literal prefix avoids false positives
/// from tool output that happens to mention a coaching-related word (e.g.
/// `moot_monitoring_status` naming a coaching setting in its output).
fn has_coaching_block(response: &serde_json::Value) -> bool {
    let text = response["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or("");
    text.contains("[Moot coaching")
}

/// GATE 5 (integration, wiring): the egress transform fires at the default
/// cadence of 25 calls.
///
/// If the chain were not wired, `should_coach()` and `render_block` would
/// never be called and the coaching block would never appear.
#[test]
fn gate5_chain_is_wired_egress_fires_coaching_block_at_call_25() {
    let dispatcher = make_live_dispatcher();

    // Calls 1–24 must NOT carry the coaching block.
    for n in 1..=24 {
        let resp = tools_call(&dispatcher, "moot_monitoring_status", serde_json::json!({}));
        assert!(
            !has_coaching_block(&resp),
            "call {n}: coaching block must not appear before the 25th call; got {}",
            resp
        );
    }

    // Call 25 MUST carry the coaching block.
    let resp_25 = tools_call(&dispatcher, "moot_monitoring_status", serde_json::json!({}));
    assert!(
        has_coaching_block(&resp_25),
        "call 25: coaching block must appear at the default cadence; got {}",
        resp_25
    );
}

/// GATE 2 (integration, record phase once per call): the coaching block fires
/// at exactly call 25, not earlier.  This proves `record_call` runs exactly
/// once per admitted call.  If the record phase ran twice per call the counter
/// would hit 25 after 13 calls; if it never ran the block never appears.
///
/// This is a subset of GATE 5 — the firing-at-25 assertion also implicitly
/// proves once-per-call record-phase execution.
#[test]
fn gate2_record_phase_fires_record_call_exactly_once_per_admitted_v2_call() {
    let dispatcher = make_live_dispatcher();

    // Calls 1–24: no coaching block yet.
    for n in 1..=24 {
        let resp = tools_call(&dispatcher, "moot_monitoring_status", serde_json::json!({}));
        assert!(
            !has_coaching_block(&resp),
            "call {n}: early coaching block means the record phase is running more than once per call"
        );
    }

    // Call 25: coaching block fires — counter is exactly 25.
    let resp_25 = tools_call(&dispatcher, "moot_monitoring_status", serde_json::json!({}));
    assert!(
        has_coaching_block(&resp_25),
        "call 25: missing coaching block means the record phase is not running (counter never reached 25)"
    );
}

/// GATE 2 (integration, frozen): a frozen v2 mutation does not trigger the
/// coaching block even after 25 refusals.
///
/// This is the integration-level proof that the record phase does not run on
/// frozen refusals.  The in-crate
/// `gate2_frozen_v2_mutation_refusal_leaves_session_counter_at_zero` test
/// provides the counter-zero proof directly.
#[test]
fn gate2_frozen_v2_mutations_do_not_feed_the_coaching_counter() {
    let frozen = Dispatcher::new(
        EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial", None,
    ).with_posture(EstatePosture::Frozen);

    // 25 frozen mutations — counter must never reach 25, so no coaching block.
    for n in 1..=25 {
        let resp = tools_call(
            &frozen,
            "moot_file_memory",
            serde_json::json!({
                "content": "must not land",
                "subject": "gate2-frozen-integration",
                "location": "gate2",
            }),
        );
        // The call is refused.
        assert_eq!(
            resp["result"]["isError"],
            serde_json::json!(true),
            "frozen v2 mutation must be refused; call {n}"
        );
        // No coaching block on refused calls.
        assert!(
            !has_coaching_block(&resp),
            "call {n}: coaching block on a frozen refusal means the record phase ran before the frozen guard"
        );
    }
}

/// GATE 6 (integration, transform wiring): a hook on the transform phase strips
/// a decoder-rejected key before decode runs, and the call succeeds.
///
/// `moot_file_memory`'s allowed-key set does not include "inject_key".  Without
/// the transform phase the decoder sees the extra key and returns an invalidParams
/// error.  With the transform phase wired before decode the hook removes the key
/// and the call reaches the substrate cleanly.
///
/// This test fails when the transform phase is not wired before the surface
/// decoder call in `tools_call`.
#[test]
fn gate6_transform_hook_strips_decoder_rejected_key_and_call_succeeds() {
    use aria_mcp::v2::call_chain::{PreDecodeHook, V2ChainRegistration};

    let mut dispatcher = make_live_dispatcher();

    // Register a transform hook that removes "inject_key" before decode.
    // "inject_key" is not in moot_file_memory's allowed-key set; the decoder
    // rejects it with invalidParams if it arrives at the decode step.
    // PreDecodeHook is Arc<dyn Fn> so registrations can be reused across
    // multiple handle calls on a shared-reference dispatcher.
    let hook: PreDecodeHook = std::sync::Arc::new(|_tool_name: &str, mut args: aria_mcp::jsonrpc::JsonValue| {
        if let aria_mcp::jsonrpc::JsonValue::Object(ref mut map) = args {
            map.remove("inject_key");
        }
        Ok(args)
    });
    dispatcher.pre_decode_registrations = vec![
        V2ChainRegistration::new("inject-key-stripper")
            .with_transform(1, hook),
    ];

    // Dispatch with the extra key present — without the transform wired this
    // returns an invalidParams error; with it the call succeeds.
    let resp = tools_call(
        &dispatcher,
        "moot_file_memory",
        serde_json::json!({
            "content": "gate6 transform proof",
            "subject": "gate6-transform-proof",
            "location": "gate6",
            "inject_key": "must be stripped before decode",
        }),
    );

    // The call must succeed: isError must be absent or false.
    let is_error = resp["result"]["isError"].as_bool().unwrap_or(false);
    assert!(
        !is_error,
        "transform hook must have stripped inject_key before decode; got {}",
        resp
    );
}
