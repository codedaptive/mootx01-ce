//! Server-loop gates for `version_skew` and `update_available` advisories.
//!
//! Tests here drive `run_stdio_loop` end-to-end with a `ServerConfig` that
//! carries the advisory fields, proving that the wiring at server.rs
//! (`.with_version_skew(config.version_skew)` and
//! `.with_update_advisory(config.update_advisory)`) actually reaches the
//! rendered output. Deleting either builder call from `run_stdio_loop` will
//! turn the corresponding positive assertions RED while leaving the negative
//! assertions green.
//!
//! The dispatcher-level gates in `aria_v2_advisory_dispatch_tests.rs` cover
//! the Dispatcher → surface leg. These tests cover the ServerConfig →
//! Dispatcher seam that sits above it, closing the gap that the unit-2 brief
//! left open.

use std::io::Cursor;
use std::sync::Arc;

use aria_mcp::{
    dispatcher::UpdateAdvisoryProvider,
    server::{run_stdio_loop, ServerConfig},
};

// ---------------------------------------------------------------------------
// Shared constants — same literals used by `aria_v2_advisory_dispatch_tests`
// ---------------------------------------------------------------------------

/// Advisory injected as `version_skew` for positive cases.
const SKEW_ADVISORY: &str =
    "plugin 1.0.15 expects binary \u{2265} 1.0.15; binary is 1.0.11 \u{2014} run `mootx01 upgrade`";

/// Advisory injected as `update_available` for positive cases.
const UPDATE_ADVISORY: &str =
    "v9.9.9 is available (installed 1.0.33) \u{2014} upgrade with `mootx01 upgrade`";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a provider that always returns the given advisory string.
fn fixed_provider(advisory: &'static str) -> UpdateAdvisoryProvider {
    Arc::new(move || Some(advisory.to_owned()))
}

/// Run one `tools/call` request through the stdio server loop and return the
/// first JSON-RPC response parsed as a Value. The config is consumed by
/// `run_stdio_loop` so each test constructs its own.
fn call_via_loop(cfg: ServerConfig, tool: &str) -> serde_json::Value {
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": tool, "arguments": {} }
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let reader = Cursor::new(input);
    let mut writer = Vec::<u8>::new();
    run_stdio_loop(reader, &mut writer, cfg);

    let line = writer
        .split(|&b| b == b'\n')
        .find(|l| !l.is_empty())
        .expect("expected at least one response line");
    serde_json::from_slice(line).expect("response must be valid JSON")
}

/// Extract `result.structuredContent.data` from a response Value.
fn data(response: &serde_json::Value) -> &serde_json::Value {
    &response["result"]["structuredContent"]["data"]
}

// ---------------------------------------------------------------------------
// version_skew — positive: config field reaches the rendered output
// ---------------------------------------------------------------------------

/// Gate: `version_skew` surfaces in `moot_estate_ping` data when `ServerConfig`
/// carries a non-empty `version_skew` string. Deleting the
/// `.with_version_skew(config.version_skew)` call in `run_stdio_loop` will
/// turn this RED.
#[test]
fn version_skew_config_surfaces_in_ping_via_server_loop() {
    let mut cfg = ServerConfig::default_inmemory();
    cfg.version_skew = SKEW_ADVISORY.to_owned();

    let resp = call_via_loop(cfg, "moot_estate_ping");
    let d = data(&resp);

    assert_eq!(
        d["version_skew"].as_str(),
        Some(SKEW_ADVISORY),
        "moot_estate_ping must carry version_skew when ServerConfig.version_skew is set; \
         deleting .with_version_skew(config.version_skew) from run_stdio_loop will turn this RED"
    );
}

/// Gate: `version_skew` surfaces in `moot_estate_status` data when `ServerConfig`
/// carries a non-empty `version_skew` string.
#[test]
fn version_skew_config_surfaces_in_status_via_server_loop() {
    let mut cfg = ServerConfig::default_inmemory();
    cfg.version_skew = SKEW_ADVISORY.to_owned();

    let resp = call_via_loop(cfg, "moot_estate_status");
    let d = data(&resp);

    assert_eq!(
        d["version_skew"].as_str(),
        Some(SKEW_ADVISORY),
        "moot_estate_status must carry version_skew when ServerConfig.version_skew is set; \
         deleting .with_version_skew(config.version_skew) from run_stdio_loop will turn this RED"
    );
}

// ---------------------------------------------------------------------------
// update_available — positive: config field reaches the rendered output
// ---------------------------------------------------------------------------

/// Gate: `update_available` surfaces in `moot_estate_ping` data when
/// `ServerConfig.update_advisory` carries a provider. Deleting the
/// `.with_update_advisory(config.update_advisory)` call in `run_stdio_loop`
/// will turn this RED.
#[test]
fn update_advisory_config_surfaces_in_ping_via_server_loop() {
    let mut cfg = ServerConfig::default_inmemory();
    cfg.update_advisory = Some(fixed_provider(UPDATE_ADVISORY));

    let resp = call_via_loop(cfg, "moot_estate_ping");
    let d = data(&resp);

    assert_eq!(
        d["update_available"].as_str(),
        Some(UPDATE_ADVISORY),
        "moot_estate_ping must carry update_available when ServerConfig.update_advisory is set; \
         deleting .with_update_advisory(config.update_advisory) from run_stdio_loop will turn this RED"
    );
}

/// Gate: `update_available` surfaces in `moot_estate_status` data when
/// `ServerConfig.update_advisory` carries a provider.
#[test]
fn update_advisory_config_surfaces_in_status_via_server_loop() {
    let mut cfg = ServerConfig::default_inmemory();
    cfg.update_advisory = Some(fixed_provider(UPDATE_ADVISORY));

    let resp = call_via_loop(cfg, "moot_estate_status");
    let d = data(&resp);

    assert_eq!(
        d["update_available"].as_str(),
        Some(UPDATE_ADVISORY),
        "moot_estate_status must carry update_available when ServerConfig.update_advisory is set; \
         deleting .with_update_advisory(config.update_advisory) from run_stdio_loop will turn this RED"
    );
}

// ---------------------------------------------------------------------------
// Negative cases — default config produces no advisory fields
// ---------------------------------------------------------------------------

/// Negative: `version_skew` key is absent from `moot_estate_ping` data when
/// `ServerConfig.version_skew` is the default empty string.
#[test]
fn no_version_skew_omits_key_from_ping_via_server_loop() {
    // default_inmemory() sets version_skew: String::new()
    let cfg = ServerConfig::default_inmemory();
    let resp = call_via_loop(cfg, "moot_estate_ping");
    let d = data(&resp);

    assert!(
        d.as_object().expect("data must be an object").get("version_skew").is_none(),
        "moot_estate_ping must NOT carry version_skew when ServerConfig.version_skew is empty; \
         got: {:?}",
        d["version_skew"]
    );
}

/// Negative: `update_available` key is absent from `moot_estate_ping` data
/// when `ServerConfig.update_advisory` is None.
#[test]
fn no_update_advisory_omits_key_from_ping_via_server_loop() {
    // default_inmemory() sets update_advisory: None
    let cfg = ServerConfig::default_inmemory();
    let resp = call_via_loop(cfg, "moot_estate_ping");
    let d = data(&resp);

    assert!(
        d.as_object().expect("data must be an object").get("update_available").is_none(),
        "moot_estate_ping must NOT carry update_available when ServerConfig.update_advisory is None; \
         got: {:?}",
        d["update_available"]
    );
}

/// Negative: `version_skew` key is absent from `moot_estate_status` data when
/// `ServerConfig.version_skew` is the default empty string.
#[test]
fn no_version_skew_omits_key_from_status_via_server_loop() {
    // default_inmemory() sets version_skew: String::new()
    let cfg = ServerConfig::default_inmemory();
    let resp = call_via_loop(cfg, "moot_estate_status");
    let d = data(&resp);

    assert!(
        d.as_object().expect("data must be an object").get("version_skew").is_none(),
        "moot_estate_status must NOT carry version_skew when ServerConfig.version_skew is empty; \
         got: {:?}",
        d["version_skew"]
    );
}

/// Negative: `update_available` key is absent from `moot_estate_status` data
/// when `ServerConfig.update_advisory` is None.
#[test]
fn no_update_advisory_omits_key_from_status_via_server_loop() {
    // default_inmemory() sets update_advisory: None
    let cfg = ServerConfig::default_inmemory();
    let resp = call_via_loop(cfg, "moot_estate_status");
    let d = data(&resp);

    assert!(
        d.as_object().expect("data must be an object").get("update_available").is_none(),
        "moot_estate_status must NOT carry update_available when ServerConfig.update_advisory is None; \
         got: {:?}",
        d["update_available"]
    );
}
