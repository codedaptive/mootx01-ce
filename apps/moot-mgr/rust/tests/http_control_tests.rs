// http_control_tests.rs — Rust twin of the Swift HTTPReadAPITests +
// ControlChannelTests + StaticServingTests + AdminPlaneGatedTests. Exercises the
// loopback HTTP read-API, the token+Origin-gated HTTP control surface, the UDS
// control channel, static asset serving, and the admin-plane gate end-to-end
// against a real bound listener. SCRATCH stores / temp dirs only.

// This suite binds a Unix-domain-socket control channel via `started_host()`,
// so the whole file is Unix-only. The HTTP read-API it also exercises is
// cross-platform, but the shared harness is UDS-coupled; the Windows control
// channel is a named pipe, whose coverage is a separate future suite.
#![cfg(unix)]

use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;

use moot_mgr::resident_host::{ResidentHost, ResidentHostConfig};
use moot_mgr::manager_config::ManagerConfig;

const NOW: f64 = 1_700_000_000.0;
/// A control token long enough to be honoured (>= 16 chars).
const TOKEN: &str = "test-token-0123456789";

fn scratch_dir() -> String {
    std::env::temp_dir()
        .join(format!("moot-mgr-rs-host-{}", uuid::Uuid::new_v4()))
        .to_string_lossy()
        .into_owned()
}

/// A short UDS socket path. Unix domain socket paths are bounded by `SUN_LEN`
/// (~104 bytes on macOS, 108 on Linux), and the scratch dir under the temp root
/// can exceed that — so the control socket is placed directly under the temp
/// root with a short unique name, well inside the limit on both platforms. This
/// is correct host practice (the resident host's default socket sits beside the
/// store, a short path); only the test's deep scratch dir would overflow.
fn scratch_socket() -> String {
    std::env::temp_dir()
        .join(format!("mm-{}.sock", &uuid::Uuid::new_v4().simple().to_string()[..12]))
        .to_string_lossy()
        .into_owned()
}

/// Build a resident host bound to an OS-assigned port (http_port = 0) with a
/// UDS control socket under a fresh scratch dir.
fn started_host() -> ResidentHost {
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let store = format!("{dir}/stats.sqlite");
    let socket = scratch_socket();
    let estates = format!("{dir}/estates");
    let cfg = ResidentHostConfig::new(
        ManagerConfig::new(store, 7 * 24 * 60 * 60, 3600),
        0, // OS-assigned port
        TOKEN,
        socket,
        estates,
    );
    let mut host = ResidentHost::new(cfg, NOW);
    host.start().expect("host must start");
    host
}

/// Issue a raw HTTP request to 127.0.0.1:port and return (status_line, body).
/// Tolerates a connection reset after the response is written (the server may
/// RST rather than FIN when it drops the stream after writing the response,
/// which happens on the 503 shed path on some platforms).
fn http_request(port: u16, raw: &str) -> (String, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    stream.write_all(raw.as_bytes()).unwrap();
    stream.flush().unwrap();
    let mut response = Vec::new();
    // Read until EOF or an error. A connection-reset-by-peer after a complete
    // response (the shed 503 path) is treated as EOF so the response is parsed.
    let mut buf = [0u8; 4096];
    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,            // clean EOF
            Ok(n) => response.extend_from_slice(&buf[..n]),
            Err(_) => break,           // RST or other error; parse what we have
        }
    }
    let response = String::from_utf8_lossy(&response).into_owned();
    let (head, body) = response.split_once("\r\n\r\n").unwrap_or((&response, ""));
    let status_line = head.lines().next().unwrap_or("").to_string();
    (status_line, body.to_string())
}

fn get(port: u16, path: &str) -> (String, String) {
    http_request(
        port,
        &format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"),
    )
}

// ───────────────────────────── read endpoints ──────────────────────────────

#[test]
fn read_endpoints_return_json() {
    let mut host = started_host();
    let port = host.bound_http_port();
    for path in ["/api/server", "/api/estates", "/api/config", "/api/events", "/api/graph"] {
        let (status, body) = get(port, path);
        assert!(status.contains("200"), "{path} → {status}");
        assert!(body.starts_with('{'), "{path} body is JSON object");
    }
    host.stop();
}

#[test]
fn estates_endpoint_merges_host_admin_section() {
    let mut host = started_host();
    let port = host.bound_http_port();
    // HttpReadApi overwrites admin with the local EstateAdmin payload (the
    // manager's base.admin may be non-null when the daemon proxy succeeds, but
    // this route replaces it). With nothing provisioned the admin section is
    // present but the hosted list is empty.
    let (status, body) = get(port, "/api/estates");
    assert!(status.contains("200"));
    assert!(body.contains("\"admin\""));
    assert!(body.contains("\"hosted\""));
    host.stop();
}

#[test]
fn json_keys_are_sorted() {
    let mut host = started_host();
    let port = host.bound_http_port();
    let (_s, body) = get(port, "/api/config");
    // sorted-keys output: monitoringEnabled < retentionCutoff < retentionSeconds.
    let mon = body.find("monitoringEnabled").unwrap();
    let cut = body.find("retentionCutoff").unwrap();
    let secs = body.find("retentionSeconds").unwrap();
    assert!(mon < cut && cut < secs, "object keys must be lexicographically sorted");
    host.stop();
}

// ───────────────────────────── static serving ──────────────────────────────

#[test]
fn static_assets_serve_from_allowlist() {
    let mut host = started_host();
    let port = host.bound_http_port();
    let (status, body) = get(port, "/");
    assert!(status.contains("200"));
    assert!(body.contains("<!DOCTYPE html>") || body.contains("<html"));
    // app.css with a cache-busting query resolves.
    let (css_status, _css) = get(port, "/app.css?v=24");
    assert!(css_status.contains("200"));
    let (js_status, _js) = get(port, "/app.js?v=24");
    assert!(js_status.contains("200"));
    // An off-allowlist path is 404 (no traversal).
    let (nf, _b) = get(port, "/../etc/passwd");
    assert!(nf.contains("404"));
    host.stop();
}

// ───────────────────────── HTTP control gate (CSRF + token) ─────────────────

#[test]
fn http_control_requires_token() {
    let mut host = started_host();
    let port = host.bound_http_port();
    // No Authorization header → 401.
    let raw = "POST /api/control/monitoring/on HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    let (status, _b) = http_request(port, raw);
    assert!(status.contains("401"), "missing token must be 401, got {status}");
    host.stop();
}

#[test]
fn http_control_rejects_cross_origin() {
    let mut host = started_host();
    let port = host.bound_http_port();
    // Cross-origin Origin → 403, BEFORE the token is even examined.
    let raw = format!(
        "POST /api/control/monitoring/on HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    let (status, _b) = http_request(port, &raw);
    assert!(status.contains("403"), "cross-origin must be 403, got {status}");
    host.stop();
}

/// Loopback-prefix spoofing: `localhost.evil` DNS-resolves to 127.0.0.1 and the
/// page sends its own origin. The old prefix-only check would allow this; the
/// suffix-validated check rejects it before the token is examined.
#[test]
fn http_control_rejects_loopback_prefix_spoof_origin() {
    let mut host = started_host();
    let port = host.bound_http_port();
    let raw = format!(
        "POST /api/control/monitoring/on HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost.evil\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    let (status, _b) = http_request(port, &raw);
    assert!(status.contains("403"), "spoofed loopback origin must be 403, got {status}");
    host.stop();
}

#[test]
fn http_control_with_token_sets_monitoring() {
    let mut host = started_host();
    let port = host.bound_http_port();
    let raw = format!(
        "POST /api/control/monitoring/on HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    let (status, body) = http_request(port, &raw);
    assert!(status.contains("200"), "valid token must be 200, got {status}");
    assert!(body.contains("\"ok\":true"));
    // The flag is now ON, visible on the read surface.
    let (_s, config) = get(port, "/api/config");
    assert!(config.contains("\"monitoringEnabled\":true"));
    host.stop();
}

// ───────────────────────── UDS control channel ─────────────────────────────

/// Send one line-oriented control request to the UDS and return the JSON reply.
fn uds_control(socket_path: &str, line: &str) -> String {
    let mut stream = UnixStream::connect(socket_path).expect("connect UDS");
    stream.write_all(line.as_bytes()).unwrap();
    stream.write_all(b"\n").unwrap();
    stream.flush().unwrap();
    let mut reply = String::new();
    stream.read_to_string(&mut reply).unwrap();
    reply
}

#[test]
fn uds_control_applies_verbs_without_a_token() {
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let socket = scratch_socket();
    let cfg = ResidentHostConfig::new(
        ManagerConfig::new(format!("{dir}/stats.sqlite"), 100_000, 3600),
        0,
        TOKEN,
        socket.clone(),
        format!("{dir}/estates"),
    );
    let mut host = ResidentHost::new(cfg, NOW);
    host.start().unwrap();

    // The UDS needs NO token (the 0600 socket perms are the gate). monitoring/on.
    let reply = uds_control(&socket, "/api/control/monitoring/on");
    assert!(reply.contains("\"ok\":true"));
    assert!(reply.contains("monitoring: ON"));

    // retention with a JSON body after a tab.
    let reply = uds_control(&socket, "/api/control/retention\t{\"seconds\":3600}");
    assert!(reply.contains("\"ok\":true"));
    assert!(reply.contains("retention: 3600s"));

    // Unknown verb → ok:false.
    let reply = uds_control(&socket, "/api/control/bogus");
    assert!(reply.contains("\"ok\":false"));

    host.stop();
}

#[test]
fn uds_socket_is_owner_only_0600() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let socket = scratch_socket();
    let cfg = ResidentHostConfig::new(
        ManagerConfig::new(format!("{dir}/stats.sqlite"), 100_000, 3600),
        0,
        TOKEN,
        socket.clone(),
        format!("{dir}/estates"),
    );
    let mut host = ResidentHost::new(cfg, NOW);
    host.start().unwrap();
    let perms = std::fs::metadata(&socket).unwrap().permissions();
    // The low 9 mode bits must be exactly 0600 (owner rw, no group/other).
    assert_eq!(perms.mode() & 0o777, 0o600);
    host.stop();
}

// ───────────────────── admin plane gate (provision over UDS) ────────────────

#[test]
fn admin_provision_over_uds_lights_corpus_and_appears_in_estates() {
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let socket = scratch_socket();
    let cfg = ResidentHostConfig::new(
        ManagerConfig::new(format!("{dir}/stats.sqlite"), 100_000, 3600),
        0,
        TOKEN,
        socket.clone(),
        format!("{dir}/estates"),
    );
    let mut host = ResidentHost::new(cfg, NOW);
    host.start().unwrap();
    let port = host.bound_http_port();

    // Provision a GLK/InMemory estate over the gated UDS (admin plane).
    let body = r#"{"estateName":"GatedScratch","kind":"GLK","backend":"InMemory","zoomWindowLow":1,"zoomWindowHigh":10,"frameworkProfile":"KnowledgeWork","syncMode":"None","owner":"gate-test"}"#;
    let reply = uds_control(&socket, &format!("/api/control/estate/provision\t{body}"));
    assert!(reply.contains("\"ok\":true"), "provision reply: {reply}");
    assert!(reply.contains("provisioned GLK estate"));

    // The provisioned estate now appears in the read-plane /api/estates admin
    // section (host-provisioned, mounted).
    let (status, estates_body) = get(port, "/api/estates");
    assert!(status.contains("200"));
    assert!(estates_body.contains("GatedScratch"), "estates: {estates_body}");
    assert!(estates_body.contains("\"mountState\":\"mounted\""));

    // DEBT-1+2 hold for the gated path too: the provisioned estate is cache-on
    // and corpus-registered (the host's admin engine constructed it via provision).
    {
        let admin = host.admin_handle();
        let admin = admin.lock().unwrap();
        let hosted = admin.payload();
        let uuid = &hosted.hosted[0].estate_uuid;
        // cache-on default unless a CI runner forced it off.
        if std::env::var("MOOTX01_ESTATE_CACHE").is_err() {
            assert_eq!(admin.backing_storage_is_caching(uuid), Some(true));
        }
        assert_eq!(admin.backing_estate_has_corpus(uuid), Some(true));
    }

    host.stop();
}

// ─────────────────────── concurrency cap (CAND-011) ──────────────────────────

// These tests exercise the LoopbackConnGate directly and through the real HTTP
// server, confirming:
//   (a) connections beyond the cap are shed with HTTP 503 + Retry-After,
//   (b) a completed connection releases its slot so a new one is accepted,
//   (c) the accept loop itself never stalls (the gate is non-blocking on the
//       accept thread).
//
// Test isolation: cap=2 is used for the server-level tests so only three
// connections are needed — fast and deterministic. The gate unit test drives
// the gate internals directly without a real socket.

use moot_mgr::http_read_api::LoopbackConnGate;

/// Gate unit test: depth tracking and shed behaviour without a real server.
#[test]
fn conn_gate_tracks_depth_and_sheds_at_cap() {
    let gate = LoopbackConnGate::new_for_test(2);
    // Below cap: two enqueues succeed.
    assert!(gate.try_enqueue(), "first slot");
    assert!(gate.try_enqueue(), "second slot");
    assert_eq!(gate.current_depth(), 2);
    // At cap: third enqueue fails (shed path).
    assert!(!gate.try_enqueue(), "third should be shed — cap=2");
    assert_eq!(gate.current_depth(), 2, "depth unchanged after shed");
    // Release one slot; now a new enqueue succeeds.
    gate.release();
    assert_eq!(gate.current_depth(), 1);
    assert!(gate.try_enqueue(), "slot freed by release");
    assert_eq!(gate.current_depth(), 2);
    // Release all.
    gate.release();
    gate.release();
    assert_eq!(gate.current_depth(), 0);
}

/// Slot-release-on-spawn-failure invariant: a reserved slot must be returned
/// to the gate if the worker closure is dropped before it executes (the
/// `std::thread::Builder::spawn` failure path).
///
/// The fix (commit secfix/c-mootmgr-slotleak) binds the release guard on the
/// accept thread immediately after `try_enqueue` succeeds, then MOVES it into
/// the spawn closure. If `spawn` returns `Err`, the closure (and guard) is
/// dropped by the `Err` destructor, calling `release()` — no slot leak.
///
/// This test models that path: reserve a slot, create a "spawn closure" that
/// owns an RAII guard, drop the closure without running it, and verify the
/// gate depth returns to 0. The RAII pattern here mirrors `OnDrop` in
/// http_read_api.rs (the production guard type), but is defined locally so
/// integration tests have no dependency on the private http_read_api internals.
#[test]
fn slot_is_released_when_spawn_closure_is_dropped_before_running() {
    use std::sync::Arc;

    let gate = Arc::new(LoopbackConnGate::new_for_test(2));
    assert_eq!(gate.current_depth(), 0, "gate starts empty");

    // Reserve a slot (as the accept loop does after try_enqueue succeeds).
    assert!(gate.try_enqueue(), "slot reservation must succeed");
    assert_eq!(gate.current_depth(), 1, "depth is 1 after reservation");

    // Build the "spawn closure": an RAII guard bound on the accept thread,
    // moved into a closure that will be discarded without running — exactly
    // what happens when std::thread::Builder::spawn returns Err.
    //
    // SlotGuard mirrors the OnDrop pattern from http_read_api.rs: the closure
    // calls gate.release() when dropped, on ANY path (normal or panic).
    struct SlotGuard(Arc<LoopbackConnGate>);
    impl Drop for SlotGuard {
        fn drop(&mut self) {
            self.0.release();
        }
    }

    let guard = SlotGuard(Arc::clone(&gate));
    // Wrap in a closure that owns the guard — this is the "spawn closure".
    // In production the closure is passed to thread::Builder::spawn; here we
    // simulate spawn failure by dropping the closure without calling it.
    let spawn_closure: Box<dyn FnOnce()> = Box::new(move || {
        let _g = guard; // guard lives in the closure; releases on closure exit
        // (worker body would go here)
    });

    // Simulate spawn failure: drop the closure without executing it.
    // The guard inside should fire release().
    drop(spawn_closure);

    assert_eq!(
        gate.current_depth(),
        0,
        "slot must be released when spawn closure is dropped (spawn-failure path)"
    );

    // Sanity: new connections are accepted again after the leak is fixed.
    assert!(gate.try_enqueue(), "gate accepts new slot after release");
    assert_eq!(gate.current_depth(), 1);
    gate.release();
    assert_eq!(gate.current_depth(), 0);
}

/// Server-level test: connections beyond cap=2 are shed with HTTP 503.
/// Completing a connection frees a slot so the next one is accepted.
#[test]
fn excess_connections_are_shed_503() {
    // Build a host with cap=2 so we only need 3 connections.
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let socket = scratch_socket();
    let cfg = ResidentHostConfig::new(
        ManagerConfig::new(format!("{dir}/stats.sqlite"), 100_000, 3600),
        0,
        TOKEN,
        socket,
        format!("{dir}/estates"),
    );
    // Build the host with an explicit cap of 2 (test-only constructor).
    let mut host = ResidentHost::new_with_http_cap(cfg, NOW, 2);
    host.start().expect("host must start");
    let port = host.bound_http_port();

    // Open two connections and send only a partial HTTP request (no CRLF CRLF
    // terminator). The server's `read_request` blocks in the header-read loop
    // waiting for the end-of-headers marker, keeping the worker thread alive
    // and its gate slot occupied.
    let mut conn1 = TcpStream::connect(("127.0.0.1", port)).expect("conn1");
    conn1.write_all(b"GET /api/server HTTP/1.1\r\nHost: 127.0.0.1\r\n").unwrap();
    // Do NOT write the final \r\n — the server blocks reading headers.

    let mut conn2 = TcpStream::connect(("127.0.0.1", port)).expect("conn2");
    conn2.write_all(b"GET /api/server HTTP/1.1\r\nHost: 127.0.0.1\r\n").unwrap();

    // Yield so the accept loop has processed conn1 + conn2 and their worker
    // threads are past try_enqueue / wait_for_slot (holding slots, blocked in
    // read_request). 50 ms is far below the 3-min test limit and reliable.
    std::thread::sleep(std::time::Duration::from_millis(50));

    // Third connection: gate is at cap — must be shed with 503 immediately
    // without any request headers being read on the accept thread.
    let (status3, body3) = get(port, "/api/server");
    assert!(
        status3.contains("503"),
        "connection beyond cap should be shed with 503, got: {status3}\nbody: {body3}"
    );
    assert!(
        body3.contains("service_unavailable") || body3.contains("retry_after"),
        "503 body should contain shed fields, got: {body3}"
    );

    // Drop conn1 and conn2 — closing the sockets causes read_request to return
    // None (EOF), the worker threads complete, and the OnDrop guards release
    // their slots.
    drop(conn1);
    drop(conn2);

    // Allow the worker threads to call release() via OnDrop. 50 ms is enough;
    // the threads complete as soon as they observe EOF from read_request.
    std::thread::sleep(std::time::Duration::from_millis(50));

    // Now a new connection should succeed — slots were freed by the drops.
    let (status4, _) = get(port, "/api/server");
    assert!(
        status4.contains("200"),
        "post-release connection should succeed with 200, got: {status4}"
    );

    host.stop();
}
