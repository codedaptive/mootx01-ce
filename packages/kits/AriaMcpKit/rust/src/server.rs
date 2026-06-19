//! Stdio framing and the main server loop — Rust version.
//!
//! Mirrors the Swift `StdioServer` and `ARIA_MCPDispatcher` wire behavior:
//! newline-delimited JSON, one object per line, no Content-Length header,
//! no embedded newlines. Reads from any `BufRead`, writes to any `Write`,
//! so the loop is testable with in-memory `Cursor<Vec<u8>>` readers.
//!
//! # Framing protocol
//!
//! Per the de-facto MCP stdio convention the Swift server documents:
//! each frame is one compact JSON object followed by a single newline
//! (0x0A). The server reads lines, parses each as a JSON-RPC request,
//! dispatches it, and writes the response (if any) with a trailing newline.
//! stdout is reserved for JSON-RPC frames; diagnostics go to stderr.
//!
//! # ServerConfig
//!
//! Two constructors select the backend at startup:
//! - `from_env()` — reads `ARIA_MCP_POSTGRES_URL` and `ARIA_MCP_SQLITE_PATH`
//!   from the environment and applies a four-state precedence ladder (no
//!   trimming on either var — whitespace-only values are treated as non-empty):
//!
//!   | ARIA_MCP_POSTGRES_URL | ARIA_MCP_SQLITE_PATH | Backend           |
//!   |-----------------------|----------------------|-------------------|
//!   | Non-empty             | Non-empty            | Ambiguous → exit 1|
//!   | Non-empty             | Absent or empty      | PostgreSQL estate |
//!   | Absent or empty       | Non-empty            | SQLite at path    |
//!   | Absent or empty       | Absent or empty      | In-memory (default)|
//!
//!   `from_env()` is the production entry point; `main.rs` calls it.
//! - `default_inmemory()` — unconditionally in-memory; preserved for tests.
//!
//! Wire surface (tools, schemas, JSON-RPC methods) is unchanged regardless
//! of which backend is selected. Persistence is server-internal only.

use std::io::{BufRead, BufReader, Read, Write};

use crate::dispatcher::Dispatcher;
use crate::estate_registry::EstateRegistry;

/// Configuration for a server run. Carries the estate registry the
/// dispatcher will route tool calls against.
///
/// Build via `from_env()` for production (env-var-selected backend) or
/// `default_inmemory()` for tests (unconditionally in-memory).
pub struct ServerConfig {
    pub registry: EstateRegistry,
    pub server_name: String,
    pub server_version: String,
    /// Build serial surfaced by `moot_estate_ping`. Computed once at
    /// construction via `crate::build_serial::derive()` so the filesystem
    /// is not touched on every ping call.
    pub build_serial: String,
}

impl ServerConfig {
    /// Construct a server config from environment variables.
    ///
    /// Reads `ARIA_MCP_POSTGRES_URL` and `ARIA_MCP_SQLITE_PATH` and applies
    /// a four-state precedence ladder. No trimming on either var — a
    /// whitespace-only value is treated as non-empty (a config error that
    /// fails fast, not a silent fallback). Matches the Swift server's
    /// no-trimming semantics exactly.
    ///
    /// Precedence table:
    /// | ARIA_MCP_POSTGRES_URL | ARIA_MCP_SQLITE_PATH | Backend                   |
    /// |-----------------------|----------------------|---------------------------|
    /// | Non-empty             | Non-empty            | Ambiguous → exit 1        |
    /// | Non-empty             | Absent or empty      | PostgreSQL estate         |
    /// | Absent or empty       | Non-empty            | SQLite at path            |
    /// | Absent or empty       | Absent or empty      | In-memory (default)       |
    ///
    /// Wire surface (tools, schemas, JSON-RPC) is unchanged for all backends.
    pub fn from_env() -> Self {
        // No .filter(|s| !s.is_empty()) — whitespace-only is non-empty here.
        // None means the env var is absent; Some("") means it was set to empty.
        // Both None and Some("") fall through to the absent/empty branch below.
        let postgres_url = std::env::var("ARIA_MCP_POSTGRES_URL").unwrap_or_default();
        let sqlite_path_raw = std::env::var("ARIA_MCP_SQLITE_PATH").unwrap_or_default();

        let registry = if !postgres_url.is_empty() && !sqlite_path_raw.is_empty() {
            // Ambiguous config: both vars set. Never pick silently — the
            // operator must resolve the ambiguity by unsetting one of them.
            // Mirrors Swift's AriaMCPMain ambiguous-config branch exactly.
            eprintln!(
                "aria-mcp: ambiguous config — both ARIA_MCP_POSTGRES_URL and \
                 ARIA_MCP_SQLITE_PATH are set. Unset one to select the intended backend."
            );
            std::process::exit(1);
        } else if !postgres_url.is_empty() {
            // Only ARIA_MCP_POSTGRES_URL set → PostgreSQL-backed estate.
            // PostgresDrawerStore::from_connection_string is lazy — the pool
            // acquires connections on first use, not here. Construction
            // succeeds even when the database is temporarily unreachable;
            // the first tool call that touches the estate surfaces any
            // connection error. Matches Swift's AriaMCPMain postgres branch.
            // Redact userinfo before logging — the URL may contain
            // user:password@host, which would leak credentials to stderr / log
            // aggregators. Log host only, matching the Swift side
            // (URL(string:)?.host ?? "configured").
            eprintln!("aria-mcp: opening PostgreSQL estate at {}", redact_postgres_url(&postgres_url));
            match EstateRegistry::new_postgres(&postgres_url, "aria-mcp-default") {
                Ok(reg) => {
                    eprintln!("aria-mcp: PostgreSQL estate ready");
                    reg
                }
                Err(e) => {
                    // Scrub any verbatim occurrence of the connection string from
                    // the error before logging, so credentials never reach stderr
                    // (parity with the Swift fatal-path redaction).
                    eprintln!("{}", format!("{e}").replace(&postgres_url, "[REDACTED]"));
                    std::process::exit(1);
                }
            }
        } else if !sqlite_path_raw.is_empty() {
            // Only ARIA_MCP_SQLITE_PATH set → SQLite-backed estate.
            let path = sqlite_path_raw;
            // Create parent directories if they do not exist. Missing parents
            // are a common operator error (the path is new or the mount is
            // stale); failing fast here with a clear message is better than
            // a cryptic SQLite "unable to open database" error.
            if let Some(parent) = std::path::Path::new(&path).parent() {
                if !parent.as_os_str().is_empty() {
                    if let Err(e) = std::fs::create_dir_all(parent) {
                        eprintln!("aria-mcp: cannot create parent directories for {path:?}: {e}");
                        std::process::exit(1);
                    }
                }
            }
            eprintln!("aria-mcp: opening SQLite estate at {path:?}");
            match EstateRegistry::new_sqlite(&path, "aria-mcp-default") {
                Ok(reg) => {
                    eprintln!("aria-mcp: SQLite estate ready at {path:?}");
                    reg
                }
                Err(e) => {
                    eprintln!("{e}");
                    std::process::exit(1);
                }
            }
        } else {
            // Neither set → in-memory ephemeral estate (v1.0 default).
            eprintln!(
                "aria-mcp: neither ARIA_MCP_POSTGRES_URL nor ARIA_MCP_SQLITE_PATH \
                       set — using in-memory estate"
            );
            EstateRegistry::new_inmemory()
        };

        ServerConfig {
            registry,
            server_name: "ARIA_MCP_Rust".to_owned(),
            server_version: "0.1.0".to_owned(),
            // Derive build serial once at config construction so the
            // filesystem is not touched on every estate_ping call.
            build_serial: crate::build_serial::derive(),
        }
    }

    /// Construct the default in-memory server: one in-memory estate as the
    /// default, no persistent storage. Preserved for tests that need a
    /// predictable in-memory estate regardless of the environment.
    pub fn default_inmemory() -> Self {
        ServerConfig {
            registry: EstateRegistry::new_inmemory(),
            server_name: "ARIA_MCP_Rust".to_owned(),
            server_version: "0.1.0".to_owned(),
            // Derive build serial once at config construction so the
            // filesystem is not touched on every estate_ping call.
            build_serial: crate::build_serial::derive(),
        }
    }
}

/// Run the newline-delimited JSON stdio loop until `reader` returns EOF.
///
/// Reads bytes from `reader`, splits on newline, parses each line as JSON,
/// dispatches, and writes responses to `writer` one line each. Malformed
/// lines emit a parseError response with a null id, matching the Swift
/// server's behavior, so a client can recover by sending the next
/// well-formed request without restarting the server.
pub fn run_stdio_loop<R: Read, W: Write>(reader: R, writer: &mut W, config: ServerConfig) {
    let dispatcher = Dispatcher::new(
        config.registry,
        &config.server_name,
        &config.server_version,
        &config.build_serial,
    );
    let mut buf = BufReader::new(reader);
    let mut line = String::new();

    loop {
        line.clear();
        match buf.read_line(&mut line) {
            Ok(0) => break, // EOF
            Ok(_) => {}
            Err(e) => {
                eprintln!("aria-mcp: read error: {e}");
                break;
            }
        }
        let trimmed = line.trim_end_matches('\n').trim_end_matches('\r');
        if trimmed.is_empty() {
            continue;
        }
        handle_frame(trimmed.as_bytes(), writer, &dispatcher);
    }
}

/// Parse one frame, dispatch, write the response (if any).
///
/// Mirrors Swift `StdioServer.handleFrame(_:output:)`:
///  - JSON parse failure → parseError with null id
///  - RPC decode failure → invalidRequest with null id
///  - Notification → no response (silent per JSON-RPC 2.0)
///  - Request → dispatch and write result
fn handle_frame<W: Write>(frame: &[u8], writer: &mut W, dispatcher: &Dispatcher) {
    use crate::jsonrpc::{
        JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JSONRPCResponse, JsonValue,
    };

    // 1. Parse JSON.
    let parsed: serde_json::Value = match serde_json::from_slice(frame) {
        Ok(v) => v,
        Err(e) => {
            let resp = JSONRPCResponse::failure(
                JsonValue::Null,
                JSONRPCError::new(JSONRPCErrorCode::PARSE_ERROR, format!("Parse error: {e}")),
            );
            write_response(&resp, writer);
            return;
        }
    };

    // 2. Decode JSON-RPC envelope.
    let request = match JSONRPCRequest::decode(&parsed) {
        Some(r) => r,
        None => {
            let resp = JSONRPCResponse::failure(
                JsonValue::Null,
                JSONRPCError::new(
                    JSONRPCErrorCode::INVALID_REQUEST,
                    "Invalid Request: malformed JSON-RPC envelope",
                ),
            );
            write_response(&resp, writer);
            return;
        }
    };

    // 3. Notifications: run side-effect (none today) and return silently.
    if request.is_notification() {
        eprintln!("aria-mcp: notification: {}", request.method);
        return;
    }

    // 4. Dispatch and write response.
    let response = dispatcher.handle(&request);
    write_response(&response, writer);
}

/// Serialize `response` and write it to `writer` with a trailing newline.
/// Serialization errors are logged to stderr; we cannot recover them onto
/// the wire because we no longer have a valid response to send.
fn write_response<W: Write>(response: &crate::jsonrpc::JSONRPCResponse, writer: &mut W) {
    match serde_json::to_vec(response) {
        Ok(mut bytes) => {
            bytes.push(b'\n');
            if let Err(e) = writer.write_all(&bytes) {
                eprintln!("aria-mcp: write error: {e}");
            }
        }
        Err(e) => {
            eprintln!("aria-mcp: serialization error: {e}");
        }
    }
}

/// Reduce a PostgreSQL connection string to its host for safe logging, dropping
/// any `user:password@` userinfo. Returns `"configured"` when no host can be
/// extracted. Mirrors the Swift side's `URL(string:)?.host ?? "configured"`.
pub fn redact_postgres_url(url: &str) -> String {
    // scheme://[user[:pass]@]host[:port][/db][?params]
    let after_scheme = url.split("://").nth(1).unwrap_or("");
    let authority = after_scheme.split('/').next().unwrap_or("");
    // Drop userinfo: keep everything after the last '@'.
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    // Drop the port.
    let host = host_port.split(':').next().unwrap_or(host_port);
    if host.is_empty() {
        "configured".to_owned()
    } else {
        host.to_owned()
    }
}

#[cfg(test)]
mod redact_tests {
    use super::redact_postgres_url;

    #[test]
    fn strips_userinfo_and_port() {
        assert_eq!(
            redact_postgres_url("postgres://user:secret@db.example.com:5432/estate"),
            "db.example.com"
        );
    }

    #[test]
    fn host_only_url_passes_through() {
        assert_eq!(redact_postgres_url("postgres://db.example.com/estate"), "db.example.com");
    }

    #[test]
    fn unparseable_returns_configured() {
        assert_eq!(redact_postgres_url("not a url"), "configured");
    }
}
