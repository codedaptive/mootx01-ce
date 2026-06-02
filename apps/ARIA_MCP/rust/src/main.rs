//! `aria-mcp` binary entry point.
//!
//! Starts one in-memory estate (the v1 default) and runs the
//! newline-delimited JSON stdio loop until stdin closes. All logging goes
//! to stderr; stdout is reserved for JSON-RPC frames.
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

use aria_mcp::server::{run_stdio_loop, ServerConfig};

fn main() {
    eprintln!("aria-mcp: starting Rust MCP server (v1 in-memory)");
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    let config = ServerConfig::default_inmemory();
    run_stdio_loop(stdin.lock(), &mut stdout, config);
    eprintln!("aria-mcp: stdin closed, exiting");
}
