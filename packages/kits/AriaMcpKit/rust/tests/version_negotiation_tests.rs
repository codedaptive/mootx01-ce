//! Protocol-version negotiation tests — Rust vertical.
//!
//! Mirrors the Swift `ServerTests` negotiation cases:
//! - A supported version is echoed exactly.
//! - An unsupported version yields the server's latest supported version
//!   (per MCP spec §3) at the JSON-RPC level (no error response).
//! - An absent version yields the latest supported version.
//! - A malformed version string yields the latest supported version.
//!
//! These tests drive the `Dispatcher` directly so they are independent of
//! the stdio framing layer.

use aria_mcp::{
    dispatcher::{Dispatcher, SUPPORTED_PROTOCOL_VERSIONS},
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};

fn make_dispatcher() -> Dispatcher {
    Dispatcher::new(EstateRegistry::new_inmemory(), "ARIA_MCP_Rust", "test", "test-serial")
}

fn initialize_with_version(dispatcher: &Dispatcher, version: Option<&str>) -> serde_json::Value {
    let params = match version {
        Some(v) => serde_json::json!({ "protocolVersion": v }),
        None => serde_json::json!({}),
    };
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": params
    });
    let request = JSONRPCRequest::decode(&raw).expect("request must decode");
    let response = dispatcher.handle(&request);
    serde_json::to_value(&response).expect("response must serialize")
}

fn protocol_version_in(response: &serde_json::Value) -> Option<&str> {
    response["result"]["protocolVersion"].as_str()
}

// --- Supported versions echoed exactly -------------------------------------

#[test]
fn supported_version_2024_11_05_is_echoed_exactly() {
    let dispatcher = make_dispatcher();
    let resp = initialize_with_version(&dispatcher, Some("2024-11-05"));
    assert_eq!(
        protocol_version_in(&resp),
        Some("2024-11-05"),
        "2024-11-05 must be echoed exactly; got: {resp}"
    );
    // No error field — initialize succeeds at the JSON-RPC level.
    assert!(resp.get("error").is_none(), "must not have an error field");
}

#[test]
fn supported_version_2025_03_26_is_echoed_exactly() {
    let dispatcher = make_dispatcher();
    let resp = initialize_with_version(&dispatcher, Some("2025-03-26"));
    assert_eq!(
        protocol_version_in(&resp),
        Some("2025-03-26"),
        "2025-03-26 must be echoed exactly; got: {resp}"
    );
    assert!(resp.get("error").is_none(), "must not have an error field");
}

#[test]
fn supported_version_2025_11_25_is_echoed_exactly() {
    // Claude Desktop's current protocol version — must be echoed exactly.
    let dispatcher = make_dispatcher();
    let resp = initialize_with_version(&dispatcher, Some("2025-11-25"));
    assert_eq!(
        protocol_version_in(&resp),
        Some("2025-11-25"),
        "2025-11-25 must be echoed exactly; got: {resp}"
    );
    assert!(resp.get("error").is_none(), "must not have an error field");
}

// --- Unsupported version → latest supported --------------------------------

#[test]
fn unsupported_version_yields_latest_supported_version() {
    // MCP spec §3: server responds with its latest supported version when the
    // client requests an unsupported one. No JSON-RPC error — the client
    // decides whether to abort after reading the returned version.
    let dispatcher = make_dispatcher();
    let resp = initialize_with_version(&dispatcher, Some("9999-01-01"));
    let latest = SUPPORTED_PROTOCOL_VERSIONS[0];
    assert_eq!(
        protocol_version_in(&resp),
        Some(latest),
        "unsupported version must yield latest supported ({latest}); got: {resp}"
    );
    assert!(resp.get("error").is_none(), "must not have an error field");
}

// --- Absent / malformed version → latest supported -------------------------

#[test]
fn absent_version_yields_latest_supported_version() {
    let dispatcher = make_dispatcher();
    let resp = initialize_with_version(&dispatcher, None);
    let latest = SUPPORTED_PROTOCOL_VERSIONS[0];
    assert_eq!(
        protocol_version_in(&resp),
        Some(latest),
        "absent version must yield latest supported ({latest}); got: {resp}"
    );
    assert!(resp.get("error").is_none(), "must not have an error field");
}

#[test]
fn malformed_version_string_yields_latest_supported_version() {
    let dispatcher = make_dispatcher();
    let resp = initialize_with_version(&dispatcher, Some("not-a-version-at-all"));
    let latest = SUPPORTED_PROTOCOL_VERSIONS[0];
    assert_eq!(
        protocol_version_in(&resp),
        Some(latest),
        "malformed version must yield latest supported ({latest}); got: {resp}"
    );
    assert!(resp.get("error").is_none(), "must not have an error field");
}

// --- Supported-versions list invariants ------------------------------------

#[test]
fn supported_versions_list_contains_expected_entries() {
    assert!(
        SUPPORTED_PROTOCOL_VERSIONS.contains(&"2024-11-05"),
        "2024-11-05 must be in the supported list"
    );
    assert!(
        SUPPORTED_PROTOCOL_VERSIONS.contains(&"2025-03-26"),
        "2025-03-26 must be in the supported list"
    );
    assert!(
        SUPPORTED_PROTOCOL_VERSIONS.contains(&"2025-11-25"),
        "2025-11-25 (Claude Desktop version) must be in the supported list"
    );
    // Most-recent version is first (the one returned for unsupported clients).
    assert_eq!(SUPPORTED_PROTOCOL_VERSIONS[0], "2025-11-25");
}
