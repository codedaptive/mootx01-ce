//! core/clients.rs — the MCP client registry (spec §4.2's 11-agent table).
//!
//! Ported from Swift MootInstallerCore/ClientConfig.swift (the reference).
//! `config_path` is home-relative except where a platform demands otherwise
//! (Claude Desktop, Cline live under the platform's app-config base).
//!
//! Platform notes (spec §8 item 3 — Windows/Linux paths verified per client
//! as install lands; the dotfile CLIs document identical home-relative paths
//! on every OS):
//!   Claude Desktop — macOS `Library/Application Support/Claude/…`,
//!     Windows `%APPDATA%\Claude\…`; no Linux build.
//!   Cline — VS Code globalStorage: macOS `Library/Application Support/Code/…`,
//!     Linux `.config/Code/…`, Windows `%APPDATA%\Code\…`.

use std::path::{Path, PathBuf};

/// Join a `/`-delimited relative path onto `base` one component at a time so
/// PathBuf uses the OS-native separator on every platform.
///
/// On Windows, `base.join(".codex/config.toml")` produces the mixed result
/// `C:\Users\Bob/.codex/config.toml` because PathBuf keeps the `/` from the
/// embedded literal. Splitting on `/` and calling `.join()` per segment lets
/// PathBuf insert `\` on Windows and `/` on POSIX — consistent native output.
pub(crate) fn join_rel(base: &Path, rel: &str) -> PathBuf {
    let mut p = base.to_path_buf();
    for seg in rel.split('/') {
        if !seg.is_empty() {
            p = p.join(seg);
        }
    }
    p
}

/// Config file format — drives the merge path (§4.2: never write one format
/// into another's file) and the wired-detection check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigFormat {
    Json,
    Toml,
    Yaml,
}

#[derive(Debug, Clone)]
pub struct McpClient {
    pub id: &'static str,
    pub display_name: &'static str,
    /// Home-relative config path for this platform; None when the client
    /// does not exist on this platform (e.g. Claude Desktop on Linux).
    config_rel: Option<&'static str>,
    pub format: ConfigFormat,
    /// Client accepts a native HTTP entry pointing at the resident daemon.
    pub supports_local_http: bool,
    /// HTTP entry shape: true → {"type":"http","url":…}; false → {"url":…}.
    pub http_entry_includes_type: bool,
    /// Client requires a stdio command entry; the proxy subcommand bridges
    /// frames to the resident daemon (Claude Desktop).
    pub use_proxy_bridge: bool,
}

/// The server entry name every client config carries.
pub const SERVER_NAME: &str = "mootx01";

impl McpClient {
    /// Whether this client appears to be installed on this machine.
    /// Conservative, dependency-free probes: app bundles on macOS, config
    /// dotfiles/dirs elsewhere (the dotfile CLIs create them on first run).
    pub fn detected(&self, home: &Path) -> bool {
        match self.id {
            "claude-desktop" => {
                #[cfg(target_os = "macos")]
                {
                    Path::new("/Applications/Claude.app").exists()
                }
                #[cfg(target_os = "windows")]
                {
                    // Three shapes count as "installed":
                    //  - Win32 install marker %LOCALAPPDATA%\AnthropicClaude (the
                    //    app dir — what the original install.ps1 checked);
                    //  - MSIX/Store package %LOCALAPPDATA%\Packages\Claude_* (the
                    //    Store build, whose config lives in a virtualized Roaming);
                    //  - an existing config dir (covers a configured Win32 copy).
                    // The Win32 %APPDATA%\Claude config dir often does not exist
                    // until first launch, so the config-dir-only check missed
                    // installed-but-unconfigured copies. Wiring creates the config
                    // dir if absent (merge create_dir_all).
                    let localappdata = std::env::var("LOCALAPPDATA")
                        .ok()
                        .filter(|v| !v.trim().is_empty())
                        .map(PathBuf::from)
                        .unwrap_or_else(|| home.join("AppData").join("Local"));
                    let win32_marker = localappdata.join("AnthropicClaude").exists();
                    let msix = windows_claude_msix_package(&localappdata).is_some();
                    let config_dir_exists = self
                        .config_path(home)
                        .and_then(|p| p.parent().map(|d| d.exists()))
                        .unwrap_or(false);
                    win32_marker || msix || config_dir_exists
                }
                #[cfg(not(any(target_os = "macos", target_os = "windows")))]
                {
                    let _ = home;
                    false // no Linux build
                }
            }
            "claude-code" => home.join(".claude.json").exists() || home.join(".claude").exists(),
            "cursor" => {
                #[cfg(target_os = "macos")]
                {
                    Path::new("/Applications/Cursor.app").exists() || home.join(".cursor").exists()
                }
                #[cfg(not(target_os = "macos"))]
                {
                    home.join(".cursor").exists()
                }
            }
            "cline" => {
                // VS Code extension dir scan: ~/.vscode/extensions/saoudrizwan.claude-dev-*
                let ext = home.join(".vscode/extensions");
                std::fs::read_dir(&ext)
                    .map(|rd| {
                        rd.filter_map(|e| e.ok())
                            .filter_map(|e| e.file_name().into_string().ok())
                            .any(|n| n.starts_with("saoudrizwan.claude-dev"))
                    })
                    .unwrap_or(false)
            }
            "continue" => home.join(".continue").exists(),
            // Codex CLI and Codex Desktop share ~/.codex/config.toml, so they
            // are represented as a single entry. Detected when the shared
            // config/dir is present (all platforms) or the macOS app bundle exists.
            "codex" => {
                let config_or_dir = home.join(".codex").join("config.toml").exists()
                    || home.join(".codex").exists();
                #[cfg(target_os = "macos")]
                {
                    config_or_dir || Path::new("/Applications/Codex.app").exists()
                }
                #[cfg(not(target_os = "macos"))]
                {
                    config_or_dir
                }
            }
            "opencode" => home.join(".config/opencode").exists(),
            "hermes" => home.join(".hermes").exists(),
            "gemini-cli" => home.join(".gemini").exists(),
            "antigravity" => {
                #[cfg(target_os = "macos")]
                {
                    Path::new("/Applications/Antigravity.app").exists()
                }
                #[cfg(not(target_os = "macos"))]
                {
                    home.join(".gemini/config").exists()
                }
            }
            "kiro" => {
                #[cfg(target_os = "macos")]
                {
                    Path::new("/Applications/Kiro.app").exists() || home.join(".kiro").exists()
                }
                #[cfg(not(target_os = "macos"))]
                {
                    home.join(".kiro").exists()
                }
            }
            _ => false,
        }
    }

    /// Absolute config path for this platform, or None when the client does
    /// not exist here. On Windows, AppData-rooted clients honor a relocated
    /// `%APPDATA%`/`%LOCALAPPDATA%` rather than assuming home-relative
    /// defaults (verified live on Windows 11 ARM64). Hermes resolves
    /// `HERMES_HOME` → `%LOCALAPPDATA%\hermes` (Windows) → `~/.hermes`
    /// (POSIX), per hermes_constants._get_platform_default_hermes_home.
    pub fn config_path(&self, home: &Path) -> Option<PathBuf> {
        if self.id == "hermes" {
            if let Some(hh) = std::env::var("HERMES_HOME")
                .ok()
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty())
            {
                return Some(PathBuf::from(hh).join("config.yaml"));
            }
            #[cfg(target_os = "windows")]
            {
                let base = std::env::var("LOCALAPPDATA")
                    .ok()
                    .filter(|v| !v.trim().is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| home.join("AppData").join("Local"));
                return Some(base.join("hermes").join("config.yaml"));
            }
        }
        #[cfg(target_os = "windows")]
        {
            // Claude Desktop is MSIX-aware (Store vs Win32 config locations).
            if self.id == "claude-desktop" {
                return Some(windows_claude_desktop_config(home));
            }
            if self.id == "cline" {
                if let Some(appdata) = std::env::var("APPDATA")
                    .ok()
                    .filter(|v| !v.is_empty())
                    .map(PathBuf::from)
                {
                    // join_rel splits on '/' so each component is appended with the
                    // OS-native separator — all-backslash on Windows.
                    return Some(join_rel(
                        &appdata,
                        "Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
                    ));
                }
            }
        }
        if self.id == "opencode" {
            // opencode reads opencode.json OR opencode.jsonc; prefer the one
            // that exists (verified live: a real install with only the .jsonc
            // must not gain a second config file). Note: a .jsonc carrying
            // comments will fail our strict-JSON parse and be refused — the
            // honest outcome until a comment-preserving merge exists.
            let jsonc = home.join(".config/opencode/opencode.jsonc");
            if jsonc.exists() {
                return Some(jsonc);
            }
        }
        // Use join_rel (segment-by-segment join) so the resolved path uses the
        // OS-native separator on every platform. A bare home.join(".codex/config.toml")
        // keeps the `/` in the relative part and produces mixed separators on Windows
        // (e.g. C:\Users\Bob/.codex/config.toml); join_rel produces all-backslash there.
        self.config_rel.map(|r| join_rel(home, r))
    }

    /// JSON servers key for this client. opencode's schema
    /// (https://opencode.ai/config.json) puts servers under top-level `mcp`;
    /// every other JSON client uses `mcpServers`.
    pub fn json_servers_key(&self) -> &'static str {
        if self.id == "opencode" {
            "mcp"
        } else {
            "mcpServers"
        }
    }

    /// Whether this client's config currently carries the mootx01 entry.
    /// Format-aware: JSON looks for `<servers_key>.mootx01` (matching the
    /// Swift installer's merge key), TOML for the `[mcp_servers.mootx01]`
    /// table, YAML for file existence (Continue per-server file) or a
    /// two-space-indented `mootx01:` entry line (Hermes shared YAML).
    pub fn wired(&self, home: &Path) -> bool {
        let Some(path) = self.config_path(home) else {
            return false;
        };
        match self.format {
            ConfigFormat::Json => {
                let Ok(bytes) = std::fs::read(&path) else { return false };
                // Strip a possible leading UTF-8 BOM before parsing — a BOM'd
                // config (Windows PowerShell 5.1 writes one) would otherwise
                // read as "not wired" and trigger a redundant re-wire.
                let lossy = String::from_utf8_lossy(&bytes);
                let Ok(v) =
                    serde_json::from_str::<serde_json::Value>(crate::core::merge::strip_bom(&lossy))
                else {
                    return false;
                };
                v.get(self.json_servers_key())
                    .and_then(|s| s.get(SERVER_NAME))
                    .is_some()
            }
            ConfigFormat::Toml => {
                let Ok(text) = std::fs::read_to_string(&path) else { return false };
                let header = format!("[mcp_servers.{SERVER_NAME}]");
                text.lines().any(|l| l.trim() == header)
            }
            ConfigFormat::Yaml => {
                // Continue's per-server file (mootx01.yaml) existing means
                // wired; a shared YAML (Hermes config.yaml) must mention the
                // server name.
                if path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.starts_with(SERVER_NAME))
                    .unwrap_or(false)
                {
                    path.exists()
                } else {
                    // Shared YAML (Hermes): wired = our entry line exists
                    // under 2-space indent (a comment mentioning the name
                    // must not count).
                    std::fs::read_to_string(&path)
                        .map(|t| {
                            t.lines()
                                .any(|l| l.trim_end() == format!("  {SERVER_NAME}:"))
                        })
                        .unwrap_or(false)
                }
            }
        }
    }
}

/// The supported client registry, in picker order. Mirrors Swift
/// `MCPClients.supported`.
pub fn supported() -> Vec<McpClient> {
    use ConfigFormat::*;
    let c = |id, display_name, config_rel, format, http, typed, proxy| McpClient {
        id,
        display_name,
        config_rel,
        format,
        supports_local_http: http,
        http_entry_includes_type: typed,
        use_proxy_bridge: proxy,
    };
    vec![
        // Claude Desktop — config schema requires a stdio command entry; proxy
        // routes frames through the resident daemon.
        c("claude-desktop", "Claude Desktop", claude_desktop_rel(), Json, false, false, true),
        c("claude-code", "Claude Code", Some(".claude.json"), Json, true, true, false),
        // Cursor infers HTTP from a bare url.
        c("cursor", "Cursor", Some(".cursor/mcp.json"), Json, true, false, false),
        c("cline", "Cline", cline_rel(), Json, true, true, false),
        // Continue — per-server YAML file (type: streamable-http).
        c("continue", "Continue (VS Code / JetBrains)", Some(".continue/mcpServers/mootx01.yaml"), Yaml, true, false, false),
        // Codex CLI and Codex Desktop share ~/.codex/config.toml — one entry
        // wires both. TOML url field; no explicit type field needed.
        c("codex", "Codex (Desktop & CLI)", Some(".codex/config.toml"), Toml, true, false, false),
        // opencode — top-level "mcp" key, {type:"remote",url} entries
        // (schema-verified); config_path prefers opencode.jsonc when present.
        c("opencode", "Opencode", Some(".config/opencode/opencode.json"), Json, true, true, false),
        // Hermes — YAML url field.
        c("hermes", "Hermes", Some(".hermes/config.yaml"), Yaml, true, false, false),
        c("gemini-cli", "Gemini CLI", Some(".gemini/settings.json"), Json, true, false, false),
        // Antigravity — documented as using a non-standard "serverUrl" key;
        // the Swift reference writes a bare "url" entry today (§8 open item),
        // so the Rust port matches that behavior for conformance.
        c("antigravity", "Antigravity", Some(".gemini/config/mcp_config.json"), Json, true, false, false),
        c("kiro", "Kiro", Some(".kiro/settings/mcp.json"), Json, true, false, false),
    ]
}

#[cfg(target_os = "macos")]
fn claude_desktop_rel() -> Option<&'static str> {
    Some("Library/Application Support/Claude/claude_desktop_config.json")
}
#[cfg(target_os = "windows")]
fn claude_desktop_rel() -> Option<&'static str> {
    // %APPDATA% = <home>\AppData\Roaming
    Some("AppData/Roaming/Claude/claude_desktop_config.json")
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn claude_desktop_rel() -> Option<&'static str> {
    None // No Linux build of Claude Desktop.
}

/// Find the Claude Desktop MSIX (Microsoft Store) package directory under
/// `<localappdata>\Packages`, if the Store version is installed.
///
/// The Store build virtualizes its Roaming AppData into
/// `%LOCALAPPDATA%\Packages\Claude_<publisherHash>\LocalCache\Roaming\Claude\`,
/// so neither the Win32 install dir (`%LOCALAPPDATA%\AnthropicClaude`) nor the
/// Win32 config dir (`%APPDATA%\Claude`) exists for it. The `Claude_` prefix is
/// the MSIX package-family name; the publisher-hash suffix is stable per
/// publisher but matched by prefix so a re-publish under the same name still
/// resolves. Kept un-gated so the directory-scan logic is unit-testable on any
/// host; only the Windows call sites use it.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
fn windows_claude_msix_package(localappdata: &Path) -> Option<PathBuf> {
    std::fs::read_dir(localappdata.join("Packages"))
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.starts_with("Claude_"))
                .unwrap_or(false)
        })
}

/// Resolve the Claude Desktop `claude_desktop_config.json` path on Windows,
/// preferring the MSIX/Store package's virtualized Roaming location when that
/// package is installed, else the Win32 `%APPDATA%\Claude` location. Both
/// distributions read their config from the returned file.
#[cfg(target_os = "windows")]
fn windows_claude_desktop_config(home: &Path) -> PathBuf {
    let localappdata = std::env::var("LOCALAPPDATA")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("AppData").join("Local"));
    if let Some(pkg) = windows_claude_msix_package(&localappdata) {
        return pkg
            .join("LocalCache")
            .join("Roaming")
            .join("Claude")
            .join("claude_desktop_config.json");
    }
    let appdata = std::env::var("APPDATA")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("AppData").join("Roaming"));
    appdata.join("Claude").join("claude_desktop_config.json")
}

#[cfg(target_os = "macos")]
fn cline_rel() -> Option<&'static str> {
    Some("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
}
#[cfg(target_os = "windows")]
fn cline_rel() -> Option<&'static str> {
    Some("AppData/Roaming/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn cline_rel() -> Option<&'static str> {
    Some(".config/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_home(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-clients-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn registry_has_eleven_clients() {
        // 11 clients: the two Codex entries (CLI + Desktop) are collapsed into one
        // "codex" entry since they share ~/.codex/config.toml.
        assert_eq!(supported().len(), 11);
    }

    #[test]
    fn json_wired_detects_mcp_servers_entry() {
        let home = tmp_home("json");
        let cfg = home.join(".claude.json");
        std::fs::write(&cfg, br#"{"mcpServers":{"mootx01":{"type":"http","url":"http://127.0.0.1:4242"}}}"#).unwrap();
        let cc = supported().into_iter().find(|c| c.id == "claude-code").unwrap();
        assert!(cc.wired(&home));
        std::fs::write(&cfg, br#"{"mcpServers":{}}"#).unwrap();
        assert!(!cc.wired(&home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn toml_wired_detects_table_header() {
        let home = tmp_home("toml");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(
            home.join(".codex/config.toml"),
            "model = \"o3\"\n\n[mcp_servers.mootx01]\nurl = \"http://127.0.0.1:4242\"\n",
        )
        .unwrap();
        let cx = supported().into_iter().find(|c| c.id == "codex").unwrap();
        assert!(cx.wired(&home));
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn msix_package_finder_matches_claude_prefix() {
        // The Microsoft Store build lives at
        // %LOCALAPPDATA%\Packages\Claude_<publisherHash>\... — the finder must
        // match by the `Claude_` package-family prefix and ignore unrelated
        // packages. (Portable: exercises the dir-scan logic on any host.)
        let home = tmp_home("msix");
        let localappdata = home.join("AppData").join("Local");
        std::fs::create_dir_all(localappdata.join("Packages").join("Other_abc")).unwrap();
        assert!(
            windows_claude_msix_package(&localappdata).is_none(),
            "no Claude_* package → None"
        );
        let pkg = localappdata.join("Packages").join("Claude_pzs8sxrjxfjjc");
        std::fs::create_dir_all(&pkg).unwrap();
        assert_eq!(
            windows_claude_msix_package(&localappdata).as_deref(),
            Some(pkg.as_path()),
            "Claude_* package must be found"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    // On macOS, /Applications/Codex.app is a valid detection signal for the
    // single "codex" entry. If the app is installed on the test machine the
    // "absent home dot-file" assertions are always true (the app fires first),
    // so we skip that part and only verify the positive case.
    #[cfg(not(target_os = "macos"))]
    #[test]
    fn codex_detected_via_config_and_dir_non_macos() {
        // On non-macOS: the "codex" entry detects when ~/.codex/config.toml exists
        // OR the ~/.codex directory exists (covers CLI before config is written).
        let home = tmp_home("codex-detect");
        let cx = supported().into_iter().find(|c| c.id == "codex").unwrap();
        assert!(!cx.detected(&home), "absent .codex must not detect");
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        assert!(cx.detected(&home), "present .codex dir must detect");
        std::fs::write(home.join(".codex/config.toml"), "model = \"o3\"\n").unwrap();
        assert!(cx.detected(&home), "present .codex/config.toml must detect");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn codex_detected_when_config_toml_present() {
        // Cross-platform: the "codex" entry always detects when config.toml exists.
        let home = tmp_home("codex-detect-config");
        let cx = supported().into_iter().find(|c| c.id == "codex").unwrap();
        std::fs::create_dir_all(home.join(".codex")).unwrap();
        std::fs::write(home.join(".codex/config.toml"), "model = \"o3\"\n").unwrap();
        assert!(cx.detected(&home), "present .codex/config.toml must detect");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn yaml_wired_is_file_existence() {
        let home = tmp_home("yaml");
        let cont = supported().into_iter().find(|c| c.id == "continue").unwrap();
        assert!(!cont.wired(&home));
        std::fs::create_dir_all(home.join(".continue/mcpServers")).unwrap();
        std::fs::write(home.join(".continue/mcpServers/mootx01.yaml"), "type: streamable-http\n").unwrap();
        assert!(cont.wired(&home));
        let _ = std::fs::remove_dir_all(&home);
    }

    /// join_rel must produce no forward-slash components in any path segment it
    /// appends — on POSIX the native separator IS '/' so we test the component
    /// structure: each segment of the relative part must map to exactly one path
    /// component, ensuring platform-native rendering on Windows too. We verify
    /// this cross-platform by asserting the joined path's components match the
    /// explicit sequence of segments rather than containing an unsplit "/"-embedded
    /// segment.
    #[test]
    fn join_rel_uses_native_components() {
        use std::path::Component;
        let base = PathBuf::from("/home/user");
        let joined = join_rel(&base, ".codex/config.toml");
        let components: Vec<_> = joined
            .components()
            .filter(|c| matches!(c, Component::Normal(_)))
            .map(|c| c.as_os_str().to_string_lossy().to_string())
            .collect();
        // Each segment must appear as its own component — no component may
        // contain a '/' (which would indicate an un-split embedded slash).
        assert!(
            components.iter().all(|c| !c.contains('/')),
            "expected no embedded '/' in any path component; got: {components:?}"
        );
        assert_eq!(components, vec!["home", "user", ".codex", "config.toml"]);
    }

    #[test]
    fn codex_config_path_resolves_to_dotcodex() {
        // The single "codex" entry must resolve to ~/.codex/config.toml using
        // join_rel so Windows paths use native backslash separators.
        let home = tmp_home("codex-path");
        let cx = supported().into_iter().find(|c| c.id == "codex").unwrap();
        let resolved = cx.config_path(&home).expect("codex must have a config path");
        assert!(
            resolved.ends_with(std::path::Path::new(".codex/config.toml"))
                || resolved.ends_with(std::path::Path::new(".codex\\config.toml")),
            "codex config path must end with .codex/config.toml; got: {resolved:?}"
        );
        let _ = std::fs::remove_dir_all(&home);
    }
}
