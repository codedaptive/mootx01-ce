//! commands/enable.rs — `mootx01 enable <feature>` / `mootx01 disable <feature>`
//! and `mootx01 hook-capture` dispatch.
//!
//! On Linux/Windows the `memory-tool` feature is managed via
//! `~/.mootx01/features.env` (parallel to Swift's `#else` branch in
//! EnableCommand.swift which writes the same file).  The `harness-memory`
//! feature delegates to `harness_memory`, which modifies
//! `~/.claude/settings.json`, installs the capture hook, and merges the
//! governance sentinel into `~/.claude/CLAUDE.md`.

use std::fs;
use std::process::ExitCode;

use super::harness_memory;

// ─── enable ──────────────────────────────────────────────────────────────────

/// Dispatch `mootx01 enable <feature>`.
pub fn run_enable(feature: &str, yes: bool, ingest_all: bool) -> ExitCode {
    match feature {
        "harness-memory" => {
            match harness_memory::enable(yes, ingest_all, &harness_memory::LiveDaemon) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("Error: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        "memory-tool" => {
            // Linux/Windows: set MOOTX01_MEMORY_TOOL=1 in features.env.
            // On macOS this is handled by Swift via the launchd plist;
            // the Rust port ships on Linux/Windows where features.env is
            // the correct mechanism.
            features_env_set("MOOTX01_MEMORY_TOOL", "1", "memory tool")
        }
        other => {
            eprintln!("Unknown feature: {other}");
            eprintln!("Available features: memory-tool, harness-memory");
            ExitCode::from(1)
        }
    }
}

// ─── disable ─────────────────────────────────────────────────────────────────

/// Dispatch `mootx01 disable <feature>`.
pub fn run_disable(
    feature: &str,
    yes: bool,
    restore_all: bool,
    no_restore: bool,
) -> ExitCode {
    match feature {
        "harness-memory" => {
            match harness_memory::disable(yes, restore_all, no_restore, &harness_memory::LiveDaemon) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => {
                    eprintln!("Error: {e}");
                    ExitCode::FAILURE
                }
            }
        }
        "memory-tool" => {
            features_env_set("MOOTX01_MEMORY_TOOL", "0", "memory tool")
        }
        other => {
            eprintln!("Unknown feature: {other}");
            eprintln!("Available features: memory-tool, harness-memory");
            ExitCode::from(1)
        }
    }
}

// ─── hook-capture ─────────────────────────────────────────────────────────────

/// Dispatch `mootx01 hook-capture`.
///
/// Reads the Claude Code PreToolUse stdin JSON, intercepts writes to the
/// project-memory path, posts the content to the estate, then outputs the
/// allow/deny JSON to stdout.  Called by the capture hook script installed
/// at `~/.mootx01/hooks/capture-harness-memory.sh`.
///
/// Uses `HookLiveDaemon` (2s connect + 2s read) rather than `LiveDaemon`
/// (3600s read) — the hook MUST NOT freeze Claude Code when the daemon is
/// slow or unreachable. On any timeout the allow-through fallback fires.
pub fn run_hook_capture() -> ExitCode {
    harness_memory::hook_capture(&harness_memory::HookLiveDaemon);
    ExitCode::SUCCESS
}

// ─── features.env helper (memory-tool on Linux/Windows) ─────────────────────

/// Toggle an environment variable in `~/.mootx01/features.env`.
///
/// `value = "1"` → set the variable; `value = "0"` → remove the variable.
/// The file is key=value lines, one per variable.  Missing file → created.
/// Other variables in the file are left intact.
///
/// This mirrors Swift `EnableCommand`'s Linux/Windows `#else` branch exactly.
fn features_env_set(env_var: &str, value: &str, label: &str) -> ExitCode {
    let enabled = value != "0";
    let verb = if enabled { "Enabling" } else { "Disabling" };
    println!("{verb} {label}...");

    let config_dir = home_dir().join(".mootx01");
    let config_path = config_dir.join("features.env");

    // Read existing lines, filter out the variable being toggled.
    let mut lines: Vec<String> = Vec::new();
    if config_path.exists() {
        match fs::read_to_string(&config_path) {
            Ok(content) => {
                lines = content
                    .lines()
                    .filter(|l| !l.starts_with(&format!("{env_var}=")))
                    .map(str::to_string)
                    .collect();
            }
            Err(e) => {
                eprintln!("  ✗ could not read {}: {e}", config_path.display());
                return ExitCode::FAILURE;
            }
        }
    }

    // Append the new value when enabling.
    if enabled {
        lines.push(format!("{env_var}={value}"));
    }

    // Write back.
    if let Err(e) = fs::create_dir_all(&config_dir) {
        eprintln!("  ✗ create config dir: {e}");
        return ExitCode::FAILURE;
    }
    let content = lines.join("\n") + "\n";
    if let Err(e) = fs::write(&config_path, content.as_bytes()) {
        eprintln!("  ✗ write {}: {e}", config_path.display());
        return ExitCode::FAILURE;
    }

    let status = if enabled { "enabled" } else { "disabled" };
    println!("  ✓ {label} {status}");
    println!("  Restart the daemon for the change to take effect.");
    ExitCode::SUCCESS
}

fn home_dir() -> std::path::PathBuf {
    #[cfg(target_os = "windows")]
    { std::env::var("USERPROFILE").map(std::path::PathBuf::from).unwrap_or_else(|_| std::path::PathBuf::from(".")) }
    #[cfg(not(target_os = "windows"))]
    { std::env::var("HOME").map(std::path::PathBuf::from).unwrap_or_else(|_| std::path::PathBuf::from(".")) }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn features_env_enable_disable_round_trip() {
        // Build a temporary features.env path.
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join(".mootx01");
        let config_path = config_dir.join("features.env");
        fs::create_dir_all(&config_dir).unwrap();

        // Enable: write MOOTX01_MEMORY_TOOL=1.
        write_features_env(&config_path, "MOOTX01_MEMORY_TOOL", "1");
        let content = fs::read_to_string(&config_path).unwrap();
        assert!(content.contains("MOOTX01_MEMORY_TOOL=1"));

        // Disable: remove the variable.
        write_features_env(&config_path, "MOOTX01_MEMORY_TOOL", "0");
        let content = fs::read_to_string(&config_path).unwrap();
        assert!(!content.contains("MOOTX01_MEMORY_TOOL="));
    }

    #[test]
    fn features_env_preserves_other_vars() {
        let dir = tempfile::tempdir().unwrap();
        let config_dir = dir.path().join(".mootx01");
        let config_path = config_dir.join("features.env");
        fs::create_dir_all(&config_dir).unwrap();

        // Pre-populate with another variable.
        fs::write(&config_path, b"OTHER_VAR=hello\n").unwrap();

        write_features_env(&config_path, "MOOTX01_MEMORY_TOOL", "1");
        let content = fs::read_to_string(&config_path).unwrap();
        assert!(content.contains("OTHER_VAR=hello"));
        assert!(content.contains("MOOTX01_MEMORY_TOOL=1"));

        write_features_env(&config_path, "MOOTX01_MEMORY_TOOL", "0");
        let content = fs::read_to_string(&config_path).unwrap();
        assert!(content.contains("OTHER_VAR=hello"));
        assert!(!content.contains("MOOTX01_MEMORY_TOOL="));
    }

    /// Extracted pure logic from `features_env_set` for testability
    /// (the real function reads HOME, which we can't control in tests).
    fn write_features_env(config_path: &PathBuf, env_var: &str, value: &str) {
        let enabled = value != "0";
        let mut lines: Vec<String> = Vec::new();
        if config_path.exists() {
            if let Ok(content) = fs::read_to_string(config_path) {
                lines = content
                    .lines()
                    .filter(|l| !l.starts_with(&format!("{env_var}=")))
                    .map(str::to_string)
                    .collect();
            }
        }
        if enabled {
            lines.push(format!("{env_var}={value}"));
        }
        let content = lines.join("\n") + "\n";
        fs::write(config_path, content.as_bytes()).unwrap();
    }
}
