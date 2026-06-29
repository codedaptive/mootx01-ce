//! Stdio framing integration tests — Rust version.
//!
//! Mirrors the Swift `StdioFramingTests`: initialize round-trip, tools/list
//! round-trip, parse error emits null-id response. The server runs against
//! an in-memory Vec<u8> reader/writer rather than real stdin/stdout so the
//! tests can assert on the bytes that would have been written.
//!
//! Each test drives the message loop end-to-end:
//!   raw bytes → framing → parse → dispatch → response bytes.

use std::io::Cursor;

use aria_mcp::server::{run_stdio_loop, ServerConfig};

/// Drive the server loop with `input_bytes` and collect the output.
fn run_with(input: &[u8]) -> Vec<u8> {
    let reader = Cursor::new(input.to_vec());
    let mut writer = Vec::<u8>::new();
    let cfg = ServerConfig::default_inmemory();
    run_stdio_loop(reader, &mut writer, cfg);
    writer
}

/// Parse the first JSON-RPC response from a newline-delimited output buffer.
fn parse_first(output: &[u8]) -> serde_json::Value {
    let line = output
        .split(|&b| b == b'\n')
        .find(|l| !l.is_empty())
        .expect("expected at least one response line");
    serde_json::from_slice(line).expect("response must be valid JSON")
}

#[test]
fn initialize_round_trips_over_in_memory_io() {
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": { "protocolVersion": "2024-11-05" }
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let output = run_with(&input);

    // Response must end with newline.
    assert_eq!(output.last(), Some(&b'\n'));

    let resp = parse_first(&output);
    let obj = resp.as_object().unwrap();
    assert_eq!(obj["jsonrpc"], "2.0");
    assert_eq!(obj["id"], 1);
    assert!(
        obj.contains_key("result"),
        "initialize must produce a result"
    );
}

#[test]
fn tools_list_round_trips_over_in_memory_io() {
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/list"
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let output = run_with(&input);

    assert_eq!(output.last(), Some(&b'\n'));
    let resp = parse_first(&output);
    let obj = resp.as_object().unwrap();
    let result = obj["result"].as_object().unwrap();
    let tools = result["tools"].as_array().unwrap();
    assert!(
        !tools.is_empty(),
        "tools/list must project the tool surface"
    );
}

#[test]
fn parse_error_emits_null_id_response() {
    // Garbage line — not valid JSON.
    let input = b"{ not json\n";

    let output = run_with(input);

    let resp = parse_first(&output);
    let obj = resp.as_object().unwrap();
    assert_eq!(obj["id"], serde_json::json!(null));
    let error = obj["error"].as_object().unwrap();
    assert_eq!(error["code"], serde_json::json!(-32700_i64));
}

/// Verifies the frame size cap (CAND-051): a frame that exceeds `MAX_FRAME_BYTES`
/// without a newline terminator causes `run_stdio_loop` to close the input
/// cleanly rather than growing the buffer unboundedly. The writer gets no
/// response — no frame was ever dispatched — and the call returns without panic.
///
/// Sends `MAX_FRAME_BYTES + 1` bytes with NO newline. The in-memory Cursor
/// reader is used so the allocation is fast (zeroed pages). The test verifies:
///   1. The call returns (loop exited cleanly rather than spinning forever).
///   2. No response bytes were written (no frame was dispatched).
#[test]
fn oversized_frame_without_newline_produces_no_response() {
    use aria_mcp::server::MAX_FRAME_BYTES;

    // MAX_FRAME_BYTES + 1 bytes, NO newline — one byte over the cap.
    // BufReader will accumulate until it detects the cap is exceeded, then
    // read_line_capped returns None and the loop exits.
    let mut payload = vec![b'A'; MAX_FRAME_BYTES + 1];
    // Deliberately omit the 0x0A newline so the cap check is what terminates.
    assert!(!payload.contains(&b'\n'), "test payload must not contain a newline");

    let output = run_with(&payload);
    assert!(
        output.is_empty(),
        "oversized frame with no newline must produce no response; got {} bytes",
        output.len()
    );

    // Also verify: a VALID frame after the cap payload is NOT dispatched
    // (the loop exited before reaching it, so no late response arrives).
    let valid_frame = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "ping" });
    let mut combined = serde_json::to_vec(&valid_frame).unwrap();
    combined.push(b'\n');
    payload.extend_from_slice(&combined);

    let output2 = run_with(&payload);
    assert!(
        output2.is_empty(),
        "after cap exceeded, subsequent frames must not be dispatched; got {} bytes",
        output2.len()
    );
}

#[test]
fn invalid_request_emits_null_id_response() {
    // Valid JSON but not a valid JSON-RPC envelope (wrong version).
    let frame = serde_json::json!({
        "jsonrpc": "1.0",
        "id": 2,
        "method": "ping"
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let output = run_with(&input);

    let resp = parse_first(&output);
    let obj = resp.as_object().unwrap();
    assert_eq!(obj["id"], serde_json::json!(null));
    let error = obj["error"].as_object().unwrap();
    assert_eq!(error["code"], serde_json::json!(-32600_i64));
}

#[test]
fn notification_produces_no_response() {
    // Notifications must not produce a reply per JSON-RPC 2.0.
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let output = run_with(&input);
    // Writer must be empty — no reply to a notification.
    assert!(output.is_empty(), "notifications must produce no response");
}

#[test]
fn ping_returns_empty_object() {
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 99,
        "method": "ping"
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let output = run_with(&input);

    let resp = parse_first(&output);
    let obj = resp.as_object().unwrap();
    assert_eq!(obj["id"], 99);
    assert_eq!(obj["result"], serde_json::json!({}));
}

#[test]
fn unknown_method_returns_method_not_found() {
    let frame = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 5,
        "method": "totally/unknown"
    });
    let mut input = serde_json::to_vec(&frame).unwrap();
    input.push(b'\n');

    let output = run_with(&input);

    let resp = parse_first(&output);
    let obj = resp.as_object().unwrap();
    let error = obj["error"].as_object().unwrap();
    assert_eq!(error["code"], serde_json::json!(-32601_i64));
}
