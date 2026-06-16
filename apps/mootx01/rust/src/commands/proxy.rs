//! commands/proxy.rs — §4.7: stdio→HTTP bridge for clients that require a
//! stdio command entry (Claude Desktop).
//!
//! Reads newline-delimited JSON-RPC frames from stdin, POSTs each to the
//! resident daemon over loopback HTTP, and writes the response frame to
//! stdout. Notifications (202, empty body) produce no output, matching the
//! MCP stdio convention. Logging goes to stderr; stdout carries frames only.

use std::io::{self, BufRead, Write};
use std::process::ExitCode;

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

    if !daemon_client::alive(port) {
        eprintln!(
            "mootx01 proxy: no resident daemon answering on 127.0.0.1:{port}. \
             Start it with `mootx01 serve --http auto` (or check `mootx01 status`)."
        );
        return ExitCode::from(exit::FAILURE);
    }
    eprintln!("mootx01 proxy: bridging stdio ↔ http://127.0.0.1:{port}");

    let stdin = io::stdin();
    let stdout = io::stdout();
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
        match daemon_client::post_frame(port, line.as_bytes()) {
            Ok((202, _)) => {} // notification: no response frame
            Ok((_, body)) if body.is_empty() => {}
            Ok((_, body)) => {
                let mut out = stdout.lock();
                if out.write_all(&body).and_then(|_| out.write_all(b"\n")).is_err() {
                    return ExitCode::from(exit::FAILURE); // client hung up
                }
                let _ = out.flush();
            }
            Err(e) => {
                eprintln!("mootx01 proxy: daemon request failed: {e}");
                return ExitCode::from(exit::FAILURE);
            }
        }
    }
    eprintln!("mootx01 proxy: stdin closed, exiting");
    ExitCode::from(exit::OK)
}
