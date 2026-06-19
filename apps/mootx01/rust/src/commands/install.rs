//! commands/install.rs — §4.2: wire mootx01 into MCP clients.
//!
//! Pipeline per selected client: backup existing config (§4.2 backups) →
//! format-dispatched merge (JSON / TOML / Continue-YAML; a shared YAML like
//! Hermes is refused rather than risk corrupting it) → permissions grant for
//! Claude Code → summary.
//!
//! Target selection: `--target ids` explicit, `--yes` all detected, else an
//! interactive numbered prompt (the arrow-key checkbox picker is §8 work;
//! the numbered prompt is the spec'd ANSI fallback and the v1 interactive
//! mode on Rust platforms).

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::cli::{InstallDepthArg, Location};
use crate::core::clients::{self, join_rel, ConfigFormat, McpClient, SERVER_NAME};
use crate::core::depth::{self, DepthOutcome, InstallDepth};
use crate::core::{merge, paths, permissions};
use crate::exit;

pub fn run(
    target: Option<Vec<String>>,
    location: Location,
    yes: bool,
    no_permissions: bool,
    no_mgr: bool,
    no_daemon: bool,
    vault_on: bool,
    depth_arg: Option<InstallDepthArg>,
) -> ExitCode {
    let home = home_dir();
    let registry = clients::supported();

    let selected = match resolve_targets(&registry, target, yes, &home) {
        Ok(s) => s,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    if selected.is_empty() {
        println!("Nothing selected.");
        return ExitCode::from(exit::OK);
    }

    // Resolve the global integration depth (§4.4). Precedence:
    //   --mode flag (honored in silent and guided modes)
    //   → --yes default (plugin, no prompt)
    //   → guided depth prompt (after the picker, before apply)
    //   → default (plugin) when non-interactive.
    let depth = match depth_arg {
        Some(InstallDepthArg::Server) => InstallDepth::Server,
        Some(InstallDepthArg::Skills) => InstallDepth::Skills,
        Some(InstallDepthArg::Plugin) => InstallDepth::Plugin,
        None if yes => InstallDepth::DEFAULT,
        None => prompt_depth(),
    };

    let binary_path = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "mootx01".to_string());
    let daemon_url = daemon_url();

    // Dedup: clients that resolve to the same config path and server name
    // share a file and must be processed once. Group them so the output
    // reports all client names together rather than wiring once and then
    // claiming "not wired" for every subsequent duplicate.
    //
    // Grouping key: (resolved_config_path, server_name) — the pair uniquely
    // identifies one file write. Clients without a config path on this
    // platform (None from config_path) are each processed individually and
    // will print their own "not available" skip message.
    let mut wired = Vec::new();
    let mut skipped = Vec::new();
    // Client ids whose MCP wiring succeeded — depth payload applies only to these.
    let mut wired_ids: Vec<&'static str> = Vec::new();

    for client in &selected {
        match install_one(client, &home, &binary_path, &daemon_url, location) {
            Ok(Some(p)) => {
                println!("  ✓ wired {} ({})", client.display_name, p.display());
                wired.push(client.display_name);
                wired_ids.push(client.id);
            }
            Ok(None) => skipped.push(client.display_name),
            Err(e) => {
                eprintln!("  ✗ {}: {e}", client.display_name);
                skipped.push(client.display_name);
            }
        }
    }

    // Integration depth (§4.4): server = MCP only (done above); skills/plugin
    // add the canonical SKILL.md / pre-generated package per client. The depth
    // is a target — each client gets the most it supports, and any plugin→skills
    // fallback is reported (the §4.4 ceiling). Applied only to clients whose MCP
    // wiring succeeded.
    if depth != InstallDepth::Server {
        println!();
        println!("Integration depth: {}", depth.as_str());
        for client in &selected {
            if !wired_ids.contains(&client.id) {
                continue;
            }
            match depth::apply(client.id, depth, &home) {
                Ok(DepthOutcome::Server) => println!(
                    "  ⓘ {}: server only (no skill/plugin payload for this client)",
                    client.display_name
                ),
                Ok(DepthOutcome::Skills(path)) => {
                    println!("  ✓ {}: skill installed → {path}", client.display_name)
                }
                Ok(DepthOutcome::Plugin(path)) => {
                    println!("  ✓ {}: plugin installed → {path}", client.display_name)
                }
                Ok(DepthOutcome::PluginFellBackToSkills(path, reason)) => println!(
                    "  ✓ {}: skill installed (plugin → skills: {reason}) → {path}",
                    client.display_name
                ),
                Err(e) => eprintln!("  ✗ {}: depth install failed: {e}", client.display_name),
            }
        }
    }

    // Permissions grant (Claude Code settings) — §4.2, AIRA-INSTALL-P3 key.
    if !no_permissions && selected.iter().any(|c| c.id == "claude-code") {
        // join_rel produces native separators on every platform (backslash on
        // Windows, forward-slash on POSIX) — home.join(".claude/settings.json")
        // would leave a mixed path on Windows.
        let settings = match location {
            Location::Global => join_rel(&home, ".claude/settings.json"),
            Location::Local => PathBuf::from(".claude").join("settings.json"),
        };
        match merge::backup_existing(&settings)
            .map_err(merge::MergeError::from)
            .and_then(|_| permissions::grant(&settings))
        {
            Ok(added) if added > 0 => {
                println!("  ✓ granted {added} tool permissions ({})", settings.display())
            }
            Ok(_) => println!("  ✓ tool permissions already granted"),
            Err(e) => eprintln!("  ✗ permissions: {e}"),
        }
    }

    // Service registration (§6). Linux: systemd user units. Windows: Task
    // Scheduler lands next. macOS: Swift/launchd territory — the Rust binary
    // is a dev build there.
    #[cfg(target_os = "linux")]
    {
        use crate::core::service;
        let data_override = std::env::var("MOOTX01_DATA_DIR").ok().filter(|v| !v.is_empty());
        if !no_daemon {
            // vault_on baked into the unit's Environment= block so the resident
            // daemon reads MOOTX01_VAULT without it being set in the shell (ADR-015).
            let unit = service::daemon_unit(&binary_path, data_override.as_deref(), vault_on);
            report_registration("daemon", service::register(&home, service::DAEMON_UNIT, &unit));
        }
        if !no_mgr {
            let mgr_binary = std::path::Path::new(&binary_path)
                .parent()
                .map(|d| d.join("moot-mgr"))
                .filter(|p| p.exists());
            match mgr_binary {
                Some(mgr) => {
                    let token = service::random_token();
                    let unit = service::mgr_unit(
                        &mgr.display().to_string(),
                        &token,
                        data_override.as_deref(),
                    );
                    report_registration("moot-mgr", service::register(&home, service::MGR_UNIT, &unit));
                }
                None => println!(
                    "  skipping moot-mgr service (no moot-mgr binary beside mootx01)"
                ),
            }
        }
    }
    #[cfg(target_os = "windows")]
    {
        use crate::core::service;
        let data_override = std::env::var("MOOTX01_DATA_DIR").ok().filter(|v| !v.is_empty());
        if !no_daemon {
            // vault_on baked into the cmd wrapper as `set MOOTX01_VAULT=...&&`
            // so the resident daemon reads MOOTX01_VAULT at launch (ADR-015).
            let (exe, arg) = service::daemon_task_command(&binary_path, data_override.as_deref(), vault_on);
            report_registration("daemon", service::register_task(service::DAEMON_TASK, &exe, &arg));
        }
        if !no_mgr {
            let mgr_binary = std::path::Path::new(&binary_path)
                .parent()
                .map(|d| d.join("moot-mgr.exe"))
                .filter(|p| p.exists());
            match mgr_binary {
                Some(mgr) => {
                    let token = service::random_token();
                    let (exe, arg) = service::mgr_task_command(
                        &mgr.display().to_string(),
                        &token,
                        data_override.as_deref(),
                    );
                    report_registration("moot-mgr", service::register_task(service::MGR_TASK, &exe, &arg));
                }
                None => println!(
                    "  skipping moot-mgr service (no moot-mgr binary beside mootx01)"
                ),
            }
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    if !no_daemon || !no_mgr {
        println!(
            "  (service registration pending on this platform — run \
             `mootx01 serve --http auto` to start the daemon manually)"
        );
    }

    if !skipped.is_empty() {
        println!("Skipped: {}.", skipped.join(", "));
    }
    if !wired.is_empty() {
        println!("Done. Restart your clients to pick up the new server.");
    }

    // ADR-015 §1 mandatory disclosure: inform the user of the vault surface
    // state so they can make an informed security choice. Always printed.
    println!();
    if vault_on {
        println!("Vault (import/export to disk) is ON by default.");
        println!("  For a more secure position: mootx01 install --vault-off  # disables import/export");
    } else {
        println!("Vault (import/export to disk) is OFF.");
        println!("  To re-enable: mootx01 install --vault-on");
    }

    ExitCode::from(exit::OK)
}

/// Wire one client. Ok(Some(path)) = wired at path; Ok(None) = skipped with
/// its own message already printed.
fn install_one(
    client: &McpClient,
    home: &Path,
    binary_path: &str,
    daemon_url: &str,
    location: Location,
) -> Result<Option<PathBuf>, merge::MergeError> {
    let Some(mut config) = client.config_path(home) else {
        println!(
            "  skipping {} (not available on this platform)",
            client.display_name
        );
        return Ok(None);
    };
    // §4.2 --location local: project-scoped .mcp.json for Claude Code.
    if location == Location::Local && client.id == "claude-code" {
        config = PathBuf::from(".mcp.json");
    }

    match client.format {
        ConfigFormat::Json => {
            merge::backup_existing(&config)?;
            let entry = merge::entry_for(client, binary_path, daemon_url);
            merge::merge_into_json_config(&config, client.json_servers_key(), SERVER_NAME, entry)?;
            Ok(Some(config))
        }
        ConfigFormat::Toml => {
            merge::backup_existing(&config)?;
            merge::merge_into_toml_config(&config, client, SERVER_NAME, binary_path, daemon_url)?;
            Ok(Some(config))
        }
        ConfigFormat::Yaml => {
            if client.id == "continue" {
                merge::backup_existing(&config)?;
                merge::write_continue_yaml(&config, binary_path, Some(daemon_url))?;
                Ok(Some(config))
            } else {
                // Hermes' shared config.yaml: line-based block merge under
                // `mcp_servers:` (schema verified against the real
                // hermes-agent example).
                merge::backup_existing(&config)?;
                merge::merge_into_hermes_yaml(&config, SERVER_NAME, daemon_url)?;
                Ok(Some(config))
            }
        }
    }
}

/// §3: clients are pointed at the resident daemon; resolve its URL from the
/// port file, falling back to the default 4242.
fn daemon_url() -> String {
    let port = paths::read_port_file(&paths::daemon_port_file(&paths::data_dir())).unwrap_or(4242);
    format!("http://127.0.0.1:{port}")
}

pub(crate) fn resolve_targets(
    registry: &[McpClient],
    target: Option<Vec<String>>,
    yes: bool,
    home: &Path,
) -> Result<Vec<McpClient>, String> {
    if let Some(ids) = target {
        let mut out = Vec::new();
        for id in &ids {
            match registry.iter().find(|c| c.id == id) {
                Some(c) => out.push(c.clone()),
                None => {
                    let known: Vec<&str> = registry.iter().map(|c| c.id).collect();
                    return Err(format!(
                        "Unknown client id '{id}'. Known ids: {}.",
                        known.join(", ")
                    ));
                }
            }
        }
        return Ok(out);
    }
    if yes {
        return Ok(registry.iter().filter(|c| c.detected(home)).cloned().collect());
    }
    Ok(prompt_select(registry, home))
}

/// Guided depth prompt (§4.4). Shown only when `--mode` was not supplied AND
/// not `--yes` (the caller enforces that). Placed AFTER the client picker and
/// BEFORE apply. Default = Full Plugin (option 3); an empty line, a
/// non-recognised entry, or a closed stdin returns the default.
fn prompt_depth() -> InstallDepth {
    println!();
    println!("Integration depth?");
    println!("  1) Server only      — MCP tools (moot_*)");
    println!("  2) Server + Skills  — tools + mootx01-memory skill (auto-loads)");
    println!("  3) Full Plugin      — native plugin per tool                 [default]");
    print!("Choice [3]: ");
    let _ = io::stdout().flush();
    let mut line = String::new();
    if io::stdin().lock().read_line(&mut line).is_err() {
        return InstallDepth::DEFAULT;
    }
    match line.trim() {
        "1" => InstallDepth::Server,
        "2" => InstallDepth::Skills,
        "3" => InstallDepth::Plugin,
        _ => InstallDepth::DEFAULT,
    }
}

/// Numbered-prompt selection (the spec'd fallback interactive mode).
/// Detected clients start selected; numbers toggle; 'a' selects all; empty
/// line confirms.
fn prompt_select(registry: &[McpClient], home: &Path) -> Vec<McpClient> {
    let mut selected: Vec<bool> = registry.iter().map(|c| c.detected(home)).collect();
    let stdin = io::stdin();
    loop {
        println!("Select agents to configure (numbers toggle, 'a' all, enter confirms):");
        for (i, c) in registry.iter().enumerate() {
            let mark = if selected[i] { "x" } else { " " };
            let det = if c.detected(home) { " (detected)" } else { "" };
            println!("  {:2}. [{mark}] {}{det}", i + 1, c.display_name);
        }
        print!("> ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).is_err() {
            return Vec::new();
        }
        let line = line.trim();
        if line.is_empty() {
            return registry
                .iter()
                .zip(&selected)
                .filter(|(_, s)| **s)
                .map(|(c, _)| c.clone())
                .collect();
        }
        if line.eq_ignore_ascii_case("a") {
            selected.iter_mut().for_each(|s| *s = true);
            continue;
        }
        for tok in line.split(|ch: char| ch == ',' || ch.is_whitespace()) {
            if let Ok(n) = tok.parse::<usize>() {
                if (1..=registry.len()).contains(&n) {
                    selected[n - 1] = !selected[n - 1];
                }
            }
        }
    }
}

#[cfg(any(target_os = "linux", target_os = "windows"))]
fn report_registration(label: &str, outcome: crate::core::service::RegisterOutcome) {
    use crate::core::service::RegisterOutcome::*;
    match outcome {
        Registered(path) => println!("  ✓ {label} service registered ({})", path.display()),
        ManualInstructions(text) => println!("  {text}"),
        SkippedNoBinary(msg) => println!("  skipping {label} service ({msg})"),
        Failed(msg) => eprintln!("  ✗ {label} service: {msg}"),
    }
}

pub(crate) fn home_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        std::env::var("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_targets_validate_ids() {
        let reg = clients::supported();
        let home = std::env::temp_dir();
        let ok = resolve_targets(&reg, Some(vec!["claude-code".into(), "cursor".into()]), false, &home)
            .unwrap();
        assert_eq!(ok.len(), 2);
        let err =
            resolve_targets(&reg, Some(vec!["frobnicator".into()]), false, &home).unwrap_err();
        assert!(err.contains("Unknown client id 'frobnicator'"));
    }

    /// The single "codex" entry wires ~/.codex/config.toml once and is idempotent —
    /// a second install on an already-wired config replaces the block in place
    /// rather than appending a duplicate.
    #[test]
    fn codex_install_is_idempotent() {
        let home = std::env::temp_dir()
            .join(format!("mootx01-codex-idem-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();

        let reg = clients::supported();
        let codex = reg.iter().find(|c| c.id == "codex").unwrap().clone();

        install_one(&codex, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .expect("first install must succeed");
        install_one(&codex, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .expect("second install must be idempotent");

        let config_path = codex.config_path(&home).unwrap();
        let text = std::fs::read_to_string(&config_path).unwrap();
        let count = text
            .lines()
            .filter(|l| l.trim() == "[mcp_servers.mootx01]")
            .count();
        assert_eq!(
            count, 1,
            "idempotent install must leave exactly one [mcp_servers.mootx01] table; got {count}"
        );

        let _ = std::fs::remove_dir_all(&home);
    }
}
