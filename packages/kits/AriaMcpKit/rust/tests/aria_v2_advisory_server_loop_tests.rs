//! Server-loop gates for `version_skew` and `update_available` advisories.
//!
//! Tests here drive `run_stdio_loop` and `serve_http` end-to-end with a
//! `ServerConfig` that carries the advisory fields, proving that the wiring
//! inside `dispatcher_from_config` (`.with_version_skew(config.version_skew)`
//! and `.with_update_advisory(config.update_advisory)`) actually reaches the
//! rendered output for BOTH transports. Deleting either builder call from
//! `dispatcher_from_config` will turn the corresponding positive assertions RED
//! for both stdio AND http simultaneously — that is the discrimination property
//! this file establishes.
//!
//! The dispatcher-level gates in `aria_v2_advisory_dispatch_tests.rs` cover
//! the Dispatcher → surface leg. These tests cover the ServerConfig →
//! Dispatcher seam that sits above it, closing the gap that the unit-2 brief
//! left open.
//!
//! The HTTP test (`both_advisories_surface_via_http_construction_path`) drives
//! the REAL `serve_http` construction path with a real `ServerConfig`, not a
//! pre-built dispatcher. A per-test helper, since collapsed into `serve_http`,
//! took an already-constructed `Arc<Mutex<Dispatcher>>` and bypassed
//! construction entirely, which was the hole this test closes.

use std::io::{Cursor, Read, Write};
use std::sync::Arc;

use aria_mcp::{
    dispatcher::UpdateAdvisoryProvider,
    http_server::{bind_loopback, http_gates_from_env, run_http_loop, serve_http},
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

// ---------------------------------------------------------------------------
// HTTP construction path — drives serve_http with a real ServerConfig
// ---------------------------------------------------------------------------

/// Helper: find the position of `needle` in `haystack`.
fn find_in(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Gate: both `version_skew` and `update_available` surface in
/// `moot_estate_ping` data when `serve_http` is given a `ServerConfig` that
/// carries both advisories.
///
/// This test drives the REAL `dispatcher_from_config` construction path — the
/// same construction `run_http_loop` triggers in production — via the bounded
/// `serve_http` helper with `connection_limit: Some(1)`. The test joins the server thread
/// before returning, so no thread is leaked.
///
/// Deleting `.with_version_skew(...)` OR `.with_update_advisory(...)` from
/// `dispatcher_from_config` will turn this RED AND will also turn the
/// corresponding stdio gate RED simultaneously — that is the discrimination
/// the brief requires.
#[test]
fn both_advisories_surface_via_http_construction_path() {
    // Build a ServerConfig that carries both advisories.
    let mut cfg = ServerConfig::default_inmemory();
    cfg.version_skew = SKEW_ADVISORY.to_owned();
    cfg.update_advisory = Some(fixed_provider(UPDATE_ADVISORY));

    // Bind an OS-assigned loopback port; hand the listener to the server.
    let listener = bind_loopback(0).expect("bind loopback for HTTP advisory gate");
    let port = listener.local_addr().unwrap().port();

    // Spawn serve_http with connection_limit=Some(1): it accepts one connection
    // and returns, so the JoinHandle is guaranteed to complete after the client
    // round-trip. This is how a test drives the real construction path without
    // leaking a thread (the prior helper took an already-constructed
    // Arc<Mutex<Dispatcher>> and bypassed construction entirely).
    let server = std::thread::spawn(move || {
        serve_http(listener, 4 * 1024 * 1024, cfg, None, Some(1), http_gates_from_env())
            .expect("serve_http must not fail during test");
    });

    // Build one tools/call frame for moot_estate_ping.
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": "moot_estate_ping", "arguments": {} }
    });
    let body = serde_json::to_vec(&frame).unwrap();

    // Send the request over a loopback TCP socket; set a read timeout so a
    // hang in the response path fails the test loudly instead of hanging the
    // entire test binary.
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port))
        .expect("connect to serve_http");
    client
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .unwrap();
    let request = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        String::from_utf8_lossy(&body)
    );
    client.write_all(request.as_bytes()).unwrap();
    client.flush().unwrap();

    // Read until the server closes the connection (Connection: close).
    let mut resp = Vec::new();
    client.read_to_end(&mut resp).unwrap();

    // Split HTTP headers from body at \r\n\r\n.
    let sep = find_in(&resp, b"\r\n\r\n")
        .expect("HTTP response must contain header/body separator \\r\\n\\r\\n");
    let json_body = &resp[sep + 4..];

    let response: serde_json::Value =
        serde_json::from_slice(json_body).expect("HTTP body must be valid JSON");
    let d = data(&response);

    assert_eq!(
        d["version_skew"].as_str(),
        Some(SKEW_ADVISORY),
        "moot_estate_ping over HTTP must carry version_skew when ServerConfig.version_skew is set; \
         deleting .with_version_skew(...) from dispatcher_from_config will turn this RED"
    );
    assert_eq!(
        d["update_available"].as_str(),
        Some(UPDATE_ADVISORY),
        "moot_estate_ping over HTTP must carry update_available when ServerConfig.update_advisory is set; \
         deleting .with_update_advisory(...) from dispatcher_from_config will turn this RED"
    );

    // Join the server thread — must not panic.
    server.join().expect("serve_http thread must not panic");
}

/// Gate: `run_http_loop` delegates to `serve_http` and surfaces both advisories
/// in `moot_estate_ping` when `ServerConfig` carries them.
///
/// This test drives the production entry point that `runtime.rs` calls.
/// The sibling test `both_advisories_surface_via_http_construction_path` drives
/// `serve_http` directly. The split exists so a neuter applied inside
/// `run_http_loop` (`config.update_advisory = None`) turns THIS test RED while
/// the sibling stays GREEN, confirming the two tests cover different routing
/// paths. `run_http_loop`'s body is an unconditional delegation; what the neuter
/// proves is that this test enters `run_http_loop` and the sibling does not.
///
/// Port selection: the test binds its own listener on port 0 and moves it into
/// the spawned server thread. The socket is listening before the thread is
/// scheduled, so the connect lands in the accept backlog with no race window.
#[test]
fn run_http_loop_delegates_to_serve_http_with_both_advisories() {
    // Build a ServerConfig that carries both advisories.
    let mut cfg = ServerConfig::default_inmemory();
    cfg.version_skew = SKEW_ADVISORY.to_owned();
    cfg.update_advisory = Some(fixed_provider(UPDATE_ADVISORY));

    // Bind the listener here; move it into the server thread. The socket is
    // already listening when the connect fires, so there is no race window.
    let listener = bind_loopback(0).expect("bind loopback for run_http_loop gate");
    let port = listener.local_addr().unwrap().port();

    // Spawn run_http_loop with connection_limit=Some(1): it accepts one
    // connection and returns.
    let server = std::thread::spawn(move || {
        run_http_loop(listener, 4 * 1024 * 1024, cfg, None, Some(1))
            .expect("run_http_loop must not fail during test");
    });

    // Build one tools/call frame for moot_estate_ping.
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": "moot_estate_ping", "arguments": {} }
    });
    let body = serde_json::to_vec(&frame).unwrap();

    // The listener was already bound before the thread spawned, so a single
    // connect suffices. A read timeout guards against hangs in the response path.
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port))
        .expect("connect to run_http_loop");
    client
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .unwrap();
    let request = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        String::from_utf8_lossy(&body)
    );
    client.write_all(request.as_bytes()).unwrap();
    client.flush().unwrap();

    // Read until the server closes the connection (Connection: close).
    let mut resp = Vec::new();
    client.read_to_end(&mut resp).unwrap();

    // Split HTTP headers from body at \r\n\r\n.
    let sep = find_in(&resp, b"\r\n\r\n")
        .expect("HTTP response must contain header/body separator \\r\\n\\r\\n");
    let json_body = &resp[sep + 4..];

    let response: serde_json::Value =
        serde_json::from_slice(json_body).expect("HTTP body must be valid JSON");
    let d = data(&response);

    assert_eq!(
        d["version_skew"].as_str(),
        Some(SKEW_ADVISORY),
        "moot_estate_ping over run_http_loop must carry version_skew; \
         a neuter of version_skew inside run_http_loop will turn this RED"
    );
    assert_eq!(
        d["update_available"].as_str(),
        Some(UPDATE_ADVISORY),
        "moot_estate_ping over run_http_loop must carry update_available; \
         inserting `config.update_advisory = None` inside run_http_loop \
         will turn this RED while both_advisories_surface_via_http_construction_path stays GREEN"
    );

    // Join the server thread — must not panic.
    server.join().expect("run_http_loop thread must not panic");
}
