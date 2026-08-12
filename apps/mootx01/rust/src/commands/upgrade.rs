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
        let code = place_and_report(&src, &home, no_restart);
        if code == ExitCode::from(exit::OK) {
            run_kg_fact_identity_backfill();
            run_shared_content_reclaim_if_pending();
            offer_estate_encryption_if_needed();
        }
        return code;
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
            // Bob's ruling: `mootx01 upgrade` is the ONLY migration vehicle,
            // and it converges whether or not a new version is available — so
            // the up-to-date early return still backfills and offers.
            run_kg_fact_identity_backfill();
            run_shared_content_reclaim_if_pending();
            offer_estate_encryption_if_needed();
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
        // After the services are back up, so a decline leaves a fully
        // converged install and an accept owns its own stop/start sequence.
        // The backfill runs first: unattended correctness migration before
        // the TTY-gated opt-in offer.
        run_kg_fact_identity_backfill();
        run_shared_content_reclaim_if_pending();
        offer_estate_encryption_if_needed();
    }
    code
}

/// MXE-MI: move pre-MXE-KH `kg_facts.sourceDrawerID` identity values into
/// the columns MXE-KH created for them (`addedBy`, `foreignSourceKey`,
/// `foreignRecordID`), via locus-kit's `kg_fact_identity_backfill`.
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling) — this is
/// that vehicle; no detection or prompting lives anywhere else. Unattended
/// and non-interactive, unlike the TTY-gated encryption offer: a
/// correctness migration must also converge scripted/service upgrades.
///
/// Failure posture inherits the estate-encryption invariant — every failure
/// path leaves a working estate at the canonical path. The backfill's moves
/// are per-row atomic UPDATEs, so a partial run leaves every row in one of
/// two readable shapes (the palace dedup anchor's fallback ladder serves
/// both) and the next upgrade completes it. The estate opens through the
/// SUBSTRATE path on purpose: the schema ladder's v12 → v13 migration is
/// what adds the identity columns to estates that predate them, and
/// `SqliteStorage::new` adopts the sibling `db.key` on its own, so keyed
/// and plaintext estates both open correctly.
fn run_kg_fact_identity_backfill() {
    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
    use persistence_kit::sqlite::SqliteStorage;
    use uuid::Uuid;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    // Absent estate means first run — serve creates new estates post-KH;
    // there is nothing to backfill.
    if !estate.exists() {
        return;
    }

    // Quiesce first (single-writer discipline, same direction as the
    // encryption migration): if the daemon will not stop, skip — nothing is
    // half-done, and the next `mootx01 upgrade` retries.
    let was_running = daemon_is_running();
    if was_running && !daemon_stop() {
        println!(
            "  ✗ kg_facts identity backfill skipped — the resident daemon would not stop; run `mootx01 upgrade` again"
        );
        return;
    }

    let result = (|| -> Result<locus_kit::kg_fact_identity_backfill::KGFactIdentityBackfillReport, String> {
        // The estate_id here is transient — the manifest holds the canonical
        // estate uuid; this value only satisfies the config constructor
        // (same convention as SqliteDrawerStore::from_path).
        let config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: estate.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        );
        let storage = SqliteStorage::new(config).map_err(|e| e.to_string())?;
        // The class-B resolver is vault-kit's stable-source-key hash,
        // injected here because locus-kit sits below vault-kit and must not
        // depend on it.
        let report = locus_kit::kg_fact_identity_backfill::run(
            &storage,
            &|key| vault_kit::drawer_mapping::DrawerMapping::lineage_id(key),
        )
        .map_err(|e| e.to_string())?;
        let _ = storage.close();
        Ok(report)
    })();

    // Put the daemon back over the (possibly migrated) estate before
    // reporting, mirroring the encryption leg's ordering.
    if was_running {
        let _ = daemon_start();
    }

    match result {
        Ok(report) => {
            if report.scanned == 0 {
                println!("  ✓ kg_facts identity columns: nothing to backfill");
            } else {
                println!(
                    "  ✓ kg_facts identity backfill: {} scanned — addedBy {}, foreignSourceKey {}, foreignRecordID {}, local anchors kept {} (sensitivity inherited {}), unclassified {}",
                    report.scanned,
                    report.host_identities,
                    report.foreign_palace_keys,
                    report.triple_ids,
                    report.local_drawer_ids,
                    report.inheritance_applied,
                    report.unclassified
                );
            }
        }
        Err(e) => {
            println!(
                "  ✗ kg_facts identity backfill failed: {e}\n    Every row remains findable in its current shape. Run `mootx01 upgrade` to retry."
            );
        }
    }
}

/// P5 of the shared-content 1.0→1.1 migration: WAL checkpoint + VACUUM for
/// any estate stranded in the `reclaimPending` state — typically because a
/// previous `mootx01 upgrade` was interrupted before physical reclamation
/// completed. Idempotent: estates already at `complete` (or not yet migrated
/// to P4) are silently skipped. Retryable on failure.
///
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling): no
/// detection or prompting lives anywhere else. Unattended and
/// non-interactive — a correctness migration must also converge
/// scripted/service upgrades.
///
/// Opens through `EstateCoordinator` rather than `SqliteStorage` alone
/// because `complete_shared_content_reclaim` uses the coordinator's
/// migration-host seam. Encryption is handled automatically:
/// `SqliteDrawerStore::from_path` → `SqliteStorage::new` adopts the sibling
/// `db.key` on its own, so keyed and plaintext estates both open correctly.
fn run_shared_content_reclaim_if_pending() {
    use genius_locus_kit::EstateCoordinator;
    use genius_locus_kit_migrations::SharedContentMigrationExt;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use std::sync::Arc;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    // Absent estate means first run — serve creates new estates post-cutover;
    // there is nothing to reclaim.
    if !estate.exists() {
        return;
    }

    // Quiesce first (single-writer discipline, same direction as the
    // kg_facts identity backfill): if the daemon will not stop, skip —
    // nothing is half-done, and the next `mootx01 upgrade` retries.
    let was_running = daemon_is_running();
    if was_running && !daemon_stop() {
        println!(
            "  ✗ shared-content reclaim skipped — the resident daemon would not stop; run `mootx01 upgrade` again"
        );
        return;
    }

    // Geometry normalization must precede the estate connection, exactly as in
    // `EstateRegistry::new_sqlite`. VACUUM fails on foreign geometry (file-header
    // byte 20 != 0, as written by Apple's SEE-provisioned sqlite3) with
    // SQLITE_CANTOPEN — "unable to open database: " with an empty filename — and
    // this path never runs the migration catalog, whose Step 0 would otherwise
    // normalize. Normalizing BEFORE the open (rather than mid-flight) is what keeps
    // the connection on the canonical path: normalization swaps the file by rename,
    // so a connection opened first would be left on the unlinked inode.
    //
    // No-op once the geometry is already correct. A failure here is logged and the
    // reclaim proceeds: the VACUUM below surfaces the real error and leaves the
    // record at ReclaimPending for the next `mootx01 upgrade`.
    if let Err(e) = genius_locus_kit_migrations::run_geometry_normalization(&estate) {
        println!("  ! geometry normalization did not run: {e:?}");
    }

    let now = wall_now_millis();
    let result = (|| -> Result<Option<persistence_kit::maintenance::MaintenanceReport>, String> {
        let sqlite_store = SqliteDrawerStore::from_path(
            &estate.display().to_string(),
            now,
            None,
            5.0,
        )
        .map_err(|e| e.to_string())?;
        let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
        let mut coord = EstateCoordinator::new();
        // The upgrade tool is not the estate's real owner; the substrate
        // validates only that ownerIdentifier is non-empty, so this
        // sentinel is sufficient.
        let handle = coord
            .open(store, OwnerCredentials::new("mootx01-upgrade"), 0, 100)
            .map_err(|e| format!("{e:?}"))?;
        let report = coord
            .complete_shared_content_reclaim(&handle, now)
            .map_err(|e| format!("{e:?}"))?;
        Ok(report)
    })();

    // Put the daemon back before reporting, mirroring the kg_facts
    // identity backfill ordering.
    if was_running {
        let _ = daemon_start();
    }

    match result {
        Ok(Some(report)) => {
            if report.reclaimed_bytes > 0 {
                println!(
                    "  ✓ shared-content reclaim: {} bytes returned to filesystem",
                    report.reclaimed_bytes
                );
            } else {
                println!(
                    "  ✓ shared-content reclaim: complete (maintenance ran, no pages to reclaim)"
                );
            }
        }
        Ok(None) => {
            println!("  ✓ shared-content reclaim: not pending");
        }
        Err(e) => {
            // The closure covers storage open, coordinator open, and the actual
            // complete_shared_content_reclaim call — Err is reachable from any
            // step. When the trim committed before the failure, freed pages remain
            // on the freelist; the next `mootx01 upgrade` retries the VACUUM.
            println!(
                "  ✗ shared-content reclaim failed: {e}\n    \
                 If the inventory trim committed before this failure, freed pages remain\n    \
                 on the freelist until a VACUUM completes. Run `mootx01 upgrade` to retry."
            );
        }
    }
}

/// CE-1.0.35-08 (Rust leg): offer to encrypt an unencrypted active estate.
///
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling): no
/// detection or prompting lives anywhere else. A plaintext estate reaches
/// this leg two ways: an estate created before the sibling `db.key`
/// convention existed (it serves plaintext silently), or a plaintext estate
/// file migrated in from a macOS install (it fails `PRAGMA key` looking
/// like corruption). Both end here. TTY-gated: a non-interactive invocation
/// never prompts and never migrates. Declining is a clean no-op.
fn offer_estate_encryption_if_needed() {
    use std::io::IsTerminal;

    use aria_mcp::estate_migration as migration;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);

    // Only a readable plaintext estate qualifies. Absent means first run
    // (serve creates new estates keyed); ciphertext means done.
    if migration::detect_estate_file_state(&estate) != migration::EstateFileState::Plaintext {
        return;
    }
    // Non-TTY invocations skip the offer silently and never migrate.
    if !io::stdin().is_terminal() {
        return;
    }

    println!(
        "\nYour memory estate at {}\n\
         is not encrypted at rest. mootx01 can encrypt it now: the estate is\n\
         cloned into an encrypted copy, verified row-for-row, and swapped in\n\
         at the same path. Your original is kept beside it until you delete it.",
        estate.display()
    );
    print!("Encrypt the estate now? Type 'yes' to confirm: ");
    let _ = io::stdout().flush();
    let mut line = String::new();
    let _ = io::stdin().lock().read_line(&mut line);
    if line.trim() != "yes" {
        println!("Leaving the estate as it is. Run `mootx01 upgrade` again any time to encrypt it.");
        return;
    }

    // Key custody: the sibling db.key convention — the same key
    // `SqliteStorage` resolves on every open, minted here if absent.
    //
    // Track whether THIS run minted it: every failure exit below rolls a
    // freshly-minted key back. Leaving it beside the still-plaintext estate
    // is a mismatched state — every subsequent open resolves the key
    // against a plaintext file and fails, so the estate is unopenable until
    // a retry succeeds (Codex 5ca9538f). A PREEXISTING key is never
    // touched: deleting it would orphan every encrypted estate it opens.
    let estates_dir = estate.parent().unwrap_or(&data).to_path_buf();
    let key_path = estates_dir.join(aria_mcp::INSTALL_KEY_FILE);
    let key_preexisted = key_path.exists();
    let rollback_minted_key = || {
        if !key_preexisted {
            let _ = std::fs::remove_file(&key_path);
        }
    };
    let key = match aria_mcp::ensure_install_key(&estates_dir) {
        Ok(k) => k,
        Err(e) => {
            rollback_minted_key();
            println!(
                "Could not provision an encryption key ({e}).\n\
                 Nothing was changed; the estate is untouched."
            );
            return;
        }
    };

    // Quiesce FIRST (never lose data): no write may land in the original
    // once the clone exists. Refusing to proceed when the daemon will not
    // stop is the safe direction — nothing has been touched yet.
    let was_running = daemon_is_running();
    if was_running && !daemon_stop() {
        rollback_minted_key();
        println!(
            "The resident daemon would not stop; nothing was changed.\n\
             Stop it manually and run `mootx01 upgrade` again."
        );
        return;
    }

    println!("Encrypting the estate\u{2026}");
    let copy = estate.with_file_name(format!(
        "{}.encrypting",
        estate.file_name().unwrap_or_default().to_string_lossy()
    ));
    // A stale copy from an interrupted earlier run is untrusted by
    // definition — regenerate rather than resume.
    migration::remove_database(&copy);

    let outcome = migration::export_encrypted_copy(&estate, &copy, &key)
        .and_then(|()| migration::verify_encrypted_copy(&estate, &copy, &key))
        .and_then(|counts| {
            migration::swap_in_encrypted_copy(&estate, &copy).map(|swap| (counts, swap))
        });

    match outcome {
        Ok((counts, swap)) => {
            let restarted = if was_running { daemon_start() } else { true };
            println!("  ✓ Estate encrypted in place at {}", estate.display());
            println!("  ✓ Verified: {counts}");
            if was_running && !restarted {
                println!(
                    "  ✗ The daemon did not restart cleanly. Restart it manually,\n\
                       or run: mootx01 serve --http auto"
                );
            } else if was_running {
                println!("  ✓ Daemon restarted over the encrypted estate.");
            }
            println!(
                "  ✓ Your original estate was kept at:\n    {}\n    \
                 That copy is STILL UNENCRYPTED \u{2014} deleting it is the final\n    \
                 step of this migration, not optional cleanup.",
                swap.retained_original.display()
            );
        }
        Err(e) => {
            // Every failure path left the plaintext original at the
            // canonical path; roll back a key this run minted, then put the
            // daemon back over the original. Order matters: the daemon's
            // startup resolves the sibling key, so the mismatched
            // key-beside-plaintext state must be gone before it opens.
            rollback_minted_key();
            if was_running {
                let _ = daemon_start();
            }
            println!(
                "Migration failed: {e}\n\
                 Your estate is still the plaintext original at {}.",
                estate.display()
            );
            if key_preexisted {
                // With a preexisting key beside a plaintext estate, encrypted
                // opens were already failing before this run — do not claim
                // otherwise.
                println!(
                    "Note: an encryption key (db.key) that predates this run exists beside\n\
                     the estate; the daemon cannot open the estate until the migration\n\
                     succeeds. Run `mootx01 upgrade` to try again."
                );
            } else {
                println!(
                    "The encryption key created for this run was removed; the estate\n\
                     opens exactly as before. Run `mootx01 upgrade` to try again."
                );
            }
        }
    }
}

/// Current wall-clock time as milliseconds since the Unix epoch.
///
/// Defined locally because `aria_mcp::estate_registry::wall_now_millis` is a
/// bare private function (not accessible from this crate). The reference
/// implementation's `i64::MAX` overflow guard is preserved here.
fn wall_now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}

/// Platform daemon control for the migration's stop → swap → start
/// sequence. Linux: the systemd unit. Windows: the scheduled task. Other
/// platforms report "not running" so the migration never tries to manage a
/// daemon it has no control surface for (the user was told to check).
fn daemon_is_running() -> bool {
    #[cfg(target_os = "linux")]
    {
        crate::core::service::is_active(crate::core::service::DAEMON_UNIT)
    }
    #[cfg(target_os = "windows")]
    {
        crate::core::service::is_task_running(crate::core::service::DAEMON_TASK)
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    false
}

fn daemon_stop() -> bool {
    #[cfg(target_os = "linux")]
    {
        crate::core::service::stop(crate::core::service::DAEMON_UNIT).is_ok()
    }
    #[cfg(target_os = "windows")]
    {
        crate::core::service::stop_task(crate::core::service::DAEMON_TASK).is_ok()
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    true
}

fn daemon_start() -> bool {
    #[cfg(target_os = "linux")]
    {
        crate::core::service::restart(crate::core::service::DAEMON_UNIT).is_ok()
    }
    #[cfg(target_os = "windows")]
    {
        crate::core::service::restart_task(crate::core::service::DAEMON_TASK).is_ok()
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    true
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

    /// Source-invariant: the Err handler in `run_shared_content_reclaim_if_pending`
    /// must provide accurate context for the operator — referencing the inventory
    /// trim and freelist state — without asserting RC-01's misleading claim.
    ///
    /// Uses `concat!()` to build search patterns at compile time so the assembled
    /// strings do not appear as literals in this file — preventing the assertion
    /// text from self-matching when `include_str!` reads the file back.
    #[test]
    fn reclaim_failure_message_names_vacuum_not_estate_unaffected() {
        let src = include_str!("upgrade.rs");
        // Positive: Err handler must reference the inventory trim for operator context.
        assert!(
            src.contains(concat!("inventory trim", " committed")),
            "Err handler must reference the inventory trim"
        );
        // Positive: Err handler must mention freed pages on the freelist.
        assert!(
            src.contains(concat!("freelist", " until a VACUUM")),
            "Err handler must mention freed pages on the freelist"
        );
        // Negative: the old misleading RC-01 phrase must be absent from the Err handler.
        // Assertion message phrased to avoid the literal target substring.
        assert!(
            !src.contains(concat!("estate is", " unaffected")),
            "Err handler must report the reclaim failure accurately — trim has committed"
        );
    }

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
