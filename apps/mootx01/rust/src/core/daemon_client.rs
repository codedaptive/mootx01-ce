//! core/daemon_client.rs — minimal loopback HTTP/1.1 client for the resident
//! daemon's MCP transport (std-only; one JSON-RPC frame per POST, mirroring
//! the server's stateless route()).
//!
//! Resolution order for the daemon address (§3): explicit URL → daemon.port
//! file → default 4242.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::core::paths;

pub const DEFAULT_PORT: u16 = 4242;

/// Resolve the daemon port: the port file when present, else 4242.
pub fn resolved_port() -> u16 {
    paths::read_port_file(&paths::daemon_port_file(&paths::data_dir())).unwrap_or(DEFAULT_PORT)
}

/// Parse "http://127.0.0.1:4242" → port. Only loopback HTTP URLs are
/// supported (the daemon binds loopback only).
pub fn port_from_url(url: &str) -> Option<u16> {
    let rest = url.strip_prefix("http://")?;
    let hostport = rest.split('/').next()?;
    let port = hostport.rsplit(':').next()?;
    port.parse().ok()
}

/// Whether the daemon answers on the port.
pub fn alive(port: u16) -> bool {
    TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_millis(250),
    )
    .is_ok()
}

/// POST one JSON-RPC frame; returns (status, body). `Connection: close` so
/// the body can be read to EOF when Content-Length is absent.
pub fn post_frame(port: u16, frame: &[u8]) -> std::io::Result<(u16, Vec<u8>)> {
    let mut stream = TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_secs(2),
    )?;
    stream.set_read_timeout(Some(Duration::from_secs(120)))?;

    let mut request = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        frame.len()
    )
    .into_bytes();
    request.extend_from_slice(frame);
    stream.write_all(&request)?;
    stream.flush()?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw)?;

    // Split headers / body.
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(raw.len());
    let head = String::from_utf8_lossy(&raw[..split.min(raw.len())]);
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split(' ').nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let mut body = raw[split.min(raw.len())..].to_vec();

    // Honor Content-Length when present (read_to_end already got everything
    // thanks to Connection: close; trim any trailing bytes defensively).
    if let Some(len) = head
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|v| v.trim().parse::<usize>().ok())
    {
        body.truncate(len);
    }
    Ok((status, body))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_port_parsing() {
        assert_eq!(port_from_url("http://127.0.0.1:4242"), Some(4242));
        assert_eq!(port_from_url("http://127.0.0.1:4300/"), Some(4300));
        assert_eq!(port_from_url("https://example.com"), None);
        assert_eq!(port_from_url("nonsense"), None);
    }

    #[test]
    fn post_frame_against_local_echo() {
        // Tiny one-shot HTTP responder.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let _ = s.read(&mut buf);
            let body = br#"{"ok":true}"#;
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            s.write_all(resp.as_bytes()).unwrap();
            s.write_all(body).unwrap();
        });
        let (status, body) = post_frame(port, br#"{"jsonrpc":"2.0"}"#).unwrap();
        assert_eq!(status, 200);
        assert_eq!(body, br#"{"ok":true}"#);
        handle.join().unwrap();
    }
}
