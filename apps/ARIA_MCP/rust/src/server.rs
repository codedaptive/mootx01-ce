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
//! - `from_env()` — reads `ARIA_MCP_SQLITE_PATH` from the environment.
//!   Present and non-empty → SQLite-backed default estate at that path.
//!   Absent or empty → in-memory estate (identical to v1.0 behavior).
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
}

impl ServerConfig {
    /// Construct a server config by reading `ARIA_MCP_SQLITE_PATH` from the
    /// environment.
    ///
    /// Behavior table:
    /// | Env var state       | Backend                          |
    /// |---------------------|----------------------------------|
    /// | Absent or empty     | In-memory (ephemeral, v1 default)|
    /// | Present, non-empty  | SQLite at the specified path     |
    /// | Present, unusable   | Exit 1 with clear stderr message |
    ///
    /// Parent directories of the SQLite path are created if missing.
    /// If directory creation fails, the server exits with a nonzero code
    /// and a clear stderr message naming the path.
    ///
    /// Wire surface (tools, schemas, JSON-RPC) is unchanged for both backends.
    pub fn from_env() -> Self {
        let sqlite_path = std::env::var("ARIA_MCP_SQLITE_PATH")
            .ok()
            .filter(|s| !s.is_empty());

        let registry = match sqlite_path {
            None => {
                eprintln!("aria-mcp: ARIA_MCP_SQLITE_PATH not set — using in-memory estate");
                EstateRegistry::new_inmemory()
            }
            Some(path) => {
                // Create parent directories if they do not exist. Missing parents
                // are a common operator error (the path is new or the mount is
                // stale); failing fast here with a clear message is better than
                // a cryptic SQLite "unable to open database" error.
                if let Some(parent) = std::path::Path::new(&path).parent() {
                    if !parent.as_os_str().is_empty() {
                        if let Err(e) = std::fs::create_dir_all(parent) {
                            eprintln!(
                                "aria-mcp: cannot create parent directories for {path:?}: {e}"
                            );
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
            }
        };

        ServerConfig {
            registry,
            server_name: "ARIA_MCP_Rust".to_owned(),
            server_version: "0.1.0".to_owned(),
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
    let dispatcher = Dispatcher::new(config.registry, &config.server_name, &config.server_version);
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
