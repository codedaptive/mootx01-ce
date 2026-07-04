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
//! Failure policy: a failed REQUEST gets a synthesized JSON-RPC error that
//! echoes the request's id (Desktop's MCP client rejects `id: null` frames at
//! the schema level — an id-less error poisons the whole stream). A failed
//! NOTIFICATION gets nothing (servers must not reply to notifications). The
//! proxy itself only exits on stdin EOF or a stdin read error — never because
//! one call failed.

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
        // Reap finished workers so the vec doesn't grow unboundedly over a
        // long session.
        workers.retain(|h| !h.is_finished());
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

/// Forward one frame and write the response (or a synthesized, id-echoing
/// error) to stdout. Never exits the proxy; stdout write failures are logged
/// and dropped.
fn forward_frame(port: u16, line: &str, stdout: &Arc<Mutex<io::Stdout>>) {
    match daemon_client::post_frame(port, line.as_bytes()) {
        Ok((202, _)) => {} // notification: no response frame
        Ok((_, body)) if body.is_empty() => {}
        Ok((_, body)) => write_frame(stdout, &body),
        Err(e) => {
            eprintln!("mootx01 proxy: daemon request failed: {e}");
            // Requests get an error echoing their id; notifications get none.
            if let Some(id) = request_id(line) {
                let msg = e.to_string().replace('\\', "\\\\").replace('"', "'");
                let frame = format!(
                    "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32603,\"message\":\"proxy: {msg}\"}}}}"
                );
                write_frame(stdout, frame.as_bytes());
            }
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
