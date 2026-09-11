//! Dispatch-level coverage for `moot_federated_recall` — the one Rust gap
//! identified in Unit 2 of V2_COVERAGE_CLOSE.
//!
//! `moot_federated_recall` is a v2-surface operation decoded by
//! `surface::SelectedSurface::decode` and executed by `execute_federated_recall`
//! in `surface.rs`. It does NOT pass through the v1 `dispatch_tool` convenience
//! function. Tests here go through `Dispatcher::new` + `Dispatcher::handle` with
//! a properly-formed `tools/call` JSON-RPC 2.0 request — the same path the
//! production server uses.
//!
//! # Expected behavior — single-estate dispatcher (no peer grants)
//!
//! `SelectedOrchestrationLower::federated_search` iterates registered peer
//! handles. When the registry has no extra estates the candidate list is
//! empty, `candidates.into_iter().next()` returns `None`, and the lower
//! returns `Err(V2OrchestrationFailure::FederatedAccessUnavailable)`.
//! `render_orchestration` maps every non-`EstateUnavailable` failure to
//! `code: "orchestration_unavailable"` and wraps it in an `isError: true`
//! refusal. `Dispatcher::handle` wraps that as a JSON-RPC "result" response
//! (not an "error" response) containing the tool-level refusal.
//!
//! # Gate discrimination
//!
//! `structuredContent.error.code == "orchestration_unavailable"` proves the
//! `execute_federated_recall` handler ran. A stub that short-circuited before
//! the decoder would produce a JSON-RPC `error` response (no `result`), while
//! the real path produces `result` containing `{ isError: true, structuredContent:
//! { error: { code: "orchestration_unavailable" } } }`.

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::estate_posture::EstatePosture;
use aria_mcp::jsonrpc::JSONRPCRequest;
use serde_json::json;

fn make_dispatcher() -> Dispatcher {
    let registry = EstateRegistry::new_inmemory();
    Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None)
        .with_posture(EstatePosture::Live)
}

fn tools_call(name: &str, arguments: serde_json::Value) -> JSONRPCRequest {
    JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": name,
            "arguments": arguments
        }
    })).expect("tools/call request must decode")
}

/// Dispatches `moot_federated_recall` against a single-estate dispatcher with
/// no registered peers. Asserts:
/// - The JSON-RPC response has a `result` (not an `error`) — the tool ran.
/// - `result.isError == true` — tool-level refusal, not a protocol fault.
/// - `result.structuredContent.error.code == "orchestration_unavailable"` —
///   proves `execute_federated_recall` reached the lower and got
///   `V2OrchestrationFailure::FederatedAccessUnavailable`.
///
/// A stub short-circuiting before the surface decoder would return a JSON-RPC
/// `error` response instead of a `result`, so the `result.isError` assertion
/// is already the discriminating gate.
#[test]
fn federated_recall_no_peer_estates_returns_orchestration_unavailable_refusal() {
    let dispatcher = make_dispatcher();
    let request = tools_call("moot_federated_recall", json!({}));
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response must serialize");

    // The response must be a successful JSON-RPC delivery (has "result", not "error").
    // A method-not-found would have "error" with no "result" key.
    assert!(
        response.get("error").is_none(),
        "moot_federated_recall must not produce a JSON-RPC protocol error; got: {response:?}"
    );
    let result = &response["result"];
    assert!(
        result.is_object(),
        "response must have a result object; got: {response:?}"
    );

    // isError: true — tool-level refusal, not a success.
    assert_eq!(
        result["isError"],
        json!(true),
        "no-peer federated_recall must produce isError:true; got result: {result:?}"
    );

    // structuredContent.error.code == "orchestration_unavailable" proves
    // execute_federated_recall reached and re-wrapped FederatedAccessUnavailable.
    assert_eq!(
        result["structuredContent"]["error"]["code"],
        "orchestration_unavailable",
        "error code must be orchestration_unavailable for no-peer estate; got: {result:?}"
    );

    // surface_version: "v2" confirms the v2 envelope path was used.
    assert_eq!(
        result["structuredContent"]["surface_version"],
        "v2",
        "structuredContent must carry surface_version v2; got: {result:?}"
    );
}

/// Dispatches `moot_federated_recall` with a `requesterEstateID` that does
/// not match the default estate. The lower gate returns `EstateUnavailable`,
/// which `render_orchestration` maps to `code: "estate_unavailable"`. This
/// confirms the requester-ID validation path is exercised separately from
/// the no-peer path above.
#[test]
fn federated_recall_spoofed_requester_estate_id_returns_estate_unavailable_refusal() {
    let dispatcher = make_dispatcher();
    let unknown_id = uuid::Uuid::new_v4().to_string();
    let request = tools_call(
        "moot_federated_recall",
        // Rust decoder uses snake_case field names; Swift uses camelCase.
        // The field is "requester_estate_id" in the Rust decoder.
        json!({ "requester_estate_id": unknown_id }),
    );
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("response must serialize");

    assert!(
        response.get("error").is_none(),
        "spoofed requesterEstateID must not produce a JSON-RPC protocol error; got: {response:?}"
    );
    let result = &response["result"];
    assert_eq!(
        result["isError"],
        json!(true),
        "spoofed requesterEstateID must produce isError:true; got: {result:?}"
    );
    assert_eq!(
        result["structuredContent"]["error"]["code"],
        "estate_unavailable",
        "error code must be estate_unavailable for non-default requesterEstateID; got: {result:?}"
    );
}
