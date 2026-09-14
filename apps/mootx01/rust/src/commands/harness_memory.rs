//! commands/harness_memory.rs — `mootx01 enable/disable harness-memory` and
//! `mootx01 hook-capture` implementation.
//!
//! Harness Memory Mode routes Claude Code's in-session memory writes into the
//! MOOTx01 estate rather than to `~/.claude/projects/*/memory/` on disk.
//!
//! Three moving parts:
//!   1. **Settings** — disables Claude Code's built-in auto-memory
//!      (`autoMemoryEnabled: false` in `~/.claude/settings.json`) and installs
//!      a PreToolUse hook that intercepts Write/Edit/MultiEdit calls targeting
//!      the project-memory directory.
//!   2. **Sentinel block** — merges governance text into `~/.claude/CLAUDE.md`
//!      so the harness learns the correct MCP verbs at session start.
//!   3. **Capture hook** — `mootx01 hook-capture` reads the Claude Code
//!      PreToolUse stdin payload, posts the memory to the estate, then denies
//!      the disk write with a teaching message. If the daemon is unreachable,
//!      it allows the disk write (losing the memory is worse than a stray file;
//!      the ingest sweep picks up stragglers).
//!
//! Metric emit points (consumed by MXE-HM-2 observability wiring):
//!   - `harness_memory.enable` — on successful enable
//!   - `harness_memory.disable` — on successful disable
//!   - `harness_memory.ingest.filed` / `.matched` / `.removed` / `.skipped`
//!   - `harness_memory.restore.written`
//!   - `harness_memory.capture.ok` / `.fallback` / `.bypass`  (hook-capture)

use std::fmt;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

// ─── Platform paths ──────────────────────────────────────────────────────────

/// Path to the Claude Code configuration directory.
///
/// - Linux/macOS: `~/.claude`
/// - Windows: `%USERPROFILE%\.claude`
pub fn claude_config_dir() -> PathBuf {
    home_dir().join(".claude")
}

/// Path to the installed harness-memory capture hook script.
///
/// Shell script on Unix; batch file on Windows.
pub fn harness_hook_script_path() -> PathBuf {
    #[cfg(target_os = "windows")]
    { home_dir().join(".mootx01").join("hooks").join("capture-harness-memory.bat") }
    #[cfg(not(target_os = "windows"))]
    { home_dir().join(".mootx01").join("hooks").join("capture-harness-memory.sh") }
}

fn home_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    { std::env::var("USERPROFILE").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(".")) }
    #[cfg(not(target_os = "windows"))]
    { std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(".")) }
}

// ─── Time utilities ───────────────────────────────────────────────────────────

/// Current UTC time as ISO 8601 string (e.g. `"2026-08-07T14:30:00Z"`).
pub(crate) fn now_iso8601() -> String {
    unix_secs_to_iso8601(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    )
}

/// Convert Unix epoch seconds to an ISO 8601 UTC string.
///
/// Uses Howard Hinnant's civil-calendar algorithm (valid for all Gregorian
/// dates). No external dependency — mirrors the `civil_from_days` helper in
/// `core::merge`.
pub(crate) fn unix_secs_to_iso8601(secs: u64) -> String {
    let sec = secs % 60;
    let min = (secs / 60) % 60;
    let hour = (secs / 3600) % 24;
    let (y, m, d) = civil_from_days((secs / 86_400) as i64);
    format!("{y:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}Z")
}

/// Compact UTC timestamp for backup filenames (`YYYYMMDD-HHMMSS`).
fn compact_timestamp_utc() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (y, m, d) = civil_from_days((secs / 86_400) as i64);
    let rem = secs % 86_400;
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    format!("{y:04}{m:02}{d:02}-{hh:02}{mm:02}{ss:02}")
}

/// Civil-calendar (year, month, day) from days since Unix epoch.
///
/// Howard Hinnant's algorithm: <https://howardhinnant.github.io/date_algorithms.html>
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468; // shift epoch to 0000-03-01 for uniform leap-year handling
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // year of era [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
    let mp = (5 * doy + 2) / 153; // month period [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // day [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // month [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// ─── DaemonHttp trait (seam for unit testing) ─────────────────────────────────

/// Minimal HTTP client contract for estate MCP calls.
///
/// The real implementation delegates to `core::daemon_client`; tests inject a
/// mock so no live daemon is required for unit tests.
pub trait DaemonHttp: Send + Sync {
    /// Whether the daemon answers on the given port (fast TCP connect check).
    fn alive(&self, port: u16) -> bool;
    /// POST one JSON-RPC frame; returns `(status_code, body_bytes)`.
    fn post_frame(&self, port: u16, frame: &[u8]) -> io::Result<(u16, Vec<u8>)>;
}

/// Production implementation: delegates to `core::daemon_client`.
///
/// Use for ingest, restore, enable, and disable — paths where the 3600s read
/// timeout in `daemon_client::post_frame` is intentional (long lens/synthesis
/// calls can legitimately take minutes).
pub struct LiveDaemon;

impl DaemonHttp for LiveDaemon {
    fn alive(&self, port: u16) -> bool {
        crate::core::daemon_client::alive(port)
    }
    fn post_frame(&self, port: u16, frame: &[u8]) -> io::Result<(u16, Vec<u8>)> {
        crate::core::daemon_client::post_frame(port, frame)
    }
}

// ─── Hook-path HTTP client ─────────────────────────────────────────────────────

/// Connect timeout (seconds) for the hook-path HTTP client.
///
/// The hook runs inline in Claude Code's PreToolUse dispatch. A long timeout
/// would freeze the Claude Code session while waiting for a slow or unreachable
/// daemon. The serve path (LiveDaemon via daemon_client) intentionally keeps
/// 3600s for long lens calls; hook intercepts must resolve fast or fall through
/// to the allow-through path.
pub const HOOK_CONNECT_TIMEOUT_SECS: u64 = 2;

/// Read timeout (seconds) for the hook-path HTTP client.
/// See `HOOK_CONNECT_TIMEOUT_SECS` for rationale.
pub const HOOK_READ_TIMEOUT_SECS: u64 = 2;

/// Short-timeout HTTP POST for the hook path.
///
/// connect_timeout = HOOK_CONNECT_TIMEOUT_SECS, read_timeout = HOOK_READ_TIMEOUT_SECS.
/// On timeout, returns `Err` — the caller's existing allow-through fallback handles it.
/// The response parsing mirrors `daemon_client::post_frame` exactly.
fn hook_post_frame(port: u16, frame: &[u8]) -> io::Result<(u16, Vec<u8>)> {
    use std::net::TcpStream;
    use std::time::Duration;

    let mut stream = TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_secs(HOOK_CONNECT_TIMEOUT_SECS),
    )?;
    stream.set_read_timeout(Some(Duration::from_secs(HOOK_READ_TIMEOUT_SECS)))?;

    let mut request = format!(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        frame.len()
    )
    .into_bytes();
    request.extend_from_slice(frame);
    stream.write_all(&request)?;
    stream.flush()?;

    let mut raw = Vec::new();
    stream.read_to_end(&mut raw)?;

    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(raw.len());
    let head = String::from_utf8_lossy(&raw[..split.min(raw.len())]);
    let status: u16 = head
        .lines()
        .next()
        .and_then(|l| l.split(' ').nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let mut body = raw[split.min(raw.len())..].to_vec();
    if let Some(len) = head
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
        .and_then(|l| l.split(':').nth(1))
        .and_then(|v| v.trim().parse::<usize>().ok())
    {
        body.truncate(len);
    }
    Ok((status, body))
}

/// Hook-path `DaemonHttp` implementation: 2s connect + 2s read timeouts.
///
/// Use exclusively for `hook_capture` (via `hook_decide` and `capture_decision`).
/// The in-session hook MUST NOT freeze Claude Code; on any error the caller
/// falls through to the allow-through path. The serve path (LiveDaemon) keeps
/// its 3600s timeout for long lens/synthesis calls.
pub struct HookLiveDaemon;

impl DaemonHttp for HookLiveDaemon {
    fn alive(&self, port: u16) -> bool {
        // daemon_client::alive uses a 250ms TCP connect check — fast enough for hook.
        crate::core::daemon_client::alive(port)
    }
    fn post_frame(&self, port: u16, frame: &[u8]) -> io::Result<(u16, Vec<u8>)> {
        hook_post_frame(port, frame)
    }
}

// ─── Settings.json pure functions ────────────────────────────────────────────
//
// All functions take and return a `serde_json::Value` (the parsed settings
// document) — no filesystem I/O so they are fully unit-testable.

/// Return true when Harness Memory Mode is already active in these settings.
///
/// Checks two conditions:
///   a) `autoMemoryEnabled` is `false`
///   b) our hook entry (identified by `hook_script_path`) is present in
///      `hooks.PreToolUse`
///
/// Both must be true; partial state (e.g. hook present but auto-memory not
/// disabled) is treated as not-yet-enabled and the enable command re-runs
/// the merge to reach the fully-enabled state.
pub fn is_harness_memory_enabled(settings: &Value, hook_script_path: &str) -> bool {
    let auto_off = settings
        .get("autoMemoryEnabled")
        .and_then(|v| v.as_bool())
        .map(|b| !b) // autoMemoryEnabled:false → we want it off → true
        .unwrap_or(false);
    auto_off && hook_entry_present(settings, hook_script_path)
}

/// Merge Harness Memory Mode settings into `current`.
///
/// Sets `autoMemoryEnabled: false` and appends our PreToolUse hook entry
/// (idempotent — re-running when already enabled is a no-op).
pub fn merge_settings(mut current: Value, hook_script_path: &str) -> Value {
    // Set auto-memory to false (key verified against Claude Code docs: A1
    // resolution — key is "autoMemoryEnabled"; env alt CLAUDE_CODE_DISABLE_AUTO_MEMORY=1).
    current["autoMemoryEnabled"] = json!(false);

    // Ensure hooks.PreToolUse exists as an array.
    let hooks_obj = current
        .as_object_mut()
        .expect("settings must be a JSON object");
    let hooks = hooks_obj
        .entry("hooks")
        .or_insert_with(|| json!({}));
    let pre_tool_use = hooks
        .as_object_mut()
        .expect("hooks must be an object")
        .entry("PreToolUse")
        .or_insert_with(|| json!([]));
    let arr = pre_tool_use
        .as_array_mut()
        .expect("hooks.PreToolUse must be an array");

    // Idempotent: only add if our entry is absent.
    if !arr.iter().any(|e| entry_owns_hook(e, hook_script_path)) {
        arr.push(json!({
            // Matcher is a pipe-separated tool name string (Claude Code PreToolUse shape).
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [{
                "type": "command",
                // Full absolute path: identifiable as ours by the .mootx01/hooks/ prefix.
                // No "args" key — byte-matches Swift's addHookEntry shape (HarnessMemory.swift).
                "command": hook_script_path
            }]
        }));
    }

    current
}

/// Remove Harness Memory Mode settings from `current`.
///
/// Removes our hook entry from `hooks.PreToolUse` (leaving all other entries
/// intact) and removes `autoMemoryEnabled: false` (restores default, which is
/// auto-memory enabled). If `PreToolUse` becomes empty, the key is left as an
/// empty array (clean JSON; callers may prune if desired).
pub fn unmerge_settings(mut current: Value, hook_script_path: &str) -> Value {
    // Remove autoMemoryEnabled if it is currently false (our setting).
    // If the user had set it to false independently, they must re-set it — we
    // cannot distinguish our write from theirs without a separate state file.
    if current
        .get("autoMemoryEnabled")
        .and_then(|v| v.as_bool())
        .map(|b| !b)
        .unwrap_or(false)
    {
        current
            .as_object_mut()
            .unwrap()
            .remove("autoMemoryEnabled");
    }

    // Remove exactly our hook entry, leave others untouched.
    if let Some(arr) = current
        .pointer_mut("/hooks/PreToolUse")
        .and_then(|v| v.as_array_mut())
    {
        arr.retain(|e| !entry_owns_hook(e, hook_script_path));
    }

    current
}

/// True when this `hooks.PreToolUse` entry belongs to our harness hook script.
///
/// Checks ALL hooks in the group (not just the first) — mirrors Swift's
/// `hasHookEntry` which uses `innerHooks.contains { … }`. A multi-command group
/// that contains our command path is still "ours" and must be removed on disable.
fn entry_owns_hook(entry: &Value, hook_script_path: &str) -> bool {
    entry
        .get("hooks")
        .and_then(|h| h.as_array())
        .map(|arr| {
            arr.iter().any(|h| {
                h.get("command")
                    .and_then(|c| c.as_str())
                    .map(|c| c == hook_script_path)
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// True when `entry_owns_hook` matches for at least one entry in
/// `settings.hooks.PreToolUse`.
fn hook_entry_present(settings: &Value, hook_script_path: &str) -> bool {
    settings
        .pointer("/hooks/PreToolUse")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().any(|e| entry_owns_hook(e, hook_script_path)))
        .unwrap_or(false)
}

// ─── CLAUDE.md sentinel block ─────────────────────────────────────────────────

const SENTINEL_BEGIN: &str = "<!-- mootx01:harness-memory:begin -->";
const SENTINEL_END: &str = "<!-- mootx01:harness-memory:end -->";

/// Teaching block merged into `~/.claude/CLAUDE.md` while Harness Memory Mode
/// is active. Marks memory governance up-front so the agent learns the correct
/// MCP verbs at session start rather than discovering the hook at write time.
///
/// The hook (hook-capture) is the in-the-moment corrector; this block is the
/// up-front teacher. Hook fire-rate decaying over time is the signal the
/// teaching works (MXE-HM-2 observability).
///
/// IMPORTANT: This text is byte-identical to `HarnessMemoryCLAUDE.block` in
/// HarnessMemory.swift (lines 279-292). The Swift text is canonical — any
/// change must be applied to both ports simultaneously. A Rust test pins this
/// invariant.
const SENTINEL_CONTENT: &str = "\n\
# Memory Governance — MOOTx01 Harness Memory Mode\n\
\n\
File memories with `moot_file_memory` (location: `harness/<project>/<name>`) and recall\n\
them with `moot_memory_search` / `moot_recall_*`. Do NOT write markdown files to\n\
`~/.claude/projects/*/memory/` — those writes are intercepted and routed to the estate.\n\
\n\
The estate provides semantic recall, temporal grading, contradiction hunting, and\n\
cross-session linking that the flat project-memory directory never had.\n";

/// True when `content` already contains our sentinel markers.
pub fn has_sentinel(content: &str) -> bool {
    content.contains(SENTINEL_BEGIN)
}

/// Append the harness-memory governance block to `content` (idempotent).
///
/// If the sentinel block is already present, the content is returned unchanged
/// so calling `install_sentinel` twice is safe.
pub fn install_sentinel(content: &str) -> String {
    if has_sentinel(content) {
        return content.to_string();
    }
    // Ensure exactly one blank line between existing content and our block.
    let base = content.trim_end_matches('\n');
    format!(
        "{}\n\n{}\n{}{}\n",
        base, SENTINEL_BEGIN, SENTINEL_CONTENT, SENTINEL_END
    )
}

/// Remove the harness-memory governance block from `content` (idempotent).
///
/// Strips everything between (and including) the sentinel markers. Content
/// outside the block is preserved exactly.
pub fn remove_sentinel(content: &str) -> String {
    let Some(begin_pos) = content.find(SENTINEL_BEGIN) else {
        return content.to_string(); // not present — no-op
    };
    let end_marker = content[begin_pos..]
        .find(SENTINEL_END)
        .map(|p| p + begin_pos + SENTINEL_END.len());
    let after = match end_marker {
        Some(pos) => &content[pos..],
        None => "", // malformed (begin but no end): remove from begin to EOF
    };
    // Strip leading newlines that were inserted before the block.
    let before = content[..begin_pos].trim_end_matches('\n');
    let after = after.trim_start_matches('\n');
    if after.is_empty() {
        format!("{}\n", before)
    } else {
        format!("{}\n\n{}", before, after)
    }
}

// ─── Hook script template ─────────────────────────────────────────────────────

/// Generate the capture hook script content for the current platform.
///
/// - `binary_path`: absolute path to the installed `mootx01` binary (e.g.
///   `~/.mootx01/bin/mootx01`). The script executes this path directly rather
///   than relying on `mootx01` being on `PATH`, so the hook works even when the
///   shell PATH inside the hook env differs from the user's interactive PATH.
///   Mirrors Swift `HarnessMemoryHook.scriptContent(binaryPath:)` (line 395).
#[cfg(not(target_os = "windows"))]
pub fn hook_script_content(binary_path: &str) -> String {
    format!(
        "#!/usr/bin/env sh\n\
         # capture-harness-memory.sh\n\
         # Installed by `mootx01 enable harness-memory`. Do not edit manually.\n\
         # Remove with: `mootx01 disable harness-memory`\n\
         exec \"{binary_path}\" hook-capture\n"
    )
}

#[cfg(target_os = "windows")]
pub fn hook_script_content(binary_path: &str) -> String {
    format!(
        "@echo off\r\n\
         :: capture-harness-memory.bat\r\n\
         :: Installed by `mootx01 enable harness-memory`. Do not edit manually.\r\n\
         :: Remove with: `mootx01 disable harness-memory`\r\n\
         \"{binary_path}\" hook-capture\r\n"
    )
}

// ─── Settings file I/O helpers ────────────────────────────────────────────────

/// Read and parse `~/.claude/settings.json`.  Returns an empty object when
/// the file is absent (first enable — the file will be created).
pub fn read_settings(settings_path: &Path) -> Result<Value, String> {
    if !settings_path.exists() {
        return Ok(json!({}));
    }
    let bytes = fs::read(settings_path).map_err(|e| format!("read settings: {e}"))?;
    serde_json::from_slice(&bytes)
        .map_err(|e| format!("parse settings.json: {e} — run with --yes to skip backup checks"))
}

/// Write a pretty-printed settings object to disk (2-space indent, no trailing
/// spaces — serde_json default is acceptable; Swift JSONSerialization output
/// differs only in whitespace conventions, not semantics).
pub fn write_settings(settings_path: &Path, value: &Value) -> Result<(), String> {
    if let Some(dir) = settings_path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("create settings dir: {e}"))?;
    }
    let pretty = serde_json::to_string_pretty(value).map_err(|e| format!("serialize: {e}"))?;
    fs::write(settings_path, pretty.as_bytes()).map_err(|e| format!("write settings: {e}"))
}

/// Copy `path` to `<path>.mootx01-bak-<ISO8601>` beside it.
///
/// Returns the backup path. Called before the first write during `enable`.
pub fn backup_settings(path: &Path) -> Result<PathBuf, String> {
    let stamp = compact_timestamp_utc();
    let file_name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("settings.json");
    let backup = path.with_file_name(format!("{file_name}.mootx01-bak-{stamp}"));
    fs::copy(path, &backup).map_err(|e| format!("backup settings: {e}"))?;
    Ok(backup)
}

// ─── MCP call helpers ─────────────────────────────────────────────────────────

/// A full estate memory record, as read from `moot_memory_get`.
///
/// Mirrors `HarnessMemoryRecord` in Swift's `LiveDaemonClient`. A v2
/// `moot_memory_list` row carries only `memory_id/fetch/subject/provenance`,
/// so `estate_list` collects ids across every page and completes them with
/// `estate_get_batch` (`moot_memory_get` with `memory_ids`, 50 per call).
/// `estate_get` completes a single id the same way. Both read
/// `placement.room` (location), `content`, and `state` from the full record.
#[derive(Debug, Clone, PartialEq, Eq)]
struct EstateRecord {
    id: String,
    location: String,
    content: String,
    is_superseded: bool,
}

/// Why an estate call failed.
///
/// Callers that only need a message use `to_string()`; callers that branch
/// on the refusal (`estate_list` restarts on a stale cursor, `estate_get`
/// treats `memory_not_found` as "no row") match on `Refused { code, .. }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonCallError {
    /// The frame did not reach the daemon or came back unreadable: a network
    /// error, a non-200 status, or a body that is not the expected JSON.
    Transport(String),
    /// The daemon answered HTTP 200 and refused the call. An ARIA v2 refusal
    /// carries `result.isError: true` and `result.structuredContent.error`
    /// `{code, message}` with no `data`; `code` is empty when the refusal
    /// names none. A top-level JSON-RPC `error` object maps to code
    /// `rpc_error` with its message.
    Refused { code: String, message: String },
}

impl fmt::Display for DaemonCallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DaemonCallError::Transport(msg) => write!(f, "{msg}"),
            DaemonCallError::Refused { code, message } if code.is_empty() => write!(f, "refused: {message}"),
            DaemonCallError::Refused { code, message } => write!(f, "refused ({code}): {message}"),
        }
    }
}

/// POST one JSON-RPC 2.0 `tools/call` frame to the estate daemon.
///
/// `tool_name` is the ARIA tool name (`moot_file_memory`, `moot_memory_get`,
/// `moot_memory_list`, …). `args` is the tool's `arguments` object.
/// Returns the parsed body when the daemon accepted the call. A refusal is an
/// `Err(Refused)` even though it arrives as HTTP 200: a refused `moot_memory_list`
/// is never an empty wing, and a refused `moot_file_memory` is never a filed row.
fn call_tool(daemon: &dyn DaemonHttp, port: u16, tool_name: &str, args: Value) -> Result<Value, DaemonCallError> {
    let frame = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": args}
    });
    let bytes = serde_json::to_vec(&frame).map_err(|e| DaemonCallError::Transport(e.to_string()))?;
    let (status, body) = daemon
        .post_frame(port, &bytes)
        .map_err(|e| DaemonCallError::Transport(e.to_string()))?;
    if status != 200 {
        let msg = String::from_utf8_lossy(&body).into_owned();
        return Err(DaemonCallError::Transport(format!("daemon returned HTTP {status}: {msg}")));
    }
    let resp = serde_json::from_slice::<Value>(&body).map_err(|e| DaemonCallError::Transport(e.to_string()))?;
    if let Some(err) = resp.get("error") {
        return Err(DaemonCallError::Refused {
            code: "rpc_error".to_string(),
            message: err["message"].as_str().unwrap_or("").to_string(),
        });
    }
    let result = &resp["result"];
    let refusal = result.pointer("/structuredContent/error");
    if refusal.is_some() || result["isError"].as_bool() == Some(true) {
        let code = refusal.and_then(|e| e["code"].as_str()).unwrap_or("").to_string();
        let message = refusal
            .and_then(|e| e["message"].as_str())
            .or_else(|| result.pointer("/content/0/text").and_then(|t| t.as_str()))
            .unwrap_or("")
            .to_string();
        return Err(DaemonCallError::Refused { code, message });
    }
    Ok(resp)
}

/// File one memory entry to the estate via `moot_file_memory`.
///
/// - `location`: estate location hint, e.g. `harness-import/<slug>/<name>`.
///   No `/memories/` prefix — the ARIA tool accepts the bare location.
/// - `content`: verbatim file body (byte-exact for restore round-trips)
/// - `subject`: one-line telegraphic assertion (≤120 chars) for recall result
///   lists. Required by the estate since PR-02.
/// - `event_time`: ISO 8601 UTC string (typically the source file's mtime)
/// - `kind`: `"list"` for MEMORY.md index files, `"prose"` otherwise
///
/// Mirrors Swift `LiveDaemonClient.fileMemory(location:content:subject:eventTime:kind:)`.
fn estate_file(
    daemon: &dyn DaemonHttp,
    port: u16,
    location: &str,
    content: &str,
    subject: &str,
    event_time: &str,
    kind: &str,
) -> Result<(), String> {
    // MXE-HM-2: harness_memory.ingest.filed metric emit point.
    call_tool(daemon, port, "moot_file_memory", json!({
        "location": location,
        "content": content,
        "subject": subject,
        "event_time": event_time,
        "kind": kind,
    }))
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Generate a subject line for estate filing from file content.
///
/// Returns the first non-blank, non-heading (`#`) line of `content`, trimmed
/// and truncated to 120 characters. Falls back to the filename stem (dropping
/// `.md` extension) when the content contains only blank lines or headings.
/// The 120-char cap matches the estate's subject length contract.
///
/// Mirrors Swift `HarnessMemoryIngest.extractSubject(from:fileName:)`.
pub fn extract_subject(content: &str, filename: &str) -> String {
    if let Some(line) = content.lines().find(|l| {
        let trimmed = l.trim();
        !trimmed.is_empty() && !trimmed.starts_with('#')
    }) {
        let trimmed = line.trim();
        return trimmed.chars().take(120).collect();
    }
    // Fallback: filename stem when content is all headings or blank lines.
    let stem = filename.strip_suffix(".md").unwrap_or(filename);
    stem.chars().take(120).collect()
}

/// Parse one element of `data.memories` from a `moot_memory_get` body.
///
/// Shared by `estate_get` and `estate_get_batch` so both read the same keys:
/// `memory_id`, `placement.room` (the original location string, e.g.
/// `harness-import/slug/file.md`), `content`, and `state`
/// (`"active"` or `"superseded"`).
fn parse_estate_record(item: &Value) -> Option<EstateRecord> {
    let id = item["memory_id"].as_str()?.to_string();
    let location = item.pointer("/placement/room")?.as_str()?.to_string();
    let content = item["content"].as_str().unwrap_or("").to_string();
    let is_superseded = item["state"].as_str() == Some("superseded");
    Some(EstateRecord { id, location, content, is_superseded })
}

/// Fetch the full memory record for a single id via `moot_memory_get`.
///
/// The v2 `moot_memory_list` row carries only `memory_id/fetch/subject/provenance`
/// (additionalProperties:false). Location and content require this follow-up call,
/// which reads `placement.room` (original location string), `content`, and
/// `state` from the full structured record.
///
/// `Ok(None)` only when the daemon refuses with code `memory_not_found`, which
/// it answers for an unknown id and for a superseded one. Every other failure
/// (transport, malformed body, any other refusal) is returned as `Err`.
fn estate_get(daemon: &dyn DaemonHttp, port: u16, memory_id: &str) -> Result<Option<EstateRecord>, DaemonCallError> {
    match call_tool(daemon, port, "moot_memory_get", json!({ "memory_id": memory_id })) {
        Ok(resp) => {
            // v2 envelope: result.structuredContent.data.memories[0]
            let item = resp
                .pointer("/result/structuredContent/data/memories/0")
                .ok_or_else(|| DaemonCallError::Transport("malformed moot_memory_get body: no memories[0]".to_string()))?;
            parse_estate_record(item)
                .map(Some)
                .ok_or_else(|| DaemonCallError::Transport(format!("malformed moot_memory_get record for {memory_id}")))
        }
        Err(DaemonCallError::Refused { code, .. }) if code == "memory_not_found" => Ok(None),
        Err(e) => Err(e),
    }
}

/// Maximum `memory_ids` per `moot_memory_get` call (server limit).
const ESTATE_GET_BATCH_SIZE: usize = 50;

/// Fetch full records for many ids via `moot_memory_get` with `memory_ids`.
///
/// Sends `ceil(n / 50)` calls of at most `ESTATE_GET_BATCH_SIZE` ids. Every
/// element of `data.memories` is parsed with `parse_estate_record`. A refusal
/// is returned. A chunk that answers fewer records than it was asked for is
/// returned as `Refused { code: "memory_not_found" }` naming the missing ids:
/// no record is ever dropped silently. Order follows the server's order within
/// each chunk.
fn estate_get_batch(daemon: &dyn DaemonHttp, port: u16, ids: &[String]) -> Result<Vec<EstateRecord>, DaemonCallError> {
    let mut records = Vec::new();
    for chunk in ids.chunks(ESTATE_GET_BATCH_SIZE) {
        let resp = call_tool(daemon, port, "moot_memory_get", json!({ "memory_ids": chunk }))?;
        let arr = resp
            .pointer("/result/structuredContent/data/memories")
            .and_then(|v| v.as_array())
            .ok_or_else(|| DaemonCallError::Transport("malformed moot_memory_get batch: no memories array".to_string()))?;
        let parsed: Vec<EstateRecord> = arr.iter().filter_map(parse_estate_record).collect();
        if parsed.len() < chunk.len() {
            let got: std::collections::HashSet<&str> = parsed.iter().map(|r| r.id.as_str()).collect();
            let missing: Vec<&str> = chunk.iter().map(String::as_str).filter(|id| !got.contains(id)).collect();
            return Err(DaemonCallError::Refused {
                code: "memory_not_found".to_string(),
                message: format!(
                    "batch answered {} of {} records; missing: {}",
                    parsed.len(),
                    chunk.len(),
                    missing.join(", ")
                ),
            });
        }
        records.extend(parsed);
    }
    Ok(records)
}

/// Page size requested from `moot_memory_list` (server maximum).
const ESTATE_LIST_PAGE_SIZE: u64 = 200;

/// How many times a stale or expired cursor restarts the enumeration before
/// the refusal is returned to the caller.
const ESTATE_LIST_MAX_RESTARTS: usize = 3;

/// List estate records whose location begins with `location_prefix` via
/// `moot_memory_list`, then complete them with `estate_get_batch`.
///
/// Only active rows exist on the wire: the server omits superseded rows from
/// `moot_memory_list`. The listing is complete across pages: each call asks for
/// `limit` 200 and the loop re-sends with `cursor = next_cursor` while
/// `has_more` is true. A refusal with code `cursor_stale` or `cursor_expired`
/// discards the ids collected so far and restarts without a cursor, at most
/// `ESTATE_LIST_MAX_RESTARTS` times; any other refusal is returned. A page
/// whose `data` lacks `memories` or `has_more` is `Transport("malformed page")`,
/// never an empty page. A `next_cursor` already seen at any earlier page — not
/// only the immediately previous one — is the same `Transport("malformed
/// page")` error: a server alternating between cursors (c1, c2, c1, …) cannot
/// spin this client forever. Errors from `estate_get_batch` are returned as-is.
///
/// ARIA v2: file memories are stored in the "Agentic Memory" wing regardless
/// of their location prefix; `room` equals the full location string. Strip
/// leading slashes before matching so both "/" and "" return empty rather than
/// sending wing="" (server rejects minLength:1). For an exact file location
/// (3+ components, no trailing slash) supply the full prefix as `room`; for a
/// directory prefix (trailing slash) omit `room` and filter client-side.
fn estate_list(daemon: &dyn DaemonHttp, port: u16, location_prefix: &str) -> Result<Vec<EstateRecord>, DaemonCallError> {
    // Normalize: strip leading slashes so both ports agree on every input shape.
    let prefix = location_prefix.trim_start_matches('/');
    if prefix.is_empty() {
        return Ok(Vec::new());
    }
    let ends_with_slash = location_prefix.ends_with('/');
    let component_count = prefix.split('/').count();
    // Supply `room` only for exact file lookups (3+ segments, no trailing slash).
    let base_args = if !ends_with_slash && component_count >= 3 {
        json!({ "wing": "Agentic Memory", "room": prefix, "limit": ESTATE_LIST_PAGE_SIZE })
    } else {
        json!({ "wing": "Agentic Memory", "limit": ESTATE_LIST_PAGE_SIZE })
    };
    let malformed = || DaemonCallError::Transport("malformed page".to_string());

    // Walk every page, collecting ids. Each row carries only memory_id/fetch/
    // subject/provenance; estate_get_batch supplies location, content, state.
    let mut ids: Vec<String> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut cursor: Option<String> = None;
    // Every cursor this call has walked, not just the immediately previous
    // one. A server alternating between cursors (c1, c2, c1, c2, …) would
    // pass a single-value comparison against `cursor` forever; tracking the
    // whole set catches the repeat on its second appearance, matching the
    // Swift twin's `seenCursors` (HarnessMemory.swift).
    let mut seen_cursors = std::collections::HashSet::new();
    let mut restarts = 0usize;
    loop {
        let mut args = base_args.clone();
        if let Some(c) = &cursor {
            args["cursor"] = json!(c);
        }
        let resp = match call_tool(daemon, port, "moot_memory_list", args) {
            Ok(resp) => resp,
            Err(DaemonCallError::Refused { code, message })
                if code == "cursor_stale" || code == "cursor_expired" =>
            {
                // The inventory moved under the cursor: start over from the
                // first page so the listing stays complete.
                if restarts >= ESTATE_LIST_MAX_RESTARTS {
                    return Err(DaemonCallError::Refused { code, message });
                }
                restarts += 1;
                ids.clear();
                seen.clear();
                cursor = None;
                seen_cursors.clear();
                continue;
            }
            Err(e) => return Err(e),
        };
        // v2 envelope: result.structuredContent.data.{memories, has_more, next_cursor}
        let data = resp.pointer("/result/structuredContent/data").ok_or_else(malformed)?;
        let arr = data["memories"].as_array().ok_or_else(malformed)?;
        let has_more = data["has_more"].as_bool().ok_or_else(malformed)?;
        for item in arr {
            if let Some(memory_id) = item["memory_id"].as_str() {
                // The server never repeats an id across pages; the set guards the
                // batch call, which rejects duplicate memory_ids.
                if seen.insert(memory_id.to_string()) {
                    ids.push(memory_id.to_string());
                }
            }
        }
        if !has_more {
            break;
        }
        // has_more without a fresh cursor cannot be walked; report it rather
        // than return the pages read so far as the whole wing. A cursor already
        // seen — at any earlier page, not just the immediately previous one —
        // fails the same way: a server alternating cursors cannot spin this
        // client forever.
        let next = data["next_cursor"].as_str().map(str::to_string);
        match next {
            Some(next) if seen_cursors.insert(next.clone()) => {
                cursor = Some(next);
            }
            _ => return Err(malformed()),
        }
    }

    // Client-side prefix filter for directory queries where room was omitted.
    Ok(estate_get_batch(daemon, port, &ids)?
        .into_iter()
        .filter(|record| record.location.starts_with(prefix))
        .collect())
}

// ─── Restore front matter ─────────────────────────────────────────────────────

/// Front-matter key that carries the estate memory id on a restored file.
///
/// Nested under `metadata:` with a two-space indent, matching the shape of
/// the `metadata:` mapping that Claude Code memory files already carry.
const FRONT_MATTER_ID_KEY: &str = "moot_memory_id";

/// Front-matter key that marks a `MEMORY.md` written by `regenerate_memory_index`
/// rather than captured from the estate or authored by hand. `ingest_project`
/// discards a marked index instead of filing it, so a disable → enable cycle
/// never adds an estate row for a slug that has no captured index. Shared
/// with Swift `HarnessMemoryFrontMatter.generatedIndexKey`.
pub const FRONT_MATTER_GENERATED_INDEX_KEY: &str = "moot_generated_index";

/// Byte offset of line `index` within `text` when `text` is split on `\n`.
fn line_offset(text: &str, index: usize) -> usize {
    text.split('\n').take(index).map(|l| l.len() + 1).sum()
}

/// Inject the estate `memory_id` into a restored file's YAML front matter.
///
/// Thin wrapper over `front_matter_inject_field` for the key
/// `moot_memory_id`. `front_matter_strip` is the exact byte inverse. Mirrors
/// Swift `HarnessMemoryFrontMatter.inject`.
pub fn front_matter_inject(content: &str, memory_id: &str) -> String {
    front_matter_inject_field(content, FRONT_MATTER_ID_KEY, memory_id)
}

/// Inject the line `  <key>: <value>` into a file's YAML front matter
/// `metadata:` mapping.
///
/// Line-based, `\n` only. Three cases:
///   1. A block is present (first line `---`, a later line exactly `---`) and
///      a line exactly `metadata:` exists inside it: insert
///      `  <key>: <value>` immediately after that `metadata:` line.
///   2. A block is present without `metadata:`: insert the two lines
///      `metadata:` and `  <key>: <value>` immediately before the
///      closing `---`.
///   3. No block (MEMORY.md, or any file without front matter): prepend the
///      three-line header `---\nmetadata:\n  <key>: <value>\n---\n`.
///
/// `front_matter_strip_field` with the same key is the exact byte inverse.
/// Mirrors Swift `HarnessMemoryFrontMatter.inject(field:)`.
pub fn front_matter_inject_field(content: &str, key: &str, value: &str) -> String {
    let id_line = format!("  {key}: {value}");
    if let Some(rest) = content.strip_prefix("---\n") {
        let lines: Vec<&str> = rest.split('\n').collect();
        if let Some(close) = lines.iter().position(|l| *l == "---") {
            let mut out = String::from("---\n");
            match lines[..close].iter().position(|l| *l == "metadata:") {
                Some(meta) => {
                    for (i, line) in lines[..close].iter().enumerate() {
                        out.push_str(line);
                        out.push('\n');
                        if i == meta {
                            out.push_str(&id_line);
                            out.push('\n');
                        }
                    }
                }
                None => {
                    for line in &lines[..close] {
                        out.push_str(line);
                        out.push('\n');
                    }
                    out.push_str("metadata:\n");
                    out.push_str(&id_line);
                    out.push('\n');
                }
            }
            // Closing fence and body, byte-exact.
            out.push_str(&rest[line_offset(rest, close)..]);
            return out;
        }
    }
    format!("---\nmetadata:\n{id_line}\n---\n{content}")
}

/// Strip the estate `memory_id` that `front_matter_inject` placed in a file.
///
/// Thin wrapper over `front_matter_strip_field` for the key `moot_memory_id`.
/// Returns `(Some(id), body)` with `body` byte-identical to the content that
/// was injected, or `(None, content unchanged)` when no id line is present.
/// Mirrors Swift `HarnessMemoryFrontMatter.strip`.
pub fn front_matter_strip(content: &str) -> (Option<String>, String) {
    front_matter_strip_field(content, FRONT_MATTER_ID_KEY)
}

/// Strip the line `  <key>: <value>` that `front_matter_inject_field` placed
/// in a file's front matter.
///
/// Returns `(Some(value), body)` with `body` byte-identical to the content
/// that was injected, or `(None, content unchanged)` when no such line is
/// present. Other `metadata:` entries (for example a `moot_memory_id` line
/// next to a `moot_generated_index` line) are left in place. Line-based,
/// `\n` only:
///   - find the first line inside the block that starts with `  <key>: `;
///     the trimmed remainder is the value; remove the line;
///   - if the line immediately before it is `metadata:` and the line now in
///     its place is not indented by two spaces (or the block ends there),
///     remove that `metadata:` line too;
///   - if the block is then empty, remove both fences.
///
/// Mirrors Swift `HarnessMemoryFrontMatter.strip(field:)`.
pub fn front_matter_strip_field(content: &str, key: &str) -> (Option<String>, String) {
    let unchanged = || (None, content.to_string());
    let Some(rest) = content.strip_prefix("---\n") else {
        return unchanged();
    };
    let lines: Vec<&str> = rest.split('\n').collect();
    let Some(close) = lines.iter().position(|l| *l == "---") else {
        return unchanged();
    };
    let id_prefix = format!("  {key}: ");
    let mut block: Vec<&str> = lines[..close].to_vec();
    let Some(idx) = block.iter().position(|l| l.starts_with(&id_prefix)) else {
        return unchanged();
    };
    let id = block[idx][id_prefix.len()..].trim().to_string();
    block.remove(idx);
    if idx > 0 && block[idx - 1] == "metadata:" {
        let next_indented = block.get(idx).map(|l| l.starts_with("  ")).unwrap_or(false);
        if !next_indented {
            block.remove(idx - 1);
        }
    }
    // Everything from the closing fence on, byte-exact ("---\n<body>", or a
    // bare "---" when the fence ends the file).
    let fence_and_body = &rest[line_offset(rest, close)..];
    if block.is_empty() {
        let body = fence_and_body.strip_prefix("---\n").unwrap_or("");
        return (Some(id), body.to_string());
    }
    let mut out = String::from("---\n");
    for line in &block {
        out.push_str(line);
        out.push('\n');
    }
    out.push_str(fence_and_body);
    (Some(id), out)
}

// ─── Path analysis (for hook-capture) ────────────────────────────────────────

/// True when an absolute tool-call path targets the Claude Code project-memory
/// directory (`…/.claude/projects/<slug>/memory/<file>`).
///
/// Windows backslashes are normalized to forward slashes before matching.
pub fn is_harness_memory_path(path: &str) -> bool {
    let normalized = path.replace('\\', "/");
    if !normalized.contains("/.claude/projects/") {
        return false;
    }
    // After `.claude/projects/`, the second path segment must be `memory`.
    let after = match normalized.split("/.claude/projects/").nth(1) {
        Some(a) => a,
        None => return false,
    };
    let parts: Vec<&str> = after.splitn(3, '/').collect();
    // parts[0] = <slug>, parts[1] = "memory", parts[2] = <filename>
    parts.len() >= 2 && parts[1] == "memory"
}

/// Extract `(project_slug, filename)` from a harness memory absolute path.
///
/// Returns `None` when the path does not match, or when security checks fail
/// (path traversal, hidden files, no filename).
pub fn parse_harness_path(path: &str) -> Option<(String, String)> {
    let normalized = path.replace('\\', "/");
    let after = normalized.split("/.claude/projects/").nth(1)?;
    let mut parts = after.splitn(3, '/');
    let slug = parts.next().filter(|s| !s.is_empty())?;
    // Slug traversal guard — mirrors Swift HarnessMemoryMatcher guard (line 644-645).
    if slug.contains("..") || slug.starts_with('.') || slug.contains('/') {
        return None;
    }
    let dir = parts.next()?;
    if dir != "memory" {
        return None;
    }
    let filename = parts.next().filter(|f| !f.is_empty())?;
    // Filename traversal guard — no `..` segments, no hidden files.
    if filename.contains("..") || filename.starts_with('.') {
        return None;
    }
    Some((slug.to_string(), filename.to_string()))
}

/// Determine memory kind from filename.
///
/// `MEMORY.md` index files (any case) are filed as `"list"` (the estate treats
/// them as a structured index rather than prose). All other files are `"prose"`.
/// Case-insensitive to match Swift's `filename.lowercased() == "memory.md"` path.
fn memory_kind(filename: &str) -> &'static str {
    if filename.eq_ignore_ascii_case("MEMORY.md") { "list" } else { "prose" }
}

// ─── Consent prompt ───────────────────────────────────────────────────────────

/// Print summary of what `enable harness-memory` will change and request
/// confirmation.  Returns true when the user consents (or `--yes` was passed).
///
/// Returns false — with an explanatory message already printed — when the user
/// declines.
fn request_consent(yes: bool, hook_script_path: &Path, settings_path: &Path) -> bool {
    println!("Harness Memory Mode — routes Claude Code memories into the MOOTx01 estate.");
    println!();
    println!("This will:");
    println!(
        "  • Back up {settings} → {settings}.mootx01-bak-<timestamp>",
        settings = settings_path.display()
    );
    println!(
        "  • Set `autoMemoryEnabled: false` in {}",
        settings_path.display()
    );
    println!("  • Add a PreToolUse hook (Write|Edit|MultiEdit) to settings.json");
    println!("  • Install {}", hook_script_path.display());
    println!("  • Add memory-governance block to ~/.claude/CLAUDE.md");
    println!();

    if yes {
        return true;
    }

    print!("Proceed? [y/N] ");
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin().read_line(&mut line).ok();
    matches!(line.trim().to_lowercase().as_str(), "y" | "yes")
}

// ─── Ingest (Part 3) ─────────────────────────────────────────────────────────

/// Per-project ingest result.
pub struct IngestResult {
    /// Files written to the estate. Every one is a new row: a file with no
    /// id, an unknown id, or a changed body all file fresh. Nothing is replaced.
    pub filed: usize,
    /// Files whose front-matter id matched an unchanged estate row; the file
    /// was removed and the row left alone.
    pub matched: usize,
    /// `MEMORY.md` indexes that `regenerate_memory_index` wrote at disable
    /// (marked `moot_generated_index: true`, no estate id); the file was
    /// removed and nothing was filed, because the estate never held it.
    pub discarded_indexes: usize,
    pub removed: usize,
    pub skipped: usize,
    pub skip_reasons: Vec<String>,
}

/// Ingest all memory files from one project's `memory/` directory into the
/// estate.  Returns an `IngestResult`.
///
/// Contract (Bob's rulings 2026-08-07 and 2026-09-09):
///   - MOVE semantics: file to estate → confirm success → delete source.
///   - Never delete before confirmation.
///   - A failed/aborted run leaves all unconfirmed source files intact.
///   - After the last file is removed, delete the empty `memory/` directory.
///   - A file restored by `disable` carries its estate `memory_id` in front
///     matter. `front_matter_strip` recovers the id and the original body;
///     the body is what gets compared, filed, and used for the subject.
///   - The id matches by identity, not by location class: the row's location
///     (`harness-import/<slug>/<file>` or `harness/<slug>/<file>`) must parse
///     to the same (slug, filename) as the file on disk.
///   - Id matches and the row's content is identical → `Matched`: remove the
///     file, touch nothing in the estate.
///   - Id matches and the content changed → `Replace`: leave the old row
///     untouched (no mutation call) and file the new body as its own row
///     at the ROW's own location (a `harness/` row stays a `harness/`
///     row); if filing fails, the old row is unaffected and the file
///     stays on disk.
///   - No id, unknown id, or a row at another slug or filename → file fresh
///     at `harness-import/<slug>/<file>`.
///   - A `MEMORY.md` with no id that carries `moot_generated_index: true` is
///     the index `regenerate_memory_index` wrote at disable, not estate
///     content: remove it, count it in `discarded_indexes`, call nothing. An
///     authored `MEMORY.md` (no markers) files fresh with kind `list`.
///   - The row lookup fails for any other reason → skip, leave the file.
///   - An unchanged row is left alone and never re-filed. A changed file
///     files a new row beside the old one, which is retained — the estate
///     gains a second row for that (slug, filename) pair.
fn ingest_project(
    daemon: &dyn DaemonHttp,
    port: u16,
    project_slug: &str,
    memory_dir: &Path,
) -> IngestResult {
    let mut result = IngestResult {
        filed: 0,
        matched: 0,
        discarded_indexes: 0,
        removed: 0,
        skipped: 0,
        skip_reasons: Vec::new(),
    };

    let entries = match fs::read_dir(memory_dir) {
        Ok(e) => e,
        Err(err) => {
            result.skip_reasons.push(format!("  {}: cannot read directory: {err}", memory_dir.display()));
            result.skipped += 1;
            return result;
        }
    };

    let mut files_to_process: Vec<PathBuf> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        // Skip directories and hidden files (security: no dotfile traversal).
        if path.is_dir() { continue; }
        let fname = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if fname.starts_with('.') {
            result.skip_reasons.push(format!("  {}: hidden file — skipped", path.display()));
            result.skipped += 1;
            continue;
        }
        // Path traversal guard.
        if fname.contains("..") {
            result.skip_reasons.push(format!("  {}: path traversal — skipped", path.display()));
            result.skipped += 1;
            continue;
        }
        files_to_process.push(path);
    }
    // read_dir order is unspecified; sort so estate calls happen in a
    // deterministic order on every platform.
    files_to_process.sort();

    for file_path in &files_to_process {
        let fname = file_path.file_name().and_then(|n| n.to_str()).unwrap_or("");

        // Read content (byte-exact — restore depends on it).
        let raw = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                result.skip_reasons.push(format!("  {}: read error: {e}", file_path.display()));
                result.skipped += 1;
                continue;
            }
        };
        // A restored file carries its estate id in front matter; the body is
        // the original content and is what the estate compares and stores.
        let (memory_id, content) = front_matter_strip(&raw);

        // A regenerated index never left the estate: `restore_memories` wrote it
        // for a slug with no captured MEMORY.md row and marked it. Filing it
        // would add one estate row per disable → enable cycle, so it is removed
        // without an estate call. Only a MEMORY.md without an id qualifies; a
        // restored or authored index is never discarded.
        if memory_id.is_none()
            && memory_kind(fname) == "list"
            && front_matter_strip_field(&content, FRONT_MATTER_GENERATED_INDEX_KEY).0.as_deref() == Some("true")
        {
            match fs::remove_file(file_path) {
                Ok(()) => {
                    result.discarded_indexes += 1;
                    result.removed += 1;
                }
                Err(e) => {
                    result.discarded_indexes += 1;
                    result.skip_reasons.push(format!(
                        "  {}: regenerated index discarded but source delete failed: {e} (remove manually)",
                        file_path.display()
                    ));
                }
            }
            continue;
        }

        // event_time = file mtime as ISO 8601 UTC.
        let event_time = match fs::metadata(file_path)
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| unix_secs_to_iso8601(d.as_secs()))
        {
            Some(t) => t,
            None => now_iso8601(), // fallback: use current time
        };

        // Location hint = reconstruction key for restore (filename preserved exactly).
        // The bare location (no `/memories/` prefix) is what `moot_file_memory` expects.
        // A Replace files at the row's own location instead (see below).
        let location = format!("harness-import/{project_slug}/{fname}");
        let kind = memory_kind(fname);

        let file_action = match determine_ingest_action(daemon, port, memory_id.as_deref(), project_slug, fname, &content) {
            Ok(action) => action,
            Err(e) => {
                // The row could not be read: leave the file, never file blind.
                result.skip_reasons.push(format!("  {fname}: estate lookup failed: {e}"));
                result.skipped += 1;
                continue;
            }
        };

        if let IngestAction::Matched(ref id) = file_action {
            // MXE-HM-2: harness_memory.ingest.matched metric emit point.
            // The estate row already holds this content; the file is the copy.
            match fs::remove_file(file_path) {
                Ok(()) => {
                    result.matched += 1;
                    result.removed += 1;
                }
                Err(e) => {
                    result.matched += 1;
                    result.skip_reasons.push(format!(
                        "  {}: matched estate row {id} but source delete failed: {e} (remove manually)",
                        file_path.display()
                    ));
                }
            }
            continue;
        }

        let subject = extract_subject(&content, fname);
        let file_result = match file_action {
            IngestAction::CreateFresh => {
                // MXE-HM-2: harness_memory.ingest.filed metric emit point.
                estate_file(daemon, port, &location, &content, &subject, &event_time, kind)
            }
            IngestAction::Replace(ref row_location) => {
                // Harness memory never supersedes and never revives: the old row
                // is left untouched, and the new body is filed as its own row at
                // the row's own location, so a capture-born `harness/` row keeps
                // its class. A single moot_file_memory call, no mutation.
                estate_file(daemon, port, row_location, &content, &subject, &event_time, kind)
            }
            IngestAction::Matched(_) => unreachable!("matched files are handled above"),
        };

        match file_result {
            Ok(()) => {
                // MOVE: delete source only after confirmed estate write.
                match fs::remove_file(file_path) {
                    Ok(()) => {
                        result.filed += 1;
                        result.removed += 1;
                    }
                    Err(e) => {
                        // Estate write succeeded but source delete failed.
                        // Report as filed (estate has it) but source still exists.
                        result.filed += 1;
                        result.skip_reasons.push(format!(
                            "  {}: filed to estate but source delete failed: {e} (remove manually)",
                            file_path.display()
                        ));
                    }
                }
            }
            Err(e) => {
                // Estate write failed — leave source intact (no move).
                result.skip_reasons.push(format!("  {fname}: estate write failed: {e}"));
                result.skipped += 1;
            }
        }
    }

    // After all files processed: remove empty memory/ directory.
    if result.removed == files_to_process.len() && !files_to_process.is_empty() {
        fs::remove_dir(memory_dir).ok(); // best-effort; non-fatal if non-empty
    }

    result
}

enum IngestAction {
    /// No usable id: file the body as a new row.
    CreateFresh,
    /// The row with this id is active for the same (slug, filename) with
    /// identical content: remove the file, leave the row.
    Matched(String),
    /// The row with this id is active for the same (slug, filename) but the
    /// content changed: the row is left untouched and the body is filed as
    /// its own new row at the row's own location. Field: row location.
    Replace(String),
}

/// Decide how one file re-enters the estate.
///
/// `memory_id` is the id recovered from the file's front matter (None when the
/// file was never restored from the estate). With an id, `estate_get` fetches
/// the row. The match is by identity, not location class: the row's location
/// must parse (`parse_restore_location`) to the same `(project_slug, fname)`
/// as the file, whichever of `harness-import/` or `harness/` it carries. Such
/// a row yields `Matched(id)` when its content equals `local_content` byte
/// for byte, otherwise `Replace(row_location)`. No id, an id the daemon
/// answers `memory_not_found` for, a superseded row, or a row at another slug
/// or filename yields `CreateFresh`. Any other daemon failure is returned so
/// the caller skips the file rather than filing a duplicate of a row it could
/// not read.
///
/// Ids come from the file's front matter, never constructed from paths.
fn determine_ingest_action(
    daemon: &dyn DaemonHttp,
    port: u16,
    memory_id: Option<&str>,
    project_slug: &str,
    fname: &str,
    local_content: &str,
) -> Result<IngestAction, DaemonCallError> {
    let Some(id) = memory_id else {
        return Ok(IngestAction::CreateFresh);
    };
    let Some(record) = estate_get(daemon, port, id)? else {
        return Ok(IngestAction::CreateFresh);
    };
    if record.is_superseded {
        return Ok(IngestAction::CreateFresh);
    }
    let same_file = parse_restore_location(&record.location)
        .map(|(slug, file)| slug == project_slug && file == fname)
        .unwrap_or(false);
    if !same_file {
        return Ok(IngestAction::CreateFresh);
    }
    if record.content == local_content {
        Ok(IngestAction::Matched(record.id))
    } else {
        Ok(IngestAction::Replace(record.location))
    }
}

// ─── Restore (Part 3b) ───────────────────────────────────────────────────────

/// Restore estate memories to disk on `disable harness-memory`.
///
/// Queries the estate for rows in both restore classes:
///   - `harness-import/*` (originally on disk, ingested by Part 3)
///   - `harness/*` (born in the estate during capture-hook interception)
///
/// Per project, offers restore (per project prompt, `--restore-all`, or
/// `--no-restore`). Each written file is the row's content with the row's
/// `memory_id` injected into its front matter (`front_matter_inject`), so a
/// later re-enable can match the file back to its row. Estate rows are left
/// exactly as they were: no mutation, no deletion (Bob's ruling 2026-09-09).
/// A refused or failed enumeration writes nothing and reports
/// `Restore FAILED`; it is never treated as an empty wing.
///
/// Returns a summary string for display.
fn restore_memories(
    daemon: &dyn DaemonHttp,
    port: u16,
    restore_all: bool,
    no_restore: bool,
    claude_dir: &Path,
) -> String {
    if no_restore {
        return "  Restore skipped (--no-restore).".to_string();
    }

    // Discover all harness rows from the estate using moot_memory_list.
    // IDs come from list results, never constructed from paths. A refusal
    // is a failure of the disable, never an empty wing: nothing is written.
    let records = match discover_restore_records(daemon, port) {
        Ok(records) => records,
        Err(e) => {
            return format!(
                "  Restore FAILED: estate enumeration refused: {e}; nothing written, estate rows unchanged."
            );
        }
    };

    if records.is_empty() {
        return "  No harness memories found in the estate to restore.".to_string();
    }

    let mut written = 0usize;
    let mut collisions = Vec::new();
    // Track restored locations for MEMORY.md regeneration.
    let mut restored_locations: Vec<String> = Vec::new();

    for record in &records {
        // Derive slug and filename from the location field of the list record.
        // Never construct /memories/… paths — derive everything from list results.
        let (slug, filename) = match parse_restore_location(&record.location) {
            Some(pair) => pair,
            None => continue,
        };

        // Per-project consent (unless --restore-all).
        if !restore_all {
            print!("  Restore '{}' to ~/.claude/projects/{slug}/memory/{filename}? [y/N] ",
                   record.location);
            io::stdout().flush().ok();
            let mut line = String::new();
            io::stdin().read_line(&mut line).ok();
            if !matches!(line.trim().to_lowercase().as_str(), "y" | "yes") {
                continue;
            }
        }

        // The row's content with its id in front matter; ingest strips the id
        // back out, so the estate never sees the header.
        let content = front_matter_inject(&record.content, &record.id);

        // Write to ~/.claude/projects/<slug>/memory/<filename>
        let dest_dir = claude_dir
            .join("projects")
            .join(&slug)
            .join("memory");
        let dest = dest_dir.join(&filename);

        // Refuse to overwrite an existing file — report collision.
        if dest.exists() {
            collisions.push(format!(
                "  {}: already exists — collision, skipped (restore manually)",
                dest.display()
            ));
            continue;
        }

        if let Err(e) = fs::create_dir_all(&dest_dir) {
            collisions.push(format!("  {}: mkdir failed: {e}", dest_dir.display()));
            continue;
        }

        if let Err(e) = fs::write(&dest, content.as_bytes()) {
            collisions.push(format!("  {}: write failed: {e}", dest.display()));
            continue;
        }
        // MXE-HM-2: harness_memory.restore.written metric emit point.
        written += 1;
        restored_locations.push(record.location.clone());
    }

    // Write a marked MEMORY.md index for each project that received restored
    // files and has no captured MEMORY.md row (a captured row was already
    // restored verbatim above). Re-enable discards the marked index.
    regenerate_memory_index(claude_dir, &restored_locations);

    let mut summary = format!("  Restore: {written} written; estate rows left unchanged.");
    for c in &collisions {
        summary.push('\n');
        summary.push_str(c);
    }
    summary
}

/// Query the estate once for every harness row across both location classes:
///   - `harness-import/*` (originally on disk, ingested by ingest sweep)
///   - `harness/*` (born in the estate via capture-hook interception)
///
/// One `estate_list` call with prefix `harness` covers both (prefix overlap),
/// so the result is filtered to locations that start with `harness-import/`
/// or `harness/` and that `parse_restore_location` accepts. Superseded rows
/// are skipped and ids are deduplicated. IDs come from list results, never
/// from constructed paths. A refused or failed enumeration is returned as the
/// error; it is never an empty result.
fn discover_restore_records(daemon: &dyn DaemonHttp, port: u16) -> Result<Vec<EstateRecord>, DaemonCallError> {
    let mut records = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for rec in estate_list(daemon, port, "harness")? {
        if rec.is_superseded {
            continue;
        }
        let in_class = rec.location.starts_with("harness-import/") || rec.location.starts_with("harness/");
        if !in_class || parse_restore_location(&rec.location).is_none() {
            continue;
        }
        if seen.insert(rec.id.clone()) {
            records.push(rec);
        }
    }
    Ok(records)
}

/// Extract `(slug, filename)` from a bare estate location string of the form
/// `harness-import/<slug>/<file>` or `harness/<slug>/<file>`.
///
/// This is the low-level parser used by the restore flow. IDs come from
/// `estate_list` results; slug and filename are extracted from the `location`
/// field of those records.
fn parse_restore_location(location: &str) -> Option<(String, String)> {
    // Strip the optional prefix so bare locations from estate_list records
    // are accepted with or without the harness[-import]/ prefix.
    let after = if location.starts_with("harness-import/") || location.starts_with("harness/") {
        location
            .strip_prefix("harness-import/")
            .or_else(|| location.strip_prefix("harness/"))?
    } else {
        location
    };
    let mut parts = after.splitn(2, '/');
    let slug = parts.next().filter(|s| !s.is_empty())?;
    // Slug traversal guard — mirrors parse_harness_path.
    if slug.contains("..") || slug.starts_with('.') || slug.contains('/') {
        return None;
    }
    let filename = parts.next().filter(|f| !f.is_empty())?;
    // Filename security: no hidden files, no traversal, no path separators.
    if filename.starts_with('.') || filename.contains("..") || filename.contains('/') {
        return None;
    }
    Some((slug.to_string(), filename.to_string()))
}

/// Regenerate a minimal MEMORY.md index for projects that received restored
/// files, UNLESS a MEMORY.md was already restored verbatim from the estate
/// (in which case it was handled by the main restore loop).
///
/// The index is `# Memory Index\n\n` followed by one `- [<f>](<f>)\n` line
/// per restored non-MEMORY.md file in byte order, wrapped in a front-matter
/// block carrying `moot_generated_index: true`. That marker is how
/// `ingest_project` tells a regenerated index (discard, never file) from a
/// captured or authored one. Exact bytes for `a.md` and `b.md`:
/// `---\nmetadata:\n  moot_generated_index: true\n---\n# Memory Index\n\n- [a.md](a.md)\n- [b.md](b.md)\n`.
/// Swift writes the identical bytes.
///
/// `restored_locations` is a vec of bare estate location strings (the form
/// returned by `estate_list`, e.g. `harness-import/<slug>/<file>`).
fn regenerate_memory_index(claude_dir: &Path, restored_locations: &[String]) {
    // Collect all (slug, filename) pairs where filename != MEMORY.md.
    use std::collections::HashMap;
    let mut by_slug: HashMap<String, Vec<String>> = HashMap::new();
    for loc in restored_locations {
        if let Some((slug, filename)) = parse_restore_location(loc) {
            if filename != "MEMORY.md" {
                by_slug.entry(slug).or_default().push(filename);
            }
        }
    }

    for (slug, files) in &by_slug {
        let memory_dir = claude_dir.join("projects").join(slug).join("memory");
        let index = memory_dir.join("MEMORY.md");
        // Only write the index if no MEMORY.md was restored verbatim already.
        if !index.exists() {
            let mut body = "# Memory Index\n\n".to_string();
            let mut sorted = files.clone();
            sorted.sort();
            for f in &sorted {
                body.push_str(&format!("- [{f}]({f})\n"));
            }
            // The body has no front matter, so the marker becomes a three-line
            // header ahead of it.
            let content = front_matter_inject_field(&body, FRONT_MATTER_GENERATED_INDEX_KEY, "true");
            fs::write(&index, content.as_bytes()).ok();
        }
    }
}

// ─── Uninstall helper ─────────────────────────────────────────────────────────

/// Compute the hook script path relative to an explicit home directory.
///
/// Used by `remove_harness_state` which receives `home` as a parameter (the
/// uninstall path) rather than reading the HOME env var at call time.
fn hook_script_path_for_home(home: &Path) -> PathBuf {
    #[cfg(target_os = "windows")]
    { home.join(".mootx01").join("hooks").join("capture-harness-memory.bat") }
    #[cfg(not(target_os = "windows"))]
    { home.join(".mootx01").join("hooks").join("capture-harness-memory.sh") }
}

/// Clean up Harness Memory Mode state on full uninstall.
///
/// Removes our hook entry from `~/.claude/settings.json`, restores
/// `autoMemoryEnabled` to the Claude Code default (key absent = enabled),
/// removes the sentinel block from `~/.claude/CLAUDE.md`, and deletes the
/// hook script. Pure file operations — no daemon contact, no restore offer
/// (restore is only offered by the interactive `disable` command).
///
/// Called from the uninstall full-teardown block BEFORE the placed binary is
/// removed, so the hook script references are cleaned up while the binary that
/// implements `hook-capture` is still present. Returns `true` if any changes
/// were made (for the caller to print a status line).
pub fn remove_harness_state(home: &Path) -> bool {
    let settings_path = home.join(".claude").join("settings.json");
    let claude_md_path = home.join(".claude").join("CLAUDE.md");
    let hook_path = hook_script_path_for_home(home);
    let hook_path_str = hook_path.to_string_lossy().into_owned();
    let mut changed = false;

    // Remove hook entry + restore autoMemoryEnabled from settings.json.
    if let Ok(settings) = read_settings(&settings_path) {
        if hook_entry_present(&settings, &hook_path_str) {
            let updated = unmerge_settings(settings, &hook_path_str);
            let _ = write_settings(&settings_path, &updated);
            changed = true;
        }
    }

    // Remove sentinel block from ~/.claude/CLAUDE.md.
    if let Ok(content) = fs::read_to_string(&claude_md_path) {
        if has_sentinel(&content) {
            let updated = remove_sentinel(&content);
            let _ = fs::write(&claude_md_path, updated.as_bytes());
            changed = true;
        }
    }

    // Remove hook script.
    if hook_path.exists() {
        let _ = fs::remove_file(&hook_path);
        changed = true;
    }

    changed
}

// ─── Public API: enable / disable / hook_capture ──────────────────────────────

/// Enable Harness Memory Mode.
///
/// See module doc comment for the full behaviour description.
/// Returns `Err` with a user-facing error message on any fatal failure.
pub fn enable(yes: bool, ingest_all: bool, daemon: &dyn DaemonHttp) -> Result<(), String> {
    let port = crate::core::daemon_client::resolved_port();
    let claude_dir = claude_config_dir();
    let settings_path = claude_dir.join("settings.json");
    let hook_path = harness_hook_script_path();
    let hook_path_str = hook_path.to_string_lossy().into_owned();

    // Part 2: refuse if daemon is unreachable — no memory backend = no service.
    if !daemon.alive(port) {
        return Err(format!(
            "The MOOTx01 estate daemon is not reachable on port {port}.\n\
             Start the daemon first (`mootx01 serve`) or run `mootx01 status` to diagnose.\n\
             Harness Memory Mode requires a reachable estate to avoid losing memories."
        ));
    }

    // Part 2: idempotence check.
    let current_settings = read_settings(&settings_path)?;
    if is_harness_memory_enabled(&current_settings, &hook_path_str) {
        println!("Harness Memory Mode is already enabled.");
        // Still offer ingest sweep for any stray files accumulated while enabled.
        if ingest_all {
            run_ingest_sweep(daemon, port, &claude_dir, true);
        }
        return Ok(());
    }

    // Part 2: consent.
    if !request_consent(yes, &hook_path, &settings_path) {
        println!("Cancelled — no changes made.");
        return Ok(());
    }

    // Part 1, step 2: backup existing settings.json before any write.
    if settings_path.exists() {
        let backup = backup_settings(&settings_path)?;
        println!("  Backed up: {}", backup.display());
    }

    // Part 1, step 3: merge and write settings.json.
    let updated = merge_settings(current_settings, &hook_path_str);
    write_settings(&settings_path, &updated)?;
    println!("  Updated: {}", settings_path.display());

    // Part 1, step 6: install hook script with absolute binary path so the hook
    // works regardless of the hook env's PATH. Mirror Swift's installed-binary URL.
    let binary_path = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|e| {
            // current_exe() should not fail in practice; fall back to PATH-relative
            // name so the hook degrades gracefully instead of refusing to install.
            eprintln!("  Warning: could not resolve binary path ({e}); hook will use PATH-relative mootx01");
            "mootx01".to_string()
        });
    install_hook_script(&hook_path, &binary_path)?;
    println!("  Installed: {}", hook_path.display());

    // Part 1, step 7: merge sentinel block into ~/.claude/CLAUDE.md.
    install_claude_md_sentinel(&claude_dir)?;
    println!("  Updated: {}", claude_dir.join("CLAUDE.md").display());

    println!();
    println!("Harness Memory Mode enabled.");
    println!("Sensitivity note: estate contradiction/dreaming machinery grades imported");
    println!("claims over time. Secrets in old memories should be withdrawn or re-filed");
    println!("restricted. Sensitivity defaults to normal.");
    println!();

    // MXE-HM-2: harness_memory.enable metric emit point.

    // Part 3: ingest offer.
    run_ingest_sweep(daemon, port, &claude_dir, ingest_all);

    Ok(())
}

/// Disable Harness Memory Mode.
///
/// Removes our hook entry from settings.json, restores auto-memory, removes
/// the sentinel block, removes the hook script, then offers restore (Part 3b).
pub fn disable(
    yes: bool,
    restore_all: bool,
    no_restore: bool,
    daemon: &dyn DaemonHttp,
) -> Result<(), String> {
    let claude_dir = claude_config_dir();
    let settings_path = claude_dir.join("settings.json");
    let hook_path = harness_hook_script_path();
    let hook_path_str = hook_path.to_string_lossy().into_owned();

    // Idempotence check.
    let current_settings = read_settings(&settings_path)?;
    if !hook_entry_present(&current_settings, &hook_path_str) {
        println!("Harness Memory Mode is not currently enabled — nothing to disable.");
        return Ok(());
    }

    if !yes {
        print!("Disable Harness Memory Mode and restore auto-memory? [y/N] ");
        io::stdout().flush().ok();
        let mut line = String::new();
        io::stdin().read_line(&mut line).ok();
        if !matches!(line.trim().to_lowercase().as_str(), "y" | "yes") {
            println!("Cancelled — no changes made.");
            return Ok(());
        }
    }

    // Backup before any write.
    if settings_path.exists() {
        let backup = backup_settings(&settings_path)?;
        println!("  Backed up: {}", backup.display());
    }

    // Part 1: remove hook entry + restore auto-memory setting.
    let updated = unmerge_settings(current_settings, &hook_path_str);
    write_settings(&settings_path, &updated)?;
    println!("  Updated: {}", settings_path.display());

    // Remove sentinel block from CLAUDE.md.
    remove_claude_md_sentinel(&claude_dir)?;
    println!("  Updated: {}", claude_dir.join("CLAUDE.md").display());

    // Remove hook script.
    if hook_path.exists() {
        fs::remove_file(&hook_path)
            .map_err(|e| format!("remove hook script: {e}"))?;
        println!("  Removed: {}", hook_path.display());
    }

    println!();
    println!("Harness Memory Mode disabled.");
    // MXE-HM-2: harness_memory.disable metric emit point.

    // Part 3b: restore offer.
    let port = crate::core::daemon_client::resolved_port();
    if daemon.alive(port) {
        let summary = restore_memories(daemon, port, restore_all, no_restore, &claude_dir);
        println!("{summary}");
    } else {
        println!("  Estate daemon not reachable — skipping restore offer.");
        println!("  Run `mootx01 enable harness-memory` again later to ingest any stray files.");
    }

    Ok(())
}

/// `mootx01 hook-capture` — Claude Code PreToolUse hook entry point.
///
/// Reads the tool-call JSON from stdin. For writes targeting the harness memory
/// path, posts the content to the estate and outputs a deny decision with a
/// teaching message. Non-memory paths, malformed input, and traversal-rejected
/// paths emit NO output — Claude Code falls through to its normal permission
/// prompt.
///
/// Daemon-down fallback: ALLOW on governed paths (losing a memory is worse than
/// a stray file; the next ingest sweep recovers stragglers).
///
/// Claude Code reads stdout for the permission decision:
///   deny  → `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<msg>"}}`
///   allow → `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}`
///   (no output) → fall-through to normal permission handling
pub fn hook_capture(daemon: &dyn DaemonHttp) {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input).ok();

    let payload: Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        // Malformed input: emit nothing — fall-through to Claude Code default.
        Err(_) => return,
    };

    let now_secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    if let Some(decision) = hook_decide(daemon, &payload, now_secs) {
        println!("{decision}");
    }
    // None: emit nothing — Claude Code falls through to normal permission handling.
}

/// Compute the PreToolUse hook decision from a parsed tool-call payload.
///
/// Returns `None` to fall through to the normal Claude Code permission prompt.
/// Non-memory paths, malformed payloads, traversal-rejected paths, and
/// unrecognised tools emit no output and let Claude Code decide.
///
/// Returns `Some(json_string)` only for paths the harness fully governs (strict
/// parse passes): `deny` on successful estate capture, `allow` as a fallback when
/// the daemon is unreachable or the estate write fails so the session is not blocked.
///
/// `now_secs`: Unix epoch seconds injected by the caller for determinism.
fn hook_decide(daemon: &dyn DaemonHttp, payload: &Value, now_secs: u64) -> Option<String> {
    let tool_name = payload.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
    let tool_input = payload.get("tool_input").cloned().unwrap_or_default();
    let path = tool_input.get("path").and_then(|v| v.as_str()).unwrap_or("");

    // Loose pre-filter: skip non-memory paths without the parse overhead.
    // An explicit allow here would auto-approve arbitrary writes under the Claude
    // Code hook contract, which is the security defect this fix addresses.
    if !is_harness_memory_path(path) {
        return None;
    }

    // Strict validation before any explicit decision is emitted. parse_harness_path
    // rejects traversal sequences (`..`), dotfiles, and empty slug/filename. Failure
    // here means the path is not safely governed — fall through, never allow.
    // This guard must run BEFORE the daemon-down check: without it, a traversal
    // path that passes the loose pre-filter would receive an explicit allow when
    // the daemon is unreachable, bypassing the user's permission prompt.
    let (project_slug, filename) = parse_harness_path(path)?;

    let port = crate::core::daemon_client::resolved_port();

    // Daemon-down fallback: allow disk write so the session is not blocked. Only
    // reached after strict parse — the path is fully governed, no traversal escape.
    if !daemon.alive(port) {
        eprintln!("mootx01 daemon unreachable on port {port} — allowing disk write as fallback");
        return Some(allow_json());
    }

    match tool_name {
        "Write" => {
            let content = tool_input
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            // Slug and filename pre-validated by parse_harness_path above; now_secs
            // injected by hook_capture for determinism — no SystemTime::now() inside.
            capture_decision(daemon, port, &project_slug, &filename, content, now_secs)
        }
        "Edit" | "MultiEdit" => {
            // Edit/MultiEdit against a nonexistent harness file: deny with teaching
            // message. Nothing is on disk to edit — files were moved to the estate.
            let location = format!("harness/{project_slug}/{filename}");
            Some(deny_json(teaching_message_with_location(&location)))
        }
        _ => {
            // Unrecognised tool targeting a memory path: fall through.
            // The hook matcher (Write|Edit|MultiEdit) normally prevents this branch;
            // it exists for forward-compatibility if Claude Code adds tool names.
            None
        }
    }
}

/// Capture a Write's content to the estate and return the hook decision.
///
/// `project_slug` and `filename` are pre-validated by `hook_decide` via
/// `parse_harness_path` — traversal and dotfile checks already ran before
/// this call, so no path security checks are repeated here.
///
/// Returns `Some(deny json)` on successful estate capture.
/// Returns `Some(allow json)` when the estate write fails (daemon reachable but
/// write errored) — fallback so the session is not blocked.
///
/// `now_secs` is passed from `hook_decide` for determinism — no
/// `SystemTime::now()` inside this function.
fn capture_decision(
    daemon: &dyn DaemonHttp,
    port: u16,
    project_slug: &str,
    filename: &str,
    content: &str,
    now_secs: u64,
) -> Option<String> {
    let location = format!("harness/{project_slug}/{filename}");
    let event_time = unix_secs_to_iso8601(now_secs);
    let kind = memory_kind(filename);
    let subject = extract_subject(content, filename);

    match estate_file(daemon, port, &location, content, &subject, &event_time, kind) {
        Ok(()) => {
            // MXE-HM-2: harness_memory.capture.ok metric emit point.
            Some(deny_json(teaching_message_with_location(&location)))
        }
        Err(e) => {
            // Estate capture failed — allow disk write (fallback).
            // MXE-HM-2: harness_memory.capture.fallback metric emit point.
            eprintln!("mootx01 estate capture failed ({e}) — allowing disk write as fallback");
            Some(allow_json())
        }
    }
}

fn teaching_message_with_location(location: &str) -> String {
    format!(
        "Captured to the estate this time. File directly with \
         moot_file_memory (location {location}) — direct filing gets semantic recall, \
         temporal grading, contradiction hunting, and linking this directory never had."
    )
}

/// JSON string for an explicit allow decision on a governed path.
///
/// Only emitted when the daemon is unreachable or the estate write fails on a
/// memory path the harness governs. Never emitted for non-memory paths or
/// malformed input (those fall through with no output).
fn allow_json() -> String {
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow"
        }
    })).unwrap_or_default()
}

/// JSON string for an explicit deny decision on a governed path.
///
/// Only emitted for Write calls that the estate successfully captured, and for
/// Edit/MultiEdit calls on governed paths (nothing on disk to edit). Never
/// emitted for non-memory paths — those fall through with no output.
fn deny_json(reason: String) -> String {
    serde_json::to_string(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason
        }
    })).unwrap_or_default()
}

// ─── Ingest sweep (called from enable and re-enable) ─────────────────────────

fn run_ingest_sweep(daemon: &dyn DaemonHttp, port: u16, claude_dir: &Path, ingest_all: bool) {
    let projects_dir = claude_dir.join("projects");
    let Ok(projects) = fs::read_dir(&projects_dir) else {
        return; // no projects directory — nothing to ingest
    };

    let mut found_any = false;
    let mut project_memory_dirs: Vec<(String, PathBuf)> = Vec::new();

    for entry in projects.flatten() {
        let slug = entry.file_name().to_string_lossy().into_owned();
        let memory_dir = entry.path().join("memory");
        if memory_dir.is_dir() {
            // Count files for the offer summary.
            let count = fs::read_dir(&memory_dir)
                .map(|e| e.count())
                .unwrap_or(0);
            if count > 0 {
                if !found_any {
                    println!("Found existing harness memory files:");
                }
                found_any = true;
                println!("  {slug}: {count} file(s)");
                project_memory_dirs.push((slug, memory_dir));
            }
        }
    }

    if !found_any {
        return;
    }

    for (slug, memory_dir) in &project_memory_dirs {
        let ingest = if ingest_all {
            true
        } else {
            print!("  Ingest '{slug}'? [y/N/all] ");
            io::stdout().flush().ok();
            let mut line = String::new();
            io::stdin().read_line(&mut line).ok();
            let answer = line.trim().to_lowercase();
            if answer == "all" {
                // Ingest this and all remaining without prompting.
                for (s2, dir2) in project_memory_dirs.iter().skip(
                    project_memory_dirs.iter().position(|(s, _)| s == slug).unwrap_or(0),
                ) {
                    let r = ingest_project(daemon, port, s2, dir2);
                    print_ingest_result(s2, &r);
                }
                return;
            }
            matches!(answer.as_str(), "y" | "yes")
        };

        if ingest {
            let r = ingest_project(daemon, port, slug, memory_dir);
            print_ingest_result(slug, &r);
        } else {
            println!("  {slug}: skipped");
        }
    }
}

fn print_ingest_result(slug: &str, r: &IngestResult) {
    println!(
        "  {slug}: filed {}, matched {}, discarded indexes {}, removed {}, skipped {}",
        r.filed, r.matched, r.discarded_indexes, r.removed, r.skipped
    );
    for reason in &r.skip_reasons {
        println!("{reason}");
    }
}

// ─── Hook script installation ─────────────────────────────────────────────────

fn install_hook_script(hook_path: &Path, binary_path: &str) -> Result<(), String> {
    if let Some(dir) = hook_path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("create hooks dir: {e}"))?;
    }
    fs::write(hook_path, hook_script_content(binary_path).as_bytes())
        .map_err(|e| format!("write hook script: {e}"))?;

    // Make executable on Unix.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(hook_path)
            .map_err(|e| format!("hook metadata: {e}"))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(hook_path, perms)
            .map_err(|e| format!("chmod hook: {e}"))?;
    }

    Ok(())
}

// ─── CLAUDE.md sentinel I/O ───────────────────────────────────────────────────

fn install_claude_md_sentinel(claude_dir: &Path) -> Result<(), String> {
    let claude_md = claude_dir.join("CLAUDE.md");
    let current = if claude_md.exists() {
        fs::read_to_string(&claude_md)
            .map_err(|e| format!("read CLAUDE.md: {e}"))?
    } else {
        String::new()
    };
    let updated = install_sentinel(&current);
    if updated != current {
        fs::create_dir_all(claude_dir)
            .map_err(|e| format!("create claude dir: {e}"))?;
        fs::write(&claude_md, updated.as_bytes())
            .map_err(|e| format!("write CLAUDE.md: {e}"))?;
    }
    Ok(())
}

fn remove_claude_md_sentinel(claude_dir: &Path) -> Result<(), String> {
    let claude_md = claude_dir.join("CLAUDE.md");
    if !claude_md.exists() {
        return Ok(());
    }
    let current = fs::read_to_string(&claude_md)
        .map_err(|e| format!("read CLAUDE.md: {e}"))?;
    let updated = remove_sentinel(&current);
    if updated != current {
        fs::write(&claude_md, updated.as_bytes())
            .map_err(|e| format!("write CLAUDE.md: {e}"))?;
    }
    Ok(())
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    // ── Mock HTTP client ──────────────────────────────────────────────────────

    /// Canned-response mock for `DaemonHttp`.
    ///
    /// Queued responses are popped in order. When the queue is exhausted, a
    /// generic 200 success is returned. Every frame sent is captured as a
    /// parsed `Value` in `calls` so tests can assert the REAL tool names and
    /// argument keys (the mismatch class that `mcp_call/name:"memory"` hid).
    pub struct MockDaemon {
        alive: bool,
        responses: Mutex<VecDeque<(u16, Vec<u8>)>>,
        /// Every JSON-RPC frame sent to the mock, in order. Parsed for assertions.
        pub calls: Mutex<Vec<Value>>,
    }

    impl MockDaemon {
        fn alive(responses: Vec<(u16, &str)>) -> Self {
            MockDaemon {
                alive: true,
                responses: Mutex::new(
                    responses
                        .into_iter()
                        .map(|(s, b)| (s, b.as_bytes().to_vec()))
                        .collect(),
                ),
                calls: Mutex::new(Vec::new()),
            }
        }
        fn dead() -> Self {
            MockDaemon {
                alive: false,
                responses: Mutex::new(VecDeque::new()),
                calls: Mutex::new(Vec::new()),
            }
        }
    }

    impl DaemonHttp for MockDaemon {
        fn alive(&self, _port: u16) -> bool {
            self.alive
        }
        fn post_frame(&self, _port: u16, frame: &[u8]) -> io::Result<(u16, Vec<u8>)> {
            // Capture every frame for test assertions.
            if let Ok(v) = serde_json::from_slice::<Value>(frame) {
                self.calls.lock().unwrap().push(v);
            }
            let mut q = self.responses.lock().unwrap();
            if let Some((status, body)) = q.pop_front() {
                Ok((status, body))
            } else {
                Ok((200, br#"{"result":{"content":[{"text":"ok"}]}}"#.to_vec()))
            }
        }
    }

    // ── Response builders for the v2 envelope ─────────────────────────────────

    /// A memory file body in the shape Claude Code writes: a YAML block with
    /// `name`, `description` and a `metadata:` mapping, then the prose.
    const SHAPE1_BODY: &str = "---\nname: bob-viewport\ndescription: \"wide\"\nmetadata:\n  node_type: memory\n  type: user\n  originSessionId: ca2fd6e7\n---\nbody\n";

    /// Build a `moot_memory_get` body holding the given `(id, room, content, state)` records.
    fn get_body(records: &[(&str, &str, &str, &str)]) -> String {
        let memories: Vec<Value> = records
            .iter()
            .map(|(id, room, content, state)| json!({
                "memory_id": id,
                "placement": {"wing": "Agentic Memory", "room": room},
                "content": content,
                "event_time": "2026-09-09T00:00:00Z",
                "state": state,
            }))
            .collect();
        json!({"jsonrpc": "2.0", "id": 1, "result": {"structuredContent": {"data": {"memories": memories}, "surface_version": "v2", "tool": "moot_memory_get"}, "isError": false}}).to_string()
    }

    /// Build a `moot_memory_list` body with one row per id.
    fn list_body(ids: &[&str], has_more: bool, next_cursor: Option<&str>) -> String {
        let memories: Vec<Value> = ids
            .iter()
            .map(|id| json!({
                "memory_id": id,
                "fetch": {"tool": "moot_memory_get", "arguments": {"memory_id": id}},
                "subject": "s",
                "provenance": "imported",
            }))
            .collect();
        let mut data = json!({"memories": memories, "has_more": has_more, "revision": 1});
        if let Some(c) = next_cursor {
            data["next_cursor"] = json!(c);
        }
        json!({"jsonrpc": "2.0", "id": 1, "result": {"structuredContent": {"data": data, "surface_version": "v2", "tool": "moot_memory_list"}, "isError": false}}).to_string()
    }

    /// A JSON-RPC error body (HTTP 200): what the server answers for an unknown
    /// or superseded `memory_id`.
    const RPC_ERROR_BODY: &str = r##"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"unknown memory_id"}}"##;

    /// Tool names of every frame the mock received, in order.
    fn call_names(daemon: &MockDaemon) -> Vec<String> {
        daemon.calls.lock().unwrap().iter()
            .map(|c| c["params"]["name"].as_str().unwrap_or("").to_string())
            .collect()
    }

    // ── ISO 8601 time ─────────────────────────────────────────────────────────

    #[test]
    fn iso8601_unix_epoch() {
        // 0 seconds = 1970-01-01T00:00:00Z
        assert_eq!(unix_secs_to_iso8601(0), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn iso8601_known_date() {
        // 2026-08-07T00:00:00Z — days: 20672 * 86400 = 1785830400
        // Verified by: date -d "2026-08-07" +%s (on Linux) = 1785801600? Let me recalc.
        // Jan 31 + Feb 28 + Mar 31 + Apr 30 + May 31 + Jun 30 + Jul 31 = 212 days
        // Aug 7 → 212 + 7 = 219 (1-indexed day of year), so 218 complete days
        // Years 1970–2025: 56 * 365 + 14 leap = 20454 days from 1970-01-01 to 2026-01-01
        // Total: 20454 + 218 = 20672 days; 20672 * 86400 = 1786060800
        assert_eq!(unix_secs_to_iso8601(1786060800), "2026-08-07T00:00:00Z");
    }

    #[test]
    fn iso8601_time_components() {
        // 1786060800 + 14*3600 + 30*60 + 45 = 1786060800 + 52245 = 1786113045
        assert_eq!(unix_secs_to_iso8601(1786113045), "2026-08-07T14:30:45Z");
    }

    #[test]
    fn iso8601_leap_day() {
        // 2000-02-29 is a valid date (leap year).
        // Days from 1970 to 2000-02-29:
        //   1970-2000: 30*365 + 7 leap years (72,76,80,84,88,92,96) = 10950+7=10957
        //   Jan=31, Feb1-29=29 → 31+28=59 days into 2000 for Feb 29 = day 60 (1-indexed)
        //   = 10957 + 59 = 11016 days
        //   11016 * 86400 = 951782400
        assert_eq!(unix_secs_to_iso8601(951782400), "2000-02-29T00:00:00Z");
    }

    // ── Settings merge ────────────────────────────────────────────────────────

    const HOOK_PATH: &str = "/home/user/.mootx01/hooks/capture-harness-memory.sh";

    #[test]
    fn merge_settings_adds_auto_memory_and_hook() {
        let current = json!({ "other": 42 });
        let merged = merge_settings(current, HOOK_PATH);
        assert_eq!(merged["autoMemoryEnabled"], json!(false));
        let hooks = merged.pointer("/hooks/PreToolUse").unwrap().as_array().unwrap();
        assert_eq!(hooks.len(), 1);
        assert!(entry_owns_hook(&hooks[0], HOOK_PATH));
        // Existing key is preserved.
        assert_eq!(merged["other"], json!(42));
    }

    #[test]
    fn merge_settings_is_idempotent() {
        let current = json!({});
        let once = merge_settings(current, HOOK_PATH);
        let twice = merge_settings(once.clone(), HOOK_PATH);
        // Hook entry count must not double.
        let hooks_once = once.pointer("/hooks/PreToolUse").unwrap().as_array().unwrap().len();
        let hooks_twice = twice.pointer("/hooks/PreToolUse").unwrap().as_array().unwrap().len();
        assert_eq!(hooks_once, hooks_twice);
        assert_eq!(hooks_once, 1);
    }

    #[test]
    fn merge_settings_preserves_existing_hooks() {
        let current = json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "SomeTool",
                    "hooks": [{"type": "command", "command": "/other/hook.sh"}]
                }]
            }
        });
        let merged = merge_settings(current, HOOK_PATH);
        let hooks = merged.pointer("/hooks/PreToolUse").unwrap().as_array().unwrap();
        assert_eq!(hooks.len(), 2);
        // The pre-existing hook is still there.
        assert!(!entry_owns_hook(&hooks[0], HOOK_PATH));
        assert!(entry_owns_hook(&hooks[1], HOOK_PATH));
    }

    #[test]
    fn unmerge_settings_removes_only_our_hook() {
        let current = json!({
            "autoMemoryEnabled": false,
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "SomeTool",
                        "hooks": [{"type": "command", "command": "/other/hook.sh"}]
                    },
                    {
                        "matcher": "Write|Edit|MultiEdit",
                        "hooks": [{"type": "command", "command": HOOK_PATH, "args": []}]
                    }
                ]
            },
            "someOther": "value"
        });
        let unmerged = unmerge_settings(current, HOOK_PATH);
        // autoMemoryEnabled is removed (we set it to false — restore to absent).
        assert!(unmerged.get("autoMemoryEnabled").is_none());
        // Our hook entry is gone; the other hook entry remains.
        let hooks = unmerged.pointer("/hooks/PreToolUse").unwrap().as_array().unwrap();
        assert_eq!(hooks.len(), 1);
        assert!(!entry_owns_hook(&hooks[0], HOOK_PATH));
        // Other key is untouched.
        assert_eq!(unmerged["someOther"], json!("value"));
    }

    #[test]
    fn unmerge_settings_when_not_enabled_is_noop() {
        let current = json!({ "someKey": true });
        let unmerged = unmerge_settings(current.clone(), HOOK_PATH);
        // No hook to remove, no autoMemoryEnabled to touch.
        assert_eq!(unmerged, current);
    }

    #[test]
    fn is_harness_memory_enabled_true_when_both_present() {
        let settings = merge_settings(json!({}), HOOK_PATH);
        assert!(is_harness_memory_enabled(&settings, HOOK_PATH));
    }

    #[test]
    fn is_harness_memory_enabled_false_when_hook_absent() {
        let settings = json!({ "autoMemoryEnabled": false });
        assert!(!is_harness_memory_enabled(&settings, HOOK_PATH));
    }

    #[test]
    fn is_harness_memory_enabled_false_when_auto_memory_not_disabled() {
        let settings = json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Write|Edit|MultiEdit",
                    "hooks": [{"type": "command", "command": HOOK_PATH}]
                }]
            }
        });
        assert!(!is_harness_memory_enabled(&settings, HOOK_PATH));
    }

    #[test]
    fn round_trip_enable_disable_restores_semantic_equality() {
        // Start with a settings object that has existing hooks.
        let original = json!({
            "someFeature": true,
            "hooks": {
                "PreToolUse": [{
                    "matcher": "OtherTool",
                    "hooks": [{"type": "command", "command": "/other.sh"}]
                }]
            }
        });
        let enabled = merge_settings(original.clone(), HOOK_PATH);
        let disabled = unmerge_settings(enabled, HOOK_PATH);
        // After round-trip: original keys preserved, our additions gone.
        assert_eq!(disabled["someFeature"], json!(true));
        let hooks = disabled.pointer("/hooks/PreToolUse").unwrap().as_array().unwrap();
        assert_eq!(hooks.len(), 1);
        assert!(!entry_owns_hook(&hooks[0], HOOK_PATH));
        assert!(disabled.get("autoMemoryEnabled").is_none());
    }

    // ── CLAUDE.md sentinel ────────────────────────────────────────────────────

    #[test]
    fn sentinel_install_adds_block() {
        let base = "# Existing content\n\nSome text.\n";
        let updated = install_sentinel(base);
        assert!(updated.contains(SENTINEL_BEGIN));
        assert!(updated.contains(SENTINEL_END));
        assert!(updated.contains("Existing content"));
    }

    #[test]
    fn sentinel_install_is_idempotent() {
        let base = "";
        let once = install_sentinel(base);
        let twice = install_sentinel(&once);
        assert_eq!(once, twice);
    }

    #[test]
    fn sentinel_remove_extracts_block() {
        let base = "# Header\n\nExisting.\n";
        let installed = install_sentinel(base);
        let removed = remove_sentinel(&installed);
        assert!(!removed.contains(SENTINEL_BEGIN));
        assert!(!removed.contains(SENTINEL_END));
        assert!(removed.contains("Header"));
        assert!(removed.contains("Existing."));
    }

    #[test]
    fn sentinel_remove_on_absent_is_noop() {
        let base = "# Just a normal CLAUDE.md\n";
        let removed = remove_sentinel(base);
        assert_eq!(removed, base);
    }

    #[test]
    fn has_sentinel_detection() {
        assert!(!has_sentinel("no sentinel here"));
        assert!(has_sentinel(&install_sentinel("content")));
    }

    // ── Path analysis (for hook-capture) ─────────────────────────────────────

    #[test]
    fn is_harness_memory_path_matches_standard_shape() {
        assert!(is_harness_memory_path(
            "/home/alice/.claude/projects/-home-alice-code-myapp/memory/MEMORY.md"
        ));
        assert!(is_harness_memory_path(
            "/Users/carol/.claude/projects/-Users-carol-devlop-mootx01/memory/notes.md"
        ));
    }

    #[test]
    fn is_harness_memory_path_rejects_non_memory_paths() {
        assert!(!is_harness_memory_path("/home/alice/.claude/CLAUDE.md"));
        assert!(!is_harness_memory_path("/tmp/memory/file.md"));
        // "memory" must be the second segment after the slug, not elsewhere.
        assert!(!is_harness_memory_path(
            "/home/alice/.claude/projects/slug/docs/memory/file.md"
        ));
    }

    #[test]
    fn is_harness_memory_path_handles_windows_separators() {
        assert!(is_harness_memory_path(
            r"C:\Users\alice\.claude\projects\slug\memory\MEMORY.md"
        ));
    }

    #[test]
    fn parse_harness_path_extracts_slug_and_filename() {
        let result = parse_harness_path(
            "/home/alice/.claude/projects/-home-alice-myapp/memory/notes.md",
        );
        assert_eq!(result, Some(("-home-alice-myapp".to_string(), "notes.md".to_string())));
    }

    #[test]
    fn parse_harness_path_rejects_hidden_files() {
        let result = parse_harness_path(
            "/home/alice/.claude/projects/slug/memory/.hidden",
        );
        assert!(result.is_none());
    }

    #[test]
    fn parse_harness_path_rejects_traversal() {
        let result = parse_harness_path(
            "/home/alice/.claude/projects/slug/memory/../../../etc/passwd",
        );
        assert!(result.is_none());
    }

    // ── Ingest with mock daemon ───────────────────────────────────────────────

    #[test]
    fn ingest_project_files_and_removes_on_success() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("note.md"), b"# A note\n").unwrap();
        fs::write(memory_dir.join("MEMORY.md"), b"# Index\n").unwrap();

        // Files without a front-matter id go straight to estate_file: one call
        // each. Both calls succeed.
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 2);
        assert_eq!(result.removed, 2);
        assert_eq!(result.skipped, 0);
        // Source files must be removed (MOVE semantics).
        assert!(!memory_dir.join("note.md").exists());
        assert!(!memory_dir.join("MEMORY.md").exists());
    }

    #[test]
    fn ingest_project_leaves_source_when_estate_write_fails() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("note.md"), b"important\n").unwrap();

        // No front-matter id → CreateFresh with no lookup; estate_file: 500 → failure.
        let daemon = MockDaemon::alive(vec![
            (500, "internal error"), // file → fail
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 0);
        assert_eq!(result.removed, 0);
        assert_eq!(result.skipped, 1);
        // Source file must survive.
        assert!(memory_dir.join("note.md").exists());
    }

    #[test]
    fn ingest_project_skips_hidden_files() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join(".hidden"), b"secret\n").unwrap();
        fs::write(memory_dir.join("visible.md"), b"ok\n").unwrap();

        // visible.md has no id: one estate_file call.
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.skipped, 1); // .hidden
        assert_eq!(result.filed, 1);   // visible.md
        assert!(result.skip_reasons[0].contains("hidden file"));
    }

    #[test]
    fn ingest_project_matches_unchanged_restored_file() {
        // A file restored by disable carries its id; the row's content is the
        // same, so the file is removed and the estate sees one get and nothing else.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("note.md"), front_matter_inject(SHAPE1_BODY, "drawer-abc")).unwrap();

        let get_resp = get_body(&[("drawer-abc", "harness-import/slug/note.md", SHAPE1_BODY, "active")]);
        let daemon = MockDaemon::alive(vec![(200, &get_resp)]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.matched, 1);
        assert_eq!(result.removed, 1);
        assert_eq!(result.filed, 0);
        assert_eq!(result.skipped, 0);
        assert!(!memory_dir.join("note.md").exists(), "matched file must be removed");

        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "matched path: exactly one estate call");
        assert_eq!(calls[0]["params"]["name"], "moot_memory_get");
        assert_eq!(calls[0]["params"]["arguments"]["memory_id"], "drawer-abc");
    }

    #[test]
    fn ingest_project_files_fresh_when_restored_content_changed() {
        // Same id, content edited on disk: the row is left untouched and the
        // stripped body is filed as its own new row, one moot_file_memory call.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        let changed = SHAPE1_BODY.replace("body\n", "body edited on disk\n");
        fs::write(memory_dir.join("note.md"), front_matter_inject(&changed, "drawer-abc")).unwrap();

        let get_resp = get_body(&[("drawer-abc", "harness-import/slug/note.md", SHAPE1_BODY, "active")]);
        let daemon = MockDaemon::alive(vec![
            (200, &get_resp),
            (200, r##"{"result":{"content":[{"text":"filed"}]}}"##),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 1);
        assert_eq!(result.removed, 1);
        assert_eq!(result.matched, 0);
        assert_eq!(result.skipped, 0);
        assert!(!memory_dir.join("note.md").exists());

        assert_eq!(call_names(&daemon), ["moot_memory_get", "moot_file_memory"]);
        let calls = daemon.calls.lock().unwrap();
        let file_args = &calls[1]["params"]["arguments"];
        assert_eq!(file_args["location"], "harness-import/slug/note.md");
        assert_eq!(file_args["content"], changed, "filed content is the stripped body, no id header");
        assert_eq!(file_args["subject"], extract_subject(&changed, "note.md"));
        assert!(calls.iter().all(|c| c["params"]["name"] != "moot_update_memory"), "no mutation on a changed file");
    }

    #[test]
    fn ingest_project_failed_filing_on_changed_content_leaves_file_and_touches_no_row() {
        // Filing the changed body fails: the old row was never touched (no
        // supersede happened), so there is nothing to roll back. The file stays.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        let changed = SHAPE1_BODY.replace("body\n", "body edited on disk\n");
        let on_disk = front_matter_inject(&changed, "drawer-abc");
        fs::write(memory_dir.join("note.md"), &on_disk).unwrap();

        let get_resp = get_body(&[("drawer-abc", "harness-import/slug/note.md", SHAPE1_BODY, "active")]);
        let daemon = MockDaemon::alive(vec![
            (200, &get_resp),
            (500, "internal error"),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.skipped, 1);
        assert_eq!(result.filed, 0);
        assert_eq!(result.removed, 0);
        assert_eq!(fs::read_to_string(memory_dir.join("note.md")).unwrap(), on_disk, "file stays on disk untouched");

        assert_eq!(call_names(&daemon), ["moot_memory_get", "moot_file_memory"]);
        let calls = daemon.calls.lock().unwrap();
        assert!(calls.iter().all(|c| c["params"]["name"] != "moot_update_memory"), "the old row is never mutated");
    }

    #[test]
    fn ingest_project_files_fresh_when_id_is_unknown() {
        // The id in the file answers memory_not_found (row gone or superseded): file fresh.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("note.md"), front_matter_inject(SHAPE1_BODY, "drawer-gone")).unwrap();

        let daemon = MockDaemon::alive(vec![
            (200, MEMORY_NOT_FOUND_FRAME),
            (200, r##"{"result":{"content":[{"text":"filed"}]}}"##),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 1);
        assert_eq!(result.matched, 0);
        assert_eq!(result.skipped, 0);
        assert_eq!(call_names(&daemon), ["moot_memory_get", "moot_file_memory"]);
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls[1]["params"]["arguments"]["content"], SHAPE1_BODY, "filed body carries no id header");
        assert!(calls.iter().all(|c| c["params"]["name"] != "moot_update_memory"), "no mutation on a fresh file");
    }

    #[test]
    fn ingest_project_skips_file_when_row_lookup_is_refused() {
        // Any refusal other than memory_not_found means the row could not be read:
        // the file stays on disk and nothing is filed (no blind duplicate).
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        let on_disk = front_matter_inject(SHAPE1_BODY, "drawer-abc");
        fs::write(memory_dir.join("note.md"), &on_disk).unwrap();

        let daemon = MockDaemon::alive(vec![(200, ESTATE_UNAVAILABLE_FRAME)]);
        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.skipped, 1);
        assert_eq!(result.filed, 0);
        assert_eq!(result.matched, 0);
        assert!(result.skip_reasons[0].contains("estate lookup failed"), "{:?}", result.skip_reasons);
        assert_eq!(fs::read_to_string(memory_dir.join("note.md")).unwrap(), on_disk);
        assert_eq!(call_names(&daemon), ["moot_memory_get"], "the lookup is the only call");
    }

    #[test]
    fn ingest_project_files_fresh_without_front_matter_id() {
        // A file that never left the estate (no id) is filed as-is in one call.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("note.md"), SHAPE1_BODY).unwrap();

        let daemon = MockDaemon::alive(vec![(200, r##"{"result":{"content":[{"text":"filed"}]}}"##)]);
        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 1);
        assert_eq!(result.removed, 1);
        assert_eq!(result.matched, 0);

        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "no id: exactly one call, the filing");
        assert_eq!(calls[0]["params"]["name"], "moot_file_memory");
        assert_eq!(calls[0]["params"]["arguments"]["content"], SHAPE1_BODY, "content unchanged");
    }

    #[test]
    fn ingest_project_matches_capture_born_harness_row_by_identity() {
        // A row born in the estate lives at harness/<slug>/<file>. Restored and
        // re-ingested, it matches by (slug, filename), not by location class.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("note.md"), front_matter_inject(SHAPE1_BODY, "cap-1")).unwrap();

        let get_resp = get_body(&[("cap-1", "harness/slug/note.md", SHAPE1_BODY, "active")]);
        let daemon = MockDaemon::alive(vec![(200, get_resp.as_str())]);
        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.matched, 1);
        assert_eq!(result.filed, 0);
        assert!(!memory_dir.join("note.md").exists(), "matched file removed");
        assert_eq!(call_names(&daemon), ["moot_memory_get"], "one call, no mutation");

        // Changed body: the new content is filed fresh at the row's own harness/
        // location, one moot_file_memory call, the old row left untouched.
        fs::create_dir_all(&memory_dir).unwrap();
        let changed = SHAPE1_BODY.replace("body\n", "body edited on disk\n");
        fs::write(memory_dir.join("note.md"), front_matter_inject(&changed, "cap-1")).unwrap();
        let daemon = MockDaemon::alive(vec![
            (200, get_resp.as_str()),
            (200, r##"{"result":{"content":[{"text":"filed"}]}}"##),
        ]);
        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 1);
        assert_eq!(call_names(&daemon), ["moot_memory_get", "moot_file_memory"]);
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls[1]["params"]["arguments"]["location"], "harness/slug/note.md", "a harness/ row stays a harness/ row");
        assert_eq!(calls[1]["params"]["arguments"]["content"], changed);
    }

    // ── hook-capture path logic ───────────────────────────────────────────────

    // ── hook_decide: fall-through for non-memory paths ───────────────────────
    //
    // The security fix for CA-01: the hook must emit NO decision for paths it
    // does not govern. Before this fix, hook_capture emitted permissionDecision:"allow"
    // on non-memory paths, which auto-approved arbitrary writes under the Claude Code
    // hook contract. These tests prove the correct fall-through behavior.

    const MEMORY_PATH: &str = "/home/bob/.claude/projects/slug/memory/note.md";
    const NON_MEMORY_PATH: &str = "/tmp/random.txt";
    const TRAVERSAL_MEMORY_PATH: &str =
        "/home/bob/.claude/projects/slug/memory/../../../etc/passwd";

    #[test]
    fn hook_decide_emits_no_decision_for_non_memory_write() {
        let daemon = MockDaemon::alive(vec![]);
        let payload = json!({
            "tool_name": "Write",
            "tool_input": {"path": NON_MEMORY_PATH, "content": "malicious"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        assert!(
            result.is_none(),
            "non-memory Write must produce no decision object, got: {:?}", result
        );
    }

    #[test]
    fn hook_decide_emits_no_decision_for_non_memory_edit() {
        let daemon = MockDaemon::alive(vec![]);
        let payload = json!({
            "tool_name": "Edit",
            "tool_input": {"path": NON_MEMORY_PATH, "old_string": "x", "new_string": "y"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        assert!(result.is_none(), "non-memory Edit must fall through");
    }

    #[test]
    fn hook_decide_emits_no_decision_for_empty_path() {
        let daemon = MockDaemon::alive(vec![]);
        let payload = json!({"tool_name": "Write", "tool_input": {"path": ""}});
        let result = hook_decide(&daemon, &payload, 0);
        assert!(result.is_none(), "empty path must fall through");
    }

    #[test]
    fn hook_decide_emits_no_decision_for_traversal_path() {
        // Path passes is_harness_memory_path but parse_harness_path rejects it.
        let daemon = MockDaemon::alive(vec![]);
        let payload = json!({
            "tool_name": "Write",
            "tool_input": {"path": TRAVERSAL_MEMORY_PATH, "content": "bad"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        assert!(
            result.is_none(),
            "traversal path must produce no decision object, got: {:?}", result
        );
    }

    #[test]
    fn hook_decide_emits_allow_on_daemon_down_for_governed_path() {
        let daemon = MockDaemon::dead();
        let payload = json!({
            "tool_name": "Write",
            "tool_input": {"path": MEMORY_PATH, "content": "memory content"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        let json = result.expect("daemon-down on governed path must emit allow");
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            v.pointer("/hookSpecificOutput/permissionDecision"),
            Some(&json!("allow")),
            "daemon-down fallback must emit allow, not fall-through"
        );
    }

    #[test]
    fn hook_decide_emits_no_decision_for_traversal_with_daemon_down() {
        // Regression: traversal path where the escape sequence comes AFTER a valid
        // filename component (e.g. `memory/z/../../etc/passwd`). The loose
        // is_harness_memory_path check accepts it; parse_harness_path rejects it
        // because the filename contains "..". With the daemon down, the pre-fix code
        // emitted allow (daemon-down check ran before parse_harness_path); the fixed
        // code runs parse_harness_path first and falls through on rejection.
        let daemon = MockDaemon::dead();
        const INTERLEAVED_TRAVERSAL: &str =
            "/home/bob/.claude/projects/slug/memory/z/../../etc/passwd";
        let payload = json!({
            "tool_name": "Write",
            "tool_input": {"path": INTERLEAVED_TRAVERSAL, "content": "evil"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        assert!(
            result.is_none(),
            "traversal path must fall through even when daemon is down, got: {:?}", result
        );
    }

    #[test]
    fn hook_decide_emits_deny_on_successful_memory_write() {
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);
        let payload = json!({
            "tool_name": "Write",
            "tool_input": {"path": MEMORY_PATH, "content": "memory content"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        let json = result.expect("successful memory write must emit deny");
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            v.pointer("/hookSpecificOutput/permissionDecision"),
            Some(&json!("deny")),
            "successful estate capture must deny the disk write"
        );
        assert!(
            v.pointer("/hookSpecificOutput/permissionDecisionReason").is_some(),
            "deny must include a teaching message"
        );
    }

    #[test]
    fn hook_decide_emits_deny_for_edit_on_governed_path() {
        let daemon = MockDaemon::alive(vec![]);
        let payload = json!({
            "tool_name": "Edit",
            "tool_input": {"path": MEMORY_PATH, "old_string": "a", "new_string": "b"}
        });
        let result = hook_decide(&daemon, &payload, 0);
        let json = result.expect("Edit on governed path must emit deny");
        let v: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            v.pointer("/hookSpecificOutput/permissionDecision"),
            Some(&json!("deny"))
        );
    }

    #[test]
    fn hook_decide_falls_through_unknown_tool_on_governed_path() {
        // The hook matcher (Write|Edit|MultiEdit) prevents this normally, but the
        // _ arm must fall through rather than auto-allow if Claude Code ever adds tools.
        let daemon = MockDaemon::alive(vec![]);
        let payload = json!({
            "tool_name": "CreateFile",
            "tool_input": {"path": MEMORY_PATH}
        });
        let result = hook_decide(&daemon, &payload, 0);
        assert!(result.is_none(), "unrecognised tool must fall through");
    }

    // ── Consent and daemon-down path (unit-level) ─────────────────────────────

    #[test]
    fn is_harness_memory_enabled_false_on_empty_settings() {
        assert!(!is_harness_memory_enabled(&json!({}), HOOK_PATH));
    }

    // ── Slug traversal regression tests ──────────────────────────────────────

    // parse_harness_path — the slug is the segment between .claude/projects/ and
    // /memory/. All three traversal guard conditions must reject at the slug level.

    #[test]
    fn parse_harness_path_rejects_dotdot_slug() {
        // slug = ".." → contains ".."
        let r = parse_harness_path("/home/bob/.claude/projects/../memory/file.md");
        assert!(r.is_none(), "slug '..' must be rejected");
    }

    #[test]
    fn parse_harness_path_rejects_dotfile_slug() {
        // slug = ".evil" → starts_with('.')
        let r = parse_harness_path("/home/bob/.claude/projects/.evil/memory/file.md");
        assert!(r.is_none(), "slug starting with '.' must be rejected");
    }

    #[test]
    fn parse_harness_path_rejects_slash_in_slug() {
        // URL-encoded slash or Windows backslash normalised: slug contains '/'
        // After replace('\\', '/') and split("/.claude/projects/"), the slug
        // segment would embed a slash only if the normalize step misparses.
        // Test a Windows path where the slug contains an embedded backslash:
        // "..\\evil" normalises to "../evil" — "..\\evil" after the split gives
        // segment "..%5Cevil"; but simpler: test a raw slug with ".." suffix.
        let r = parse_harness_path("/home/bob/.claude/projects/a..b/memory/file.md");
        // "a..b" contains ".." → rejected.
        assert!(r.is_none(), "slug with '..' inside must be rejected");
    }

    // parse_restore_location — same slug guard on the estate location string
    // returned by estate_list.

    #[test]
    fn parse_restore_location_rejects_dotdot_slug_bare() {
        // Bare location from estate_list: harness-import/../etc/passwd
        let r = parse_restore_location("harness-import/../etc/passwd");
        assert!(r.is_none(), "bare location with '..' slug must be rejected");
    }

    #[test]
    fn parse_restore_location_rejects_dotfile_slug_bare() {
        // Bare location from estate_list: harness/.evil/file.md
        let r = parse_restore_location("harness/.evil/file.md");
        assert!(r.is_none(), "bare location with dotfile slug must be rejected");
    }

    // ── Sentinel parity: Rust SENTINEL_CONTENT == Swift HarnessMemoryCLAUDE.block body ──

    #[test]
    fn sentinel_content_is_canonical_governance_text() {
        // This test pins SENTINEL_CONTENT byte-for-byte against the canonical text
        // defined in HarnessMemory.swift (HarnessMemoryCLAUDE.block, lines 279-292).
        // If the Swift text changes, this test must be updated simultaneously.
        // The Swift block body (between beginMarker and endMarker, excluding the
        // markers themselves) must equal SENTINEL_CONTENT exactly.
        let expected = "\n\
# Memory Governance — MOOTx01 Harness Memory Mode\n\
\n\
File memories with `moot_file_memory` (location: `harness/<project>/<name>`) and recall\n\
them with `moot_memory_search` / `moot_recall_*`. Do NOT write markdown files to\n\
`~/.claude/projects/*/memory/` — those writes are intercepted and routed to the estate.\n\
\n\
The estate provides semantic recall, temporal grading, contradiction hunting, and\n\
cross-session linking that the flat project-memory directory never had.\n";
        assert_eq!(
            SENTINEL_CONTENT, expected,
            "SENTINEL_CONTENT diverged from Swift canonical; update both ports simultaneously"
        );
    }

    // ── Frame shape tests — every estate_* helper sends the correct ARIA tool ──
    //
    // These tests exist so the wrong-tool-name class (old `name:"memory"` with
    // command-based args) can never pass silently. If a helper is changed to use
    // a wrong tool name, these tests catch it immediately.

    #[test]
    fn estate_file_sends_moot_file_memory_frame() {
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);
        let result = estate_file(
            &daemon, 4242,
            "harness/test-slug/note.md",
            "hello world",
            "test subject line",
            "2026-08-07T00:00:00Z",
            "prose",
        );
        assert!(result.is_ok());
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let args = &calls[0]["params"]["arguments"];
        assert_eq!(calls[0]["params"]["name"], "moot_file_memory");
        assert_eq!(args["location"], "harness/test-slug/note.md");
        assert_eq!(args["content"], "hello world");
        assert_eq!(args["subject"], "test subject line");
        assert_eq!(args["event_time"], "2026-08-07T00:00:00Z");
        assert_eq!(args["kind"], "prose");
        // No legacy "command" arg — drift guard.
        assert!(args.get("command").is_none(), "no command arg");
    }

    // v2 list response: memories[] rows carry only memory_id/fetch/subject/provenance.
    // Location and content come from a follow-up moot_memory_get call (estate_get).
    // These response shapes are derived from the captured v2 binary fixtures.
    const V2_LIST_RESP: &str = r##"{"result":{"structuredContent":{"data":{"memories":[{"memory_id":"m1","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"m1"}},"subject":"test","provenance":"imported"}],"has_more":false},"surface_version":"v2","tool":"moot_memory_list"},"isError":false}}"##;
    const V2_GET_RESP: &str = r##"{"result":{"structuredContent":{"data":{"memories":[{"memory_id":"m1","placement":{"wing":"Agentic Memory","room":"harness-import/slug1/MEMORY.md"},"content":"Memory Index content","event_time":"2026-09-09T00:00:00Z","state":"active"}]},"surface_version":"v2","tool":"moot_memory_get"},"isError":false}}"##;

    /// The exact ARIA v2 refusal frame for a stale list cursor (HTTP 200, no
    /// top-level JSON-RPC error, no `data`).
    const CURSOR_STALE_FRAME: &str = r##"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"The inventory changed; restart moot_memory_list without the cursor."}],"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","error":{"code":"cursor_stale","message":"The inventory changed; restart moot_memory_list without the cursor.","retryable":true},"meta":{}}}}"##;
    /// ARIA v2 refusal for an unknown or superseded memory id.
    const MEMORY_NOT_FOUND_FRAME: &str = r##"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"memory not found"}],"structuredContent":{"surface_version":"v2","tool":"moot_memory_get","error":{"code":"memory_not_found","message":"memory not found","retryable":false},"meta":{}}}}"##;
    /// ARIA v2 refusal that is not about the id: the estate itself is unavailable.
    const ESTATE_UNAVAILABLE_FRAME: &str = r##"{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"estate unavailable"}],"structuredContent":{"surface_version":"v2","tool":"moot_memory_get","error":{"code":"estate_unavailable","message":"estate unavailable","retryable":true},"meta":{}}}}"##;

    const PAGE1_FIXTURE: &str = include_str!("../../../../../distribution/plugin/tests/fixtures/rust_memory_list_page1.json");
    const PAGE2_FIXTURE: &str = include_str!("../../../../../distribution/plugin/tests/fixtures/rust_memory_list_page2.json");
    const GET_BATCH_FIXTURE: &str = include_str!("../../../../../distribution/plugin/tests/fixtures/rust_memory_get_batch.json");
    const LIST_FIXTURE: &str = include_str!("../../../../../distribution/plugin/tests/fixtures/rust_memory_list.json");
    const GET_FIXTURE: &str = include_str!("../../../../../distribution/plugin/tests/fixtures/rust_memory_get.json");

    /// Test setup only: the ids a list fixture page carries, in page order.
    fn fixture_page_ids(fixture: &str) -> Vec<String> {
        let full: Value = serde_json::from_str(fixture).expect("fixture must parse");
        full.pointer("/result/structuredContent/data/memories").and_then(|v| v.as_array())
            .expect("fixture page has memories")
            .iter()
            .map(|m| m["memory_id"].as_str().expect("row has memory_id").to_string())
            .collect()
    }

    /// Test setup only: `next_cursor` of a list fixture page.
    fn fixture_next_cursor(fixture: &str) -> String {
        let full: Value = serde_json::from_str(fixture).expect("fixture must parse");
        full.pointer("/result/structuredContent/data/next_cursor").and_then(|v| v.as_str())
            .expect("fixture page has next_cursor").to_string()
    }

    /// The 207 ids of the two-page fixture run, and the five get bodies that
    /// answer them in 50-id chunks. The recorded batch fixture covers exactly the
    /// first 50 ids of page 1; the remaining four chunks are synthesized from the
    /// page ids (distinct `harness-import/bigslug/synth-<n>.md` rooms) because
    /// no recorded batch exists for them.
    fn two_page_run() -> (Vec<String>, Vec<String>) {
        let mut ids = fixture_page_ids(PAGE1_FIXTURE);
        ids.extend(fixture_page_ids(PAGE2_FIXTURE));
        assert_eq!(ids.len(), 207, "fixture run is 200 + 7 ids");
        let mut bodies = vec![GET_BATCH_FIXTURE.to_string()];
        for (n, chunk) in ids[50..].chunks(50).enumerate() {
            let rooms: Vec<String> = (0..chunk.len())
                .map(|i| format!("harness-import/bigslug/synth-{n}-{i}.md"))
                .collect();
            let records: Vec<(&str, &str, &str, &str)> = chunk.iter().zip(rooms.iter())
                .map(|(id, room)| (id.as_str(), room.as_str(), "synth body\n", "active"))
                .collect();
            bodies.push(get_body(&records));
        }
        (ids, bodies)
    }

    #[test]
    fn estate_list_exact_file_sends_wing_and_room() {
        // Production callers pass exact file locations (3 segments, no trailing slash).
        // estate_list must send wing="Agentic Memory" with the full location as room
        // and limit 200, then one batched moot_memory_get for the page's ids.
        let daemon = MockDaemon::alive(vec![
            (200, V2_LIST_RESP),
            (200, V2_GET_RESP),
        ]);
        let records = estate_list(&daemon, 4242, "harness-import/slug1/MEMORY.md").expect("list ok");
        assert_eq!(records.len(), 1, "must return 1 record after the batch get");
        assert_eq!(records[0].id, "m1");
        assert_eq!(records[0].location, "harness-import/slug1/MEMORY.md");
        assert_eq!(records[0].content, "Memory Index content");
        assert!(!records[0].is_superseded);

        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 2, "must issue list then one batch get");
        let list_args = &calls[0]["params"]["arguments"];
        assert_eq!(calls[0]["params"]["name"], "moot_memory_list");
        assert_eq!(list_args["wing"], "Agentic Memory", "v2 file memories live in Agentic Memory wing");
        assert_eq!(list_args["room"], "harness-import/slug1/MEMORY.md", "exact file → full location as room");
        assert_eq!(list_args["limit"], 200, "always ask for the server maximum page");
        assert!(list_args.get("cursor").is_none(), "first page carries no cursor");
        assert!(list_args.get("location_prefix").is_none(), "no v1 location_prefix arg");
        let get_args = &calls[1]["params"]["arguments"];
        assert_eq!(calls[1]["params"]["name"], "moot_memory_get");
        assert_eq!(get_args["memory_ids"], json!(["m1"]), "batch form carries memory_ids");
        assert!(get_args.get("memory_id").is_none(), "batch form never sends the single-id key");
    }

    #[test]
    fn estate_list_directory_prefix_omits_room() {
        // Directory-prefix callers pass a trailing-slash prefix.
        // estate_list must omit room and filter client-side by the normalized prefix.
        // Two list items: one matching, one from a different slug (filtered out).
        let list_resp = list_body(&["m1", "m2"], false, None);
        let get_resp = get_body(&[
            ("m1", "harness-import/slug1/MEMORY.md", "c1", "active"),
            ("m2", "harness-import/other-slug/notes.md", "c2", "active"),
        ]);
        let daemon = MockDaemon::alive(vec![
            (200, list_resp.as_str()),
            (200, get_resp.as_str()),
        ]);
        let records = estate_list(&daemon, 4242, "harness-import/slug1/").expect("list ok");
        // Only m1 matches the prefix "harness-import/slug1/" (m2 is other-slug).
        assert_eq!(records.len(), 1, "client-side filter must exclude non-matching locations");
        assert_eq!(records[0].id, "m1");

        let calls = daemon.calls.lock().unwrap();
        // list call + one batch get = 2 total
        assert_eq!(calls.len(), 2);
        let list_args = &calls[0]["params"]["arguments"];
        assert_eq!(calls[0]["params"]["name"], "moot_memory_list");
        assert_eq!(list_args["wing"], "Agentic Memory");
        // Directory prefix: no room filter.
        assert!(list_args.get("room").is_none(), "directory prefix must not send room");
        assert_eq!(calls[1]["params"]["arguments"]["memory_ids"], json!(["m1", "m2"]));
    }

    #[test]
    fn estate_list_empty_prefix_returns_empty() {
        // Empty prefix must return empty without calling the daemon.
        let daemon = MockDaemon::alive(vec![]);
        let records = estate_list(&daemon, 4242, "").expect("empty prefix is Ok");
        assert_eq!(records.len(), 0);
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 0, "empty prefix must not call daemon");
    }

    #[test]
    fn estate_list_leading_slash_normalized() {
        // Leading slash is normalized away; both ports must agree on this shape.
        let daemon = MockDaemon::alive(vec![
            (200, V2_LIST_RESP),
            (200, V2_GET_RESP),
        ]);
        let records = estate_list(&daemon, 4242, "/harness-import/slug1/MEMORY.md").expect("list ok");
        assert_eq!(records.len(), 1, "leading slash must be stripped before matching");
        let calls = daemon.calls.lock().unwrap();
        // Must still supply room = the normalized prefix (without leading slash).
        let list_args = &calls[0]["params"]["arguments"];
        assert_eq!(list_args["room"], "harness-import/slug1/MEMORY.md");
    }

    #[test]
    fn estate_list_walks_every_page_and_batches_get() {
        // Two pages (200 + 7 ids), then ceil(207 / 50) = 5 get frames of at most 50 ids.
        let (ids, bodies) = two_page_run();
        let mut queue = vec![(200, PAGE1_FIXTURE), (200, PAGE2_FIXTURE)];
        queue.extend(bodies.iter().map(|b| (200, b.as_str())));
        let daemon = MockDaemon::alive(queue);

        let records = estate_list(&daemon, 4242, "harness-import/").expect("list ok");
        assert_eq!(records.len(), 207, "every id on every page becomes a record");
        let got: std::collections::HashSet<&str> = records.iter().map(|r| r.id.as_str()).collect();
        assert!(ids.iter().all(|id| got.contains(id.as_str())), "no id dropped across pages");

        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 7, "2 list frames + 5 get frames");
        assert_eq!(calls[0]["params"]["name"], "moot_memory_list");
        assert!(calls[0]["params"]["arguments"].get("cursor").is_none(), "first page has no cursor");
        assert_eq!(calls[1]["params"]["name"], "moot_memory_list");
        assert_eq!(
            calls[1]["params"]["arguments"]["cursor"],
            fixture_next_cursor(PAGE1_FIXTURE),
            "second page continues from page1's next_cursor"
        );
        let get_frames: Vec<&Value> = calls.iter().filter(|c| c["params"]["name"] == "moot_memory_get").collect();
        assert_eq!(get_frames.len(), 5, "ceil(207 / 50) get frames");
        let lens: Vec<usize> = get_frames.iter()
            .map(|c| c["params"]["arguments"]["memory_ids"].as_array().expect("memory_ids array").len())
            .collect();
        assert_eq!(lens, [50, 50, 50, 50, 7]);
        assert!(lens.iter().all(|n| *n <= 50), "no get frame carries more than 50 ids");
        assert_eq!(get_frames[0]["params"]["arguments"]["memory_ids"], json!(ids[..50]), "first chunk is page1's first 50 ids in order");
    }

    #[test]
    fn estate_get_sends_moot_memory_get_frame() {
        // estate_get must send moot_memory_get with the correct key and parse
        // placement.room as location, plus state="superseded" → is_superseded=true.
        let get_resp = r##"{"result":{"structuredContent":{"data":{"memories":[{"memory_id":"m1","placement":{"wing":"Agentic Memory","room":"harness-import/slug1/MEMORY.md"},"content":"Index content","event_time":"2026-09-09T00:00:00Z","state":"superseded"}]},"surface_version":"v2","tool":"moot_memory_get"},"isError":false}}"##;
        let daemon = MockDaemon::alive(vec![(200, get_resp)]);
        let record = estate_get(&daemon, 4242, "m1").expect("call ok").expect("must return a record");
        assert_eq!(record.id, "m1");
        assert_eq!(record.location, "harness-import/slug1/MEMORY.md", "location from placement.room");
        assert_eq!(record.content, "Index content");
        assert!(record.is_superseded, "state=superseded → is_superseded=true");
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["params"]["name"], "moot_memory_get");
        // v2 uses memory_id, not legacy id.
        assert_eq!(calls[0]["params"]["arguments"]["memory_id"], "m1");
        assert!(calls[0]["params"]["arguments"].get("id").is_none(), "no legacy id arg");
    }

    #[test]
    fn estate_get_none_on_memory_not_found_and_err_on_other_refusals() {
        // memory_not_found is the daemon's answer for an unknown or superseded id: no row.
        let daemon = MockDaemon::alive(vec![(200, MEMORY_NOT_FOUND_FRAME)]);
        assert_eq!(estate_get(&daemon, 4242, "gone"), Ok(None));
        // Any other refusal is an error the caller must see.
        let daemon = MockDaemon::alive(vec![(200, ESTATE_UNAVAILABLE_FRAME)]);
        assert_eq!(
            estate_get(&daemon, 4242, "m1"),
            Err(DaemonCallError::Refused { code: "estate_unavailable".into(), message: "estate unavailable".into() })
        );
        // A top-level JSON-RPC error object is a refusal with code rpc_error.
        let daemon = MockDaemon::alive(vec![(200, RPC_ERROR_BODY)]);
        assert_eq!(
            estate_get(&daemon, 4242, "m1"),
            Err(DaemonCallError::Refused { code: "rpc_error".into(), message: "unknown memory_id".into() })
        );
        // Transport failures stay transport failures.
        let daemon = MockDaemon::alive(vec![(500, "internal error")]);
        assert!(matches!(estate_get(&daemon, 4242, "m1"), Err(DaemonCallError::Transport(_))));
    }

    #[test]
    fn estate_list_parses_v2_fixture_envelope() {
        // The recorded list fixture (two rows) drives estate_list through the mock;
        // the batch get answers with the recorded get fixture's record for the
        // first id plus a synthesized record for the second (no recorded get
        // exists for it). Assertions are on the returned EstateRecord.
        let ids = fixture_page_ids(LIST_FIXTURE);
        assert_eq!(ids.len(), 2);
        let recorded: Value = serde_json::from_str(GET_FIXTURE).expect("fixture must parse");
        let recorded_item = recorded.pointer("/result/structuredContent/data/memories/0").expect("record").clone();
        assert_eq!(recorded_item["memory_id"], ids[0], "get fixture answers the list fixture's first id");
        let batch = json!({"jsonrpc": "2.0", "id": 1, "result": {"structuredContent": {"data": {"memories": [
            recorded_item,
            {"memory_id": ids[1], "placement": {"wing": "Agentic Memory", "room": "harness-import/testslug/second.md"}, "content": "second", "event_time": "2026-09-09T00:00:00Z", "state": "active"}
        ]}, "surface_version": "v2", "tool": "moot_memory_get"}, "isError": false}}).to_string();
        let daemon = MockDaemon::alive(vec![(200, LIST_FIXTURE), (200, batch.as_str())]);

        let records = estate_list(&daemon, 4242, "harness-import/").expect("list ok");
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].id, "23dcd969-47eb-412b-854f-8ca8eccb5ac3");
        assert_eq!(records[0].location, "harness-import/testslug/notes.md");
        assert_eq!(records[0].content, "# Notes for testslug");
        assert!(!records[0].is_superseded);
        assert_eq!(records[1].id, ids[1]);
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0]["params"]["arguments"]["limit"], 200);
        assert_eq!(calls[1]["params"]["arguments"]["memory_ids"], json!(ids));
    }

    #[test]
    fn estate_get_parses_v2_fixture_envelope() {
        // The recorded moot_memory_get body drives estate_get through the mock.
        let daemon = MockDaemon::alive(vec![(200, GET_FIXTURE)]);
        let record = estate_get(&daemon, 4242, "23dcd969-47eb-412b-854f-8ca8eccb5ac3")
            .expect("call ok")
            .expect("fixture holds one record");
        assert_eq!(record.id, "23dcd969-47eb-412b-854f-8ca8eccb5ac3");
        assert_eq!(record.location, "harness-import/testslug/notes.md", "location from placement.room");
        assert_eq!(record.content, "# Notes for testslug");
        assert!(!record.is_superseded, "state=active");
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls[0]["params"]["arguments"]["memory_id"], "23dcd969-47eb-412b-854f-8ca8eccb5ac3");
    }

    // ── Front matter: the restore id header ──────────────────────────────────

    #[test]
    fn front_matter_inject_and_strip_are_byte_inverses() {
        // Vector 1: a real memory file with a metadata: mapping. The id goes
        // right after `metadata:`; the round trip is exact.
        let injected = front_matter_inject(SHAPE1_BODY, "abc");
        let lines: Vec<&str> = injected.lines().collect();
        assert_eq!(lines.iter().filter(|l| **l == "---").count(), 2, "exactly one front-matter document");
        let meta = lines.iter().position(|l| *l == "metadata:").expect("metadata: kept");
        assert_eq!(lines[meta + 1], "  moot_memory_id: abc", "id line sits right after metadata:");
        let keys: Vec<&str> = lines[1..lines.len() - 2].iter().map(|l| l.split(':').next().unwrap()).collect();
        assert_eq!(keys, ["name", "description", "metadata", "  moot_memory_id", "  node_type", "  type", "  originSessionId"]);
        assert_eq!(front_matter_strip(&injected), (Some("abc".to_string()), SHAPE1_BODY.to_string()));

        // Vector 2: a block without metadata: gains the mapping before the fence.
        let v2 = "---\nname: x\n---\nbody\n";
        let injected = front_matter_inject(v2, "abc");
        assert_eq!(injected, "---\nname: x\nmetadata:\n  moot_memory_id: abc\n---\nbody\n");
        assert_eq!(front_matter_strip(&injected), (Some("abc".to_string()), v2.to_string()));

        // Vector 3: no block (MEMORY.md) gains the three-line header.
        let v3 = "# Memory Index\n";
        let injected = front_matter_inject(v3, "abc");
        assert_eq!(injected, "---\nmetadata:\n  moot_memory_id: abc\n---\n# Memory Index\n");
        assert_eq!(front_matter_strip(&injected), (Some("abc".to_string()), v3.to_string()));

        // No id line: nothing to strip, content unchanged.
        assert_eq!(front_matter_strip(SHAPE1_BODY), (None, SHAPE1_BODY.to_string()));
        assert_eq!(front_matter_strip(v2), (None, v2.to_string()));
        assert_eq!(front_matter_strip(v3), (None, v3.to_string()));
    }

    #[test]
    fn front_matter_field_round_trip_leaves_memory_id_line_in_place() {
        // A second key on the corpus-shaped body: the new line sits right after
        // `metadata:`, ahead of the id line; stripping it gives back the exact
        // bytes and never disturbs `moot_memory_id`.
        let with_id = front_matter_inject(SHAPE1_BODY, "abc");
        let both = front_matter_inject_field(&with_id, FRONT_MATTER_GENERATED_INDEX_KEY, "true");
        let lines: Vec<&str> = both.lines().collect();
        let meta = lines.iter().position(|l| *l == "metadata:").expect("metadata: kept");
        assert_eq!(lines[meta + 1], "  moot_generated_index: true");
        assert_eq!(lines[meta + 2], "  moot_memory_id: abc");
        assert_eq!(lines.iter().filter(|l| **l == "---").count(), 2, "exactly one front-matter document");

        assert_eq!(
            front_matter_strip_field(&both, FRONT_MATTER_GENERATED_INDEX_KEY),
            (Some("true".to_string()), with_id.clone())
        );
        // Stripping the id instead leaves the generated-index line behind.
        assert_eq!(
            front_matter_strip(&both),
            (Some("abc".to_string()), front_matter_inject_field(SHAPE1_BODY, FRONT_MATTER_GENERATED_INDEX_KEY, "true"))
        );
        // A key that is absent strips nothing.
        assert_eq!(
            front_matter_strip_field(&with_id, FRONT_MATTER_GENERATED_INDEX_KEY),
            (None, with_id.clone())
        );
    }

    // ── Regenerated MEMORY.md index: marked at disable, discarded at enable ───

    /// The bytes `regenerate_memory_index` writes for restored `a.md` and
    /// `b.md`. Shared with the Swift port, which must write the identical bytes.
    const GENERATED_INDEX_AB: &str =
        "---\nmetadata:\n  moot_generated_index: true\n---\n# Memory Index\n\n- [a.md](a.md)\n- [b.md](b.md)\n";

    #[test]
    fn regenerated_index_bytes_are_pinned() {
        let dir = tempfile::tempdir().unwrap();
        let claude_dir = dir.path().join("claude");
        let memory_dir = claude_dir.join("projects").join("slug").join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        // Locations arrive in the estate's order; the index is byte-ordered.
        let locations = vec![
            "harness-import/slug/b.md".to_string(),
            "harness-import/slug/a.md".to_string(),
        ];
        regenerate_memory_index(&claude_dir, &locations);
        assert_eq!(fs::read_to_string(memory_dir.join("MEMORY.md")).unwrap(), GENERATED_INDEX_AB);
        assert_eq!(
            front_matter_strip_field(GENERATED_INDEX_AB, FRONT_MATTER_GENERATED_INDEX_KEY),
            (Some("true".to_string()), "# Memory Index\n\n- [a.md](a.md)\n- [b.md](b.md)\n".to_string())
        );
        assert_eq!(front_matter_strip(GENERATED_INDEX_AB).0, None, "a regenerated index carries no estate id");
    }

    #[test]
    fn regenerated_index_is_discarded_on_reingest_not_filed() {
        // Rows a.md and b.md, no MEMORY.md row: restore writes both files with
        // their ids plus the marked index. Re-enable matches the two rows and
        // discards the index without an estate call, so the row count is
        // unchanged by the cycle.
        let dir = tempfile::tempdir().unwrap();
        let claude_dir = dir.path().join("claude");
        let memory_dir = claude_dir.join("projects").join("slug").join("memory");
        let list_resp = list_body(&["id-a", "id-b"], false, None);
        let get_resp = get_body(&[
            ("id-a", "harness-import/slug/a.md", "alpha\n", "active"),
            ("id-b", "harness-import/slug/b.md", "beta\n", "active"),
        ]);
        let daemon = MockDaemon::alive(vec![(200, list_resp.as_str()), (200, get_resp.as_str())]);

        let summary = restore_memories(&daemon, 4242, true, false, &claude_dir);
        assert_eq!(summary, "  Restore: 2 written; estate rows left unchanged.");
        let mut names: Vec<String> = fs::read_dir(&memory_dir).unwrap().flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        assert_eq!(names, ["MEMORY.md", "a.md", "b.md"]);
        assert_eq!(fs::read_to_string(memory_dir.join("MEMORY.md")).unwrap(), GENERATED_INDEX_AB);
        assert_eq!(fs::read_to_string(memory_dir.join("a.md")).unwrap(), front_matter_inject("alpha\n", "id-a"));

        // Re-enable. Files are processed in byte order: MEMORY.md, a.md, b.md.
        // The index makes no estate call; each row is looked up once.
        let get_a = get_body(&[("id-a", "harness-import/slug/a.md", "alpha\n", "active")]);
        let get_b = get_body(&[("id-b", "harness-import/slug/b.md", "beta\n", "active")]);
        let daemon = MockDaemon::alive(vec![(200, get_a.as_str()), (200, get_b.as_str())]);
        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.matched, 2);
        assert_eq!(result.discarded_indexes, 1);
        assert_eq!(result.filed, 0);
        assert_eq!(result.removed, 3);
        assert_eq!(result.skipped, 0);
        assert!(result.skip_reasons.is_empty(), "{:?}", result.skip_reasons);
        let names = call_names(&daemon);
        assert_eq!(names, ["moot_memory_get", "moot_memory_get"]);
        assert!(!names.iter().any(|n| n == "moot_file_memory" || n == "moot_update_memory"));
        assert!(!memory_dir.exists(), "emptied memory dir is removed");
    }

    #[test]
    fn authored_memory_index_without_markers_files_as_list() {
        // A hand-written MEMORY.md has neither an id nor the generated marker:
        // it files fresh with kind "list", exactly as before.
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        fs::write(memory_dir.join("MEMORY.md"), b"# Memory Index\n\n- [note.md](note.md)\n").unwrap();
        let daemon = MockDaemon::alive(vec![(200, r#"{"result":{"content":[{"text":"ok"}]}}"#)]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 1);
        assert_eq!(result.discarded_indexes, 0);
        assert_eq!(result.removed, 1);
        assert_eq!(call_names(&daemon), ["moot_file_memory"]);
        let calls = daemon.calls.lock().unwrap();
        let args = &calls[0]["params"]["arguments"];
        assert_eq!(args["kind"], "list");
        assert_eq!(args["content"], "# Memory Index\n\n- [note.md](note.md)\n");
        drop(calls);
        assert!(!memory_dir.join("MEMORY.md").exists());
    }

    // ── Restore: rows untouched, files carry ids, re-ingest matches ──────────

    #[test]
    fn restore_leaves_rows_unchanged_and_reingest_matches() {
        let dir = tempfile::tempdir().unwrap();
        let claude_dir = dir.path().join("claude");
        let memory_dir = claude_dir.join("projects").join("slug").join("memory");
        let index_body = "# Memory Index\n";
        let list_resp = list_body(&["id-index", "id-note"], false, None);
        let get_resp = get_body(&[
            ("id-index", "harness-import/slug/MEMORY.md", index_body, "active"),
            ("id-note", "harness-import/slug/note.md", SHAPE1_BODY, "active"),
        ]);
        let daemon = MockDaemon::alive(vec![(200, list_resp.as_str()), (200, get_resp.as_str())]);

        let summary = restore_memories(&daemon, 4242, true, false, &claude_dir);
        assert_eq!(summary, "  Restore: 2 written; estate rows left unchanged.");
        assert!(
            !call_names(&daemon).iter().any(|n| n == "moot_update_memory"),
            "restore never mutates an estate row"
        );
        assert_eq!(
            fs::read_to_string(memory_dir.join("MEMORY.md")).unwrap(),
            front_matter_inject(index_body, "id-index")
        );
        assert_eq!(
            fs::read_to_string(memory_dir.join("note.md")).unwrap(),
            front_matter_inject(SHAPE1_BODY, "id-note")
        );

        // Re-enable: the same rows are still active, so every file matches.
        // Files are processed in name order: MEMORY.md, then note.md.
        let get_index = get_body(&[("id-index", "harness-import/slug/MEMORY.md", index_body, "active")]);
        let get_note = get_body(&[("id-note", "harness-import/slug/note.md", SHAPE1_BODY, "active")]);
        let daemon = MockDaemon::alive(vec![(200, get_index.as_str()), (200, get_note.as_str())]);
        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.matched, 2);
        assert_eq!(result.filed, 0);
        assert_eq!(result.removed, 2);
        assert_eq!(result.skipped, 0);
        assert_eq!(call_names(&daemon), ["moot_memory_get", "moot_memory_get"]);
        assert!(!memory_dir.exists(), "emptied memory dir is removed");
    }

    #[test]
    fn restore_restarts_enumeration_on_stale_cursor() {
        // page1, then a cursor_stale refusal on the second page, then the full
        // run again: every record lands on disk and the retry starts without a cursor.
        let (ids, bodies) = two_page_run();
        let mut queue = vec![
            (200, PAGE1_FIXTURE),
            (200, CURSOR_STALE_FRAME),
            (200, PAGE1_FIXTURE),
            (200, PAGE2_FIXTURE),
        ];
        queue.extend(bodies.iter().map(|b| (200, b.as_str())));
        let daemon = MockDaemon::alive(queue);
        let dir = tempfile::tempdir().unwrap();
        let claude_dir = dir.path().join("claude");

        let summary = restore_memories(&daemon, 4242, true, false, &claude_dir);
        assert_eq!(summary, "  Restore: 207 written; estate rows left unchanged.");

        let memory_dir = claude_dir.join("projects").join("bigslug").join("memory");
        let mut with_id = std::collections::HashSet::new();
        let mut regenerated = Vec::new();
        for entry in fs::read_dir(&memory_dir).unwrap().flatten() {
            let text = fs::read_to_string(entry.path()).unwrap();
            match front_matter_strip(&text).0 {
                Some(id) => { with_id.insert(id); }
                None => regenerated.push(entry.file_name().to_string_lossy().into_owned()),
            }
        }
        assert_eq!(with_id.len(), 207, "one file per record, each carrying its id");
        assert!(ids.iter().all(|id| with_id.contains(id)), "every listed id reached disk");
        assert!(regenerated.iter().all(|f| f == "MEMORY.md"), "only the regenerated index lacks an id: {regenerated:?}");

        let calls = daemon.calls.lock().unwrap();
        let list_frames: Vec<&Value> = calls.iter().filter(|c| c["params"]["name"] == "moot_memory_list").collect();
        assert_eq!(list_frames.len(), 4, "page1, stale page2, page1 again, page2");
        assert!(list_frames[1]["params"]["arguments"].get("cursor").is_some(), "second frame carried the cursor");
        assert!(list_frames[2]["params"]["arguments"].get("cursor").is_none(), "restart begins without a cursor");
        assert!(list_frames[3]["params"]["arguments"].get("cursor").is_some());
        assert!(!calls.iter().any(|c| c["params"]["name"] == "moot_update_memory"));
    }

    #[test]
    fn restore_fails_closed_when_batch_get_is_refused() {
        // The list succeeds, the batch get is refused: nothing is written and the
        // summary says so. A refusal is never an empty wing.
        let list_resp = list_body(&["a", "b", "c"], false, None);
        let daemon = MockDaemon::alive(vec![(200, list_resp.as_str()), (200, MEMORY_NOT_FOUND_FRAME)]);
        let dir = tempfile::tempdir().unwrap();
        let claude_dir = dir.path().join("claude");

        let summary = restore_memories(&daemon, 4242, true, false, &claude_dir);
        assert!(summary.starts_with("  Restore FAILED"), "summary was: {summary}");
        assert!(summary.contains("memory_not_found"));
        assert!(!claude_dir.exists(), "zero files written");
        assert_eq!(call_names(&daemon), ["moot_memory_list", "moot_memory_get"]);
    }

    #[test]
    fn estate_list_stale_cursor_gives_up_after_three_restarts() {
        // Four stale answers in a row: three restarts, then the refusal is returned.
        let daemon = MockDaemon::alive(vec![
            (200, CURSOR_STALE_FRAME),
            (200, CURSOR_STALE_FRAME),
            (200, CURSOR_STALE_FRAME),
            (200, CURSOR_STALE_FRAME),
        ]);
        let err = estate_list(&daemon, 4242, "harness").expect_err("must give up");
        assert!(matches!(err, DaemonCallError::Refused { ref code, .. } if code == "cursor_stale"));
        assert_eq!(call_names(&daemon).len(), 4, "initial attempt plus three restarts");
    }

    #[test]
    fn estate_get_batch_reports_missing_records_instead_of_dropping_them() {
        // Two ids asked, one record answered: the missing id is named, never dropped.
        let one = get_body(&[("a", "harness-import/slug/a.md", "a", "active")]);
        let daemon = MockDaemon::alive(vec![(200, one.as_str())]);
        let err = estate_get_batch(&daemon, 4242, &["a".to_string(), "b".to_string()]).expect_err("short batch is an error");
        match err {
            DaemonCallError::Refused { code, message } => {
                assert_eq!(code, "memory_not_found");
                assert!(message.contains("missing: b"), "message was: {message}");
            }
            other => panic!("expected Refused, got {other:?}"),
        }
    }

    #[test]
    fn estate_list_malformed_page_is_an_error_not_empty() {
        // A 200 body without data.memories / data.has_more is a malformed page.
        let daemon = MockDaemon::alive(vec![(200, r#"{"result":{"content":[{"text":""}]}}"#)]);
        assert_eq!(
            estate_list(&daemon, 4242, "harness"),
            Err(DaemonCallError::Transport("malformed page".to_string()))
        );
    }

    #[test]
    fn estate_list_has_more_without_next_cursor_is_an_error_not_a_truncated_wing() {
        // has_more true and no next_cursor: the rest of the wing is unreachable.
        // The pages read so far are never returned as the whole wing.
        let page = r##"{"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[{"memory_id":"a1","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"a1"}}}],"has_more":true,"revision":"r"}},"content":[]}}"##;
        let daemon = MockDaemon::alive(vec![(200, page)]);
        assert_eq!(
            estate_list(&daemon, 4242, "harness"),
            Err(DaemonCallError::Transport("malformed page".to_string()))
        );
        assert_eq!(daemon.calls.lock().unwrap().len(), 1, "no get is attempted on an incomplete listing");
    }

    #[test]
    fn estate_list_repeated_cursor_is_an_error_not_a_truncated_wing() {
        // Two pages that hand back the same cursor: the second page cannot be walked past.
        let page1 = r##"{"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[{"memory_id":"a1","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"a1"}}}],"has_more":true,"next_cursor":"c1","revision":"r"}},"content":[]}}"##;
        let page2 = r##"{"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[{"memory_id":"a2","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"a2"}}}],"has_more":true,"next_cursor":"c1","revision":"r"}},"content":[]}}"##;
        let daemon = MockDaemon::alive(vec![(200, page1), (200, page2)]);
        assert_eq!(
            estate_list(&daemon, 4242, "harness"),
            Err(DaemonCallError::Transport("malformed page".to_string()))
        );
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[1]["params"]["arguments"]["cursor"], "c1");
    }

    #[test]
    fn estate_list_alternating_cursor_is_an_error_not_an_infinite_loop() {
        // c1, c2, c1: the third page repeats the FIRST cursor, not the one
        // immediately before it. A server alternating between two cursors
        // must not spin this client forever — every cursor seen is tracked,
        // not just the most recent one.
        let page1 = r##"{"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[{"memory_id":"a1","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"a1"}}}],"has_more":true,"next_cursor":"c1","revision":"r"}},"content":[]}}"##;
        let page2 = r##"{"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[{"memory_id":"a2","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"a2"}}}],"has_more":true,"next_cursor":"c2","revision":"r"}},"content":[]}}"##;
        let page3 = r##"{"result":{"isError":false,"structuredContent":{"surface_version":"v2","tool":"moot_memory_list","data":{"memories":[{"memory_id":"a3","fetch":{"tool":"moot_memory_get","arguments":{"memory_id":"a3"}}}],"has_more":true,"next_cursor":"c1","revision":"r"}},"content":[]}}"##;
        let daemon = MockDaemon::alive(vec![(200, page1), (200, page2), (200, page3)]);
        assert_eq!(
            estate_list(&daemon, 4242, "harness"),
            Err(DaemonCallError::Transport("malformed page".to_string()))
        );
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 3, "the loop must stop at the third page, not spin forever");
        assert_eq!(calls[1]["params"]["arguments"]["cursor"], "c1");
        assert_eq!(calls[2]["params"]["arguments"]["cursor"], "c2");
    }

    // ── Live round trip (opt-in: MOOT_HARNESS_LIVE_PORT) ─────────────────────

    /// Disable → re-enable against a running scratch daemon. Every harness row
    /// is restored with its id, every restored file re-ingests as a match, every
    /// regenerated index is discarded rather than filed, and the set of ids is
    /// unchanged. Run with
    /// `MOOT_HARNESS_LIVE_PORT=<port> cargo test --offline live_round_trip -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn live_round_trip_against_scratch_daemon() {
        let Some(port) = std::env::var("MOOT_HARNESS_LIVE_PORT").ok().and_then(|p| p.parse::<u16>().ok()) else {
            println!("LIVE ROUND TRIP skipped: MOOT_HARNESS_LIVE_PORT not set");
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        let claude_dir = dir.path().join("claude");

        let before = estate_list(&LiveDaemon, port, "harness").expect("live list before");
        let mut before_ids: Vec<String> = before.iter().map(|r| r.id.clone()).collect();
        before_ids.sort();
        before_ids.dedup();
        let by_id: std::collections::HashMap<&str, &EstateRecord> = before.iter().map(|r| (r.id.as_str(), r)).collect();

        let summary = restore_memories(&LiveDaemon, port, true, false, &claude_dir);
        assert!(summary.starts_with("  Restore: "), "summary was: {summary}");

        // Every restored file strips back to (Some(id), the row's content). The
        // regenerated MEMORY.md indexes (no id) carry the generated marker and
        // stay on disk: re-ingest must discard them, never file them.
        let mut restored = 0usize;
        let mut regenerated = 0usize;
        let mut slug_dirs = Vec::new();
        for project in fs::read_dir(claude_dir.join("projects")).unwrap().flatten() {
            let memory_dir = project.path().join("memory");
            let slug = project.file_name().to_string_lossy().into_owned();
            for entry in fs::read_dir(&memory_dir).unwrap().flatten() {
                let text = fs::read_to_string(entry.path()).unwrap();
                match front_matter_strip(&text) {
                    (Some(id), body) => {
                        let record = by_id.get(id.as_str()).unwrap_or_else(|| panic!("restored id {id} not in before set"));
                        assert_eq!(body, record.content, "restored body differs for {id}");
                        restored += 1;
                    }
                    (None, body) => {
                        assert_eq!(entry.file_name(), "MEMORY.md", "only a regenerated index lacks an id");
                        assert_eq!(
                            front_matter_strip_field(&body, FRONT_MATTER_GENERATED_INDEX_KEY).0.as_deref(),
                            Some("true"),
                            "a regenerated index carries the generated marker"
                        );
                        regenerated += 1;
                    }
                }
            }
            slug_dirs.push((slug, memory_dir));
        }

        let mut matched = 0usize;
        let mut filed = 0usize;
        let mut discarded_indexes = 0usize;
        for (slug, memory_dir) in &slug_dirs {
            let r = ingest_project(&LiveDaemon, port, slug, memory_dir);
            assert!(r.skip_reasons.is_empty(), "skips for {slug}: {:?}", r.skip_reasons);
            matched += r.matched;
            filed += r.filed;
            discarded_indexes += r.discarded_indexes;
        }
        assert_eq!(matched, restored, "every restored file re-ingests as a match");
        assert_eq!(discarded_indexes, regenerated, "every regenerated index is discarded");
        assert_eq!(filed, 0, "nothing is filed twice");

        let after = estate_list(&LiveDaemon, port, "harness").expect("live list after");
        let mut after_ids: Vec<String> = after.iter().map(|r| r.id.clone()).collect();
        after_ids.sort();
        after_ids.dedup();
        assert_eq!(after_ids, before_ids, "the id set is unchanged by disable + re-enable");
        let mut locations: Vec<&str> = after.iter().map(|r| r.location.as_str()).collect();
        locations.sort();
        let unique = locations.len();
        locations.dedup();
        assert_eq!(locations.len(), unique, "no duplicate locations after the round trip");
        println!(
            "LIVE ROUND TRIP {port}: before={} after={} restored={restored} matched={matched} discarded_indexes={discarded_indexes} ids={}",
            before_ids.len(),
            after_ids.len(),
            after_ids.join(",")
        );
        if before_ids.len() > 200 {
            assert!(restored > 200, "a wing over one page must restore past the first page");
        }
    }

    // ── Finding 1: hook-path timeout constants ────────────────────────────────

    #[test]
    fn hook_timeout_constants_are_2_seconds() {
        // These constants gate the hook-path HTTP client. Raising them above 2s
        // risks freezing Claude Code's PreToolUse dispatch; lowering them below
        // ~0.5s risks spurious timeouts on a loaded machine. Do not change without
        // understanding the latency contract with Claude Code's hook dispatcher.
        assert_eq!(HOOK_CONNECT_TIMEOUT_SECS, 2, "hook connect timeout must be 2s");
        assert_eq!(HOOK_READ_TIMEOUT_SECS, 2, "hook read timeout must be 2s");
    }

    #[test]
    fn hook_post_frame_fails_fast_on_non_listening_port() {
        // A port that is not listening returns ECONNREFUSED immediately.
        // This verifies hook_post_frame returns Err (triggering allow-through)
        // rather than hanging for HOOK_READ_TIMEOUT_SECS seconds.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener); // close — port is now not listening
        let result = hook_post_frame(port, br#"{"jsonrpc":"2.0"}"#);
        assert!(result.is_err(), "hook_post_frame must fail on non-listening port");
    }

    // ── Finding 2: remove_harness_state ──────────────────────────────────────

    #[test]
    fn remove_harness_state_cleans_enabled_fixture() {
        // Build a full enabled-state fixture: settings.json with our hook entry,
        // CLAUDE.md with the sentinel block, and the hook script on disk.
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();

        let settings_path = home.join(".claude").join("settings.json");
        fs::create_dir_all(settings_path.parent().unwrap()).unwrap();

        let hook_path = hook_script_path_for_home(home);
        let hook_path_str = hook_path.to_string_lossy().into_owned();

        // settings.json with hook entry + autoMemoryEnabled:false.
        let settings = merge_settings(json!({}), &hook_path_str);
        write_settings(&settings_path, &settings).unwrap();

        // CLAUDE.md with sentinel block.
        let claude_md = home.join(".claude").join("CLAUDE.md");
        let claude_content = install_sentinel("# Existing content\n");
        fs::write(&claude_md, claude_content.as_bytes()).unwrap();

        // Hook script.
        fs::create_dir_all(hook_path.parent().unwrap()).unwrap();
        fs::write(&hook_path, b"#!/bin/sh\nexec mootx01 hook-capture\n").unwrap();

        // Run remove_harness_state.
        let changed = remove_harness_state(home);
        assert!(changed, "must report changes when state was present");

        // settings.json must have no hook entry.
        let updated = read_settings(&settings_path).unwrap();
        assert!(
            !hook_entry_present(&updated, &hook_path_str),
            "hook entry must be removed from settings.json"
        );
        // autoMemoryEnabled must be absent (restored to Claude Code default).
        assert!(
            updated.get("autoMemoryEnabled").is_none(),
            "autoMemoryEnabled must be removed"
        );

        // CLAUDE.md must not have our sentinel.
        let updated_claude = fs::read_to_string(&claude_md).unwrap();
        assert!(
            !has_sentinel(&updated_claude),
            "CLAUDE.md sentinel must be removed"
        );

        // Hook script must be gone.
        assert!(!hook_path.exists(), "hook script must be deleted");
    }

    #[test]
    fn remove_harness_state_on_clean_fixture_is_noop() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        // No harness state set up — nothing to clean.
        let changed = remove_harness_state(home);
        assert!(!changed, "must report no changes when harness-memory was not enabled");
    }

    // ── Finding 3: hook_script_content uses absolute binary path ─────────────

    #[test]
    fn hook_script_content_uses_absolute_binary_path() {
        let content = hook_script_content("/home/alice/.mootx01/bin/mootx01");
        // Must exec the absolute path, not the bare binary name.
        assert!(
            content.contains("\"/home/alice/.mootx01/bin/mootx01\" hook-capture"),
            "hook script must exec the absolute binary path; got:\n{content}"
        );
        // Must not fall back to PATH-relative "mootx01".
        assert!(
            !content.contains("exec mootx01 hook-capture"),
            "hook script must not use bare PATH-relative binary name; got:\n{content}"
        );
    }

    // ── Finding 5: discover_restore_records covers both classes in one call ──

    #[test]
    fn discover_restore_records_deduplicates_harness_import_under_harness_prefix() {
        // One list call with prefix "harness" covers harness-import/* and harness/*
        // (prefix overlap). The record must appear exactly once and the estate
        // must see exactly one moot_memory_list frame.
        let list_resp = list_body(&["d1", "d2", "d3"], false, None);
        let get_resp = get_body(&[
            ("d1", "harness-import/slug/note.md", "c", "active"),
            ("d2", "harness/slug/captured.md", "c", "active"),
            ("d3", "harnessless/slug/other.md", "c", "active"),
        ]);
        let daemon = MockDaemon::alive(vec![(200, list_resp.as_str()), (200, get_resp.as_str())]);
        let records = discover_restore_records(&daemon, 4242).expect("discover ok");
        let ids: Vec<&str> = records.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, ["d1", "d2"], "harness-import and harness rows once each; other prefixes excluded");
        let names = call_names(&daemon);
        assert_eq!(names.iter().filter(|n| *n == "moot_memory_list").count(), 1, "exactly one list frame");
        assert_eq!(names.len(), 2, "list then one batch get");
    }

    // ── Finding 6: memory_kind is case-insensitive ────────────────────────────

    #[test]
    fn memory_kind_is_case_insensitive() {
        // Matches Swift's filename.lowercased() == "memory.md" path.
        assert_eq!(memory_kind("MEMORY.md"), "list");
        assert_eq!(memory_kind("memory.md"), "list", "lowercase variant must return 'list'");
        assert_eq!(memory_kind("Memory.MD"), "list", "mixed case must return 'list'");
        assert_eq!(memory_kind("note.md"), "prose", "non-MEMORY.md must return 'prose'");
    }

    // ── Clock injection: capture_decision uses now_secs, not SystemTime::now() ──

    #[test]
    fn capture_decision_uses_injected_timestamp() {
        // Fixed epoch seconds for 2026-08-07T00:00:00Z.
        // Same value verified in iso8601_known_date above.
        let now_secs: u64 = 1786060800;
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);
        let result = capture_decision(
            &daemon, 4242,
            "test-project", "note.md",
            "test content",
            now_secs,
        );
        // capture_decision must return Some(deny json) on successful estate write.
        let json_str = result.expect("valid memory path + alive daemon must return Some(deny)");
        let v: Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(
            v.pointer("/hookSpecificOutput/permissionDecision"),
            Some(&json!("deny")),
            "successful capture must produce deny decision"
        );
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1, "one moot_file_memory frame expected");
        assert_eq!(calls[0]["params"]["name"], "moot_file_memory");
        assert_eq!(
            calls[0]["params"]["arguments"]["event_time"],
            "2026-08-07T00:00:00Z",
            "event_time must derive from injected now_secs, not SystemTime::now()"
        );
        assert_eq!(calls[0]["params"]["arguments"]["location"], "harness/test-project/note.md");
    }

    // ── extract_subject tests ────────────────────────────────────────────────

    #[test]
    fn extract_subject_returns_first_content_line() {
        let content = "# Heading\n\nThis is the first real line.\nAnd another.";
        let result = extract_subject(content, "notes.md");
        assert_eq!(result, "This is the first real line.");
    }

    #[test]
    fn extract_subject_truncates_at_120_chars() {
        let long_line = "x".repeat(200);
        let content = format!("# Heading\n{long_line}");
        let result = extract_subject(&content, "notes.md");
        assert_eq!(result.len(), 120);
        assert_eq!(result, "x".repeat(120));
    }

    #[test]
    fn extract_subject_falls_back_to_filename_stem_on_heading_only() {
        let content = "# Heading One\n## Heading Two\n### Heading Three";
        let result = extract_subject(content, "my-notes.md");
        assert_eq!(result, "my-notes");
    }

    #[test]
    fn extract_subject_falls_back_to_filename_stem_on_empty_content() {
        let result = extract_subject("", "ideas.md");
        assert_eq!(result, "ideas");
    }
}
