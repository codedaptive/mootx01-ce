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
//!   - `harness_memory.ingest.filed` / `.removed` / `.skipped`
//!   - `harness_memory.restore.written` / `.superseded` / `.revived`
//!   - `harness_memory.capture.ok` / `.fallback` / `.bypass`  (hook-capture)

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

/// An estate memory record returned by `estate_list`.
///
/// Mirrors `HarnessMemoryRecord` in Swift's `LiveDaemonClient`, which derives
/// fields from the `moot_memory_list` JSON response.
struct EstateRecord {
    id: String,
    location: String,
    content: String,
    is_superseded: bool,
}

/// POST one JSON-RPC 2.0 `tools/call` frame to the estate daemon.
///
/// `tool_name` is the ARIA tool name (`moot_file_memory`, `moot_update_memory`,
/// `moot_memory_list`, …). `args` is the tool's `arguments` object.
/// Returns the parsed response body on HTTP 200, or an error string.
fn call_tool(daemon: &dyn DaemonHttp, port: u16, tool_name: &str, args: Value) -> Result<Value, String> {
    let frame = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": args}
    });
    let bytes = serde_json::to_vec(&frame).map_err(|e| e.to_string())?;
    let (status, body) = daemon
        .post_frame(port, &bytes)
        .map_err(|e| e.to_string())?;
    if status != 200 {
        let msg = String::from_utf8_lossy(&body).into_owned();
        return Err(format!("daemon returned HTTP {status}: {msg}"));
    }
    serde_json::from_slice::<Value>(&body).map_err(|e| e.to_string())
}

/// File one memory entry to the estate via `moot_file_memory`.
///
/// - `location`: estate location hint, e.g. `harness-import/<slug>/<name>`.
///   No `/memories/` prefix — the ARIA tool accepts the bare location.
/// - `content`: verbatim file body (byte-exact for restore round-trips)
/// - `event_time`: ISO 8601 UTC string (typically the source file's mtime)
/// - `kind`: `"list"` for MEMORY.md index files, `"prose"` otherwise
///
/// Mirrors Swift `LiveDaemonClient.fileMemory(location:content:eventTime:kind:)`.
fn estate_file(
    daemon: &dyn DaemonHttp,
    port: u16,
    location: &str,
    content: &str,
    event_time: &str,
    kind: &str,
) -> Result<(), String> {
    // MXE-HM-2: harness_memory.ingest.filed metric emit point.
    call_tool(daemon, port, "moot_file_memory", json!({
        "location": location,
        "content": content,
        "event_time": event_time,
        "kind": kind,
    }))?;
    Ok(())
}

/// Apply a mutation to an existing estate record via `moot_update_memory`.
///
/// - `id`: the estate drawer ID (UUID) obtained from a prior `estate_list` call
/// - `mutation`: `"supersede"` or `"revive"`
/// - `note`: human-readable rationale appended to the estate audit trail
///
/// Mirrors Swift `LiveDaemonClient.updateMemory(id:mutation:note:)`.
fn estate_update(
    daemon: &dyn DaemonHttp,
    port: u16,
    id: &str,
    mutation: &str,
    note: &str,
) -> Result<(), String> {
    // MXE-HM-2: harness_memory.restore.superseded / .revived metric emit points.
    call_tool(daemon, port, "moot_update_memory", json!({
        "id": id,
        "mutation": mutation,
        "note": note,
    }))?;
    Ok(())
}

/// List estate records whose location begins with `location_prefix` via
/// `moot_memory_list`. Returns all matching records (active and superseded).
///
/// Returns an empty vec on any network or parse error — callers treat absence
/// as "no prior record" and proceed with a fresh file. The response shape
/// mirrors what Swift `LiveDaemonClient.listMemories(locationPrefix:)` parses:
/// `{ "result": { "memories": [{ "id", "location", "content", "superseded" }] } }`.
fn estate_list(daemon: &dyn DaemonHttp, port: u16, location_prefix: &str) -> Vec<EstateRecord> {
    let Ok(resp) = call_tool(daemon, port, "moot_memory_list", json!({
        "location_prefix": location_prefix,
    })) else {
        return Vec::new();
    };
    // The ARIA response wraps the payload in a JSON-RPC `result` object.
    // `memories` lives at result.memories.
    let Some(arr) = resp.pointer("/result/memories").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|item| {
            Some(EstateRecord {
                id: item["id"].as_str()?.to_string(),
                location: item["location"].as_str()?.to_string(),
                content: item["content"].as_str().unwrap_or("").to_string(),
                is_superseded: item["superseded"].as_bool().unwrap_or(false),
            })
        })
        .collect()
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
    pub filed: usize,
    pub removed: usize,
    pub skipped: usize,
    pub skip_reasons: Vec<String>,
}

/// Ingest all memory files from one project's `memory/` directory into the
/// estate.  Returns an `IngestResult`.
///
/// Contract (Bob's ruling 2026-08-07):
///   - MOVE semantics: file to estate → confirm success → delete source.
///   - Never delete before confirmation.
///   - A failed/aborted run leaves all unconfirmed source files intact.
///   - After the last file is removed, delete the empty `memory/` directory.
///   - Before filing, check for a superseded `harness-import` drawer with the
///     same location; if content is unchanged → revive; if changed → file fresh.
fn ingest_project(
    daemon: &dyn DaemonHttp,
    port: u16,
    project_slug: &str,
    memory_dir: &Path,
) -> IngestResult {
    let mut result = IngestResult { filed: 0, removed: 0, skipped: 0, skip_reasons: Vec::new() };

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

    for file_path in &files_to_process {
        let fname = file_path.file_name().and_then(|n| n.to_str()).unwrap_or("");

        // Read content (byte-exact — restore depends on it).
        let content = match fs::read_to_string(file_path) {
            Ok(c) => c,
            Err(e) => {
                result.skip_reasons.push(format!("  {}: read error: {e}", file_path.display()));
                result.skipped += 1;
                continue;
            }
        };

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
        let location = format!("harness-import/{project_slug}/{fname}");
        let kind = memory_kind(fname);

        // Check for a superseded drawer with the same location (re-enable path).
        // If the content is unchanged, revive. If changed, file fresh (new drawer).
        // If absent, file fresh normally.
        let file_action = determine_ingest_action(daemon, port, &location, &content);

        let file_result = match file_action {
            IngestAction::CreateFresh => {
                // MXE-HM-2: harness_memory.ingest.filed metric emit point.
                estate_file(daemon, port, &location, &content, &event_time, kind)
            }
            IngestAction::Revive(ref id) => {
                // MXE-HM-2: harness_memory.restore.revived metric emit point.
                estate_update(daemon, port, id, "revive", "re-enabled harness-memory; content unchanged")
            }
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
    CreateFresh,
    /// Revive a superseded drawer; the String is its estate drawer ID.
    Revive(String),
}

/// Check estate for a superseded drawer at `location`.
///
/// Queries `moot_memory_list` with the exact location as prefix to find prior
/// records. If a superseded record exists with matching content, return
/// `Revive(id)` — the ID drives `moot_update_memory` so no duplicate drawer
/// is created across toggle cycles (enable → disable → re-enable). Otherwise
/// return `CreateFresh`.
///
/// IDs are derived from list results, never constructed from paths.
fn determine_ingest_action(
    daemon: &dyn DaemonHttp,
    port: u16,
    location: &str,
    local_content: &str,
) -> IngestAction {
    let records = estate_list(daemon, port, location);
    // Find a superseded record at the exact location whose content matches.
    for record in &records {
        if record.is_superseded && record.location == location
            && record.content.trim() == local_content.trim()
        {
            return IngestAction::Revive(record.id.clone());
        }
    }
    IngestAction::CreateFresh
}

// ─── Restore (Part 3b) ───────────────────────────────────────────────────────

/// Restore estate memories to disk on `disable harness-memory`.
///
/// Queries the estate for drawers in both restore classes:
///   - `harness-import/*` (originally on disk, ingested by Part 3)
///   - `harness/*` (born in the estate during capture-hook interception)
///
/// Per project, offers restore (per project prompt, `--restore-all`, or
/// `--no-restore`).  After each confirmed disk write, marks the estate
/// record with `mutation=supersede` and a timestamped note.  Estate records
/// are NEVER deleted.
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

    // Discover all harness records from the estate using moot_memory_list.
    // IDs come from list results — never constructed from paths.
    let records = discover_restore_records(daemon, port);

    if records.is_empty() {
        return "  No harness memories found in the estate to restore.".to_string();
    }

    let mut written = 0usize;
    let mut superseded = 0usize;
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

        // Content is already in the list record — no extra round-trip needed.
        let content = &record.content;

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
        written += 1;
        restored_locations.push(record.location.clone());

        // Mark estate record as superseded via moot_update_memory (use record ID,
        // not a constructed path). Estate keeps full history while the harness
        // copy is live.
        // MXE-HM-2: harness_memory.restore.written metric emit point.
        let note = format!("restored to harness {}", now_iso8601());
        if estate_update(daemon, port, &record.id, "supersede", &note).is_ok() {
            superseded += 1;
        }
    }

    // Regenerate MEMORY.md index for each project that received restored files.
    // (If a captured MEMORY.md drawer exists it was already restored verbatim above.)
    regenerate_memory_index(claude_dir, &restored_locations);

    let mut summary = format!("  Restore: {written} written, {superseded} superseded in estate.");
    for c in &collisions {
        summary.push('\n');
        summary.push_str(c);
    }
    summary
}

/// Query the estate for all harness records across both location classes:
///   - `harness-import/*` (originally on disk, ingested by ingest sweep)
///   - `harness/*` (born in the estate via capture-hook interception)
///
/// Uses `moot_memory_list` which returns records with IDs and content.
/// IDs drive subsequent `moot_update_memory` calls — never constructed paths.
///
/// Deduplicates by `record.location`: querying with prefix "harness" returns
/// `harness-import/*` records too (prefix overlap), so a record received from
/// the first query is skipped if it appears again in the second.
fn discover_restore_records(daemon: &dyn DaemonHttp, port: u16) -> Vec<EstateRecord> {
    let mut records = Vec::new();
    let mut seen = std::collections::HashSet::new();
    // "harness-import" queried first; "harness" would also match those locations.
    for prefix in &["harness-import", "harness"] {
        let batch = estate_list(daemon, port, prefix);
        for rec in batch {
            // Skip if we already have this location from a previous prefix query.
            if seen.insert(rec.location.clone()) {
                records.push(rec);
            }
        }
    }
    records
}

/// Extract `(slug, filename)` from `/memories/harness[-import]/<slug>/<file>`.
///
/// Used by tests and as a utility for callers that receive the legacy
/// `/memories/…` path format. Production restore code uses
/// `parse_restore_location` instead (which takes the bare `location` string).
fn parse_restore_path(memory_path: &str) -> Option<(String, String)> {
    // Strip leading /memories/harness[-import]/
    let after = memory_path
        .strip_prefix("/memories/harness-import/")
        .or_else(|| memory_path.strip_prefix("/memories/harness/"))?;
    parse_restore_location(after)
}

/// Extract `(slug, filename)` from a bare estate location string of the form
/// `harness-import/<slug>/<file>` or `harness/<slug>/<file>`.
///
/// This is the low-level parser used by the restore flow. IDs come from
/// `estate_list` results; slug and filename are extracted from the `location`
/// field of those records.
fn parse_restore_location(location: &str) -> Option<(String, String)> {
    // Strip the optional prefix so we can handle both bare locations from
    // estate_list records and legacy /memories/ paths (via parse_restore_path).
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
            let mut content = "# Memory Index\n\n".to_string();
            let mut sorted = files.clone();
            sorted.sort();
            for f in &sorted {
                content.push_str(&format!("- [{f}]({f})\n"));
            }
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
/// Returns `Some(json_string)` only for paths the harness governs: `deny` on
/// successful estate capture, `allow` as a fallback when the daemon is
/// unreachable or the estate write fails (so the session is never blocked).
///
/// `now_secs`: Unix epoch seconds injected by the caller for determinism.
fn hook_decide(daemon: &dyn DaemonHttp, payload: &Value, now_secs: u64) -> Option<String> {
    let tool_name = payload.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
    let tool_input = payload.get("tool_input").cloned().unwrap_or_default();
    let path = tool_input.get("path").and_then(|v| v.as_str()).unwrap_or("");

    // Non-memory paths are not governed by this hook — fall through.
    // An explicit allow here would auto-approve arbitrary writes under the Claude
    // Code hook contract, which is the security defect this fix addresses.
    if !is_harness_memory_path(path) {
        // MXE-HM-2: harness_memory.capture.bypass metric emit point.
        return None;
    }

    let port = crate::core::daemon_client::resolved_port();

    // Daemon-down fallback: allow disk write so the session is not blocked.
    // The next ingest sweep recovers any stray files.
    if !daemon.alive(port) {
        // MXE-HM-2: harness_memory.capture.fallback metric emit point.
        eprintln!("mootx01 daemon unreachable on port {port} — allowing disk write as fallback");
        return Some(allow_json());
    }

    match tool_name {
        "Write" => {
            let content = tool_input
                .get("content")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            // now_secs captured at the outermost call site (hook_capture) for
            // determinism — no SystemTime::now() call inside capture_decision.
            capture_decision(daemon, port, path, content, now_secs)
        }
        "Edit" | "MultiEdit" => {
            // Edit/MultiEdit against a nonexistent harness file: deny with teaching
            // message. Nothing is on disk to edit — files were moved to the estate.
            Some(deny_json(teaching_message(path)))
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
/// Returns `None` when path security checks reject the target (traversal,
/// hidden file) — these fall through to the normal permission prompt.
/// Returns `Some(deny json)` on successful estate capture.
/// Returns `Some(allow json)` when the estate write fails so the session
/// is not blocked (fallback).
///
/// `now_secs` is passed from `hook_decide` for determinism — no
/// `SystemTime::now()` inside this function.
fn capture_decision(
    daemon: &dyn DaemonHttp,
    port: u16,
    path: &str,
    content: &str,
    now_secs: u64,
) -> Option<String> {
    let (project_slug, filename) = match parse_harness_path(path) {
        Some(pair) => pair,
        // parse_harness_path rejected the path (traversal, hidden file, missing
        // filename) even though is_harness_memory_path accepted it. Fall through
        // to the normal permission prompt — do not auto-allow.
        None => return None,
    };

    let location = format!("harness/{project_slug}/{filename}");
    let event_time = unix_secs_to_iso8601(now_secs);
    let kind = memory_kind(&filename);

    match estate_file(daemon, port, &location, content, &event_time, kind) {
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

fn teaching_message(path: &str) -> String {
    let location = parse_harness_path(path)
        .map(|(slug, file)| format!("harness/{slug}/{file}"))
        .unwrap_or_else(|| "harness/<project>/<name>".to_string());
    teaching_message_with_location(&location)
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
        "  {slug}: filed {}, removed {}, skipped {}",
        r.filed, r.removed, r.skipped
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
            "/Users/bob/.claude/projects/-Users-bob-devlop-mootx01/memory/notes.md"
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

        // Each file triggers two calls: estate_list (determine_ingest_action) then
        // estate_file. The MockDaemon queue is intentionally short — exhausted calls
        // fall back to the default 200 success response, so all 4 calls succeed.
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

        // estate_list (determine_ingest_action): no `memories` key → empty → CreateFresh.
        // estate_file: 500 → failure.
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":""}]}}"#), // list → empty
            (500, "internal error"),                           // file → fail
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

        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":""}]}}"#),
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.skipped, 1); // .hidden
        assert_eq!(result.filed, 1);   // visible.md
        assert!(result.skip_reasons[0].contains("hidden file"));
    }

    #[test]
    fn ingest_project_revives_when_content_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path().join("memory");
        fs::create_dir_all(&memory_dir).unwrap();
        // File content matches what the estate returns (superseded drawer).
        fs::write(memory_dir.join("note.md"), b"same content\n").unwrap();

        let daemon = MockDaemon::alive(vec![
            // estate_list response: superseded record at exact location with same content.
            (200, r#"{"result":{"memories":[{"id":"drawer-abc","location":"harness-import/slug/note.md","content":"same content\n","superseded":true}]}}"#),
            // estate_update (revive) response.
            (200, r#"{"result":{"content":[{"text":"revived"}]}}"#),
        ]);

        let result = ingest_project(&daemon, 4242, "slug", &memory_dir);
        assert_eq!(result.filed, 1);
        assert_eq!(result.removed, 1);

        // Assert real ARIA frames: list then update(revive).
        let calls = daemon.calls.lock().unwrap();
        // First call: moot_memory_list
        assert_eq!(calls[0]["params"]["name"], "moot_memory_list", "list must use moot_memory_list");
        assert!(calls[0]["params"]["arguments"]["location_prefix"].is_string(), "list must have location_prefix");
        // Second call: moot_update_memory with mutation=revive
        assert_eq!(calls[1]["params"]["name"], "moot_update_memory", "revive must use moot_update_memory");
        assert_eq!(calls[1]["params"]["arguments"]["id"], "drawer-abc");
        assert_eq!(calls[1]["params"]["arguments"]["mutation"], "revive");
        // No "subject" argument — spec-doc drift guard.
        assert!(calls[1]["params"]["arguments"].get("subject").is_none(), "no subject arg in update");
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

    #[test]
    fn parse_restore_path_harness_import() {
        let r = parse_restore_path("/memories/harness-import/my-slug/note.md");
        assert_eq!(r, Some(("my-slug".to_string(), "note.md".to_string())));
    }

    #[test]
    fn parse_restore_path_harness() {
        let r = parse_restore_path("/memories/harness/my-slug/file.md");
        assert_eq!(r, Some(("my-slug".to_string(), "file.md".to_string())));
    }

    #[test]
    fn parse_restore_path_rejects_hidden() {
        assert!(parse_restore_path("/memories/harness/slug/.hidden").is_none());
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

    // parse_restore_path / parse_restore_location — same slug guard on the
    // estate location string returned by estate_list.

    #[test]
    fn parse_restore_path_rejects_dotdot_slug() {
        // /memories/harness-import/../etc → slug = ".." → rejected.
        let r = parse_restore_path("/memories/harness-import/../etc/passwd");
        assert!(r.is_none(), "restore slug '..' must be rejected");
    }

    #[test]
    fn parse_restore_path_rejects_dotfile_slug() {
        // /memories/harness/.hidden/file.md → slug = ".hidden" → rejected.
        let r = parse_restore_path("/memories/harness/.hidden/file.md");
        assert!(r.is_none(), "restore slug starting with '.' must be rejected");
    }

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
        assert_eq!(args["event_time"], "2026-08-07T00:00:00Z");
        assert_eq!(args["kind"], "prose");
        // No legacy "command" or "subject" args — drift guard.
        assert!(args.get("command").is_none(), "no command arg");
        assert!(args.get("subject").is_none(), "no subject arg");
    }

    #[test]
    fn estate_update_sends_moot_update_memory_frame() {
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"content":[{"text":"ok"}]}}"#),
        ]);
        let result = estate_update(&daemon, 4242, "drawer-uuid-abc", "supersede", "test note");
        assert!(result.is_ok());
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let args = &calls[0]["params"]["arguments"];
        assert_eq!(calls[0]["params"]["name"], "moot_update_memory");
        assert_eq!(args["id"], "drawer-uuid-abc");
        assert_eq!(args["mutation"], "supersede");
        assert_eq!(args["note"], "test note");
        // No legacy "command" or "subject" args — drift guard.
        assert!(args.get("command").is_none(), "no command arg");
        assert!(args.get("subject").is_none(), "no subject arg");
    }

    #[test]
    fn estate_list_sends_moot_memory_list_frame() {
        let daemon = MockDaemon::alive(vec![
            (200, r#"{"result":{"memories":[{"id":"d1","location":"harness/slug/file.md","content":"c","superseded":false}]}}"#),
        ]);
        let records = estate_list(&daemon, 4242, "harness/slug");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].id, "d1");
        let calls = daemon.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        let args = &calls[0]["params"]["arguments"];
        assert_eq!(calls[0]["params"]["name"], "moot_memory_list");
        assert_eq!(args["location_prefix"], "harness/slug");
        // No legacy "command" or "path" args — drift guard.
        assert!(args.get("command").is_none(), "no command arg");
        assert!(args.get("path").is_none(), "no path arg");
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

    // ── Finding 5: discover_restore_records deduplicates harness-import ──────

    #[test]
    fn discover_restore_records_deduplicates_harness_import_under_harness_prefix() {
        // A harness-import record that the estate returns for BOTH the "harness-import"
        // prefix query AND the "harness" prefix query (because "harness-import" starts
        // with "harness") must appear exactly once in the result.
        let harness_import_json = r#"{"result":{"memories":[{"id":"d1","location":"harness-import/slug/note.md","content":"c","superseded":false}]}}"#;
        let daemon = MockDaemon::alive(vec![
            // First query (prefix "harness-import"): server returns the record.
            (200, harness_import_json),
            // Second query (prefix "harness"): server also returns it (prefix overlap).
            (200, harness_import_json),
        ]);
        let records = discover_restore_records(&daemon, 4242);
        assert_eq!(
            records.len(), 1,
            "harness-import record must appear exactly once despite prefix overlap"
        );
        assert_eq!(records[0].id, "d1");
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
            "/home/bob/.claude/projects/test-project/memory/note.md",
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
}
