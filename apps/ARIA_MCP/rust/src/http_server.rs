//! Loopback HTTP MCP transport — Rust version.
//!
//! Mirrors the Swift `HTTPServer` wire behavior: a client POSTs one JSON-RPC
//! frame and receives one JSON-RPC frame as the `application/json` response
//! body. The JSON-RPC surface is identical to the stdio loop (`server.rs`);
//! only the framing differs (HTTP body vs newline-delimited stdin/stdout).
//!
//! # No-FFI
//!
//! Per ADR-LOOPBACKHTTP-001 the shared `LoopbackHTTP` library is Swift-only.
//! This Rust vertical hand-rolls its own `std::net` listener and a minimal HTTP
//! parser; parity with the Swift transport is enforced at the JSON-RPC wire, not
//! the transport implementation. The two servers are independent verticals.
//!
//! # Concurrency
//!
//! Connections are served sequentially against a single `Dispatcher` (the stdio
//! loop is single-threaded too). The observable wire behavior is identical to
//! the Swift transport's concurrent serving; the concurrency model is a
//! per-language choice, like ObserverSink's. Concurrency hardening is a later
//! (P4) concern.
//!
//! # Security
//!
//! Binds loopback only (`127.0.0.1`), never `0.0.0.0`. No authentication on the
//! Community-Edition transport (ADR-LOOPBACKHTTP-001); the Enterprise OAuth layer
//! composes above the transport in v2.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

use crate::dispatcher::Dispatcher;
use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JSONRPCResponse, JsonValue};
use crate::server::ServerConfig;

/// Header block cap — guards against an unbounded read from a misbehaving
/// (loopback-but-hostile) peer. Matches the Swift LoopbackHTTP default.
const MAX_HEADER_BYTES: usize = 64 * 1024;

/// Run the resident loopback HTTP MCP transport on `127.0.0.1:port` until the
/// process is terminated. Returns only if the bind fails.
pub fn run_http_loop(port: u16, max_body_bytes: usize, config: ServerConfig) -> std::io::Result<()> {
    let dispatcher = Dispatcher::new(config.registry, &config.server_name, &config.server_version);
    let listener = bind_loopback(port)?;
    let bound = listener.local_addr()?.port();
    eprintln!("aria-mcp: HTTP listening on 127.0.0.1:{bound} (max body {max_body_bytes} bytes)");
    loop {
        serve_once(&listener, &dispatcher, max_body_bytes);
    }
}

/// Bind a TCP listener to the loopback interface only. Never `INADDR_ANY`.
pub fn bind_loopback(port: u16) -> std::io::Result<TcpListener> {
    TcpListener::bind(("127.0.0.1", port))
}

/// Accept one connection and serve it. Exposed for tests; `run_http_loop` calls
/// it in a loop.
pub fn serve_once(listener: &TcpListener, dispatcher: &Dispatcher, max_body_bytes: usize) {
    match listener.accept() {
        Ok((mut stream, _)) => serve(&mut stream, dispatcher, max_body_bytes),
        Err(e) => eprintln!("aria-mcp: accept error: {e}"),
    }
}

/// A parsed HTTP request: the method, the Origin (for the CSRF/DNS-rebinding
/// guard), and the body. The path is always `/`.
struct HttpRequest {
    method: String,
    origin: Option<String>,
    body: Vec<u8>,
}

/// Serve one connection: read the request, route it, write the response.
fn serve(stream: &mut TcpStream, dispatcher: &Dispatcher, max_body_bytes: usize) {
    let request = match read_request(stream, max_body_bytes) {
        Some(r) => r,
        None => return,
    };
    let (status, body) = route(&request, dispatcher);
    write_http_response(stream, status, &body);
}

/// Read one HTTP/1.1 request: request line + headers, then exactly
/// Content-Length body bytes bounded by `max_body_bytes`.
fn read_request(stream: &mut TcpStream, max_body_bytes: usize) -> Option<HttpRequest> {
    let mut buf: Vec<u8> = Vec::new();
    let mut tmp = [0u8; 16 * 1024];

    // Read until the header terminator (CRLF CRLF).
    let header_end = loop {
        if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > MAX_HEADER_BYTES {
            return None;
        }
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let header_text = std::str::from_utf8(&buf[..header_end]).ok()?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next()?;
    let method = request_line.split(' ').next()?.to_owned();

    let mut content_length = 0usize;
    let mut origin: Option<String> = None;
    for line in lines {
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim();
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().unwrap_or(0);
            } else if name.eq_ignore_ascii_case("origin") {
                origin = Some(value.trim().to_string());
            }
        }
    }

    // Body: read up to min(Content-Length, max_body_bytes). A body larger than
    // the cap is bounded; callers set max_body_bytes high enough that a valid
    // MCP tools/call cannot be truncated (ADR-LOOPBACKHTTP-001 condition 2).
    let want = content_length.min(max_body_bytes);
    let mut body: Vec<u8> = buf[header_end..].to_vec();
    while body.len() < want {
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&tmp[..n]);
    }
    if body.len() > want {
        body.truncate(want);
    }

    Some(HttpRequest { method, origin, body })
}

/// Route one request to `(status, body)`. The parse → decode → dispatch → encode
/// path mirrors `server::handle_frame` so the JSON-RPC bytes match the stdio
/// transport. JSON-RPC-level failures return HTTP 200 with a JSON-RPC error
/// object (the error is in the body); a notification returns HTTP 202, empty.
fn route(request: &HttpRequest, dispatcher: &Dispatcher) -> (u16, Vec<u8>) {
    // DNS-rebinding / CSRF guard (runs first). Accept absent/loopback Origins
    // (native MCP clients send none); reject any other origin — that is a
    // cross-origin browser request. CSRF boundary, not authentication; mirrors
    // the Swift HTTPServer.isOriginAllowed and moot-mgr's HTTPReadAPI.
    if !is_origin_allowed(request.origin.as_deref()) {
        return (403, br#"{"error":"forbidden_origin"}"#.to_vec());
    }

    if request.method != "POST" {
        return (405, br#"{"error":"method_not_allowed"}"#.to_vec());
    }

    let parsed: serde_json::Value = match serde_json::from_slice(&request.body) {
        Ok(v) => v,
        Err(e) => {
            return (
                200,
                error_frame(JSONRPCErrorCode::PARSE_ERROR, &format!("Parse error: {e}")),
            );
        }
    };

    let rpc = match JSONRPCRequest::decode(&parsed) {
        Some(r) => r,
        None => {
            return (
                200,
                error_frame(
                    JSONRPCErrorCode::INVALID_REQUEST,
                    "Invalid Request: malformed JSON-RPC envelope",
                ),
            );
        }
    };

    if rpc.is_notification() {
        eprintln!("aria-mcp: notification: {}", rpc.method);
        return (202, Vec::new());
    }

    let response = dispatcher.handle(&rpc);
    match serde_json::to_vec(&response) {
        Ok(bytes) => (200, bytes),
        Err(e) => {
            eprintln!("aria-mcp: serialization error: {e}");
            (200, error_frame(JSONRPCErrorCode::INTERNAL_ERROR, "Internal error"))
        }
    }
}

/// Serialize a JSON-RPC error object (null id) to bytes.
fn error_frame(code: i64, message: &str) -> Vec<u8> {
    let response = JSONRPCResponse::failure(JsonValue::Null, JSONRPCError::new(code, message));
    serde_json::to_vec(&response).unwrap_or_else(|_| {
        br#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#.to_vec()
    })
}

/// Write an HTTP/1.1 response. `Content-Type: application/json` is sent only when
/// there is a body (matching the Swift transport's empty-202 shape); 405 carries
/// `Allow: POST`.
fn write_http_response(stream: &mut TcpStream, status: u16, body: &[u8]) {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        405 => "Method Not Allowed",
        _ => "OK",
    };
    let mut head = format!("HTTP/1.1 {status} {reason}\r\n");
    if !body.is_empty() {
        head.push_str("Content-Type: application/json\r\n");
    }
    head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    if status == 405 {
        head.push_str("Allow: POST\r\n");
    }
    head.push_str("Connection: close\r\n\r\n");
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

/// True if the Origin is acceptable: absent (native MCP clients send none) or a
/// loopback origin. Any other origin is a cross-origin browser request (the
/// DNS-rebinding vector) and is rejected. Mirrors the Swift
/// `HTTPServer.isOriginAllowed`.
fn is_origin_allowed(origin: Option<&str>) -> bool {
    match origin {
        None => true,
        Some(o) if o.is_empty() => true,
        Some(o) => {
            let l = o.to_ascii_lowercase();
            l.starts_with("http://127.0.0.1")
                || l.starts_with("http://localhost")
                || l.starts_with("https://127.0.0.1")
                || l.starts_with("https://localhost")
                || l.starts_with("http://[::1]")
                || l.starts_with("https://[::1]")
        }
    }
}

/// Find the first index of `needle` in `haystack`.
fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}
