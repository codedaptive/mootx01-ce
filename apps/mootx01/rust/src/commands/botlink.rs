//! commands/botlink.rs — `mootx01 botlink`: the explicit AI data path for
//! cloud agents whose only channel to this Mac is a permissioned one-shot
//! shell. One invocation performs one MCP operation and exits.
//!
//! stdout contract: exactly ONE JSON value per invocation, no banners, no
//! log lines. All diagnostics belong on stderr. Exit codes are normative
//! (BL-2 Rust parity of the BL-1 Swift engine):
//!
//! | Code | Meaning |
//! |------|---------|
//! |    0 | MCP result with isError false/absent (stdout: result JSON) |
//! |    2 | Tool ran, isError true (stdout: raw result object) |
//! |    1 | Transport/daemon/parse failure (stdout: {"error":…,"ok":false}) |
//! |   64 | Usage / bad argv / non-loopback --http (same shape as 1) |
//!
//! Exit 2 vs 0 is load-bearing: a failed recall must be distinguishable from
//! a dead hop without parsing prose.
//!
//! SECURITY BOUNDARY: the estate never leaves the Mac. botLink is a local
//! hop, not a server. `validate_loopback_http` is the gate: any `--http`
//! value that is not 127.0.0.1 / localhost / [::1] over plain http is
//! rejected BEFORE any request is constructed (fails CLOSED, exit 64, zero
//! requests sent).

use std::io::{BufRead, BufReader, Write};
use std::process::{Command as Proc, ExitCode, Stdio};

use serde_json::Value;

use crate::cli::BotLinkSub;
use crate::core::daemon_client;

// Exit 2 is botLink-surface semantics (tool ran, isError true). It is
// deliberately NOT added to the spec-section-5 exit module: exit 2 only
// applies to the botlink surface, and adding it there would imply it is
// meaningful across all subcommands.
const TOOL_ERROR: u8 = 2;

// ── Outcome ──────────────────────────────────────────────────────────────────

/// Result of one botLink operation: the single JSON value for stdout (None =
/// empty stdout, e.g. a notification) plus the process exit code.
pub struct Outcome {
    pub stdout: Option<Value>,
    pub code: u8,
}

impl Outcome {
    fn ok(v: Value) -> Self { Outcome { stdout: Some(v), code: 0 } }
    fn tool_error(v: Value) -> Self { Outcome { stdout: Some(v), code: TOOL_ERROR } }
    fn failure(msg: &str) -> Self {
        Outcome {
            stdout: Some(serde_json::json!({"error": msg, "ok": false})),
            code: 1,
        }
    }
    fn usage_error(msg: &str) -> Self {
        Outcome {
            stdout: Some(serde_json::json!({"error": msg, "ok": false})),
            code: 64,
        }
    }
}

// ── Transport abstraction ─────────────────────────────────────────────────────

/// One-shot MCP transport. Production wiring uses HTTP (daemon POST) or stdio
/// (serve subprocess). Tests inject canned closures for full engine coverage.
///
/// `kind` is "http" or "stdio", reported verbatim in ping output.
/// `endpoint` is the daemon base URL (HTTP transport) or None (stdio; ping
/// omits the `endpoint` key rather than inventing one).
/// `send(frame_bytes, expect_id)` sends one frame; expect_id=None means
/// notification (no response expected) → returns Ok(None).
pub struct Transport {
    pub kind: String,
    pub endpoint: Option<String>,
    pub send: Box<dyn FnMut(&[u8], Option<&Value>) -> Result<Option<Value>, String>>,
}

impl std::fmt::Debug for Transport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Transport")
            .field("kind", &self.kind)
            .field("endpoint", &self.endpoint)
            .finish_non_exhaustive()
    }
}

// ── Serialization ─────────────────────────────────────────────────────────────

/// Serialize a JSON value for stdout: one line, sorted keys (byte order),
/// slashes unescaped (serde_json never escapes slashes by default).
///
/// serde_json is compiled with the `preserve_order` feature (unified via
/// genius-locus-kit/queuekit), so `to_string()` emits keys in insertion order,
/// NOT sorted. Swift serializes with `.sortedKeys` — explicit recursive sorting
/// is MANDATORY here for parity. Every stdout value goes through this function.
pub fn serialize_stdout(value: &Value) -> String {
    sort_keys_recursive(value).to_string()
}

fn sort_keys_recursive(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            // Collect and sort keys by byte order (ASCII keys throughout botLink
            // output). Rebuild the object with keys in sorted order so that
            // preserve_order retains the correct sequence on serialization.
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let mut sorted = serde_json::Map::new();
            for k in keys {
                sorted.insert(k.clone(), sort_keys_recursive(&map[k]));
            }
            Value::Object(sorted)
        }
        Value::Array(arr) => Value::Array(arr.iter().map(sort_keys_recursive).collect()),
        other => other.clone(),
    }
}

// ── Loopback guard ────────────────────────────────────────────────────────────

/// A `--http` override that passed the loopback guard.
///
/// Stores the parsed URL pieces separately so the endpoint string can be
/// rebuilt with the port that is ACTUALLY used by the transport (reviewer
/// finding F-2: attribution reports the hop used, never the literal flag
/// value).
pub struct ValidatedLoopbackUrl {
    /// The host as written in the URL, including brackets for IPv6.
    /// E.g. "localhost", "127.0.0.1", "[::1]".
    pub host_bracketed: String,
    /// Explicit port extracted from the URL, or None when the URL carries no port.
    /// When None, callers resolve the port via `daemon_client::resolved_port()`.
    pub explicit_port: Option<u16>,
    /// Path portion of the URL (everything after the authority), with any
    /// trailing slash stripped. "" for "http://localhost/"; "/x" for "http://[::1]/x/".
    pub path_suffix: String,
}

impl ValidatedLoopbackUrl {
    /// Build the endpoint string inserting `port`. Call with `explicit_port.unwrap()`
    /// for URLs that carried an explicit port; call with the resolved daemon port for
    /// portless URLs. Attribution then reports the hop actually used (reviewer F-2).
    pub fn endpoint_with_port(&self, port: u16) -> String {
        format!("http://{}:{}{}", self.host_bracketed, port, self.path_suffix)
    }
}

/// Validate a `--http` override as a loopback-only HTTP URL.
///
/// Accepts exactly `http://127.0.0.1:*`, `http://localhost:*`, and
/// `http://[::1]:*` (any port — INCLUDING NO PORT — and any path). Portless
/// URLs are accepted here because the security boundary is the host, not the
/// port. `daemon_client::port_from_url` rejects portless URLs (it requires a
/// colon after the host) and is therefore NOT reused for this guard.
///
/// Everything else — other hosts, https, non-http schemes, 0.0.0.0,
/// unparseable strings — returns None and the caller exits 64 WITHOUT
/// constructing any request (fails CLOSED).
pub fn validate_loopback_http(s: &str) -> Option<ValidatedLoopbackUrl> {
    // Must start with http:// — rejects https and all other schemes.
    let rest = s.strip_prefix("http://")?;
    // Authority = everything before the first '/' (or end of string).
    let authority = rest.split('/').next().unwrap_or("");
    // Extract host and port, handling IPv6 bracket notation [::1].
    // host_bracketed includes brackets for IPv6 so it can be used verbatim
    // when reassembling the URL in endpoint_with_port.
    let (host, host_bracketed, explicit_port) = if authority.starts_with('[') {
        // IPv6 bracketed form: "[::1]" or "[::1]:port"
        let close = authority.find(']')?;
        let host = &authority[1..close];
        let rest_after = &authority[close + 1..];
        let port = if let Some(p) = rest_after.strip_prefix(':') {
            p.parse::<u16>().ok()
        } else {
            None
        };
        (host, format!("[{host}]"), port)
    } else {
        // IPv4 / hostname: "host" or "host:port"
        match authority.rsplit_once(':') {
            Some((h, p)) => (h, h.to_string(), p.parse::<u16>().ok()),
            None => (authority, authority.to_string(), None),
        }
    };
    // Enforce loopback: only 127.0.0.1, localhost, and ::1 are permitted.
    // 0.0.0.0 and any other host are rejected.
    match host {
        "127.0.0.1" | "localhost" | "::1" => {}
        _ => return None,
    }
    // Path: everything after "http://{authority}", trailing slash stripped.
    // A bare "/" becomes "" (no path component); "/x/" becomes "/x".
    let authority_end = "http://".len() + authority.len();
    let path_raw = &s[authority_end..];
    let path_suffix = if path_raw == "/" {
        String::new()
    } else if path_raw.ends_with('/') {
        path_raw[..path_raw.len() - 1].to_string()
    } else {
        path_raw.to_string()
    };
    Some(ValidatedLoopbackUrl { host_bracketed, explicit_port, path_suffix })
}

// ── Transport resolution ──────────────────────────────────────────────────────

/// Resolve the transport per BL-2 transport-select rules. Returns Ok(transport)
/// on success, Err(outcome) when the --http guard fires (exit 64 without any
/// request) — see P-2 ordering below.
///
/// Ordering (enforced — P-2 is a gate):
/// 1. `--http` (when present) is loopback-validated FIRST, before the probe
///    and before `--db` is consulted. A bad URL exits 64 even when `--db`
///    pins stdio (the guard always wins).
/// 2. `--db` absent + 250 ms probe finds the daemon → HTTP transport using
///    the override URL's port (when given) or the resolved default port.
/// 3. Otherwise → serve subprocess (stdio transport).
pub fn resolve_transport(
    http: Option<&str>,
    db: Option<&str>,
) -> Result<Transport, Outcome> {
    // Step 1: validate --http FIRST (P-2: bad URL exits 64 regardless of --db).
    let validated_url = if let Some(url_str) = http {
        match validate_loopback_http(url_str) {
            Some(v) => Some(v),
            None => {
                return Err(Outcome::usage_error(&format!(
                    "'--http' must be a loopback HTTP URL (e.g. http://127.0.0.1:4242), got '{url_str}'"
                )));
            }
        }
    } else {
        None
    };

    // Step 2: --db absent → try HTTP transport.
    if db.is_none() {
        let port = validated_url
            .as_ref()
            .and_then(|v| v.explicit_port)
            .unwrap_or_else(daemon_client::resolved_port);
        // Portless --http override: the guard accepted the URL (security boundary
        // is the host, not the port). For portless URLs we POST to the daemon's
        // resolved port and the endpoint string carries that same resolved port —
        // attribution reports the hop actually used, never the literal flag value
        // (reviewer finding F-2). Swift's portless behaviour would POST to port 80
        // (the HTTP default); the Rust vertical maps portless to the resolved daemon
        // port instead, which is the only meaningful local target.
        if daemon_client::alive(port) {
            let endpoint = validated_url
                .map(|v| v.endpoint_with_port(port))
                .unwrap_or_else(|| format!("http://127.0.0.1:{port}"));
            return Ok(http_transport(port, endpoint));
        }
    }

    // Step 3: stdio subprocess (--db pin or daemon not alive).
    Ok(stdio_transport(db.map(str::to_string)))
}

fn http_transport(port: u16, endpoint: String) -> Transport {
    Transport {
        kind: "http".to_string(),
        endpoint: Some(endpoint),
        send: Box::new(move |frame: &[u8], expect_id: Option<&Value>| {
            let (status, body) = daemon_client::post_frame(port, frame)
                .map_err(|e| format!("daemon request failed: {e}"))?;

            // Notification: return Ok(None) BEFORE any status check (P-14).
            // The daemon acks notifications with 202 empty body; there is no
            // response frame to parse. Checking status for a notification is
            // meaningless — the caller does not wait for a response object.
            if expect_id.is_none() {
                return Ok(None);
            }

            if !(200..=299).contains(&status) {
                return Err(format!("daemon returned HTTP {status}"));
            }

            // Long tool calls are legitimate: lens/synthesis on a large estate
            // legitimately runs for minutes. daemon_client::post_frame carries a
            // 3600 s read timeout — the cloud agent owns its own timeout policy;
            // this hop must not impose a shorter one.
            let v: Value = serde_json::from_slice(&body)
                .map_err(|_| "daemon returned non-JSON response".to_string())?;
            if !v.is_object() {
                return Err("daemon returned non-JSON response".to_string());
            }
            Ok(Some(v))
        }),
    }
}

fn stdio_transport(db: Option<String>) -> Transport {
    Transport {
        kind: "stdio".to_string(),
        endpoint: None,
        send: Box::new(move |frame, expect_id| {
            let exe = std::env::current_exe()
                .map_err(|e| format!("cannot resolve binary: {e}"))?;
            let mut cmd = Proc::new(&exe);
            cmd.arg("serve");
            if let Some(name) = db.as_deref() {
                cmd.args(["--db", name]);
            }
            let mut child = cmd
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                // Inherit stderr: serve subprocess banners go to OUR stderr, never
                // stdout. An unread stderr pipe can deadlock chatty tools — the
                // botLink contract routes all serve diagnostics through stderr.
                // This deliberately differs from query.rs which uses Stdio::null()
                // (query's callers are human-readable; botLink's callers are AI
                // agents that must see no banner contamination on stdout).
                .stderr(Stdio::inherit())
                .spawn()
                .map_err(|e| format!("cannot spawn serve subprocess: {e}"))?;

            let mut stdin = child.stdin.take().expect("piped stdin");
            let stdout = child.stdout.take().expect("piped stdout");

            let init = serde_json::json!({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "mootx01-botlink", "version": crate::CURRENT_VERSION}
                }
            });

            // Send initialize frame (id 1), then the ONE frame. No "initialized"
            // notification: the Rust vertical's established wire shape sends only
            // initialize + call. McpOneShot.swift:16-20 documents that as valid
            // MCP — "initialized" is a no-op notification the server tolerates
            // being absent. This is a deliberate cross-port wire difference;
            // both shapes are valid MCP.
            let send_result = (|| -> std::io::Result<()> {
                stdin.write_all(init.to_string().as_bytes())?;
                stdin.write_all(b"\n")?;
                stdin.write_all(frame)?;
                stdin.write_all(b"\n")?;
                stdin.flush()
            })();
            if let Err(e) = send_result {
                let _ = child.kill();
                return Err(format!("subprocess write failed: {e}"));
            }
            drop(stdin); // close → server exits after responding (stdin-closed loop)

            // Notification: write the frame, drop stdin, wait, return Ok(None).
            if expect_id.is_none() {
                let _ = child.wait();
                return Ok(None);
            }

            // Read stdout lines until a frame whose "id" Value-EQUALS the request's
            // id. Value equality handles both integer and string ids — rpc forwards
            // caller-authored ids verbatim; the comparison works regardless of
            // whether the id is JSON number 2 or the string "abc".
            let mut result = None;
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                if v.get("id") == expect_id.map(|id| id) {
                    result = Some(v);
                    break;
                }
            }
            let _ = child.wait();
            result.ok_or_else(|| "no response from serve subprocess".to_string()).map(Some)
        }),
    }
}

// ── Argument parsing ──────────────────────────────────────────────────────────

/// Parse `["--key", "value", …]` pairs with botLink semantics. Called to
/// process the `kv` tokens captured by `mootx01 botlink call`.
///
/// Decode rules (normative for BL-2; deliberately differ from query's
/// `parse_kv_args` — see below):
/// - Values decoded as i64 when they parse as such; "true"/"false" as bool;
///   everything else is a String. `--limit 1.5` MUST put the STRING "1.5"
///   on the wire (the shipped Swift botLink decodes integers and booleans
///   only; floats stay strings).
/// - Non-`--` positional tokens are silently skipped.
/// - Bare `--` is silently skipped (option terminator, may appear in shell).
/// - Trailing `--flag` with no following value → true.
///
/// Why NOT reuse query::parse_kv_args: query full-JSON-decodes values
/// (floats/arrays/objects) and REJECTS non-`--` positionals with an error.
/// The shipped Swift botLink (`@Argument(parsing: .allUnrecognized)`) silently
/// skips positional tokens, and only decodes i64 + bool. Parity requires the
/// botLink semantics, not query's.
pub fn parse_kv_arguments(tokens: &[String]) -> Value {
    let mut obj = serde_json::Map::new();
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        // Skip non-`--` positionals silently.
        if !token.starts_with("--") {
            i += 1;
            continue;
        }
        let key = &token[2..];
        // Skip bare "--" (bash-style option terminator).
        if key.is_empty() {
            i += 1;
            continue;
        }
        // Peek at the next token: if absent or starts with "--", treat as flag.
        if i + 1 < tokens.len() && !tokens[i + 1].starts_with("--") {
            let raw = &tokens[i + 1];
            let decoded = decode_kv_value(raw);
            obj.insert(key.to_string(), decoded);
            i += 2;
        } else {
            // Flag-style argument: treat as true.
            obj.insert(key.to_string(), Value::Bool(true));
            i += 1;
        }
    }
    Value::Object(obj)
}

/// Decode a KV value with botLink semantics: i64, then bool, then String.
/// Floats and structured values (arrays, objects) remain strings — the server
/// contract for botLink arguments uses integer and boolean scalars only;
/// complex values should be expressed via `--args` JSON object.
fn decode_kv_value(s: &str) -> Value {
    if let Ok(n) = s.parse::<i64>() {
        return Value::Number(n.into());
    }
    match s {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        _ => Value::String(s.to_string()),
    }
}

/// Parse a `--args` JSON string into a JSON object. Returns None when the
/// string is malformed or not a JSON object (array/scalar inputs also return
/// None). The caller exits 64 on None — usage error, validated BEFORE any
/// transport is resolved (P-4).
fn parse_args_json(s: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(s).ok()?;
    if v.is_object() { Some(v) } else { None }
}

/// Overlay KV pairs onto a `--args` base object. KV wins on key collision
/// (`--args` is the base, `--key value` is the override) — normative for
/// BL-2 parity (P-5).
fn overlay_arguments(base: Value, overlay: Value) -> Value {
    let mut merged = match base {
        Value::Object(m) => m,
        _ => serde_json::Map::new(),
    };
    if let Value::Object(kv) = overlay {
        for (k, v) in kv {
            merged.insert(k, v);
        }
    }
    Value::Object(merged)
}

// ── Ping payload parsing ──────────────────────────────────────────────────────

/// Parse the `moot_estate_ping` pong payload into attribution fields.
///
/// Operates on the HEAD LINE ONLY (P-8). Lines after the first, trimmed and
/// non-empty, are advisories — the caller prints them to stderr; they never
/// appear in the stdout JSON.
///
/// Head must start with "pong: estate" or all fields are None.
/// Fields are optional by parse: absent when not extractable, never invented.
fn parse_pong(text: &str) -> PongFields {
    let mut lines = text.split('\n');
    let head = lines.next().unwrap_or("").to_string();
    // Advisories: lines after the first, trimmed, non-empty.
    let advisories: Vec<String> = lines
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();

    if !head.starts_with("pong: estate") {
        return PongFields { estate: None, estate_id: None, build: None, advisories };
    }

    // Both estate and estate_id are extracted ONLY when a '[' … ']' bracket
    // pair is present (open < close). A head without brackets yields both as
    // None — matching Swift's parsePong (BotLink.swift lines 210-219) which
    // gates the entire name/id block inside a single bracket-found guard.
    // Without this guard a bracketless head like "pong: estate Foo is live —
    // build 2.0" would emit the garbage string " Foo is live — build 2.0" as
    // the estate name, diverging from the Swift behaviour.
    let (estate, estate_id) = if let (Some(open), Some(close)) = (head.find('['), head.find(']')) {
        if open < close {
            let id = &head[open + 1..close];
            let estate_id = if !id.is_empty() { Some(id.to_string()) } else { None };
            // Estate name sits between "pong: estate" and '[', trimmed.
            let name_start = "pong: estate".len();
            let name = head[name_start..open].trim();
            let estate = if !name.is_empty() { Some(name.to_string()) } else { None };
            (estate, estate_id)
        } else {
            (None, None)
        }
    } else {
        (None, None)
    };

    // Build: text after "build " to end of head.
    let build = head.find("build ").map(|pos| {
        head[pos + "build ".len()..].trim().to_string()
    }).filter(|b| !b.is_empty());

    PongFields { estate, estate_id, build, advisories }
}

struct PongFields {
    estate: Option<String>,
    estate_id: Option<String>,
    build: Option<String>,
    advisories: Vec<String>,
}

// ── Subcommand engines ────────────────────────────────────────────────────────

/// `ping`: liveness + identity. One `tools/call moot_estate_ping` plus
/// transport attribution. Success stdout is the shaped object; fields the
/// payload cannot fill are omitted. `toolCount` is NEVER emitted (P-7) —
/// the ping payload does not carry it; botLink never invents values.
pub fn ping_engine(transport: &mut Transport) -> Outcome {
    let frame = build_frame(2, "tools/call", &serde_json::json!({
        "name": "moot_estate_ping",
        "arguments": {}
    }));
    let expect_id = Value::Number(2.into());
    match (transport.send)(frame.as_bytes(), Some(&expect_id)) {
        Err(e) => Outcome::failure(&e),
        Ok(None) => Outcome::failure("no response received"),
        Ok(Some(obj)) => {
            if let Some(err) = obj.get("error") {
                return Outcome::failure(&format!("tool error: {err}"));
            }
            let result = match obj.get("result").and_then(|v| if v.is_object() { Some(v) } else { None }) {
                None => return Outcome::failure("no result field in ping response"),
                Some(r) => r,
            };
            if is_error_result(result) {
                // DELIBERATE CHOICE (BL-1, normative for BL-2): estate_ping
                // has reachable isError paths (quiesced/draining estate,
                // unmounted estate). Exit 2 is load-bearing — a failed tool
                // must be distinguishable from a dead hop — and stdout is the
                // RAW result object (parseable, carries the server's own error
                // content), NOT the synthesized ok:true/ok:false shape. Do not
                // "fix" this into either shape.
                return Outcome::tool_error(result.clone());
            }
            let mut payload = serde_json::Map::new();
            payload.insert("ok".into(), Value::Bool(true));
            payload.insert("transport".into(), Value::String(transport.kind.clone()));
            if let Some(ep) = &transport.endpoint {
                payload.insert("endpoint".into(), Value::String(ep.clone()));
            }
            if let Some(text) = result
                .get("content")
                .and_then(|c| c.as_array())
                .and_then(|a| a.first())
                .and_then(|o| o.get("text"))
                .and_then(|t| t.as_str())
            {
                let pong = parse_pong(text);
                if let Some(e) = pong.estate { payload.insert("estate".into(), Value::String(e)); }
                if let Some(id) = pong.estate_id { payload.insert("estateId".into(), Value::String(id)); }
                if let Some(b) = pong.build { payload.insert("build".into(), Value::String(b)); }
                // Advisory lines (version_skew / update_available) are diagnostics:
                // they go to stderr, keeping stdout machine JSON only. Not an
                // `advisories` field — the normative ping shape has no such field
                // and botLink never invents values.
                for advisory in pong.advisories {
                    eprintln!("mootx01 botlink: {advisory}");
                }
            }
            Outcome::ok(Value::Object(payload))
        }
    }
}

/// Iteration cap for `list` cursor-following. tools/list pages are
/// server-controlled; a misbehaving server that loops cursors forever must not
/// hang the one-shot process. 64 pages × any sane page size covers every real
/// surface (77 tools today) by orders of magnitude.
const MAX_LIST_PAGES: usize = 64;

/// `list`: emit the MCP tools/list RESULT OBJECT — `{"tools":[…]}`.
/// Follows `nextCursor` internally and prints ONE combined array; the caller
/// never loops.
pub fn list_engine(transport: &mut Transport) -> Outcome {
    let mut tools: Vec<Value> = Vec::new();
    let mut cursor: Option<String> = None;
    let mut request_id: i64 = 2;

    for _ in 0..MAX_LIST_PAGES {
        let params = if let Some(c) = &cursor {
            serde_json::json!({"cursor": c})
        } else {
            serde_json::json!({})
        };
        let frame = build_frame(request_id, "tools/list", &params);
        let expect_id = Value::Number(request_id.into());
        let obj = match (transport.send)(frame.as_bytes(), Some(&expect_id)) {
            Err(e) => return Outcome::failure(&e),
            Ok(None) => return Outcome::failure("no response received"),
            Ok(Some(o)) => o,
        };
        if let Some(err) = obj.get("error") {
            return Outcome::failure(&format!("tool error: {err}"));
        }
        let result = match obj.get("result").and_then(|v| if v.is_object() { Some(v) } else { None }) {
            None => return Outcome::failure("no result field in tools/list response"),
            Some(r) => r,
        };
        if let Some(page) = result.get("tools").and_then(|t| t.as_array()) {
            tools.extend(page.iter().cloned());
        }
        let next = result.get("nextCursor").and_then(|v| v.as_str()).map(str::to_string);
        // Absent nextCursor OR empty-string nextCursor terminates the loop (P-9).
        if next.as_deref().map(|s| s.is_empty()).unwrap_or(true) {
            return Outcome::ok(serde_json::json!({"tools": tools}));
        }
        cursor = next;
        request_id += 1;
    }
    Outcome::failure(&format!("tools/list did not terminate within {MAX_LIST_PAGES} pages"))
}

/// `call`: one `tools/call moot_<verb>`. Stdout is the RAW MCP result object
/// (with `content` and `isError`) — never unwrapped. Exit 0/2 by `isError`.
pub fn call_engine(verb: &str, arguments: Value, transport: &mut Transport) -> Outcome {
    let frame = build_frame(2, "tools/call", &serde_json::json!({
        "name": format!("moot_{verb}"),
        "arguments": arguments
    }));
    let expect_id = Value::Number(2.into());
    match (transport.send)(frame.as_bytes(), Some(&expect_id)) {
        Err(e) => Outcome::failure(&e),
        Ok(None) => Outcome::failure("no response received"),
        Ok(Some(obj)) => {
            if let Some(err) = obj.get("error") {
                return Outcome::failure(&format!("tool error: {err}"));
            }
            match obj.get("result").and_then(|v| if v.is_object() { Some(v) } else { None }) {
                None => Outcome::failure("no result field in tools/call response"),
                Some(result) => {
                    if is_error_result(result) {
                        Outcome::tool_error(result.clone())
                    } else {
                        Outcome::ok(result.clone())
                    }
                }
            }
        }
    }
}

/// `rpc`: the escape hatch — one caller-authored JSON-RPC frame in, one frame
/// out. The frame's ORIGINAL BYTES are sent verbatim — no re-encoding of
/// caller bytes (P-10). A notification (no `id`) produces empty stdout, exit
/// 0. A response frame is printed whole via serialize_stdout.
///
/// Response exit mapping:
/// - JSON-RPC `error` member → exit 1, stdout = the RESPONSE FRAME ITSELF
///   via serialize_stdout (NOT the ok:false shape — G-3 byte-compares; this
///   asymmetry is deliberate: the frame is already machine-parseable and
///   carries the protocol-level error detail).
/// - result.isError true → exit 2.
/// - Otherwise → exit 0.
pub fn rpc_engine(frame_str: &str, transport: &mut Transport) -> Outcome {
    // Parse to validate it's a JSON object and extract the id.
    let frame_val: Value = match serde_json::from_str::<Value>(frame_str) {
        Ok(v) if v.is_object() => v,
        _ => return Outcome::usage_error("rpc frame is not a JSON object"),
    };
    let expect_id = frame_val.get("id").cloned();

    // Send the ORIGINAL BYTES verbatim (P-10).
    let response = match (transport.send)(frame_str.as_bytes(), expect_id.as_ref()) {
        Err(e) => return Outcome::failure(&e),
        Ok(None) => {
            // Notification: empty stdout, exit 0.
            return Outcome { stdout: None, code: 0 };
        }
        Ok(Some(r)) => r,
    };

    let code = if response.get("error").is_some() {
        1
    } else if response.get("result")
        .filter(|r| is_error_result(r))
        .is_some()
    {
        TOOL_ERROR
    } else {
        0
    };
    // rpc response: stdout is the response FRAME ITSELF via serialize_stdout,
    // even for error-member responses (G-3). This differs from Outcome::failure
    // which uses the ok:false shape. The deliberate asymmetry: rpc callers
    // expect the raw protocol frame, not a botLink-shaped error envelope.
    Outcome { stdout: Some(response), code }
}

/// A tools/call result is an error when `isError` is `Bool(true)` exactly.
/// Absent or `false` both mean success (normative: "isError false or absent").
fn is_error_result(result: &Value) -> bool {
    result.get("isError") == Some(&Value::Bool(true))
}

/// Build a JSON-RPC 2.0 frame string.
fn build_frame(id: i64, method: &str, params: &Value) -> String {
    serde_json::json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params
    })
    .to_string()
}

// ── run() — wiring ────────────────────────────────────────────────────────────

/// Entry point: resolve transport, run the subcommand engine, emit stdout,
/// return exit code.
pub fn run(sub: BotLinkSub, http: Option<String>, db: Option<String>) -> ExitCode {
    // --args validation for call is done BEFORE transport resolution (P-4):
    // a bad --args JSON exits 64 without constructing any transport or
    // network connection.
    let (_call_verb, call_args) = if let BotLinkSub::Call { ref verb, ref args_json, ref kv } = sub {
        let base = if let Some(json_str) = args_json {
            match parse_args_json(json_str) {
                Some(v) => v,
                None => {
                    let outcome = Outcome::usage_error("--args must be a JSON object");
                    return emit(outcome);
                }
            }
        } else {
            Value::Object(serde_json::Map::new())
        };
        let overlay = parse_kv_arguments(kv);
        let merged = overlay_arguments(base, overlay);
        (Some(verb.clone()), Some(merged))
    } else {
        (None, None)
    };

    let mut transport = match resolve_transport(http.as_deref(), db.as_deref()) {
        Ok(t) => t,
        Err(outcome) => return emit(outcome),
    };

    let outcome = match &sub {
        BotLinkSub::Ping => ping_engine(&mut transport),
        BotLinkSub::List => list_engine(&mut transport),
        BotLinkSub::Call { verb, .. } => {
            call_engine(verb, call_args.unwrap_or(Value::Object(serde_json::Map::new())), &mut transport)
        }
        BotLinkSub::Rpc { frame } => {
            let raw = match frame {
                Some(s) => s.clone(),
                None => {
                    use std::io::Read;
                    let mut buf = String::new();
                    std::io::stdin().read_to_string(&mut buf).unwrap_or(0);
                    buf.trim().to_string()
                }
            };
            rpc_engine(&raw, &mut transport)
        }
    };

    emit(outcome)
}

fn emit(outcome: Outcome) -> ExitCode {
    if let Some(v) = outcome.stdout {
        println!("{}", serialize_stdout(&v));
    }
    ExitCode::from(outcome.code)
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::io::{Read, Write};
    use std::sync::{Arc, Mutex};
    use std::sync::atomic::{AtomicUsize, Ordering};

    // ── Stub server helpers ───────────────────────────────────────────────────

    /// HTTP/1.1 minimal response wrapping a JSON body.
    fn http_ok(body: &[u8]) -> Vec<u8> {
        let mut r = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        r.extend_from_slice(body);
        r
    }

    /// Like stub_server_capturing but also captures each request body. Returns (port, captured_bodies).
    fn stub_server_capturing(responses: Vec<Vec<u8>>) -> (u16, Arc<Mutex<Vec<Vec<u8>>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let bodies: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));
        let bodies2 = bodies.clone();
        std::thread::spawn(move || {
            for resp in responses {
                if let Ok((mut conn, _)) = listener.accept() {
                    // Read the full HTTP request; body follows \r\n\r\n.
                    let mut raw = vec![0u8; 32768];
                    let n = conn.read(&mut raw).unwrap_or(0);
                    raw.truncate(n);
                    // Extract body after header separator.
                    let body = if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                        raw[pos + 4..].to_vec()
                    } else {
                        raw
                    };
                    bodies2.lock().unwrap().push(body);
                    let _ = conn.write_all(&resp);
                }
            }
        });
        (port, bodies)
    }

    /// Counting stub: accepts connections and counts them; serves no useful response.
    fn counting_stub() -> (u16, Arc<AtomicUsize>) {
        let counter = Arc::new(AtomicUsize::new(0));
        let counter2 = counter.clone();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            loop {
                if let Ok((mut conn, _)) = listener.accept() {
                    counter2.fetch_add(1, Ordering::SeqCst);
                    let _ = conn.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
                }
            }
        });
        (port, counter)
    }

    /// Build an injected transport backed by a simple function (for engine unit tests).
    fn make_transport(
        kind: &str,
        endpoint: Option<String>,
        f: impl FnMut(&[u8], Option<&Value>) -> Result<Option<Value>, String> + 'static,
    ) -> Transport {
        Transport {
            kind: kind.to_string(),
            endpoint,
            send: Box::new(f),
        }
    }

    // ── G-1: loopback guard blocks non-loopback --http ─────────────────────────

    #[test]
    fn g1_non_loopback_http_exits_64_zero_requests_sorted_shape() {
        // Non-loopback URL (example.com): guard must fire before any connection
        // is made. Cheap validity check for exit code and serialized shape.
        let (_stub_port, request_count) = counting_stub();
        let result = resolve_transport(Some("http://example.com"), None);
        assert!(result.is_err(), "non-loopback URL must be rejected");
        let outcome = result.unwrap_err();
        assert_eq!(outcome.code, 64);
        // Assert the exact serialized string (sorted keys, G-1).
        let stdout_str = serialize_stdout(outcome.stdout.as_ref().unwrap());
        assert_eq!(
            stdout_str,
            r#"{"error":"'--http' must be a loopback HTTP URL (e.g. http://127.0.0.1:4242), got 'http://example.com'","ok":false}"#
        );
        // Zero requests to the counting stub (the stub is on a different port
        // and the guard fires before any socket is opened anyway).
        assert_eq!(request_count.load(Ordering::SeqCst), 0);

        // The 0.0.0.0 sub-case is the DISCRIMINATING one: on this platform
        // 0.0.0.0 as a connect target reaches loopback, so a "reject-after-POST"
        // or "probe-before-validate" implementation WOULD hit the counting stub
        // bound on that port. The correct guard rejects 0.0.0.0 before
        // constructing any connection, keeping the count at zero even when a
        // route exists through 0.0.0.0 → loopback.
        let (stub_port_00, count_00) = counting_stub();
        let url_00 = format!("http://0.0.0.0:{stub_port_00}");
        let result_00 = resolve_transport(Some(&url_00), None);
        assert!(result_00.is_err(), "0.0.0.0 URL must be rejected");
        let outcome_00 = result_00.unwrap_err();
        assert_eq!(outcome_00.code, 64);
        let stdout_00 = serialize_stdout(outcome_00.stdout.as_ref().unwrap());
        assert_eq!(
            stdout_00,
            format!(
                r#"{{"error":"'--http' must be a loopback HTTP URL (e.g. http://127.0.0.1:4242), got 'http://0.0.0.0:{stub_port_00}'","ok":false}}"#
            )
        );
        // Sleep ≤100 ms to let any stray connection land before we check.
        std::thread::sleep(std::time::Duration::from_millis(100));
        assert_eq!(count_00.load(Ordering::SeqCst), 0, "0.0.0.0 guard must send zero requests");
    }

    // ── Loopback guard unit cases ──────────────────────────────────────────────

    #[test]
    fn loopback_guard_accepts_valid_urls() {
        assert!(validate_loopback_http("http://127.0.0.1:9").is_some());
        assert!(validate_loopback_http("http://localhost:4242/x").is_some());
        assert!(validate_loopback_http("http://[::1]:4242").is_some());
        // Portless — accepted by the guard (explicit_port = None in result).
        assert!(validate_loopback_http("http://localhost").is_some());
        let portless = validate_loopback_http("http://localhost").unwrap();
        assert!(portless.explicit_port.is_none());
    }

    #[test]
    fn loopback_guard_rejects_invalid_urls() {
        assert!(validate_loopback_http("https://127.0.0.1:4242").is_none(), "https rejected");
        assert!(validate_loopback_http("http://192.168.1.1:4242").is_none(), "LAN IP rejected");
        assert!(validate_loopback_http("http://0.0.0.0:4242").is_none(), "0.0.0.0 rejected");
        assert!(validate_loopback_http("http://evil.com:4242").is_none(), "external host rejected");
        assert!(validate_loopback_http("garbage").is_none(), "garbage rejected");
    }

    #[test]
    fn loopback_guard_trailing_slash_stripped() {
        // Trailing slash on an explicit-port URL: path_suffix is "", endpoint
        // built with endpoint_with_port matches the slash-stripped form.
        let v = validate_loopback_http("http://127.0.0.1:4242/").unwrap();
        assert_eq!(v.endpoint_with_port(v.explicit_port.unwrap()), "http://127.0.0.1:4242");
    }

    #[test]
    fn loopback_guard_ipv6_bracketed() {
        let v = validate_loopback_http("http://[::1]:4242").unwrap();
        assert_eq!(v.explicit_port, Some(4242));
        assert_eq!(v.endpoint_with_port(4242), "http://[::1]:4242");
    }

    // ── F-2: portless --http endpoint attribution ─────────────────────────────

    /// Pure helper — does not touch the live daemon; exercises endpoint
    /// construction with an injected resolved port (reviewer finding F-2).
    fn portless_endpoint_attr(url: &str, resolved: u16) -> String {
        let v = validate_loopback_http(url).expect("valid loopback url");
        let port = v.explicit_port.unwrap_or(resolved);
        v.endpoint_with_port(port)
    }

    #[test]
    fn f2_portless_endpoint_attribution() {
        // Portless URLs carry the resolved port in the endpoint (reviewer F-2).
        assert_eq!(portless_endpoint_attr("http://localhost/", 4242), "http://localhost:4242");
        assert_eq!(portless_endpoint_attr("http://[::1]/", 4242), "http://[::1]:4242");
        // Portless with a non-root path: resolved port inserted, trailing slash stripped.
        assert_eq!(portless_endpoint_attr("http://[::1]/x/", 4242), "http://[::1]:4242/x");
        // Explicit-port URL: endpoint is the URL as given minus trailing slash,
        // regardless of the injected resolved port (explicit port wins).
        assert_eq!(portless_endpoint_attr("http://127.0.0.1:9/", 9999), "http://127.0.0.1:9");
    }

    // ── G-2: KV argument capture — string/int/bool semantics ──────────────────

    #[test]
    fn g2_kv_float_stays_string() {
        // --limit 1.5 must put the STRING "1.5" on the wire (botLink semantics:
        // i64 decode only). A stub captures the request body to verify.
        let ping_resp = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "content": [{"type":"text","text":"pong: estate test [abc] is live — build 1.0"}],
                "isError": false
            }
        });
        let (port, bodies) = stub_server_capturing(vec![http_ok(ping_resp.to_string().as_bytes())]);
        let mut transport = http_transport(port, format!("http://127.0.0.1:{port}"));
        let tokens: Vec<String> = vec![
            "--limit".into(), "1.5".into(),
            "--n".into(), "5".into(),
            "--b".into(), "true".into(),
            "skip_me".into(),           // positional → skipped
            "--trailing".into(),         // trailing flag → true
            "--".into(),                 // bare "--" → skipped
        ];
        let kv = parse_kv_arguments(&tokens);
        call_engine("test_verb", kv.clone(), &mut transport);

        let captured = bodies.lock().unwrap();
        let body: Value = serde_json::from_slice(&captured[0]).unwrap();
        let args = &body["params"]["arguments"];
        // --limit 1.5: float → stays STRING "1.5"
        assert_eq!(args["limit"], Value::String("1.5".into()), "float must stay string");
        // --n 5: integer → Number
        assert_eq!(args["n"], serde_json::json!(5i64), "integer must decode to i64");
        // --b true: bool → Bool
        assert_eq!(args["b"], Value::Bool(true), "bool literal must decode to bool");
        // --trailing with no following value → true
        assert_eq!(args["trailing"], Value::Bool(true), "trailing flag must be true");
        // bare "--" skipped → no "" key
        assert!(args.get("").is_none(), "bare -- must be skipped");
    }

    // ── P-5: KV overlay wins over --args base ─────────────────────────────────

    #[test]
    fn p5_kv_overlay_wins_on_collision() {
        let base = parse_args_json(r#"{"key": "base_value", "other": 1}"#).unwrap();
        let kv_tokens: Vec<String> = vec!["--key".into(), "override".into()];
        let overlay = parse_kv_arguments(&kv_tokens);
        let merged = overlay_arguments(base, overlay);
        assert_eq!(merged["key"], Value::String("override".into()));
        assert_eq!(merged["other"], serde_json::json!(1));
    }

    // ── P-4: --args validation before transport ────────────────────────────────

    #[test]
    fn p4_args_array_exits_64_no_transport() {
        // parse_args_json is pure — no transport or network access needed.
        // A JSON array is not an object → returns None → caller exits 64.
        let result = parse_args_json("[1,2]");
        assert!(result.is_none(), "array must fail validation");
    }

    #[test]
    fn p4_args_not_json_exits_64() {
        assert!(parse_args_json("not-json").is_none());
    }

    #[test]
    fn p4_args_valid_object_ok() {
        let v = parse_args_json(r#"{"a": 1}"#).unwrap();
        assert_eq!(v["a"], serde_json::json!(1));
    }

    // ── Ping happy path via stub ───────────────────────────────────────────────

    #[test]
    fn ping_happy_path_sorted_keys_and_advisory_lines() {
        // Multi-line pong: head + advisory lines. Advisory must go to stderr,
        // NOT appear in stdout JSON.
        let pong_text = "pong: estate MyEstate [abc-123] is live — build 1.2.3\nversion_skew: minor\nupdate_available: 1.3.0";
        let resp = serde_json::json!({
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "content": [{"type": "text", "text": pong_text}],
                "isError": false
            }
        });
        let mut transport = make_transport("http", Some("http://127.0.0.1:9999".into()), {
            let resp = resp.clone();
            move |_, _| Ok(Some(resp.clone()))
        });
        let outcome = ping_engine(&mut transport);
        assert_eq!(outcome.code, 0);
        let stdout_str = serialize_stdout(outcome.stdout.as_ref().unwrap());
        // G-4: assert the exact serialized string (sorted keys).
        assert_eq!(
            stdout_str,
            r#"{"build":"1.2.3","endpoint":"http://127.0.0.1:9999","estate":"MyEstate","estateId":"abc-123","ok":true,"transport":"http"}"#
        );
    }

    #[test]
    fn ping_head_line_only_no_advisories_field() {
        let pong_text = "pong: estate Sol [id-1] is live — build 2.0\nextra advisory line";
        let v = parse_pong(pong_text);
        assert_eq!(v.estate.as_deref(), Some("Sol"));
        assert_eq!(v.estate_id.as_deref(), Some("id-1"));
        assert_eq!(v.build.as_deref(), Some("2.0"));
        assert_eq!(v.advisories, vec!["extra advisory line"]);
    }

    #[test]
    fn ping_bracketless_head_yields_no_estate_no_id() {
        // A head without brackets must not extract estate or estateId.
        // Swift's parsePong (BotLink.swift lines 210-219) gates BOTH fields
        // inside a single `if let open = …, let close = …, open < close` guard,
        // so a bracketless head yields estate=None AND estateId=None.
        // Without this guard the Rust code would emit the garbage string
        // " Foo is live — build 2.0" as the estate name.
        let v = parse_pong("pong: estate Foo is live — build 2.0");
        assert!(v.estate.is_none(), "no brackets → estate must be None");
        assert!(v.estate_id.is_none(), "no brackets → estate_id must be None");
        assert_eq!(v.build.as_deref(), Some("2.0"));
    }

    #[test]
    fn ping_empty_bracket_id_yields_estate_and_build_no_id() {
        // G-8 omission matrix case (d): an EMPTY bracket pair "[]" fills
        // estate and build but omits estateId — Swift guards each field
        // independently inside the bracket branch (`if !id.isEmpty`,
        // BotLink.swift:213), so an empty id is dropped while the name
        // beside it still parses.
        let v = parse_pong("pong: estate Foo [] is live — build 2.0");
        assert_eq!(v.estate.as_deref(), Some("Foo"), "estate must survive an empty id");
        assert!(v.estate_id.is_none(), "empty [] → estateId must be None");
        assert_eq!(v.build.as_deref(), Some("2.0"));
    }

    #[test]
    fn ping_is_error_true_returns_raw_result_exit_2() {
        // isError:true ping → raw result object, exit 2 (P-6).
        let result_obj = serde_json::json!({"isError": true, "content": [{"type":"text","text":"estate quiesced"}]});
        let resp = serde_json::json!({
            "jsonrpc": "2.0", "id": 2,
            "result": result_obj
        });
        let mut transport = make_transport("http", Some("http://127.0.0.1:0".into()), {
            let resp = resp.clone();
            move |_, _| Ok(Some(resp.clone()))
        });
        let outcome = ping_engine(&mut transport);
        assert_eq!(outcome.code, TOOL_ERROR);
        // stdout is the RAW result object, not ok:false shape.
        let stdout = outcome.stdout.unwrap();
        assert_eq!(stdout["isError"], Value::Bool(true));
        assert!(stdout.get("ok").is_none(), "ok:false shape must NOT appear for isError ping");
    }

    // ── List: pagination ───────────────────────────────────────────────────────

    #[test]
    fn list_two_pages_via_cursor_combined() {
        // Page 1 returns nextCursor "page2"; page 2 has no cursor → combined.
        let mut call_count = 0usize;
        let mut transport = make_transport("http", None, move |frame, _| {
            call_count += 1;
            let frame_str = std::str::from_utf8(frame).unwrap();
            let v: Value = serde_json::from_str(frame_str).unwrap();
            let id = v["id"].as_i64().unwrap();
            if call_count == 1 {
                Ok(Some(serde_json::json!({
                    "jsonrpc": "2.0", "id": id,
                    "result": {"tools": [{"name": "tool_a"}], "nextCursor": "page2"}
                })))
            } else {
                Ok(Some(serde_json::json!({
                    "jsonrpc": "2.0", "id": id,
                    "result": {"tools": [{"name": "tool_b"}]}
                })))
            }
        });
        let outcome = list_engine(&mut transport);
        assert_eq!(outcome.code, 0);
        let stdout = outcome.stdout.unwrap();
        let tools = stdout["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 2);
        assert_eq!(tools[0]["name"], "tool_a");
        assert_eq!(tools[1]["name"], "tool_b");
    }

    #[test]
    fn list_empty_string_cursor_terminates() {
        let mut transport = make_transport("http", None, |_, _| {
            Ok(Some(serde_json::json!({
                "jsonrpc": "2.0", "id": 2,
                "result": {"tools": [{"name": "only"}], "nextCursor": ""}
            })))
        });
        let outcome = list_engine(&mut transport);
        assert_eq!(outcome.code, 0);
        assert_eq!(outcome.stdout.unwrap()["tools"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn list_65_cursored_pages_exits_1() {
        let mut transport = make_transport("http", None, |frame, _| {
            let v: Value = serde_json::from_slice(frame).unwrap();
            let id = v["id"].as_i64().unwrap();
            Ok(Some(serde_json::json!({
                "jsonrpc": "2.0", "id": id,
                "result": {"tools": [], "nextCursor": "loop"}
            })))
        });
        let outcome = list_engine(&mut transport);
        assert_eq!(outcome.code, 1);
        let msg = outcome.stdout.unwrap()["error"].as_str().unwrap().to_string();
        assert!(msg.contains("64 pages"), "error must mention 64 pages: {msg}");
    }

    // ── Rpc ───────────────────────────────────────────────────────────────────

    #[test]
    fn rpc_notification_empty_stdout_exit_0() {
        // Frame with no "id" field → notification → Ok(None) from transport.
        let mut transport = make_transport("http", None, |_, expect_id| {
            assert!(expect_id.is_none(), "notification must send expect_id=None");
            Ok(None)
        });
        let frame = r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#;
        let outcome = rpc_engine(frame, &mut transport);
        assert_eq!(outcome.code, 0);
        assert!(outcome.stdout.is_none());
    }

    #[test]
    fn rpc_error_member_exit_1_stdout_is_response_frame_not_ok_false_shape() {
        // G-3: error-member response → exit 1, stdout = the response frame itself
        // via serialize_stdout (NOT the {"error":"…","ok":false} botLink shape).
        let error_resp = serde_json::json!({
            "jsonrpc": "2.0", "id": 5,
            "error": {"code": -32600, "message": "Invalid Request"}
        });
        let mut transport = make_transport("http", None, {
            let r = error_resp.clone();
            move |_, _| Ok(Some(r.clone()))
        });
        let frame = r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#;
        let outcome = rpc_engine(frame, &mut transport);
        assert_eq!(outcome.code, 1);
        let stdout_str = serialize_stdout(outcome.stdout.as_ref().unwrap());
        // G-3 positive byte-compare: stdout IS the response frame, one line,
        // sorted keys (error < id < jsonrpc; code < message inside error).
        assert_eq!(
            stdout_str,
            r#"{"error":{"code":-32600,"message":"Invalid Request"},"id":5,"jsonrpc":"2.0"}"#
        );
        // G-3 negative: and it is NOT the {"error":…,"ok":false} botLink shape.
        assert!(!stdout_str.contains(r#""ok":false"#), "G-3: must not be ok:false shape: {stdout_str}");
        // Must contain the protocol-level error.
        assert!(stdout_str.contains(r#""error""#));
        assert!(stdout_str.contains("Invalid Request"));
    }

    #[test]
    fn rpc_is_error_result_exit_2() {
        let resp = serde_json::json!({
            "jsonrpc": "2.0", "id": 1,
            "result": {"isError": true, "content": []}
        });
        let mut transport = make_transport("http", None, {
            let r = resp.clone();
            move |_, _| Ok(Some(r.clone()))
        });
        let frame = r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#;
        let outcome = rpc_engine(frame, &mut transport);
        assert_eq!(outcome.code, TOOL_ERROR);
    }

    #[test]
    fn rpc_string_id_value_equality() {
        // String-id frame → transport called with Some(String-value "myid") →
        // response with matching string id → outcome ok.
        let mut transport = make_transport("http", None, |frame, expect_id| {
            // Verify the transport received the string id.
            assert_eq!(expect_id, Some(&Value::String("myid".into())));
            let v: Value = serde_json::from_slice(frame).unwrap();
            let id = v["id"].clone();
            Ok(Some(serde_json::json!({
                "jsonrpc": "2.0", "id": id,
                "result": {"ok": true}
            })))
        });
        let frame = r#"{"jsonrpc":"2.0","id":"myid","method":"tools/call","params":{}}"#;
        let outcome = rpc_engine(frame, &mut transport);
        assert_eq!(outcome.code, 0);
    }

    #[test]
    fn rpc_not_json_object_exits_64() {
        let mut transport = make_transport("http", None, |_, _| Ok(None));
        let outcome = rpc_engine("not-json", &mut transport);
        assert_eq!(outcome.code, 64);
        let stdout_str = serialize_stdout(outcome.stdout.as_ref().unwrap());
        assert_eq!(stdout_str, r#"{"error":"rpc frame is not a JSON object","ok":false}"#);
    }

    // ── serialize_stdout: nested sorted keys, slashes unescaped ───────────────

    #[test]
    fn serialize_stdout_recursive_sort_and_unescaped_slashes() {
        let v = serde_json::json!({
            "z": {"b": 2, "a": 1},
            "a": {"url": "http://foo/bar"},
            "m": 42
        });
        let s = serialize_stdout(&v);
        // Outer keys: a, m, z (sorted).
        // Inner z: a, b (sorted).
        // Slashes in URL: must not be escaped.
        assert_eq!(
            s,
            r#"{"a":{"url":"http://foo/bar"},"m":42,"z":{"a":1,"b":2}}"#
        );
    }

    // ── P-2: transport select — bad --http + --db both set exits 64 ────────────

    #[test]
    fn p2_bad_http_with_db_still_exits_64() {
        // --http validated FIRST (P-2); a bad URL exits 64 even when --db is set.
        let result = resolve_transport(Some("https://127.0.0.1:4242"), Some("mydb"));
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().code, 64);
    }

    // ── parse_kv_arguments corner cases ──────────────────────────────────────

    #[test]
    fn kv_parse_positionals_skipped() {
        let tokens: Vec<String> = vec!["skip".into(), "--key".into(), "val".into(), "also_skip".into()];
        let v = parse_kv_arguments(&tokens);
        assert_eq!(v["key"], Value::String("val".into()));
        assert!(v.get("skip").is_none());
        assert!(v.get("also_skip").is_none());
    }

    #[test]
    fn kv_parse_bare_dash_dash_skipped() {
        let tokens: Vec<String> = vec!["--".into(), "--key".into(), "val".into()];
        let v = parse_kv_arguments(&tokens);
        assert_eq!(v["key"], Value::String("val".into()));
        assert!(v.get("").is_none());
    }

    #[test]
    fn kv_parse_integer_decodes() {
        let tokens: Vec<String> = vec!["--limit".into(), "10".into()];
        let v = parse_kv_arguments(&tokens);
        assert_eq!(v["limit"], serde_json::json!(10i64));
    }

    // ── G-7: empty estate name is omitted from stdout JSON ───────────────────

    #[test]
    fn g7_empty_estate_name_omitted() {
        // G-7 rationale: every fixture with a NAMED estate passes either a
        // "omit-vs-empty-string" implementation, because an omitted key and a
        // missing key both produce the same output when the name is non-empty
        // (it is always filled in). Only the empty-name case distinguishes
        // them: an implementation that emits `"estate":""` will produce a
        // different key set than the Swift reference, which omits unfillable
        // fields entirely. This test pins that behaviour with the verbatim
        // pong head observed from the live Swift daemon run:
        //   "pong: estate  [797B75F6-9685-4050-90B7-8A10085CA456] is live — build 20260812180424/6bae5a30"
        // Note the double space: the name between "pong: estate " and " [" is
        // the empty string. The expected key set is exactly
        // {build, endpoint, estateId, ok, transport} — NO "estate" key.
        let pong_text = "pong: estate  [797B75F6-9685-4050-90B7-8A10085CA456] is live \u{2014} build 20260812180424/6bae5a30";
        let resp = serde_json::json!({
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "content": [{"type": "text", "text": pong_text}],
                "isError": false
            }
        });
        let mut transport = make_transport("http", Some("http://127.0.0.1:4242".into()), {
            let resp = resp.clone();
            move |_, _| Ok(Some(resp.clone()))
        });
        let outcome = ping_engine(&mut transport);
        assert_eq!(outcome.code, 0);
        let stdout_str = serialize_stdout(outcome.stdout.as_ref().unwrap());
        // Exact byte comparison: "estate" key must be absent; key set is
        // {build, endpoint, estateId, ok, transport} in sorted order.
        assert_eq!(
            stdout_str,
            r#"{"build":"20260812180424/6bae5a30","endpoint":"http://127.0.0.1:4242","estateId":"797B75F6-9685-4050-90B7-8A10085CA456","ok":true,"transport":"http"}"#
        );
    }

    // ── P-10: rpc forwards caller's original bytes verbatim on the wire ───────

    #[test]
    fn p10_rpc_wire_bytes_verbatim() {
        // P-10 executed-reference contract: Swift's `rpc` passes caller bytes
        // through untouched — caller key order is preserved and slashes are
        // unescaped on the wire (`call`, by contrast, builds its own frame).
        // Note: in THIS crate serde_json has preserve_order enabled and never
        // escapes slashes, so a compact decode-and-re-encode of this exact
        // frame could coincidentally byte-match; the gate still pins the
        // verbatim-forward contract (frames with whitespace or non-compact
        // formatting would diverge under any re-encode).
        let canned_result = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 7,
            "result": {"content": [{"type": "text", "text": "ok"}], "isError": false}
        });
        let (port, bodies) = stub_server_capturing(vec![
            http_ok(canned_result.to_string().as_bytes()),
        ]);
        let mut transport = http_transport(port, format!("http://127.0.0.1:{port}"));

        // Deliberately non-sorted keys and a slash-bearing method — the Swift
        // reference forwards these bytes exactly (observed on the wire); the
        // sorted-stdout rule (P-11) governs stdout only, never the wire.
        let frame = r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"moot_foo"}}"#;
        let outcome = rpc_engine(frame, &mut transport);
        assert_eq!(outcome.code, 0);

        let captured = bodies.lock().unwrap();
        assert!(!captured.is_empty(), "stub must have received a request");
        // The body on the wire must be byte-identical to the input frame:
        // key order preserved (jsonrpc before id), slash in "tools/call"
        // unescaped (not "tools\/call").
        assert_eq!(
            captured[0],
            frame.as_bytes(),
            "rpc must forward caller bytes verbatim; decode-and-re-encode changes key order and escapes slashes"
        );
    }
}
