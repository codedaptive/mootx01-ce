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

/// Abstraction over invoking the `claude` CLI (plugin-owned MCP connections:
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
        // stdin is EXPLICITLY nulled and the run is bounded by a deadline.
        // Both are load-bearing: with the installer's stdout/stderr as the
        // only visible output, a `claude` that decides to prompt (first-run
        // onboarding, consent, an update question) would otherwise read from
        // the inherited terminal with its question invisible — the install
        // appears to hang forever (observed on a brew-migrated macOS machine,
        // 2026-07-11, in the Swift twin of this runner). Nulled stdin turns
        // any prompt into immediate EOF; the deadline catches non-prompt
        // stalls (network, lock). Both surface as `false`, which callers
        // treat exactly like a nonzero exit: print the run-it-yourself
        // fallback and continue the install.
        let mut child = match std::process::Command::new(bin)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => return false,
        };
        // 60s: `claude plugin update` normally finishes in seconds; this
        // leaves room for a slow network fetch while guaranteeing return.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return status.success(),
                Ok(None) if std::time::Instant::now() >= deadline => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
                Ok(None) => std::thread::sleep(std::time::Duration::from_millis(200)),
                Err(_) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
            }
        }
    }
}

/// Codex CLI seam. Tests use a fake; production runs without terminal input and
/// with a deadline. `None` means unavailable, unsuccessful, or malformed output.
pub trait CodexCliRunning {
    fn run(&self, args: &[&str]) -> Option<String>;
}

pub struct ProcessCodexCliRunner;
impl CodexCliRunning for ProcessCodexCliRunner {
    fn run(&self, args: &[&str]) -> Option<String> {
        use std::io::Read;
        use std::process::{Command, Stdio};
        let mut child = Command::new("codex").args(args)
            .stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null())
            .spawn().ok()?;
        let stdout = child.stdout.take()?;
        // Drain concurrently so list output cannot fill the pipe and deadlock.
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = stdout.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes);
            let output = if result.is_ok() && bytes.len() <= 4 * 1024 * 1024 {
                String::from_utf8(bytes).ok()
            } else { None };
            let _ = sender.send(output);
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    return if status.success() { receiver.recv_timeout(std::time::Duration::from_secs(2)).ok().flatten() } else { None };
                }
                Ok(None) if std::time::Instant::now() < deadline =>
                    std::thread::sleep(std::time::Duration::from_millis(100)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
            }
        }
    }
}

/// Registry state comes from Codex, never a leftover materialized directory.
/// Outer None is a failed/invalid query; inner None means not installed.
pub fn codex_installed_enabled(cli: &dyn CodexCliRunning) -> Option<Option<bool>> {
    let output = cli.run(&["plugin", "list", "--json"])?;
    let root: serde_json::Value = serde_json::from_str(&output).ok()?;
    let installed = root.get("installed")?.as_array()?;
    for plugin in installed {
        if plugin.get("pluginId")?.as_str()? == "mootx01@mootx01" {
            if !plugin.get("installed")?.as_bool()? { return Some(None); }
            return Some(Some(plugin.get("enabled")?.as_bool()?));
        }
    }
    Some(None)
}

fn codex_registered_version(cli: &dyn CodexCliRunning, expected: &str) -> bool {
    let Some(output) = cli.run(&["plugin", "list", "--json"]) else { return false; };
    let Ok(root) = serde_json::from_str::<serde_json::Value>(&output) else { return false; };
    root.get("installed").and_then(|v| v.as_array()).map(|plugins| plugins.iter().any(|p|
        p.get("pluginId").and_then(|v| v.as_str()) == Some("mootx01@mootx01")
        && p.get("installed").and_then(|v| v.as_bool()) == Some(true)
        && p.get("enabled").and_then(|v| v.as_bool()) == Some(true)
        && p.get("version").and_then(|v| v.as_str()) == Some(expected)
    )).unwrap_or(false)
}

/// Remove only the exact HTTP table written by this installer, after verified
/// plugin registration. Extra options, child tables, alternate endpoints and
/// malformed/duplicate tables are preserved for manual inspection.
fn cleanup_codex_default_direct_entry(home: &Path) -> std::io::Result<()> {
    let codex_home = if codex_cli_home_matches(home) {
        std::env::var_os("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".codex"))
    } else { home.join(".codex") };
    let path = codex_home.join("config.toml");
    let content = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    let mut in_table = false;
    let mut tables = 0;
    let mut body = Vec::new();
    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            if line.starts_with("[mcp_servers.mootx01.") { return Ok(()); }
            in_table = line == "[mcp_servers.mootx01]";
            if in_table { tables += 1; }
        } else if in_table && !line.is_empty() && !line.starts_with('#') {
            body.push(line);
        }
    }
    if tables != 1 || body != ["url = \"http://127.0.0.1:4242\""] { return Ok(()); }
    backup_existing(&path)?;
    crate::core::merge::remove_from_toml_config(&path, "mootx01")
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    Ok(())
}

/// Production guard: a fixture/alternate home must never mutate the live Codex
/// registry. The CLI resolves CODEX_HOME itself for the actual user's install.
pub fn codex_cli_home_matches(home: &Path) -> bool {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from).as_deref() == Some(home)
}

/// Install the embedded Codex package and register it through Codex's supported
/// CLI. Upgrade only refreshes confirmed installed/enabled plugins; disabled
/// plugins are left untouched because `plugin add` can re-enable them.
pub fn apply_codex_plugin(
    home: &Path,
    vault_off: bool,
    upgrade_only: bool,
    cli: &dyn CodexCliRunning,
) -> std::io::Result<Option<DepthOutcome>> {
    if upgrade_only {
        match codex_installed_enabled(cli) {
            Some(Some(true)) => {},
            Some(Some(false)) => {
                println!("  ⓘ Codex mootx01 plugin is disabled; update deferred to preserve that choice.");
                return Ok(None);
            }
            Some(None) => return Ok(None),
            None => {
                println!("  ⓘ Could not check installed Codex plugins; plugin update skipped.");
                return Ok(None);
            }
        }
    }
    let outcome = apply("codex", InstallDepth::Plugin, home, vault_off, &ProcessClaudeCliRunner)?;
    let DepthOutcome::Plugin(ref path) = outcome else { return Ok(Some(outcome)); };
    let dir = Path::new(path);
    let marketplace_dir = dir.join(".codex-plugin");
    std::fs::create_dir_all(&marketplace_dir)?;
    let marketplace = serde_json::json!({
        "name": "mootx01",
        "owner": {"name": "Codedaptive"},
        "plugins": [{"name": "mootx01", "source": "./"}]
    });
    std::fs::write(marketplace_dir.join("marketplace.json"),
        serde_json::to_vec_pretty(&marketplace)?)?;
    let manifest: serde_json::Value = serde_json::from_slice(
        &std::fs::read(dir.join(".codex-plugin/plugin.json"))?)?;
    let expected_version = manifest.get("version").and_then(|v| v.as_str())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "Codex plugin version missing"))?;
    if cli.run(&["plugin", "marketplace", "add", path]).is_none()
        || cli.run(&["plugin", "add", "mootx01@mootx01"]).is_none()
        || !codex_registered_version(cli, expected_version) {
        println!("  ⓘ Codex plugin files prepared; registration failed. Run `codex plugin marketplace add '{}'` then `codex plugin add mootx01@mootx01`, then restart Codex.", path.replace('\'', "'\\''"));
        let skill = apply("codex", InstallDepth::Skills, home, vault_off, &ProcessClaudeCliRunner)?;
        if let DepthOutcome::Skills(path) = skill {
            return Ok(Some(DepthOutcome::PluginFellBackToSkills(path,
                "Codex CLI registration failed; wrote skill only".to_string())));
        }
    } else {
        if let Err(e) = cleanup_codex_default_direct_entry(home) {
            println!("  ⓘ Codex plugin registered, but direct MCP cleanup failed: {e}");
        }
        println!("  ✓ Codex mootx01 plugin registered — restart Codex to load it.");
    }
    Ok(Some(outcome))
}

/// The committed, embedded install bundle (compact JSON). Self-contained: the
/// installed binary carries the skill, the host map, and every package.
#[cfg(feature = "aria-v2")]
const INSTALL_BUNDLE_JSON: &str = include_str!("../embedded/install-bundle-v2.json");
#[cfg(not(feature = "aria-v2"))]
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
    #[serde(rename = "ariaVersion")]
    aria_version: Option<String>,
    #[serde(rename = "ariaBundleIdentity")]
    aria_bundle_identity: Option<String>,
    #[serde(rename = "skillMarkdown")]
    skill_markdown: String,
    #[serde(rename = "skillMarkdownByHost")]
    skill_markdown_by_host: Option<BTreeMap<String, String>>,
    #[serde(rename = "installMap")]
    install_map: InstallMapWire,
    /// "<host>/<relpath>" -> file contents.
    packages: BTreeMap<String, String>,
}

/// The decoded embedded bundle: canonical skill, host map, package trees.
pub struct InstallBundle {
    pub aria_version: String,
    pub aria_bundle_identity: String,
    pub skill_markdown: String,
    skill_markdown_by_host: BTreeMap<String, String>,
    hosts: BTreeMap<String, InstallMapHost>,
    packages: BTreeMap<String, String>,
}

impl InstallBundle {
    fn selected_aria_version() -> &'static str {
        #[cfg(feature = "aria-v2")]
        {
            // The Rust vertical reads the public selected-surface authority,
            // enabled only by the explicit Cargo feature forwarding.
            aria_mcp::v2::render::V2_SURFACE_VERSION
        }
        #[cfg(not(feature = "aria-v2"))]
        {
            "v1"
        }
    }

    fn from_json(json: &str) -> Result<Self, String> {
        let wire: BundleWire = serde_json::from_str(json).map_err(|error| error.to_string())?;
        let aria_version = wire.aria_version.unwrap_or_else(|| "v1".to_string());
        let selected = Self::selected_aria_version();
        if aria_version != selected {
            return Err(format!(
                "install bundle ARIA release {aria_version} does not match executable release {selected}"
            ));
        }
        let aria_bundle_identity = match wire.aria_bundle_identity {
            Some(identity) if !identity.is_empty() => identity,
            _ if aria_version == "v1" => "legacy-v1".to_string(),
            _ => return Err(format!("install bundle has no identity for ARIA release {aria_version}")),
        };
        let mut hosts = BTreeMap::new();
        for h in wire.install_map.hosts {
            hosts.insert(h.id.clone(), h);
        }
        Ok(InstallBundle {
            aria_version,
            aria_bundle_identity,
            skill_markdown: wire.skill_markdown,
            skill_markdown_by_host: wire.skill_markdown_by_host.unwrap_or_default(),
            hosts,
            packages: wire.packages,
        })
    }

    /// Decode the embedded bundle. Panics on malformed embedded data — that is
    /// a build defect (the artifact is committed), surfaced loudly.
    pub fn embedded() -> &'static InstallBundle {
        use std::sync::OnceLock;
        static BUNDLE: OnceLock<InstallBundle> = OnceLock::new();
        BUNDLE.get_or_init(|| {
            Self::from_json(INSTALL_BUNDLE_JSON)
                .expect("embedded install-bundle.json failed to parse (build defect)")
        })
    }

    /// The install-map host for an installer client id, or None when the client
    /// has no skill/plugin payload (claude-desktop, continue, kiro are MCP-only).
    /// Installer client ids and host ids are identical where both exist.
    pub fn host(&self, client_id: &str) -> Option<&InstallMapHost> {
        self.hosts.get(client_id)
    }

    /// Select a generated host wrapper, retaining the neutral scalar for
    /// pre-selector or intentionally shared payloads.
    pub fn skill_markdown_for_host(&self, host_id: &str) -> &str {
        self.skill_markdown_by_host
            .get(host_id)
            .map(String::as_str)
            .unwrap_or(&self.skill_markdown)
    }

    pub fn host_count(&self) -> usize {
        self.hosts.len()
    }

    /// Every host that supports plugin depth (`family == "manifestBundle"`).
    /// Exposed so callers (e.g. `mootx01 upgrade`'s rematerialization pass,
    /// plugin-owned MCP connections) can iterate the plugin-capable hosts without
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
/// express HTTP — see `inject_vault_env`'s doc comment, plugin-owned MCP connections
/// Defect 2). HTTP-shaped entries are never touched: the resident daemon
/// already carries `MOOTX01_VAULT` in its own systemd/Task-Scheduler
/// environment (wired independently at daemon-registration time in
/// `core::service`), and client-side env on an HTTP entry is inert. When
/// false (default / vault-on) the env block is absent, which the server
/// interprets as vault-on (the open 1.0 Vault posture: absent MOOTX01_VAULT means vault
/// enabled).
///
/// `claude_cli` — injectable seam for the `claude plugin update`
/// stranded-cache refresh. Pass
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
        InstallDepth::Skills => write_skill(host, bundle, home),
        InstallDepth::Plugin => {
            if host.supports_plugin() {
                install_plugin(host, home, vault_off, claude_cli)
            } else {
                // §4.4 ceiling: fall back to skills and report it.
                match write_skill(host, bundle, home)? {
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
/// rematerialize it after a binary swap (plugin-owned MCP connections — an
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
fn write_skill(
    host: &InstallMapHost,
    bundle: &InstallBundle,
    home: &Path,
) -> std::io::Result<DepthOutcome> {
    let dest = expand_tilde(&host.skill_user_path, home);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    backup_existing(&dest)?;
    std::fs::write(&dest, bundle.skill_markdown_for_host(&host.id))?;
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
/// Claude Code loads plugins from a cache snapshot. After materializing the
/// package, this also refreshes Claude Code's own
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
        return match write_skill(host, bundle, home)? {
            DepthOutcome::Skills(path) => Ok(DepthOutcome::PluginFellBackToSkills(
                path,
                "no embedded package for host; wrote skill only".to_string(),
            )),
            other => Ok(other),
        };
    }
    let dest = plugin_install_directory(host, home);
    // Back up an existing plugin directory, then replace it.
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
        // entries are skipped: the resident daemon already
        // carries the vault posture in its own service-manager environment,
        // and client-side env on an HTTP entry is inert.
        let out = if vault_off {
            inject_vault_env(rel, contents)
        } else {
            contents.clone()
        };
        std::fs::write(&file, out)?;
    }

    // Claude Code's plugin cache
    // (~/.claude/plugins/installed_plugins.json) pins installPath + version
    // at install time and is never refreshed by rewriting this directory —
    // ask the live CLI to refresh it if the plugin was already installed.
    if host.id == "claude-code" {
        if let Some(line) = refresh_stranded_plugin_cache(home, claude_cli) {
            println!("{line}");
        }
    }

    Ok(DepthOutcome::Plugin(dest.display().to_string()))
}

/// The Claude Code plugin registry id this installer manages.
const CLAUDE_CODE_PLUGIN_ID: &str = "mootx01@mootx01";

/// Claude Code loads plugins from a cache snapshot
/// (`~/.claude/plugins/installed_plugins.json`) that
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
/// fails the install over this: a missing CLI or a nonzero exit only yields
/// a one-line instruction asking the user to run the refresh themselves,
/// then restart Claude Code.
///
/// Returns the user-facing line the CALLER prints, or None when the plugin
/// was never installed (nothing to say). The success line exists because
/// `claude plugin update` refreshes the ON-DISK cache only — a running
/// Claude Code session keeps the previous plugin snapshot loaded until it
/// is restarted, so a silent success left users testing against the old
/// plugin while the upgrade reported clean (MOOT-INSTALL-E defect 1;
/// mirrors the Swift `refreshStrandedPluginCache`). Returning the message
/// keeps the line unit-testable via the fake runner.
fn refresh_stranded_plugin_cache(
    home: &Path,
    claude_cli: &dyn ClaudeCliRunning,
) -> Option<String> {
    if !crate::core::mcp_ownership::is_plugin_installed(CLAUDE_CODE_PLUGIN_ID, home) {
        return None;
    }
    if claude_cli.run(&["plugin", "update", CLAUDE_CODE_PLUGIN_ID]) {
        return Some(
            "  ✓ Claude Code plugin cache refreshed — restart Claude Code (start a new \
             session) to load the updated plugin."
                .to_string(),
        );
    }
    Some(format!(
        "  ⓘ Could not refresh the cached mootx01 plugin automatically — run \
         `claude plugin update {CLAUDE_CODE_PLUGIN_ID}` yourself, then restart Claude Code."
    ))
}

/// Inject
/// `"env": {"MOOTX01_VAULT": "0"}` on the `mcpServers.<PLUGIN_SERVER_NAME>`
/// entry of a plugin package's MCP manifest — this runs only over the files
/// `install_plugin` materialises, so the key is the plugin-package key
/// (`clients::PLUGIN_SERVER_NAME`), never the direct-entry
/// `clients::SERVER_NAME`. The two differ deliberately; see `core::clients`.
///
/// The patch applies ONLY when that entry is command/stdio-shaped
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
        .and_then(|m| m.get_mut(crate::core::clients::PLUGIN_SERVER_NAME))
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
    use crate::core::clients;

    struct FakeCodexCli {
        replies: std::cell::RefCell<std::collections::VecDeque<Option<String>>>,
        calls: std::cell::RefCell<Vec<Vec<String>>>,
    }
    impl FakeCodexCli {
        fn new(replies: Vec<Option<&str>>) -> Self {
            Self {
                replies: std::cell::RefCell::new(replies.into_iter().map(|s| s.map(str::to_string)).collect()),
                calls: std::cell::RefCell::new(Vec::new()),
            }
        }
    }
    impl CodexCliRunning for FakeCodexCli {
        fn run(&self, args: &[&str]) -> Option<String> {
            self.calls.borrow_mut().push(args.iter().map(|s| s.to_string()).collect());
            self.replies.borrow_mut().pop_front().expect("unexpected Codex CLI call")
        }
    }
    fn codex_test_home() -> PathBuf {
        let home = std::env::temp_dir().join(format!("moot-codex-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        home
    }
    fn codex_current_registry() -> String {
        let bundle = InstallBundle::embedded();
        let manifest: serde_json::Value = serde_json::from_str(
            &bundle.package_files("codex")[".codex-plugin/plugin.json"]).unwrap();
        serde_json::json!({"installed":[{"pluginId":"mootx01@mootx01", "installed":true,
            "enabled":true,"version":manifest["version"]}]}).to_string()
    }
    #[test]
    fn codex_install_registers_local_embedded_plugin() {
        let home = codex_test_home();
        let registry = codex_current_registry();
        let cli = FakeCodexCli::new(vec![Some("{}"), Some("{}"), Some(&registry)]);
        let result = apply_codex_plugin(&home, false, false, &cli).unwrap();
        let Some(DepthOutcome::Plugin(path)) = result else { panic!("expected plugin"); };
        let calls = cli.calls.borrow();
        assert_eq!(calls[0], vec!["plugin", "marketplace", "add", &path]);
        assert_eq!(calls[1], vec!["plugin", "add", "mootx01@mootx01"]);
        let manifest: serde_json::Value = serde_json::from_slice(&std::fs::read(
            Path::new(&path).join(".codex-plugin/marketplace.json")).unwrap()).unwrap();
        assert_eq!(manifest["plugins"][0]["source"], "./");
        assert!(Path::new(&path).join(".codex-plugin/plugin.json").is_file());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn codex_upgrade_uses_registry_not_materialized_directory() {
        for reply in [Some(r#"{"installed":[]}"#),
            Some(r#"{"installed":[{"pluginId":"mootx01@mootx01","installed":true,"enabled":false}]}"#),
            Some("malformed"), None] {
            let home = codex_test_home();
            let bundle = InstallBundle::embedded();
            let dir = plugin_install_directory(bundle.host("codex").unwrap(), &home);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("marker"), "untouched").unwrap();
            let cli = FakeCodexCli::new(vec![reply]);
            assert!(apply_codex_plugin(&home, false, true, &cli).unwrap().is_none());
            assert_eq!(std::fs::read_to_string(dir.join("marker")).unwrap(), "untouched");
            assert_eq!(cli.calls.borrow().len(), 1);
            assert!(!dir.join(".codex-plugin/plugin.json").exists());
            std::fs::remove_dir_all(home).unwrap();
        }
    }
    #[test]
    fn codex_upgrade_refreshes_installed_plugin_without_loose_directory() {
        let home = codex_test_home();
        let registry = codex_current_registry();
        let cli = FakeCodexCli::new(vec![Some(&registry), Some("{}"), Some("{}"), Some(&registry)]);
        assert!(matches!(apply_codex_plugin(&home, false, true, &cli).unwrap(), Some(DepthOutcome::Plugin(_))));
        assert_eq!(cli.calls.borrow().len(), 4);
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn codex_cleanup_preserves_foreign_and_removes_only_managed_http() {
        for (body, removed) in [
            ("url = \"http://127.0.0.1:4242\"\n", true),
            ("url = \"http://127.0.0.1:4243\"\n", false),
            ("url = \"http://127.0.0.1:4242\"\nenabled = false\n", false),
            ("url = \"http://127.0.0.1:4242\"\n[mcp_servers.mootx01.env]\nA = \"B\"\n", false),
        ] {
            let home = codex_test_home();
            std::fs::create_dir_all(home.join(".codex")).unwrap();
            let path = home.join(".codex/config.toml");
            let original = format!("model = \"test\"\n[mcp_servers.mootx01]\n{body}[other]\nx = true\n");
            std::fs::write(&path, &original).unwrap();
            cleanup_codex_default_direct_entry(&home).unwrap();
            let actual = std::fs::read_to_string(path).unwrap();
            assert_eq!(!actual.contains("[mcp_servers.mootx01]"), removed);
            if !removed { assert_eq!(actual, original); }
            assert!(actual.contains("[other]\nx = true"));
            std::fs::remove_dir_all(home).unwrap();
        }
    }
    #[test]
    fn codex_readback_failure_preserves_direct_connection() {
        let home = codex_test_home();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        let path = home.join(".codex/config.toml");
        let original = "[mcp_servers.mootx01]\nurl = \"http://127.0.0.1:4242\"\n";
        std::fs::write(&path, original).unwrap();
        let cli = FakeCodexCli::new(vec![Some("{}"), Some("{}"), Some(r#"{"installed":[]}"#)]);
        assert!(matches!(apply_codex_plugin(&home, false, false, &cli).unwrap(),
            Some(DepthOutcome::PluginFellBackToSkills(_, _))));
        assert_eq!(std::fs::read_to_string(path).unwrap(), original);
        assert_eq!(cli.calls.borrow().len(), 3);
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn codex_registration_failure_writes_fallback_skill_and_stops_sequence() {
        let home = codex_test_home();
        let cli = FakeCodexCli::new(vec![None]);
        let Some(DepthOutcome::PluginFellBackToSkills(path, _)) =
            apply_codex_plugin(&home, false, false, &cli).unwrap() else { panic!("expected skill fallback"); };
        assert!(Path::new(&path).is_file());
        assert_eq!(cli.calls.borrow().len(), 1);
        assert!(!codex_cli_home_matches(&home));
        std::fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn mode_flag_parses() {
        assert_eq!(InstallDepth::from_flag("server"), Some(InstallDepth::Server));
        assert_eq!(InstallDepth::from_flag("skills"), Some(InstallDepth::Skills));
        assert_eq!(InstallDepth::from_flag("plugin"), Some(InstallDepth::Plugin));
        assert_eq!(InstallDepth::from_flag("PLUGIN"), Some(InstallDepth::Plugin));
        assert_eq!(InstallDepth::from_flag("bogus"), None);
        assert_eq!(InstallDepth::DEFAULT, InstallDepth::Plugin);
    }

    /// No embedded Codex lifecycle hook command may resolve `mootx01` via
    /// bare PATH order (CH-01 security finding: hooks fire automatically on
    /// Codex lifecycle events, so a bare name hands code execution to any
    /// attacker-controlled directory earlier in PATH). `mootx01 install`
    /// materializes the packages map compiled in above (INSTALL_BUNDLE_JSON,
    /// include_str!) — this guards the carrier the Rust port actually ships,
    /// parsed via serde_json, never substring-matched. A bare token is any
    /// token delimited by whitespace, shell separators (`;&|()`), quote
    /// characters, or backticks that equals `mootx01` with no `/` — so
    /// `exec mootx01 …`, `env mootx01 …`, `sh -c 'mootx01 …'`, and both
    /// command-substitution forms are all caught, not just a bare head
    /// token. Mirrors the Swift twin in MootInstallerCoreTests
    /// PluginPackageShapeTests and the packager guard in moot-packager
    /// GeneratorTests; keep the three token rules in sync.
    #[test]
    fn embedded_codex_hook_commands_never_resolve_via_bare_path() {
        fn hook_commands(v: &serde_json::Value, out: &mut Vec<String>) {
            match v {
                serde_json::Value::Object(map) => {
                    if map.get("type").and_then(|t| t.as_str()) == Some("command") {
                        if let Some(cmd) = map.get("command").and_then(|c| c.as_str()) {
                            out.push(cmd.to_string());
                        }
                    }
                    for val in map.values() {
                        hook_commands(val, out);
                    }
                }
                serde_json::Value::Array(arr) => {
                    for val in arr {
                        hook_commands(val, out);
                    }
                }
                _ => {}
            }
        }

        let bundle = InstallBundle::embedded();
        let wiring = bundle
            .packages
            .get("codex/.codex/hooks.json")
            .expect("embedded codex package carries no .codex/hooks.json — bundle shape changed?");
        let root: serde_json::Value = serde_json::from_str(wiring)
            .expect("embedded codex hooks wiring is not valid JSON");

        let mut commands = Vec::new();
        hook_commands(&root, &mut commands);
        assert!(
            !commands.is_empty(),
            "embedded codex hooks wiring carries no commands — wiring shape changed?"
        );

        for cmd in &commands {
            let bare = cmd
                .split(|c: char| c.is_whitespace() || ";&|()'\"`".contains(c))
                .any(|token| token == "mootx01");
            assert!(
                !bare,
                "embedded codex hooks wiring resolves mootx01 via bare PATH: {cmd}"
            );
        }
    }

    #[test]
    fn embedded_bundle_decodes() {
        let b = InstallBundle::embedded();
        assert!(b.skill_markdown.contains("name: mootx01-memory"));
        assert_eq!(b.aria_version, InstallBundle::selected_aria_version());
        assert!(b.aria_bundle_identity.starts_with(&format!("mootx01/{}/", b.aria_version)));
        assert_eq!(b.host_count(), 10); // 10th host: xcode (EE packager sync 0b632002)
        assert!(b.host("claude-code").is_some());
        // MCP-only clients have no matrix row.
        assert!(b.host("claude-desktop").is_none());
        assert!(b.host("continue").is_none());
        assert!(b.host("kiro").is_none());
    }

    #[cfg(feature = "aria-v2")]
    #[test]
    fn v2_embedded_bundle_identity_matches_registry() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .ancestors().nth(3).expect("repository root from apps/mootx01/rust");
        let registry: serde_json::Value = serde_json::from_slice(&std::fs::read(
            root.join("packages/kits/AriaMcpKit/Registry/aria-v2-selected-release.json")
        ).expect("read selected ARIA release artifact")).expect("decode selected ARIA release artifact");
        let catalog_identity = registry["catalogIdentity"].as_str().expect("catalog identity");
        let bundle = InstallBundle::embedded();
        assert_eq!(registry["ariaVersion"], "v2");
        assert_eq!(bundle.aria_version, "v2");
        assert_eq!(bundle.aria_bundle_identity, format!("mootx01/v2/{catalog_identity}"));
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
            b.package_files("claude-code")
                .get("skills/mootx01-memory/SKILL.md")
                .map(String::as_str),
            Some(b.skill_markdown_for_host("claude-code"))
        );
    }

    fn staged_bundle_json(version: &str) -> String {
        format!(r#"{{
          "schemaVersion": 1,
          "ariaVersion": "{version}",
          "ariaBundleIdentity": "mootx01/fixture/selected",
          "skillMarkdown": "shared teaching",
          "skillMarkdownByHost": {{"codex": "codex teaching"}},
          "installMap": {{"hosts": [{{
            "id": "codex", "displayName": "Codex", "family": "manifestBundle",
            "mcpMapKey": "mcpServers", "mcpUserFormat": "json",
            "mcpUserPath": "~/.codex/config.json", "roadmap": "now",
            "skillUserPath": "~/.codex/skills/mootx01-memory/SKILL.md"
          }}]}},
          "packages": {{}}
        }}"#)
    }

    #[test]
    fn staged_bundle_selects_host_payload_and_writes_fixture_home() {
        let staged = InstallBundle::from_json(&staged_bundle_json(InstallBundle::selected_aria_version())).unwrap();
        assert_eq!(staged.aria_bundle_identity, "mootx01/fixture/selected");
        assert_eq!(staged.skill_markdown_for_host("codex"), "codex teaching");
        assert_eq!(staged.skill_markdown_for_host("unknown"), "shared teaching");

        let home = tmp_home("staged-host-payload");
        let host = staged.host("codex").unwrap();
        write_skill(host, &staged, &home).unwrap();
        let written = std::fs::read_to_string(join_rel(&home, ".codex/skills/mootx01-memory/SKILL.md")).unwrap();
        assert_eq!(written, "codex teaching");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn staged_bundle_rejects_unselected_release() {
        let other = if InstallBundle::selected_aria_version() == "v1" { "v2" } else { "v1" };
        assert!(InstallBundle::from_json(&staged_bundle_json(other)).is_err());
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
        assert_eq!(written, InstallBundle::embedded().skill_markdown_for_host("claude-code"));
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

    /// an HTTP-shaped plugin entry (claude-code's
    /// `.mcp.json`, plugin-owned MCP connections) must NOT get an env block even under
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
        let server = &mcp["mcpServers"][clients::PLUGIN_SERVER_NAME];
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
            patched_json["mcpServers"][clients::PLUGIN_SERVER_NAME]["env"]["MOOTX01_VAULT"], "0",
            "a command-shaped entry must still get MOOTX01_VAULT=0 injected"
        );

        let http_entry = r#"{"mcpServers":{"mootx01":{"type":"http","url":"http://127.0.0.1:4242"}}}"#;
        let unchanged = inject_vault_env(".mcp.json", http_entry);
        let unchanged_json: serde_json::Value = serde_json::from_str(&unchanged).unwrap();
        assert!(
            unchanged_json["mcpServers"][clients::PLUGIN_SERVER_NAME].get("env").is_none(),
            "an HTTP-shaped entry must never gain an env block"
        );
    }

    /// vault-on (default) must NOT inject an env block — absent MOOTX01_VAULT
    /// means vault-on.
    #[test]
    fn vault_on_does_not_inject_env() {
        let home = tmp_home("vault-on");
        apply("claude-code", InstallDepth::Plugin, &home, false, &ProcessClaudeCliRunner).unwrap();
        let root = join_rel(&home, ".claude/mootx01-plugin");
        let mcp_text = std::fs::read_to_string(root.join(".mcp.json")).unwrap();
        let mcp: serde_json::Value = serde_json::from_str(&mcp_text).unwrap();
        assert_eq!(
            mcp["mcpServers"][clients::PLUGIN_SERVER_NAME]["env"],
            serde_json::Value::Null,
            "vault-on must leave env absent (absent = vault-on)"
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

    // --- stranded cache refresh ---

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
        let line = refresh_stranded_plugin_cache(&home, &fake);
        assert_eq!(fake.invocations(), vec![vec!["plugin".to_string(), "update".to_string(), "mootx01@mootx01".to_string()]]);
        // MOOT-INSTALL-E defect 1: the SUCCESS path must tell the user to
        // restart Claude Code — the CLI refreshed the on-disk cache only;
        // a running session keeps the old snapshot until restarted.
        let line = line.expect("success must yield a user-facing line");
        assert!(line.contains("restart Claude Code"), "success line must say restart: {line}");
        assert!(line.contains('✓'));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn stranded_cache_refresh_noop_when_not_installed() {
        let home = tmp_home("stranded-absent");
        let fake = FakeClaudeCliRunner::new(true);
        let line = refresh_stranded_plugin_cache(&home, &fake);
        assert!(fake.invocations().is_empty(), "no stale cache to refresh when the plugin was never installed");
        assert!(line.is_none(), "nothing to say when the plugin was never installed");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn stranded_cache_refresh_failure_yields_instruction() {
        let home = tmp_home("stranded-fail-msg");
        write_installed_plugins(&home, "1.0.11");
        let fake = FakeClaudeCliRunner::new(false);
        let line = refresh_stranded_plugin_cache(&home, &fake)
            .expect("failure must yield a user-facing line");
        assert!(
            line.contains("claude plugin update mootx01@mootx01"),
            "failure line must name the exact command: {line}"
        );
        assert!(line.contains("restart Claude Code"));
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
            mcp_json["mcpServers"][clients::PLUGIN_SERVER_NAME]["type"], "http",
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

    // ---- generation-boundary shape contract -------------------------------
    //
    // The plugin entry's shape asserted directly against the embedded bundle,
    // before any install machinery runs. Rust twin of Swift's
    // `PluginPackageShapeTests`.
    //
    // Why here and not only at the install boundary: when the packager renamed
    // the plugin MCP server key (7f64973aa), three install-boundary tests went
    // red with "type is not http" — a symptom three layers downstream of the
    // actual change, describing the wrong defect (the entry was HTTP-shaped
    // all along; the key it was filed under had moved). Nothing asserted the
    // contract where the contract is produced.

    /// The map key a package's MCP manifest files the server entry under.
    /// Most hosts use `mcpServers`; VS Code / GitHub Copilot uses `servers`.
    const SERVER_MAP_KEYS: [&str; 2] = ["mcpServers", "servers"];

    /// A generated plugin entry carries its endpoint under one of these. Most
    /// hosts use `url`; Antigravity's schema names it `serverUrl`.
    const URL_KEYS: [&str; 2] = ["url", "serverUrl"];

    /// Every JSON file in `host_id`'s package that declares a server map, as
    /// (relative path, map key, the server map).
    fn server_maps(host_id: &str) -> Vec<(String, &'static str, serde_json::Map<String, serde_json::Value>)> {
        let mut found = Vec::new();
        for (rel, contents) in InstallBundle::embedded().package_files(host_id) {
            if !rel.ends_with(".json") {
                continue;
            }
            let Ok(root) = serde_json::from_str::<serde_json::Value>(&contents) else {
                continue;
            };
            for key in SERVER_MAP_KEYS {
                if let Some(servers) = root.get(key).and_then(|v| v.as_object()) {
                    found.push((rel.clone(), key, servers.clone()));
                }
            }
        }
        found
    }

    /// The contract, stated once at the boundary that produces it: every
    /// plugin-capable host's generated MCP manifest files exactly one server,
    /// under `clients::PLUGIN_SERVER_NAME`, and that entry is HTTP-shaped — it
    /// points at the resident daemon over HTTP and carries neither a `command`
    /// (the stdio proxy-bridge shape, which the transport ruling moved away
    /// from so concurrent clients share one daemon) nor an `env` (client-side
    /// env on an HTTP entry is inert — nothing reads it).
    #[test]
    fn plugin_package_entries_are_http_shaped() {
        // Length note: this runs long on purpose and does not split. The
        // contract is "every plugin-capable host, every MCP manifest it
        // ships" — so the host loop, the per-file assertions, and the
        // closing coverage count are one indivisible statement. Extracting
        // the loop body into a per-file helper would let the count-guard
        // drift away from the assertions it certifies, which is the precise
        // failure this suite exists to prevent.
        let bundle = InstallBundle::embedded();
        let mut hosts: Vec<&str> = bundle.plugin_capable_hosts().map(|h| h.id.as_str()).collect();
        hosts.sort_unstable();

        // Guard the guard: this test is worthless if the iteration silently
        // covers nothing — the exact failure mode it exists to catch.
        assert!(!hosts.is_empty(), "the embedded bundle must declare plugin-capable hosts");

        let mut checked = 0usize;
        for host_id in &hosts {
            let maps = server_maps(host_id);
            assert!(
                !maps.is_empty(),
                "{host_id} is plugin-capable but its package declares no MCP server map"
            );

            for (rel, map_key, servers) in maps {
                let at = format!("{host_id}/{rel} [{map_key}]");
                let keys: Vec<&str> = servers.keys().map(|k| k.as_str()).collect();
                assert_eq!(
                    keys,
                    vec![clients::PLUGIN_SERVER_NAME],
                    "{at}: must declare exactly the plugin server key '{}'",
                    clients::PLUGIN_SERVER_NAME
                );

                let entry = servers
                    .get(clients::PLUGIN_SERVER_NAME)
                    .and_then(|v| v.as_object())
                    .unwrap_or_else(|| panic!("{at}: no object entry under the plugin server key"));

                assert!(
                    URL_KEYS.iter().any(|k| entry.contains_key(*k)),
                    "{at}: an HTTP-shaped entry must carry a url; got {:?}",
                    entry.keys().collect::<Vec<_>>()
                );
                assert!(
                    !entry.contains_key("command"),
                    "{at}: HTTP-shaped entries must never carry a command — that is the stdio proxy-bridge shape"
                );
                assert!(
                    !entry.contains_key("env"),
                    "{at}: HTTP-shaped entries must never carry an env block — it is inert"
                );

                // Hosts whose schema takes a transport discriminator must say
                // `http`; hosts whose schema has no `type` field omit it. Any
                // other value means the entry is not HTTP-shaped at all.
                if let Some(ty) = entry.get("type") {
                    assert_eq!(ty, "http", "{at}: transport must be http");
                }

                checked += 1;
            }
        }

        assert_eq!(
            checked,
            hosts.len(),
            "expected exactly one MCP manifest per plugin-capable host"
        );
    }

    /// The constant the installer reads must be the key the packager writes.
    /// `PLUGIN_SERVER_NAME` mirrors generated data; this keeps the mirror
    /// honest. Direct tripwire for a repeat of 7f64973aa, where the generated
    /// key moved and the installer's copy did not.
    #[test]
    fn plugin_server_name_matches_generated_packages() {
        let mut emitted: Vec<String> = InstallBundle::embedded()
            .plugin_capable_hosts()
            .flat_map(|h| server_maps(&h.id))
            .flat_map(|(_, _, servers)| servers.keys().cloned().collect::<Vec<_>>())
            .collect();
        emitted.sort_unstable();
        emitted.dedup();
        assert_eq!(
            emitted,
            vec![clients::PLUGIN_SERVER_NAME.to_string()],
            "the generated packages are the authority for the plugin server key; \
             PLUGIN_SERVER_NAME is '{}' but the packages emit {emitted:?}",
            clients::PLUGIN_SERVER_NAME
        );
    }

    /// The two keys are intentionally the same: both the plugin and the direct
    /// install entry use `"mootx01"` so MOOT tools surface under a single
    /// `mcp__mootx01__*` prefix regardless of install path.
    #[test]
    fn plugin_and_direct_server_keys_are_identical() {
        assert_eq!(clients::PLUGIN_SERVER_NAME, clients::SERVER_NAME);
    }
}
