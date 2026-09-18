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
//! - `for_estate(RuntimeEstate)` — the production entry point, called by
//!   `runtime::run`. The caller resolved the estate from the estate catalog
//!   (`--db`, `--in-memory`); a SQLite record opens as its kind decides, a
//!   PostgreSQL record at its connection string, `InMemory` in RAM. No
//!   environment value names an estate.
//! - `default_inmemory()` — unconditionally in-memory; preserved for tests.
//!
//! Wire surface (tools, schemas, JSON-RPC methods) is unchanged regardless
//! of which backend is selected. Persistence is server-internal only.

use std::io::{BufRead, BufReader, Read, Write};
use std::sync::Arc;

use crate::dispatcher::Dispatcher;
use crate::estate_registry::EstateRegistry;

/// Configuration for a server run. Carries the estate registry the
/// dispatcher will route tool calls against.
///
/// Build via `for_estate(RuntimeEstate)` for production or
/// `default_inmemory()` for tests (unconditionally in-memory).
pub struct ServerConfig {
    pub registry: EstateRegistry,
    pub server_name: String,
    pub server_version: String,
    /// Build serial surfaced by `moot_estate_ping`. Computed once at
    /// construction via `crate::build_serial::derive()` so the filesystem
    /// is not touched on every ping call.
    pub build_serial: String,
    /// Plugin/binary version-skew advisory (empty ⇒ none to report). This
    /// reference server has no plugin concept, so it always constructs with
    /// `String::new()`. Injected into the dispatcher via `with_version_skew`
    /// inside `dispatcher_from_config`, the shared construction function called
    /// by both `run_stdio_loop` and `run_http_loop`; surfaces as the optional
    /// `version_skew` field of `moot_estate_ping` / `moot_estate_status`.
    pub version_skew: String,
    /// Upstream-release advisory provider (see
    /// `crate::dispatcher::UpdateAdvisoryProvider`) surfaced as an
    /// `update_available:` line by ping/status. `None` (both constructors'
    /// default) means no provider — the host (mootx01-cli's resident
    /// `serve`) injects one after `for_estate()`; stdio one-shots and the
    /// aria-mcp dev server leave it unset.
    pub update_advisory: Option<crate::dispatcher::UpdateAdvisoryProvider>,
}

/// The estate a server runtime opens, decided by the caller from the estate
/// catalog and passed in. Nothing in this kit reads an estate path or a
/// connection string from the environment. Twin of the Swift AriaMCPMain
/// `Arguments` resolution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeEstate {
    /// A SQLite estate: the record's `estate.sqlite`, opened as the record
    /// decides (`EstateOpening::for_record`), its manifest refreshed after the
    /// migration chain with the at-rest posture the caller resolved.
    Sqlite {
        record: genius_locus_kit::EstateRecord,
        opening: crate::estate_registry::EstateOpening,
        encryption: genius_locus_kit::EstateManifestEncryption,
    },
    /// A PostgreSQL estate at the record's connection string, opened as the
    /// record decides.
    Postgresql {
        connection_string: String,
        opening: crate::estate_registry::EstateOpening,
    },
    /// The in-memory backend (`--in-memory`): the estate lives and dies with
    /// the process. The caller still resolves its catalog record first, so a
    /// bad `--db` is refused before the backend is chosen; the opening it
    /// passes is always `EstateOpening::TRANSIENT` (R8, 2026-09-08).
    InMemory { opening: crate::estate_registry::EstateOpening },
}

impl ServerConfig {
    /// Construct a server config over `estate`. Fails with an operator-facing
    /// message when the estate cannot be opened; a PostgreSQL connection
    /// string never appears in that message.
    pub fn for_estate(estate: RuntimeEstate) -> Result<Self, String> {
        let registry = match estate {
            RuntimeEstate::Postgresql { connection_string, opening } => {
                // EstateRegistry::new_postgres reads the estate manifest during
                // construction, so an unreachable or unusable PostgreSQL estate
                // fails at startup rather than on first tool call. Redact
                // userinfo before logging — the string may carry
                // user:password@host.
                eprintln!("aria-mcp: opening PostgreSQL estate at {}", redact_postgres_url(&connection_string));
                let reg = EstateRegistry::new_postgres_with(&connection_string, "aria-mcp-default", opening)
                    .map_err(|e| format!("{e}").replace(&connection_string, "[REDACTED]"))?;
                eprintln!("aria-mcp: PostgreSQL estate ready");
                reg
            }
            RuntimeEstate::Sqlite { record, opening, encryption } => {
                // The estate directory is the record's; create it so a first
                // open of a fresh record succeeds.
                std::fs::create_dir_all(&record.directory).map_err(|e| {
                    format!("aria-mcp: cannot create the estate directory {}: {e}", record.directory.display())
                })?;
                let path_text = record.database_path().to_string_lossy().into_owned();
                eprintln!("aria-mcp: opening SQLite estate at {path_text:?}");
                let reg = EstateRegistry::new_sqlite_with(&path_text, "aria-mcp-default", opening)?;
                // The manifest must say what is on disk: after the migration
                // chain, or for an estate that predates manifests, rewrite
                // estate.json. Twin of Swift `EstateManifestRefresh.afterPrepare`.
                let now_millis = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis().min(i64::MAX as u128) as i64)
                    .unwrap_or(0);
                match genius_locus_kit_migrations::refresh_after_chain(&record, encryption, now_millis) {
                    Ok(true) => eprintln!(
                        "aria-mcp: estate manifest refreshed (format {}, schema {})",
                        genius_locus_kit::estate_format::EstateFormatVersion::CURRENT,
                        genius_locus_kit_migrations::composite_schema_version()
                    ),
                    Ok(false) => {}
                    Err(e) => return Err(format!("aria-mcp: estate manifest at {} could not be written: {e}", record.manifest_path().display())),
                }
                eprintln!("aria-mcp: SQLite estate ready at {path_text:?}");
                reg
            }
            RuntimeEstate::InMemory { opening } => {
                eprintln!("aria-mcp: in-memory estate — exists only for this process");
                EstateRegistry::new_inmemory_with(opening)
            }
        };
        Ok(ServerConfig {
            registry,
            server_name: "ARIA_MCP_Rust".to_owned(),
            server_version: "0.1.0".to_owned(),
            // Derive build serial once at config construction so the
            // filesystem is not touched on every estate_ping call.
            build_serial: crate::build_serial::derive(),
            version_skew: String::new(),
            update_advisory: None,
        })
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
            version_skew: String::new(),
            update_advisory: None,
        }
    }
}

/// Run the newline-delimited JSON stdio loop until `reader` returns EOF.
///
/// Maximum frame size for the stdio read loop (CAND-051 hardening).
/// Public so integration tests can verify the cap triggers at the correct boundary.
///
/// A peer writing bytes without a newline terminator would cause the
/// `BufReader::read_line` accumulation buffer to grow without bound,
/// eventually exhausting process memory (local DoS). This cap limits the
/// accumulated line length: once a partial line exceeds `MAX_FRAME_BYTES`
/// with no newline the loop exits cleanly rather than growing further.
/// 4 MiB matches the HTTP transport's `maxBodyBytes` default — large
/// enough for any legitimate MCP payload and small enough to bound
/// per-connection memory to a known ceiling.
pub const MAX_FRAME_BYTES: usize = 4 * 1024 * 1024;

/// Read one newline-terminated line from `reader`, accumulating partial
/// chunks, and return it. Returns `None` on EOF or read error; returns
/// `Some(String)` when a complete line is found.
///
/// Unlike `BufReader::read_line`, this function enforces `MAX_FRAME_BYTES`:
/// if the accumulated length exceeds the cap before a newline is found the
/// function logs the overflow and returns `None` to close the loop — the
/// caller must not continue reading from a runaway peer.
///
/// Implementation uses `BufReader::fill_buf` + `consume` to inspect the
/// internal buffer in place without a byte-at-a-time read, giving the same
/// throughput as `read_line` while adding the size gate.
fn read_line_capped<R: BufRead>(reader: &mut R) -> Option<String> {
    let mut line = String::new();
    loop {
        // fill_buf() returns the bytes currently available in the internal
        // buffer without consuming them. On EOF it returns Ok(&[]).
        let available = match reader.fill_buf() {
            Ok(b) => b,
            Err(e) => {
                eprintln!("aria-mcp: read error: {e}");
                return None;
            }
        };
        if available.is_empty() {
            // EOF — return what we have, or None if the line is empty.
            if line.is_empty() {
                return None;
            }
            return Some(line);
        }
        // Scan the available bytes for a newline.
        let newline_pos = available.iter().position(|&b| b == b'\n');
        let consume_len = match newline_pos {
            Some(pos) => pos + 1, // consume through the newline
            None => available.len(), // consume all available bytes
        };
        // Accumulate into the line string. `from_utf8_lossy` replaces any invalid
        // UTF-8 sequences with the replacement character so the buffer never
        // contains unvalidated bytes. Legitimate MCP frames are always valid UTF-8
        // (JSON over stdio); the lossy path is a safety net only.
        let chunk = String::from_utf8_lossy(&available[..consume_len]);
        line.push_str(&chunk);
        reader.consume(consume_len);

        // Check frame size cap before deciding whether to continue.
        if line.len() > MAX_FRAME_BYTES {
            eprintln!(
                "aria-mcp stdio: frame size cap exceeded ({} > {}), closing input",
                line.len(),
                MAX_FRAME_BYTES
            );
            return None;
        }

        // If we found a newline, the line is complete.
        if newline_pos.is_some() {
            return Some(line);
        }
        // Otherwise loop to read the next chunk.
    }
}

/// Construct a production [`Dispatcher`] from a [`ServerConfig`].
///
/// This is the ONLY place a production `Dispatcher` is constructed from a
/// `ServerConfig`. Both server loops (`run_stdio_loop` and `run_http_loop`)
/// call this function via `crate::server::dispatcher_from_config`, so both
/// transports carry identical advisory wiring. Deleting either builder call
/// (`.with_version_skew` or `.with_update_advisory`) here will turn at least
/// one stdio gate AND the HTTP construction gate RED simultaneously.
///
/// `monitoring_control` is `None` for stdio (no stats store in that transport)
/// and `Some(...)` for HTTP when a stats store is configured.
pub(crate) fn dispatcher_from_config(
    config: ServerConfig,
    monitoring_control: Option<Arc<dyn crate::monitoring_control::MonitoringControl>>,
) -> Dispatcher {
    // Destructure first so config.registry can be moved into Dispatcher::new
    // without triggering a "partial move" compile error on the remaining fields.
    let ServerConfig {
        registry,
        server_name,
        server_version,
        build_serial,
        version_skew,
        update_advisory,
    } = config;
    Dispatcher::new(registry, &server_name, &server_version, &build_serial, monitoring_control)
        .with_version_skew(version_skew)
        // Forwarded even when None (stdio configs carry None, HTTP resident hosts
        // inject the real provider). Both transports share the same builder chain.
        .with_update_advisory(update_advisory)
}

/// Reads bytes from `reader`, splits on newline, parses each line as JSON,
/// dispatches, and writes responses to `writer` one line each. Malformed
/// lines emit a parseError response with a null id, matching the Swift
/// server's behavior, so a client can recover by sending the next
/// well-formed request without restarting the server.
///
/// Frame size cap (CAND-051): if a partial line accumulates more than
/// `MAX_FRAME_BYTES` without a newline the loop exits cleanly. The peer
/// is expected to reconnect; the process does not crash or grow without bound.
pub fn run_stdio_loop<R: Read, W: Write>(reader: R, writer: &mut W, config: ServerConfig) {
    // stdio mode: no stats store → monitoring_control = None.
    // moot_monitoring_status will report "unavailable" in this transport.
    let dispatcher = dispatcher_from_config(config, None);
    let mut buf = BufReader::new(reader);

    loop {
        let line = match read_line_capped(&mut buf) {
            Some(l) => l,
            None => break, // EOF, read error, or frame size cap exceeded
        };
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
