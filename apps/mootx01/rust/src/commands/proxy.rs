//! commands/proxy.rs — §4.7: stdio→HTTP bridge for clients that require a
//! stdio command entry (Claude Desktop).
//!
//! Reads newline-delimited JSON-RPC frames from stdin, POSTs each to the
//! resident daemon over loopback HTTP, and writes the response frame to
//! stdout. Notifications (202, empty body) produce no output, matching the
//! MCP stdio convention. Logging goes to stderr; stdout carries frames only.
//!
//! Concurrency: each frame forwards on its own thread. The previous serial
//! loop meant one slow tool call (lens/synthesis on a large estate runs for
//! minutes) blocked every frame behind it — pings, cancellations, parallel
//! calls — and Claude Desktop read the stall as a dead server. Responses may
//! interleave out of order; that is legal JSON-RPC (clients correlate by id).
//!
//! Failure policy: a failed REQUEST — transport error OR HTTP-level failure
//! (empty body at a non-202 status, any non-2xx status, status 0 from an
//! unparseable response line) — gets a synthesized JSON-RPC -32603 error that
//! echoes the request's id. Desktop's MCP client rejects `id: null` frames at
//! the schema level, so the error MUST echo the real id. A failed NOTIFICATION
//! gets nothing (servers must not reply to notifications per MCP spec). The
//! proxy itself only exits on stdin EOF or a stdin read error — never because
//! one call failed. Non-2xx response bodies are never relayed: they may not
//! be JSON-RPC envelopes, and a malformed frame poisons the whole stream.

use std::io::{self, BufRead, Write};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};

use crate::core::daemon_client;
use crate::exit;

pub fn run(daemon_url: Option<String>) -> ExitCode {
    let port = match daemon_url.as_deref() {
        Some(url) => match daemon_client::port_from_url(url) {
            Some(p) => p,
            None => {
                eprintln!(
                    "mootx01 proxy: '--daemon-url' must be a loopback HTTP URL \
                     (e.g. http://127.0.0.1:4242), got '{url}'."
                );
                return ExitCode::from(exit::FAILURE);
            }
        },
        None => daemon_client::resolved_port(),
    };

    // Wait up to 2 min for the daemon to bind: on a large estate it takes
    // ~30 s of startup work before listening, and the service manager may
    // still be relaunching it after an upgrade. A single-shot check meant
    // Claude Desktop connecting right after a daemon restart always failed.
    let mut up = false;
    for attempt in 0..240u32 {
        if daemon_client::alive(port) {
            up = true;
            break;
        }
        if attempt == 10 {
            eprintln!(
                "mootx01 proxy: daemon not up yet on 127.0.0.1:{port} — waiting \
                 (large estates take ~30 s to start)"
            );
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    if !up {
        eprintln!(
            "mootx01 proxy: no resident daemon answering on 127.0.0.1:{port} after 2 min. \
             Start it with `mootx01 serve --http auto` (or check `mootx01 status`)."
        );
        return ExitCode::from(exit::FAILURE);
    }
    eprintln!("mootx01 proxy: bridging stdio ↔ http://127.0.0.1:{port}");

    // Frames forward concurrently; stdout is one stream, so writes serialize
    // through this mutex (an interleaved write would corrupt both frames).
    let stdout = Arc::new(Mutex::new(io::stdout()));
    let mut workers: Vec<std::thread::JoinHandle<()>> = Vec::new();

    // Frame size cap (#36): reject single lines larger than 4 MB. A normal
    // JSON-RPC frame is a few KB; anything larger is a malformed or malicious
    // input that would consume unbounded memory. The cap is generous enough
    // for any legitimate MCP tool call (the largest is vault import which
    // carries a path, not content) while preventing a multi-GB stdin attack.
    const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                eprintln!("mootx01 proxy: stdin read error: {e}");
                return ExitCode::from(exit::FAILURE);
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        if line.len() > MAX_LINE_BYTES {
            eprintln!("mootx01 proxy: frame exceeds {} byte limit, dropped", MAX_LINE_BYTES);
            continue;
        }
        // Reap finished workers so the vec doesn't grow unboundedly over a
        // long session.
        workers.retain(|h| !h.is_finished());
        // Concurrency cap (#12): limit in-flight frames to 16 threads. A burst
        // of frames beyond this waits for an existing worker to finish before
        // spawning. Prevents unbounded thread count from a fast stdin producer.
        const MAX_CONCURRENT: usize = 16;
        while workers.len() >= MAX_CONCURRENT {
            workers.retain(|h| !h.is_finished());
            if workers.len() >= MAX_CONCURRENT {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
        }
        let out = Arc::clone(&stdout);
        workers.push(std::thread::spawn(move || {
            forward_frame(port, &line, &out);
        }));
    }

    // stdin closed: let in-flight calls finish so their responses aren't lost.
    for h in workers {
        let _ = h.join();
    }
    eprintln!("mootx01 proxy: stdin closed, exiting");
    ExitCode::from(exit::OK)
}

/// Write a JSON-RPC error echoing the request's id. Notifications (no id,
/// id:null, unparseable) get nothing, per spec. The id MUST be echoed:
/// Claude Desktop rejects `id: null` frames at the schema level and the
/// resulting parse error poisons the whole stream.
fn respond_error<W: Write>(out: &Arc<Mutex<W>>, line: &str, message: &str) {
    let Some(id) = request_id(line) else { return };
    let msg = message.replace('\\', "\\\\").replace('"', "'");
    let frame = format!(
        "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32603,\"message\":\"{msg}\"}}}}"
    );
    write_frame(out, frame.as_bytes());
}

/// Forward one frame and write the response (or a synthesized, id-echoing
/// error) to stdout. Never exits the proxy; stdout write failures are logged
/// and dropped.
///
/// Guard: if this proxy ever gains an `Mcp-Session-Id` header, session
/// recovery (clear + re-initialize + one-shot retry) must be added at the
/// same time — a server restart without recovery becomes a permanent outage
/// for the session.
fn forward_frame<W: Write>(port: u16, line: &str, out: &Arc<Mutex<W>>) {
    match daemon_client::post_frame(port, line.as_bytes()) {
        // Notification acknowledged; per MCP spec there is no reply.
        Ok((202, _)) => {}

        // Any other empty body is a failure, not a notification — a daemon
        // mid-restart (status 0: post_frame parses an unparseable status line
        // as 0), a 500/503, or a request rejected before the handler. Reply
        // with an id-echoing error so the client unblocks; silence hangs it
        // forever with no visible error.
        Ok((status, body)) if body.is_empty() => {
            respond_error(out, line, &format!("proxy: empty response (HTTP {status})"));
        }

        // Non-2xx: do NOT relay the body. It may not be a JSON-RPC envelope
        // (HTML error page, plain text), and a malformed frame poisons the
        // stream for every later request.
        Ok((status, _)) if !(200..300).contains(&status) => {
            respond_error(out, line, &format!("proxy: HTTP {status}"));
        }

        Ok((_, body)) => write_frame(out, &body),

        Err(e) => {
            eprintln!("mootx01 proxy: daemon request failed: {e}");
            respond_error(out, line, &format!("proxy: {e}"));
        }
    }
}

fn write_frame<W: Write>(out: &Arc<Mutex<W>>, body: &[u8]) {
    let mut w = match out.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(), // a poisoned mutex is still writable
    };
    if w.write_all(body).and_then(|_| w.write_all(b"\n")).is_err() {
        eprintln!("mootx01 proxy: stdout write failed (client hung up)");
        return;
    }
    let _ = w.flush();
}

/// Extract the JSON-RPC `id` of a request frame, re-encoded as a JSON literal
/// (quoted string or bare number). Returns None for notifications (no id) and
/// unparseable frames — both get no synthesized reply.
fn request_id(line: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let id = v.get("id")?;
    match id {
        serde_json::Value::String(_) | serde_json::Value::Number(_) => {
            serde_json::to_string(id).ok()
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    use std::net::TcpListener;

    // ── test frames ──────────────────────────────────────────────────────────

    const REQUEST: &str = r#"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{}}"#;
    const NOTIFICATION: &str = r#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#;
    const NULL_ID: &str = r#"{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{}}"#;
    const VALID_BODY: &[u8] = br#"{"jsonrpc":"2.0","id":42,"result":{}}"#;

    // ── helpers ───────────────────────────────────────────────────────────────

    /// Collect newline-terminated frames from the capture buffer.
    fn captured_frames(buf: &Arc<Mutex<Vec<u8>>>) -> Vec<String> {
        let bytes = buf.lock().unwrap();
        String::from_utf8_lossy(&bytes)
            .lines()
            .filter(|l| !l.is_empty())
            .map(String::from)
            .collect()
    }

    /// Build a minimal HTTP/1.1 response for the given status + body.
    fn http_resp(status: u16, reason: &str, body: &[u8]) -> Vec<u8> {
        let mut r = format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        r.extend_from_slice(body);
        r
    }

    /// Build a response with an unparseable status line.
    /// `post_frame` parses it as status 0 — the most common real-world route
    /// into the empty-body drop arm (daemon accepts TCP then resets mid-restart).
    fn http_resp_garbage_status(body: &[u8]) -> Vec<u8> {
        let mut r = format!(
            "GARBAGE LINE\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        r.extend_from_slice(body);
        r
    }

    /// Start a stub server that serves each response once, returns the port.
    fn stub_server(responses: Vec<Vec<u8>>) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for resp in responses {
                if let Ok((mut conn, _)) = listener.accept() {
                    let mut drain = vec![0u8; 8192];
                    // Drain the request before replying (avoids broken-pipe resets).
                    let _ = conn.read(&mut drain);
                    let _ = conn.write_all(&resp);
                }
            }
        });
        port
    }

    fn capture_buf() -> Arc<Mutex<Vec<u8>>> {
        Arc::new(Mutex::new(Vec::new()))
    }

    // ── request_id conformance ────────────────────────────────────────────────

    #[test]
    fn request_id_extracts_number_string_and_rejects_notifications() {
        assert_eq!(request_id(r#"{"jsonrpc":"2.0","id":7,"method":"x"}"#), Some("7".into()));
        assert_eq!(
            request_id(r#"{"jsonrpc":"2.0","id":"ab\"c","method":"x"}"#),
            Some(r#""ab\"c""#.into())
        );
        // Notification: no id → no synthesized reply.
        assert_eq!(request_id(r#"{"jsonrpc":"2.0","method":"notifications/x"}"#), None);
        // Null id must NOT round-trip into an error frame (Desktop rejects it).
        assert_eq!(request_id(r#"{"jsonrpc":"2.0","id":null,"method":"x"}"#), None);
        assert_eq!(request_id("not json"), None);
        // Boolean id: Value::Bool is not String or Number, so this must return None.
        assert_eq!(request_id(r#"{"jsonrpc":"2.0","id":true,"method":"x"}"#), None);
    }

    // ── disposition table ─────────────────────────────────────────────────────

    #[test]
    fn status_200_valid_body_is_relayed_verbatim() {
        let port = stub_server(vec![http_resp(200, "OK", VALID_BODY)]);
        let buf = capture_buf();
        forward_frame(port, REQUEST, &buf);
        let frames = captured_frames(&buf);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0], String::from_utf8_lossy(VALID_BODY));
    }

    #[test]
    fn status_202_empty_produces_no_frame() {
        let port = stub_server(vec![http_resp(202, "Accepted", b"")]);
        let buf = capture_buf();
        forward_frame(port, REQUEST, &buf);
        assert!(captured_frames(&buf).is_empty(), "202 must produce no output frame");
    }

    #[test]
    fn status_202_empty_notification_produces_no_frame() {
        let port = stub_server(vec![http_resp(202, "Accepted", b"")]);
        let buf = capture_buf();
        forward_frame(port, NOTIFICATION, &buf);
        assert!(captured_frames(&buf).is_empty(), "202 notification must produce no output frame");
    }

    #[test]
    fn status_500_empty_body_produces_error_frame_echoing_id() {
        let port = stub_server(vec![http_resp(500, "Internal Server Error", b"")]);
        let buf = capture_buf();
        forward_frame(port, REQUEST, &buf);
        let frames = captured_frames(&buf);
        assert_eq!(frames.len(), 1, "500+empty must produce exactly one error frame");
        let f: serde_json::Value = serde_json::from_str(&frames[0]).unwrap();
        assert_eq!(f["id"], 42);
        assert_eq!(f["error"]["code"], -32603);
        assert!(f["error"]["message"].as_str().unwrap().contains("HTTP 500"));
    }

    /// Status 0 is what post_frame yields when the TCP connection is accepted
    /// but the HTTP status line cannot be parsed (daemon mid-restart: accepts
    /// the connection then resets before writing a valid response).
    #[test]
    fn status_0_empty_body_produces_error_frame_echoing_id() {
        let port = stub_server(vec![http_resp_garbage_status(b"")]);
        let buf = capture_buf();
        forward_frame(port, REQUEST, &buf);
        let frames = captured_frames(&buf);
        assert_eq!(frames.len(), 1, "status-0+empty must produce exactly one error frame");
        let f: serde_json::Value = serde_json::from_str(&frames[0]).unwrap();
        assert_eq!(f["id"], 42);
        assert_eq!(f["error"]["code"], -32603);
        assert!(f["error"]["message"].as_str().unwrap().contains("HTTP 0"));
    }

    #[test]
    fn status_0_garbage_body_produces_error_frame_body_not_relayed() {
        let port = stub_server(vec![http_resp_garbage_status(b"<html>garbage</html>")]);
        let buf = capture_buf();
        forward_frame(port, REQUEST, &buf);
        let frames = captured_frames(&buf);
        assert_eq!(frames.len(), 1, "status-0+garbage must produce exactly one error frame");
        // The raw garbage body must not appear in the error frame.
        assert!(!frames[0].contains("html"), "garbage body must not be relayed");
        let f: serde_json::Value = serde_json::from_str(&frames[0]).unwrap();
        assert_eq!(f["id"], 42);
    }

    #[test]
    fn status_503_non_json_body_produces_error_frame_body_not_relayed() {
        let html = b"<html><body>Service Unavailable</body></html>";
        let port = stub_server(vec![http_resp(503, "Service Unavailable", html)]);
        let buf = capture_buf();
        forward_frame(port, REQUEST, &buf);
        let frames = captured_frames(&buf);
        assert_eq!(frames.len(), 1, "503+non-JSON body must produce exactly one error frame");
        assert!(!frames[0].contains("html"), "non-JSON body must not be relayed");
        let f: serde_json::Value = serde_json::from_str(&frames[0]).unwrap();
        assert_eq!(f["id"], 42);
        assert_eq!(f["error"]["code"], -32603);
        assert!(f["error"]["message"].as_str().unwrap().contains("HTTP 503"));
    }

    #[test]
    fn notification_any_failure_produces_no_frame() {
        let port = stub_server(vec![http_resp(500, "Internal Server Error", b"")]);
        let buf = capture_buf();
        forward_frame(port, NOTIFICATION, &buf);
        assert!(captured_frames(&buf).is_empty(), "notification failure must produce no frame");
    }

    #[test]
    fn null_id_any_failure_produces_no_frame() {
        let port = stub_server(vec![http_resp(500, "Internal Server Error", b"")]);
        let buf = capture_buf();
        forward_frame(port, NULL_ID, &buf);
        assert!(captured_frames(&buf).is_empty(), "null-id failure must produce no frame");
    }

    // ── daemon-restart regression ─────────────────────────────────────────────

    /// Regression: daemon restart between two requests on one session.
    ///
    /// Frame 1: stub server answers normally.
    /// Restart: stub server exits; subsequent connections fail.
    /// Frame 2: proxy receives a transport error. The invariant requires a
    /// synthesized error echoing id 2 — never silence, which would hang the client.
    ///
    /// This is the regression that the original empty-body drop arm allowed:
    /// a restarting daemon (status 0, empty body) produced no output and the
    /// client waited indefinitely. The test exercises the transport-error path
    /// (connection refused) which is simpler to produce deterministically and
    /// exercises the same invariant.
    #[test]
    fn daemon_restart_second_request_still_answered() {
        // Frame 1: serve one request, then let the listener drop (simulates daemon exit).
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let resp1 = http_resp(200, "OK", VALID_BODY);
        std::thread::spawn(move || {
            if let Ok((mut conn, _)) = listener.accept() {
                let mut drain = vec![0u8; 8192];
                let _ = conn.read(&mut drain);
                let _ = conn.write_all(&resp1);
                // listener drops here: subsequent connects → connection refused.
            }
        });

        let buf = capture_buf();
        let req1 = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#;
        forward_frame(port, req1, &buf);
        let after1 = captured_frames(&buf);
        assert_eq!(after1.len(), 1, "frame 1 must produce exactly one response");

        // Frame 2: daemon is gone (connection refused). Proxy must synthesize an error.
        let req2 = r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#;
        forward_frame(port, req2, &buf);
        let after2 = captured_frames(&buf);
        assert!(
            after2.len() >= 2,
            "frame 2 must produce a response after daemon restart; got: {after2:?}"
        );
        let f2: serde_json::Value = serde_json::from_str(&after2[1]).unwrap();
        assert_eq!(f2["id"], 2, "frame 2 response must echo id 2");
        // Must be an error frame, not a relay of garbage.
        assert!(f2.get("error").is_some(), "frame 2 must be a JSON-RPC error");
    }
}
