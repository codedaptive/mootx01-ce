//! commands/uninstall.rs — §4.3: remove mootx01 from MCP clients.
//!
//! Reverse of install: backup each config before touching it (§4.2 backups
//! apply to uninstall too), remove the entry per format, revoke Claude Code
//! permissions, and with `--purge` delete the estate databases. Default
//! never touches user data.

use std::io::{self, BufRead, Write};
use std::path::Path;
use std::process::ExitCode;

use crate::core::clients::{self, join_rel, ConfigFormat, McpClient, SERVER_NAME};
use crate::core::{merge, paths, permissions};
use crate::exit;

pub fn run(target: Option<Vec<String>>, yes: bool, purge: bool) -> ExitCode {
    let home = super::install::home_dir();
    let registry = clients::supported();

    let explicit_target_given = target.as_ref().map(|_| ());
    // Targets: explicit ids, else every client currently wired.
    let selected: Vec<McpClient> = match target {
        Some(ids) => {
            match super::install::resolve_targets(&registry, Some(ids), false, &home) {
                Ok(s) => s,
                Err(msg) => {
                    eprintln!("{msg}");
                    return ExitCode::from(exit::FAILURE);
                }
            }
        }
        None => registry.iter().filter(|c| c.wired(&home)).cloned().collect(),
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
        match remove_one(client, &home) {
            Ok(true) => println!("  ✓ removed from {} ({})",
                client.display_name,
                client.config_path(&home).map(|p| p.display().to_string()).unwrap_or_default()
            ),
            Ok(false) => println!("  - {} was not wired", client.display_name),
            Err(e) => eprintln!("  ✗ {}: {e}", client.display_name),
        }
    }

    // Revoke Claude Code permissions when it was in scope.
    if selected.iter().any(|c| c.id == "claude-code") {
        // join_rel produces native separators on every platform — backslash on
        // Windows, forward-slash on POSIX.
        let settings = join_rel(&home, ".claude/settings.json");
        match merge::backup_existing(&settings)
            .map_err(merge::MergeError::from)
            .and_then(|_| permissions::revoke(&settings))
        {
            Ok(n) if n > 0 => println!("  ✓ revoked {n} tool permissions"),
            Ok(_) => {}
            Err(e) => eprintln!("  ✗ permissions: {e}"),
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
        }
    }

    if purge {
        return purge_data(yes);
    }
    ExitCode::from(exit::OK)
}

fn remove_one(client: &McpClient, home: &Path) -> Result<bool, merge::MergeError> {
    let Some(config) = client.config_path(home) else {
        return Ok(false);
    };
    match client.format {
        ConfigFormat::Json => {
            if !config.exists() {
                return Ok(false);
            }
            merge::backup_existing(&config)?;
            merge::remove_from_json_config(&config, client.json_servers_key(), SERVER_NAME)
        }
        ConfigFormat::Toml => {
            if !config.exists() {
                return Ok(false);
            }
            merge::backup_existing(&config)?;
            merge::remove_from_toml_config(&config, SERVER_NAME)
        }
        ConfigFormat::Yaml => {
            if client.id == "continue" {
                // Per-server file: backing up preserves it, then delete.
                if !config.exists() {
                    return Ok(false);
                }
                merge::backup_existing(&config)?;
                std::fs::remove_file(&config)?;
                Ok(true)
            } else {
                // Hermes' shared config.yaml: remove our block only.
                if !config.exists() {
                    return Ok(false);
                }
                merge::backup_existing(&config)?;
                merge::remove_from_hermes_yaml(&config, SERVER_NAME)
            }
        }
    }
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
            remove_one(&codex, &home).unwrap(),
            true,
            "first remove must find and remove the entry"
        );
        // Second removal on the now-empty file: Ok(false) — already gone.
        assert_eq!(
            remove_one(&codex, &home).unwrap(),
            false,
            "second remove on already-cleaned file must return false"
        );

        let _ = std::fs::remove_dir_all(&home);
    }
}
