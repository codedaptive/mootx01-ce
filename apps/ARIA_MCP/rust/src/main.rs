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

use aria_mcp::server::{run_stdio_loop, ServerConfig};

fn main() {
    eprintln!("aria-mcp: starting Rust MCP server");
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    // from_env reads ARIA_MCP_POSTGRES_URL and ARIA_MCP_SQLITE_PATH and applies
    // the four-state precedence ladder. Exits with a nonzero code on ambiguous
    // config or an unusable path/URL (unreachable PostgreSQL fails fast here).
    let config = ServerConfig::from_env();
    run_stdio_loop(stdin.lock(), &mut stdout, config);
    eprintln!("aria-mcp: stdin closed, exiting");
}
