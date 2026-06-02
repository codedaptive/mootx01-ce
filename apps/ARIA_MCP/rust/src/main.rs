//! `aria-mcp` binary entry point.
//!
//! Reads `ARIA_MCP_SQLITE_PATH` from the environment to select the storage
//! backend, then runs the newline-delimited JSON stdio loop until stdin
//! closes. All logging goes to stderr; stdout is reserved for JSON-RPC
//! frames.
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
//! Set `ARIA_MCP_SQLITE_PATH` to a writable filesystem path to enable
//! durable storage. Absent or empty → in-memory estate (ephemeral, default
//! behavior). See `server::ServerConfig::from_env` for the full behavior
//! table.

use aria_mcp::server::{run_stdio_loop, ServerConfig};

fn main() {
    eprintln!("aria-mcp: starting Rust MCP server");
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    // from_env reads ARIA_MCP_SQLITE_PATH: present+non-empty → SQLite-backed
    // estate, absent/empty → in-memory. Exits with nonzero code if the path
    // is set but cannot be opened.
    let config = ServerConfig::from_env();
    run_stdio_loop(stdin.lock(), &mut stdout, config);
    eprintln!("aria-mcp: stdin closed, exiting");
}
