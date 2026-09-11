//! Dispatch-level coverage for 7 ARIA v2 lens operations through the production
//! server path — `Dispatcher::new` + `Dispatcher::handle` with a properly-formed
//! `tools/call` JSON-RPC 2.0 request.
//!
//! `dispatch_tool` is the v1 test-helper entry point. The running server never
//! reaches it (see `rust/src/lib.rs:19` and `rust/src/dispatcher.rs:193-200`).
//! Every test here goes through the path the production server uses.
//!
//! Operations covered:
//!   moot_lens_anticipate, moot_lens_bias, moot_lens_constellation,
//!   moot_lens_drift, moot_lens_latent_themes, moot_lens_overlap (refusal),
//!   moot_lens_rhythm.
//!
//! # V2 success envelope shape
//!
//! `crate::v2::render::success` produces:
//! ```json
//! {
//!   "isError": false,
//!   "content": [{ "type": "text", "text": "..." }],
//!   "structuredContent": {
//!     "surface_version": "v2",
//!     "tool": "<operation name>",
//!     "data": { /* operation-specific camelCase keys */ },
//!     "meta": { ... }
//!   }
//! }
//! ```
//!
//! The two discriminating assertions per happy-path test:
//! 1. `structuredContent.tool == <operation>` — wrong if the wrong handler ran.
//! 2. At least one named key in `structuredContent.data` is non-null — wrong if
//!    the handler was replaced by a stub returning an empty success.
//!
//! # moot_lens_overlap — current-behaviour refusal
//!
//! `CoordinatorRecallLensLower::comparison_handle` looks up the supplied
//! `comparison_estate_id` UUID in `coordinator.handles()`. The single-estate
//! `make_dispatcher()` has no extra estates registered in the coordinator, so any
//! unregistered UUID causes `comparison_handle` to return `Err(())`.
//! `execute_recall` maps `Err(())` from the lower to a `lens_unavailable` refusal
//! wrapped in `isError: true`. This test records that refusal as current behaviour.
//!
//! # Model test
//!
//! The harness shape (make_dispatcher / tools_call / dispatch_and_unwrap) is
//! copied from `aria_v2_federated_recall_dispatch_coverage_tests.rs`, which
//! already does it correctly. No test in this file calls `dispatch_tool`.

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::estate_posture::EstatePosture;
use aria_mcp::estate_registry::EstateRegistry;
use aria_mcp::jsonrpc::JSONRPCRequest;
use serde_json::json;

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

/// Builds a single-estate dispatcher using the same pattern as the federated
/// recall coverage tests.  No extra estates are registered in the coordinator.
fn make_dispatcher() -> Dispatcher {
    let registry = EstateRegistry::new_inmemory();
    Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None)
        .with_posture(EstatePosture::Live)
}

/// Wraps arguments into a well-formed `tools/call` JSON-RPC 2.0 request.
fn tools_call(name: &str, arguments: serde_json::Value) -> JSONRPCRequest {
    JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": name,
            "arguments": arguments
        }
    }))
    .expect("tools/call request must decode")
}

/// Dispatches `request` through `Dispatcher::handle`, serializes the
/// `JSONRPCResponse`, asserts the response carries a `result` (not a protocol
/// `error`), and returns the `result` value for further inspection.
///
/// A protocol-level `error` response means the tool was not found in the v2
/// catalog or a JSON-RPC framing error occurred — either is a hard failure.
fn dispatch_and_unwrap(dispatcher: &Dispatcher, request: JSONRPCRequest) -> serde_json::Value {
    let response = serde_json::to_value(dispatcher.handle(&request))
        .expect("JSONRPCResponse must serialize");
    assert!(
        response.get("error").is_none(),
        "expected a result response, not a JSON-RPC protocol error; full response: {response:?}"
    );
    response["result"].clone()
}

// ---------------------------------------------------------------------------
// Happy paths — 6 operations that succeed with an empty estate
// ---------------------------------------------------------------------------

/// moot_lens_anticipate dispatches through the v2 surface and returns the
/// typed actions shape.
///
/// `targetKind` is required by the ANTICIPATE grammar.  With an empty estate,
/// `run_anticipate` returns an empty predictions list; `project_data` wraps it
/// in `data.actions = []`, which is non-null and discriminates against a stub.
#[test]
fn lens_anticipate_dispatches_through_v2_surface_and_returns_actions_shape() {
    let dispatcher = make_dispatcher();
    let request = tools_call("moot_lens_anticipate", json!({ "targetKind": "prose" }));
    let result = dispatch_and_unwrap(&dispatcher, request);

    assert_eq!(
        result["isError"],
        json!(false),
        "moot_lens_anticipate must succeed; got: {result:?}"
    );
    // structuredContent.tool carries the operation name if and only if the
    // request reached execute_recall and was rendered through render::success.
    assert_eq!(
        result["structuredContent"]["tool"],
        "moot_lens_anticipate",
        "structuredContent.tool must be moot_lens_anticipate; got: {result:?}"
    );
    // data.actions is always present from project_data, even when empty.
    assert!(
        !result["structuredContent"]["data"]["actions"].is_null(),
        "structuredContent.data must carry actions key; got: {result:?}"
    );
}

/// moot_lens_bias dispatches through the v2 surface and returns the typed bias
/// shape.
///
/// No required args (BIAS grammar, required is empty).  With an empty estate,
/// `run_bias` returns an empty report; `project_data` always emits all four
/// array keys (`biasedFor`, `biasedAgainst`, `dismissal`, `learned`).
#[test]
fn lens_bias_dispatches_through_v2_surface_and_returns_bias_shape() {
    let dispatcher = make_dispatcher();
    let request = tools_call("moot_lens_bias", json!({}));
    let result = dispatch_and_unwrap(&dispatcher, request);

    assert_eq!(
        result["isError"],
        json!(false),
        "moot_lens_bias must succeed; got: {result:?}"
    );
    assert_eq!(
        result["structuredContent"]["tool"],
        "moot_lens_bias",
        "structuredContent.tool must be moot_lens_bias; got: {result:?}"
    );
    // biasedFor is always present from project_data, even as [].
    assert!(
        !result["structuredContent"]["data"]["biasedFor"].is_null(),
        "structuredContent.data must carry biasedFor key; got: {result:?}"
    );
}

/// moot_lens_constellation dispatches through the v2 surface and returns the
/// typed communities shape.
///
/// `wing` is required by the WING grammar.  With an empty estate,
/// `run_constellation` returns an empty communities list; `project_data` wraps
/// it in `data.communities = []`, which is non-null.
#[test]
fn lens_constellation_dispatches_through_v2_surface_and_returns_communities_shape() {
    let dispatcher = make_dispatcher();
    let request = tools_call("moot_lens_constellation", json!({ "wing": "work" }));
    let result = dispatch_and_unwrap(&dispatcher, request);

    assert_eq!(
        result["isError"],
        json!(false),
        "moot_lens_constellation must succeed; got: {result:?}"
    );
    assert_eq!(
        result["structuredContent"]["tool"],
        "moot_lens_constellation",
        "structuredContent.tool must be moot_lens_constellation; got: {result:?}"
    );
    // communities is always present from project_data, even as [].
    assert!(
        !result["structuredContent"]["data"]["communities"].is_null(),
        "structuredContent.data must carry communities key; got: {result:?}"
    );
}

/// moot_lens_drift dispatches through the v2 surface and returns the typed
/// drift shape.
///
/// `splitAt` is required by the DRIFT grammar (ISO 8601 string).  With an
/// empty estate, `run_drift` produces `before_count=0, after_count=0`; these
/// are integers (not null) in `data`.
#[test]
fn lens_drift_dispatches_through_v2_surface_and_returns_drift_shape() {
    let dispatcher = make_dispatcher();
    let request = tools_call(
        "moot_lens_drift",
        json!({ "splitAt": "2026-01-01T00:00:00Z" }),
    );
    let result = dispatch_and_unwrap(&dispatcher, request);

    assert_eq!(
        result["isError"],
        json!(false),
        "moot_lens_drift must succeed; got: {result:?}"
    );
    assert_eq!(
        result["structuredContent"]["tool"],
        "moot_lens_drift",
        "structuredContent.tool must be moot_lens_drift; got: {result:?}"
    );
    // beforeCount and afterCount are the v2-specific scalar keys.  The v1
    // content[0].text path returns a "drift: before=N after=M" prefix string
    // and no structuredContent.data at all.
    assert!(
        !result["structuredContent"]["data"]["beforeCount"].is_null(),
        "structuredContent.data must carry beforeCount key; got: {result:?}"
    );
    assert!(
        !result["structuredContent"]["data"]["afterCount"].is_null(),
        "structuredContent.data must carry afterCount key; got: {result:?}"
    );
}

/// moot_lens_latent_themes dispatches through the v2 surface and returns the
/// typed latent-themes shape.
///
/// No required args (ESTATE grammar, required is empty).  `project_data`
/// always emits `data.k` and `data.loadings`; with an empty estate these are
/// 0 and [] respectively — non-null and discriminating.
#[test]
fn lens_latent_themes_dispatches_through_v2_surface_and_returns_latent_shape() {
    let dispatcher = make_dispatcher();
    let request = tools_call("moot_lens_latent_themes", json!({}));
    let result = dispatch_and_unwrap(&dispatcher, request);

    assert_eq!(
        result["isError"],
        json!(false),
        "moot_lens_latent_themes must succeed; got: {result:?}"
    );
    assert_eq!(
        result["structuredContent"]["tool"],
        "moot_lens_latent_themes",
        "structuredContent.tool must be moot_lens_latent_themes; got: {result:?}"
    );
    // k is always emitted by project_data for LensLatentThemes.
    assert!(
        !result["structuredContent"]["data"]["k"].is_null(),
        "structuredContent.data must carry k key; got: {result:?}"
    );
}

/// moot_lens_rhythm dispatches through the v2 surface and returns the typed
/// rhythm shape.
///
/// All four args are required by the RHYTHM grammar: `bit`, `bucketSeconds`,
/// `bucketCount`, `endingAt`.  With an empty estate, `run_rhythm_from_estate`
/// returns `bucket_count = bucketCount` and `periods = []`; both are non-null.
#[test]
fn lens_rhythm_dispatches_through_v2_surface_and_returns_rhythm_shape() {
    let dispatcher = make_dispatcher();
    let request = tools_call(
        "moot_lens_rhythm",
        json!({
            "bit": "1",
            "bucketSeconds": "86400",
            "bucketCount": "32",
            "endingAt": "2026-12-31T23:59:59Z"
        }),
    );
    let result = dispatch_and_unwrap(&dispatcher, request);

    assert_eq!(
        result["isError"],
        json!(false),
        "moot_lens_rhythm must succeed; got: {result:?}"
    );
    assert_eq!(
        result["structuredContent"]["tool"],
        "moot_lens_rhythm",
        "structuredContent.tool must be moot_lens_rhythm; got: {result:?}"
    );
    // bucketCount is always emitted by project_data for LensRhythm.
    assert!(
        !result["structuredContent"]["data"]["bucketCount"].is_null(),
        "structuredContent.data must carry bucketCount key; got: {result:?}"
    );
}

// ---------------------------------------------------------------------------
// Current-behaviour refusal — moot_lens_overlap
// ---------------------------------------------------------------------------

/// FINDING: moot_lens_overlap with an unregistered comparison_estate_id
/// returns isError:true with code "lens_unavailable" through the v2 surface.
///
/// The single-estate dispatcher created by make_dispatcher() has no extra
/// estates registered in its coordinator. CoordinatorRecallLensLower::
/// comparison_handle() searches coordinator.handles() for the supplied UUID
/// and returns Err(()) when it is absent. execute_recall maps Err(()) to a
/// V2OperationalRefusal with code "lens_unavailable", wrapped in isError:true.
///
/// This test records current behaviour — NOT correct behaviour. Fix: register a
/// second estate in the coordinator before invoking the comparison lenses.
///
/// Discrimination: a stub handler short-circuiting before execute_recall would
/// produce a JSON-RPC protocol "error" (caught by dispatch_and_unwrap), or
/// return isError:false, or carry a different error code — all three would fail.
#[test]
fn lens_overlap_current_behaviour_is_lens_unavailable_refusal() {
    let dispatcher = make_dispatcher();
    // A random UUID that is not registered in the single-estate coordinator.
    // The v2 grammar (COMPARISON) admits it as a UUID field without -32602.
    let request = tools_call(
        "moot_lens_overlap",
        json!({ "comparison_estate_id": "11111111-1111-1111-1111-111111111111" }),
    );
    let result = dispatch_and_unwrap(&dispatcher, request);

    // Tool-level refusal: isError:true inside a result (not a protocol error).
    // The old v1 path would have rejected "comparison_estate_id" with -32602
    // (strict_object rejects extra keys in v1 arg maps), and dispatch_and_unwrap
    // would have panicked above — so reaching here already proves v2 decoding ran.
    assert_eq!(
        result["isError"],
        json!(true),
        "overlap with unregistered comparison_estate_id must be isError:true; got: {result:?}"
    );
    // lens_unavailable is the specific code set by execute_recall when the lower
    // returns Err(()). Any other code (e.g. estate_unavailable, method_not_found)
    // means a different code path ran — and must be investigated.
    assert_eq!(
        result["structuredContent"]["error"]["code"],
        "lens_unavailable",
        "refusal code must be lens_unavailable; got: {result:?}"
    );
}
