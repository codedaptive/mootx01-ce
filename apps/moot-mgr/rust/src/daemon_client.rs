// daemon_client.rs — raw std::net HTTP/1.0 GET client for proxying the resident
// ARIA daemon's read endpoints into the moot-mgr console.
//
// No external HTTP crates — raw TcpStream only (the no-new-external-dep rule
// applies to this host layer). The approach mirrors
// `apps/mootx01/rust/src/core/daemon_client.rs`, adapted for GET rather than
// POST and with a 3-second connect+read timeout for graceful degradation when
// the daemon is down.
//
// CONTENT-SAFETY: this module transports only classification codes, FDC heading
// labels (from the bundled taxonomy), and integer counts from /api/lattice; and
// estate metadata (UUIDs, names, kinds, backend strings, mount states) from
// /api/admin/estates. No memory/rung content ever crosses this surface — the
// daemon itself enforces that contract on its read endpoints.
//
// Daemon address resolution:
//   1. `ARIA_MCP_API_BASE` env var  → parse host and port (http://host:port).
//   2. Default: `http://127.0.0.1:4242`.
// Mirrors Swift `MootManager.ariaAPIBase` (apps/moot-mgr/Sources/MootManager/MootManager.swift ~line 146).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

/// Default daemon base URL when `ARIA_MCP_API_BASE` is not set.
pub const DEFAULT_BASE: &str = "http://127.0.0.1:4242";

/// Connect-and-read timeout for every daemon probe (3 s). Short enough to
/// degrade gracefully when the daemon is not running; matches the Swift host's
/// URLSession timeout for the same proxy paths.
const TIMEOUT: Duration = Duration::from_secs(3);

/// Parse a `http://host:port` URL into a `(host, port)` pair.
///
/// Only HTTP (not HTTPS) is supported — the daemon is loopback-only. Returns
/// `None` on any parse failure so callers can fall back to the default.
pub fn parse_base_url(url: &str) -> Option<(String, u16)> {
    let rest = url.strip_prefix("http://")?;
    // Drop any trailing path component (e.g. "http://127.0.0.1:4242/foo").
    let hostport = rest.split('/').next()?;
    // Split host:port.  IPv4 only — the daemon binds loopback.
    let (host, port_str) = hostport.rsplit_once(':')?;
    let port: u16 = port_str.parse().ok()?;
    if host.is_empty() || port == 0 {
        return None;
    }
    Some((host.to_string(), port))
}

/// Resolve the daemon's `(host, port)`.
///
/// Priority: explicit `ARIA_MCP_API_BASE` override → the port the daemon actually
/// bound, read from `<data>/daemon.port` (the daemon's own source of truth) →
/// `127.0.0.1:4242`. Reading the real port matters because the daemon hunts
/// upward off 4242 with `--http auto`, so a hardcoded 4242 misses it and the
/// console never connects.
pub fn resolved_addr() -> (String, u16) {
    if let Some(addr) = std::env::var("ARIA_MCP_API_BASE")
        .ok()
        .as_deref()
        .and_then(parse_base_url)
    {
        return addr;
    }
    if let Some(port) = read_daemon_port() {
        return ("127.0.0.1".to_string(), port);
    }
    ("127.0.0.1".to_string(), 4242)
}

/// Read the daemon's bound port from `<data>/daemon.port`. `None` when the file
/// is absent or unparseable (daemon not running, or it hasn't written the port
/// yet) — callers then fall back to the default 4242.
fn read_daemon_port() -> Option<u16> {
    let path = crate::resident_host::daemon_port_file_path();
    parse_port_file_contents(&std::fs::read_to_string(path).ok()?)
}

/// Parse a port-file body (the daemon writes the decimal port, possibly with a
/// trailing newline). Pure, for testability. `None` for empty/zero/non-numeric.
fn parse_port_file_contents(raw: &str) -> Option<u16> {
    raw.trim().parse::<u16>().ok().filter(|&p| p != 0)
}

/// Issue a raw HTTP/1.0 GET for the given path against `host:port`.
///
/// Returns `Some(body_bytes)` on a `200 OK` response, `None` on any
/// connect / timeout / non-200 / read failure. `Connection: close` lets us
/// read the body to EOF without needing a Content-Length parser.
///
/// Callers use `None` as the signal to fall back to the honest degraded state;
/// they do not distinguish between "daemon down" and "bad response".
pub fn get(host: &str, port: u16, path: &str) -> Option<Vec<u8>> {
    let addr = format!("{host}:{port}");
    let socket_addr: std::net::SocketAddr = addr.parse().ok()?;

    let mut stream = TcpStream::connect_timeout(&socket_addr, TIMEOUT).ok()?;
    stream.set_read_timeout(Some(TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(TIMEOUT)).ok()?;

    // HTTP/1.0 GET — simplest framing: the server closes the connection after
    // the response body, so we read to EOF and get exactly the full body with
    // no chunked-transfer complexity.
    let request = format!(
        "GET {path} HTTP/1.0\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).ok()?;
    stream.flush().ok()?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).ok()?;

    // Split headers / body at the blank line.
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(raw.len());

    let head = String::from_utf8_lossy(&raw[..split.min(raw.len())]);

    // Only accept 200 OK.
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split(' ').nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    if status != 200 {
        return None;
    }

    let body = raw[split.min(raw.len())..].to_vec();
    Some(body)
}

// ─────────────────────────────── tests ────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_port_file_contents (daemon.port resolution) ─────────────────────

    #[test]
    fn parse_port_file_contents_accepts_decimal_with_newline() {
        assert_eq!(parse_port_file_contents("4243\n"), Some(4243));
        assert_eq!(parse_port_file_contents("4242"), Some(4242));
        assert_eq!(parse_port_file_contents("  5000  "), Some(5000));
    }

    #[test]
    fn parse_port_file_contents_rejects_empty_zero_and_garbage() {
        assert_eq!(parse_port_file_contents(""), None);
        assert_eq!(parse_port_file_contents("\n"), None);
        assert_eq!(parse_port_file_contents("0"), None);
        assert_eq!(parse_port_file_contents("not-a-port"), None);
    }

    // ── parse_base_url ────────────────────────────────────────────────────────

    #[test]
    fn parse_base_url_standard() {
        assert_eq!(
            parse_base_url("http://127.0.0.1:4242"),
            Some(("127.0.0.1".to_string(), 4242))
        );
    }

    #[test]
    fn parse_base_url_custom_port() {
        assert_eq!(
            parse_base_url("http://127.0.0.1:9000"),
            Some(("127.0.0.1".to_string(), 9000))
        );
    }

    #[test]
    fn parse_base_url_with_trailing_slash() {
        // Path after the host:port is stripped; host+port are still resolved.
        assert_eq!(
            parse_base_url("http://127.0.0.1:4242/api/lattice"),
            Some(("127.0.0.1".to_string(), 4242))
        );
    }

    #[test]
    fn parse_base_url_rejects_https() {
        // Only http:// is supported (loopback daemon is plain HTTP).
        assert_eq!(parse_base_url("https://127.0.0.1:4242"), None);
    }

    #[test]
    fn parse_base_url_rejects_no_port() {
        assert_eq!(parse_base_url("http://127.0.0.1"), None);
    }

    #[test]
    fn parse_base_url_rejects_garbage() {
        assert_eq!(parse_base_url("not-a-url"), None);
        assert_eq!(parse_base_url(""), None);
    }

    // ── get — live loopback echo server ───────────────────────────────────────

    /// Start a minimal one-shot HTTP/1.0 server that responds to the next GET
    /// with the given status line + body. Returns (listener, port).
    fn one_shot_server(status: u16, body: &'static [u8]) -> (std::net::TcpListener, u16) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let listener_clone = listener.try_clone().unwrap();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = listener_clone.accept() {
                // Drain the request.
                let mut buf = [0u8; 4096];
                let _ = s.read(&mut buf);
                let reason = if status == 200 { "OK" } else { "Service Unavailable" };
                let header = format!(
                    "HTTP/1.0 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(header.as_bytes());
                let _ = s.write_all(body);
            }
        });
        (listener, port)
    }

    #[test]
    fn get_returns_body_on_200() {
        let body: &'static [u8] = br#"{"addresses":[]}"#;
        let (_listener, port) = one_shot_server(200, body);
        let result = get("127.0.0.1", port, "/api/lattice");
        assert_eq!(result.as_deref(), Some(body));
    }

    #[test]
    fn get_returns_none_on_non_200() {
        let (_listener, port) = one_shot_server(503, b"error");
        let result = get("127.0.0.1", port, "/api/lattice");
        assert!(result.is_none(), "non-200 must degrade to None");
    }

    #[test]
    fn get_returns_none_when_unreachable() {
        // Port 1 is almost certainly not bound; connect_timeout should fail fast.
        // We use a dedicated closed-port probe rather than timing out the 3s window.
        // Find a guaranteed-closed port by binding port 0, noting it, then dropping.
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let closed_port = l.local_addr().unwrap().port();
        drop(l); // port is now closed (no acceptor)
        let result = get("127.0.0.1", closed_port, "/api/lattice");
        assert!(result.is_none(), "closed port must degrade to None");
    }
}
