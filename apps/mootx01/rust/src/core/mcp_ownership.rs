//! core/mcp_ownership.rs — ADR-024 §3/§4: MCP connection ownership and
//! install-moment dedupe. Rust twin of Swift's MCPEntryOwnership.swift —
//! keep the two in sync by hand; there is no shared source between the
//! ports for this classification.
//!
//! Two install moments can wire a client's MCP connection: the CLI installer
//! (this binary) and the Claude Code plugin (`mootx01@mootx01`, a
//! declarative manifest with no install-time script). When both are
//! present, the plugin is the preferred connection owner (ADR-024 §1) and
//! the installer must detect it, skip writing a competing direct entry, and
//! clean up any direct entry a PRIOR install wrote — but only when that
//! entry is confirmed `OursDefault` (§4). An entry carrying a data-dir/
//! estate override (a development rig) is `Foreign` and never auto-removed;
//! callers report it by name and path instead.

use std::path::Path;

use serde_json::Value;

/// Ownership classification for an existing direct `mcpServers.<name>` (or
/// equivalent per-format) MCP entry, per ADR-024 §4.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpEntryOwnership {
    /// Our server name, and no data-dir/estate env override. Mechanically on
    /// the default database by construction (`serve` resolves the default
    /// data dir unless overridden) — safe to replace or remove.
    OursDefault,
    /// Carries an env override pointing at a non-default data dir/estate
    /// (e.g. a development rig). Never auto-removed or auto-replaced; the
    /// reason names the specific override(s) found, for the printed report.
    Foreign(String),
}

/// Env keys whose presence on an existing entry marks it as pointing at a
/// non-default database (ADR-024 §4): `serve` resolves the default data dir
/// unless one of these overrides it, so an entry carrying neither is on the
/// default database by construction.
pub const OVERRIDE_ENV_KEYS: [&str; 2] = ["MOOTX01_DATA_DIR", "ARIA_MCP_SQLITE_PATH"];

/// Classify a JSON-decoded `mcpServers.<name>` entry value (e.g.
/// `{"command":...,"args":[...],"env":{...}}` or `{"type":"http","url":...}`).
///
/// HTTP entries (no `env` key in every shape this installer writes) cannot
/// disagree about the database — they reach whatever estate the resident
/// daemon holds (ADR-024 §4) — so the absence of an `env` map is itself
/// `OursDefault`. Command/stdio entries (the proxy bridge, or a legacy bare
/// `serve`) are `OursDefault` only when their `env` carries neither
/// override key.
pub fn classify(entry: &Value) -> McpEntryOwnership {
    let Some(env) = entry.get("env").and_then(|e| e.as_object()) else {
        return McpEntryOwnership::OursDefault;
    };
    let overriding: Vec<&str> = OVERRIDE_ENV_KEYS
        .iter()
        .filter(|k| env.contains_key(**k))
        .copied()
        .collect();
    if overriding.is_empty() {
        McpEntryOwnership::OursDefault
    } else {
        McpEntryOwnership::Foreign(format!("env override: {}", overriding.join(", ")))
    }
}

/// Returns `true` when `plugin_id` (e.g. `"mootx01@mootx01"`) has at least
/// one installed entry in `~/.claude/plugins/installed_plugins.json`.
///
/// Shape (Claude Code, verified against a real installation):
/// `{"version":2,"plugins":{"<id>":[{"scope":"user","installPath":...,
/// "version":"1.0.11", ...}]}}`. Absence of the file, an empty entry array,
/// or any decode failure all mean "not installed" — the caller falls back
/// to normal direct wiring.
///
/// SAFETY: tests must inject a sandbox `home`, never the real `~/.claude`.
pub fn is_plugin_installed(plugin_id: &str, home: &Path) -> bool {
    let path = home
        .join(".claude")
        .join("plugins")
        .join("installed_plugins.json");
    let Ok(bytes) = std::fs::read(&path) else {
        return false;
    };
    let lossy = String::from_utf8_lossy(&bytes);
    let Ok(root) = serde_json::from_str::<Value>(&lossy) else {
        return false;
    };
    root.get("plugins")
        .and_then(|p| p.get(plugin_id))
        .and_then(|e| e.as_array())
        .map(|a| !a.is_empty())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn http_entry_with_no_env_is_ours_default() {
        let entry = json!({"type": "http", "url": "http://127.0.0.1:4242"});
        assert_eq!(classify(&entry), McpEntryOwnership::OursDefault);
    }

    #[test]
    fn command_entry_with_empty_env_is_ours_default() {
        let entry = json!({"command": "/usr/local/bin/mootx01", "args": ["proxy"], "env": {}});
        assert_eq!(classify(&entry), McpEntryOwnership::OursDefault);
    }

    #[test]
    fn data_dir_override_is_foreign() {
        let entry = json!({
            "command": "/usr/local/bin/mootx01",
            "args": [],
            "env": {"MOOTX01_DATA_DIR": "/Users/dev/rig-a"},
        });
        match classify(&entry) {
            McpEntryOwnership::Foreign(reason) => assert!(reason.contains("MOOTX01_DATA_DIR")),
            other => panic!("expected Foreign, got {other:?}"),
        }
    }

    #[test]
    fn sqlite_path_override_is_foreign() {
        let entry = json!({
            "command": "/usr/local/bin/mootx01",
            "args": [],
            "env": {"ARIA_MCP_SQLITE_PATH": "/Users/dev/estate.sqlite"},
        });
        match classify(&entry) {
            McpEntryOwnership::Foreign(reason) => assert!(reason.contains("ARIA_MCP_SQLITE_PATH")),
            other => panic!("expected Foreign, got {other:?}"),
        }
    }

    #[test]
    fn is_plugin_installed_false_when_absent() {
        let home = std::env::temp_dir().join(format!("mootx01-plugin-detect-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        assert!(!is_plugin_installed("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn is_plugin_installed_true_when_present() {
        let home = std::env::temp_dir().join(format!("mootx01-plugin-detect-{}-2", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = json!({
            "version": 2,
            "plugins": {
                "mootx01@mootx01": [{"scope": "user", "installPath": "x", "version": "1.0.15"}],
            },
        });
        std::fs::write(dir.join("installed_plugins.json"), body.to_string()).unwrap();
        assert!(is_plugin_installed("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn is_plugin_installed_false_when_entry_array_empty() {
        let home = std::env::temp_dir().join(format!("mootx01-plugin-detect-{}-3", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = json!({"version": 2, "plugins": {"mootx01@mootx01": []}});
        std::fs::write(dir.join("installed_plugins.json"), body.to_string()).unwrap();
        assert!(!is_plugin_installed("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }
}
