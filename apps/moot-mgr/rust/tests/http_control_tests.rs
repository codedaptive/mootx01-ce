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
fn http_request(port: u16, raw: &str) -> (String, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    stream.write_all(raw.as_bytes()).unwrap();
    stream.flush().unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
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
    // The host's own EstateAdmin section is merged in (the manager's base.admin
    // is null; HttpReadApi substitutes the host's admin payload). With nothing
    // provisioned the admin section is present but empty.
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
