//! `aria-mcp` binary entry point.
//!
//! Reads `ARIA_MCP_POSTGRES_URL` and `ARIA_MCP_SQLITE_PATH` from the
//! environment to select the storage backend, then runs the newline-delimited
//! JSON stdio loop until stdin closes. All logging goes to stderr; stdout is
//! reserved for JSON-RPC frames.
//!
//! # Running
//!
//! ```sh
//! cargo run --manifest-path apps/ARIA_MCP/rust/Cargo.toml
//! ```
//!
//! # Wire contract
//!
//! Newline-delimited JSON, one JSON-RPC 2.0 object per line. Compatible
//! with every MCP host that speaks the de-facto stdio convention (Claude
//! Desktop, Claude Code, MemPalace's own MCP server).
//!
//! # Persistence
//!
//! Two env vars drive backend selection; see `server::ServerConfig::from_env`
//! for the full four-state precedence table. Short form:
//!   Both set → exit 1 (ambiguous).
//!   ARIA_MCP_POSTGRES_URL only → PostgreSQL (pooled durable estate, libpq URL).
//!   ARIA_MCP_SQLITE_PATH only → SQLite at that path (durable, WAL-mode).
//!   Neither set → in-memory estate (ephemeral, default behavior).
//!
//! # Brain pump (resident HTTP branch only)
//!
//! When the HTTP transport is selected (`MOOTX01_HTTP_PORT` is set), the
//! resident Brain pump (`brain_pump::BrainPump`) is started on a background
//! thread alongside `run_http_loop`. The pump drives dreaming + maintenance on
//! their own cadences (NeuronKit); `run_http_loop` drives the MCP transport.
//! Both run for the lifetime of the resident process.
//!
//! ARIA_MCP_SPEC §17.1 mandates that the resident daemon owns the Brain. The
//! stdio branch does NOT start the pump — stdio mode is for testing, migrations,
//! and one-shot use, not the resident daemon role.

use std::sync::Arc;

use aria_mcp::brain_pump::BrainPump;
use aria_mcp::http_server::run_http_loop;
use aria_mcp::server::{run_stdio_loop, ServerConfig};

fn main() {
    eprintln!("aria-mcp: starting Rust MCP server");
    // from_env reads ARIA_MCP_POSTGRES_URL and ARIA_MCP_SQLITE_PATH and applies
    // the four-state precedence ladder. Exits with a nonzero code on ambiguous
    // config or an unusable path/URL (unreachable PostgreSQL fails fast here).
    let config = ServerConfig::from_env();

    // Transport select. stdio is the default (testing, migrations, PoC). When
    // MOOTX01_HTTP_PORT is set, run the resident loopback HTTP MCP transport —
    // the v1 primary transport for the resident daemon. Both drive the same
    // dispatcher; the JSON-RPC surface is identical.
    let http_port = std::env::var("MOOTX01_HTTP_PORT").unwrap_or_default();
    if !http_port.is_empty() {
        let port: u16 = match http_port.parse() {
            Ok(p) => p,
            Err(_) => {
                eprintln!("aria-mcp: MOOTX01_HTTP_PORT={http_port:?} is not a valid TCP port (0–65535)");
                std::process::exit(1);
            }
        };
        let max_body = parse_max_body_bytes();

        // Wire the pump to the live default estate so it reads from and writes
        // to the same estate the HTTP tool-calls operate on. The pump and the
        // HTTP transport share the same Arc<Mutex<EstateCoordinator>> — the
        // Mutex serializes all coordinator access between the two threads.
        //
        // Clone the Arc pointers before moving `config` into `run_http_loop`.
        // Both the pump thread and `run_http_loop` then hold independent Arc
        // clones of the same underlying coordinator and store.
        let pump_coord = Arc::clone(&config.registry.coord);
        let pump_handle = config.registry.default.handle;
        let pump_store = Arc::clone(&config.registry.default.store);

        // Start the resident Brain pump on a background thread. The pump drives
        // dreaming + maintenance on their own cadences alongside the HTTP
        // transport. Per ARIA_MCP_SPEC §17.1: the resident daemon is the entity
        // that triggers its own Brain; moot-mgr is the GUI control surface, not
        // the Brain driver.
        //
        // The pump thread runs until the process exits; no join is needed because
        // the main thread (run_http_loop) is the process-lifetime anchor. If the
        // HTTP loop exits (bind failure), the process exits and the pump thread is
        // torn down automatically.
        // Spawn and detach: dropping the JoinHandle here detaches the thread,
        // which keeps running for the process lifetime. run_http_loop below is the
        // lifetime anchor and does not return on success; on bind failure the
        // process exits and the OS reaps the pump thread. No join is needed.
        std::thread::spawn(move || {
            let mut pump = BrainPump::new(pump_coord, pump_handle, pump_store);
            pump.run_loop();
        });

        if let Err(e) = run_http_loop(port, max_body, config) {
            eprintln!("aria-mcp: cannot bind HTTP transport on 127.0.0.1:{port}: {e}");
            std::process::exit(1);
        }
        eprintln!("aria-mcp: HTTP transport stopped, exiting");
    } else {
        let stdin = std::io::stdin();
        let stdout = std::io::stdout();
        let mut stdout = stdout.lock();
        run_stdio_loop(stdin.lock(), &mut stdout, config);
        eprintln!("aria-mcp: stdin closed, exiting");
    }
}

/// Resolve the HTTP request body cap from `MOOTX01_HTTP_MAX_BODY_BYTES`,
/// defaulting to 4 MiB. MCP `tools/call` bodies can exceed LoopbackHTTP's 64 KiB
/// default, which would silently truncate. An invalid value falls back to the
/// default with a stderr note.
fn parse_max_body_bytes() -> usize {
    let raw = std::env::var("MOOTX01_HTTP_MAX_BODY_BYTES").unwrap_or_default();
    if raw.is_empty() {
        return 4 * 1024 * 1024;
    }
    match raw.parse::<usize>() {
        Ok(v) if v > 0 => v,
        _ => {
            eprintln!("aria-mcp: MOOTX01_HTTP_MAX_BODY_BYTES={raw:?} invalid; using 4 MiB default");
            4 * 1024 * 1024
        }
    }
}
