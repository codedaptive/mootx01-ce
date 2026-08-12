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
fn respond_error(stdout: &Arc<Mutex<io::Stdout>>, line: &str, message: &str) {
    let Some(id) = request_id(line) else { return };
    let msg = message.replace('\\', "\\\\").replace('"', "'");
    let frame = format!(
        "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32603,\"message\":\"{msg}\"}}}}"
    );
    write_frame(stdout, frame.as_bytes());
}

/// Forward one frame and write the response (or a synthesized, id-echoing
/// error) to stdout. Never exits the proxy; stdout write failures are logged
/// and dropped.
///
/// Guard: if this proxy ever gains an `Mcp-Session-Id` header, session
/// recovery (clear + re-initialize + one-shot retry) must be added at the
/// same time — a server restart without recovery becomes a permanent outage
/// for the session.
fn forward_frame(port: u16, line: &str, stdout: &Arc<Mutex<io::Stdout>>) {
    match daemon_client::post_frame(port, line.as_bytes()) {
        // Notification acknowledged; per MCP spec there is no reply.
        Ok((202, _)) => {}

        // Any other empty body is a failure, not a notification — a daemon
        // mid-restart (status 0: post_frame parses an unparseable status line
        // as 0), a 500/503, or a request rejected before the handler. Reply
        // with an id-echoing error so the client unblocks; silence hangs it
        // forever with no visible error.
        Ok((status, body)) if body.is_empty() => {
            respond_error(stdout, line, &format!("proxy: empty response (HTTP {status})"));
        }

        // Non-2xx: do NOT relay the body. It may not be a JSON-RPC envelope
        // (HTML error page, plain text), and a malformed frame poisons the
        // stream for every later request.
        Ok((status, _)) if !(200..300).contains(&status) => {
            respond_error(stdout, line, &format!("proxy: HTTP {status}"));
        }

        Ok((_, body)) => write_frame(stdout, &body),

        Err(e) => {
            eprintln!("mootx01 proxy: daemon request failed: {e}");
            respond_error(stdout, line, &format!("proxy: {e}"));
        }
    }
}

fn write_frame(stdout: &Arc<Mutex<io::Stdout>>, body: &[u8]) {
    let mut out = match stdout.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(), // a poisoned stdout mutex is still writable
    };
    if out.write_all(body).and_then(|_| out.write_all(b"\n")).is_err() {
        eprintln!("mootx01 proxy: stdout write failed (client hung up)");
        return;
    }
    let _ = out.flush();
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
    }
}
