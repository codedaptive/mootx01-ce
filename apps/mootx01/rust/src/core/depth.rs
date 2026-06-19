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
pub fn apply(client_id: &str, depth: InstallDepth, home: &Path) -> std::io::Result<DepthOutcome> {
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
                install_plugin(host, home)
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
fn install_plugin(host: &InstallMapHost, home: &Path) -> std::io::Result<DepthOutcome> {
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
    // Host plugin root: parent of the skill's `skills/` dir. For
    // ~/.claude/skills/mootx01-memory/SKILL.md that is ~/.claude.
    let skill_dest = expand_tilde(&host.skill_user_path, home);
    let plugin_root = skill_dest
        .parent() // mootx01-memory/
        .and_then(|p| p.parent()) // skills/
        .and_then(|p| p.parent()) // host plugin root
        .map(Path::to_path_buf)
        .unwrap_or_else(|| home.to_path_buf());
    let dest = plugin_root.join("mootx01-plugin");
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
        std::fs::write(&file, contents)?;
    }
    Ok(DepthOutcome::Plugin(dest.display().to_string()))
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

/// Local timestamp `yyyymmdd-HHMMSS` for backup suffixes. Dependency-free
/// (the crate ships no chrono); derived from the system clock in UTC, which is
/// sufficient for a unique-per-second backup name.
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
        assert_eq!(b.host_count(), 9);
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

    #[test]
    fn server_depth_is_noop() {
        let home = tmp_home("server");
        assert_eq!(apply("claude-code", InstallDepth::Server, &home).unwrap(), DepthOutcome::Server);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn skills_depth_writes_canonical_skill() {
        let home = tmp_home("skills");
        let outcome = apply("claude-code", InstallDepth::Skills, &home).unwrap();
        let dest = home.join(".claude/skills/mootx01-memory/SKILL.md");
        assert_eq!(outcome, DepthOutcome::Skills(dest.display().to_string()));
        let written = std::fs::read_to_string(&dest).unwrap();
        assert_eq!(written, InstallBundle::embedded().skill_markdown);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn plugin_depth_installs_package() {
        let home = tmp_home("plugin");
        let outcome = apply("claude-code", InstallDepth::Plugin, &home).unwrap();
        let root = home.join(".claude/mootx01-plugin");
        assert_eq!(outcome, DepthOutcome::Plugin(root.display().to_string()));
        assert!(root.join("skills/mootx01-memory/SKILL.md").exists());
        assert!(root.join(".claude-plugin/plugin.json").exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn plugin_falls_back_to_skills_for_module_host() {
        let home = tmp_home("fallback");
        let outcome = apply("opencode", InstallDepth::Plugin, &home).unwrap();
        let dest = home.join(".config/opencode/skills/mootx01-memory/SKILL.md");
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
        assert_eq!(apply("claude-desktop", InstallDepth::Plugin, &home).unwrap(), DepthOutcome::Server);
        assert_eq!(apply("kiro", InstallDepth::Skills, &home).unwrap(), DepthOutcome::Server);
        let _ = std::fs::remove_dir_all(&home);
    }
}
