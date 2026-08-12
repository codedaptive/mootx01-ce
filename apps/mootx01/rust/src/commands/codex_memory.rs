//! Codex stable-field lifecycle hook adapter for the Linux/Windows binary.
//! Never reads transcript_path; state is user-private and removed at SessionEnd.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::ExitCode;

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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn state_path_sanitizes_session_id() {
        let path = state_path("thread/../../secret");
        assert!(!path.file_name().unwrap().to_string_lossy().contains('/'));
        assert!(path.to_string_lossy().contains("codex-memory"));
    }
}
