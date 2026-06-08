//! HTTP MCP transport integration tests — Rust version.
//!
//! Mirrors the Swift `HTTPServerTests`: the same JSON-RPC surface exercised over
//! a real loopback TCP socket. Each test binds an OS-assigned port, connects a
//! client, and serves the queued connection single-threaded (TCP completes the
//! handshake via the listen backlog before `accept()`), so no thread/Send/Sync
//! juggling is needed. Parity with the Swift transport is at the JSON-RPC wire.

use std::io::{Read, Write};
use std::net::TcpStream;

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::http_server::{bind_loopback, serve_once};
use aria_mcp::server::ServerConfig;

fn make_dispatcher() -> Dispatcher {
    let config = ServerConfig::default_inmemory();
    Dispatcher::new(config.registry, &config.server_name, &config.server_version)
}

/// One HTTP request/response round-trip against a freshly bound listener.
/// Returns `(status, body_bytes)`.
fn round_trip(method: &str, body: &str) -> (u16, Vec<u8>) {
    round_trip_with_origin(method, body, None)
}

/// Round-trip with an optional `Origin` header (for the CSRF/DNS-rebinding guard).
fn round_trip_with_origin(method: &str, body: &str, origin: Option<&str>) -> (u16, Vec<u8>) {
    let listener = bind_loopback(0).expect("bind loopback");
    let port = listener.local_addr().unwrap().port();
    let dispatcher = make_dispatcher();

    // Connect first: the TCP handshake completes via the listen backlog before
    // accept(), so a single thread can connect, send, then serve, then read.
    let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    let origin_line = origin.map(|o| format!("Origin: {o}\r\n")).unwrap_or_default();
    let request = format!(
        "{method} / HTTP/1.1\r\nHost: 127.0.0.1\r\n{origin_line}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        body
    );
    client.write_all(request.as_bytes()).unwrap();
    client.flush().unwrap();

    serve_once(&listener, &dispatcher, 4 * 1024 * 1024);

    let mut resp = Vec::new();
    client.read_to_end(&mut resp).unwrap();

    let sep = find(&resp, b"\r\n\r\n").expect("response has header terminator");
    let head = String::from_utf8_lossy(&resp[..sep]).to_string();
    let status: u16 = head
        .lines()
        .next()
        .unwrap()
        .split(' ')
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    (status, resp[sep + 4..].to_vec())
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[test]
fn http_initialize_round_trips() {
    let (status, body) = round_trip(
        "POST",
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#,
    );
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["jsonrpc"].as_str(), Some("2.0"));
    assert_eq!(v["result"]["serverInfo"]["name"].as_str(), Some("ARIA_MCP_Rust"));
}

#[test]
fn http_tools_list_round_trips() {
    let (status, body) = round_trip("POST", r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#);
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let tools = v["result"]["tools"].as_array().expect("tools array");
    assert!(!tools.is_empty());
}

#[test]
fn http_non_post_returns_405() {
    let (status, _) = round_trip("GET", "");
    assert_eq!(status, 405);
}

#[test]
fn http_cross_origin_is_rejected() {
    let (status, _) = round_trip_with_origin(
        "POST",
        r#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
        Some("http://evil.example.com"),
    );
    assert_eq!(status, 403);
}

#[test]
fn http_loopback_origin_is_allowed() {
    let (status, _) = round_trip_with_origin(
        "POST",
        r#"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#,
        Some("http://127.0.0.1:4242"),
    );
    assert_eq!(status, 200);
}

#[test]
fn http_malformed_body_returns_parse_error() {
    let (status, body) = round_trip("POST", "this is not json");
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["error"]["code"].as_i64(), Some(-32700));
}
