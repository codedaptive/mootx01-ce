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

/// The exact loopback daemon port this installer's default wiring ever
/// writes. Mirrors Swift's `MootPaths.defaultResidentPort`. A loopback URL
/// on any OTHER port fails the shape check in `classify` (see its doc
/// comment) — a known Swift/Rust asymmetry (ADR-024's recorded static-port
/// limitation, #3) does not change this: the classifier is intentionally
/// conservative rather than permissive.
const DEFAULT_RESIDENT_PORT: u16 = 4242;

/// Classify a JSON-decoded `mcpServers.<name>` entry value (e.g.
/// `{"command":...,"args":[...],"env":{...}}` or `{"type":"http","url":...}`).
///
/// Adams #2 correction: a positive SHAPE check runs first
/// (`looks_like_ours`). Classifying `OursDefault` from the mere absence of
/// an env override — without ever checking that the entry actually looks
/// like ours — made a malformed entry (`{}`) or a user's own unrelated
/// server that happens to sit under the key `"mootx01"` (with no env block)
/// auto-removable on a routine `mootx01 install` once a plugin is present.
/// An entry must resolve to the `mootx01` binary (command basename +
/// `serve`/`proxy` args) OR the exact loopback daemon endpoint before its
/// env is even considered; anything else is `Foreign` — reported by name,
/// never removed — regardless of its env block.
///
/// Once the shape check passes: HTTP entries (no `env` key in every shape
/// this installer writes) cannot disagree about the database — they reach
/// whatever estate the resident daemon holds (ADR-024 §4) — so the absence
/// of an `env` map is itself `OursDefault`. Command/stdio entries (the
/// proxy bridge, or a legacy bare `serve`) are `OursDefault` only when
/// their `env` carries neither override key.
pub fn classify(entry: &Value) -> McpEntryOwnership {
    if !looks_like_ours(entry) {
        return McpEntryOwnership::Foreign(
            "entry shape does not resolve to the mootx01 binary or the loopback daemon endpoint"
                .to_string(),
        );
    }
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

/// Positive shape check (Adams #2): does `entry` actually look like an
/// entry this installer itself would write?
///
/// - Command/stdio shape: `command`'s last path component (basename) is
///   exactly `"mootx01"` (matches either the bare binary name or the
///   absolute placed-binary path), AND `args` contains `"serve"` or
///   `"proxy"` — the only two stdio shapes the installer ever writes.
/// - HTTP shape: `url` matches the loopback daemon endpoint exactly
///   (`is_loopback_daemon_url`) — the ONLY port this installer's default
///   wiring ever writes. A loopback URL on a non-default port does NOT
///   match: it may point at a different, deliberately-scoped daemon
///   instance (the HTTP analogue of an env override), so it fails the
///   shape check and is reported rather than assumed identical.
///
/// A malformed entry (e.g. `{}`), an entry with neither key, or a foreign
/// command/URL under our key name all fail this check.
fn looks_like_ours(entry: &Value) -> bool {
    if let Some(url) = entry.get("url").and_then(|v| v.as_str()) {
        return is_loopback_daemon_url(url);
    }
    if let Some(command) = entry.get("command").and_then(|v| v.as_str()) {
        let basename = std::path::Path::new(command)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let recognized_args = entry
            .get("args")
            .and_then(|v| v.as_array())
            .map(|args| {
                args.iter().any(|a| {
                    matches!(a.as_str(), Some("serve") | Some("proxy"))
                })
            })
            .unwrap_or(false);
        return basename == "mootx01" && recognized_args;
    }
    false
}

/// True only for the exact loopback daemon endpoint this installer writes:
/// `http://127.0.0.1:<DEFAULT_RESIDENT_PORT>` or
/// `http://localhost:<DEFAULT_RESIDENT_PORT>`, with nothing else in the
/// string (no path, query, userinfo, or trailing characters after the port
/// digits).
fn is_loopback_daemon_url(url: &str) -> bool {
    for host in ["127.0.0.1", "localhost"] {
        let expected = format!("http://{host}:{DEFAULT_RESIDENT_PORT}");
        if url == expected {
            return true;
        }
    }
    false
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
    installed_entry(plugin_id, home).is_some()
}

/// Returns the installed plugin manifest version (e.g. `"1.0.15"`) from the
/// first entry for `plugin_id`, or `None` when not installed. Used by
/// `version_skew_advisory` (ADR-024 §5) to compare the plugin's declared
/// version against the running binary's version.
pub fn installed_version(plugin_id: &str, home: &Path) -> Option<String> {
    installed_entry(plugin_id, home)?
        .get("version")?
        .as_str()
        .map(str::to_owned)
}

fn installed_entry(plugin_id: &str, home: &Path) -> Option<Value> {
    let path = home
        .join(".claude")
        .join("plugins")
        .join("installed_plugins.json");
    let bytes = std::fs::read(&path).ok()?;
    let lossy = String::from_utf8_lossy(&bytes);
    let root: Value = serde_json::from_str(&lossy).ok()?;
    root.get("plugins")?
        .get(plugin_id)?
        .as_array()?
        .first()
        .cloned()
}

/// ADR-024 §5: at daemon startup (and in `moot_estate_ping` /
/// `moot_estate_status`), when a plugin is detected, compare the plugin
/// manifest version against the binary version and report skew. Rust twin
/// of Swift's `MootInstallerCore.VersionSkewAdvisory.compute` — keep the two
/// in sync by hand. Returns `None` when the plugin is not installed or its
/// version matches `binary_version` exactly (no skew to report).
pub fn version_skew_advisory(plugin_id: &str, binary_version: &str, home: &Path) -> Option<String> {
    let plugin_version = installed_version(plugin_id, home)?;
    if plugin_version == binary_version {
        return None;
    }
    Some(format!(
        "plugin {plugin_version} expects binary ≥ {plugin_version}; binary is {binary_version} — run `mootx01 upgrade`"
    ))
}

/// Returns `true` when `plugin_id` is enabled in `~/.claude/settings.json`'s
/// `enabledPlugins` map (Adams #5 correction).
///
/// Claude Code tracks installation and enablement SEPARATELY:
/// `installed_plugins.json` records what is present; `settings.json` carries
/// `"enabledPlugins": {"<id>": true/false, ...}` recording what is actually
/// active. An installed-but-disabled plugin does NOT own the MCP
/// connection — treating "installed" alone as "owns the connection" would
/// make `mootx01 install` silently strip the client's only working direct
/// entry out from under it, leaving no connection at all.
///
/// Fails CLOSED toward "not enabled": an absent file, absent
/// `enabledPlugins` key, absent entry for `plugin_id`, or any decode
/// failure all return `false` — the safer direction, since the caller uses
/// this to decide whether to skip/remove the direct entry, and keeping a
/// redundant direct entry is far less harmful than removing the client's
/// only connection.
///
/// SAFETY: tests must inject a sandbox `home`, never the real `~/.claude`.
pub fn is_plugin_enabled(plugin_id: &str, home: &Path) -> bool {
    let path = home.join(".claude").join("settings.json");
    let Ok(bytes) = std::fs::read(&path) else {
        return false;
    };
    let lossy = String::from_utf8_lossy(&bytes);
    let Ok(root) = serde_json::from_str::<Value>(&lossy) else {
        return false;
    };
    root.get("enabledPlugins")
        .and_then(|e| e.get(plugin_id))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// True when the plugin both HAS an installed entry and IS enabled — the
/// combined condition that actually means "this plugin owns the MCP
/// connection right now" (ADR-024 §1/§3, Adams #5 correction). Callers
/// deciding whether to skip/remove a direct entry must use this, not
/// `is_plugin_installed` alone.
pub fn owns_connection(plugin_id: &str, home: &Path) -> bool {
    is_plugin_installed(plugin_id, home) && is_plugin_enabled(plugin_id, home)
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
            "args": ["proxy"],
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
            "args": ["proxy"],
            "env": {"ARIA_MCP_SQLITE_PATH": "/Users/dev/estate.sqlite"},
        });
        match classify(&entry) {
            McpEntryOwnership::Foreign(reason) => assert!(reason.contains("ARIA_MCP_SQLITE_PATH")),
            other => panic!("expected Foreign, got {other:?}"),
        }
    }

    // --- Positive shape check (Adams #2) ---

    #[test]
    fn malformed_empty_entry_never_ours_default() {
        let entry = json!({});
        match classify(&entry) {
            McpEntryOwnership::Foreign(_) => {}
            other => panic!("expected Foreign for a malformed {{}} entry, got {other:?}"),
        }
    }

    #[test]
    fn foreign_command_under_our_key_never_ours_default() {
        // Structurally valid, no env override at all — but the command does
        // not resolve to mootx01. Before the shape check this classified
        // OursDefault purely from env absence.
        let entry = json!({"command": "/usr/bin/some-other-server", "args": ["--stdio"]});
        match classify(&entry) {
            McpEntryOwnership::Foreign(_) => {}
            other => panic!("expected Foreign for a foreign command entry, got {other:?}"),
        }
    }

    #[test]
    fn mootx01_command_without_recognized_args_never_ours_default() {
        let entry = json!({"command": "/usr/local/bin/mootx01", "args": ["--version"]});
        match classify(&entry) {
            McpEntryOwnership::Foreign(_) => {}
            other => panic!("expected Foreign for an unrecognized args shape, got {other:?}"),
        }
    }

    #[test]
    fn loopback_url_nonstandard_port_never_ours_default() {
        // Structurally a loopback HTTP entry, but not on the exact port this
        // installer writes — may be a different, deliberately-scoped daemon
        // instance. Before the shape check this classified OursDefault
        // purely from env absence (HTTP entries carry no env at all).
        let entry = json!({"type": "http", "url": "http://127.0.0.1:9999"});
        match classify(&entry) {
            McpEntryOwnership::Foreign(reason) => assert!(!reason.is_empty()),
            other => panic!("expected Foreign for a nonstandard-port loopback URL, got {other:?}"),
        }
    }

    #[test]
    fn non_loopback_url_never_ours_default() {
        let entry = json!({"type": "http", "url": "http://example.com:4242"});
        match classify(&entry) {
            McpEntryOwnership::Foreign(_) => {}
            other => panic!("expected Foreign for a non-loopback host, got {other:?}"),
        }
    }

    #[test]
    fn localhost_loopback_shape_is_ours_default() {
        let entry = json!({"url": "http://localhost:4242"});
        assert_eq!(classify(&entry), McpEntryOwnership::OursDefault);
    }

    #[test]
    fn legacy_bare_serve_command_is_ours_default() {
        let entry = json!({"command": "/usr/local/bin/mootx01", "args": ["serve"], "env": {}});
        assert_eq!(classify(&entry), McpEntryOwnership::OursDefault);
    }

    // --- is_plugin_enabled / owns_connection (Adams #5) ---

    fn write_settings(home: &Path, json_text: &str) {
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::write(home.join(".claude").join("settings.json"), json_text).unwrap();
    }

    fn write_installed(home: &Path, plugin_id: &str) {
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = json!({"version": 2, "plugins": {plugin_id: [{"scope": "user", "installPath": "x", "version": "1.0.15"}]}});
        std::fs::write(dir.join("installed_plugins.json"), body.to_string()).unwrap();
    }

    #[test]
    fn enabled_false_when_settings_absent() {
        let home = std::env::temp_dir().join(format!("mootx01-enabled-{}-1", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        assert!(!is_plugin_enabled("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn enabled_false_when_key_absent() {
        let home = std::env::temp_dir().join(format!("mootx01-enabled-{}-2", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_settings(&home, r#"{"editorMode":"vim"}"#);
        assert!(!is_plugin_enabled("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn enabled_false_when_explicitly_disabled() {
        let home = std::env::temp_dir().join(format!("mootx01-enabled-{}-3", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":false}}"#);
        assert!(!is_plugin_enabled("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn enabled_false_when_malformed() {
        let home = std::env::temp_dir().join(format!("mootx01-enabled-{}-4", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_settings(&home, "not json at all {{{");
        assert!(!is_plugin_enabled("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn enabled_true_when_enabled() {
        let home = std::env::temp_dir().join(format!("mootx01-enabled-{}-5", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":true,"startup-advisor@awesome-skills":true}}"#);
        assert!(is_plugin_enabled("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn owns_connection_false_when_installed_but_disabled() {
        let home = std::env::temp_dir().join(format!("mootx01-owns-{}-1", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_installed(&home, "mootx01@mootx01");
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":false}}"#);
        assert!(is_plugin_installed("mootx01@mootx01", &home));
        assert!(!owns_connection("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn owns_connection_false_when_settings_absent_fail_closed() {
        let home = std::env::temp_dir().join(format!("mootx01-owns-{}-2", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_installed(&home, "mootx01@mootx01");
        assert!(!owns_connection("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn owns_connection_true_when_installed_and_enabled() {
        let home = std::env::temp_dir().join(format!("mootx01-owns-{}-3", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_installed(&home, "mootx01@mootx01");
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":true}}"#);
        assert!(owns_connection("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn owns_connection_false_when_enabled_but_never_installed() {
        let home = std::env::temp_dir().join(format!("mootx01-owns-{}-4", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":true}}"#);
        assert!(!owns_connection("mootx01@mootx01", &home));
        let _ = std::fs::remove_dir_all(&home);
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
    fn version_skew_advisory_none_when_no_plugin() {
        let home = std::env::temp_dir().join(format!("mootx01-skew-{}-1", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        assert_eq!(version_skew_advisory("mootx01@mootx01", "1.0.15", &home), None);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn version_skew_advisory_none_when_versions_match() {
        let home = std::env::temp_dir().join(format!("mootx01-skew-{}-2", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = json!({"version": 2, "plugins": {"mootx01@mootx01": [{"scope": "user", "installPath": "x", "version": "1.0.15"}]}});
        std::fs::write(dir.join("installed_plugins.json"), body.to_string()).unwrap();
        assert_eq!(version_skew_advisory("mootx01@mootx01", "1.0.15", &home), None);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn version_skew_advisory_reports_mismatch() {
        let home = std::env::temp_dir().join(format!("mootx01-skew-{}-3", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = json!({"version": 2, "plugins": {"mootx01@mootx01": [{"scope": "user", "installPath": "x", "version": "1.0.15"}]}});
        std::fs::write(dir.join("installed_plugins.json"), body.to_string()).unwrap();
        let advisory = version_skew_advisory("mootx01@mootx01", "1.0.11", &home).unwrap();
        assert!(advisory.contains("1.0.15"));
        assert!(advisory.contains("1.0.11"));
        assert!(advisory.contains("mootx01 upgrade"));
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
