//! commands/install.rs — §4.2: wire mootx01 into MCP clients.
//!
//! Pipeline per selected client: backup existing config (§4.2 backups) →
//! format-dispatched merge (JSON / TOML / Continue-YAML / Hermes shared YAML) →
//! optional permissions grant for Claude Code (only when --grant-permissions is
//! explicitly passed) → summary.
//!
//! Target selection: `--target ids` explicit, `--yes` all detected, else an
//! interactive numbered prompt (the arrow-key checkbox picker is §8 work;
//! the numbered prompt is the spec'd ANSI fallback and the v1 interactive
//! mode on Rust platforms).

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use crate::cli::{ExistingDbArg, InstallDepthArg, Location};
use crate::core::clients::{self, join_rel, ConfigFormat, McpClient, SERVER_NAME};
use crate::core::depth::{self, DepthOutcome, InstallDepth, ProcessClaudeCliRunner};
use crate::core::desktop_ext;
use crate::core::{mcp_ownership, merge, paths, permissions};
use crate::exit;

pub fn run(
    target: Option<Vec<String>>,
    location: Location,
    yes: bool,
    grant_permissions: bool,
    no_permissions: bool,
    no_mgr: bool,
    no_daemon: bool,
    vault_on: bool,
    depth_arg: Option<InstallDepthArg>,
    db_arg: Option<ExistingDbArg>,
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

    // Existing-database disposition (reinstall contract): resolved BEFORE any
    // wiring so a 'replace' that cannot proceed (daemon running, trash
    // failure) aborts the install with nothing half-done.
    if let Err(code) = handle_existing_database(db_arg, yes) {
        return code;
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

    // Process each selected client in order. Clients without a config path on
    // this platform (None from config_path) are each handled by install_one,
    // which prints a "not available" skip message.
    let mut wired = Vec::new();
    let mut skipped = Vec::new();
    // Client ids whose MCP wiring succeeded — depth payload applies only to these.
    let mut wired_ids: Vec<&'static str> = Vec::new();

    for client in &selected {
        // ADR-024 §1/§3: the plugin is the preferred connection owner. Still
        // place the binary/daemon (done above, unconditionally) but skip
        // writing a competing direct entry, and clean up any direct entry a
        // PRIOR install wrote — only when confirmed ours-default (§4).
        // Adams #5: gate on installed AND enabled — Claude Code tracks
        // enablement separately (~/.claude/settings.json's enabledPlugins
        // map), and an installed-but-disabled plugin does not own the
        // connection. Skipping/removing the direct entry in that state
        // would leave the client with nothing.
        if let Some(plugin_id) = plugin_owner(client.id) {
            if mcp_ownership::owns_connection(plugin_id, &home) {
                match dedupe_one(client, &home, location) {
                    Ok(merge::JsonOwnershipOutcome::NotPresent) => {}
                    Ok(merge::JsonOwnershipOutcome::Removed) => println!(
                        "  ⓘ {}: removed a stale direct mootx01 entry — the plugin now owns the connection",
                        client.display_name
                    ),
                    Ok(merge::JsonOwnershipOutcome::RetainedForeign { reason, path }) => println!(
                        "  ⚠ {}: a non-default mootx01 entry at {} ({reason}) was left untouched — inspect it by hand",
                        client.display_name,
                        path.display()
                    ),
                    Err(e) => eprintln!(
                        "  ✗ {}: could not check for a competing direct entry: {e}",
                        client.display_name
                    ),
                }
                println!(
                    "  ⓘ MOOTx01 plugin already installed — {} connects through it; skipping direct wiring.",
                    client.display_name
                );
                // Wave 6, Defect A (live 1.0.16 machine finding): the
                // ADR-024 ownership skip above applies ONLY to the direct
                // mcpServers entry. Before this fix, `continue` here left
                // `client.id` out of `wired_ids` entirely, and the depth
                // loop below filters on `wired_ids.contains(...)` — so a
                // plugin-owned client got NO depth pass at all: no package
                // rematerialization, no stranded-cache refresh. The stale
                // stdio-era package in ~/.claude/mootx01-plugin (and Claude
                // Code's stale cached snapshot) then survived every
                // subsequent `mootx01 install` run forever. A plugin-owned
                // connection is exactly the case where the package must
                // stay freshest, so this client counts as wired (its MCP
                // connection succeeded — via the plugin, not a direct
                // entry) and proceeds to the depth pass below.
                wired.push(client.display_name);
                wired_ids.push(client.id);
                continue;
            }
        }
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
    // fallback is reported (the §4.4 ceiling). Applied to every client whose MCP
    // wiring succeeded — direct OR plugin-owned (Wave 6, Defect A: a
    // plugin-owned client's connection ownership is NOT a reason to skip this
    // pass; it is the reason the package must stay freshest).
    if depth != InstallDepth::Server {
        println!();
        println!("Integration depth: {}", depth.as_str());
        for client in &selected {
            if !wired_ids.contains(&client.id) {
                continue;
            }
            // vault_off = !vault_on: thread the vault posture into the plugin
            // installer so any command/stdio-shaped entry in the package (the
            // proxy-bridge fallback for a host whose schema cannot express
            // HTTP) inherits the correct env. HTTP-shaped entries are
            // untouched — the resident daemon carries the vault posture in
            // its own service-manager environment (`core::service`),
            // independent of this call (ADR-024 Wave 3, Defect 2).
            match depth::apply(client.id, depth, &home, !vault_on, &ProcessClaudeCliRunner) {
                Ok(DepthOutcome::Server) => {
                    // Claude Desktop's "plugin" is a Desktop extension, not a
                    // file-drop payload. At plugin depth, install it
                    // programmatically (the same registry writes a .mcpb
                    // double-click makes). Other MCP-only hosts (continue, kiro)
                    // genuinely have no plugin surface.
                    if client.id == "claude-desktop" && depth == InstallDepth::Plugin {
                        match desktop_ext::install(
                            client,
                            &home,
                            &binary_path,
                            env!("CARGO_PKG_VERSION"),
                        ) {
                            Ok(true) => println!(
                                "  ✓ {}: extension installed → restart Claude Desktop to load it",
                                client.display_name
                            ),
                            Ok(false) => println!(
                                "  ⓘ {}: MCP server wired (Claude Desktop not detected — skipped extension)",
                                client.display_name
                            ),
                            Err(e) => eprintln!(
                                "  ⚠ {}: MCP server wired; extension install failed: {e}",
                                client.display_name
                            ),
                        }
                    } else if client.id == "claude-desktop" {
                        println!("  ⓘ {}: MCP server wired.", client.display_name);
                    } else {
                        println!(
                            "  ⓘ {}: server only (no skill/plugin payload for this client)",
                            client.display_name
                        );
                    }
                }
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

    // Permissions (Claude Code settings) — §4.2, AIRA-INSTALL-P3 key.
    //
    //   default              → TIERED by verb semantics (Bob's re-tier
    //                          ruling, 2026-07-04, permissions::classify):
    //                          reads and additive-unconfirmed writes allow,
    //                          mutations of existing state ask, destructive
    //                          purges deny. The PRIOR default put every
    //                          non-diagnostic tool in ask — 55 ask rules on
    //                          a real machine, including every pure read —
    //                          which is what made moot unusable from
    //                          permission prompts. migrate_tiers converges
    //                          an existing install onto the new default
    //                          before grant_tiered adds anything still
    //                          missing; both write BOTH the direct
    //                          (mcp__mootx01__) and plugin
    //                          (mcp__plugin_mootx01_mootx01__) namespaces —
    //                          a rule under only one matches zero calls made
    //                          through the other Claude Code connection.
    //   --grant-permissions  → every tool into allow (explicit opt-in).
    //   --no-permissions     → write nothing (guaranteed no-write for scripts).
    if !no_permissions && selected.iter().any(|c| c.id == "claude-code") {
        // join_rel produces native separators on every platform (backslash on
        // Windows, forward-slash on POSIX) — home.join(".claude/settings.json")
        // would leave a mixed path on Windows.
        let settings = match location {
            Location::Global => join_rel(&home, ".claude/settings.json"),
            Location::Local => PathBuf::from(".claude").join("settings.json"),
        };
        if grant_permissions {
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
        } else {
            // Re-tier any entry from a PRIOR install that predates the
            // current classification (Bob's re-tier ruling, 2026-07-04)
            // before adding whatever is still missing — otherwise a repeat
            // `mootx01 install` run would leave an existing install's stale
            // tiering (e.g. every read fossilized in `ask` under the old
            // default) in place forever, since grant_tiered only adds
            // absent entries.
            match merge::backup_existing(&settings)
                .map_err(merge::MergeError::from)
                .and_then(|_| permissions::migrate_tiers(&settings))
            {
                Ok(moved) if moved > 0 => {
                    println!("  ✓ Re-tiered {moved} existing ARIA tool permission(s) to the current default")
                }
                Ok(_) => {}
                Err(e) => eprintln!("  ✗ permissions migration: {e}"),
            }
            match permissions::grant_tiered(&settings) {
                Ok((a, k, d)) if a + k + d > 0 => println!(
                    "  ✓ Claude Code tool permissions: {a} allowed (reads + new-content writes), {k} ask (mutations of existing content), {d} denied (destructive) — edit in {}",
                    settings.display()
                ),
                Ok(_) => {}
                Err(e) => eprintln!("  ✗ permissions: {e}"),
            }
        }
    }

    // Service registration (§6). Linux: systemd user units. Windows: Task
    // Scheduler via PowerShell cmdlets. macOS: Swift/launchd territory — the
    // Rust binary is used for dev builds only.
    #[cfg(target_os = "linux")]
    {
        use crate::core::service;
        let data_override = std::env::var("MOOTX01_DATA_DIR").ok().filter(|v| !v.is_empty());
        if !no_daemon {
            // vault_on baked into the unit's Environment= block so the resident
            // daemon reads MOOTX01_VAULT without it being set in the shell (ADR-015).
            // Fails CLOSED if MOOTX01_DATA_DIR contains characters that would allow
            // systemd directive injection.
            match service::daemon_unit(&binary_path, data_override.as_deref(), vault_on) {
                Ok(unit) => report_registration("daemon", service::register(&home, service::DAEMON_UNIT, &unit)),
                Err(e) => eprintln!("  ✗ daemon service: data-dir path rejected: {e}"),
            }
        }
        if !no_mgr {
            let mgr_binary = std::path::Path::new(&binary_path)
                .parent()
                .map(|d| d.join("moot-mgr"))
                .filter(|p| p.exists());
            match mgr_binary {
                Some(mgr) => {
                    let token = service::random_token();
                    // Fails CLOSED if MOOTX01_DATA_DIR contains characters that would
                    // allow systemd directive injection.
                    match service::mgr_unit(
                        &mgr.display().to_string(),
                        &token,
                        data_override.as_deref(),
                    ) {
                        Ok(unit) => report_registration("moot-mgr", service::register(&home, service::MGR_UNIT, &unit)),
                        Err(e) => eprintln!("  ✗ moot-mgr service: data-dir path rejected: {e}"),
                    }
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
            // Fails CLOSED if MOOTX01_DATA_DIR contains cmd.exe-unsafe characters.
            match service::daemon_task_command(&binary_path, data_override.as_deref(), vault_on) {
                Ok((exe, arg)) => report_registration("daemon", service::register_task(service::DAEMON_TASK, &exe, &arg)),
                Err(e) => eprintln!("  ✗ daemon service: data-dir path rejected: {e}"),
            }
        }
        if !no_mgr {
            let mgr_binary = std::path::Path::new(&binary_path)
                .parent()
                .map(|d| d.join("moot-mgr.exe"))
                .filter(|p| p.exists());
            match mgr_binary {
                Some(mgr) => {
                    let token = service::random_token();
                    if let Err(e) = service::write_mgr_control_token(&token) {
                        report_registration("moot-mgr", service::RegisterOutcome::Failed(e));
                    } else {
                        // Fails CLOSED if MOOTX01_DATA_DIR contains cmd.exe-unsafe characters.
                        match service::mgr_task_command(
                            &mgr.display().to_string(),
                            &token,
                            data_override.as_deref(),
                        ) {
                            Ok((exe, arg)) => report_registration("moot-mgr", service::register_task(service::MGR_TASK, &exe, &arg)),
                            Err(e) => eprintln!("  ✗ moot-mgr service: data-dir path rejected: {e}"),
                        }
                    }
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

/// ADR-024 §3: clients the CLI installer knows how to detect a live plugin
/// for, mapped to the plugin registry id (`installed_plugins.json`'s
/// top-level key). Only Claude Code has a live plugin today; kept as an
/// explicit small table rather than guessed for hosts with no shipped
/// plugin yet.
fn plugin_owner(client_id: &str) -> Option<&'static str> {
    match client_id {
        "claude-code" => Some("mootx01@mootx01"),
        _ => None,
    }
}

/// ADR-024 §3/§4: resolve the same config path `install_one` would target
/// (respecting `--location local` for Claude Code) and run the
/// ownership-aware dedupe pass against it. Scoped to JSON-format clients —
/// the only format any currently plugin-owned client uses.
fn dedupe_one(
    client: &McpClient,
    home: &Path,
    location: Location,
) -> Result<merge::JsonOwnershipOutcome, merge::MergeError> {
    let Some(mut config) = client.config_path(home) else {
        return Ok(merge::JsonOwnershipOutcome::NotPresent);
    };
    if location == Location::Local && client.id == "claude-code" {
        config = PathBuf::from(".mcp.json");
    }
    if client.format != ConfigFormat::Json {
        return Ok(merge::JsonOwnershipOutcome::NotPresent);
    }
    merge::dedupe_direct_entry(&config, client.json_servers_key(), SERVER_NAME)
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

// ── existing-database disposition (reinstall contract) ─────────────────────
//
// A reinstall over live data must never silently adopt OR silently destroy
// it. The contract (mirrored by the Swift InstallCommand):
//   Reuse   → the existing database stays THE default estate; the moot-mgr
//             history store is moved to the platform trash so the dashboard
//             re-registers only what the daemon actually serves.
//   Replace → the default estate files AND the moot-mgr store move to the
//             platform trash (recoverable); a fresh database is created on
//             first serve and is then the only estate moot-mgr knows.
// Named estates under databases/<name>/ are untouched by both branches —
// they are addressed by `mootx01 db`, not by the install flow.

/// What the reinstall phase decided. Factored out so the flag/prompt matrix
/// is unit-testable without a TTY.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum DbDecision {
    /// No existing database — nothing to decide.
    Fresh,
    /// Proceed without touching anything (with the printed reason).
    Untouched(&'static str),
    /// Adopt the existing database; reset the moot-mgr store.
    Reuse,
    /// Trash the default estate + moot-mgr store for a fresh start.
    Replace,
    /// The user was asked to confirm destruction and did not type 'yes'.
    Aborted,
}

/// Resolve the flag/prompt matrix for an existing database.
///
/// - `flag`        — explicit `--reuse-db` / `--replace-db`.
/// - `yes`         — `--yes` skips the typed destruction confirmation, but
///                   only when the choice itself was explicit (`--replace-db`).
/// - `interactive` — stdin is a terminal.
/// - `choose`      — interactive reuse-or-replace prompt; true = replace.
/// - `confirm`     — the typed-'yes' destruction gate for replace.
pub(crate) fn decide_existing_db(
    flag: Option<ExistingDbArg>,
    yes: bool,
    interactive: bool,
    choose: impl FnOnce() -> bool,
    confirm: impl FnOnce() -> bool,
) -> DbDecision {
    let replace = match flag {
        Some(ExistingDbArg::Reuse) => false,
        Some(ExistingDbArg::Replace) => true,
        None if !interactive => {
            // No explicit choice and nobody to ask: leave everything as it
            // is. Existing automation (CI harnesses, scripted installs)
            // keeps its historical no-data-surprises contract.
            return DbDecision::Untouched(
                "existing database left untouched (non-interactive; pass --reuse-db or --replace-db to choose)",
            );
        }
        None => choose(),
    };
    if !replace {
        return DbDecision::Reuse;
    }
    if yes {
        return DbDecision::Replace;
    }
    if !interactive {
        return DbDecision::Untouched(
            "existing database left untouched (--replace-db needs --yes when non-interactive)",
        );
    }
    if confirm() {
        DbDecision::Replace
    } else {
        DbDecision::Aborted
    }
}

/// True when a default estate database already exists in `data`, in either
/// layout: the Rust `databases/default/estate.sqlite` or the Swift legacy
/// flat `<data>/estate.sqlite` (a migrated data directory).
pub(crate) fn default_estate_exists(data: &Path) -> bool {
    paths::estate_sqlite_path(data, "default").exists() || data.join("estate.sqlite").exists()
}

/// Adopt the existing database: it stays the active default estate; the
/// moot-mgr history store is trashed so the dashboard's estate registry
/// rebuilds from what the daemon actually serves.
pub(crate) fn apply_reuse(data: &Path) -> Result<(), String> {
    paths::set_active_estate(data, "default")
        .map_err(|e| format!("cannot set active estate: {e}"))?;
    trash_mgr_store(data)
}

/// Fresh start: move the default estate files (both layouts) and the
/// moot-mgr store to the platform trash. Named estates are untouched.
pub(crate) fn apply_replace(data: &Path) -> Result<(), String> {
    // Flat legacy layout: the SQLite file, its WAL/SHM sidecars, and the
    // derived vector / dreaming-queue siblings that carry estate content
    // (`estate.sqlite` → `estate.vectors.vec` / `estate.queue.sqlite`,
    //  see VectorStore.vectorsURL and EstateConfiguration.queueSibling).
    for name in [
        "estate.sqlite",
        "estate.sqlite-wal",
        "estate.sqlite-shm",
        "estate.vectors.vec",
        "estate.queue.sqlite",
        "estate.queue.sqlite-wal",
        "estate.queue.sqlite-shm",
    ] {
        let p = data.join(name);
        if p.exists() {
            trash::delete(&p).map_err(|e| format!("cannot trash {}: {e}", p.display()))?;
        }
    }
    // Rust layout: the whole databases/default/ directory (SQLite, sidecars,
    // and the whole-file encryption key live together).
    let default_dir = data.join("databases").join("default");
    if default_dir.exists() {
        trash::delete(&default_dir)
            .map_err(|e| format!("cannot trash {}: {e}", default_dir.display()))?;
    }
    paths::set_active_estate(data, "default")
        .map_err(|e| format!("cannot set active estate: {e}"))?;
    trash_mgr_store(data)
}

/// Move the moot-mgr history store (<data>/moot-mgr/) to the platform trash
/// if present. The manager recreates an empty store on next start, so this
/// is the "reset registration" primitive both branches share.
fn trash_mgr_store(data: &Path) -> Result<(), String> {
    let mgr = data.join("moot-mgr");
    if mgr.exists() {
        trash::delete(&mgr).map_err(|e| format!("cannot trash {}: {e}", mgr.display()))?;
    }
    Ok(())
}

/// Interactive/flag front-end for the reinstall contract. Returns Err(code)
/// when the install must stop (user abort, daemon still running, trash
/// failure); Ok(()) to continue installing.
fn handle_existing_database(flag: Option<ExistingDbArg>, yes: bool) -> Result<(), ExitCode> {
    use std::io::IsTerminal;
    let data = paths::data_dir();
    if !default_estate_exists(&data) {
        return Ok(());
    }
    let interactive = io::stdin().is_terminal();
    let decision = decide_existing_db(
        flag,
        yes,
        interactive,
        || {
            println!("\nAn existing MOOTx01 database was found at {}.", data.display());
            print!("Reuse it, or replace it with a fresh one? [reuse/replace] (reuse): ");
            let _ = io::stdout().flush();
            let mut line = String::new();
            let _ = io::stdin().lock().read_line(&mut line);
            line.trim().eq_ignore_ascii_case("replace")
        },
        || {
            println!("WARNING: replacing DESTROYS the current default estate and moot-mgr history.");
            println!("They will be moved to {} (recoverable until you empty it).", super::uninstall::trash_name());
            print!("Type 'yes' to confirm: ");
            let _ = io::stdout().flush();
            let mut line = String::new();
            let _ = io::stdin().lock().read_line(&mut line);
            line.trim() == "yes"
        },
    );
    match decision {
        DbDecision::Fresh => Ok(()),
        DbDecision::Untouched(reason) => {
            println!("  ⓘ {reason}");
            Ok(())
        }
        DbDecision::Aborted => {
            println!("Aborted — nothing was installed or removed.");
            Err(ExitCode::from(exit::FAILURE))
        }
        DbDecision::Reuse => {
            reject_if_daemon_alive("reusing the database resets the moot-mgr history store")?;
            apply_reuse(&data).map_err(|e| {
                eprintln!("  ✗ {e}");
                ExitCode::from(exit::FAILURE)
            })?;
            println!("  ✓ Existing database adopted as the default estate; moot-mgr history reset.");
            Ok(())
        }
        DbDecision::Replace => {
            reject_if_daemon_alive("replacing the database")?;
            apply_replace(&data).map_err(|e| {
                eprintln!("  ✗ {e}");
                ExitCode::from(exit::FAILURE)
            })?;
            println!(
                "  ✓ Previous database moved to {}; a fresh estate will be created on first serve.",
                super::uninstall::trash_name()
            );
            Ok(())
        }
    }
}

/// A live daemon holds the estate and stats stores open (on Windows, open
/// handles also make the move fail). Refuse the data operation and tell the
/// user to stop it first, rather than yanking files out from under it.
fn reject_if_daemon_alive(action: &str) -> Result<(), ExitCode> {
    let port = crate::core::daemon_client::resolved_port();
    if crate::core::daemon_client::alive(port) {
        eprintln!(
            "  ✗ The mootx01 daemon is running on port {port}; {action} needs it stopped.\n    Stop it (or uninstall) and re-run install."
        );
        return Err(ExitCode::from(exit::FAILURE));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verifies the permissions gate: --no-permissions is a guaranteed
    /// no-write; the default writes the TIERED lists (allow/ask/deny — full
    /// broad approval still requires --grant-permissions, which fills allow).
    #[test]
    fn grant_permissions_flag_gates_settings_write() {
        use crate::core::permissions;
        let tmp = std::env::temp_dir()
            .join(format!("mootx01-perm-gate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let settings = tmp.join("settings.json");

        // Mirrors the gate condition in run(): --no-permissions blocks any
        // write regardless of other flags.
        let no_permissions = true;
        if !no_permissions {
            permissions::grant_tiered(&settings).unwrap();
        }
        assert!(
            !settings.exists(),
            "settings.json must not be written under --no-permissions"
        );

        // Default (no flags): tiered write occurs, and destructive tools land
        // in deny — NOT allow. The old default (write nothing) left every tool
        // unapproved and the install non-functional out of the box.
        let no_permissions = false;
        if !no_permissions {
            permissions::grant_tiered(&settings).unwrap();
        }
        assert!(
            settings.exists(),
            "settings.json must get the tiered defaults on a plain install"
        );
        let root: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&settings).unwrap()).unwrap();
        let deny: Vec<&str> = root["permissions"]["deny"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|v| v.as_str())
            .collect();
        assert!(
            deny.iter().any(|e| e.contains("erase")),
            "destructive tools must default to deny, got deny={deny:?}"
        );
        let allow = root["permissions"]["allow"].as_array().unwrap();
        assert!(
            allow.iter().any(|v| v.as_str().unwrap().ends_with("_ping")),
            "diagnostics must default to allow"
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

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

    // ADR-024 §3/§4: four-state matrix (plugin present/absent × prior direct
    // entry present/absent) + the non-default-entry-survives guarantee.
    // Mirrors Swift's PluginDedupeTests.swift. SAFETY: every test uses a
    // temp-dir sandbox home; never the real ~/.claude.

    fn plugin_test_home(tag: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!("mootx01-plugin-dedupe-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        home
    }

    fn write_installed_plugins(home: &Path, plugin_id: &str) {
        let dir = home.join(".claude").join("plugins");
        std::fs::create_dir_all(&dir).unwrap();
        let body = serde_json::json!({
            "version": 2,
            "plugins": { plugin_id: [{"scope": "user", "installPath": "x", "version": "1.0.15"}] },
        });
        std::fs::write(dir.join("installed_plugins.json"), body.to_string()).unwrap();
    }

    fn write_settings(home: &Path, json_text: &str) {
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        std::fs::write(home.join(".claude").join("settings.json"), json_text).unwrap();
    }

    fn claude_code_client() -> McpClient {
        clients::supported().into_iter().find(|c| c.id == "claude-code").unwrap()
    }

    fn read_direct_entry(client: &McpClient, home: &Path) -> Option<serde_json::Value> {
        let config = client.config_path(home)?;
        let bytes = std::fs::read(&config).ok()?;
        let root: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
        root.get(client.json_servers_key())?.get(SERVER_NAME).cloned()
    }

    #[test]
    fn state1_no_plugin_no_prior_entry_normal_install_wires() {
        let home = plugin_test_home("s1");
        let client = claude_code_client();
        assert!(!mcp_ownership::is_plugin_installed("mootx01@mootx01", &home));
        install_one(&client, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .unwrap();
        assert!(read_direct_entry(&client, &home).is_some());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn state2_no_plugin_prior_entry_present_rewires_in_place() {
        let home = plugin_test_home("s2");
        let client = claude_code_client();
        install_one(&client, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .unwrap();
        assert!(!mcp_ownership::is_plugin_installed("mootx01@mootx01", &home));
        install_one(&client, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .unwrap();
        assert!(read_direct_entry(&client, &home).is_some());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn state3_plugin_present_no_prior_entry_dedupe_is_noop() {
        let home = plugin_test_home("s3");
        let client = claude_code_client();
        write_installed_plugins(&home, "mootx01@mootx01");
        assert!(mcp_ownership::is_plugin_installed("mootx01@mootx01", &home));
        let outcome = dedupe_one(&client, &home, Location::Global).unwrap();
        assert_eq!(outcome, merge::JsonOwnershipOutcome::NotPresent);
        assert!(read_direct_entry(&client, &home).is_none());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn state4_plugin_present_prior_ours_default_entry_removed() {
        let home = plugin_test_home("s4");
        let client = claude_code_client();
        install_one(&client, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .unwrap();
        assert!(read_direct_entry(&client, &home).is_some());
        write_installed_plugins(&home, "mootx01@mootx01");
        let outcome = dedupe_one(&client, &home, Location::Global).unwrap();
        assert_eq!(outcome, merge::JsonOwnershipOutcome::Removed);
        assert!(read_direct_entry(&client, &home).is_none());
        let _ = std::fs::remove_dir_all(&home);
    }

    // ADR-024 §1/§3 gated on installed AND enabled (Adams #5). Mirrors the
    // exact conditional install::run() uses: "disabled falls back to direct
    // wiring; enabled skips as shipped."

    #[test]
    fn disabled_plugin_falls_back_to_direct_wiring() {
        let home = plugin_test_home("disabled");
        let client = claude_code_client();
        write_installed_plugins(&home, "mootx01@mootx01");
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":false}}"#);

        if mcp_ownership::owns_connection("mootx01@mootx01", &home) {
            panic!("plugin must not be considered connection-owning while disabled");
        }
        install_one(&client, &home, "/usr/local/bin/mootx01", "http://127.0.0.1:4242", Location::Global)
            .unwrap();
        assert!(
            read_direct_entry(&client, &home).is_some(),
            "disabled plugin must not block direct wiring — the client would otherwise have no connection"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn enabled_plugin_skips_direct_wiring_as_shipped() {
        let home = plugin_test_home("enabled");
        let client = claude_code_client();
        write_installed_plugins(&home, "mootx01@mootx01");
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":true}}"#);

        assert!(
            mcp_ownership::owns_connection("mootx01@mootx01", &home),
            "plugin must be considered connection-owning while installed and enabled"
        );
        // Matches install::run()'s skip branch: no install_one call.
        assert!(
            read_direct_entry(&client, &home).is_none(),
            "enabled plugin must skip direct wiring — no competing entry written"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Wave 6, Defect A regression fixture — the exact state Bob's machine
    /// was found in: plugin installed+enabled (own_connection true) AND a
    /// stale stdio-era package already on disk (`.mcp.json` with
    /// `command: mootx01, args: [serve]`, pre-ADR-024-§2). Before the fix,
    /// `run()`'s loop `continue`d without pushing `client.id` into
    /// `wired_ids`, so the depth pass's `wired_ids.contains(...)` filter
    /// (line ~134) silently excluded claude-code — the plugin package,
    /// and Claude Code's cached snapshot of it, never converged.
    ///
    /// This test drives the same two calls `run()`'s FIXED code path makes
    /// once a plugin-owned client is (correctly) included in the depth
    /// pass: `dedupe_one` (must find no competing direct entry to write)
    /// and `depth::apply(.., InstallDepth::Plugin, ..)` (must rewrite the
    /// stale package to the current HTTP-shaped manifest and invoke the
    /// stranded-cache CLI-update seam, since the plugin is already
    /// installed).
    struct FakeClaudeCliRunner {
        invoked: std::cell::RefCell<Vec<Vec<String>>>,
    }
    impl FakeClaudeCliRunner {
        fn new() -> Self {
            FakeClaudeCliRunner { invoked: std::cell::RefCell::new(Vec::new()) }
        }
    }
    impl depth::ClaudeCliRunning for FakeClaudeCliRunner {
        fn run(&self, args: &[&str]) -> bool {
            self.invoked.borrow_mut().push(args.iter().map(|s| s.to_string()).collect());
            true
        }
    }

    #[test]
    fn plugin_owned_client_with_stale_package_is_rematerialized_not_skipped() {
        let home = plugin_test_home("defect-a");
        let client = claude_code_client();
        write_installed_plugins(&home, "mootx01@mootx01");
        write_settings(&home, r#"{"enabledPlugins":{"mootx01@mootx01":true}}"#);
        assert!(
            mcp_ownership::owns_connection("mootx01@mootx01", &home),
            "fixture setup: plugin must be connection-owning"
        );

        // Seed the stale stdio-era package Bob's machine actually had on
        // disk — pre-ADR-024-§2, before the package moved to an
        // HTTP-shaped .mcp.json.
        let bundle = depth::InstallBundle::embedded();
        let host = bundle.host("claude-code").expect("claude-code must be in the embedded install map");
        let plugin_dir = depth::plugin_install_directory(host, &home);
        std::fs::create_dir_all(&plugin_dir).unwrap();
        let stale_mcp = serde_json::json!({
            "mcpServers": {"mootx01": {"command": "mootx01", "args": ["serve"]}}
        });
        std::fs::write(plugin_dir.join(".mcp.json"), stale_mcp.to_string()).unwrap();

        // Step 1 of run()'s plugin-owned branch: dedupe — no direct entry
        // exists to remove or retain, and none must be written.
        let outcome = dedupe_one(&client, &home, Location::Global).unwrap();
        assert!(
            matches!(outcome, merge::JsonOwnershipOutcome::NotPresent),
            "no prior direct entry in this fixture; expected NotPresent, got {outcome:?}"
        );

        // Step 2 (the fix): the depth pass now runs for this client too.
        let fake = FakeClaudeCliRunner::new();
        let result = depth::apply("claude-code", InstallDepth::Plugin, &home, false, &fake).unwrap();
        assert!(matches!(result, DepthOutcome::Plugin(_)), "expected DepthOutcome::Plugin, got {result:?}");

        let rewritten: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(plugin_dir.join(".mcp.json")).unwrap()).unwrap();
        assert_eq!(
            rewritten["mcpServers"]["mootx01"]["type"], "http",
            "the stale stdio manifest must have converged to the current HTTP-shaped entry; got: {rewritten}"
        );
        assert!(
            rewritten["mcpServers"]["mootx01"]["command"].is_null(),
            "the stale bare `command: mootx01` placeholder must be gone; got: {rewritten}"
        );

        // The stranded-cache refresh (ADR-024 Wave 3, Defect 1) must have
        // invoked the CLI-update seam, since the plugin is already installed.
        assert_eq!(
            fake.invoked.borrow().as_slice(),
            &[vec!["plugin".to_string(), "update".to_string(), "mootx01@mootx01".to_string()]],
            "rematerializing an already-installed plugin must invoke `claude plugin update`"
        );

        // No direct entry must exist — the plugin still owns the connection.
        assert!(
            read_direct_entry(&client, &home).is_none(),
            "a plugin-owned client must never gain a competing direct entry from the depth pass"
        );

        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn non_default_dev_rig_entry_survives_dedupe_untouched_and_named() {
        let home = plugin_test_home("nondefault");
        let client = claude_code_client();
        let config = client.config_path(&home).unwrap();
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        let dev_rig = serde_json::json!({
            "mcpServers": {
                "mootx01": {
                    "command": "/Users/dev/build/mootx01",
                    "args": ["proxy"],
                    "env": {"MOOTX01_DATA_DIR": "/Users/dev/rig-a/.mootx01-data"},
                }
            }
        });
        std::fs::write(&config, dev_rig.to_string()).unwrap();

        write_installed_plugins(&home, "mootx01@mootx01");
        let outcome = dedupe_one(&client, &home, Location::Global).unwrap();
        match outcome {
            merge::JsonOwnershipOutcome::RetainedForeign { reason, path } => {
                assert!(reason.contains("MOOTX01_DATA_DIR"));
                assert_eq!(path, config);
            }
            other => panic!("expected RetainedForeign, got {other:?}"),
        }
        let entry = read_direct_entry(&client, &home).unwrap();
        assert_eq!(entry["command"], "/Users/dev/build/mootx01");
        assert_eq!(entry["env"]["MOOTX01_DATA_DIR"], "/Users/dev/rig-a/.mootx01-data");
        let _ = std::fs::remove_dir_all(&home);
    }

    // Verification-pass addendum: classify()'s label alone is by-construction
    // evidence; these round-trip a shape-mismatched entry through a REAL temp
    // config file and the full dedupe_one/dedupe_direct_entry pass with
    // plugin-present state, proving the file survives untouched.

    #[test]
    fn dedupe_round_trip_malformed_entry_survives() {
        let home = plugin_test_home("malformed");
        let client = claude_code_client();
        let config = client.config_path(&home).unwrap();
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        let malformed = serde_json::json!({"mcpServers": {"mootx01": {}}});
        std::fs::write(&config, malformed.to_string()).unwrap();

        write_installed_plugins(&home, "mootx01@mootx01");
        let outcome = dedupe_one(&client, &home, Location::Global).unwrap();
        match outcome {
            merge::JsonOwnershipOutcome::RetainedForeign { .. } => {}
            other => panic!("expected RetainedForeign for a malformed {{}} entry, got {other:?}"),
        }
        let entry = read_direct_entry(&client, &home).unwrap();
        assert!(entry.as_object().unwrap().is_empty(), "the malformed entry must still be present, untouched");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn dedupe_round_trip_foreign_command_entry_survives() {
        let home = plugin_test_home("foreign-command");
        let client = claude_code_client();
        let config = client.config_path(&home).unwrap();
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        let foreign = serde_json::json!({
            "mcpServers": {
                "mootx01": {
                    "command": "/usr/bin/some-other-server",
                    "args": ["--stdio"],
                }
            }
        });
        std::fs::write(&config, foreign.to_string()).unwrap();

        write_installed_plugins(&home, "mootx01@mootx01");
        let outcome = dedupe_one(&client, &home, Location::Global).unwrap();
        match outcome {
            merge::JsonOwnershipOutcome::RetainedForeign { .. } => {}
            other => panic!("expected RetainedForeign for a foreign command entry, got {other:?}"),
        }
        let entry = read_direct_entry(&client, &home).unwrap();
        assert_eq!(entry["command"], "/usr/bin/some-other-server");
        assert_eq!(entry["args"][0], "--stdio");
        let _ = std::fs::remove_dir_all(&home);
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

    // ── existing-database decision matrix ───────────────────────────────
    // Every destructive branch must require an explicit human 'yes' or the
    // --replace-db --yes automation pair; the implicit non-interactive
    // default must change nothing.

    fn never() -> bool {
        panic!("prompt must not be reached in this branch")
    }

    #[test]
    fn no_flag_non_interactive_is_untouched() {
        let d = decide_existing_db(None, false, false, never, never);
        assert!(matches!(d, DbDecision::Untouched(_)));
    }

    #[test]
    fn no_flag_yes_non_interactive_is_still_untouched() {
        // --yes alone must not pick a disposition for existing data.
        let d = decide_existing_db(None, true, false, never, never);
        assert!(matches!(d, DbDecision::Untouched(_)));
    }

    #[test]
    fn reuse_flag_needs_no_confirmation() {
        let d = decide_existing_db(Some(ExistingDbArg::Reuse), false, false, never, never);
        assert_eq!(d, DbDecision::Reuse);
    }

    #[test]
    fn replace_flag_with_yes_replaces() {
        let d = decide_existing_db(Some(ExistingDbArg::Replace), true, false, never, never);
        assert_eq!(d, DbDecision::Replace);
    }

    #[test]
    fn replace_flag_non_interactive_without_yes_is_untouched() {
        let d = decide_existing_db(Some(ExistingDbArg::Replace), false, false, never, never);
        assert!(matches!(d, DbDecision::Untouched(_)));
    }

    #[test]
    fn replace_flag_interactive_requires_typed_yes() {
        let d = decide_existing_db(Some(ExistingDbArg::Replace), false, true, never, || false);
        assert_eq!(d, DbDecision::Aborted);
        let d = decide_existing_db(Some(ExistingDbArg::Replace), false, true, never, || true);
        assert_eq!(d, DbDecision::Replace);
    }

    #[test]
    fn interactive_prompt_reuse_and_replace_paths() {
        let d = decide_existing_db(None, false, true, || false, never);
        assert_eq!(d, DbDecision::Reuse);
        let d = decide_existing_db(None, false, true, || true, || true);
        assert_eq!(d, DbDecision::Replace);
        let d = decide_existing_db(None, false, true, || true, || false);
        assert_eq!(d, DbDecision::Aborted);
    }

    #[test]
    fn default_estate_detection_covers_both_layouts() {
        let data = std::env::temp_dir()
            .join(format!("mootx01-dbdetect-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&data);
        std::fs::create_dir_all(&data).unwrap();
        assert!(!default_estate_exists(&data));
        // Swift legacy flat layout.
        std::fs::write(data.join("estate.sqlite"), b"x").unwrap();
        assert!(default_estate_exists(&data));
        let _ = std::fs::remove_file(data.join("estate.sqlite"));
        // Rust databases/default layout.
        std::fs::create_dir_all(data.join("databases").join("default")).unwrap();
        std::fs::write(
            data.join("databases").join("default").join("estate.sqlite"),
            b"x",
        )
        .unwrap();
        assert!(default_estate_exists(&data));
        let _ = std::fs::remove_dir_all(&data);
    }
}
