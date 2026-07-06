//! core/depth.rs — integration-depth feature (PLUGIN_PACKAGING_SPEC §4.4).
//!
//! Three depths applied globally to every selected client:
//!   server  — Mode 1: MCP wiring only (shipping behaviour). No skills.
//!   skills  — Mode 2: server + write the canonical SKILL.md into the client's
//!             real skills dir (install-map skillUserPath, `~` expanded).
//!   plugin  — Mode 3: server + materialise the host's pre-generated native
//!             package into its local plugin dir; falls back to skills (and
//!             REPORTS the fallback) where no plugin format exists (§4.4 table).
//!
//! The depth is a TARGET: each client gets the most it supports, with any
//! fallback reported. This is the non-Apple installer vertical; the Swift
//! vertical (MootInstallerCore/InstallDepth.swift) implements the identical
//! behaviour independently. No FFI — both read the same embedded install
//! bundle (`src/embedded/install-bundle.json`), the shared agreement substrate.
//!
//! The installer consumes pre-generated elements; it NEVER generates them
//! (spec §4 / Decision 3). The bundle is byte-sourced from tools/moot-packager.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

/// Abstraction over invoking the `claude` CLI (ADR-024 Wave 3, Defect 1:
/// "stranded cache"). Rust twin of Swift's `ClaudeCLIRunning` — keep the two
/// in sync by hand. Real callers use `ProcessClaudeCliRunner`, which shells
/// out to `claude` (resolved via PATH, cross-platform); tests inject a fake
/// so the refresh path is unit-testable without touching a real Claude Code
/// installation. Absence of the CLI on PATH and a nonzero exit both surface
/// as `false` — the caller never fails the install over this, only prints a
/// fallback instruction.
pub trait ClaudeCliRunning {
    /// Runs `claude <args>`. Returns `true` on a clean (exit 0) run, `false`
    /// if `claude` is absent from PATH or exits nonzero.
    fn run(&self, args: &[&str]) -> bool;
}

/// Default runner: shells out to `claude`. `std::process::Command` searches
/// PATH itself on every platform (unlike Swift's `Process`, which requires
/// an absolute `executableURL` and needs the `env` indirection) — so no
/// platform-specific PATH resolution is needed here. `Command::new` resolves
/// PATH binaries only — a shell alias or function named `claude` (no PATH
/// binary) is invisible to it, so an alias-only setup falls into this same
/// CLI-absent `false` fallback.
pub struct ProcessClaudeCliRunner;

impl ClaudeCliRunning for ProcessClaudeCliRunner {
    fn run(&self, args: &[&str]) -> bool {
        // Resolve the claude binary from known install locations before
        // falling back to unqualified PATH lookup (#10). A malicious binary
        // named "claude" earlier in PATH could be executed otherwise.
        let home_claude = std::env::var("HOME")
            .map(|h| std::path::PathBuf::from(h).join(".claude/local/claude"))
            .unwrap_or_default();
        let candidates = [
            std::path::PathBuf::from("/usr/local/bin/claude"),
            home_claude,
        ];
        let bin = candidates
            .iter()
            .find(|p| p.is_file())
            .cloned()
            .unwrap_or_else(|| std::path::PathBuf::from("claude"));
        std::process::Command::new(bin)
            .args(args)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }
}

/// The committed, embedded install bundle (compact JSON). Self-contained: the
/// installed binary carries the skill, the host map, and every package.
const INSTALL_BUNDLE_JSON: &str = include_str!("../embedded/install-bundle.json");

/// Requested integration depth.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallDepth {
    Server,
    Skills,
    Plugin,
}

impl InstallDepth {
    /// Default depth (§4.4: Full Plugin). The `--yes` silent default and an
    /// empty depth prompt both resolve here.
    pub const DEFAULT: InstallDepth = InstallDepth::Plugin;

    /// Parse the `--mode` flag value; None for an unrecognised value.
    pub fn from_flag(s: &str) -> Option<InstallDepth> {
        match s.to_ascii_lowercase().as_str() {
            "server" => Some(InstallDepth::Server),
            "skills" => Some(InstallDepth::Skills),
            "plugin" => Some(InstallDepth::Plugin),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            InstallDepth::Server => "server",
            InstallDepth::Skills => "skills",
            InstallDepth::Plugin => "plugin",
        }
    }
}

/// What the installer actually achieved for one client at the requested depth.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DepthOutcome {
    /// Server only: no skill payload for this client, or depth was `server`.
    Server,
    /// Skills (Mode 2): canonical SKILL.md written at this path.
    Skills(String),
    /// Plugin (Mode 3): native package installed at this path.
    Plugin(String),
    /// Plugin requested but the host has no plugin format — fell back to
    /// skills. (path, ceiling reason for reporting).
    PluginFellBackToSkills(String, String),
}

/// One host row from the embedded install-map.
#[derive(Debug, Clone, Deserialize)]
pub struct InstallMapHost {
    pub id: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    pub family: String,
    #[serde(rename = "mcpMapKey")]
    pub mcp_map_key: String,
    #[serde(rename = "mcpUserFormat")]
    pub mcp_user_format: String,
    #[serde(rename = "mcpUserPath")]
    pub mcp_user_path: String,
    pub roadmap: String,
    #[serde(rename = "skillUserPath")]
    pub skill_user_path: String,
}

impl InstallMapHost {
    /// Mode-3 capable only for Family-A manifest bundles. Module-code (Cline,
    /// Hermes, opencode) and ide-config (Xcode) families ceil at Mode 2.
    pub fn supports_plugin(&self) -> bool {
        self.family == "manifestBundle"
    }

    /// Ceiling note printed when a plugin target falls back to skills (§4.4).
    pub fn fallback_reason(&self) -> &'static str {
        match self.family.as_str() {
            "moduleCode" => "no drop-in plugin format (module-host shim is out of scope)",
            "ideConfig" => "config-route only; full plug-in is roadmap 1.1",
            _ => "no plugin format on this host",
        }
    }
}

#[derive(Debug, Deserialize)]
struct InstallMapWire {
    hosts: Vec<InstallMapHost>,
}

#[derive(Debug, Deserialize)]
struct BundleWire {
    #[serde(rename = "skillMarkdown")]
    skill_markdown: String,
    #[serde(rename = "installMap")]
    install_map: InstallMapWire,
    /// "<host>/<relpath>" -> file contents.
    packages: BTreeMap<String, String>,
}

/// The decoded embedded bundle: canonical skill, host map, package trees.
pub struct InstallBundle {
    pub skill_markdown: String,
    hosts: BTreeMap<String, InstallMapHost>,
    packages: BTreeMap<String, String>,
}

impl InstallBundle {
    /// Decode the embedded bundle. Panics on malformed embedded data — that is
    /// a build defect (the artifact is committed), surfaced loudly.
    pub fn embedded() -> &'static InstallBundle {
        use std::sync::OnceLock;
        static BUNDLE: OnceLock<InstallBundle> = OnceLock::new();
        BUNDLE.get_or_init(|| {
            let wire: BundleWire = serde_json::from_str(INSTALL_BUNDLE_JSON)
                .expect("embedded install-bundle.json failed to parse (build defect)");
            let mut hosts = BTreeMap::new();
            for h in wire.install_map.hosts {
                hosts.insert(h.id.clone(), h);
            }
            InstallBundle {
                skill_markdown: wire.skill_markdown,
                hosts,
                packages: wire.packages,
            }
        })
    }

    /// The install-map host for an installer client id, or None when the client
    /// has no skill/plugin payload (claude-desktop, continue, kiro are MCP-only).
    /// Installer client ids and host ids are identical where both exist.
    pub fn host(&self, client_id: &str) -> Option<&InstallMapHost> {
        self.hosts.get(client_id)
    }

    pub fn host_count(&self) -> usize {
        self.hosts.len()
    }

    /// Every host that supports plugin depth (`family == "manifestBundle"`).
    /// Exposed so callers (e.g. `mootx01 upgrade`'s rematerialization pass,
    /// ADR-024 Wave 3 Defect 1) can iterate the plugin-capable hosts without
    /// needing to know every client id up front.
    pub fn plugin_capable_hosts(&self) -> impl Iterator<Item = &InstallMapHost> {
        self.hosts.values().filter(|h| h.supports_plugin())
    }

    /// Package files for a host, keyed by host-relative path.
    pub fn package_files(&self, host_id: &str) -> BTreeMap<String, String> {
        let prefix = format!("{host_id}/");
        self.packages
            .iter()
            .filter_map(|(k, v)| k.strip_prefix(&prefix).map(|rel| (rel.to_string(), v.clone())))
            .collect()
    }
}

/// Expand a leading `~` in an install-map path against `home`.
pub fn expand_tilde(path: &str, home: &Path) -> PathBuf {
    if path == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        let mut p = home.to_path_buf();
        for seg in rest.split('/') {
            if !seg.is_empty() {
                p = p.join(seg);
            }
        }
        return p;
    }
    PathBuf::from(path)
}

/// Apply the requested depth to one client. `Server` is a no-op (MCP wiring
/// already happened in the caller's Mode-1 path); `Skills`/`Plugin` add the
/// payload. Backs up an existing file/dir first (§4.2). Returns what was
/// actually achieved.
///
/// `vault_off` — when true, `MOOTX01_VAULT=0` is injected into the `env`
/// block of any command/stdio-shaped MCP entry written by the plugin
/// installer (the proxy-bridge fallback for a host whose schema cannot
/// express HTTP — see `inject_vault_env`'s doc comment, ADR-024 Wave 3
/// Defect 2). HTTP-shaped entries are never touched: the resident daemon
/// already carries `MOOTX01_VAULT` in its own systemd/Task-Scheduler
/// environment (wired independently at daemon-registration time in
/// `core::service`), and client-side env on an HTTP entry is inert. When
/// false (default / vault-on) the env block is absent, which the server
/// interprets as vault-on (ADR-015 §1: absent MOOTX01_VAULT means vault
/// enabled).
///
/// `claude_cli` — injectable seam for the `claude plugin update`
/// stranded-cache refresh (ADR-024 Wave 3, Defect 1). Pass
/// `&ProcessClaudeCliRunner` in production; tests inject a fake.
pub fn apply(
    client_id: &str,
    depth: InstallDepth,
    home: &Path,
    vault_off: bool,
    claude_cli: &dyn ClaudeCliRunning,
) -> std::io::Result<DepthOutcome> {
    if depth == InstallDepth::Server {
        return Ok(DepthOutcome::Server);
    }
    let bundle = InstallBundle::embedded();
    let Some(host) = bundle.host(client_id) else {
        // MCP-only client — degrade to server.
        return Ok(DepthOutcome::Server);
    };

    match depth {
        InstallDepth::Server => Ok(DepthOutcome::Server),
        InstallDepth::Skills => write_skill(host, home),
        InstallDepth::Plugin => {
            if host.supports_plugin() {
                install_plugin(host, home, vault_off, claude_cli)
            } else {
                // §4.4 ceiling: fall back to skills and report it.
                match write_skill(host, home)? {
                    DepthOutcome::Skills(path) => Ok(DepthOutcome::PluginFellBackToSkills(
                        path,
                        host.fallback_reason().to_string(),
                    )),
                    other => Ok(other),
                }
            }
        }
    }
}

/// The plugin-depth install directory for `host` (parent of the skill's
/// `skills/` dir + `mootx01-plugin`), without checking existence. Exposed so
/// callers (e.g. `mootx01 upgrade`) can check whether a plugin was
/// previously materialized for this host, to decide whether to
/// rematerialize it after a binary swap (ADR-024 Wave 3, Defect 1 — an
/// upgrade alone does not touch this directory or Claude Code's plugin
/// cache unless something asks it to).
pub fn plugin_install_directory(host: &InstallMapHost, home: &Path) -> PathBuf {
    let skill_dest = expand_tilde(&host.skill_user_path, home);
    let plugin_root = skill_dest
        .parent() // mootx01-memory/
        .and_then(|p| p.parent()) // skills/
        .and_then(|p| p.parent()) // host plugin root
        .map(Path::to_path_buf)
        .unwrap_or_else(|| home.to_path_buf());
    plugin_root.join("mootx01-plugin")
}

/// Mode 2: write the embedded canonical SKILL.md to the host's skillUserPath.
fn write_skill(host: &InstallMapHost, home: &Path) -> std::io::Result<DepthOutcome> {
    let bundle = InstallBundle::embedded();
    let dest = expand_tilde(&host.skill_user_path, home);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    backup_existing(&dest)?;
    std::fs::write(&dest, &bundle.skill_markdown)?;
    Ok(DepthOutcome::Skills(dest.display().to_string()))
}

/// Mode 3: materialise the host's pre-generated package tree from the embedded
/// bundle into the host's plugin root (parent of the skill's `skills/` dir).
///
/// When `vault_off` is true, every command/stdio-shaped MCP entry in the
/// package (the proxy-bridge fallback — see `inject_vault_env`) has
/// `env.MOOTX01_VAULT=0` injected before being written. HTTP-shaped entries,
/// skills files, and plugin-metadata files (plugin.json without an
/// mcpServers block) are written verbatim.
///
/// ADR-024 Wave 3, Defect 1 ("stranded cache"): for Claude Code specifically,
/// after materializing the package this also refreshes Claude Code's own
/// plugin cache if it was already installed — see
/// `refresh_stranded_plugin_cache`.
fn install_plugin(
    host: &InstallMapHost,
    home: &Path,
    vault_off: bool,
    claude_cli: &dyn ClaudeCliRunning,
) -> std::io::Result<DepthOutcome> {
    let bundle = InstallBundle::embedded();
    let files = bundle.package_files(&host.id);
    if files.is_empty() {
        // No embedded package — fall back to skills.
        return match write_skill(host, home)? {
            DepthOutcome::Skills(path) => Ok(DepthOutcome::PluginFellBackToSkills(
                path,
                "no embedded package for host; wrote skill only".to_string(),
            )),
            other => Ok(other),
        };
    }
    let dest = plugin_install_directory(host, home);
    // §4.2: back up an existing plugin dir, then replace it.
    if dest.exists() {
        backup_existing(&dest)?;
        std::fs::remove_dir_all(&dest)?;
    }
    std::fs::create_dir_all(&dest)?;
    for (rel, contents) in &files {
        let file = dest.join(rel);
        if let Some(parent) = file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // When vault-off, patch any command/stdio-shaped MCP entry — HTTP
        // entries are skipped (Defect 2): the resident daemon already
        // carries the vault posture in its own service-manager environment,
        // and client-side env on an HTTP entry is inert.
        let out = if vault_off {
            inject_vault_env(rel, contents)
        } else {
            contents.clone()
        };
        std::fs::write(&file, out)?;
    }

    // ADR-024 Wave 3, Defect 1: Claude Code's plugin cache
    // (~/.claude/plugins/installed_plugins.json) pins installPath + version
    // at install time and is never refreshed by rewriting this directory —
    // ask the live CLI to refresh it if the plugin was already installed.
    if host.id == "claude-code" {
        refresh_stranded_plugin_cache(home, claude_cli);
    }

    Ok(DepthOutcome::Plugin(dest.display().to_string()))
}

/// The Claude Code plugin registry id this installer manages.
const CLAUDE_CODE_PLUGIN_ID: &str = "mootx01@mootx01";

/// ADR-024 Wave 3, Defect 1 ("stranded cache"): Claude Code loads plugins
/// from a CACHE SNAPSHOT (`~/.claude/plugins/installed_plugins.json`) that
/// pins `installPath` + `version` at install time — it does NOT re-read the
/// marketplace directory on every launch. Rewriting `~/.claude/mootx01-plugin`
/// (a fresh package, current transport) does nothing to that cache: a user
/// who already has the plugin installed keeps whatever snapshot Claude Code
/// cached — potentially the OLD stdio manifest — no matter how many times
/// `mootx01 install`/`upgrade` rewrites the on-disk package, until something
/// explicitly tells Claude Code to refresh it.
///
/// If the plugin is NOT yet installed, there is no stale cache to refresh —
/// Claude Code discovers and installs fresh (reading the CURRENT package)
/// the next time it loads.
///
/// If it IS already installed, ask the live `claude` CLI to refresh its
/// cached copy (`claude plugin update <id>`, default scope `user`). Never
/// fails the install over this: a missing CLI or a nonzero exit only prints
/// a one-line instruction asking the user to run the refresh themselves,
/// then restart Claude Code.
fn refresh_stranded_plugin_cache(home: &Path, claude_cli: &dyn ClaudeCliRunning) {
    if !crate::core::mcp_ownership::is_plugin_installed(CLAUDE_CODE_PLUGIN_ID, home) {
        return;
    }
    if claude_cli.run(&["plugin", "update", CLAUDE_CODE_PLUGIN_ID]) {
        return;
    }
    println!(
        "  ⓘ Could not refresh the cached mootx01 plugin automatically — run \
         `claude plugin update {CLAUDE_CODE_PLUGIN_ID}` yourself, then restart Claude Code."
    );
}

/// ADR-024 Wave 3, Defect 2 ("dead vault env on HTTP entry"): inject
/// `"env": {"MOOTX01_VAULT": "0"}` on the `mcpServers.mootx01` entry of an
/// MCP config JSON file — but ONLY when that entry is command/stdio-shaped
/// (carries a `command` key: the proxy-bridge fallback for a host whose
/// schema cannot express HTTP). An HTTP-shaped entry (`type`/`url`, no
/// `command`) is left untouched: the resident daemon is the actual MCP
/// server for HTTP transport, so client-side env on the entry is never read
/// by anything — the vault posture for HTTP hosts is carried entirely by
/// the daemon's own systemd/Task-Scheduler environment, wired independently
/// at daemon-registration time (`core::service::daemon_unit` /
/// `daemon_task_command`). Injecting a client-side env block there would be
/// pure noise — worse, it could read as "vault-off applied" when it did
/// nothing.
///
/// Also returns `contents` unchanged for non-`.json` files and JSON files
/// without an `mcpServers` block (plugin-metadata files: author/description
/// only).
///
/// On JSON parse failure the original content is returned unchanged so the
/// host tool can surface the error rather than silently dropping the file.
fn inject_vault_env(rel: &str, contents: &str) -> String {
    // Fast-path: non-JSON files and JSON files without a server block.
    if !rel.ends_with(".json") || !contents.contains("\"mcpServers\"") {
        return contents.to_string();
    }
    let Ok(mut root) = serde_json::from_str::<serde_json::Value>(contents) else {
        // Unparseable embedded JSON is a build defect; return as-is.
        return contents.to_string();
    };
    if let Some(server) = root
        .get_mut("mcpServers")
        .and_then(|m| m.get_mut("mootx01"))
        .and_then(|v| v.as_object_mut())
    {
        // HTTP-shaped entry (no `command` key) — client-side env is inert;
        // skip it (Defect 2). Only command/stdio entries (the proxy bridge)
        // read their own env at all.
        if !server.contains_key("command") {
            return contents.to_string();
        }
        // Merge into an existing env block or create a new one.
        let env = server
            .entry("env")
            .or_insert_with(|| serde_json::Value::Object(serde_json::Map::new()));
        if let Some(env_map) = env.as_object_mut() {
            env_map.insert(
                "MOOTX01_VAULT".to_string(),
                serde_json::Value::String("0".to_string()),
            );
        }
    }
    match serde_json::to_string_pretty(&root) {
        Ok(s) => s + "\n",
        Err(_) => contents.to_string(),
    }
}

/// Back up an existing file or dir to `<name>.bak-<yyyymmdd-HHMMSS>` beside it
/// before overwriting (§4.2). Absent paths are exempt. Mirrors the Swift
/// vertical's `Installer.backupExisting` discipline; reuses the timestamp shape
/// of `merge::backup_existing`.
fn backup_existing(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let stamp = backup_stamp();
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let backup = path.with_file_name(format!("{name}.bak-{stamp}"));
    if backup.exists() {
        return Ok(());
    }
    if path.is_dir() {
        copy_dir_recursive(path, &backup)?;
    } else {
        std::fs::copy(path, &backup)?;
    }
    Ok(())
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if from.is_dir() {
            copy_dir_recursive(&from, &to)?;
        } else {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

/// UTC timestamp `yyyymmdd-HHMMSS` for backup suffixes. Dependency-free
/// (the crate ships no chrono); computed from `SystemTime::UNIX_EPOCH` in UTC,
/// which is sufficient for a unique-per-second backup name.
fn backup_stamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Civil-from-days (Howard Hinnant's algorithm) → y/m/d, plus h:m:s.
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (h, mi, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}{m:02}{d:02}-{h:02}{mi:02}{s:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_flag_parses() {
        assert_eq!(InstallDepth::from_flag("server"), Some(InstallDepth::Server));
        assert_eq!(InstallDepth::from_flag("skills"), Some(InstallDepth::Skills));
        assert_eq!(InstallDepth::from_flag("plugin"), Some(InstallDepth::Plugin));
        assert_eq!(InstallDepth::from_flag("PLUGIN"), Some(InstallDepth::Plugin));
        assert_eq!(InstallDepth::from_flag("bogus"), None);
        assert_eq!(InstallDepth::DEFAULT, InstallDepth::Plugin);
    }

    #[test]
    fn embedded_bundle_decodes() {
        let b = InstallBundle::embedded();
        assert!(b.skill_markdown.contains("name: mootx01-memory"));
        assert_eq!(b.host_count(), 10); // 10th host: xcode (EE packager sync 0b632002)
        assert!(b.host("claude-code").is_some());
        // MCP-only clients have no matrix row.
        assert!(b.host("claude-desktop").is_none());
        assert!(b.host("continue").is_none());
        assert!(b.host("kiro").is_none());
    }

    #[test]
    fn plugin_ceiling_by_family() {
        let b = InstallBundle::embedded();
        for id in ["claude-code", "cursor", "codex", "gemini-cli", "antigravity"] {
            assert!(b.host(id).unwrap().supports_plugin(), "{id} should support plugin");
            assert!(!b.package_files(id).is_empty(), "{id} should have a package");
        }
        for id in ["opencode", "cline", "hermes"] {
            assert!(!b.host(id).unwrap().supports_plugin(), "{id} should ceil at skills");
        }
        // Package SKILL.md is byte-identical to the canonical skill (§0.4).
        assert_eq!(
            b.package_files("claude-code").get("skills/mootx01-memory/SKILL.md"),
            Some(&b.skill_markdown)
        );
    }

    fn tmp_home(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-depth-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Join a `/`-separated relative path onto `home` segment-by-segment, the
    /// same way the production path builders (`expand_tilde`) do. This yields
    /// native separators on every platform — `PathBuf::join` on a single
    /// `/`-containing string keeps the `/` literally on Windows, which would not
    /// match the backslash paths the code produces there.
    fn join_rel(home: &Path, rel: &str) -> PathBuf {
        let mut p = home.to_path_buf();
        for seg in rel.split('/') {
            if !seg.is_empty() {
                p = p.join(seg);
            }
        }
        p
    }

    #[test]
    fn server_depth_is_noop() {
        let home = tmp_home("server");
        assert_eq!(apply("claude-code", InstallDepth::Server, &home, false, &ProcessClaudeCliRunner).unwrap(), DepthOutcome::Server);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn skills_depth_writes_canonical_skill() {
        let home = tmp_home("skills");
        let outcome = apply("claude-code", InstallDepth::Skills, &home, false, &ProcessClaudeCliRunner).unwrap();
        let dest = join_rel(&home, ".claude/skills/mootx01-memory/SKILL.md");
        assert_eq!(outcome, DepthOutcome::Skills(dest.display().to_string()));
        let written = std::fs::read_to_string(&dest).unwrap();
        assert_eq!(written, InstallBundle::embedded().skill_markdown);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn plugin_depth_installs_package() {
        let home = tmp_home("plugin");
        let outcome = apply("claude-code", InstallDepth::Plugin, &home, false, &ProcessClaudeCliRunner).unwrap();
        let root = join_rel(&home, ".claude/mootx01-plugin");
        assert_eq!(outcome, DepthOutcome::Plugin(root.display().to_string()));
        assert!(root.join("skills/mootx01-memory/SKILL.md").exists());
        assert!(root.join(".claude-plugin/plugin.json").exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn plugin_falls_back_to_skills_for_module_host() {
        let home = tmp_home("fallback");
        let outcome = apply("opencode", InstallDepth::Plugin, &home, false, &ProcessClaudeCliRunner).unwrap();
        let dest = join_rel(&home, ".config/opencode/skills/mootx01-memory/SKILL.md");
        match outcome {
            DepthOutcome::PluginFellBackToSkills(path, reason) => {
                assert_eq!(path, dest.display().to_string());
                assert!(!reason.is_empty());
            }
            other => panic!("expected fallback, got {other:?}"),
        }
        assert!(dest.exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn mcp_only_client_degrades_to_server() {
        let home = tmp_home("mcp-only");
        assert_eq!(apply("claude-desktop", InstallDepth::Plugin, &home, false, &ProcessClaudeCliRunner).unwrap(), DepthOutcome::Server);
        assert_eq!(apply("kiro", InstallDepth::Skills, &home, false, &ProcessClaudeCliRunner).unwrap(), DepthOutcome::Server);
        let _ = std::fs::remove_dir_all(&home);
    }

    /// ADR-024 Wave 3, Defect 2: an HTTP-shaped plugin entry (claude-code's
    /// `.mcp.json`, ADR-024 §2) must NOT get an env block even under
    /// vault-off — client-side env on an HTTP entry is inert (the resident
    /// daemon is the actual server, and it carries the vault posture in its
    /// own service-manager environment, wired independently at
    /// daemon-registration time). Before this fix, inject_vault_env blindly
    /// added an env key to this HTTP entry, which did nothing but looked
    /// like it had applied.
    #[test]
    fn vault_off_skips_http_shaped_entry() {
        let home = tmp_home("vault-off");
        let outcome = apply("claude-code", InstallDepth::Plugin, &home, true, &ProcessClaudeCliRunner).unwrap();
        let root = join_rel(&home, ".claude/mootx01-plugin");
        assert_eq!(outcome, DepthOutcome::Plugin(root.display().to_string()));

        let mcp_path = root.join(".mcp.json");
        let mcp_text = std::fs::read_to_string(&mcp_path).unwrap();
        let mcp: serde_json::Value =
            serde_json::from_str(&mcp_text).expect(".mcp.json must be valid JSON");
        let server = &mcp["mcpServers"]["mootx01"];
        assert!(server.get("command").is_none(), "claude-code's plugin entry must remain HTTP-shaped");
        assert_eq!(server["env"], serde_json::Value::Null, "HTTP-shaped entries must never get a client-side env block");
        assert_eq!(server["type"], "http");
        assert!(server.get("url").is_some());

        // Plugin-metadata JSON (no mcpServers) must not gain a spurious env key.
        let meta_path = root.join(".claude-plugin/plugin.json");
        let meta_text = std::fs::read_to_string(&meta_path).unwrap();
        let meta: serde_json::Value = serde_json::from_str(&meta_text).unwrap();
        assert!(meta.get("env").is_none(), "plugin metadata must not be patched");

        // SKILL.md must be present and unmodified.
        assert!(root.join("skills/mootx01-memory/SKILL.md").exists());

        let _ = std::fs::remove_dir_all(&home);
    }

    /// Direct unit coverage of `inject_vault_env`'s shape check (Defect 2): a
    /// synthetic command/stdio-shaped entry (the proxy-bridge fallback shape
    /// — dead for every host reachable through `install_plugin` today) still
    /// gets `MOOTX01_VAULT=0` injected; an HTTP-shaped entry does not.
    #[test]
    fn inject_vault_env_shape_check() {
        let command_entry = r#"{"mcpServers":{"mootx01":{"command":"mootx01","args":["proxy"]}}}"#;
        let patched = inject_vault_env(".mcp.json", command_entry);
        let patched_json: serde_json::Value = serde_json::from_str(&patched).unwrap();
        assert_eq!(
            patched_json["mcpServers"]["mootx01"]["env"]["MOOTX01_VAULT"], "0",
            "a command-shaped entry must still get MOOTX01_VAULT=0 injected"
        );

        let http_entry = r#"{"mcpServers":{"mootx01":{"type":"http","url":"http://127.0.0.1:4242"}}}"#;
        let unchanged = inject_vault_env(".mcp.json", http_entry);
        let unchanged_json: serde_json::Value = serde_json::from_str(&unchanged).unwrap();
        assert!(
            unchanged_json["mcpServers"]["mootx01"].get("env").is_none(),
            "an HTTP-shaped entry must never gain an env block"
        );
    }

    /// vault-on (default) must NOT inject an env block — absent MOOTX01_VAULT
    /// means vault-on per ADR-015 §1.
    #[test]
    fn vault_on_does_not_inject_env() {
        let home = tmp_home("vault-on");
        apply("claude-code", InstallDepth::Plugin, &home, false, &ProcessClaudeCliRunner).unwrap();
        let root = join_rel(&home, ".claude/mootx01-plugin");
        let mcp_text = std::fs::read_to_string(root.join(".mcp.json")).unwrap();
        let mcp: serde_json::Value = serde_json::from_str(&mcp_text).unwrap();
        assert_eq!(
            mcp["mcpServers"]["mootx01"]["env"],
            serde_json::Value::Null,
            "vault-on must leave env absent (absent = vault-on per ADR-015 §1)"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    /// inject_vault_env must leave non-JSON and metadata-only JSON files unchanged.
    #[test]
    fn inject_vault_env_skips_non_mcp_files() {
        // Non-JSON file.
        let md = "# SKILL.md\nsome content";
        assert_eq!(inject_vault_env("skills/mootx01-memory/SKILL.md", md), md);

        // JSON with no mcpServers key (plugin metadata).
        let meta = r#"{"name":"mootx01","version":"0.1.0"}"#;
        assert_eq!(inject_vault_env(".claude-plugin/plugin.json", meta), meta);
    }

    // --- stranded cache refresh (ADR-024 Wave 3, Defect 1) ---

    /// Test double for `ClaudeCliRunning`. `RefCell` is fine — every test
    /// using this drives it synchronously, single-threaded.
    struct FakeClaudeCliRunner {
        should_succeed: bool,
        invoked: std::cell::RefCell<Vec<Vec<String>>>,
    }

    impl FakeClaudeCliRunner {
        fn new(should_succeed: bool) -> Self {
            FakeClaudeCliRunner { should_succeed, invoked: std::cell::RefCell::new(Vec::new()) }
        }
        fn invocations(&self) -> Vec<Vec<String>> {
            self.invoked.borrow().clone()
        }
    }

    impl ClaudeCliRunning for FakeClaudeCliRunner {
        fn run(&self, args: &[&str]) -> bool {
            self.invoked.borrow_mut().push(args.iter().map(|s| s.to_string()).collect());
            self.should_succeed
        }
    }

    fn write_installed_plugins(home: &Path, version: &str) {
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = format!(
            r#"{{"version":2,"plugins":{{"mootx01@mootx01":[{{"scope":"user","installPath":"cache/mootx01/mootx01/{version}","version":"{version}"}}]}}}}"#
        );
        std::fs::write(dir.join("installed_plugins.json"), body).unwrap();
    }

    #[test]
    fn stranded_cache_refresh_invoked_when_installed() {
        let home = tmp_home("stranded-installed");
        write_installed_plugins(&home, "1.0.11");
        let fake = FakeClaudeCliRunner::new(true);
        refresh_stranded_plugin_cache(&home, &fake);
        assert_eq!(fake.invocations(), vec![vec!["plugin".to_string(), "update".to_string(), "mootx01@mootx01".to_string()]]);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn stranded_cache_refresh_noop_when_not_installed() {
        let home = tmp_home("stranded-absent");
        let fake = FakeClaudeCliRunner::new(true);
        refresh_stranded_plugin_cache(&home, &fake);
        assert!(fake.invocations().is_empty(), "no stale cache to refresh when the plugin was never installed");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn stranded_cache_refresh_failure_does_not_fail_install() {
        let home = tmp_home("stranded-fail");
        write_installed_plugins(&home, "1.0.11");
        // should_succeed: false simulates both "claude CLI absent from PATH"
        // and "claude plugin update exited nonzero" — both fall back to a
        // printed instruction, never a propagated error.
        let fake = FakeClaudeCliRunner::new(false);
        let outcome = apply("claude-code", InstallDepth::Plugin, &home, false, &fake).unwrap();
        assert!(matches!(outcome, DepthOutcome::Plugin(_)), "install must succeed even when the cache-refresh CLI fails");
        assert_eq!(fake.invocations().len(), 1);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn stranded_cache_refresh_scoped_to_claude_code() {
        let home = tmp_home("stranded-scope");
        write_installed_plugins(&home, "1.0.11");
        let fake = FakeClaudeCliRunner::new(true);
        apply("cursor", InstallDepth::Plugin, &home, false, &fake).unwrap();
        assert!(fake.invocations().is_empty(), "the stranded-cache refresh is Claude-Code specific");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Acceptance test (mission text verbatim): "a machine in today's exact
    /// broken state (marketplace dir stdio, cache pinned 1.0.11-stdio,
    /// binary upgraded) converges to HTTP-only after `mootx01 install`/
    /// `upgrade` + the plugin update hook + a Claude restart" — exercised
    /// via the injectable seam.
    #[test]
    fn stdio_era_install_converges_to_http() {
        let home = tmp_home("stdio-era");

        // Today's exact broken state: a stale hand-written plugin dir with a
        // bare stdio .mcp.json, AND a cache pinned to that stdio manifest.
        let plugin_dir = join_rel(&home, ".claude/mootx01-plugin");
        std::fs::create_dir_all(&plugin_dir).unwrap();
        std::fs::write(
            plugin_dir.join(".mcp.json"),
            r#"{"mcpServers":{"mootx01":{"command":"mootx01","args":["serve"]}}}"#,
        )
        .unwrap();
        write_installed_plugins(&home, "1.0.11");

        // The exact check `mootx01 upgrade` uses before rematerializing.
        let bundle = InstallBundle::embedded();
        let host = bundle.host("claude-code").unwrap();
        assert!(plugin_install_directory(host, &home).exists());

        let fake = FakeClaudeCliRunner::new(true);
        let outcome = apply("claude-code", InstallDepth::Plugin, &home, false, &fake).unwrap();
        assert!(matches!(outcome, DepthOutcome::Plugin(_)));

        let mcp_text = std::fs::read_to_string(plugin_dir.join(".mcp.json")).unwrap();
        let mcp_json: serde_json::Value = serde_json::from_str(&mcp_text).unwrap();
        assert_eq!(
            mcp_json["mcpServers"]["mootx01"]["type"], "http",
            "converged package must be HTTP-shaped"
        );
        assert!(!mcp_text.contains("\"serve\""), "stdio-era serve entry must not survive rematerialization");
        assert_eq!(
            fake.invocations(),
            vec![vec!["plugin".to_string(), "update".to_string(), "mootx01@mootx01".to_string()]],
            "the stranded cache must be refreshed as part of convergence"
        );

        let _ = std::fs::remove_dir_all(&home);
    }
}
