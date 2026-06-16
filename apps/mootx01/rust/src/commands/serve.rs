//! commands/serve.rs — §4.1: host the ARIA MCP server.
//!
//! Thin translation of spec flags onto the aria-mcp runtime's environment
//! contract, then a single call into `aria_mcp::runtime::run` — the same
//! function the `aria-mcp` dev binary calls, so both entry points run
//! identical resident-daemon logic.
//!
//! Flag → env translation:
//!   --db <name>   → ARIA_MCP_SQLITE_PATH = <data>/databases/<name>/estate.sqlite
//!                   (skipped when the caller already set ARIA_MCP_POSTGRES_URL
//!                   or ARIA_MCP_SQLITE_PATH — explicit env wins, and setting
//!                   both would trip from_env's ambiguity exit)
//!   --http auto   → hunt 4242 upward to the first free port (§3)
//!   --http <port> → exact; busy means exit 1, never hunt (§3)
//!   (neither)     → MOOTX01_HTTP_PORT env if the caller set it, else stdio
//!
//! Whatever port the daemon binds is written to `<data>/daemon.port` and
//! best-effort removed when the runtime returns (§3).

use std::net::TcpListener;
use std::path::Path;
use std::process::ExitCode;

use crate::cli::HttpMode;
use crate::core::paths;
use crate::exit;

/// How many ports above 4242 `auto` will probe before giving up.
const HUNT_RANGE: u16 = 100;
/// §3 default daemon port.
const DEFAULT_PORT: u16 = 4242;

pub fn run(db: Option<String>, http: Option<HttpMode>) -> ExitCode {
    let data = paths::data_dir();

    // Estate selection. Explicit backend env vars win over --db; otherwise
    // resolve the named (or active) estate to a SQLite path.
    let postgres_set = env_nonempty("ARIA_MCP_POSTGRES_URL");
    let sqlite_set = env_nonempty("ARIA_MCP_SQLITE_PATH");
    if !postgres_set && !sqlite_set {
        let name = db.unwrap_or_else(|| paths::active_estate(&data));
        let estate = paths::estate_sqlite_path(&data, &name);
        if let Some(dir) = estate.parent() {
            if let Err(e) = std::fs::create_dir_all(dir) {
                eprintln!("mootx01: cannot create estate directory {}: {e}", dir.display());
                return ExitCode::from(exit::FAILURE);
            }
        }
        std::env::set_var("ARIA_MCP_SQLITE_PATH", &estate);
        eprintln!("mootx01: estate '{name}' at {}", estate.display());
    } else if db.is_some() {
        eprintln!(
            "mootx01: --db ignored (ARIA_MCP_POSTGRES_URL / ARIA_MCP_SQLITE_PATH set explicitly)"
        );
    }

    // Transport selection + port hunting (§3).
    let bound_port: Option<u16> = match http {
        Some(HttpMode::Port(p)) => {
            // Explicit means exact: fail if busy, never hunt.
            if !port_free(p) {
                eprintln!(
                    "mootx01: port {p} is in use and was requested explicitly; \
                     not hunting. Free the port or use --http auto."
                );
                return ExitCode::from(exit::FAILURE);
            }
            std::env::set_var("MOOTX01_HTTP_PORT", p.to_string());
            Some(p)
        }
        Some(HttpMode::Auto) => match hunt(DEFAULT_PORT, HUNT_RANGE) {
            Some(p) => {
                if p != DEFAULT_PORT {
                    eprintln!("mootx01: port {DEFAULT_PORT} busy; hunted to {p}");
                }
                std::env::set_var("MOOTX01_HTTP_PORT", p.to_string());
                Some(p)
            }
            None => {
                eprintln!(
                    "mootx01: no free port in {DEFAULT_PORT}–{}",
                    DEFAULT_PORT + HUNT_RANGE
                );
                return ExitCode::from(exit::FAILURE);
            }
        },
        None => {
            // Env-driven daemon mode (service units may set MOOTX01_HTTP_PORT
            // directly). Explicit env is exact per §3 — validate it parses;
            // the runtime enforces bind failure as exit 1.
            match std::env::var("MOOTX01_HTTP_PORT") {
                Ok(v) if !v.is_empty() => match v.parse::<u16>() {
                    Ok(p) => Some(p),
                    Err(_) => {
                        eprintln!(
                            "mootx01: MOOTX01_HTTP_PORT={v:?} is not a valid TCP port (0–65535)"
                        );
                        return ExitCode::from(exit::FAILURE);
                    }
                },
                _ => None, // stdio
            }
        }
    };

    // §3: whatever port the daemon binds is written to daemon.port and
    // removed on clean shutdown. The resident daemon also writes mootx01.pid
    // (status reports it) and enforces the single-writer rule: one resident
    // BrainPump per estate (ADR-LOOPBACKHTTP-001). Liveness is the recorded
    // port answering on loopback — portable where kill(pid, 0) is not.
    // stdio serves are ephemeral, do not pump, and are not guarded or filed.
    let port_file = paths::daemon_port_file(&data);
    let pid_file = data.join("mootx01.pid");
    if let Some(p) = bound_port {
        if let Some(prev) = paths::read_port_file(&port_file) {
            if prev != p && !port_free(prev) {
                eprintln!(
                    "mootx01: estate is already served by a live resident daemon \
                     on port {prev}. One resident writer per estate \u{2014} stop it first."
                );
                return ExitCode::from(exit::FAILURE);
            }
        }
        if let Err(e) = paths::write_port_file(&port_file, p) {
            eprintln!(
                "mootx01: cannot write port file {}: {e} (continuing)",
                port_file.display()
            );
        }
        let _ = std::fs::write(&pid_file, format!("{}\n", std::process::id()));
    }

    // Host the runtime. Does not return until the transport stops.
    aria_mcp::runtime::run("mootx01");

    if bound_port.is_some() {
        remove_port_file(&port_file);
        let _ = std::fs::remove_file(&pid_file);
    }
    ExitCode::from(exit::OK)
}

fn env_nonempty(key: &str) -> bool {
    std::env::var(key).map(|v| !v.is_empty()).unwrap_or(false)
}

/// Probe-bind on loopback; free means we could bind. Racy by nature (the
/// port can be taken between probe and the runtime's real bind), in which
/// case the runtime's bind failure path exits 1 — acceptable for v1.
fn port_free(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// First free port in [start, start+range], or None.
fn hunt(start: u16, range: u16) -> Option<u16> {
    (start..=start.saturating_add(range)).find(|&p| port_free(p))
}

fn remove_port_file(path: &Path) {
    let _ = std::fs::remove_file(path);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hunt_skips_a_busy_port() {
        // Occupy a port, then hunt starting at it: hunt must return a
        // different (higher) free port.
        let holder = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let busy = holder.local_addr().unwrap().port();
        let found = hunt(busy, 10).expect("a free port within 10 of any port");
        assert_ne!(found, busy);
        assert!(found > busy);
    }

    #[test]
    fn port_free_reflects_occupancy() {
        let holder = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let busy = holder.local_addr().unwrap().port();
        assert!(!port_free(busy));
        drop(holder);
        assert!(port_free(busy));
    }
}
