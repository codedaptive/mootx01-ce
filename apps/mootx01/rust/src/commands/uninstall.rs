//! commands/uninstall.rs — §4.3: remove mootx01 from MCP clients.
//!
//! Reverse of install: backup each config before touching it (§4.2 backups
//! apply to uninstall too), remove the entry per format, revoke Claude Code
//! permissions, and with `--purge` delete the estate databases. Default
//! never touches user data.

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::cli::Location;
use crate::core::clients::{self, join_rel, ConfigFormat, McpClient, SERVER_NAME};
use crate::core::{merge, paths, permissions};
use crate::exit;

pub fn run(
    target: Option<Vec<String>>,
    location: Option<Location>,
    yes: bool,
    purge: bool,
) -> ExitCode {
    let home = super::install::home_dir();
    let registry = clients::supported();

    let explicit_target_given = target.as_ref().map(|_| ());
    // Targets: explicit ids, else every client currently wired.
    let selected: Vec<McpClient> = match target {
        Some(ids) => match super::install::resolve_targets(&registry, Some(ids), false, &home) {
            Ok(s) => s,
            Err(msg) => {
                eprintln!("{msg}");
                return ExitCode::from(exit::FAILURE);
            }
        },
        None => registry
            .iter()
            .filter(|c| {
                (location_allows_global(location) && c.wired(&home))
                    || (c.id == "claude-code"
                        && location_allows_local(location)
                        && local_claude_code_wired())
            })
            .cloned()
            .collect(),
    };

    if selected.is_empty() && !purge {
        println!("Nothing to uninstall — no wired clients found.");
        return ExitCode::from(exit::OK);
    }

    if !yes && !selected.is_empty() {
        let names: Vec<&str> = selected.iter().map(|c| c.display_name).collect();
        println!("Remove mootx01 from: {}?", names.join(", "));
        print!("Type 'yes' to confirm: ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        if line.trim() != "yes" {
            println!("Aborted.");
            return ExitCode::from(exit::FAILURE);
        }
    }

    for client in &selected {
        match remove_one(client, &home, location) {
            Ok(true) => println!(
                "  ✓ removed from {} ({})",
                client.display_name,
                removed_paths(client, &home, location).join(", ")
            ),
            Ok(false) => println!("  - {} was not wired", client.display_name),
            Err(e) => eprintln!("  ✗ {}: {e}", client.display_name),
        }
    }

    // Revoke Claude Code permissions when it was in scope.
    if selected.iter().any(|c| c.id == "claude-code") {
        for settings in claude_settings_paths(&home, location) {
            match merge::backup_existing(&settings)
                .map_err(merge::MergeError::from)
                .and_then(|_| permissions::revoke(&settings))
            {
                Ok(n) if n > 0 => {
                    println!("  ✓ revoked {n} tool permissions ({})", settings.display())
                }
                Ok(_) => {}
                Err(e) => eprintln!("  ✗ permissions {}: {e}", settings.display()),
            }
        }
    }

    // Service unregistration (§6): full-teardown phase, ONLY on a full
    // uninstall (no --target). A targeted uninstall scopes to the named
    // clients' wirings; the resident daemon may still be serving other
    // wired clients. (Same scoping bug existed in the Swift vertical and
    // tore down a live installation during a two-client uninstall.)
    #[allow(unused_variables)]
    let full_uninstall = explicit_target_given.is_none();
    #[cfg(target_os = "linux")]
    {
        if full_uninstall {
            use crate::core::service;
            for unit in [service::DAEMON_UNIT, service::MGR_UNIT] {
                match service::unregister(&home, unit) {
                    Ok(true) => println!("  ✓ {unit} unregistered"),
                    Ok(false) => {}
                    Err(e) => eprintln!("  ✗ {unit}: {e}"),
                }
            }
        }
    }
    #[cfg(target_os = "windows")]
    {
        if full_uninstall {
            use crate::core::service;
            for task in [service::DAEMON_TASK, service::MGR_TASK] {
                match service::unregister_task(task) {
                    Ok(true) => println!("  ✓ task {task} unregistered"),
                    Ok(false) => {}
                    Err(e) => eprintln!("  ✗ task {task}: {e}"),
                }
            }
            // Force-kill any daemon/console the task-stop missed (detached or
            // manually-started), so the binaries are unlocked for a reinstall and
            // nothing is left orphaned. Excludes this uninstall process itself.
            service::stop_processes();
        }
    }

    if purge {
        return purge_data(yes);
    }
    ExitCode::from(exit::OK)
}

fn remove_one(
    client: &McpClient,
    home: &Path,
    location: Option<Location>,
) -> Result<bool, merge::MergeError> {
    let mut removed = false;
    for config in config_paths(client, home, location) {
        removed |= remove_from_config(client, &config)?;
    }
    Ok(removed)
}

fn remove_from_config(client: &McpClient, config: &Path) -> Result<bool, merge::MergeError> {
    match client.format {
        ConfigFormat::Json => {
            if !config.exists() {
                return Ok(false);
            }
            // ADR-024 §4: ownership-aware — a Foreign entry (env override,
            // e.g. a development rig) is reported and left untouched rather
            // than silently removed.
            match merge::remove_from_json_config_owned(config, client.json_servers_key(), SERVER_NAME)? {
                merge::JsonOwnershipOutcome::NotPresent => Ok(false),
                merge::JsonOwnershipOutcome::Removed => Ok(true),
                merge::JsonOwnershipOutcome::RetainedForeign { reason, path } => {
                    println!(
                        "  ⚠ {}: a non-default mootx01 entry at {} ({reason}) was left untouched — remove it by hand if intended",
                        client.display_name,
                        path.display()
                    );
                    Ok(false)
                }
            }
        }
        ConfigFormat::Toml => {
            if !config.exists() {
                return Ok(false);
            }
            merge::backup_existing(config)?;
            merge::remove_from_toml_config(config, SERVER_NAME)
        }
        ConfigFormat::Yaml => {
            if client.id == "continue" {
                // Per-server file: backing up preserves it, then delete.
                if !config.exists() {
                    return Ok(false);
                }
                merge::backup_existing(config)?;
                std::fs::remove_file(config)?;
                Ok(true)
            } else {
                // Hermes' shared config.yaml: remove our block only.
                if !config.exists() {
                    return Ok(false);
                }
                merge::backup_existing(config)?;
                merge::remove_from_hermes_yaml(config, SERVER_NAME)
            }
        }
    }
}

fn config_paths(client: &McpClient, home: &Path, location: Option<Location>) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if location_allows_global(location) {
        if let Some(config) = client.config_path(home) {
            paths.push(config);
        }
    }
    if client.id == "claude-code" && location_allows_local(location) {
        paths.push(PathBuf::from(".mcp.json"));
    }
    paths
}

fn removed_paths(client: &McpClient, home: &Path, location: Option<Location>) -> Vec<String> {
    config_paths(client, home, location)
        .into_iter()
        .map(|p| p.display().to_string())
        .collect()
}

fn claude_settings_paths(home: &Path, location: Option<Location>) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if location_allows_global(location) {
        // join_rel produces native separators on every platform — backslash on
        // Windows, forward-slash on POSIX.
        paths.push(join_rel(home, ".claude/settings.json"));
    }
    if location_allows_local(location) {
        paths.push(PathBuf::from(".claude").join("settings.json"));
    }
    paths
}

fn local_claude_code_wired() -> bool {
    let path = Path::new(".mcp.json");
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    let lossy = String::from_utf8_lossy(&bytes);
    let Ok(v) = serde_json::from_str::<serde_json::Value>(merge::strip_bom(&lossy)) else {
        return false;
    };
    v.get("mcpServers")
        .and_then(|s| s.get(SERVER_NAME))
        .is_some()
}

fn location_allows_global(location: Option<Location>) -> bool {
    !matches!(location, Some(Location::Local))
}

fn location_allows_local(location: Option<Location>) -> bool {
    !matches!(location, Some(Location::Global))
}

/// `--purge`: delete the estate databases and config.json. Irreversible.
fn purge_data(yes: bool) -> ExitCode {
    let data = paths::data_dir();
    if !yes {
        println!(
            "Delete ALL estate databases under {}? This is irreversible.",
            data.display()
        );
        print!("Type 'yes' to confirm: ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        if line.trim() != "yes" {
            println!("Aborted.");
            return ExitCode::from(exit::FAILURE);
        }
    }
    let databases = data.join("databases");
    if databases.exists() {
        if let Err(e) = std::fs::remove_dir_all(&databases) {
            eprintln!("Cannot delete {}: {e}", databases.display());
            return ExitCode::from(exit::FAILURE);
        }
    }
    let _ = std::fs::remove_file(paths::config_json_path(&data));
    println!("Estate databases deleted.");
    ExitCode::from(exit::OK)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::clients;
    use crate::core::merge;

    /// The single "codex" entry: remove_one returns true when the table
    /// is present and false when already gone (idempotent / safe second call).
    #[test]
    fn codex_remove_one_round_trip() {
        let home = std::env::temp_dir()
            .join(format!("mootx01-codex-remove-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();

        let reg = clients::supported();
        let codex = reg.iter().find(|c| c.id == "codex").unwrap().clone();

        let config_path = codex.config_path(&home).unwrap();
        std::fs::create_dir_all(config_path.parent().unwrap()).unwrap();
        merge::merge_into_toml_config(
            &config_path,
            &codex,
            SERVER_NAME,
            "/usr/local/bin/mootx01",
            "http://127.0.0.1:4242",
        )
        .unwrap();

        // First removal: entry is present → Ok(true).
        assert_eq!(
            remove_one(&codex, &home, None).unwrap(),
            true,
            "first remove must find and remove the entry"
        );
        // Second removal on the now-empty file: Ok(false) — already gone.
        assert_eq!(
            remove_one(&codex, &home, None).unwrap(),
            false,
            "second remove on already-cleaned file must return false"
        );

        let _ = std::fs::remove_dir_all(&home);
    }

    // ADR-024 §4: uninstall must not silently remove a non-default (dev-rig)
    // entry — it is reported and left untouched. An ours-default entry is
    // still removed as before (regression guard).

    #[test]
    fn uninstall_retains_non_default_entry_and_reports_it() {
        let home = std::env::temp_dir()
            .join(format!("mootx01-uninstall-nondefault-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();

        let reg = clients::supported();
        let claude = reg.iter().find(|c| c.id == "claude-code").unwrap().clone();
        let config = claude.config_path(&home).unwrap();
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        let dev_rig = serde_json::json!({
            "mcpServers": {
                "mootx01": {
                    "command": "/Users/dev/build/mootx01",
                    "args": ["proxy"],
                    "env": {"ARIA_MCP_SQLITE_PATH": "/Users/dev/rig-a/estate.sqlite"},
                }
            }
        });
        std::fs::write(&config, dev_rig.to_string()).unwrap();

        // remove_one aggregates to false (nothing "removed") but must not
        // touch the file's content.
        assert_eq!(remove_one(&claude, &home, None).unwrap(), false);
        let bytes = std::fs::read(&config).unwrap();
        let root: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            root["mcpServers"]["mootx01"]["env"]["ARIA_MCP_SQLITE_PATH"],
            "/Users/dev/rig-a/estate.sqlite",
            "non-default entry must survive uninstall untouched"
        );

        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn uninstall_removes_ours_default_entry_as_before() {
        let home = std::env::temp_dir()
            .join(format!("mootx01-uninstall-oursdefault-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();

        let reg = clients::supported();
        let claude = reg.iter().find(|c| c.id == "claude-code").unwrap().clone();
        let config = claude.config_path(&home).unwrap();
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        merge::merge_into_json_config(
            &config,
            claude.json_servers_key(),
            SERVER_NAME,
            merge::entry_for(&claude, "/usr/local/bin/mootx01", "http://127.0.0.1:4242"),
        )
        .unwrap();

        assert_eq!(remove_one(&claude, &home, None).unwrap(), true);
        let bytes = std::fs::read(&config).unwrap();
        let root: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert!(root.get("mcpServers").and_then(|s| s.get(SERVER_NAME)).is_none());

        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn claude_code_location_paths_cover_local_project_files() {
        let home =
            std::env::temp_dir().join(format!("mootx01-claude-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();

        let reg = clients::supported();
        let claude = reg.iter().find(|c| c.id == "claude-code").unwrap().clone();

        assert_eq!(
            config_paths(&claude, &home, Some(Location::Local)),
            vec![PathBuf::from(".mcp.json")]
        );
        assert_eq!(
            claude_settings_paths(&home, Some(Location::Local)),
            vec![PathBuf::from(".claude").join("settings.json")]
        );

        let both = config_paths(&claude, &home, None);
        assert!(both.contains(&home.join(".claude.json")));
        assert!(both.contains(&PathBuf::from(".mcp.json")));

        let _ = std::fs::remove_dir_all(&home);
    }
}
