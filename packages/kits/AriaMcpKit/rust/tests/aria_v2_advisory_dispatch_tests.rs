//! Dispatcher-level gates for `update_available` and `version_skew` advisories
//! on `moot_estate_ping` and `moot_estate_status`.
//!
//! Tests here go through `Dispatcher::new` + `Dispatcher::handle` with a
//! properly-formed `tools/call` JSON-RPC 2.0 request — the same path the
//! production server uses. Removing the wiring in `dispatcher.rs` that passes
//! the advisory to `surface::execute` will turn the "present" assertions RED
//! while leaving the "absent" assertions green, proving discrimination.
//!
//! `update_available`: wired via `Dispatcher::with_update_advisory(provider)`.
//! Provider is an `Arc<dyn Fn() -> Option<String> + Send + Sync>` evaluated
//! only for ping and status operations, not map/drain/rebuild/timing.
//!
//! `version_skew`: wired via `Dispatcher::with_version_skew(string)`. Injected
//! at startup; empty string means "no advisory".

use aria_mcp::{
    dispatcher::{Dispatcher, UpdateAdvisoryProvider},
    estate_registry::EstateRegistry,
    jsonrpc::JSONRPCRequest,
};
use serde_json::json;
use std::sync::Arc;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// The advisory string for `update_available` used across all tests.
const UPDATE_ADVISORY: &str =
    "v9.9.9 is available (installed 1.0.33) — upgrade with `mootx01 upgrade`";

/// The advisory string for `version_skew` used across all tests.
const SKEW_ADVISORY: &str =
    "plugin 1.0.15 expects binary \u{2265} 1.0.15; binary is 1.0.11 — run `mootx01 upgrade`";

/// Build an in-memory dispatcher with no advisory providers. Use
/// `with_update_advisory` / `with_version_skew` to attach providers.
fn base_dispatcher() -> Dispatcher {
    let registry = EstateRegistry::new_inmemory();
    Dispatcher::new(registry, "aria-mcp-test", "test", "test-serial", None)
}

/// Build a provider that always returns the given advisory string.
fn fixed_provider(advisory: &'static str) -> UpdateAdvisoryProvider {
    Arc::new(move || Some(advisory.to_owned()))
}

/// Call a tool through the live dispatcher and return the full JSON-RPC response.
fn call(dispatcher: &Dispatcher, tool: &str) -> serde_json::Value {
    let request = JSONRPCRequest::decode(&json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": tool, "arguments": {} }
    }))
    .expect("tools/call request must decode");
    serde_json::to_value(dispatcher.handle(&request)).expect("response must serialize")
}

/// Extract `result.structuredContent.data` from the response.
fn data(response: &serde_json::Value) -> &serde_json::Value {
    &response["result"]["structuredContent"]["data"]
}

// ---------------------------------------------------------------------------
// update_available — ping
// ---------------------------------------------------------------------------

/// Gate: `update_available` surfaces in `moot_estate_ping` structured data when
/// a provider returning a non-None string is attached to the dispatcher.
///
/// Removing the `self.update_advisory.as_ref()` argument from the
/// `surface::execute` call in `dispatcher.rs` will cause this to fail:
/// `data["update_available"]` will be null/absent instead of the expected string.
#[test]
fn update_available_provider_surfaces_in_ping() {
    let dispatcher =
        base_dispatcher().with_update_advisory(Some(fixed_provider(UPDATE_ADVISORY)));
    let response = call(&dispatcher, "moot_estate_ping");
    let d = data(&response);
    assert_eq!(
        d["update_available"].as_str(),
        Some(UPDATE_ADVISORY),
        "moot_estate_ping must carry update_available when provider is set; \
         structured data: {d}",
    );
}

/// Gate: `update_available` is absent from `moot_estate_ping` structured data
/// when no provider is attached (the default).
#[test]
fn no_update_available_provider_omits_key_from_ping() {
    let dispatcher = base_dispatcher(); // no update_advisory provider
    let response = call(&dispatcher, "moot_estate_ping");
    let d = data(&response);
    assert!(
        d.as_object().expect("data must be an object").get("update_available").is_none(),
        "moot_estate_ping must NOT carry update_available when no provider is set; \
         structured data: {d}",
    );
}

// ---------------------------------------------------------------------------
// update_available — status
// ---------------------------------------------------------------------------

/// Gate: `update_available` surfaces in `moot_estate_status` structured data
/// when a provider returning a non-None string is attached to the dispatcher.
#[test]
fn update_available_provider_surfaces_in_status() {
    let dispatcher =
        base_dispatcher().with_update_advisory(Some(fixed_provider(UPDATE_ADVISORY)));
    let response = call(&dispatcher, "moot_estate_status");
    let d = data(&response);
    assert_eq!(
        d["update_available"].as_str(),
        Some(UPDATE_ADVISORY),
        "moot_estate_status must carry update_available when provider is set; \
         structured data: {d}",
    );
}

/// Gate: `update_available` is absent from `moot_estate_status` structured data
/// when no provider is attached.
#[test]
fn no_update_available_provider_omits_key_from_status() {
    let dispatcher = base_dispatcher(); // no update_advisory provider
    let response = call(&dispatcher, "moot_estate_status");
    let d = data(&response);
    assert!(
        d.as_object().expect("data must be an object").get("update_available").is_none(),
        "moot_estate_status must NOT carry update_available when no provider is set; \
         structured data: {d}",
    );
}

// ---------------------------------------------------------------------------
// version_skew — ping
// ---------------------------------------------------------------------------

/// Gate: `version_skew` surfaces in `moot_estate_ping` structured data when
/// a non-empty skew string is injected via `with_version_skew`.
///
/// Removing the `&self.version_skew` argument from the `surface::execute` call
/// in `dispatcher.rs` will cause this to fail.
#[test]
fn version_skew_surfaces_in_ping() {
    let dispatcher =
        base_dispatcher().with_version_skew(SKEW_ADVISORY.to_owned());
    let response = call(&dispatcher, "moot_estate_ping");
    let d = data(&response);
    assert_eq!(
        d["version_skew"].as_str(),
        Some(SKEW_ADVISORY),
        "moot_estate_ping must carry version_skew when a skew advisory is set; \
         structured data: {d}",
    );
}

/// Gate: `version_skew` is absent from `moot_estate_ping` structured data when
/// no skew advisory is set (default empty string).
#[test]
fn no_version_skew_omits_key_from_ping() {
    let dispatcher = base_dispatcher(); // version_skew defaults to ""
    let response = call(&dispatcher, "moot_estate_ping");
    let d = data(&response);
    assert!(
        d.as_object().expect("data must be an object").get("version_skew").is_none(),
        "moot_estate_ping must NOT carry version_skew when no advisory is set; \
         structured data: {d}",
    );
}

// ---------------------------------------------------------------------------
// version_skew — status
// ---------------------------------------------------------------------------

/// Gate: `version_skew` surfaces in `moot_estate_status` structured data when
/// a non-empty skew string is injected via `with_version_skew`.
#[test]
fn version_skew_surfaces_in_status() {
    let dispatcher =
        base_dispatcher().with_version_skew(SKEW_ADVISORY.to_owned());
    let response = call(&dispatcher, "moot_estate_status");
    let d = data(&response);
    assert_eq!(
        d["version_skew"].as_str(),
        Some(SKEW_ADVISORY),
        "moot_estate_status must carry version_skew when a skew advisory is set; \
         structured data: {d}",
    );
}

/// Gate: `version_skew` is absent from `moot_estate_status` structured data
/// when no skew advisory is set (default empty string).
#[test]
fn no_version_skew_omits_key_from_status() {
    let dispatcher = base_dispatcher(); // version_skew defaults to ""
    let response = call(&dispatcher, "moot_estate_status");
    let d = data(&response);
    assert!(
        d.as_object().expect("data must be an object").get("version_skew").is_none(),
        "moot_estate_status must NOT carry version_skew when no advisory is set; \
         structured data: {d}",
    );
}
