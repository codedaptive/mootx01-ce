//! commands/db.rs — §4.4: named estate lifecycle and the estate-level
//! settings that live in the estate itself (`composition`).
//!
//! Estate lifecycle commands follow the same structure as Swift DbCommand.
//! Note: flag names differ in places (e.g. `--force` here vs Swift's `--yes`
//! for delete confirmation), and exit codes on abort also differ.
//! Estates are directories under `<data>/databases/<name>/`; the SQLite file
//! is created on first `serve`, so `create` makes the directory only.

use std::io::{self, BufRead, Write};
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Instant;

use aria_mcp::estate_registry::EstateRegistry;
use corpus_kit_providers::default_ensemble;
use genius_locus_kit::{EstateCoordinator, EstateHandle};
use genius_locus_kit_migrations::MigrationChainExt;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::drawer_store_sqlite::SqliteDrawerStore;
use locus_kit::estate_types::OwnerCredentials;
use persistence_kit::Storage;

use super::upgrade::{with_resident_daemon_quiesced, DaemonControl, PlatformDaemon};
use crate::cli::DbCommand;
use crate::core::{encrypt_optout, paths};
use crate::exit;

/// Host identity for a `composition` open (the registry's production default).
const OWNER: &str = "aria-mcp-default";

pub fn run(cmd: DbCommand) -> ExitCode {
    let data = paths::data_dir();
    match cmd {
        DbCommand::Create { name, no_encrypt } => create(&data, &name, no_encrypt),
        DbCommand::List => list(&data),
        DbCommand::Open { name } => open(&data, &name),
        DbCommand::Delete { name, force } => delete(&data, &name, force),
        DbCommand::Composition { db, set } => composition(&data, db, set),
    }
}

fn estate_dir(data: &std::path::Path, name: &str) -> std::path::PathBuf {
    data.join("databases").join(name)
}

/// Estate names are path components; refuse anything that could traverse.
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\\')
}

fn create(data: &std::path::Path, name: &str, no_encrypt: bool) -> ExitCode {
    if !valid_name(name) {
        eprintln!("Estate name '{name}' is not valid (no path separators).");
        return ExitCode::from(exit::FAILURE);
    }
    let dir = estate_dir(data, name);
    if dir.exists() {
        eprintln!("Estate '{name}' already exists.");
        return ExitCode::from(exit::FAILURE);
    }
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("Cannot create estate '{name}': {e}");
        return ExitCode::from(exit::FAILURE);
    }

    // create makes the estate DIRECTORY; the substrate writes the SQLite file
    // lazily on first serve. So the encryption posture is settled here, before
    // the file exists, in the same two ways install settles it (twin of Swift
    // DbCreateCommand).
    let estate = paths::estate_sqlite_path(data, name);
    if no_encrypt {
        if let Err(e) = encrypt_optout::write_opt_out(&estate) {
            // Failing to record the choice must not silently produce the
            // opposite posture. Leave nothing behind so the create can be
            // retried cleanly.
            let _ = std::fs::remove_dir_all(&dir);
            eprintln!("Cannot record the --no-encrypt choice for estate '{name}': {e}. Nothing was created.");
            return ExitCode::from(exit::FAILURE);
        }
        println!("Created estate '{name}' (UNENCRYPTED, --no-encrypt).");
        println!("  Run `mootx01 upgrade` at any time to encrypt it.");
    } else {
        // A re-created estate name can inherit a stale --no-encrypt marker
        // from an earlier estate at the same path. The open posture honors
        // the marker for an absent file — so without this sweep, first serve
        // would create the estate PLAINTEXT even though the user did not opt
        // out (stale-marker downgrade).
        match encrypt_optout::remove_opt_out(&estate) {
            Ok(true) => println!("Removed a stale --no-encrypt marker for '{name}'; the estate will be encrypted (the default)."),
            Ok(false) => {}
            Err(e) => {
                let _ = std::fs::remove_dir_all(&dir);
                eprintln!("Cannot remove a stale --no-encrypt marker for estate '{name}': {e}. Nothing was created.");
                return ExitCode::from(exit::FAILURE);
            }
        }
        // Mint db.key NOW rather than at first open. Two reasons: a failure
        // surfaces here, while `db create` can still be retried and nothing
        // has been half-made; and delete disposes of the key with the estate
        // directory, so minting eagerly keeps create and delete symmetric.
        if let Err(e) = aria_mcp::ensure_install_key(&dir) {
            // Fail closed and leave nothing behind: an estate directory whose
            // key could not be minted would otherwise be created plaintext on
            // first serve, silently contradicting the default the user did
            // not opt out of.
            let _ = std::fs::remove_dir_all(&dir);
            eprintln!("Cannot prepare the encryption key for estate '{name}': {e}. Nothing was created. Use --no-encrypt to create an unencrypted estate.");
            return ExitCode::from(exit::FAILURE);
        }
        println!("Created estate '{name}' (encrypted at rest).");
    }
    println!("Run `mootx01 db open {name}` to make it the active estate.");
    ExitCode::from(exit::OK)
}

fn list(data: &std::path::Path) -> ExitCode {
    let estates = list_estates(data);
    if estates.is_empty() {
        println!("No estates found. Run `mootx01 serve` to create the default estate.");
        return ExitCode::from(exit::OK);
    }
    let active = paths::active_estate(data);
    println!("Estates:");
    for name in estates {
        let marker = if name == active { " (active)" } else { "" };
        println!("  {name}{marker}");
    }
    ExitCode::from(exit::OK)
}

/// Sorted estate directory names under `<data>/databases/`.
pub fn list_estates(data: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(data.join("databases"))
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .filter_map(|e| e.file_name().into_string().ok())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

fn open(data: &std::path::Path, name: &str) -> ExitCode {
    // Validate before computing the estate dir — estate_dir calls path::join
    // on the name; an unvalidated traversal like "../evil" would join outside
    // the databases/ subtree and allow arbitrary directory reads.
    if !valid_name(name) {
        eprintln!("Estate name '{name}' is not valid (no path separators).");
        return ExitCode::from(exit::FAILURE);
    }
    if !estate_dir(data, name).exists() {
        println!("Estate '{name}' not found. Run `mootx01 db list` to see available estates.");
        return ExitCode::from(exit::FAILURE);
    }
    if let Err(e) = paths::set_active_estate(data, name) {
        eprintln!("Cannot set active estate: {e}");
        return ExitCode::from(exit::FAILURE);
    }
    println!("Active estate set to '{name}'.");
    ExitCode::from(exit::OK)
}

fn delete(data: &std::path::Path, name: &str, force: bool) -> ExitCode {
    // Validate before computing the estate dir — an unvalidated traversal like
    // "../databases" or "../../../etc" would allow deleting arbitrary directories
    // outside the databases/ subtree.
    if !valid_name(name) {
        eprintln!("Estate name '{name}' is not valid (no path separators).");
        return ExitCode::from(exit::FAILURE);
    }
    if name == "default" {
        eprintln!("Cannot delete 'default' (use uninstall --purge).");
        return ExitCode::from(exit::FAILURE);
    }
    let dir = estate_dir(data, name);
    if !dir.exists() {
        println!("Estate '{name}' not found. Run `mootx01 db list` to see available estates.");
        return ExitCode::from(exit::FAILURE);
    }
    if !force {
        println!("Delete estate '{name}' and all its data? This is irreversible.");
        print!("Type 'yes' to confirm: ");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().lock().read_line(&mut line);
        if line.trim() != "yes" {
            println!("Aborted.");
            return ExitCode::from(exit::FAILURE);
        }
    }
    // Removing the estate directory disposes of everything in it: the encrypted
    // SQLite file, its -wal/-shm sidecars, AND the whole-file encryption key
    // (db.key). The key never outlives the data it protects.
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        eprintln!("Cannot delete estate '{name}': {e}");
        return ExitCode::from(exit::FAILURE);
    }
    // Deleting the active estate falls back to default.
    if paths::active_estate(data) == name {
        let _ = paths::set_active_estate(data, "default");
    }
    println!("Estate '{name}' deleted (database, sidecars, and encryption key).");
    ExitCode::from(exit::OK)
}

/// `mootx01 db composition [--db <name>] [--set <policy-id>]`: show or change
/// the estate's stored index composition policy, which names the text each
/// search index lane is built from (id `lex=<source>;dense=<source>`). The
/// policy is an estate setting (LocusKit manifest key
/// `index_composition_policy`), read by GeniusLocusKit at every open.
///
/// Without `--set` the command prints the stored id. With `--set` it
/// validates the id before opening anything, opens the estate through the
/// kit with the rebuild committed (a serving open refuses a Corpus whose rows
/// disagree with the stored setting), writes the setting, wires the Corpus
/// under it, drains the encode queue, and runs the same `reindex_corpus` the
/// upgrade convergence step runs, so the stored policy and the index rows
/// never disagree; it prints the rows reindexed and exits non-zero on any
/// failure. When the data directory is the resident estate the resident
/// daemon is stopped around the rebuild and restarted afterwards, as
/// `mootx01 upgrade` does. Rust twin of Swift `DbCompositionCommand`.
fn composition(data: &Path, db: Option<String>, set: Option<String>) -> ExitCode {
    let name = db.unwrap_or_else(|| paths::active_estate(data));
    // Estate path: an explicit ARIA_MCP_SQLITE_PATH override wins; else the
    // named/active estate (mirrors redistill.rs).
    let estate = match std::env::var("ARIA_MCP_SQLITE_PATH") {
        Ok(p) if !p.is_empty() => p,
        _ => paths::estate_sqlite_path(data, &name).to_string_lossy().into_owned(),
    };
    let dir_exists = Path::new(&estate).parent().map(Path::exists).unwrap_or(false);
    if !dir_exists {
        eprintln!("mootx01 db composition fatal: estate '{name}' not found at {estate}");
        return ExitCode::from(exit::FAILURE);
    }
    let outcome = match set.as_deref() {
        // Show is a read: the daemon keeps serving.
        None => run_composition_on_estate(&estate, &name, None),
        Some(id) => set_composition_quiesced(
            data,
            &paths::resident_data_dir(),
            &PlatformDaemon,
            &estate,
            &name,
            id,
        ),
    };
    match outcome {
        Ok(lines) => {
            for line in lines {
                println!("{line}");
            }
            ExitCode::from(exit::OK)
        }
        Err(e) => {
            eprintln!("mootx01 db composition fatal: {e}");
            ExitCode::from(exit::FAILURE)
        }
    }
}

/// `--set` with the resident daemon quiesced. The rebuild rewrites every
/// index row while a serving daemon would keep encoding captures under the
/// policy it opened with, the single-writer hazard `mootx01 upgrade` already
/// guards: `with_resident_daemon_quiesced` stops the daemon around
/// `run_composition_on_estate` only when `data` is the resident estate and
/// restarts it afterwards; a clone is rebuilt with the daemon untouched. A
/// daemon that will not stop means nothing is written. Twin of the Swift
/// command's `ResidentDaemonQuiesce.run` wrap.
pub(crate) fn set_composition_quiesced(
    data: &Path,
    resident: &Path,
    daemon: &dyn DaemonControl,
    estate: &str,
    name: &str,
    id: &str,
) -> Result<Vec<String>, String> {
    with_resident_daemon_quiesced(data, resident, "index composition rebuild", daemon, || {
        run_composition_on_estate(estate, name, Some(id))
    })
    .unwrap_or_else(|| {
        Err("the resident daemon would not stop; nothing was changed. Stop it and run `mootx01 db composition --set` again".to_string())
    })
}

/// Show the stored setting, or store `set` and rebuild every index lane
/// under it. Returns the lines to print. A malformed `set` is refused before
/// the estate is opened, so nothing is written.
pub(crate) fn run_composition_on_estate(
    estate: &str,
    name: &str,
    set: Option<&str>,
) -> Result<Vec<String>, String> {
    let requested = match set {
        Some(id) => Some(EstateCoordinator::index_composition_policy_id_parsing(id).ok_or_else(|| {
            format!(
                "'{id}' is not an index composition policy id (expected lex=<source>;dense=<source>, e.g. lex=original;dense=distilled)"
            )
        })?),
        None => None,
    };
    let mut lines = vec![format!("estate: {name}")];
    let Some(requested) = requested else {
        // Opening through the registry runs the migration chain, which seeds
        // the setting on an estate that predates it.
        let reg = EstateRegistry::new_sqlite(estate, OWNER)?;
        let stored = {
            let coord = reg.coord.lock().map_err(|e| format!("coordinator lock poisoned: {e}"))?;
            coord
                .stored_index_composition_policy_id(&reg.default.handle)
                .map_err(|e| format!("{e:?}"))?
        };
        lines.push(format!("index_composition_policy: {}", stored.unwrap_or_else(|| "none".to_string())));
        return Ok(lines);
    };
    let start = Instant::now();
    let now_ms = wall_now_millis();
    // The estate opens through the kit, not the registry: the registry's
    // serving open refuses a Corpus whose index rows disagree with the stored
    // setting, and that is exactly the state this command creates between
    // writing the setting and rebuilding the rows. Same call tree as Swift
    // DbCompositionCommand: open + migration chain, then
    // 1. Store the setting. 2. Wire the Corpus under it with the rebuild
    // committed (its rows still carry the old id). 3. Drain the encode
    // queue. 4. Rebuild every lane. 5. Prove every active row now carries
    // the new id.
    let (mut coord, handle, storage) = open_estate_for_rebuild(estate, now_ms)?;
    let stored = coord
        .set_index_composition_policy_id(&handle, &requested)
        .map_err(|e| format!("{e:?}"))?;
    coord
        .wire_glk_substores(&handle, storage, default_ensemble(), now_ms, true)
        .map_err(|e| format!("{e:?}"))?;
    // Drain to empty BEFORE the rebuild. A job left pending by an earlier
    // process (a capture whose encode had not run when that process exited)
    // would otherwise be indexed by this command's own drain worker while
    // `reindex_corpus` runs, and the interleaving would decide the row's
    // final state. Drained here, every pending job is indexed under the
    // stored setting first; the rebuild then rewrites every row. Twin of the
    // Swift command's `awaitEncodeDrain(for:)`.
    coord.await_encode_drain(&handle).map_err(|e| format!("{e:?}"))?;
    coord.reindex_corpus(&handle, now_ms).map_err(|e| format!("{e:?}"))?;
    let counts = coord
        .index_composition_policy_row_counts(&handle)
        .map_err(|e| format!("{e:?}"))?;
    coord.close(&handle).map_err(|e| format!("{e:?}"))?;
    let reindexed = counts.get(&stored).copied().unwrap_or(0);
    let stale: Vec<String> = counts
        .iter()
        .filter(|(id, _)| *id != &stored)
        .map(|(id, n)| format!("{id}: {n}"))
        .collect();
    lines.push(format!("index_composition_policy: {stored}"));
    lines.push(format!("rows reindexed: {reindexed}"));
    lines.push(format!("elapsed: {:.1}s", start.elapsed().as_secs_f64()));
    if !stale.is_empty() {
        return Err(format!(
            "rows still carry another policy after the rebuild ({})",
            stale.join(", ")
        ));
    }
    Ok(lines)
}

/// SQLite busy timeout for the rebuild open, the registry's serving value.
const SQLITE_BUSY_TIMEOUT_SECS: f64 = 5.0;

/// Wall clock in epoch milliseconds at the command boundary; the kits never
/// read the clock themselves.
fn wall_now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Open `estate` through the kit for a rebuild: geometry normalization (the
/// pre-open step every Rust host runs so VACUUM and ATTACH see a reserve-0
/// file), `SqliteDrawerStore::from_path` (adopts the sibling install key),
/// `EstateCoordinator::open`, then the compiled migration chain, which seeds
/// the setting on an estate that predates it. No Corpus is wired here; the
/// caller wires it with the rebuild committed. Returns the coordinator, the
/// handle, and the estate's own storage for the Corpus to build on. Twin of
/// Swift DbCompositionCommand's `kit.open` + `GLKMigrationCatalog.prepare`.
fn open_estate_for_rebuild(
    estate: &str,
    now_ms: i64,
) -> Result<(EstateCoordinator, EstateHandle, Arc<dyn Storage>), String> {
    if let Err(e) = genius_locus_kit_migrations::run_geometry_normalization(Path::new(estate)) {
        eprintln!(
            "mootx01 db composition: geometry normalization for {estate}: {e:?} (parked; VACUUM will surface this)"
        );
    }
    let store: Arc<dyn DrawerStore> = Arc::new(
        SqliteDrawerStore::from_path(estate, now_ms, None, SQLITE_BUSY_TIMEOUT_SECS)
            .map_err(|e| format!("cannot open SQLite estate at {estate}: {e}"))?,
    );
    let storage = store
        .storage()
        .ok_or_else(|| format!("SqliteDrawerStore at {estate} did not expose its backing Storage"))?;
    let mut coord = EstateCoordinator::new();
    let handle = coord
        .open(store, OwnerCredentials::new(OWNER), 0, 100)
        .map_err(|e| format!("{e:?}"))?;
    coord
        .run_migration_chain(&handle, now_ms, default_ensemble())
        .map_err(|e| format!("estate migration chain: {e}"))?;
    Ok((coord, handle, storage))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_data(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("mootx01-db-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn list_estates_sorted_dirs_only() {
        let data = tmp_data("list");
        std::fs::create_dir_all(data.join("databases/work")).unwrap();
        std::fs::create_dir_all(data.join("databases/default")).unwrap();
        std::fs::write(data.join("databases/strayfile"), b"x").unwrap();
        assert_eq!(list_estates(&data), vec!["default", "work"]);
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn name_validation_blocks_traversal() {
        assert!(!valid_name("../evil"));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(""));
        assert!(valid_name("work"));
    }

    #[test]
    fn open_rejects_traversal_name() {
        let data = tmp_data("open-traversal");
        std::fs::create_dir_all(data.join("databases")).unwrap();
        // "../work" would join outside databases/; open must reject it before
        // touching the filesystem so no speculative probe leaks path info.
        let code = open(&data, "../work");
        assert_ne!(code, ExitCode::from(exit::OK), "open should reject traversal names");
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn delete_rejects_traversal_name() {
        let data = tmp_data("delete-traversal");
        std::fs::create_dir_all(data.join("databases")).unwrap();
        // An attacker supplying "../databases" as the name would attempt to
        // delete the whole databases/ directory; the validation gate stops it.
        let code = delete(&data, "../databases", true);
        assert_ne!(code, ExitCode::from(exit::OK), "delete should reject traversal names");
        let _ = std::fs::remove_dir_all(&data);
    }

    /// `db create --no-encrypt` records the opt-out marker beside the estate
    /// and mints NO key; the first serve then creates the estate plaintext.
    #[test]
    fn create_no_encrypt_writes_marker_and_mints_no_key() {
        let data = tmp_data("create-optout");
        let code = create(&data, "work", true);
        assert_eq!(code, ExitCode::from(exit::OK));
        let dir = estate_dir(&data, "work");
        assert!(dir.join(crate::core::encrypt_optout::ENCRYPTION_OPT_OUT_MARKER_NAME).exists());
        assert!(!dir.join(aria_mcp::INSTALL_KEY_FILE).exists(), "--no-encrypt must not mint a key");
        let _ = std::fs::remove_dir_all(&data);
    }

    /// Default `db create` mints db.key eagerly (a failure surfaces at create
    /// time, and delete disposes of the key with the directory — symmetric)
    /// and leaves no opt-out marker behind.
    #[test]
    fn create_default_mints_key_and_leaves_no_marker() {
        let data = tmp_data("create-default");
        let code = create(&data, "work", false);
        assert_eq!(code, ExitCode::from(exit::OK));
        let dir = estate_dir(&data, "work");
        assert!(
            !dir.join(crate::core::encrypt_optout::ENCRYPTION_OPT_OUT_MARKER_NAME).exists(),
            "default create must not leave an opt-out marker"
        );
        assert!(dir.join(aria_mcp::INSTALL_KEY_FILE).exists(), "default create mints db.key eagerly");
        let _ = std::fs::remove_dir_all(&data);
    }

    fn temp_estate() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("estate.sqlite").to_string_lossy().into_owned();
        (dir, path)
    }

    /// File one memory through a serving registry and, when `drain` is
    /// set, wait for its encode job to be indexed before the registry goes.
    /// Undrained, the job may still be pending on disk when the registry is
    /// released; releasing the registry stops its drain worker either way.
    fn file_memory_with(estate: &str, content: &str, drain: bool) {
        use aria_mcp::jsonrpc::JsonValue;
        use aria_mcp::surfaced_recall_ledger::SurfacedRecallLedger;
        let reg = EstateRegistry::new_sqlite(estate, OWNER).expect("open");
        let mut args: std::collections::BTreeMap<String, JsonValue> = std::collections::BTreeMap::new();
        args.insert("content".into(), JsonValue::from(serde_json::json!(content)));
        args.insert("subject".into(), JsonValue::from(serde_json::json!(content)));
        args.insert("location".into(), JsonValue::from(serde_json::json!("composition-cli")));
        let result = aria_mcp::dispatch::dispatch_tool("moot_file_memory", &args, &reg, &SurfacedRecallLedger::new())
            .expect("file memory");
        assert!(!result["isError"].as_bool().unwrap_or(false), "{result}");
        if drain {
            reg.coord
                .lock()
                .unwrap()
                .await_encode_drain(&reg.default.handle)
                .expect("await the encode drain");
        }
    }

    /// File one memory and wait for it to be indexed: the fixture every
    /// test that reasons about index rows starts from.
    fn file_memory(estate: &str, content: &str) {
        file_memory_with(estate, content, true);
    }

    fn resident_and_scratch() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let tmp = tempfile::tempdir().expect("tempdir");
        let resident = tmp.path().join("resident");
        let scratch = tmp.path().join("resident-bench");
        std::fs::create_dir_all(&resident).expect("resident dir");
        std::fs::create_dir_all(&scratch).expect("scratch dir");
        (tmp, resident, scratch)
    }

    /// Two memories filed with their encode jobs left undrained on purpose,
    /// then `--set`: the command drains the queue under the new setting
    /// before the rebuild, every active row ends under the new id, and a
    /// plain serving open succeeds. The hazard this pins: a drain worker
    /// that outlives its released registry indexes the second memory under
    /// the old id after the rebuild, and the reopen refuses the estate; the
    /// kits' drain_worker_ownership_tests pin that no worker outlives its
    /// engine.
    #[test]
    fn composition_set_rebuilds_with_encode_jobs_left_undrained() {
        let (_dir, estate) = temp_estate();
        file_memory_with(&estate, "composition cli undrained content one", false);
        file_memory_with(&estate, "composition cli undrained content two", false);
        let new_id = "lex=originalPlusAdornments;dense=distilled";
        let set = run_composition_on_estate(&estate, "t", Some(new_id)).expect("set");
        assert_eq!(set[1], format!("index_composition_policy: {new_id}"));
        let reindexed: usize = set[2]
            .strip_prefix("rows reindexed: ")
            .and_then(|n| n.parse().ok())
            .expect("rows reindexed line");
        assert!(reindexed >= 2, "{set:?}");

        let reg = EstateRegistry::new_sqlite(&estate, OWNER).expect("a serving open succeeds");
        let coord = reg.coord.lock().unwrap();
        let counts = coord
            .index_composition_policy_row_counts(&reg.default.handle)
            .expect("row counts");
        assert_eq!(counts.keys().collect::<Vec<_>>(), vec![new_id], "{counts:?}");
        assert!(counts[new_id] >= 2, "{counts:?}");
    }

    /// The resident estate: the daemon is stopped before the rebuild and
    /// restarted after it, and the rebuild itself lands.
    #[test]
    fn composition_set_on_the_resident_estate_stops_then_restarts_the_daemon() {
        use crate::commands::upgrade::daemon_test_support::RecordingDaemon;
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli resident content");
        let daemon = RecordingDaemon::new(true, true);
        let new_id = "lex=originalPlusAdornments;dense=distilled";
        let lines = set_composition_quiesced(&resident, &resident, &daemon, &estate, "t", new_id)
            .expect("set on the resident estate");
        assert_eq!(lines[1], format!("index_composition_policy: {new_id}"));
        assert_eq!(daemon.calls(), vec!["is_running", "stop", "start"]);
        EstateRegistry::new_sqlite(&estate, OWNER).expect("the estate serves again");
    }

    /// A clone beside the resident directory: the daemon has no stake in it
    /// and is left alone.
    #[test]
    fn composition_set_on_a_clone_leaves_the_daemon_alone() {
        use crate::commands::upgrade::daemon_test_support::RecordingDaemon;
        let (_tmp, resident, scratch) = resident_and_scratch();
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli clone content");
        let daemon = RecordingDaemon::new(true, true);
        let new_id = "lex=originalPlusAdornments;dense=distilled";
        let lines = set_composition_quiesced(&scratch, &resident, &daemon, &estate, "t", new_id)
            .expect("set on a clone");
        assert_eq!(lines[1], format!("index_composition_policy: {new_id}"));
        assert!(daemon.calls().is_empty(), "a clone must not touch the daemon: {:?}", daemon.calls());
    }

    /// The resident estate with the daemon down: nothing is started.
    #[test]
    fn composition_set_with_the_daemon_down_never_starts_one() {
        use crate::commands::upgrade::daemon_test_support::RecordingDaemon;
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli daemon down content");
        let daemon = RecordingDaemon::new(false, true);
        let new_id = "lex=originalPlusAdornments;dense=distilled";
        set_composition_quiesced(&resident, &resident, &daemon, &estate, "t", new_id)
            .expect("set with the daemon down");
        assert_eq!(daemon.calls(), vec!["is_running"]);
    }

    /// A daemon that will not stop: the rebuild is refused and the stored
    /// setting is untouched.
    #[test]
    fn composition_set_is_refused_when_the_daemon_will_not_stop() {
        use crate::commands::upgrade::daemon_test_support::RecordingDaemon;
        let (_tmp, resident, _scratch) = resident_and_scratch();
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli stubborn daemon content");
        let daemon = RecordingDaemon::new(true, false);
        let new_id = "lex=originalPlusAdornments;dense=distilled";
        let err = set_composition_quiesced(&resident, &resident, &daemon, &estate, "t", new_id)
            .expect_err("refused");
        assert!(err.contains("would not stop"), "{err}");
        assert_eq!(daemon.calls(), vec!["is_running", "stop"]);
        let shown = run_composition_on_estate(&estate, "t", None).expect("show");
        assert_eq!(shown[1], "index_composition_policy: lex=original;dense=distilled");
    }

    /// A fresh estate shows the production default; `--set` stores a new id,
    /// rebuilds every row under it, and the next show reports it.
    #[test]
    fn composition_shows_then_sets_and_reindexes() {
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli test content one");
        file_memory(&estate, "composition cli test content two");

        let shown = run_composition_on_estate(&estate, "t", None).expect("show");
        assert_eq!(shown, vec![
            "estate: t".to_string(),
            "index_composition_policy: lex=original;dense=distilled".to_string(),
        ]);

        let new_id = "lex=originalPlusAdornments;dense=distilled";
        let set = run_composition_on_estate(&estate, "t", Some(new_id)).expect("set");
        assert_eq!(set[0], "estate: t");
        assert_eq!(set[1], format!("index_composition_policy: {new_id}"));
        let reindexed: usize = set[2]
            .strip_prefix("rows reindexed: ")
            .and_then(|n| n.parse().ok())
            .expect("rows reindexed line");
        assert!(reindexed >= 2, "both filed items are active and must be reindexed; got {reindexed}");
        assert!(set[3].starts_with("elapsed: "), "{set:?}");

        // Every active index row now carries the new id, and the stored
        // setting reads it back.
        let reg = EstateRegistry::new_sqlite(&estate, OWNER).expect("reopen");
        let coord = reg.coord.lock().unwrap();
        let counts = coord
            .index_composition_policy_row_counts(&reg.default.handle)
            .expect("row counts");
        assert_eq!(counts.keys().collect::<Vec<_>>(), vec![new_id]);
        assert_eq!(
            coord.stored_index_composition_policy_id(&reg.default.handle).expect("read"),
            Some(new_id.to_string())
        );
        assert_eq!(
            coord.index_composition_policy(&reg.default.handle).map(|p| p.id()),
            Some(new_id.to_string())
        );
    }

    /// Rows built under the default policy with the stored setting flipped
    /// to another id and no rebuild: the registry's serving open refuses the
    /// estate with the engine's exact mismatch detail, and `--set` still
    /// rebuilds it because its open commits to the rebuild. Afterwards the
    /// estate serves again with every active row under the new id.
    #[test]
    fn composition_set_rebuilds_an_estate_a_serving_open_refuses() {
        const NOW: i64 = 1_700_000_000_000;
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli mismatch content one");
        file_memory(&estate, "composition cli mismatch content two");
        let new_id = "lex=originalPlusAdornments;dense=distilled";
        {
            let reg = EstateRegistry::new_sqlite(&estate, OWNER).expect("open");
            let coord = reg.coord.lock().unwrap();
            coord.reindex_corpus(&reg.default.handle, NOW).expect("reindex under the default");
            let counts = coord
                .index_composition_policy_row_counts(&reg.default.handle)
                .expect("row counts");
            assert_eq!(counts.keys().collect::<Vec<_>>(), vec!["lex=original;dense=distilled"]);
            assert!(counts["lex=original;dense=distilled"] >= 2, "{counts:?}");
            coord
                .set_index_composition_policy_id(&reg.default.handle, new_id)
                .expect("flip the stored setting without a rebuild");
        }
        let refused = EstateRegistry::new_sqlite(&estate, OWNER)
            .err()
            .expect("a serving open must refuse rows built under another policy");
        assert!(
            refused.contains(
                "CompositionPolicyMismatch(\"recorded=lex=original;dense=distilled;configured=lex=originalPlusAdornments;dense=distilled\")"
            ),
            "{refused}"
        );

        let set = run_composition_on_estate(&estate, "t", Some(new_id)).expect("set");
        assert_eq!(set[1], format!("index_composition_policy: {new_id}"));
        let reindexed: usize = set[2]
            .strip_prefix("rows reindexed: ")
            .and_then(|n| n.parse().ok())
            .expect("rows reindexed line");
        assert!(reindexed >= 2, "{set:?}");

        let reg = EstateRegistry::new_sqlite(&estate, OWNER).expect("the estate serves again");
        let coord = reg.coord.lock().unwrap();
        let counts = coord
            .index_composition_policy_row_counts(&reg.default.handle)
            .expect("row counts");
        assert_eq!(counts.keys().collect::<Vec<_>>(), vec![new_id]);
        assert_eq!(
            coord.stored_index_composition_policy_id(&reg.default.handle).expect("read"),
            Some(new_id.to_string())
        );
    }

    /// An invalid id is refused before the estate is opened or written.
    #[test]
    fn composition_refuses_an_invalid_id_before_any_write() {
        let (_dir, estate) = temp_estate();
        file_memory(&estate, "composition cli invalid id content");
        let before = std::fs::metadata(&estate).expect("estate file").modified().expect("mtime");
        let err = run_composition_on_estate(&estate, "t", Some("cell B")).expect_err("refused");
        assert!(err.contains("not an index composition policy id"), "{err}");
        let after = std::fs::metadata(&estate).expect("estate file").modified().expect("mtime");
        assert_eq!(before, after, "a refused --set must not touch the estate");
        let shown = run_composition_on_estate(&estate, "t", None).expect("show");
        assert_eq!(shown[1], "index_composition_policy: lex=original;dense=distilled");
    }

    /// Deleting an estate removes the whole directory — including the encryption
    /// key (db.key) and the SQLCipher sidecars — so the key never outlives the
    /// data it protected.
    #[test]
    fn delete_removes_database_sidecars_and_key() {
        let data = tmp_data("delete-key");
        let dir = estate_dir(&data, "work");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("estate.sqlite"), b"ciphertext").unwrap();
        std::fs::write(dir.join("estate.sqlite-wal"), b"wal").unwrap();
        std::fs::write(dir.join("db.key"), b"0123456789abcdef0123456789abcdef").unwrap();

        let _ = delete(&data, "work", true);
        assert!(!dir.exists(), "estate dir removed");
        assert!(!dir.join("db.key").exists(), "encryption key removed");
        let _ = std::fs::remove_dir_all(&data);
    }
}
