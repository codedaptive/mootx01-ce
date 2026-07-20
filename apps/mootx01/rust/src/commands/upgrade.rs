//! commands/upgrade.rs — §4.8: upgrade to the latest release or a local build.
//!
//!   --from <path>   install a specific binary, no network
//!   --check         print the latest available version, exit
//!   --yes           skip the download confirmation
//!   --no-restart    place the binary but skip restarting services
//!
//! Online path: GitHub latest tag → semver compare → download + SHA-256
//! verify → atomic place. Network failure reports clearly; there is no
//! local-build fallback on the Rust platforms (dev builds use --from).
//! Service restart is wired for Linux (systemd) and Windows (Task Scheduler).
//! Other platforms print a manual restart note.

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use crate::core::clients::join_rel;
use crate::core::depth::{self, InstallDepth, ProcessClaudeCliRunner};
use crate::core::{permissions, release};
use crate::exit;
use crate::CURRENT_VERSION;

pub fn run(from: Option<String>, check: bool, yes: bool, no_restart: bool) -> ExitCode {
    let home = super::install::home_dir();

    // Local-build path: --from skips the online check entirely.
    if let Some(path) = from {
        let src = PathBuf::from(&path);
        if !src.exists() {
            eprintln!("mootx01 upgrade: no binary at {path}");
            return ExitCode::from(exit::FAILURE);
        }
        return place_and_report(&src, &home, no_restart);
    }

    // Online: resolve the latest version.
    let latest = match release::latest_version() {
        Ok(v) => v,
        Err(e) => {
            eprintln!(
                "mootx01 upgrade: cannot reach the release feed ({e}). \
                 For a local build use `mootx01 upgrade --from <path>`."
            );
            return ExitCode::from(exit::FAILURE);
        }
    };

    if check {
        println!("Latest available: v{latest} (installed: v{CURRENT_VERSION})");
        return ExitCode::from(exit::OK);
    }

    match release::is_newer(&latest, CURRENT_VERSION) {
        Some(true) => {}
        Some(false) => {
            println!("Already up to date (v{CURRENT_VERSION}).");
            return ExitCode::from(exit::OK);
        }
        None => {
            eprintln!(
                "mootx01 upgrade: cannot compare versions ('{latest}' vs '{CURRENT_VERSION}')."
            );
            return ExitCode::from(exit::FAILURE);
        }
    }

    println!("New version available: v{CURRENT_VERSION} → v{latest}");
    if !yes {
        print!("Download and install v{latest}? Type 'yes' to confirm: ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        if line.trim() != "yes" {
            println!("Aborted.");
            return ExitCode::from(exit::FAILURE);
        }
    }

    let (binary, tmp) = match release::download_and_verify(&latest) {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("mootx01 upgrade: {e}");
            return ExitCode::from(exit::FAILURE);
        }
    };
    let code = place_and_report(&binary, &home, no_restart);
    let _ = std::fs::remove_dir_all(&tmp);
    if code == ExitCode::from(exit::OK) {
        println!("Upgraded to v{latest}. Run `mootx01 status` to confirm.");
    }
    code
}

fn place_and_report(src: &std::path::Path, home: &std::path::Path, no_restart: bool) -> ExitCode {
    match release::place_binary(src, home) {
        Ok(installed) => {
            println!("Installed: {}", installed.display());
            // an upgrade alone never touches
            // ~/.claude/mootx01-plugin or Claude Code's plugin cache —
            // without this, a machine upgraded via `mootx01 upgrade` keeps a
            // stranded plugin package (and Claude Code keeps a stranded
            // cached snapshot) indefinitely. Independent of --no-restart:
            // this is a filesystem/cache convergence step, not a service
            // restart.
            rematerialize_plugin_depth(home);

            // Bob's re-tier ruling (2026-07-04): converge an EXISTING
            // Claude Code integration's tool-permission tiering onto the
            // current default the same way rematerialize_plugin_depth
            // converges the plugin package above — never CREATES
            // ~/.claude/settings.json or a mootx01 integration for a user
            // who never selected Claude Code as an install target (gated
            // on has_any_moot_entries).
            migrate_permission_tiers(home);

            if !no_restart {
                restart_services();
            }
            ExitCode::from(exit::OK)
        }
        Err(e) => {
            eprintln!("mootx01 upgrade: cannot place binary: {e}");
            ExitCode::from(exit::FAILURE)
        }
    }
}

/// Rematerialize plugin-depth packages for every host that already has one
/// on disk (never CREATES a new plugin-depth install for a host that never
/// had one — upgrade only converges existing installs), and — for Claude
/// Code — refresh its plugin cache the same way `mootx01 install` does (see
/// `depth::install_plugin`'s stranded-cache refresh).
///
/// `vault_off: false` is safe regardless of the original install's vault
/// posture: every plugin-capable host's package is HTTP-shaped today, so
/// `vault_off` has no effect on rematerialization. The vault posture that
/// matters lives in the resident daemon's own
/// service-manager environment, which `mootx01 upgrade` does not touch (it
/// restarts the daemon from its EXISTING unit/task, never rewriting it).
fn rematerialize_plugin_depth(home: &std::path::Path) {
    let bundle = depth::InstallBundle::embedded();
    for host in bundle.plugin_capable_hosts() {
        let dir = depth::plugin_install_directory(host, home);
        if !dir.exists() {
            continue;
        }
        match depth::apply(&host.id, InstallDepth::Plugin, home, false, &ProcessClaudeCliRunner) {
            Ok(_) => println!("  ✓ {}: plugin package rematerialized", host.display_name),
            Err(e) => println!(
                "  ✗ {}: could not rematerialize plugin package: {e}",
                host.display_name
            ),
        }
    }
}

/// See the call site's doc comment. Only touches `~/.claude/settings.json`
/// when it already carries at least one of our permission entries
/// (`permissions::has_any_moot_entries`) — an upgrade never creates a
/// Claude Code integration that was never installed. When gated in, runs
/// the same two-pass composition `mootx01 install` runs: `migrate_tiers`
/// re-tiers anything already present but stale, then `grant_tiered` adds
/// anything still missing (e.g. a tool added to the surface since the last
/// install/upgrade, such as moot_memory_get).
fn migrate_permission_tiers(home: &std::path::Path) {
    let settings = join_rel(home, ".claude/settings.json");
    if !permissions::has_any_moot_entries(&settings) {
        return;
    }
    match permissions::migrate_tiers(&settings) {
        Ok(moved) if moved > 0 => {
            println!("  ✓ Re-tiered {moved} existing ARIA tool permission(s) to the current default")
        }
        Ok(_) => {}
        Err(e) => println!("  ✗ could not migrate Claude Code tool permissions: {e}"),
    }
    match permissions::grant_tiered(&settings) {
        Ok((a, k, d)) if a + k + d > 0 => {
            println!("  ✓ Added {} new ARIA tool permission(s)", a + k + d)
        }
        Ok(_) => {}
        Err(e) => println!("  ✗ could not add new Claude Code tool permissions: {e}"),
    }
}

/// Restart the registered services after placing a new binary. Linux:
/// systemd restart of both units (mgr best-effort). Windows: Task Scheduler
/// restart of both tasks (mgr best-effort). Other platforms: manual note.
fn restart_services() {
    #[cfg(target_os = "linux")]
    {
        use crate::core::service;
        match service::restart(service::DAEMON_UNIT) {
            Ok(()) => println!("  ✓ restarted {}", service::DAEMON_UNIT),
            Err(e) => println!(
                "  ({} not restarted: {e} — if the daemon is not registered as a \
                 service, restart it manually: stop it, then `mootx01 serve --http auto`)",
                service::DAEMON_UNIT
            ),
        }
        // mgr restart is best-effort: absent unit is normal (--no-mgr installs).
        if service::restart(service::MGR_UNIT).is_ok() {
            println!("  ✓ restarted {}", service::MGR_UNIT);
        }
    }
    #[cfg(target_os = "windows")]
    {
        use crate::core::service;
        match service::restart_task(service::DAEMON_TASK) {
            Ok(()) => println!("  ✓ restarted task {}", service::DAEMON_TASK),
            Err(e) => println!(
                "  (task {} not restarted: {e} — if the daemon is not registered as a \
                 task, restart it manually: stop it, then `mootx01 serve --http auto`)",
                service::DAEMON_TASK
            ),
        }
        if service::restart_task(service::MGR_TASK).is_ok() {
            println!("  ✓ restarted task {}", service::MGR_TASK);
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    println!(
        "  (service restart pending on this platform — restart a running \
         daemon manually: stop it, then `mootx01 serve --http auto`)"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::depth::{self, InstallBundle, InstallDepth, ProcessClaudeCliRunner};

    fn tmp_home(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-upgrade-rematerialize-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Direct test of `rematerialize_plugin_depth`'s gating logic. A host that
    /// already has a plugin directory on disk (claude-code,
    /// seeded here) must be converged — its package is rewritten in place.
    /// A plugin-capable host with NO existing directory (cursor) must be
    /// left alone: an upgrade never CREATES a new plugin-depth install for
    /// a host that never had one.
    #[test]
    fn rematerializes_only_hosts_with_an_existing_plugin_dir() {
        let home = tmp_home("gate");

        // No plugin-capable host has a directory yet.
        let cursor_host = InstallBundle::embedded()
            .host("cursor")
            .expect("cursor must be in the embedded install map")
            .clone();
        let cursor_dir = depth::plugin_install_directory(&cursor_host, &home);
        assert!(!cursor_dir.exists(), "cursor must start with no plugin dir");

        // Seed claude-code as an EXISTING plugin-depth install (as if
        // `mootx01 install --mode plugin` ran previously for it only).
        depth::apply("claude-code", InstallDepth::Plugin, &home, false, &ProcessClaudeCliRunner)
            .expect("seeding claude-code's plugin install must succeed");
        let claude_host = InstallBundle::embedded().host("claude-code").unwrap().clone();
        let claude_dir = depth::plugin_install_directory(&claude_host, &home);
        let marker = claude_dir.join(".claude-plugin/plugin.json");
        assert!(marker.exists(), "seed must have created claude-code's plugin manifest");

        // Delete the manifest so the rematerialize pass has something
        // observable to converge — a no-op pass would leave it missing.
        std::fs::remove_file(&marker).unwrap();

        rematerialize_plugin_depth(&home);

        assert!(marker.exists(), "claude-code (had an existing dir) must be rematerialized");
        assert!(!cursor_dir.exists(), "cursor (never had a dir) must NOT get a new plugin install");

        let _ = std::fs::remove_dir_all(&home);
    }

    /// The gate is keyed on the plugin directory's existence, not on any
    /// other install state — a host with the directory pre-created (but not
    /// via a full `apply`) must still be picked up and populated.
    #[test]
    fn rematerializes_a_bare_pre_existing_directory() {
        let home = tmp_home("bare-dir");
        let claude_host = InstallBundle::embedded().host("claude-code").unwrap().clone();
        let claude_dir = depth::plugin_install_directory(&claude_host, &home);
        std::fs::create_dir_all(&claude_dir).unwrap();
        let manifest = claude_dir.join(".claude-plugin/plugin.json");
        assert!(!manifest.exists());

        rematerialize_plugin_depth(&home);

        assert!(manifest.exists(), "a bare pre-existing plugin dir must still be rematerialized");
        let _ = std::fs::remove_dir_all(&home);
    }
}
