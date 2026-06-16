//! main.rs — moot-bridge (Rust twin) CLI entry point.
//!
//!   moot-bridge --config <c.json>
//!
//! The AI client launches `moot-bridge --config c.json` as its memory MCP server.
//! Hand-rolled arg parsing (no clap) to hold the minimal-dependency line. stdout
//! is the client's JSON-RPC channel — NOTHING but JSON-RPC responses goes there;
//! all diagnostics + stats go to stderr.
//!
//! Stats note: the Rust twin tracks the same per-backend latency + secondary-
//! failure stats as the Swift twin and writes them to stderr on shutdown and via
//! `bridge_status`. The Swift twin additionally emits into the ObserverSink stats
//! store (an in-repo Swift library); the Rust vertical has no FFI into that Swift
//! store, so its stats surface is the stderr/bridge_status path. The in-process
//! statistics themselves are identical between the two verticals.

use moot_bridge::config::BridgeConfig;
use std::io::{self, BufReader};

const USAGE: &str = "\
moot-bridge — a bridging MCP memory server (Rust twin).

USAGE:
  moot-bridge --config <c.json>

The AI client launches this as its single memory MCP server. Every WRITE is
fanned out to BOTH configured backends; every READ is served from the current
PRIMARY. The AI flips the primary mid-session with the bridge_set_primary tool;
bridge_status reports the current primary and per-backend stats.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.is_empty() || args.iter().any(|a| a == "--help" || a == "-h") {
        eprint!("{USAGE}");
        std::process::exit(if args.is_empty() { 1 } else { 0 });
    }

    let config_path = match option_value(&args, "--config") {
        Some(p) => p,
        None => {
            eprintln!("moot-bridge error: missing required option --config");
            std::process::exit(1);
        }
    };

    let config = match BridgeConfig::load(config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("moot-bridge error: {e}");
            std::process::exit(1);
        }
    };

    let stdin = io::stdin();
    let stdout = io::stdout();
    let stderr = io::stderr();
    let result = moot_bridge::run_bridge(
        &config,
        BufReader::new(stdin.lock()),
        stdout.lock(),
        stderr.lock(),
    );
    if let Err(e) = result {
        eprintln!("moot-bridge error: {e}");
        std::process::exit(1);
    }
}

/// Returns the value following `--name`, or None if absent / no value follows.
fn option_value<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    let i = args.iter().position(|a| a == name)?;
    args.get(i + 1).map(|s| s.as_str())
}
