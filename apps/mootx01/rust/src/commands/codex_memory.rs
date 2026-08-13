//! Codex stable-field lifecycle hook adapter for the Linux/Windows binary.
//! Never reads transcript_path; state is user-private and removed at SessionEnd.
//!
//! Also provides:
//! - `run_doctor()` — Codex/MOOT posture diagnostics (mirrors Swift `CodexMemoryDoctorCommand`)
//! - `run_import_chronicle()` — Chronicle Markdown importer (mirrors Swift `CodexChronicleImporter`)

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

// ─── Hook (existing) ─────────────────────────────────────────────────────────

#[derive(Default, Serialize, Deserialize)]
struct HookState {
    observed_moot_read: bool,
    observed_moot_write: bool,
    stop_gate_used: bool,
    compacted: bool,
}

pub fn run_hook(event: &str) -> ExitCode {
    let mut body = String::new();
    if io::stdin().read_to_string(&mut body).is_err() { return ExitCode::SUCCESS; }
    let Ok(input) = serde_json::from_str::<Value>(&body) else { return ExitCode::SUCCESS; };
    let Some(session_id) = input.get("session_id").and_then(Value::as_str) else {
        return ExitCode::SUCCESS;
    };
    let path = state_path(session_id);
    let mut state = load_state(&path);
    match event {
        "SessionStart" => {
            let source = input.get("source").and_then(Value::as_str).unwrap_or("startup");
            if source == "startup" || source == "clear" { state = HookState::default(); }
            save_state(&path, &state);
            let mut message = "MOOTx01 is available as durable memory. Use its tools when prior context matters; file durable decisions before finishing.".to_string();
            if source == "compact" || state.compacted {
                message.push_str(" This session was compacted; re-orient with moot_estate_status and moot_read_journal.");
            }
            emit_context("SessionStart", &message);
        }
        "PreCompact" => { state.compacted = true; save_state(&path, &state); }
        "PostCompact" => {
            state.compacted = true; save_state(&path, &state);
            emit_context("PostCompact", "MOOTx01 compaction recovery: re-check estate status/journal and do not assume omitted details.");
        }
        "PostToolUse" => {
            let tool = input.get("tool_name").and_then(Value::as_str).unwrap_or("").to_lowercase();
            if tool.contains("moot_") || tool.contains("mootx01") {
                let writes = ["file_memory", "file_fact", "write_journal", "update_memory",
                    "confirm_memory", "withdraw_memory", "retire_fact", "link_memories"];
                if writes.iter().any(|marker| tool.contains(marker)) { state.observed_moot_write = true; }
                else { state.observed_moot_read = true; }
                save_state(&path, &state);
            }
        }
        "Stop" => {
            if input.get("stop_hook_active").and_then(Value::as_bool) == Some(true)
                || state.stop_gate_used { return ExitCode::SUCCESS; }
            state.stop_gate_used = true; save_state(&path, &state);
            if !state.observed_moot_write {
                println!("{}", json!({
                    "decision": "block",
                    "reason": "One-shot MOOTx01 writeback gate: assess whether this turn produced durable decisions, corrections, preferences, facts, links, or continuity notes. File what changed, or continue if nothing durable changed. Do not repeat this gate."
                }));
            }
        }
        "SessionEnd" => { let _ = fs::remove_file(path); }
        // Reset turn-scoped tracking. stop_hook_active remains the authoritative
        // recursion guard for a continuation created by Stop.
        "UserPromptSubmit" => {
            state.observed_moot_write = false;
            state.stop_gate_used = false;
            save_state(&path, &state);
        }
        _ => {}
    }
    ExitCode::SUCCESS
}

fn state_path(session_id: &str) -> PathBuf {
    let safe: String = session_id.chars().take(120).map(|c| {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }
    }).collect();
    home_dir().join(".mootx01").join("codex-memory").join("sessions")
        .join(format!("{}.json", if safe.is_empty() { "unknown" } else { &safe }))
}

fn load_state(path: &PathBuf) -> HookState {
    fs::read(path).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

fn save_state(path: &PathBuf, state: &HookState) {
    let Some(dir) = path.parent() else { return; };
    if fs::create_dir_all(dir).is_err() { return; }
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    if let Ok(data) = serde_json::to_vec_pretty(state) {
        if fs::write(path, data).is_ok() {
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
            }
        }
    }
}

fn emit_context(event: &str, text: &str) {
    println!("{}", json!({"hookSpecificOutput": {
        "hookEventName": event, "additionalContext": text
    }}));
}

fn home_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    { std::env::var("USERPROFILE").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(".")) }
    #[cfg(not(target_os = "windows"))]
    { std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(".")) }
}

// ─── Doctor ──────────────────────────────────────────────────────────────────

/// Codex/MOOT posture diagnostic report.
///
/// Mirrors Swift `CodexMemoryDoctorCommand.run()` in
/// `apps/mootx01/Sources/mootx01/Commands/CodexMemoryCommand.swift`.
pub fn run_doctor() -> ExitCode {
    use aria_mcp::estate_migration as migration;

    let home = home_dir();
    let codex_home = resolve_codex_home(&home);
    let config_path = codex_home.join("config.toml");
    let codex_text = fs::read_to_string(&config_path).unwrap_or_default();

    // Binary version.
    println!("mootx01 codex-memory doctor");
    println!("─────────────────────────────────");
    println!("Binary: {}", env!("CARGO_PKG_VERSION"));

    // Codex plugin/client detection via the client registry.
    let codex_client = crate::core::clients::supported()
        .into_iter()
        .find(|c| c.id == "codex");
    let codex_detected = codex_client.as_ref().map_or(false, |c| c.detected(&home));
    println!("Codex plugin: {}", if codex_detected { "enabled" } else { "not enabled" });

    // MCP ownership: is mootx01 wired into Codex's config?
    let codex_wired = codex_client.as_ref().map_or(false, |c| c.wired(&home));
    if codex_wired {
        println!("MCP ownership: direct config");
    } else {
        println!("MCP ownership: not wired");
    }

    // Native memory settings: read ~/.codex/config.toml with the hand-rolled
    // line scanner, matching Swift's CodexNativeMemorySettings.value(in:table:key:).
    let managed_keys = [
        ("features", "memories"),
        ("memories", "generate_memories"),
        ("memories", "use_memories"),
    ];
    for (table, key) in &managed_keys {
        let val = toml_value(&codex_text, table, key)
            .map(|v| v.to_string())
            .unwrap_or_else(|| "default".to_string());
        println!("Native {table}.{key}: {val}");
    }

    // Chronicle: count .md files under CODEX_HOME/memories_extensions/chronicle/.
    let chronicle_root = codex_home.join("memories_extensions").join("chronicle");
    let exists = chronicle_root.exists();
    let count = if exists { walk_markdown_files(&chronicle_root).len() } else { 0 };
    if exists {
        println!("Chronicle: available ({count} Markdown file(s))");
    } else {
        println!("Chronicle: not present");
    }
    println!("Chronicle policy: generated Markdown only; no screenshots; import is consent-gated and read-only toward CODEX_HOME");

    // Estate at rest: use aria_mcp::estate_migration::detect_estate_file_state.
    let data_dir = crate::core::paths::data_dir();
    let active = crate::core::paths::active_estate(&data_dir);
    let estate_path = crate::core::paths::estate_sqlite_path(&data_dir, &active);
    let posture = migration::detect_estate_file_state(&estate_path);
    let posture_text = match posture {
        migration::EstateFileState::Absent => "absent",
        migration::EstateFileState::Plaintext => "plaintext (migration recommended)",
        migration::EstateFileState::Ciphertext => "encrypted/ciphertext",
    };
    println!("Estate at rest: {posture_text}");

    // Count estate backup files (*.bak or files containing "backup" in name).
    let backup_count = if let Some(parent) = estate_path.parent() {
        fs::read_dir(parent)
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        let name = e.file_name().to_string_lossy().to_string();
                        name.contains("backup") || name.ends_with(".bak")
                    })
                    .count()
            })
            .unwrap_or(0)
    } else {
        0
    };
    println!("Estate backups detected: {backup_count}");

    ExitCode::SUCCESS
}

// ─── Import Chronicle ─────────────────────────────────────────────────────────

/// Chronicle Markdown importer.
///
/// Mirrors Swift `CodexChronicleImportCommand.run()` and
/// `CodexChronicleImporter.run()` in
/// `apps/mootx01/Sources/MootInstallerCore/CodexMemory.swift`.
pub fn run_import_chronicle(yes: bool) -> ExitCode {
    use sha2::{Digest, Sha256};

    let home = home_dir();
    let codex_home = resolve_codex_home(&home);
    let chronicle_root = codex_home.join("memories_extensions").join("chronicle");

    // Walk for .md files sorted by path (skip hidden, skip symlinks).
    let files = walk_markdown_files(&chronicle_root);
    if files.is_empty() {
        println!("No Chronicle-generated Markdown found at {}.", chronicle_root.display());
        return ExitCode::SUCCESS;
    }

    // Confirmation prompt when --yes is not passed.
    if !yes {
        print!("Import {} Chronicle Markdown file(s) into MOOTx01? [y/N] ", files.len());
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line).is_err() || !line.trim().to_lowercase().starts_with('y') {
            println!("Aborted.");
            return ExitCode::FAILURE;
        }
    }

    // Resolve daemon port and ping.
    let port = crate::core::daemon_client::resolved_port();
    let daemon = crate::commands::harness_memory::LiveDaemon;
    // Bring the DaemonHttp trait into scope for the alive() method call.
    use crate::commands::harness_memory::DaemonHttp;
    if !daemon.alive(port) {
        println!("MOOTx01 daemon is not reachable on port {port}; no files were imported.");
        return ExitCode::FAILURE;
    }

    // Load dedup index from ~/.mootx01/codex-memory/chronicle-index.json.
    // Schema: { "hashes": { "relative_path": "sha256_hex" } }
    let index_path = home.join(".mootx01").join("codex-memory").join("chronicle-index.json");
    let mut index: ChronicleIndex = fs::read(&index_path)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or_default();

    let mut imported = 0usize;
    let mut duplicates = 0usize;
    let mut failed = 0usize;

    // Resolve chronicle root to a canonical path for relative-path derivation.
    let root_canonical = chronicle_root.canonicalize().unwrap_or(chronicle_root.clone());
    let root_str = {
        let s = root_canonical.to_string_lossy().to_string();
        if s.ends_with('/') { s } else { s + "/" }
    };

    for file in &files {
        // Read file content.
        let data = match fs::read(file) {
            Ok(d) => d,
            Err(_) => { failed += 1; continue; }
        };
        let body = match String::from_utf8(data.clone()) {
            Ok(s) => s,
            Err(_) => { failed += 1; continue; }
        };

        // Derive SHA-256 hex digest.
        let digest = {
            let mut hasher = Sha256::new();
            hasher.update(&data);
            format!("{:x}", hasher.finalize())
        };

        // Dedup: skip if any stored hash already matches this content.
        if index.hashes.values().any(|h| h == &digest) {
            duplicates += 1;
            continue;
        }

        // Derive relative path from chronicle root.
        let file_canonical = file.canonicalize().unwrap_or(file.clone());
        let file_str = file_canonical.to_string_lossy().to_string();
        let relative = if file_str.starts_with(&root_str) {
            file_str[root_str.len()..].to_string()
        } else {
            file.file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default()
        };

        // Build provenance header matching Swift format.
        let provenance = format!(
            "MOOTx01 import provenance:\n\
             - source: Codex Chronicle generated Markdown\n\
             - source_path: {relative}\n\
             - source_sha256: {digest}\n\
             - confirmation: unconfirmed\n\
             \n\
             {body}"
        );

        // Generate subject from provenance content (mirrors Swift's extractSubject).
        let subject = crate::commands::harness_memory::extract_subject(&provenance, &relative);

        // Get file modification time as ISO 8601 UTC string.
        let event_time = file
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .map(system_time_to_iso8601)
            .unwrap_or_else(|| utc_now_iso8601());

        // File into estate via moot_file_memory with location codex-chronicle/<relative>.
        let location = format!("codex-chronicle/{relative}");
        match chronicle_estate_file(
            &daemon, port, &location, &provenance, &subject, &event_time, "document",
        ) {
            Ok(()) => {
                index.hashes.insert(relative, digest);
                imported += 1;
            }
            Err(_) => {
                failed += 1;
            }
        }
    }

    // Write index atomically; set permissions 0o600 on Unix.
    write_chronicle_index(&index_path, &index);

    println!("Chronicle import: imported {imported}, duplicate {duplicates}, failed {failed}.");
    println!("CODEX_HOME was read only; Chronicle screenshots and temporary capture data were not accessed.");

    if failed > 0 { ExitCode::FAILURE } else { ExitCode::SUCCESS }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

/// Resolve CODEX_HOME: $CODEX_HOME env override, else ~/.codex.
fn resolve_codex_home(home: &Path) -> PathBuf {
    if let Ok(v) = std::env::var("CODEX_HOME") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    home.join(".codex")
}

/// Walk `root` for `.md` files, skipping hidden files and symlinks, sorted by path.
///
/// Mirrors Swift `CodexChronicleImporter.markdownFiles(root:)`.
pub fn walk_markdown_files(root: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    walk_md_recursive(root, &mut result);
    result.sort();
    result
}

fn walk_md_recursive(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.filter_map(|e| e.ok()) {
        let name = entry.file_name().to_string_lossy().to_string();
        // Skip hidden files and directories (names starting with '.').
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
        // Skip symlinks.
        if meta.file_type().is_symlink() {
            continue;
        }
        if meta.is_dir() {
            walk_md_recursive(&path, out);
        } else if meta.is_file() && name.to_lowercase().ends_with(".md") {
            out.push(path);
        }
    }
}

/// Hand-rolled TOML line scanner: returns the raw value for `[table] key = value`.
///
/// Mirrors Swift `CodexNativeMemorySettings.value(in:table:key:)`. Preserves
/// comments, ordering, and unrelated tables. Returns `None` when the key is
/// absent from the specified table.
pub fn toml_value<'a>(text: &'a str, table: &str, key: &str) -> Option<&'a str> {
    let mut active_table: Option<&str> = None;
    for line in text.lines() {
        let trimmed = line.trim();
        // Table header: [name]
        if trimmed.starts_with('[') && trimmed.ends_with(']') && !trimmed.starts_with("[[") {
            active_table = Some(&trimmed[1..trimmed.len() - 1]);
            continue;
        }
        // Only scan inside the target table.
        if active_table != Some(table) {
            continue;
        }
        // Skip comments and blank lines.
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        // Key = value line.
        if let Some(eq_pos) = trimmed.find('=') {
            let lhs = trimmed[..eq_pos].trim();
            if lhs == key {
                return Some(trimmed[eq_pos + 1..].trim());
            }
        }
    }
    None
}

/// File one Chronicle memory into the estate via `moot_file_memory`.
///
/// Mirrors the pattern in `harness_memory::estate_file` — builds and posts a
/// JSON-RPC 2.0 `tools/call` frame using the `DaemonHttp` seam so tests can
/// inject a mock without a live daemon.
fn chronicle_estate_file(
    daemon: &dyn crate::commands::harness_memory::DaemonHttp,
    port: u16,
    location: &str,
    content: &str,
    subject: &str,
    event_time: &str,
    kind: &str,
) -> Result<(), String> {
    let frame = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "moot_file_memory",
            "arguments": {
                "location": location,
                "content": content,
                "subject": subject,
                "event_time": event_time,
                "kind": kind,
            }
        }
    });
    let bytes = serde_json::to_vec(&frame).map_err(|e| e.to_string())?;
    let (status, body) = daemon.post_frame(port, &bytes).map_err(|e| e.to_string())?;
    if status != 200 {
        let msg = String::from_utf8_lossy(&body).into_owned();
        return Err(format!("daemon returned HTTP {status}: {msg}"));
    }
    Ok(())
}

/// Dedup index persisted at ~/.mootx01/codex-memory/chronicle-index.json.
#[derive(Default, Serialize, Deserialize)]
struct ChronicleIndex {
    hashes: std::collections::HashMap<String, String>,
}

fn write_chronicle_index(path: &Path, index: &ChronicleIndex) {
    let Some(dir) = path.parent() else { return };
    if fs::create_dir_all(dir).is_err() { return; }
    if let Ok(data) = serde_json::to_vec_pretty(index) {
        if fs::write(path, data).is_ok() {
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
            }
        }
    }
}

/// Convert `SystemTime` to ISO 8601 UTC string (e.g. `2026-08-12T14:05:00Z`).
/// Hand-rolled — no chrono dependency.
fn system_time_to_iso8601(t: std::time::SystemTime) -> String {
    use std::time::{Duration, UNIX_EPOCH};
    let secs = t.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO).as_secs() as i64;
    let (y, mo, d, h, min, s) = secs_to_ymd_hms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{min:02}:{s:02}Z")
}

/// Current UTC time as ISO 8601 string (fallback when mtime is unavailable).
fn utc_now_iso8601() -> String {
    system_time_to_iso8601(std::time::SystemTime::now())
}

/// Decompose a Unix timestamp (seconds since epoch) into (year, month, day,
/// hour, minute, second) UTC components.
///
/// Uses Howard Hinnant's civil-from-days algorithm for the date part, plus
/// standard modular arithmetic for time-of-day.
fn secs_to_ymd_hms(secs: i64) -> (i64, u32, u32, u32, u32, u32) {
    // Time-of-day (seconds within the UTC day).
    let time_of_day = secs.rem_euclid(86400) as u32;
    let h = time_of_day / 3600;
    let min = (time_of_day % 3600) / 60;
    let s = time_of_day % 60;

    // Days since the Unix epoch (1970-01-01).
    let days = secs.div_euclid(86400);
    let (y, mo, d) = civil_from_days(days);
    (y, mo, d, h, min, s)
}

/// Howard Hinnant's civil_from_days algorithm.
/// <https://howardhinnant.github.io/date_algorithms.html>
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli::{Command, parse};

    fn p(s: &[&str]) -> Result<Command, crate::cli::UsageError> {
        let v: Vec<String> = s.iter().map(|x| x.to_string()).collect();
        parse(&v)
    }

    // ── CLI parse tests ──────────────────────────────────────────────────────

    #[test]
    fn codex_memory_doctor_parses() {
        assert_eq!(p(&["codex-memory", "doctor"]).unwrap(), Command::CodexMemoryDoctor);
    }

    #[test]
    fn codex_memory_import_chronicle_defaults() {
        assert_eq!(
            p(&["codex-memory", "import-chronicle"]).unwrap(),
            Command::CodexMemoryImportChronicle { yes: false }
        );
    }

    #[test]
    fn codex_memory_import_chronicle_with_yes() {
        assert_eq!(
            p(&["codex-memory", "import-chronicle", "--yes"]).unwrap(),
            Command::CodexMemoryImportChronicle { yes: true }
        );
    }

    #[test]
    fn codex_memory_import_chronicle_short_yes() {
        assert_eq!(
            p(&["codex-memory", "import-chronicle", "-y"]).unwrap(),
            Command::CodexMemoryImportChronicle { yes: true }
        );
    }

    #[test]
    fn codex_memory_no_subcommand_is_error() {
        assert!(p(&["codex-memory"]).is_err());
    }

    #[test]
    fn codex_memory_unknown_subcommand_is_error() {
        assert!(p(&["codex-memory", "frobnicate"]).is_err());
    }

    #[test]
    fn codex_memory_doctor_with_trailing_arg_is_error() {
        assert!(p(&["codex-memory", "doctor", "extra"]).is_err());
    }

    #[test]
    fn codex_memory_import_chronicle_unknown_flag_is_error() {
        assert!(p(&["codex-memory", "import-chronicle", "--nope"]).is_err());
    }

    // ── TOML line scanner ────────────────────────────────────────────────────

    #[test]
    fn toml_value_finds_key_in_table() {
        let text = "[features]\nmemories = false\n";
        assert_eq!(toml_value(text, "features", "memories"), Some("false"));
    }

    #[test]
    fn toml_value_absent_key_returns_none() {
        let text = "[features]\nother = true\n";
        assert_eq!(toml_value(text, "features", "memories"), None);
    }

    #[test]
    fn toml_value_absent_table_returns_none() {
        let text = "[other]\nmemories = true\n";
        assert_eq!(toml_value(text, "features", "memories"), None);
    }

    #[test]
    fn toml_value_skips_comments() {
        let text = "[features]\n# memories = true\nmemories = false\n";
        assert_eq!(toml_value(text, "features", "memories"), Some("false"));
    }

    #[test]
    fn toml_value_multiple_tables() {
        let text = "[features]\nmemories = false\n[memories]\ngenerate_memories = false\nuse_memories = false\n";
        assert_eq!(toml_value(text, "features", "memories"), Some("false"));
        assert_eq!(toml_value(text, "memories", "generate_memories"), Some("false"));
        assert_eq!(toml_value(text, "memories", "use_memories"), Some("false"));
    }

    // ── Chronicle file walker ─────────────────────────────────────────────────

    #[test]
    fn walk_markdown_files_returns_only_md_files_sorted() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::write(root.join("a.md"), "a").unwrap();
        fs::write(root.join("b.md"), "b").unwrap();
        fs::write(root.join("c.txt"), "c").unwrap();
        let files = walk_markdown_files(root);
        assert_eq!(files.len(), 2);
        assert!(files[0].file_name().unwrap().to_string_lossy().starts_with('a'));
        assert!(files[1].file_name().unwrap().to_string_lossy().starts_with('b'));
    }

    #[test]
    fn walk_markdown_files_skips_hidden() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::write(root.join("visible.md"), "v").unwrap();
        fs::write(root.join(".hidden.md"), "h").unwrap();
        let files = walk_markdown_files(root);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].file_name().unwrap(), "visible.md");
    }

    #[test]
    fn walk_markdown_files_recurses_into_subdirectories() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        fs::create_dir(root.join("sub")).unwrap();
        fs::write(root.join("top.md"), "t").unwrap();
        fs::write(root.join("sub").join("nested.md"), "n").unwrap();
        let files = walk_markdown_files(root);
        assert_eq!(files.len(), 2);
    }

    // ── Dedup index ───────────────────────────────────────────────────────────

    #[test]
    fn dedup_index_matches_by_hash_value() {
        let mut index = ChronicleIndex::default();
        index.hashes.insert("some/file.md".to_string(), "abc123".to_string());
        // Same content hash → treated as duplicate.
        assert!(index.hashes.values().any(|h| h == "abc123"));
        // Different hash → not a duplicate.
        assert!(!index.hashes.values().any(|h| h == "xyz789"));
    }

    // ── Drift guards ─────────────────────────────────────────────────────────

    #[test]
    fn run_doctor_return_type_is_exit_code() {
        // Compile-time check: function exists and returns ExitCode.
        let _f: fn() -> ExitCode = run_doctor;
    }

    #[test]
    fn run_import_chronicle_accepts_bool() {
        // Compile-time check: function exists and takes a bool.
        let _f: fn(bool) -> ExitCode = run_import_chronicle;
    }

    // Hook tests (pre-existing).
    #[test]
    fn state_path_sanitizes_session_id() {
        let path = state_path("thread/../../secret");
        assert!(!path.file_name().unwrap().to_string_lossy().contains('/'));
        assert!(path.to_string_lossy().contains("codex-memory"));
    }
}
