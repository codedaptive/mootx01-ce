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

pub fn run(
    from: Option<String>,
    check: bool,
    yes: bool,
    no_restart: bool,
    converge_only: bool,
    backfill_only: bool,
) -> ExitCode {
    let home = super::install::home_dir();

    // --converge-only: we ARE the freshly installed binary, re-executed by the
    // upgrade that placed us. Run the convergence steps and nothing else.
    if converge_only {
        run_convergence();
        return ExitCode::from(exit::OK);
    }

    // --backfill-only: headless data-dir convergence for scripted and benchmark
    // estates. Runs the six data-directory migration steps (schema 10 → 19,
    // kg_facts identity, shared-content reclaim, dense pooling convergence,
    // span encode, vector reclaim) against the estate resolved via
    // MOOTX01_DATA_DIR, then exits. No network, no prompts; each step
    // quiesces the daemon only when the estate is the resident one. Ordering
    // matches run_convergence: schema gate → correctness migration →
    // VACUUM-backed reclaim → dense pooling convergence → span encode →
    // vector reclaim. A refused schema version stops the sequence (every later
    // step would open the schema and stamp it); otherwise all steps run even
    // when earlier steps fail (independent + retryable) and the exit is
    // non-zero when any step reported failure.
    if backfill_only {
        if !run_schema_upgrade() {
            return ExitCode::from(exit::FAILURE);
        }
        let ok_kg    = run_kg_fact_identity_backfill();
        let ok_recl  = run_shared_content_reclaim_if_pending();
        let ok_facts = run_ssc_facts_backfill();
        let ok_dense = run_dense_pooling_convergence();
        let ok_span  = run_span_encode_backfill();
        let ok_vec   = run_vector_reclaim();
        if ok_kg && ok_recl && ok_facts && ok_dense && ok_span && ok_vec {
            return ExitCode::from(exit::OK);
        } else {
            return ExitCode::from(exit::FAILURE);
        }
    }

    // Local-build path: --from skips the online check entirely.
    if let Some(path) = from {
        let src = PathBuf::from(&path);
        if !src.exists() {
            eprintln!("mootx01 upgrade: no binary at {path}");
            return ExitCode::from(exit::FAILURE);
        }
        let code = place_and_report(&src, &home, no_restart);
        if code == ExitCode::from(exit::OK) {
            converge_after_install(&home, no_restart);
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
            // the up-to-date early return still runs all migration steps and offers.
            if run_schema_upgrade() {
                run_kg_fact_identity_backfill();
                run_shared_content_reclaim_if_pending();
                run_ssc_facts_backfill();
                run_dense_pooling_convergence();
                run_span_encode_backfill();
                run_vector_reclaim();
            }
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
        converge_after_install(&home, no_restart);
        offer_estate_encryption_if_needed();
    }
    code
}

/// The post-install convergence steps, run in the binary that was JUST
/// INSTALLED rather than in this image.
///
/// Without the re-execution every step here would run the version being
/// replaced, so a fix to any of them could never apply on the run that
/// installed it — operators had to run `mootx01 upgrade` twice, and the
/// messages they read came from the old binary.
///
/// Falls back to converging in THIS image when the installed binary cannot be
/// executed or exits non-zero, so a failed re-exec never leaves an upgrade less
/// converged than before.
///
/// NOTE ON REACH: this only helps when the ALREADY-INSTALLED binary carries it.
/// Upgrading FROM a version without this logic still converges with that old
/// version's code — the installer cannot be fixed from the release it installs.
fn converge_after_install(home: &std::path::Path, no_restart: bool) {
    // Same destination `release::place_binary` writes to.
    #[cfg(not(target_os = "windows"))]
    let installed = home.join(".mootx01/bin/mootx01");
    #[cfg(target_os = "windows")]
    let installed = home.join(".mootx01/bin/mootx01.exe");
    if reexec_convergence(&installed, no_restart) {
        return;
    }
    println!("Note: converging with the previous binary — the installed one could not run.");
    run_convergence();
}

/// Re-execute `binary` with `--converge-only`. Returns false when it could not
/// be launched or exited non-zero.
///
/// stdout/stderr are inherited so the child's progress appears inline as one
/// continuous transcript; stdout is flushed first because it is block-buffered
/// whenever it is not a TTY, which would otherwise place this process's lines
/// after the child's. `--yes` is passed so the pass never waits on a prompt and
/// `--no-restart` is forwarded so the flag keeps its meaning across the boundary.
fn reexec_convergence(binary: &std::path::Path, no_restart: bool) -> bool {
    use std::io::Write;
    if !binary.exists() {
        return false;
    }
    let mut args: Vec<&str> = vec!["upgrade", "--converge-only", "--yes"];
    if no_restart {
        args.push("--no-restart");
    }
    let _ = std::io::stdout().flush();
    match std::process::Command::new(binary).args(&args).status() {
        Ok(status) if status.success() => true,
        Ok(status) => {
            println!("Note: the installed binary exited {status} during convergence.");
            false
        }
        Err(e) => {
            println!("Note: could not execute the installed binary ({e}).");
            false
        }
    }
}

/// The convergence sequence itself, in order. The migration steps and the reclaim
/// both need a quiesced estate; the reclaim additionally repairs foreign SQLite
/// geometry before its VACUUM.
fn run_convergence() {
    // Return values are intentionally ignored in the full convergence path —
    // each step is independent and retryable; the next `mootx01 upgrade` catches failures.
    // A refused schema version skips every data step: each of them would
    // open the LocusKit schema and stamp the estate current.
    if run_schema_upgrade() {
        let _ = run_kg_fact_identity_backfill();
        let _ = run_shared_content_reclaim_if_pending();
        let _ = run_dense_pooling_convergence();
        let _ = run_span_encode_backfill();
        let _ = run_vector_reclaim();
    }
    run_corpus_counts_migration();
    remove_redundant_codex_direct_entry();
}

/// Schema 10 → 19 (ENCODER_RERANK_CONTRACT §12): the one product schema
/// migration. Reads the LocusKit ledger row RAW, before any schema open, and
/// decides with `locus_kit::schema::upgrade_path`: 10 (CE 1.0.35/1.0.37) →
/// open the LocusKit schema, which applies the single v10 → v19 hop; 19 →
/// nothing; no row → fresh; anything else → REFUSE, naming the version
/// found, and return false so the caller skips every later step. The refusal
/// must come first because persistence-kit's runner stamps the declared
/// version whenever no ladder entry matches: any later step's open would mark
/// an estate at 11–18 as 19 with none of the v19 objects in place. Pre-release
/// development estates at 18 are moved by the surgery script, never by this
/// command. Twin of Swift `UpgradeCommand.runSchemaUpgrade`.
///
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
/// Returns `true` when the estate is at 19 afterwards (or absent).
fn run_schema_upgrade() -> bool {
    use locus_kit::schema::{self, SchemaUpgradePath};
    use persistence_kit::sqlite::SqliteStorage;
    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
    use uuid::Uuid;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    // Absent estate means first run — serve creates new estates at 19.
    if !estate.exists() {
        return true;
    }
    let Some(ok) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "schema upgrade",
        &PlatformDaemon,
        || {
            let result = (|| -> Result<String, String> {
                let config = EstateConfiguration::new(
                    Uuid::new_v4(),
                    BackendConfiguration::Sqlite {
                        path: estate.display().to_string(),
                        busy_timeout_secs: 5.0,
                    },
                );
                let storage = SqliteStorage::new(config).map_err(|e| e.to_string())?;
                // The ledger row, read before any schema open (see the doc comment).
                let stored = storage
                    .current_schema_version_for(schema::KIT_ID)
                    .map_err(|e| e.to_string())?;
                let outcome = match schema::upgrade_path(stored) {
                    SchemaUpgradePath::Unsupported { found } => Err(format!(
                        "refused: this estate is at LocusKit schema {found}.\n    This build upgrades schema {} (CE 1.0.35/1.0.37) and serves schema {}; nothing was changed.\n    A pre-release development estate at 11–18 is moved to 19 by the schema surgery script, not by this build; a newer estate needs a newer build.",
                        schema::SUPPORTED_UPGRADE_FLOOR,
                        schema::SCHEMA_VERSION
                    )),
                    SchemaUpgradePath::Current => Ok(format!(
                        "already at LocusKit schema {}",
                        schema::SCHEMA_VERSION
                    )),
                    SchemaUpgradePath::Fresh => Ok(format!(
                        "no LocusKit ledger row; schema {} is created on the first open",
                        schema::SCHEMA_VERSION
                    )),
                    SchemaUpgradePath::Upgrade { from } => {
                        storage.open(&schema::schema()).map_err(|e| e.to_string())?;
                        let after = storage
                            .current_schema_version_for(schema::KIT_ID)
                            .map_err(|e| e.to_string())?;
                        if after != schema::SCHEMA_VERSION {
                            Err(format!(
                                "expected LocusKit schema {} after the hop, found {after}. Run `mootx01 upgrade` to retry.",
                                schema::SCHEMA_VERSION
                            ))
                        } else {
                            Ok(format!(
                                "LocusKit {from} → {after} (encoder_models, ssc_facts, subject trio, kg_facts identity trio, operationalAND, idx_drawers_filedAt, recall_trace attribution)"
                            ))
                        }
                    }
                };
                let _ = storage.close();
                outcome
            })();
            match result {
                Ok(msg) => {
                    println!("  ✓ schema: {msg}");
                    true
                }
                Err(e) => {
                    println!("  ✗ schema upgrade {e}");
                    false
                }
            }
        },
    ) else {
        return false;
    };
    ok
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
/// Returns `true` when the step completes (or determines there is nothing to do),
/// `false` when it fails. The caller decides whether to continue or aggregate the failure.
fn run_kg_fact_identity_backfill() -> bool {
    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
    use persistence_kit::sqlite::SqliteStorage;
    use uuid::Uuid;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    // Absent estate means first run — serve creates new estates post-KH;
    // there is nothing to backfill.
    if !estate.exists() {
        return true;
    }

    // Single-writer discipline: the resident daemon is stopped around the
    // work only when this is its estate (the helper prints why when it is
    // not). `None` means the daemon would not stop; the step is skipped
    // and the next `mootx01 upgrade` retries.
    let Some(result) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "kg_facts identity backfill",
        &PlatformDaemon,
        || {
        (|| -> Result<locus_kit::kg_fact_identity_backfill::KGFactIdentityBackfillReport, String> {
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
        })()
        },
    ) else {
        return false;
    };

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
            return false;
        }
    }
    true
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
///
/// Bring the dense distributional lanes (random-indexing, PPMI, NMF, LSA)
/// onto the basis format this binary's codec writes. A basis row persisted
/// under an earlier format version holds vectors pooled the old way; the
/// corpus opens such a slot untrained and its open-time provider reconcile
/// retrains it from the estate's content and re-embeds every row. This step
/// runs that rebuild here, under the daemon quiesce, so it happens at upgrade
/// time and is reported, rather than on the next serve open.
///
/// Eligibility is a raw read of `corpus_provider_basis`: any part-0 row whose
/// frame version byte differs from `BASIS_FORMAT_VERSION`. An estate with no
/// such table (it never held a trained basis) or with every row current is
/// skipped. Idempotent: after one pass every row carries the current version
/// and the step is a no-op. Runs BEFORE the span-encode step so that
/// step's open does not absorb the rebuild unreported.
/// Twin of Swift `UpgradeCommand.runDensePoolingConvergence`.
///
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
/// Returns `true` on success or when there is nothing to converge, `false` on failure.
fn run_dense_pooling_convergence() -> bool {
    use corpus_kit_providers::BASIS_FORMAT_VERSION;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    if !estate.exists() {
        return true;
    }
    // Eligibility: a single read of the basis frames, before any quiesce.
    let stale = match stale_format_basis_providers(&estate) {
        Ok(stale) => stale,
        Err(e) => {
            println!(
                "  ✗ dense pooling convergence: could not read corpus_provider_basis: {e}\n    Run `mootx01 upgrade` to retry."
            );
            return false;
        }
    };
    if stale.is_empty() {
        println!("  ✓ dense pooling: provider bases already at basis format v{BASIS_FORMAT_VERSION}");
        return true;
    }
    // Single-writer discipline: the resident daemon is stopped around the
    // work only when this is its estate (the helper prints why when it is
    // not). `None` means the daemon would not stop; the step is skipped and
    // the next `mootx01 upgrade` retries.
    let Some(ok) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "dense pooling convergence",
        &PlatformDaemon,
        || {
            let result = (|| -> Result<Vec<String>, String> {
                // Maintenance open: skips default-wing seeding so upgrade never
                // creates content. Opening wires the corpus, which runs the
                // provider reconcile: every slot whose persisted basis was
                // refused for format skew opens untrained, retrains from the
                // estate's content, and re-covers every row under the new basis
                // before the open returns. Dropping the registry stops and joins
                // the drain worker.
                let reg = aria_mcp::estate_registry::EstateRegistry::new_sqlite_for_maintenance(
                    &estate.display().to_string(),
                    "aria-mcp-default",
                )?;
                drop(reg);
                stale_format_basis_providers(&estate)
            })();
            match result {
                Ok(remaining) if remaining.is_empty() => {
                    println!(
                        "  ✓ dense pooling convergence: {} retrained to basis format v{BASIS_FORMAT_VERSION}; dense vectors re-embedded",
                        stale.join(", ")
                    );
                    true
                }
                Ok(remaining) => {
                    println!(
                        "  ✗ dense pooling convergence: {} still at an earlier basis format after the rebuild.\n    Run `mootx01 upgrade` to retry.",
                        remaining.join(", ")
                    );
                    false
                }
                Err(e) => {
                    println!(
                        "  ✗ dense pooling convergence failed: {e}\n    Recall keeps serving through the lexical and stateless lanes; the stale dense slots stay untrained until the rebuild completes. Run `mootx01 upgrade` to retry."
                    );
                    false
                }
            }
        },
    ) else {
        return false;
    };
    ok
}

/// Provider keys (`model_id@model_version`) whose part-0 basis row carries a
/// frame version other than `BASIS_FORMAT_VERSION`, sorted. Empty when the
/// table is absent (an estate that never held a trained basis) or every row
/// is current. Opens the estate SQLite directly (no schema ladder); the
/// sibling `db.key` is adopted automatically for encrypted estates.
fn stale_format_basis_providers(estate: &std::path::Path) -> Result<Vec<String>, String> {
    use corpus_kit_providers::BASIS_FORMAT_VERSION;
    use persistence_kit::predicate::StoragePredicate;
    use persistence_kit::sqlite::SqliteStorage;
    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
    use persistence_kit::types::{Column, TypedValue};
    use uuid::Uuid;

    let config = EstateConfiguration::new(
        Uuid::new_v4(),
        BackendConfiguration::Sqlite {
            path: estate.display().to_string(),
            busy_timeout_secs: 5.0,
        },
    );
    let storage = SqliteStorage::new(config).map_err(|e| e.to_string())?;
    let predicate = StoragePredicate::Eq(
        Column::new("corpus_provider_basis", "part_index"),
        TypedValue::Int(0),
    );
    // No basis table: the estate predates persisted bases, so there is no
    // dense lane to converge (the same skip the counts migration makes).
    let Ok(rows) = storage
        .row_store()
        .query("corpus_provider_basis", Some(&predicate), &[], None, None)
    else {
        return Ok(Vec::new());
    };
    let mut stale = Vec::new();
    for row in &rows {
        let (Some(TypedValue::Text(model_id)), Some(TypedValue::Text(model_version)), Some(TypedValue::Blob(basis))) =
            (row.get("model_id"), row.get("model_version"), row.get("basis"))
        else {
            continue;
        };
        if corpus_kit::basis_blob_frame::format_version(basis) != Some(BASIS_FORMAT_VERSION) {
            stale.push(format!("{model_id}@{model_version}"));
        }
    }
    stale.sort();
    Ok(stale)
}

/// Span encode (ENCODER_RERANK_CONTRACT §10, §12): encode spans for every
/// drawer whose bit 27 is clear under the ACTIVE registry row, so a freshly
/// upgraded estate reranks from its first query instead of waiting for the
/// REM-ALPHA duty. The estate is opened through the registry's maintenance
/// path first, which runs the migration chain (it moves the vector tier's
/// ledger rows to their SynapseKit ids before any store opens under the new
/// id) and wires the corpus; the batch work then runs through
/// `span_encode_backfill::run`, which is the duty's batch function until the
/// NeuronKit duty lands. No active model, or a model whose directory or vocab
/// check fails, is a clean skip: recall stays lexical-only and the next
/// upgrade retries. Twin of Swift `UpgradeCommand.runSpanEncodeBackfill`.
///
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
/// Upgrade never creates content: spans are derived rows, not drawers.
/// Returns `true` on success or when there is nothing to encode.
fn run_span_encode_backfill() -> bool {
    use super::span_encode_backfill::{self, SpanEncodeReport};
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    if !estate.exists() {
        return true;
    }
    let Some(ok) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "span encode",
        &PlatformDaemon,
        || {
            let now = wall_now_millis();
            let result = (|| -> Result<SpanEncodeReport, String> {
                // Maintenance open: runs the migration chain and wires the
                // corpus without seeding content (upgrade never creates content).
                let reg = aria_mcp::estate_registry::EstateRegistry::new_sqlite_for_maintenance(
                    &estate.display().to_string(),
                    "aria-mcp-default",
                )?;
                drop(reg);
                let store = SqliteDrawerStore::from_path(&estate.display().to_string(), now, None, 5.0)
                    .map_err(|e| e.to_string())?;
                // Migration writes the activation key: a CE 1.0.x estate arrives
                // at 19 with no `embedding_provider`, and only `provision` and
                // this upgrade step ever write it (Bob's ruling, 2026-09-06).
                // The next serve open reads it and activates the encoder.
                // Swift twin: UpgradeCommand.runSpanEncodeBackfill →
                // provisionDefaultEncoderIfAbsent.
                let key = genius_locus_kit::EstateCoordinator::EMBEDDING_PROVIDER_META_KEY;
                let absent = store
                    .get_meta(key)
                    .map_err(|e| e.to_string())?
                    .map(|v| v.is_empty())
                    .unwrap_or(true);
                if absent {
                    store
                        .set_meta(key, genius_locus_kit::EstateCoordinator::ENCODER_PROVIDER_ID)
                        .map_err(|e| e.to_string())?;
                    println!("  ✓ encoder: span encoder is now the default recall stage (embedding_provider = encoder)");
                }
                let storage = store.storage().ok_or("drawer store exposes no storage")?;
                span_encode_backfill::run(storage, &store, &data, now)
            })();
            match result {
                Ok(SpanEncodeReport::NoActiveModel) => {
                    println!("  ✓ span encode: no active encoder model registered; recall stays lexical-only");
                    true
                }
                Ok(SpanEncodeReport::ModelUnavailable(reason)) => {
                    println!("  ✓ span encode: encoder unavailable ({reason}); recall stays lexical-only until the model ships");
                    true
                }
                Ok(SpanEncodeReport::Encoded { drawers: 0, remaining: 0, .. }) => {
                    println!("  ✓ span encode: every drawer is indexed under the active model");
                    true
                }
                Ok(SpanEncodeReport::Encoded { drawers, spans, remaining }) => {
                    println!("  ✓ span encode: {drawers} drawer(s), {spans} span(s) written; {remaining} drawer(s) still owed");
                    true
                }
                Err(e) => {
                    println!(
                        "  ✗ span encode failed: {e}\n    Recall keeps serving lexical-only; the duty encodes the remaining drawers. Run `mootx01 upgrade` to retry."
                    );
                    false
                }
            }
        },
    ) else {
        return false;
    };
    ok
}

/// Models whose vector rows `mootx01 upgrade` reclaims: the dense
/// distributional families the Encoder Rerank Program took dark
/// (`dense-families` feature off). Their rows serve nothing at 19.
const RETIRED_DENSE_FAMILY_MODEL_IDS: [&str; 4] = ["lsa-v1", "nmf-v1", "ppmi-v1", "fdc-v1"];

/// Reclaim the vector rows nothing serves at schema 19 (ENCODER_RERANK
/// CONTRACT §12): every row of the retired dense families and every row at a
/// non-serving generation, then a VACUUM when anything was deleted. Opened
/// through the registry's maintenance path first for the same ledger-id
/// reason as the span-encode step. Idempotent: a reclaimed estate deletes
/// nothing and skips the VACUUM. Twin of Swift `UpgradeCommand.runVectorReclaim`.
///
/// `mootx01 upgrade` is the ONLY migration vehicle (Bob's ruling).
/// Returns `true` on success or when there is nothing to reclaim.
fn run_vector_reclaim() -> bool {
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
    use synapsekit::VectorStore;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    if !estate.exists() {
        return true;
    }
    let Some(ok) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "vector reclaim",
        &PlatformDaemon,
        || {
            let now = wall_now_millis();
            let result = (|| -> Result<(usize, usize, i64), String> {
                let reg = aria_mcp::estate_registry::EstateRegistry::new_sqlite_for_maintenance(
                    &estate.display().to_string(),
                    "aria-mcp-default",
                )?;
                drop(reg);
                let store = SqliteDrawerStore::from_path(&estate.display().to_string(), now, None, 5.0)
                    .map_err(|e| e.to_string())?;
                let storage = store.storage().ok_or("drawer store exposes no storage")?;
                let vectors = VectorStore::new(std::sync::Arc::clone(&storage), None);
                let (retired, non_serving) = vectors
                    .reclaim_retired_vector_rows(&RETIRED_DENSE_FAMILY_MODEL_IDS)
                    .map_err(|e| format!("{e:?}"))?;
                let mut reclaimed_bytes = 0i64;
                if retired + non_serving > 0 {
                    reclaimed_bytes = storage
                        .perform_maintenance(None, None)
                        .map_err(|e| format!("{e:?}"))?
                        .reclaimed_bytes;
                }
                Ok((retired, non_serving, reclaimed_bytes))
            })();
            match result {
                Ok((0, 0, _)) => {
                    println!("  ✓ vector reclaim: nothing to reclaim");
                    true
                }
                Ok((retired, non_serving, bytes)) => {
                    println!("  ✓ vector reclaim: {retired} retired-family row(s), {non_serving} non-serving row(s) deleted; {bytes} bytes returned to filesystem");
                    true
                }
                Err(e) => {
                    println!("  ✗ vector reclaim failed: {e}\n    Every serving row is untouched. Run `mootx01 upgrade` to retry.");
                    false
                }
            }
        },
    ) else {
        return false;
    };
    ok
}

/// Write SSC facts for every drawer that owes them and rebuild the BM25
/// documents when any were written (Encoder Rerank contract sheet §6).
///
/// A live estate never accrues facts debt: the capture path writes a
/// drawer's facts before the drawer is encoded. An estate migrated from an
/// earlier schema arrives with every `ssc_facts` NULL and with BM25
/// documents composed under the earlier scheme, so this step pays the debt
/// once (`EstateCoordinator::backfill_ssc_facts`) and, when it wrote
/// anything, rebuilds every derived lane (`reindex_corpus`) so the
/// supplement reaches the posting lists. A converged estate writes nothing
/// and skips the rebuild. Runs after the schema upgrade and the
/// shared-content reclaim, before the dense pooling convergence, so the
/// rebuild happens once under the final schema. Twin of Swift
/// `UpgradeCommand.runSSCFactsBackfill`.
///
/// Returns `true` on success or when there is nothing to write.
fn run_ssc_facts_backfill() -> bool {
    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    if !estate.exists() {
        return true;
    }
    let Some(ok) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "ssc facts backfill",
        &PlatformDaemon,
        || {
            let now = wall_now_millis();
            let result = (|| -> Result<usize, String> {
                // Maintenance open: runs the migration chain and wires the
                // corpus without seeding content (upgrade never creates content).
                let reg = aria_mcp::estate_registry::EstateRegistry::new_sqlite_for_maintenance(
                    &estate.display().to_string(),
                    "aria-mcp-default",
                )?;
                let guard = reg.coord.lock().map_err(|e| e.to_string())?;
                let written = guard.backfill_ssc_facts(&reg.default.handle).map_err(|e| format!("{e:?}"))?;
                if written > 0 {
                    guard.reindex_corpus(&reg.default.handle, now).map_err(|e| format!("{e:?}"))?;
                }
                Ok(written)
            })();
            match result {
                Ok(0) => {
                    println!("  ✓ ssc facts: every drawer already carries its facts");
                    true
                }
                Ok(written) => {
                    println!("  ✓ ssc facts: {written} drawer(s) written; BM25 and dense lanes rebuilt");
                    true
                }
                Err(e) => {
                    println!("  ✗ ssc facts backfill failed: {e}\n    Rows already written keep their facts. Run `mootx01 upgrade` to retry.");
                    false
                }
            }
        },
    ) else {
        return false;
    };
    ok
}

/// Returns `true` on success or when there is nothing to reclaim, `false` on failure.
fn run_shared_content_reclaim_if_pending() -> bool {
    use genius_locus_kit::EstateCoordinator;
    use genius_locus_kit_migrations::{SharedContentMigrationExt, SharedContentMigrationStore};
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use persistence_kit::Storage;
    use std::sync::Arc;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    // Absent estate means first run — serve creates new estates post-cutover;
    // there is nothing to reclaim.
    if !estate.exists() {
        return true;
    }

    // Single-writer discipline: the resident daemon is stopped around the
    // work only when this is its estate (the helper prints why when it is
    // not). `None` means the daemon would not stop; the step is skipped
    // and the next `mootx01 upgrade` retries.
    let Some(result) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "shared-content reclaim",
        &PlatformDaemon,
        || {
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
        (|| -> Result<Option<persistence_kit::maintenance::MaintenanceReport>, String> {
            let sqlite_store = SqliteDrawerStore::from_path(
                &estate.display().to_string(),
                now,
                None,
                5.0,
            )
            .map_err(|e| e.to_string())?;
            let store: Arc<dyn DrawerStore> = Arc::new(sqlite_store);
            let storage: Arc<dyn Storage> = store.storage().ok_or("drawer store exposes no storage")?;
            // Apply the ledger schema (CREATE TABLE IF NOT EXISTS) before reading
            // the reclaim record. An estate that never ran the shared-content
            // migration has no ledger table, and store.load() would throw
            // "no such table". Applying the declaration is a no-op once the table
            // exists.
            storage
                .migrate(&SharedContentMigrationStore::schema_declaration())
                .map_err(|e| format!("ledger schema apply: {e:?}"))?;
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
        })()
        },
    ) else {
        return false;
    };

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
            true
        }
        Ok(None) => {
            println!("  ✓ shared-content reclaim: not pending");
            true
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
            false
        }
    }
}

/// CORPUS-COUNTS-01: clear the legacy text-keyed vocab rows and zero the
/// stale PPMI counts blob so the next reindex starts from a clean slate.
///
/// ## What this step does
///
///   1. DELETE all rows from `corpus_provider_vocab` — the text-keyed v3 table
///      superseded by the v4 integer-keyed pair (`corpus_provider_term_dictionary`
///      + `corpus_provider_term_payload`). These are large blobs accumulated by
///      the distributional providers and are no longer read; keeping them wastes
///      disk and adds to every SQLite VACUUM's work.
///
///   2. UPDATE all rows in `corpus_provider_counts` SET counts = empty blob —
///      zeros the opaque provider-serialized counts blob, which has been
///      invalidated by the schema change. `doc_count` and `vocab_size` are
///      durable monotone anchors and are intentionally preserved.
///
///   3. Call `reindex_required()` at the tail to enqueue a reindex marker job
///      and set the estate-manifest latch. If the enqueue does not take (queue
///      not reachable), the deferral line is printed and the next upgrade retries.
///
/// ## Failure posture
///
/// The DELETE and UPDATE are both full-table passes executed synchronously.
/// If either fails (e.g. the table was never created because the estate
/// predates CorpusKit v2), the step logs and returns; nothing is half-done.
/// `mootx01 upgrade` is the only migration vehicle — the next run retries.
///
/// The estate-mutation core of the corpus-counts migration, extracted so a
/// test can drive the REAL operations on a scratch estate without the
/// daemon-quiesce wrapper (which acts on the machine-global daemon and must
/// never run from a test). `run_corpus_counts_migration` is quiesce + this
/// + restart + report; everything that touches estate bytes is HERE.
///
/// Operates through `SqliteStorage` (not `EstateCoordinator`), the same
/// surface used by `run_kg_fact_identity_backfill`. The estate and queue
/// SQLite files are opened independently; the core is NOT schema-aware and
/// does NOT run migrations — it touches only the two corpus tables that must
/// pre-exist, and the manifest key-value table via the latch.
pub(crate) fn corpus_counts_migration_core(
    estate_config: &persistence_kit::storage::EstateConfiguration,
    now_ms: i64,
) -> Result<(usize, usize), String> {
    use corpus_kit::reindex_latch::reindex_required;
    use persistence_kit::sqlite::SqliteStorage;
    use persistence_kit::storage::Storage;
    use persistence_kit::predicate::StoragePredicate;
    use persistence_kit::types::TypedValue;
    use queuekit::facade::QueueKit;
    use queuekit::persistencekit::PersistenceKitBackend;
    use std::collections::BTreeMap;
    use std::sync::Arc;

    let storage: Arc<dyn Storage> =
        Arc::new(SqliteStorage::new(estate_config.clone()).map_err(|e| e.to_string())?);


    // Step 1: DELETE all rows from `corpus_provider_vocab`.
    // This table was created in the v2→v3 migration and is superseded by the
    // v4 integer-keyed pair. If it never existed (estate predates v3) the
    // delete returns an error, which we surface as a skip — not a failure.
    let vocab_deleted = storage
        .row_store()
        .delete("corpus_provider_vocab", &StoragePredicate::IsTrue)
        .map_err(|e| format!("vocab table delete failed: {e:?}"))?;

    // Step 2: UPDATE all rows in `corpus_provider_counts` SET counts = INVALIDATED_COUNTS_SENTINEL.
    // Writing the named sentinel (an empty blob) marks the opaque per-provider accumulator as
    // invalid. The reader recognises the same sentinel through the shared `is_invalidated_counts`
    // predicate (corpus_provider_counts_store.rs) and returns Ok(false) — "start from zero" —
    // without calling any provider codec. Using the named constant instead of an ad-hoc vec![]
    // means the writer and reader share ONE definition and cannot drift independently.
    //
    // doc_count and vocab_size are NOT in `values` — update() touches ONLY the specified
    // columns, leaving the monotone anchors intact.
    let mut zero_counts: BTreeMap<String, TypedValue> = BTreeMap::new();
    zero_counts.insert(
        "counts".to_string(),
        TypedValue::Blob(
            corpus_kit::corpus_provider_counts_store::INVALIDATED_COUNTS_SENTINEL.to_vec(),
        ),
    );
    let counts_updated = storage
        .row_store()
        .update("corpus_provider_counts", zero_counts, &StoragePredicate::IsTrue)
        .map_err(|e| format!("counts blob zero failed: {e:?}"))?;

    // Step 2b: Read-back verification gate.
    // Immediately after the UPDATE, query every corpus_provider_counts row and confirm
    // the `counts` column is the invalidation sentinel. A mismatch means the storage
    // layer returned a shape the reader cannot interpret — a loud failure here is
    // recoverable (the user re-runs `mootx01 upgrade`); silent undecodable state on disk
    // is not (it surfaces later in recall, far from its cause).
    //
    // Empirically observed: SqliteStorage returns an empty blob as TypedValue::Blob(vec![])
    // — confirmed by the real-path test `corpus_counts_migration_core_clears_legacy_preserves_anchors_sets_latch`
    // which asserts exactly this shape post-update. The gate encodes this observation:
    // only Blob variants are checked against is_invalidated_counts; any other variant
    // is rejected immediately because it cannot be the sentinel.
    //
    // This gate does NOT open a Corpus or touch any CorpusKit engine machinery. It
    // operates on raw TypedValue rows through the same SqliteStorage surface used above.
    {
        let readback = storage
            .row_store()
            .query("corpus_provider_counts", None, &[], None, None)
            .map_err(|e| format!("counts read-back query failed: {e:?}"))?;
        for row in &readback {
            let model_id = row
                .get("model_id")
                .map(|v| format!("{v:?}"))
                .unwrap_or_else(|| "?".into());
            let model_version = row
                .get("model_version")
                .map(|v| format!("{v:?}"))
                .unwrap_or_else(|| "?".into());
            match row.get("counts") {
                Some(TypedValue::Blob(b))
                    if corpus_kit::corpus_provider_counts_store::is_invalidated_counts(b) =>
                {
                    // Row is correctly zeroed to the sentinel.
                }
                Some(TypedValue::Blob(b)) => {
                    return Err(format!(
                        "counts read-back: row ({model_id}, {model_version}) counts blob \
                         is not the invalidation sentinel (len={}); migration left \
                         undecodable state on disk",
                        b.len()
                    ));
                }
                other => {
                    return Err(format!(
                        "counts read-back: row ({model_id}, {model_version}) counts column \
                         has unexpected shape {other:?}; expected Blob — migration cannot \
                         verify the invalidation sentinel"
                    ));
                }
            }
        }
    }

    // Step 3: open the queue sibling and call the reindex latch.
    // The latch enqueues a full-reindex marker job on the "reindex" stream
    // and writes the "corpus_reindex_required" key into the estate manifest
    // table. If the enqueue does not take, it prints the deferral line.
    let queue_config = estate_config
        .queue_sibling("queue.sqlite")
        .map_err(|e| format!("queue sibling path: {e:?}"))?;
    let queue_storage: Arc<dyn Storage> =
        Arc::new(SqliteStorage::new(queue_config).map_err(|e| e.to_string())?);
    // open_schema is idempotent — ensures the queuekit_jobs table exists
    // (it may predate this upgrade; open_schema is a no-op when the schema
    // is already at the current version).
    PersistenceKitBackend::open_schema(queue_storage.as_ref())
        .map_err(|e| format!("queue schema open: {e:?}"))?;
    let queue = QueueKit::new(PersistenceKitBackend::new(queue_storage));
    reindex_required(&queue, storage.as_ref(), now_ms)
        .map_err(|e| format!("reindex latch: {e}"))?;

    let _ = storage.close();
    Ok((vocab_deleted, counts_updated))
}

fn run_corpus_counts_migration() {
    use persistence_kit::storage::{BackendConfiguration, EstateConfiguration};
    use uuid::Uuid;

    let data = crate::core::paths::data_dir();
    let name = crate::core::paths::active_estate(&data);
    let estate = crate::core::paths::estate_sqlite_path(&data, &name);
    // Absent estate means first run — nothing to migrate.
    if !estate.exists() {
        return;
    }

    // Single-writer discipline: the resident daemon is stopped around the
    // work only when this is its estate (the helper prints why when it is
    // not). `None` means the daemon would not stop; the step is skipped
    // and the next `mootx01 upgrade` retries.
    let Some(result) = with_resident_daemon_quiesced(
        &data,
        &crate::core::paths::resident_data_dir(),
        "corpus-counts migration",
        &PlatformDaemon,
        || {
        // Open the estate SQLite directly (no schema ladder — we are touching only
        // pre-existing tables, not running migrations). This is the same surface
        // used by run_kg_fact_identity_backfill. The sibling `db.key` is adopted
        // automatically by SqliteStorage::new for encrypted estates.
        let estate_config = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: estate.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        );

        let now_ms = wall_now_millis();

        corpus_counts_migration_core(&estate_config, now_ms)
        },
    ) else {
        return;
    };

    match result {
        Ok((vocab_deleted, counts_updated)) => {
            if vocab_deleted == 0 && counts_updated == 0 {
                println!("  ✓ corpus-counts migration: nothing to clear");
            } else {
                println!(
                    "  ✓ corpus-counts migration: {} vocab rows cleared, {} counts blobs zeroed",
                    vocab_deleted, counts_updated
                );
            }
        }
        Err(e) => {
            println!(
                "  ✗ corpus-counts migration failed: {e}\n    \
                 The estate is readable in its current shape. Run `mootx01 upgrade` to retry."
            );
        }
    }
}

/// MXE-NS-CODEX: at upgrade time, when the Codex plugin owns the MCP
/// connection (plugin enabled + version installed), remove the redundant
/// direct `[mcp_servers.mootx01]` entry from `~/.codex/config.toml`.
/// Thin wrapper that resolves the home directory and delegates to
/// `remove_redundant_codex_direct_entry_from`.
fn remove_redundant_codex_direct_entry() {
    let home = super::install::home_dir();
    remove_redundant_codex_direct_entry_from(&home);
}

/// Core logic for the Codex direct-entry cleanup, with an injected home
/// directory for testability. The plugin wiring is sufficient; keeping both
/// opens a second connection under the same `mootx01` key. A
/// `.mootx01-backup` copy is made before the removal. Idempotent: absent
/// file or absent table are both silent no-ops.
fn remove_redundant_codex_direct_entry_from(home: &std::path::Path) {
    let config_path = join_rel(home, ".codex/config.toml");
    if !config_path.exists() {
        return;
    }

    // Plugin must own the Codex connection before we touch anything. An
    // enabled-but-not-installed entry is stale config; installed-but-not-enabled
    // means the plugin is inactive and the direct entry is the live connection.
    if !codex_plugin_owns_connection(home) {
        return;
    }

    // Fast path: nothing to remove if the table is absent.
    let content = match std::fs::read_to_string(&config_path) {
        Ok(c) => c,
        Err(_) => return,
    };
    if !content.lines().any(|l| l.trim() == "[mcp_servers.mootx01]") {
        return;
    }

    // Backup before mutating. Fail closed: if the backup cannot be written,
    // leave the config untouched rather than mutating without a recovery copy.
    let backup_path = join_rel(home, ".codex/config.toml.mootx01-backup");
    if let Err(e) = std::fs::copy(&config_path, &backup_path) {
        println!("  ! Could not back up Codex config before cleanup: {e}");
        return;
    }

    match crate::core::merge::remove_from_toml_config(&config_path, "mootx01") {
        Ok(true) => {
            println!(
                "  ✓ Removed redundant direct MCP entry from Codex config (plugin owns connection)."
            );
        }
        // Ok(false) means the table was absent — should not happen given the
        // check above, but safe to ignore (idempotent by design).
        Ok(false) => {}
        Err(e) => {
            println!("  ! Could not clean Codex config: {e}");
        }
    }
}

/// True when the `mootx01@mootx01` Codex plugin is both enabled in config
/// and has at least one installed version under the Codex plugin cache.
/// Mirrors Swift's `PluginDetector.ownsCodexConnection`.
fn codex_plugin_owns_connection(home: &std::path::Path) -> bool {
    codex_plugin_is_enabled(home) && codex_plugin_is_installed(home)
}

/// Scan `~/.codex/config.toml` line-by-line for the
/// `[plugins."mootx01@mootx01"]` section. Returns true only when that
/// section contains `enabled = true`. Fails closed on any read or parse
/// error — keeping a redundant direct entry is far less harmful than
/// removing the only working connection.
fn codex_plugin_is_enabled(home: &std::path::Path) -> bool {
    let config_path = join_rel(home, ".codex/config.toml");
    let content = match std::fs::read_to_string(&config_path) {
        Ok(c) => c,
        Err(_) => return false,
    };
    // Codex accepts both double- and single-quoted section headers.
    let accepted = [
        r#"[plugins."mootx01@mootx01"]"#,
        r#"[plugins.'mootx01@mootx01']"#,
    ];
    let mut in_table = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_table = accepted.contains(&trimmed);
            continue;
        }
        if !in_table || trimmed.starts_with('#') {
            continue;
        }
        if let Some(eq_pos) = trimmed.find('=') {
            let key = trimmed[..eq_pos].trim();
            let value = trimmed[eq_pos + 1..].trim();
            if key == "enabled" {
                return value == "true";
            }
        }
    }
    false
}

/// True when at least one version directory containing a plugin manifest
/// exists under `~/.codex/plugins/cache/mootx01/mootx01/`. Recognises
/// both `.codex-plugin/plugin.json` (native) and `.claude-plugin/plugin.json`
/// (shared marketplace legacy format).
fn codex_plugin_is_installed(home: &std::path::Path) -> bool {
    let cache = join_rel(home, ".codex/plugins/cache/mootx01/mootx01");
    let entries = match std::fs::read_dir(&cache) {
        Ok(rd) => rd,
        Err(_) => return false,
    };
    for entry in entries.flatten() {
        let base = entry.path();
        if base.join(".codex-plugin").join("plugin.json").exists()
            || base.join(".claude-plugin").join("plugin.json").exists()
        {
            return true;
        }
    }
    false
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

    // The daemon seam: the platform control when this is the resident
    // estate, a no-op otherwise — a cloned estate is encrypted with the
    // resident daemon left running over its own estate. The resident
    // directory comes from the daemon's service registration; an
    // unreadable registration selects the platform control (SAFETY: the
    // clone+swap never runs under a daemon that may hold this estate open).
    let resident_dir = crate::core::paths::resident_data_dir();
    let resident = crate::core::paths::is_resident_estate(&data, &resident_dir);
    if !resident {
        println!(
            "  data directory {} is not the resident estate; daemon left running",
            data.display()
        );
    } else if let Some(warning) = resident_dir.registration_warning(&data) {
        println!("{warning}");
    }
    let daemon: &dyn DaemonControl = if resident { &PlatformDaemon } else { &NoDaemon };

    // Quiesce FIRST (never lose data): no write may land in the original
    // once the clone exists. Refusing to proceed when the daemon will not
    // stop is the safe direction — nothing has been touched yet.
    let was_running = daemon.is_running();
    if was_running && !daemon.stop() {
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
            let restarted = if was_running { daemon.start() } else { true };
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
                let _ = daemon.start();
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

/// The daemon control seam every resident-estate quiesce goes through
/// (`mootx01 upgrade` steps).
/// `PlatformDaemon` is the production implementation; `NoDaemon` stands in
/// for a non-resident estate; tests inject a recorder so a step can be
/// shown to leave the daemon alone. Twin of the Swift
/// `EstateEncryptionMigrator.DaemonControl` seam.
pub(crate) trait DaemonControl {
    fn is_running(&self) -> bool;
    fn stop(&self) -> bool;
    fn start(&self) -> bool;
}

/// Platform daemon control for the stop → work → start sequence. Linux:
/// the systemd unit. Windows: the scheduled task. Other platforms report
/// "not running" so the upgrade never tries to manage a daemon it has no
/// control surface for (the user was told to check).
pub(crate) struct PlatformDaemon;

impl DaemonControl for PlatformDaemon {
    fn is_running(&self) -> bool {
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

    fn stop(&self) -> bool {
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

    fn start(&self) -> bool {
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
}

/// A control with no daemon behind it: never running, stop and start
/// succeed. Selected for a non-resident estate, mirroring the Swift
/// `DaemonControl.none`.
struct NoDaemon;

impl DaemonControl for NoDaemon {
    fn is_running(&self) -> bool {
        false
    }
    fn stop(&self) -> bool {
        true
    }
    fn start(&self) -> bool {
        true
    }
}

/// Run `work` with the resident daemon quiesced when `data` is the resident
/// estate; otherwise run it with the daemon untouched.
///
/// Resident estate (`paths::is_resident_estate`): capture whether the daemon
/// is running, stop it — single-writer discipline, because the step opens
/// the estate SQLite the daemon has open — run `work`, then start the daemon
/// again if it was running. The restart happens on every outcome of `work`,
/// so a failed step never leaves the daemon down.
///
/// Not the resident estate: print one line naming the directory so an
/// operator sees why nothing restarted, then run `work`. The daemon serves a
/// different estate and has no stake in this one.
///
/// Unreadable registration (`ResidentDataDir::UnreadableRegistration`):
/// print the registration warning, then proceed exactly as for the resident
/// estate. SAFETY: an estate the daemon may hold open is never migrated
/// under a running daemon.
///
/// Returns `work`'s result, or `None` when the daemon was running and would
/// not stop — the step is skipped, nothing is half-done, and the next
/// `mootx01 upgrade` retries. Twin of the Swift `ResidentDaemonQuiesce.run`.
pub(crate) fn with_resident_daemon_quiesced<T>(
    data: &std::path::Path,
    resident: &crate::core::paths::ResidentDataDir,
    step: &str,
    daemon: &dyn DaemonControl,
    work: impl FnOnce() -> T,
) -> Option<T> {
    if !crate::core::paths::is_resident_estate(data, resident) {
        println!(
            "  data directory {} is not the resident estate; daemon left running",
            data.display()
        );
        return Some(work());
    }
    if let Some(warning) = resident.registration_warning(data) {
        println!("{warning}");
    }
    let was_running = daemon.is_running();
    if was_running && !daemon.stop() {
        println!(
            "  ✗ {step} skipped — the resident daemon would not stop; run `mootx01 upgrade` again"
        );
        return None;
    }
    let out = work();
    if was_running {
        let _ = daemon.start();
    }
    Some(out)
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

/// The recording daemon control shared by every command test that pins the
/// resident-quiesce rule (`upgrade` steps).
#[cfg(test)]
pub(crate) mod daemon_test_support {
    /// Records every daemon-control call in order; the recorder IS the
    /// daemon, so no service manager is ever reached from a test.
    pub(crate) struct RecordingDaemon {
        running: bool,
        stop_succeeds: bool,
        calls: std::cell::RefCell<Vec<&'static str>>,
    }

    impl RecordingDaemon {
        pub(crate) fn new(running: bool, stop_succeeds: bool) -> Self {
            Self { running, stop_succeeds, calls: std::cell::RefCell::new(Vec::new()) }
        }
        pub(crate) fn calls(&self) -> Vec<&'static str> {
            self.calls.borrow().clone()
        }
    }

    impl super::DaemonControl for RecordingDaemon {
        fn is_running(&self) -> bool {
            self.calls.borrow_mut().push("is_running");
            self.running
        }
        fn stop(&self) -> bool {
            self.calls.borrow_mut().push("stop");
            self.stop_succeeds
        }
        fn start(&self) -> bool {
            self.calls.borrow_mut().push("start");
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::daemon_test_support::RecordingDaemon;

    /// REAL-PATH gate for the corpus-counts migration (Bob's ruling,
    /// 2026-08-15): drives `corpus_counts_migration_core` — the exact estate
    /// operations `mootx01 upgrade` runs — on a scratch SQLite estate seeded
    /// with a POPULATED pre-v3 layout (ProviderVocabStorageTests precedent:
    /// ee#49 shipped broken twice against fresh-database tests). The daemon
    /// quiesce/restart wrapper is deliberately outside the core: a test must
    /// never stop the machine-global daemon.
    #[test]
    fn corpus_counts_migration_core_clears_legacy_preserves_anchors_sets_latch() {
        use persistence_kit::predicate::StoragePredicate;
        use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
        use persistence_kit::sqlite::SqliteStorage;
        use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
        use persistence_kit::types::TypedValue;
        use std::collections::BTreeMap;
        use std::sync::Arc;
        use uuid::Uuid;

        let dir = std::env::temp_dir().join(format!("counts-mig-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let estate = dir.join("estate.sqlite");
        let cfg = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: estate.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        );

        // ── Seed a POPULATED pre-v3 layout ────────────────────────────────
        {
            let st: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg.clone()).unwrap());
            let schema = SchemaDeclaration::new(
                "MigTestSeed",
                1,
                vec![
                    TableDeclaration::new(
                        "corpus_provider_counts",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::text("model_version"),
                            ColumnDeclaration::blob("counts"),
                            ColumnDeclaration::int("doc_count"),
                            ColumnDeclaration::int("vocab_size"),
                        ],
                        vec!["model_id".to_string(), "model_version".to_string()],
                    ),
                    TableDeclaration::new(
                        "corpus_provider_vocab",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::text("model_version"),
                            ColumnDeclaration::text("term"),
                            ColumnDeclaration::blob("vector"),
                        ],
                        vec!["model_id".to_string(), "model_version".to_string(), "term".to_string()],
                    ),
                    TableDeclaration::new(
                        "manifest",
                        vec![ColumnDeclaration::text("key"), ColumnDeclaration::text("value")],
                        vec!["key".to_string()],
                    ),
                ],
            );
            st.open(&schema).unwrap();
            let rs = st.row_store();
            let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
            row.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
            row.insert("model_version".into(), TypedValue::Text("1".into()));
            row.insert("counts".into(), TypedValue::Blob(b"legacy-serialized-counts".to_vec()));
            row.insert("doc_count".into(), TypedValue::Int(42));
            row.insert("vocab_size".into(), TypedValue::Int(17));
            rs.upsert("corpus_provider_counts", row, &["model_id".to_string(), "model_version".to_string()]).unwrap();
            for term in ["alpha", "beta"] {
                let mut v: BTreeMap<String, TypedValue> = BTreeMap::new();
                v.insert("model_id".into(), TypedValue::Text("random-indexing-v1".into()));
                v.insert("model_version".into(), TypedValue::Text("1".into()));
                v.insert("term".into(), TypedValue::Text(term.into()));
                v.insert("vector".into(), TypedValue::Blob(vec![1, 2, 3]));
                rs.upsert("corpus_provider_vocab", v, &["model_id".to_string(), "model_version".to_string(), "term".to_string()]).unwrap();
            }
            // Positive pre-state: the seed is POPULATED (falsification anchor —
            // an empty seed would make every later assertion vacuous).
            assert_eq!(rs.count("corpus_provider_vocab", None).unwrap(), 2);
            let _ = st.close();
        }

        // ── Drive the REAL migration core ─────────────────────────────────
        let (vocab_deleted, counts_updated) =
            corpus_counts_migration_core(&cfg, 1_700_000_000_000).expect("core must succeed");
        assert_eq!(vocab_deleted, 2, "both legacy vocab rows must be deleted");
        assert_eq!(counts_updated, 1, "the counts blob row must be zeroed");

        // ── Post-state: legacy gone, anchors kept, latch set, job queued ──
        {
            let st: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg.clone()).unwrap());
            let rs = st.row_store();
            assert_eq!(rs.count("corpus_provider_vocab", None).unwrap(), 0, "legacy vocab rows must be gone");
            let rows = rs.query("corpus_provider_counts", None, &[], None, None).unwrap();
            assert_eq!(rows.len(), 1);
            match rows[0].get("counts") {
                Some(TypedValue::Blob(b)) => assert!(b.is_empty(), "counts blob must be zeroed"),
                other => panic!("counts column wrong shape: {other:?}"),
            }
            assert_eq!(rows[0].get("doc_count"), Some(&TypedValue::Int(42)), "doc_count anchor preserved");
            assert_eq!(rows[0].get("vocab_size"), Some(&TypedValue::Int(17)), "vocab_size anchor preserved");
            let flag = rs
                .query(
                    "manifest",
                    Some(&StoragePredicate::Eq(
                        persistence_kit::types::Column::new("manifest", "key"),
                        TypedValue::Text("corpus_reindex_required".into()),
                    )),
                    &[],
                    None,
                    None,
                )
                .unwrap();
            assert_eq!(flag.len(), 1, "latch manifest flag must be set");
            assert_eq!(flag[0].get("value"), Some(&TypedValue::Text("1".into())));
            let _ = st.close();
        }
        // Queue sibling carries the reindex job.
        {
            let qcfg = cfg.queue_sibling("queue.sqlite").unwrap();
            let qst: Arc<dyn Storage> = Arc::new(SqliteStorage::new(qcfg).unwrap());
            let jobs = qst.row_store().count("queuekit_jobs", None).unwrap();
            assert!(jobs >= 1, "the reindex job must be enqueued in the queue sibling");
            let _ = qst.close();
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Regression guard: after `corpus_counts_migration_core` runs, every
    /// `corpus_provider_counts` row must carry the invalidation sentinel, and the
    /// migration's own read-back gate must confirm this — i.e. the function must
    /// succeed (not Err) after writing the sentinel.
    ///
    /// This test proves the gate FIRES in the success path: the migration writes
    /// the sentinel, reads it back, confirms each row satisfies `is_invalidated_counts`,
    /// and returns Ok. It pins the observation recorded in the brief: SqliteStorage
    /// returns an empty blob as TypedValue::Blob(vec![]) — the gate encodes exactly
    /// this shape.
    ///
    /// Cannot construct a case where a row is left in an uninterpretable shape
    /// without bypassing SqliteStorage itself (the write+read loop is deterministic
    /// for the blob type). The success path is therefore the observable gate: the
    /// migration does not Err, and the read-back rows satisfy is_invalidated_counts.
    #[test]
    fn corpus_counts_migration_gate_verifies_sentinel_on_every_row() {
        use corpus_kit::corpus_provider_counts_store::is_invalidated_counts;
        use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
        use persistence_kit::sqlite::SqliteStorage;
        use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
        use persistence_kit::types::TypedValue;
        use std::collections::BTreeMap;
        use std::sync::Arc;
        use uuid::Uuid;

        let dir = std::env::temp_dir().join(format!("counts-mig-gate-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let estate = dir.join("estate.sqlite");
        let cfg = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: estate.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        );

        // Seed two counts rows with non-empty legacy blobs, so the gate has something
        // real to verify (two rows exercise the loop, not just the 0-or-1 case).
        {
            let st: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg.clone()).unwrap());
            let schema = SchemaDeclaration::new(
                "GateSeed",
                1,
                vec![
                    TableDeclaration::new(
                        "corpus_provider_counts",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::text("model_version"),
                            ColumnDeclaration::blob("counts"),
                            ColumnDeclaration::int("doc_count"),
                            ColumnDeclaration::int("vocab_size"),
                        ],
                        vec!["model_id".to_string(), "model_version".to_string()],
                    ),
                    TableDeclaration::new(
                        "corpus_provider_vocab",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::text("model_version"),
                            ColumnDeclaration::text("term"),
                            ColumnDeclaration::blob("vector"),
                        ],
                        vec!["model_id".to_string(), "model_version".to_string(), "term".to_string()],
                    ),
                    TableDeclaration::new(
                        "manifest",
                        vec![ColumnDeclaration::text("key"), ColumnDeclaration::text("value")],
                        vec!["key".to_string()],
                    ),
                ],
            );
            st.open(&schema).unwrap();
            let rs = st.row_store();
            for (mid, mv, blob, doc, vocab) in [
                ("ppmi-v1", "1", b"ppmi-legacy-bytes" as &[u8], 100i64, 500i64),
                ("ri-v1", "1", b"ri-legacy-bytes", 200, 800),
            ] {
                let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
                row.insert("model_id".into(), TypedValue::Text(mid.into()));
                row.insert("model_version".into(), TypedValue::Text(mv.into()));
                row.insert("counts".into(), TypedValue::Blob(blob.to_vec()));
                row.insert("doc_count".into(), TypedValue::Int(doc));
                row.insert("vocab_size".into(), TypedValue::Int(vocab));
                rs.upsert(
                    "corpus_provider_counts",
                    row,
                    &["model_id".to_string(), "model_version".to_string()],
                )
                .unwrap();
            }
            // Falsification anchor: pre-state must have non-empty blobs.
            let rows = rs.query("corpus_provider_counts", None, &[], None, None).unwrap();
            assert_eq!(rows.len(), 2, "seed must have two rows");
            for row in &rows {
                match row.get("counts") {
                    Some(TypedValue::Blob(b)) => {
                        assert!(!b.is_empty(), "seed blobs must be non-empty (pre-state)");
                    }
                    other => panic!("unexpected counts shape in seed: {other:?}"),
                }
            }
            let _ = st.close();
        }

        // Drive the migration — the read-back gate is embedded in the core.
        // If the gate rejects any row, the core returns Err and this test panics.
        let (_, counts_updated) =
            corpus_counts_migration_core(&cfg, 1_700_000_000_001).expect(
                "migration must succeed: read-back gate must confirm sentinel on every row",
            );
        assert_eq!(counts_updated, 2, "both counts rows must be updated");

        // Independently verify the post-state: every row now satisfies is_invalidated_counts.
        // This is the same check the gate performs internally; doing it here makes the
        // observation explicit in the test output.
        {
            let st: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg.clone()).unwrap());
            let rs = st.row_store();
            let rows = rs.query("corpus_provider_counts", None, &[], None, None).unwrap();
            assert_eq!(rows.len(), 2, "both rows must survive (anchors preserved)");
            for row in &rows {
                match row.get("counts") {
                    Some(TypedValue::Blob(b)) => {
                        // Observed read-back shape: TypedValue::Blob(vec![]) for an empty blob.
                        // This is the empirical confirmation that is_invalidated_counts matches
                        // what SqliteStorage actually returns.
                        assert!(
                            is_invalidated_counts(b),
                            "every row must satisfy is_invalidated_counts after migration; \
                             got blob of len {}",
                            b.len()
                        );
                    }
                    other => panic!("unexpected counts shape after migration: {other:?}"),
                }
            }
            let _ = st.close();
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Regression guard: a normal migration (populated estate) leaves all anchors
    /// intact and sets the reindex latch. No error from the read-back gate.
    /// Complements `corpus_counts_migration_core_clears_legacy_preserves_anchors_sets_latch`
    /// by asserting the gate's presence does not interfere with the success path.
    #[test]
    fn corpus_counts_migration_gate_does_not_interfere_with_normal_migration() {
        use persistence_kit::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
        use persistence_kit::sqlite::SqliteStorage;
        use persistence_kit::storage::{BackendConfiguration, EstateConfiguration, Storage};
        use persistence_kit::types::TypedValue;
        use std::collections::BTreeMap;
        use std::sync::Arc;
        use uuid::Uuid;

        let dir = std::env::temp_dir().join(format!("counts-mig-nointerfer-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let estate = dir.join("estate.sqlite");
        let cfg = EstateConfiguration::new(
            Uuid::new_v4(),
            BackendConfiguration::Sqlite {
                path: estate.display().to_string(),
                busy_timeout_secs: 5.0,
            },
        );

        {
            let st: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg.clone()).unwrap());
            let schema = SchemaDeclaration::new(
                "NormalSeed",
                1,
                vec![
                    TableDeclaration::new(
                        "corpus_provider_counts",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::text("model_version"),
                            ColumnDeclaration::blob("counts"),
                            ColumnDeclaration::int("doc_count"),
                            ColumnDeclaration::int("vocab_size"),
                        ],
                        vec!["model_id".to_string(), "model_version".to_string()],
                    ),
                    TableDeclaration::new(
                        "corpus_provider_vocab",
                        vec![
                            ColumnDeclaration::text("model_id"),
                            ColumnDeclaration::text("model_version"),
                            ColumnDeclaration::text("term"),
                            ColumnDeclaration::blob("vector"),
                        ],
                        vec!["model_id".to_string(), "model_version".to_string(), "term".to_string()],
                    ),
                    TableDeclaration::new(
                        "manifest",
                        vec![ColumnDeclaration::text("key"), ColumnDeclaration::text("value")],
                        vec!["key".to_string()],
                    ),
                ],
            );
            st.open(&schema).unwrap();
            let rs = st.row_store();
            let mut row: BTreeMap<String, TypedValue> = BTreeMap::new();
            row.insert("model_id".into(), TypedValue::Text("nmf-v1".into()));
            row.insert("model_version".into(), TypedValue::Text("1".into()));
            row.insert("counts".into(), TypedValue::Blob(b"nmf-legacy-counts".to_vec()));
            row.insert("doc_count".into(), TypedValue::Int(77));
            row.insert("vocab_size".into(), TypedValue::Int(333));
            rs.upsert(
                "corpus_provider_counts",
                row,
                &["model_id".to_string(), "model_version".to_string()],
            )
            .unwrap();
            let _ = st.close();
        }

        // Must succeed — the gate must not reject a cleanly-written sentinel.
        let result = corpus_counts_migration_core(&cfg, 1_700_000_000_002);
        assert!(
            result.is_ok(),
            "normal migration must succeed even with the read-back gate present: {result:?}"
        );
        let (vocab_deleted, counts_updated) = result.unwrap();
        assert_eq!(vocab_deleted, 0, "no legacy vocab rows to delete");
        assert_eq!(counts_updated, 1, "one counts row updated");

        // Anchors preserved.
        {
            let st: Arc<dyn Storage> = Arc::new(SqliteStorage::new(cfg.clone()).unwrap());
            let rows = st
                .row_store()
                .query("corpus_provider_counts", None, &[], None, None)
                .unwrap();
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].get("doc_count"), Some(&TypedValue::Int(77)), "doc_count preserved");
            assert_eq!(
                rows[0].get("vocab_size"),
                Some(&TypedValue::Int(333)),
                "vocab_size preserved"
            );
            let _ = st.close();
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

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

    // ── MXE-NS-CODEX: Codex direct-entry cleanup (Part 6) ──────────────────

    fn tmp_codex_home(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!(
            "mootx01-upgrade-codex-{tag}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// Write a minimal Codex config.toml containing the plugin section and an
    /// mcp_servers entry, then populate the plugin cache so ownership is
    /// detected. Expect the mcp_servers table to be removed and a backup to
    /// be created.
    #[test]
    fn removes_mcp_servers_entry_when_plugin_owns_connection() {
        let home = tmp_codex_home("remove");

        // Seed the config.toml with both the plugin section and the MCP entry.
        let codex_dir = home.join(".codex");
        std::fs::create_dir_all(&codex_dir).unwrap();
        let config = codex_dir.join("config.toml");
        std::fs::write(
            &config,
            "[plugins.\"mootx01@mootx01\"]\nenabled = true\n\n[mcp_servers.mootx01]\ncommand = \"mootx01\"\nargs = [\"proxy\"]\n",
        )
        .unwrap();

        // Seed the plugin cache with a version directory and a native manifest.
        let cache_version = codex_dir
            .join("plugins")
            .join("cache")
            .join("mootx01")
            .join("mootx01")
            .join("1.0.0");
        let codex_plugin_dir = cache_version.join(".codex-plugin");
        std::fs::create_dir_all(&codex_plugin_dir).unwrap();
        std::fs::write(codex_plugin_dir.join("plugin.json"), r#"{"version":"1.0.0"}"#).unwrap();

        // Verify ownership is detected.
        assert!(codex_plugin_owns_connection(&home), "plugin must own connection");

        remove_redundant_codex_direct_entry_from(&home);

        let after = std::fs::read_to_string(&config).unwrap();
        assert!(
            !after.contains("[mcp_servers.mootx01]"),
            "mcp_servers table must be removed"
        );
        assert!(
            after.contains("[plugins.\"mootx01@mootx01\"]"),
            "plugin section must be preserved"
        );
        let backup = codex_dir.join("config.toml.mootx01-backup");
        assert!(backup.exists(), "backup must be created before removal");

        let _ = std::fs::remove_dir_all(&home);
    }

    /// When the plugin section is absent, `remove_redundant_codex_direct_entry`
    /// must leave the config file untouched.
    #[test]
    fn skips_when_plugin_not_installed() {
        let home = tmp_codex_home("skip-no-plugin");
        let codex_dir = home.join(".codex");
        std::fs::create_dir_all(&codex_dir).unwrap();
        let config = codex_dir.join("config.toml");
        std::fs::write(
            &config,
            "[mcp_servers.mootx01]\ncommand = \"mootx01\"\nargs = [\"proxy\"]\n",
        )
        .unwrap();

        remove_redundant_codex_direct_entry_from(&home);

        let after = std::fs::read_to_string(&config).unwrap();
        assert!(
            after.contains("[mcp_servers.mootx01]"),
            "config must be untouched when plugin is absent"
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    /// When config.toml has no `[mcp_servers.mootx01]` table, the function
    /// must be a clean no-op even when the plugin is present.
    #[test]
    fn no_op_when_mcp_table_absent() {
        let home = tmp_codex_home("noop");
        let codex_dir = home.join(".codex");
        std::fs::create_dir_all(&codex_dir).unwrap();
        let config = codex_dir.join("config.toml");
        std::fs::write(
            &config,
            "[plugins.\"mootx01@mootx01\"]\nenabled = true\nmodel = \"o3\"\n",
        )
        .unwrap();

        // Seed the plugin cache.
        let cache_version = codex_dir
            .join("plugins")
            .join("cache")
            .join("mootx01")
            .join("mootx01")
            .join("1.0.0");
        let codex_plugin_dir = cache_version.join(".codex-plugin");
        std::fs::create_dir_all(&codex_plugin_dir).unwrap();
        std::fs::write(codex_plugin_dir.join("plugin.json"), r#"{"version":"1.0.0"}"#).unwrap();

        remove_redundant_codex_direct_entry_from(&home);

        let backup = codex_dir.join("config.toml.mootx01-backup");
        assert!(!backup.exists(), "no backup when table was already absent");

        let _ = std::fs::remove_dir_all(&home);
    }

    /// When the backup write fails (backup path is a pre-existing directory,
    /// so `fs::copy` cannot overwrite it), the function must leave the
    /// config file untouched. Fail-closed: never mutate without a recovery copy.
    #[test]
    fn leaves_config_untouched_when_backup_fails() {
        let home = tmp_codex_home("backup-fail");
        let codex_dir = home.join(".codex");
        std::fs::create_dir_all(&codex_dir).unwrap();
        let config = codex_dir.join("config.toml");
        let original = "[plugins.\"mootx01@mootx01\"]\nenabled = true\n\n[mcp_servers.mootx01]\ncommand = \"mootx01\"\nargs = [\"proxy\"]\n";
        std::fs::write(&config, original).unwrap();

        // Seed the plugin cache.
        let cache_version = codex_dir
            .join("plugins")
            .join("cache")
            .join("mootx01")
            .join("mootx01")
            .join("1.0.0");
        let codex_plugin_dir = cache_version.join(".codex-plugin");
        std::fs::create_dir_all(&codex_plugin_dir).unwrap();
        std::fs::write(codex_plugin_dir.join("plugin.json"), r#"{"version":"1.0.0"}"#).unwrap();

        // Block the backup by placing a DIRECTORY at the backup path —
        // fs::copy cannot overwrite a directory with a file, so the write fails.
        let backup_path = codex_dir.join("config.toml.mootx01-backup");
        std::fs::create_dir_all(&backup_path).unwrap();

        remove_redundant_codex_direct_entry_from(&home);

        // Config must be unchanged — the mcp_servers table stays in place.
        let after = std::fs::read_to_string(&config).unwrap();
        assert_eq!(
            after, original,
            "config must be untouched when backup write fails"
        );

        let _ = std::fs::remove_dir_all(&home);
    }

    use crate::core::paths::ResidentDataDir;

    /// A resident directory (as a registration with no override names it)
    /// and a scratch clone beside it.
    fn resident_and_scratch() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let tmp = tempfile::tempdir().expect("tempdir");
        let resident = tmp.path().join("resident");
        // A benchmark clone beside the resident directory: same parent,
        // same prefix, a different estate.
        let scratch = tmp.path().join("resident-bench");
        std::fs::create_dir_all(&resident).expect("resident dir");
        std::fs::create_dir_all(&scratch).expect("scratch dir");
        (tmp, resident, scratch)
    }

    fn registered(dir: &std::path::Path) -> ResidentDataDir {
        ResidentDataDir::Directory(dir.to_path_buf())
    }

    #[test]
    fn scratch_estate_runs_the_work_and_never_touches_the_daemon() {
        let (_tmp, resident, scratch) = resident_and_scratch();
        let daemon = RecordingDaemon::new(true, true);
        let ran = std::cell::Cell::new(false);
        let out = super::with_resident_daemon_quiesced(
            &scratch,
            &registered(&resident),
            "kg_facts identity backfill",
            &daemon,
            || {
                ran.set(true);
                7
            },
        );
        assert_eq!(out, Some(7));
        assert!(ran.get());
        assert!(daemon.calls().is_empty(), "a scratch estate must not touch the daemon");
    }

    #[test]
    fn resident_estate_stops_then_restarts_a_running_daemon() {
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let daemon = RecordingDaemon::new(true, true);
        let out = super::with_resident_daemon_quiesced(
            &resident,
            &registered(&resident),
            "schema upgrade",
            &daemon,
            || true,
        );
        assert_eq!(out, Some(true));
        assert_eq!(daemon.calls(), vec!["is_running", "stop", "start"]);
    }

    #[test]
    fn failed_work_still_restarts_the_daemon() {
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let daemon = RecordingDaemon::new(true, true);
        let out = super::with_resident_daemon_quiesced(
            &resident,
            &registered(&resident),
            "shared-content reclaim",
            &daemon,
            || false,
        );
        assert_eq!(out, Some(false));
        assert_eq!(daemon.calls(), vec!["is_running", "stop", "start"]);
    }

    #[test]
    fn resident_estate_with_daemon_down_never_starts_one() {
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let daemon = RecordingDaemon::new(false, true);
        let out = super::with_resident_daemon_quiesced(
            &resident,
            &registered(&resident),
            "span encode",
            &daemon,
            || true,
        );
        assert_eq!(out, Some(true));
        assert_eq!(daemon.calls(), vec!["is_running"]);
    }

    #[test]
    fn daemon_that_will_not_stop_skips_the_work() {
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let daemon = RecordingDaemon::new(true, false);
        let ran = std::cell::Cell::new(false);
        let out = super::with_resident_daemon_quiesced(
            &resident,
            &registered(&resident),
            "kg_facts identity backfill",
            &daemon,
            || {
                ran.set(true);
                true
            },
        );
        assert_eq!(out, None);
        assert!(!ran.get(), "the work must not run when the daemon will not stop");
        assert_eq!(daemon.calls(), vec!["is_running", "stop"]);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_to_the_resident_estate_is_quiesced() {
        let (tmp, resident, _scratch) = resident_and_scratch();
        let link = tmp.path().join("estate-link");
        std::os::unix::fs::symlink(&resident, &link).expect("symlink");
        let daemon = RecordingDaemon::new(true, true);
        let out = super::with_resident_daemon_quiesced(
            &link,
            &registered(&resident),
            "corpus-counts migration",
            &daemon,
            || (),
        );
        assert_eq!(out, Some(()));
        assert_eq!(daemon.calls(), vec!["is_running", "stop", "start"]);
    }

    #[test]
    fn registered_override_directory_is_quiesced_not_the_platform_default() {
        // `mootx01 install` run with MOOTX01_DATA_DIR=<scratch> registers the
        // daemon over scratch. An upgrade step on scratch quiesces; a step on
        // the platform default (an estate the daemon never opened) does not.
        let (_tmp, resident, scratch) = resident_and_scratch();
        let registration = registered(&scratch);
        let on_scratch = RecordingDaemon::new(true, true);
        let out = super::with_resident_daemon_quiesced(
            &scratch,
            &registration,
            "schema upgrade",
            &on_scratch,
            || true,
        );
        assert_eq!(out, Some(true));
        assert_eq!(on_scratch.calls(), vec!["is_running", "stop", "start"]);

        let on_default = RecordingDaemon::new(true, true);
        let out = super::with_resident_daemon_quiesced(
            &resident,
            &registration,
            "schema upgrade",
            &on_default,
            || true,
        );
        assert_eq!(out, Some(true));
        assert!(on_default.calls().is_empty());
    }

    #[test]
    fn unreadable_registration_quiesces_every_estate() {
        let (_tmp, _resident, scratch) = resident_and_scratch();
        let unreadable = ResidentDataDir::UnreadableRegistration(std::path::PathBuf::from(
            "/home/u/.config/systemd/user/mootx01.service",
        ));
        let daemon = RecordingDaemon::new(true, true);
        let out = super::with_resident_daemon_quiesced(
            &scratch,
            &unreadable,
            "kg_facts identity backfill",
            &daemon,
            || true,
        );
        assert_eq!(out, Some(true));
        assert_eq!(daemon.calls(), vec!["is_running", "stop", "start"]);
    }

    #[test]
    fn no_daemon_control_is_never_running_and_always_succeeds() {
        use super::DaemonControl;
        assert!(!super::NoDaemon.is_running());
        assert!(super::NoDaemon.stop());
        assert!(super::NoDaemon.start());
    }

    /// REAL-PATH gate: a fresh estate opened through `new_sqlite_for_maintenance`
    /// (the path the upgrade command uses) must contain zero drawers — the
    /// default wings must NOT be seeded at open. Upgrade is a migration vehicle;
    /// it converges existing content and creates none.
    ///
    /// Mirrors the Swift invariant: `UpgradeCommand.runSpanEncodeBackfill`
    /// opens through the bare `GeniusLocusKit.open(storage:owner:)` path, which
    /// does not call `seedDefaultWings`.
    #[test]
    fn maintenance_open_creates_no_default_wings() {
        let tmpdir = tempfile::tempdir().expect("tempdir");
        let estate_path = tmpdir.path().join("estate.sqlite").display().to_string();

        let reg = aria_mcp::estate_registry::EstateRegistry::new_sqlite_for_maintenance(
            &estate_path,
            "aria-mcp-default",
        )
        .expect("maintenance open");
        let handle = reg.default.handle.clone();
        let coord = reg.coord.lock().expect("coordinator lock");

        let drawers = coord.all_drawers(&handle).expect("all_drawers");
        assert_eq!(
            drawers.len(),
            0,
            "maintenance open must create zero drawers; found {}: {:?}",
            drawers.len(),
            drawers.iter().map(|d| d.content.as_str()).collect::<Vec<_>>()
        );
    }

    /// Guard the boundary in the other direction: the regular `new_sqlite` open
    /// (used by `serve`) still seeds the default wings. This test confirms that
    /// fixing the upgrade path did not silently break the serve path.
    #[test]
    fn regular_open_seeds_default_wings() {
        let tmpdir = tempfile::tempdir().expect("tempdir");
        let estate_path = tmpdir.path().join("estate.sqlite").display().to_string();

        let reg = aria_mcp::estate_registry::EstateRegistry::new_sqlite(
            &estate_path,
            "aria-mcp-default",
        )
        .expect("regular open");
        let handle = reg.default.handle.clone();
        let coord = reg.coord.lock().expect("coordinator lock");

        let drawers = coord.all_drawers(&handle).expect("all_drawers");
        assert!(
            !drawers.is_empty(),
            "regular (serve) open must seed default wings but found zero drawers"
        );
    }
}
