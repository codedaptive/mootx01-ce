//! moot-bridge (Rust twin) — a bridging MCP memory server.
//!
//! An AI client launches this as its single memory MCP server; every WRITE fans
//! out to BOTH configured backends (e.g. MemPalace AND mootx01), every READ is
//! served from the current PRIMARY, and the AI flips the primary mid-session via
//! the `bridge_set_primary` tool. Wire-contract peer of the Swift `moot-bridge`; the
//! internal architecture is idiomatic Rust. Per the no-FFI law this crate is a
//! COMPLETE Rust vertical — it never calls Swift, Swift never calls it.
//!
//! The library exposes the testable pieces (config, stats, classify/translate,
//! the run driver); `main.rs` wires stdin/stdout and the backend processes.

pub mod backend;
pub mod config;
pub mod bridge;
pub mod stats;

use backend::RawMcpBackend;
use config::BridgeConfig;
use bridge::{BridgeBackend, BridgeServer};
use std::io::{BufRead, Write};

/// Errors raised while running the bridge.
#[derive(Debug)]
pub struct BridgeError(pub String);

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for BridgeError {}

/// The MCP `initialize` request the bridge sends to a backend at startup so the
/// first real tools/call is not rejected for a missing handshake. id 0 lives on
/// the backend's own (disjoint) id space.
fn backend_initialize_message() -> String {
    serde_json::json!({
        "jsonrpc": "2.0", "id": 0, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "moot-bridge", "version": "0.1.0" }
        }
    })
    .to_string()
}

/// Starts a backend transport and performs its initialize handshake.
fn start_backend(name: &str, command: &str, verb_map: config::VerbMap) -> Result<BridgeBackend, BridgeError> {
    let mut transport =
        RawMcpBackend::start(name, command).map_err(|e| BridgeError(e.to_string()))?;
    // Handshake so the first real tools/call lands on an initialized server.
    let _ = transport.send_and_receive(&backend_initialize_message());
    Ok(BridgeBackend {
        transport,
        name: name.to_string(),
        verb_map,
    })
}

/// Runs the bridge against the given reader (client requests) and writer (client
/// responses). Loads + handshakes both backends, drives the loop until the
/// reader hits EOF, then writes the final stats block to `diagnostics` (stderr).
///
/// Split out from `main` so tests can drive it with in-memory pipes / a scripted
/// client, exactly as the Swift acceptance test drives the binary over stdio.
pub fn run_bridge<R: BufRead, W: Write, D: Write>(
    config: &BridgeConfig,
    mut client_in: R,
    mut client_out: W,
    mut diagnostics: D,
) -> Result<(), BridgeError> {
    let backend_a = start_backend(&config.backend_a.name, &config.backend_a.command,
                                  config.backend_a.verb_map.clone())?;
    let backend_b = start_backend(&config.backend_b.name, &config.backend_b.command,
                                  config.backend_b.verb_map.clone())?;
    let primary_index = if config.primary == config.backend_a.name { 0 } else { 1 };
    let mut server = BridgeServer::new(vec![backend_a, backend_b], primary_index);

    let _ = writeln!(
        diagnostics,
        "[bridge] ready: backends [{}, {}], primary={}",
        config.backend_a.name, config.backend_b.name, config.primary
    );

    // Run until the client closes stdin.
    let mut line = String::new();
    loop {
        line.clear();
        let n = client_in
            .read_line(&mut line)
            .map_err(|e| BridgeError(format!("read client: {e}")))?;
        if n == 0 {
            break; // EOF → shut down
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            continue;
        }
        if let Some(response) = server.handle_message(trimmed) {
            client_out
                .write_all(response.as_bytes())
                .and_then(|_| client_out.write_all(b"\n"))
                .and_then(|_| client_out.flush())
                .map_err(|e| BridgeError(format!("write client: {e}")))?;
        }
    }

    // Final stats + teardown.
    let (snapshot, mut backends) = server.into_parts();
    let _ = write!(diagnostics, "{}", snapshot.rendered("[bridge] final stats"));
    for b in backends.iter_mut() {
        b.transport.stop();
    }
    Ok(())
}
