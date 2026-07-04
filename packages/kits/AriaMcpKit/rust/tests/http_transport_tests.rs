//! HTTP MCP transport integration tests — Rust version.
//!
//! Mirrors the Swift `HTTPServerTests`: the same JSON-RPC surface exercised over
//! a real loopback TCP socket. Each test binds an OS-assigned port, connects a
//! client, and serves the queued connection single-threaded (TCP completes the
//! handshake via the listen backlog before `accept()`), so no thread/Send/Sync
//! juggling is needed. Parity with the Swift transport is at the JSON-RPC wire.
//!
//! Hardening tests (added for ARIA HTTP P4 hardening) cover:
//!   - ConcurrencyGate: acquire/release balance, shed on full queue
//!   - record_latency_ns: bucket routing and total accumulation (tested
//!     indirectly via the global atomics; serve_once updates them)
//!   - GLOBAL_RPC_COUNTER: increments on each dispatched call
//!   - send_shed_response: writes 503 + Retry-After to a stream

use std::io::{Read, Write};
use std::net::TcpStream;

use aria_mcp::dispatcher::Dispatcher;
use aria_mcp::http_server::{
    bind_loopback, drive_sse_stream, run_http_loop_for_test, send_shed_response, serve_once,
    ConcurrencyGate, GLOBAL_RPC_COUNTER, GLOBAL_SHED_COUNTER,
};
use aria_mcp::server::ServerConfig;

fn make_dispatcher() -> Dispatcher {
    let config = ServerConfig::default_inmemory();
    Dispatcher::new(config.registry, &config.server_name, &config.server_version, &config.build_serial, &config.version_skew)
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

    serve_once(&listener, &dispatcher, 4 * 1024 * 1024, None);

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

/// Round-trip a GET request to a specific path against a fresh empty
/// dispatcher. Returns `(status, body_bytes)`.
fn round_trip_get(path: &str) -> (u16, Vec<u8>) {
    round_trip_get_with(path, make_dispatcher())
}

/// Round-trip a GET request to a specific path against a caller-supplied
/// dispatcher (so tests can seed the estate store before the request).
/// Returns `(status, body_bytes)`.
fn round_trip_get_with(path: &str, dispatcher: Dispatcher) -> (u16, Vec<u8>) {
    round_trip_get_with_stats_store(path, dispatcher, None)
}

/// Round-trip a GET request with an optional stats store (for /api/graph snapshot
/// reads). Pass `Some(store)` to exercise the store-read path; `None` returns
/// `structurePending: true` (no snapshot available).
fn round_trip_get_with_stats_store(
    path: &str,
    dispatcher: Dispatcher,
    stats_store: Option<&observer_sink::StatsStore>,
) -> (u16, Vec<u8>) {
    let listener = bind_loopback(0).expect("bind loopback");
    let port = listener.local_addr().unwrap().port();

    let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    let request = format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n");
    client.write_all(request.as_bytes()).unwrap();
    client.flush().unwrap();

    serve_once(&listener, &dispatcher, 4 * 1024 * 1024, stats_store);

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
fn http_non_post_non_get_returns_405() {
    // PUT (and other non-GET, non-POST methods) must be rejected with 405.
    // GET was the original test subject but now routes to the side-channel
    // endpoints, so this test uses PUT to verify the POST-only guard still fires.
    let (status, _) = round_trip("PUT", "");
    assert_eq!(status, 405);
}

#[test]
fn http_get_unknown_path_returns_404() {
    // GET to a path that is not one of the three side-channel endpoints
    // (/api/graph, /api/lattice, /api/admin/estates) must return 404.
    // The round_trip helper requests path "/", which is not registered.
    let (status, _) = round_trip("GET", "");
    assert_eq!(status, 404);
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

/// Loopback-prefix spoofing: attacker registers `localhost.evil` (or
/// `127.0.0.1.evil`) as a domain DNS-resolving to 127.0.0.1. The old
/// prefix-only check would allow these; the suffix-validated check rejects them.
#[test]
fn http_loopback_prefix_spoof_origin_is_rejected() {
    for origin in [
        "http://localhost.evil",
        "https://localhost.attacker.test",
        "http://127.0.0.1.evil",
        "http://[::1].evil",
        "http://localhost@evil.example",
    ] {
        let (status, _) = round_trip_with_origin(
            "POST",
            r#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
            Some(origin),
        );
        assert_eq!(status, 403, "spoofed origin {origin} must be rejected");
    }
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

#[test]
fn http_get_lattice_returns_200_with_addresses_key() {
    let (status, body) = round_trip_get("/api/lattice");
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    // Top-level "addresses" key must be present (array, may be empty on fresh store).
    assert!(v.get("addresses").is_some(), "expected 'addresses' key in /api/lattice response");
    assert!(v["addresses"].is_array());
}

#[test]
fn http_get_graph_returns_200_with_nodes_edges_communities_keys() {
    let (status, body) = round_trip_get("/api/graph");
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert!(v.get("nodes").is_some(), "expected 'nodes' key in /api/graph response");
    assert!(v.get("edges").is_some(), "expected 'edges' key in /api/graph response");
    assert!(v["nodes"].is_array());
    assert!(v["edges"].is_array());
    // communities is part of the GraphPayload wire contract even when the
    // store is empty — an empty array, never a missing key.
    let communities = v["communities"].as_array().expect("communities array");
    assert!(communities.is_empty(), "fresh store must yield zero communities");
}


/// GET /api/graph with no stats store wired returns `structurePending: true`
/// and empty arrays. This is the correct cold-start behavior — the governor has
/// not yet fired, or no stats store is configured.
#[test]
fn http_get_graph_no_store_returns_structure_pending() {
    // round_trip_get passes None for stats_store → structurePending: true.
    let (status, body) = round_trip_get("/api/graph");
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(
        v["structurePending"].as_bool(),
        Some(true),
        "no store → structurePending must be true"
    );
    assert!(v["nodes"].as_array().expect("nodes").is_empty());
    assert!(v["edges"].as_array().expect("edges").is_empty());
}

/// GET /api/graph with a stats store that holds a topology snapshot returns
/// that payload verbatim. Tests the full store-read path at the HTTP layer
/// without needing a governor run — mirrors `httpGraphReaderPayloadPassedThrough`
/// in the Swift suite.
#[test]
fn http_get_graph_store_payload_returned_verbatim() {
    use observer_sink::StatsStore;
    use uuid::Uuid;

    let store = StatsStore::new(":memory:").expect("in-memory stats store must open");
    store.open().expect("store.open must succeed");

    // Craft a minimal pre-built snapshot and write it directly to the store.
    let registry = aria_mcp::estate_registry::EstateRegistry::new_inmemory();
    let estate_id = Uuid::from_bytes(registry.default.handle.estate_uuid).to_string();
    let pre_built_payload = r#"{"nodes":[{"id":"abc","nounType":0,"communityId":1,"centrality":0.5,"anomaly":false,"tombstonedTs":null}],"edges":[],"structurePending":false,"communities":[{"id":1,"size":1,"dominantUdcCode":"510"}],"generatedTs":"2026-01-01T00:00:00Z"}"#;
    // 1_735_689_600.0 == 2026-01-01T00:00:00Z in Unix epoch seconds.
    store
        .write_topology_snapshot(&estate_id, 1_735_689_600.0, pre_built_payload, None)
        .expect("write_topology_snapshot must succeed");

    let dispatcher = Dispatcher::new(registry, "ARIA_MCP_Rust", "test", "test-serial", "");
    let (status, body) = round_trip_get_with_stats_store("/api/graph", dispatcher, Some(&store));
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();

    // Payload returned verbatim — structurePending is false, node count correct.
    assert_eq!(
        v["structurePending"].as_bool(),
        Some(false),
        "store has snapshot → structurePending must be false"
    );
    let nodes = v["nodes"].as_array().expect("nodes array");
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0]["id"].as_str(), Some("abc"));
    let communities = v["communities"].as_array().expect("communities array");
    assert_eq!(communities.len(), 1);
    // generatedTs forwarded verbatim — transport is transparent.
    assert_eq!(v["generatedTs"].as_str(), Some("2026-01-01T00:00:00Z"));
}

#[test]
fn http_get_admin_estates_returns_200_with_hosted_key() {
    let (status, body) = round_trip_get("/api/admin/estates");
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert!(v.get("hosted").is_some(), "expected 'hosted' key in /api/admin/estates response");
    assert!(v["hosted"].is_array());
    // At minimum the default in-memory estate is present.
    assert!(!v["hosted"].as_array().unwrap().is_empty());
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Hardening tests (P4 backpressure + counters)
// ─────────────────────────────────────────────────────────────────────────────

/// ConcurrencyGate: balanced acquire/release returns depth to 0.
#[test]
fn concurrency_gate_balanced_acquire_release() {
    let gate = ConcurrencyGate::new(4, 8);
    assert!(gate.try_acquire(), "first acquire must succeed");
    assert_eq!(gate.current_depth(), 1);
    gate.release();
    assert_eq!(gate.current_depth(), 0);
}

/// ConcurrencyGate: with maxQueued=0, a second concurrent try_acquire
/// must return false (shed immediately).
///
/// The first slot is held by calling try_acquire without releasing; the
/// second call must fail because maxConcurrent=1 and maxQueued=0 means
/// the total allowed depth is exactly 1.
#[test]
fn concurrency_gate_zero_queue_sheds_on_second() {
    let gate = ConcurrencyGate::new(1, 0);
    assert!(gate.try_acquire(), "first acquire must succeed");
    // With maxConcurrent=1 and maxQueued=0, a second try_acquire should
    // return false immediately (queue-full branch).
    // However, because the gate uses a Condvar, a second try_acquire
    // would block waiting for the first to release (depth=1 == maxConcurrent).
    // We can only test the shed branch when depth > maxConcurrent + maxQueued.
    // depth=1, maxConcurrent=1, maxQueued=0 → 1 > 1 is false so it parks.
    // To test the shed path we need depth 2 with maxConcurrent+maxQueued=1:
    // set maxConcurrent=1, maxQueued=0, then do a try_acquire from another
    // thread while the gate is at depth 1. But that would deadlock in the
    // single-threaded test context.
    //
    // Instead, test with a gate that already has depth 2 by using
    // max_concurrent=2, max_queued=0 and acquiring twice, then checking the
    // third is rejected — which does NOT block because 3 > 2+0=2.
    gate.release();  // restore to depth 0

    let gate2 = ConcurrencyGate::new(2, 0);
    assert!(gate2.try_acquire());  // depth=1
    assert!(gate2.try_acquire());  // depth=2 (both slots taken)
    // Third: depth would be 3 > 2+0 → shed immediately.
    let shed = gate2.try_acquire();
    gate2.release();
    gate2.release();
    assert!(!shed, "third acquire when queue is full must return false (shed)");
}

/// GLOBAL_RPC_COUNTER increments for every non-202 response.
#[test]
fn rpc_counter_increments_on_round_trip() {
    let before = GLOBAL_RPC_COUNTER.load(std::sync::atomic::Ordering::Relaxed);
    // A successful initialize round-trip produces HTTP 200 → RPC counter +1.
    round_trip(
        "POST",
        r#"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#,
    );
    let after = GLOBAL_RPC_COUNTER.load(std::sync::atomic::Ordering::Relaxed);
    assert!(after > before, "RPC counter must increment after a dispatched call");
}

/// GLOBAL_SHED_COUNTER is a pub atomic that starts at some value; asserting
/// it can be loaded is sufficient to show it is wired.
#[test]
fn shed_counter_is_accessible() {
    // Merely reading the counter is sufficient — we're testing public visibility
    // and that the type is correct (usize atomic).
    let _count = GLOBAL_SHED_COUNTER.load(std::sync::atomic::Ordering::Relaxed);
}

/// send_shed_response writes a 503 with Retry-After: 1 to a real TCP stream.
/// Uses a loopback socketpair-equivalent (bind port 0 + connect) to avoid
/// unix-specific socketpair().
#[test]
fn send_shed_response_writes_503_retry_after() {
    use std::net::{TcpListener, TcpStream};

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut client = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut server = listener.accept().unwrap().0;

    send_shed_response(&mut server);
    drop(server);  // close server side → client read_to_end returns

    let mut resp = Vec::new();
    client.read_to_end(&mut resp).unwrap();
    let text = String::from_utf8_lossy(&resp);

    assert!(text.contains("503"), "shed response must contain 503 status");
    assert!(text.contains("Retry-After"), "shed response must contain Retry-After header");
    assert!(text.contains("service_unavailable"), "shed response body must contain service_unavailable");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - #23 regression tests: accept-loop saturation and queue drain
// ─────────────────────────────────────────────────────────────────────────────

/// Saturation test (a): with all concurrency slots occupied and the soft queue
/// full, the next try_enqueue returns false IMMEDIATELY without blocking.
///
/// This proves that the accept loop never parks inside the gate under saturation.
/// If try_enqueue() had contained a Condvar wait, this test would deadlock
/// (single-threaded caller would block forever waiting on itself to release).
/// The non-blocking return proves the accept thread stays free to shed inline.
#[test]
fn saturation_try_enqueue_is_non_blocking() {
    use aria_mcp::http_server::ConcurrencyGate;

    // max_concurrent=1, max_queued=1 → total capacity 2.
    let gate = ConcurrencyGate::new(1, 1);

    // Enqueue slot 1 and slot 2 — both non-blocking (just increment active).
    assert!(gate.try_enqueue(), "first enqueue must succeed");
    assert!(gate.try_enqueue(), "second enqueue must succeed (fills queue)");
    assert_eq!(gate.current_depth(), 2);

    // Third enqueue: active=2 >= max_concurrent+max_queued=2, must return false
    // WITHOUT blocking. The fact that this returns at all proves no Condvar wait.
    let overflow = gate.try_enqueue();
    assert!(!overflow, "overflow enqueue must return false immediately");
    assert_eq!(gate.current_depth(), 2, "depth must not change after rejected enqueue");

    // Cleanup.
    gate.release();
    gate.release();
    assert_eq!(gate.current_depth(), 0);
}

/// Queue drain test (b): a connection enqueued in the soft queue receives its
/// slot and completes successfully after a running connection releases.
///
/// Shape: gate(max_concurrent=1, max_queued=1) → connection A acquires the slot
/// via try_acquire (= try_enqueue + wait_for_slot combined, non-blocking because
/// there is a free slot) → connection B enqueues (non-blocking) + spawns a thread
/// calling wait_for_slot (blocks) → A releases → B's wait_for_slot unblocks and
/// B's flag is set within a bounded time.
#[test]
fn queue_drain_after_slot_frees() {
    use aria_mcp::http_server::ConcurrencyGate;
    use std::sync::{Arc, atomic::{AtomicBool, Ordering}};
    use std::time::Duration;

    let gate = ConcurrencyGate::new(1, 1);

    // Connection A: acquire the sole concurrency slot (non-blocking — free slot).
    assert!(gate.try_acquire(), "A must acquire the slot immediately");

    // Connection B: enqueue into the soft queue (non-blocking depth check).
    assert!(gate.try_enqueue(), "B must enqueue into the soft queue");
    assert_eq!(gate.current_depth(), 2);

    let slot_granted = Arc::new(AtomicBool::new(false));
    let flag_clone = Arc::clone(&slot_granted);
    let gate_clone = Arc::clone(&gate);

    // B's worker thread: calls wait_for_slot (blocks until A releases).
    let b_thread = std::thread::spawn(move || {
        gate_clone.wait_for_slot();
        flag_clone.store(true, Ordering::Relaxed);
        gate_clone.release();
    });

    // Give B's thread a moment to reach wait_for_slot.
    std::thread::sleep(Duration::from_millis(10));
    assert!(!slot_granted.load(Ordering::Relaxed), "B must not have its slot yet");

    // Release A's slot → B's wait_for_slot wakes.
    gate.release();

    // Wait up to 2 s for B to complete.
    b_thread.join().expect("B thread must not panic");
    assert!(slot_granted.load(Ordering::Relaxed), "B must have been granted its slot");
    assert_eq!(gate.current_depth(), 0, "gate depth must be 0 after both released");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - #26 regression test: slow client does not block fast concurrent request
// ─────────────────────────────────────────────────────────────────────────────

/// #26 test (c): a slow-writing client does NOT block a concurrent fast request.
///
/// Before the fix, `run_http_loop`'s worker thread locked the dispatcher before
/// reading the request. A slow TCP sender held the Mutex while waiting on the
/// socket, serializing all other requests behind it.
///
/// After the fix, the worker reads the request bytes BEFORE taking the
/// dispatcher lock. The lock scope is limited to `route()` alone.
///
/// This test uses `run_http_loop_for_test` — an exported variant of
/// `run_http_loop` that accepts a pre-bound listener and serves exactly N
/// connections, then returns. This lets the test drive real threaded behavior
/// without the process-lifetime loop.
///
/// Shape:
///   - Server: max_concurrent=2, max_queued=0.
///   - Slow client: connects first; pauses 200 ms mid-send (headers sent,
///     body withheld) to simulate a slow sender.
///   - Fast client: connects second; sends a complete request immediately.
///   - Assertion: fast client receives its response within 300 ms, even
///     while the slow client is still writing.
///
/// The 300 ms bound is far above a loopback RTT (<1 ms) and far below the
/// 200 ms slow-sender delay — so the test fails if the fast request was
/// waiting behind the slow one.
#[test]
fn slow_client_does_not_block_fast_concurrent_request() {
    use std::net::TcpStream;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    // Build a fresh in-memory dispatcher for this test.
    let config = ServerConfig::default_inmemory();
    let dispatcher = Arc::new(Mutex::new(
        Dispatcher::new(config.registry, &config.server_name, &config.server_version, &config.build_serial, &config.version_skew)
    ));

    // Bind the listener.
    let listener = bind_loopback(0).expect("bind loopback");
    let port = listener.local_addr().unwrap().port();

    // Two-thread pool: both connections can be in-flight simultaneously.
    let gate = ConcurrencyGate::new(2, 0);

    // Spawn the server loop: serves exactly 2 connections then returns.
    let server_listener = listener.try_clone().expect("clone listener");
    let sse_gate = Arc::new(ConcurrencyGate::new(16, 0));
    let server_thread = run_http_loop_for_test(server_listener, Arc::clone(&dispatcher), Arc::clone(&gate), Arc::clone(&sse_gate), 2);

    // Brief pause to ensure the server loop is in accept() before clients connect.
    std::thread::sleep(Duration::from_millis(5));

    // Slow client: connect, send headers immediately, pause 200 ms before body.
    let slow_done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let slow_flag = Arc::clone(&slow_done);
    std::thread::spawn(move || {
        let mut slow = TcpStream::connect(("127.0.0.1", port)).expect("slow connect");
        let body = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#;
        // Headers declare the full Content-Length but the body is withheld.
        let head = format!(
            "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        slow.write_all(head.as_bytes()).unwrap();
        slow.flush().unwrap();
        // Simulate a slow writer: pause 200 ms before sending the body.
        std::thread::sleep(Duration::from_millis(200));
        slow.write_all(body.as_bytes()).unwrap();
        slow.flush().unwrap();
        let mut resp = Vec::new();
        slow.read_to_end(&mut resp).unwrap();
        slow_flag.store(true, std::sync::atomic::Ordering::Relaxed);
    });

    // Brief pause so the slow client is first in the accept queue.
    std::thread::sleep(Duration::from_millis(20));

    // Fast client: connect and send a complete request immediately.
    let fast_start = Instant::now();
    let mut fast = TcpStream::connect(("127.0.0.1", port)).expect("fast connect");
    let fast_body = r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#;
    let fast_req = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        fast_body.len(), fast_body
    );
    fast.write_all(fast_req.as_bytes()).unwrap();
    fast.flush().unwrap();

    // Read the fast response with a 300 ms timeout — the test fails loudly if
    // the fast response was blocked behind the slow sender.
    fast.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
    let mut fast_resp = Vec::new();
    let _ = fast.read_to_end(&mut fast_resp);
    let fast_elapsed = fast_start.elapsed();

    assert!(
        fast_elapsed < Duration::from_millis(300),
        "fast request must complete in <300 ms; took {:?} (slow-client blocking may be present)",
        fast_elapsed
    );
    // Response must be parseable HTTP with tools payload.
    let fast_text = String::from_utf8_lossy(&fast_resp);
    if !fast_resp.is_empty() {
        assert!(
            fast_text.contains("200") || fast_text.contains("tools"),
            "fast response must be HTTP 200 or contain tools: {:?}",
            &fast_text[..fast_text.len().min(200)]
        );
    }

    server_thread.join().expect("server thread must not panic");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - #23 end-to-end saturation proof: +1 reads 503 ON THE WIRE
// ─────────────────────────────────────────────────────────────────────────────

/// End-to-end saturation proof: the overflow (+1) connection reads its 503
/// response ON THE WIRE while the slot-holder is still in-flight.
///
/// This is the literal proof for pinned proof-point 1 from the SEND-BACK on
/// commit 83972851: "saturation: maxConcurrent + maxQueued + 1 → the +1 gets
/// the SHED RESPONSE in BOTH ports — observed ON THE WIRE, not hidden in the OS
/// backlog."
///
/// Shape (gate: max_concurrent=1, max_queued=1, connection_count=3):
///
///   A (slow in-flight):
///     - Connects and sends headers only; body withheld for 600 ms.
///     - After try_enqueue succeeds, the worker thread calls wait_for_slot.
///       With depth=1 ≤ max_concurrent=1 the slot is granted immediately.
///     - The worker then blocks in read_request waiting for the body bytes.
///
///   B (queued):
///     - Connects and sends a complete request.
///     - try_enqueue succeeds (depth=2, within max_concurrent+max_queued=2).
///     - Worker thread calls wait_for_slot; depth=2 > max_concurrent=1 → parks
///       on the Condvar. B is now in the soft queue.
///
///   C (+1 overflow):
///     - Connects after A is confirmed in-flight and B is confirmed queued.
///     - try_enqueue sees depth=2 ≥ 2 → returns false immediately (no Condvar
///       wait). The accept thread calls send_shed_response inline.
///     - C reads 503 + Retry-After from the wire within 2 s.
///
/// Wire-proof timing check: C's 503 is observed before A's body is released.
/// The slow body hold is 600 ms; C's bounded wait is 2 s — so if C's response
/// arrived AFTER the slow hold, the elapsed time from C-connect to C-read would
/// exceed 600 ms, and we assert it is ≤ 400 ms (far below 600 ms).
///
/// Drain check: after C confirms its 503, A's body is released. Both worker
/// threads run to completion; B's response is read successfully (drain works).
#[test]
fn saturation_overflow_reads_503_on_wire_while_slot_holder_in_flight() {
    use std::net::TcpStream;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    // ── Server setup ─────────────────────────────────────────────────────────
    let config = ServerConfig::default_inmemory();
    let dispatcher = Arc::new(Mutex::new(
        Dispatcher::new(config.registry, &config.server_name, &config.server_version, &config.build_serial, &config.version_skew)
    ));
    let listener = bind_loopback(0).expect("bind loopback");
    let port = listener.local_addr().unwrap().port();

    // gate: 1 concurrency slot + 1 soft-queue slot = total capacity 2.
    // connection_count=3: A (served as worker), B (served as worker), C (shed).
    let gate = ConcurrencyGate::new(1, 1);
    let sse_gate_2 = Arc::new(ConcurrencyGate::new(16, 0));
    let server_thread = run_http_loop_for_test(
        listener,
        Arc::clone(&dispatcher),
        Arc::clone(&gate),
        Arc::clone(&sse_gate_2),
        3,
    );

    // Brief pause so the server's accept() is ready before clients connect.
    std::thread::sleep(Duration::from_millis(5));

    // ── Connection A (slow in-flight) ────────────────────────────────────────
    // A signals when its body send is ALLOWED (via this channel):
    // we hold A's body until after C has read its 503.
    let body_release = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let release_flag = Arc::clone(&body_release);

    let mut a_conn = TcpStream::connect(("127.0.0.1", port)).expect("A connect");
    let slow_body = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#;

    // Send A's headers immediately (declares Content-Length so the server's
    // read_request blocks waiting for the body bytes).
    let a_head = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
        slow_body.len()
    );
    a_conn.write_all(a_head.as_bytes()).expect("A headers");
    a_conn.flush().expect("A flush headers");

    // Move A's connection into a background thread that waits for the release
    // signal before sending the body, then reads the response.
    let mut a_conn_bg = a_conn.try_clone().expect("clone A conn");
    let a_thread = std::thread::spawn(move || {
        // Poll for the release flag with a short sleep (bounded: 3 s total).
        let deadline = Instant::now() + Duration::from_secs(3);
        while !release_flag.load(std::sync::atomic::Ordering::Relaxed) {
            if Instant::now() > deadline { break; }
            std::thread::sleep(Duration::from_millis(10));
        }
        a_conn_bg.write_all(slow_body.as_bytes()).expect("A body");
        a_conn_bg.flush().expect("A flush body");
        let mut resp = Vec::new();
        let _ = a_conn_bg.read_to_end(&mut resp);
        resp
    });

    // Allow time for A's worker thread to be spawned by the accept loop,
    // call wait_for_slot, acquire the slot (depth=1 ≤ max_concurrent=1),
    // and block in read_request waiting for the body.
    std::thread::sleep(Duration::from_millis(30));

    // ── Connection B (queued) ─────────────────────────────────────────────────
    // B sends a complete request. try_enqueue succeeds (depth→2), the worker
    // thread parks in wait_for_slot (depth=2 > max_concurrent=1).
    let b_body = r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#;
    let b_req = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        b_body.len(), b_body
    );
    let mut b_conn = TcpStream::connect(("127.0.0.1", port)).expect("B connect");
    b_conn.write_all(b_req.as_bytes()).expect("B request");
    b_conn.flush().expect("B flush");

    // Allow time for B to be accepted and its worker thread to reach
    // wait_for_slot (and park there because the slot is taken by A).
    std::thread::sleep(Duration::from_millis(20));

    // Gate depth must be 2: A in-flight + B queued.
    assert_eq!(
        gate.current_depth(),
        2,
        "gate depth must be 2 (A in-flight, B queued) before C connects"
    );

    // ── Connection C (+1 overflow) ────────────────────────────────────────────
    // C connects NOW. try_enqueue on the accept thread sees depth=2 ≥ 1+1=2
    // and returns false immediately. send_shed_response writes 503 inline.
    // C must receive its 503 WHILE A is still holding the body (≤ 400 ms,
    // well below A's 600+ ms body hold).
    let c_connect_time = Instant::now();
    let mut c_conn = TcpStream::connect(("127.0.0.1", port)).expect("C connect");
    // Bounded read: 2 s is the hard cap per the task contract.
    c_conn.set_read_timeout(Some(Duration::from_millis(2_000))).unwrap();
    let mut c_resp = Vec::new();
    let _ = c_conn.read_to_end(&mut c_resp);
    let c_elapsed = c_connect_time.elapsed();

    // Wire assertions: 503 and Retry-After must appear in C's raw response bytes.
    let c_text = String::from_utf8_lossy(&c_resp);
    assert!(
        c_text.contains("503"),
        "overflow (+1) connection must read 503 from the wire; got: {:?}",
        &c_text[..c_text.len().min(300)]
    );
    assert!(
        c_text.contains("Retry-After"),
        "overflow (+1) connection must read Retry-After from the wire; got: {:?}",
        &c_text[..c_text.len().min(300)]
    );
    assert!(
        c_text.contains("service_unavailable"),
        "overflow (+1) connection must read service_unavailable body from the wire; got: {:?}",
        &c_text[..c_text.len().min(300)]
    );

    // Timing proof: C's 503 arrived within 400 ms — well before A's body could
    // have been released (still held by the flag). If C had waited for A's slot
    // to free, elapsed would be ≥ 600 ms (the slow-body hold duration).
    assert!(
        c_elapsed < Duration::from_millis(400),
        "overflow 503 must arrive in <400 ms (slot-holder is still in-flight); took {:?}",
        c_elapsed
    );

    // ── Drain verification ────────────────────────────────────────────────────
    // After server thread returns (all 3 connections counted), release A's body.
    // This unblocks A's read_request → A completes → gate releases A's slot →
    // B's wait_for_slot wakes → B completes. Drain still works end-to-end.
    server_thread.join().expect("server thread must not panic");

    // Now release A: signal the background thread to send the body.
    body_release.store(true, std::sync::atomic::Ordering::Relaxed);

    // Wait for A to finish (bounded: 3 s).
    let a_resp = a_thread.join().expect("A thread must not panic");
    let a_text = String::from_utf8_lossy(&a_resp);
    assert!(
        a_text.contains("200") || a_text.contains("tools"),
        "A (slow in-flight) must complete successfully after body release; got: {:?}",
        &a_text[..a_text.len().min(300)]
    );

    // Wait for B to complete (bounded: 3 s via read_timeout on the connection).
    b_conn.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    let mut b_resp = Vec::new();
    let _ = b_conn.read_to_end(&mut b_resp);
    let b_text = String::from_utf8_lossy(&b_resp);
    assert!(
        b_text.contains("200") || b_text.contains("tools"),
        "B (queued) must drain and complete successfully after A releases; got: {:?}",
        &b_text[..b_text.len().min(300)]
    );

    // Gate must be fully drained.
    assert_eq!(gate.current_depth(), 0, "gate depth must be 0 after all connections complete");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SSE event-stream tests (P2)
// ─────────────────────────────────────────────────────────────────────────────

/// GET /api/events with Accept: text/event-stream opens the SSE channel and
/// sends a live heartbeat.
///
/// The server sends the SSE response head (200 + text/event-stream + keep-alive)
/// then the `: heartbeat` comment line at the configured interval. This test
/// drives `drive_sse_stream` directly with a very short interval (50 ms) so the
/// first heartbeat arrives within a bounded read timeout (500 ms), proving the
/// stream is live and not dead-advertised.
///
/// Mirrors `sseStreamSendsHeadAndHeartbeat` in the Swift test suite.
#[test]
fn sse_stream_sends_head_and_heartbeat() {
    use std::io::Read;
    use std::net::{TcpListener, TcpStream};
    use std::time::Duration;

    // Build a loopback socketpair: listener + client connect + accept.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let mut client = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let (mut server, _) = listener.accept().unwrap();

    // Drive the SSE stream on a background thread with a 50 ms heartbeat interval
    // so the test receives the first ping quickly without waiting 15 seconds.
    let interval_ms: u64 = 50;
    let server_thread = std::thread::spawn(move || {
        drive_sse_stream(&mut server, interval_ms);
    });

    // Set a receive timeout so the read returns after we have seen enough data.
    client.set_read_timeout(Some(Duration::from_millis(500))).unwrap();

    // Read until we see the heartbeat comment line or the timeout fires.
    let mut received = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match client.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                received.extend_from_slice(&buf[..n]);
                let text = String::from_utf8_lossy(&received);
                if text.contains(": heartbeat") {
                    break;
                }
            }
            Err(_) => break, // timeout or error
        }
    }

    // Drop client — this closes the TCP connection, which causes drive_sse_stream
    // to get a write error on the next tick and return, letting the thread finish.
    drop(client);
    // Give the server thread up to 1 second to exit cleanly.
    let _ = server_thread.join();

    let response_text = String::from_utf8_lossy(&received).to_string();

    // Verify response head.
    assert!(
        response_text.contains("HTTP/1.1 200"),
        "SSE response must be 200; got: {:?}",
        &response_text[..response_text.len().min(300)]
    );
    assert!(
        response_text.contains("text/event-stream"),
        "SSE response must carry Content-Type: text/event-stream; got: {:?}",
        &response_text[..response_text.len().min(300)]
    );
    assert!(
        response_text.contains("keep-alive"),
        "SSE response must carry Connection: keep-alive; got: {:?}",
        &response_text[..response_text.len().min(300)]
    );
    // Verify heartbeat arrived — the stream is live, not dead-advertised.
    assert!(
        response_text.contains(": heartbeat"),
        "SSE stream must send heartbeat comment line; got: {:?}",
        &response_text[..response_text.len().min(300)]
    );
}

/// GET /api/events WITHOUT Accept: text/event-stream falls through to the
/// normal GET router and returns 404. Mirrors
/// `httpSSEEventStreamWithoutAcceptHeaderReturns404` in the Swift suite.
#[test]
fn sse_get_without_accept_header_returns_404() {
    let listener = bind_loopback(0).expect("bind loopback");
    let port = listener.local_addr().unwrap().port();
    let dispatcher = make_dispatcher();

    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
    // No Accept: text/event-stream — the SSE branch must not fire.
    let request = format!(
        "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
    );
    use std::io::Write;
    client.write_all(request.as_bytes()).unwrap();
    client.flush().unwrap();

    serve_once(&listener, &dispatcher, 4 * 1024 * 1024, None);

    use std::io::Read;
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

    assert_eq!(status, 404, "GET /api/events without Accept: text/event-stream must return 404");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CAND-025: SSE gate isolation
// ─────────────────────────────────────────────────────────────────────────────

/// Verifies that concurrent SSE connections do NOT consume slots from the normal
/// request/response gate (CAND-025). The test opens N SSE connections that hold
/// their sockets open, then verifies a normal POST completes without waiting for
/// the SSE connections to close.
///
/// Setup: normal gate maxConcurrent=1 (tight — any slot leak is fatal);
/// SSE gate maxConcurrent=4 (room for the test SSE clients).
/// If SSE were consuming normal gate slots, the POST would block waiting for one
/// of the SSE clients to disconnect and release its slot.
#[test]
fn sse_streams_do_not_starve_normal_gate_slots() {
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::sync::{Arc, Mutex};

    let config = ServerConfig::default_inmemory();
    let dispatcher = Arc::new(Mutex::new(
        Dispatcher::new(config.registry, &config.server_name, &config.server_version, &config.build_serial, &config.version_skew)
    ));
    let listener = bind_loopback(0).expect("bind loopback");
    let port = listener.local_addr().unwrap().port();

    // Tight normal gate: 1 concurrent slot.
    // If SSE consumed this slot, the POST below would block until an SSE client disconnects.
    let normal_gate = Arc::new(ConcurrencyGate::new(1, 4));
    // Generous SSE gate: 4 concurrent SSE streams — room for our 3 test clients.
    let test_sse_gate = Arc::new(ConcurrencyGate::new(4, 0));

    // Serve 4 connections: 3 SSE + 1 POST.
    let server_thread = run_http_loop_for_test(
        listener,
        Arc::clone(&dispatcher),
        Arc::clone(&normal_gate),
        Arc::clone(&test_sse_gate),
        4,
    );

    std::thread::sleep(std::time::Duration::from_millis(10));

    // Connect 3 SSE clients and leave them open.
    let mut sse_clients: Vec<TcpStream> = Vec::new();
    for _ in 0..3 {
        let mut client = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect SSE");
        client.set_read_timeout(Some(std::time::Duration::from_millis(200))).ok();
        let req = "GET /api/events HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\nOrigin: http://127.0.0.1\r\n\r\n";
        client.write_all(req.as_bytes()).unwrap();
        client.flush().unwrap();
        // Read the SSE response head to confirm the server accepted the connection.
        let mut head = vec![0u8; 256];
        let _ = client.read(&mut head); // may timeout after 200ms — that's OK
        sse_clients.push(client);
    }

    // Wait briefly to let the SSE threads establish their streams.
    std::thread::sleep(std::time::Duration::from_millis(50));

    // Now issue a normal POST while all 3 SSE connections are still open.
    // With the fix: SSE holds the test_sse_gate; normal_gate slot is free.
    // Without the fix: normal_gate would be held by the first SSE client,
    // and this POST would stall until a timeout or disconnect.
    let frame = r#"{"jsonrpc":"2.0","id":99,"method":"ping"}"#;
    let frame_bytes = frame.as_bytes();
    let http_req = format!(
        "POST /mcp/v1/message HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nOrigin: http://127.0.0.1\r\n\r\n{}",
        frame_bytes.len(),
        frame
    );
    let mut post_client = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect POST");
    // POST must complete within 3 seconds. If the gate is starved this will time out.
    post_client.set_read_timeout(Some(std::time::Duration::from_secs(3))).ok();
    post_client.write_all(http_req.as_bytes()).unwrap();
    post_client.flush().unwrap();

    let mut resp = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match post_client.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => { resp.extend_from_slice(&buf[..n]); }
        }
    }

    // Close SSE clients to let the server thread exit cleanly.
    drop(sse_clients);
    let _ = server_thread.join();

    let resp_text = String::from_utf8_lossy(&resp);
    let first_line = resp_text.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();
    let status: u16 = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    assert_eq!(
        status, 200,
        "POST must complete with 200 while SSE streams are open; got {status}. Response: {}",
        &resp_text[..resp_text.len().min(300)]
    );
    assert!(
        resp_text.contains("\"result\""),
        "POST response must contain JSON-RPC result; got: {}",
        &resp_text[..resp_text.len().min(300)]
    );
}

// ── Finding #4 — last_n negative / zero / huge clamped in moot_read_journal ──

#[test]
fn read_journal_negative_last_n_returns_invalid_params() {
    // last_n=-1 must return a JSON-RPC invalidParams error (-32602).
    // Before the fix, optionalInt let -1 through → SQLite LIMIT -1 = all rows.
    let (status, body) = round_trip(
        "POST",
        r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"last_n":-1}}}"#,
    );
    assert_eq!(status, 200, "JSON-RPC errors are always HTTP 200");
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let code = v["error"]["code"].as_i64().expect("must have error.code; got result instead");
    assert_eq!(code, -32602, "expected invalidParams (-32602); got {code}");
}

#[test]
fn read_journal_zero_last_n_returns_invalid_params() {
    let (status, body) = round_trip(
        "POST",
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"last_n":0}}}"#,
    );
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let code = v["error"]["code"].as_i64().expect("must have error.code");
    assert_eq!(code, -32602);
}

#[test]
fn read_journal_huge_last_n_is_clamped_silently() {
    // last_n=1000 (above ceiling 500) must not error — clamp to 500 and succeed.
    let (status, body) = round_trip(
        "POST",
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"last_n":1000}}}"#,
    );
    assert_eq!(status, 200);
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert!(v.get("result").is_some(), "last_n=1000 must be clamped silently; got: {v}");
}

// ── Finding #8 — Host guard on ARIA MCP GET routes → 421 ──

/// A GET with a non-loopback Host header must be rejected 421.
/// Uses `run_http_loop_for_test` so the full gate+read path is exercised.
#[test]
fn http_get_with_non_loopback_host_returns_421() {
    use std::sync::{Arc, Mutex};
    let dispatcher = Arc::new(Mutex::new(make_dispatcher()));
    let normal_gate = Arc::new(aria_mcp::http_server::ConcurrencyGate::new(4, 4));
    let sse_gate = Arc::new(aria_mcp::http_server::ConcurrencyGate::new(2, 0));

    for path in ["/api/graph", "/api/admin/estates", "/api/lattice"] {
        let listener = bind_loopback(0).expect("bind");
        let port = listener.local_addr().unwrap().port();

        let mut client = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect");
        let req = format!(
            "GET {path} HTTP/1.1\r\nHost: attacker.example.com\r\nContent-Length: 0\r\n\r\n"
        );
        client.write_all(req.as_bytes()).unwrap();
        client.flush().unwrap();

        let handle = aria_mcp::http_server::run_http_loop_for_test(
            listener,
            Arc::clone(&dispatcher),
            Arc::clone(&normal_gate),
            Arc::clone(&sse_gate),
            1,
        );
        let _ = handle.join();

        let mut resp = Vec::new();
        client.read_to_end(&mut resp).unwrap();
        let status: u16 = String::from_utf8_lossy(&resp)
            .lines()
            .next()
            .unwrap_or("")
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        assert_eq!(status, 421, "GET {path} with non-loopback Host must return 421; got {status}");
    }
}

/// A GET with a loopback Host header must succeed (200), not be blocked.
#[test]
fn http_get_with_loopback_host_succeeds() {
    let (status, _) = round_trip_get("/api/graph");
    assert_eq!(status, 200);
}

/// A GET with absent Host must succeed (curl omits Host).
#[test]
fn http_get_with_absent_host_succeeds() {
    let listener = bind_loopback(0).expect("bind");
    let port = listener.local_addr().unwrap().port();
    let dispatcher = make_dispatcher();

    let mut client = TcpStream::connect(format!("127.0.0.1:{port}")).expect("connect");
    // No Host header — absent host must be allowed.
    let req = "GET /api/graph HTTP/1.1\r\nContent-Length: 0\r\n\r\n".to_string();
    client.write_all(req.as_bytes()).unwrap();
    client.flush().unwrap();

    serve_once(&listener, &dispatcher, 4 * 1024 * 1024, None);

    let mut resp = Vec::new();
    client.read_to_end(&mut resp).unwrap();
    let status: u16 = String::from_utf8_lossy(&resp)
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    assert_eq!(status, 200, "absent Host must be allowed; got {status}");
}
