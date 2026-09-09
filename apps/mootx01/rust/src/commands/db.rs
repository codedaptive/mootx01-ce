//! commands/db.rs — §4.4: estate lifecycle through the catalog: create,
//! register, unregister, list, open (activate), delete.
//!
//! Every estate is a directory named for the estate, holding its files and
//! its manifest (`estate.json`). `EstateCatalog` is the only thing that knows
//! where estates are. `<value>` arguments follow the catalog's one rule: a
//! bare name means the default database location under the configuration
//! directory; a pathname means exactly that place.
//!
//!   db create <name>            create at the default location and register it
//!   db create <dir>/<name>      create at that place, unregistered and therefore
//!                               plaintext (`--no-encrypt` required); `--db
//!                               <dir>/<name>` attaches it
//!   db register <value>         register an estate that already exists
//!   db unregister <name>        forget a registered estate; files untouched
//!   db list                     the catalog, active first
//!   db open <name>              make a registered estate the active one
//!   db delete <name>            remove a registered estate's files and record
//!
//! Twin of Swift DbCommand. Both ports use `--yes`/`-y` for the delete
//! confirmation flag. An aborted delete prints "Aborted." and exits 0,
//! matching Swift DbCommand behaviour (I2-2).

use std::io::{self, BufRead, Write};
use std::process::ExitCode;

use genius_locus_kit::estate_format::EstateFormatVersion;
use genius_locus_kit::{
    EstateBackend, EstateCatalog, EstateCatalogNames, EstateManifest, EstateManifestEncryption,
    EstateRecord, EstateRecordKind, EstateSelector,
};
use genius_locus_kit_migrations::{composite_schema_version, iso8601_utc};

use crate::cli::DbCommand;
use crate::exit;

pub fn run(cmd: DbCommand) -> ExitCode {
    let now_millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let result = match cmd {
        DbCommand::Create { value, no_encrypt } => create(&value, no_encrypt, now_millis),
        DbCommand::Register { value } => register(&value),
        DbCommand::Unregister { name } => unregister(&name),
        DbCommand::List => list(),
        DbCommand::Open { name } => open(&name),
        DbCommand::Delete { name, yes } => delete(&name, yes, || confirm_on_stdin()),
    };
    match result {
        Ok(()) => ExitCode::from(exit::OK),
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(exit::FAILURE)
        }
    }
}

/// The catalog every `db` subcommand works through. `pub(crate)` so the
/// adoption-ordering tests in `core::estate_open` can drive the real
/// entry point rather than a copy of it.
pub(crate) fn open_catalog() -> Result<EstateCatalog, String> {
    // Routes through the funnel: Windows base-directory adoption first (no-op
    // on non-Windows and adopted machines), then EstateCatalog::open().
    crate::core::estate_open::catalog(None)
}

/// The record a `<value>` names: a bare name lands under the catalog's default
/// location (registered), a pathname at exactly that place (transient).
fn record_for(catalog: &EstateCatalog, selector: &EstateSelector) -> EstateRecord {
    let directory = selector.directory().unwrap_or_else(|| catalog.directory_for_bare_name(&selector.name));
    let kind = if selector.path.is_none() { EstateRecordKind::Registered } else { EstateRecordKind::Transient };
    EstateRecord::with(&selector.name, directory, kind, EstateBackend::Sqlite)
}

fn create(value: &str, no_encrypt: bool, now_millis: i64) -> Result<(), String> {
    let mut catalog = open_catalog()?;
    let selector = EstateSelector::parse(value).map_err(|e| e.to_string())?;
    let registered = selector.path.is_none();
    let record = record_for(&catalog, &selector);
    let dir = record.directory.clone();
    let shown = dir.display();

    if registered && catalog.record_named(&record.name).is_some() {
        return Err(format!("an estate named '{}' is already registered", record.name));
    }
    // Only a registered estate, owned by this machine, may be encrypted with a
    // key this machine keeps. An unregistered estate is plaintext by definition.
    if !registered && !no_encrypt {
        return Err(format!(
            "'{shown}' would be an unregistered estate, and only a registered estate can be encrypted. Pass --no-encrypt, or create it by name and register it."
        ));
    }
    if dir.exists() {
        return Err(format!("'{shown}' already exists; delete it or choose another name"));
    }

    // The directory and the manifest are the estate's identity on disk; the
    // substrate writes the SQLite file lazily on first open. The encryption
    // posture is settled here, in the manifest, before the file exists — the
    // same record install writes.
    std::fs::create_dir_all(&dir).map_err(|e| format!("could not create '{shown}': {e}"))?;
    // Leave nothing behind on any later failure. An estate directory whose key
    // could not be provisioned would otherwise be opened as plaintext later,
    // silently contradicting the default the user did not opt out of.
    let fail_closed = |error: String| -> String {
        let _ = std::fs::remove_dir_all(&dir);
        format!(
            "could not prepare estate '{}': {error}. Nothing was created. Use --no-encrypt to create an unencrypted estate.",
            record.name
        )
    };
    let manifest = EstateManifest::new(
        &record.name,
        composite_schema_version(),
        EstateFormatVersion::CURRENT,
        if no_encrypt { EstateManifestEncryption::Plaintext } else { EstateManifestEncryption::Encrypted },
        iso8601_utc(now_millis),
    );
    EstateCatalog::write_manifest(&manifest, &record).map_err(|e| fail_closed(e.to_string()))?;

    // The manifest written above is the record of the posture. Plaintext needs
    // nothing more; an encrypted registered estate gets its key now. Rust key
    // custody is `db.key` beside the database: minting it here rather than at
    // first open surfaces a failure while nothing is half-made, and delete
    // disposes of the key with the directory, which keeps create and delete
    // symmetric.
    if !no_encrypt {
        aria_mcp::ensure_install_key(&dir).map_err(|e| fail_closed(e.to_string()))?;
    }

    if registered {
        catalog
            .register(&record.name, &dir, EstateBackend::Sqlite)
            .map_err(|e| fail_closed(e.to_string()))?;
    }

    let posture = if no_encrypt { "UNENCRYPTED, --no-encrypt" } else { "encrypted at rest" };
    println!("Created estate '{}' at {shown} ({posture}).", record.name);
    if no_encrypt {
        println!("  Run `mootx01 upgrade` at any time to encrypt it.");
    }
    if registered {
        println!("Run `mootx01 db open {}` to make it the active estate.", record.name);
    } else {
        println!("Unregistered: attach it with `--db {shown}`, or `mootx01 db register {shown}`.");
    }
    Ok(())
}

fn register(value: &str) -> Result<(), String> {
    let mut catalog = open_catalog()?;
    let selector = EstateSelector::parse(value).map_err(|e| e.to_string())?;
    let record = record_for(&catalog, &selector);
    if !record.manifest_path().exists() {
        return Err(format!(
            "no estate at {}: its {} is missing",
            record.directory.display(),
            EstateCatalogNames::MANIFEST
        ));
    }
    // Names this estate, files inside, no redirects.
    EstateCatalog::read_manifest(&record).map_err(|e| e.to_string())?;
    catalog
        .register(&record.name, &record.directory, EstateBackend::Sqlite)
        .map_err(|e| e.to_string())?;
    println!("Registered estate '{}' at {}.", record.name, record.directory.display());
    Ok(())
}

fn unregister(name: &str) -> Result<(), String> {
    let mut catalog = open_catalog()?;
    let Some(record) = catalog.record_named(name).cloned() else {
        return Err(format!("no estate named '{name}' is registered. Run `mootx01 db list`."));
    };
    catalog.remove(name).map_err(|e| e.to_string())?;
    println!("Unregistered estate '{name}'; its files remain at {}.", record.directory.display());
    Ok(())
}

fn list() -> Result<(), String> {
    let catalog = open_catalog()?;
    println!("Estates (default location {}):", catalog.default_location.display());
    for (index, record) in catalog.records().iter().enumerate() {
        let marker = if index == 0 { " (active)" } else { "" };
        println!("  {}{marker}  {}", record.name, record.directory.display());
    }
    Ok(())
}

fn open(name: &str) -> Result<(), String> {
    let mut catalog = open_catalog()?;
    let selector = EstateSelector::parse(name).map_err(|e| e.to_string())?;
    if selector.path.is_some() {
        return Err(format!(
            "`db open` takes a registered name; register '{name}' first with `mootx01 db register`, or attach it for one invocation with `--db {name}`."
        ));
    }
    if catalog.record_named(&selector.name).is_none() {
        return Err(format!("no estate named '{}' is registered. Run `mootx01 db list`.", selector.name));
    }
    catalog.activate(&selector.name).map_err(|e| e.to_string())?;
    println!("Active estate set to '{}'.", selector.name);
    Ok(())
}

/// Interactive confirmation for `db delete` without `--yes`.
fn confirm_on_stdin() -> bool {
    print!("Type 'yes' to confirm: ");
    let _ = io::stdout().flush();
    let mut line = String::new();
    let _ = io::stdin().lock().read_line(&mut line);
    line.trim().eq_ignore_ascii_case("yes")
}

fn delete(name: &str, yes: bool, confirm: impl FnOnce() -> bool) -> Result<(), String> {
    let mut catalog = open_catalog()?;
    let Some(record) = catalog.record_named(name).cloned() else {
        return Err(format!("no estate named '{name}' is registered. Run `mootx01 db list`."));
    };
    if name == EstateCatalog::DEFAULT_NAME {
        return Err("cannot delete 'default' (use uninstall --purge).".to_string());
    }
    if catalog.active().name == name {
        return Err(format!("'{name}' is the active estate; run `mootx01 db open <other>` first."));
    }
    if !yes {
        println!(
            "Delete estate '{name}' at {} and all its data? This is irreversible.",
            record.directory.display()
        );
        if !confirm() {
            // Abort exits 0 (no error): the user made a deliberate choice.
            // Matches Swift DbCommand behaviour.
            println!("Aborted.");
            return Ok(());
        }
    }

    // Files first, then the record: a failure mid-way leaves a record that
    // still points at whatever remains, never an orphan directory nobody can
    // find. Removing the directory disposes of everything in it: the SQLite
    // file, its -wal/-shm sidecars, and the whole-file encryption key
    // (db.key). The key never outlives the data it protected.
    EstateCatalog::verify_files_stay_inside(&record).map_err(|e| e.to_string())?;
    std::fs::remove_dir_all(&record.directory)
        .map_err(|e| format!("cannot delete estate '{name}': {e}"))?;
    catalog.remove(name).map_err(|e| e.to_string())?;
    println!("Estate '{name}' deleted.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::MutexGuard;

    /// The catalog's configuration directory is process-global, so the tests
    /// serialize and point it at a scratch directory each. The lock is the
    /// crate's one configuration-directory lock, shared with
    /// `core::estate_adoption::tests`, which redirects the same global.
    use crate::core::estate_adoption::CONFIGURATION_TEST_LOCK as TEST_LOCK;

    struct Scratch {
        dir: PathBuf,
        _guard: MutexGuard<'static, ()>,
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            EstateCatalog::set_configuration_directory_override(None);
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn configuration(tag: &str) -> Scratch {
        let guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let dir = std::env::temp_dir().join(format!("mootx01-db-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        EstateCatalog::set_configuration_directory_override(Some(dir.clone()));
        Scratch { dir, _guard: guard }
    }

    #[test]
    fn create_registered_writes_manifest_mints_key_and_registers() {
        let s = configuration("create-registered");
        create("work", false, 1_788_825_600_000).unwrap();
        let catalog = EstateCatalog::open().unwrap();
        let record = catalog.record_named("work").expect("registered");
        assert_eq!(record.directory, s.dir.join("databases").join("work"));
        let manifest = EstateCatalog::read_manifest(record).unwrap();
        assert_eq!(manifest.encryption, EstateManifestEncryption::Encrypted);
        assert_eq!(manifest.created, "2026-09-08T00:00:00Z");
        assert!(record.directory.join(aria_mcp::INSTALL_KEY_FILE).exists(), "default create mints db.key");
        assert_eq!(catalog.active().name, "default", "create does not activate");
    }

    #[test]
    fn create_no_encrypt_records_plaintext_and_mints_no_key() {
        let s = configuration("create-plaintext");
        create("work", true, 0).unwrap();
        let record = EstateCatalog::open().unwrap().record_named("work").unwrap().clone();
        assert_eq!(EstateCatalog::read_manifest(&record).unwrap().encryption, EstateManifestEncryption::Plaintext);
        assert!(!record.directory.join(aria_mcp::INSTALL_KEY_FILE).exists(), "--no-encrypt mints no key");
        drop(s);
    }

    #[test]
    fn create_pathname_requires_no_encrypt_and_stays_unregistered() {
        let s = configuration("create-transient");
        let elsewhere = s.dir.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let value = format!("{}/scratch", elsewhere.display());
        let err = create(&value, false, 0).unwrap_err();
        assert!(err.contains("only a registered estate can be encrypted"), "{err}");
        assert!(!elsewhere.join("scratch").exists(), "nothing created on refusal");

        create(&value, true, 0).unwrap();
        assert!(elsewhere.join("scratch").join(EstateCatalogNames::MANIFEST).exists());
        assert!(EstateCatalog::open().unwrap().record_named("scratch").is_none(), "pathname stays unregistered");
    }

    #[test]
    fn create_refuses_duplicate_name_and_existing_directory() {
        let s = configuration("create-dup");
        create("work", true, 0).unwrap();
        assert!(create("work", true, 0).unwrap_err().contains("already registered"));
        std::fs::create_dir_all(s.dir.join("databases").join("other")).unwrap();
        assert!(create("other", true, 0).unwrap_err().contains("already exists"));
    }

    #[test]
    fn register_needs_a_manifest_and_unregister_keeps_files() {
        let s = configuration("register");
        let elsewhere = s.dir.join("elsewhere");
        let value = format!("{}/scratch", elsewhere.display());
        assert!(register(&value).unwrap_err().contains("is missing"));

        create(&value, true, 0).unwrap();
        register(&value).unwrap();
        let record = EstateCatalog::open().unwrap().record_named("scratch").unwrap().clone();
        assert_eq!(record.directory, elsewhere.join("scratch"));

        unregister("scratch").unwrap();
        assert!(EstateCatalog::open().unwrap().record_named("scratch").is_none());
        assert!(record.manifest_path().exists(), "files untouched");
        assert!(unregister("scratch").unwrap_err().contains("is registered"));
    }

    #[test]
    fn open_activates_registered_names_only() {
        let s = configuration("open");
        create("work", true, 0).unwrap();
        assert!(open("nope").unwrap_err().contains("no estate named"));
        assert!(open(&format!("{}/work", s.dir.display())).unwrap_err().contains("takes a registered name"));
        open("work").unwrap();
        assert_eq!(EstateCatalog::open().unwrap().active().name, "work");
    }

    #[test]
    fn delete_refuses_default_and_active_then_removes_files_and_record() {
        let s = configuration("delete");
        create("work", false, 0).unwrap();
        let dir = s.dir.join("databases").join("work");
        assert!(delete("default", true, || true).unwrap_err().contains("cannot delete 'default'"));
        open("work").unwrap();
        assert!(delete("work", true, || true).unwrap_err().contains("is the active estate"));
        open("default").unwrap();

        // Abort returns Ok(()) and exits 0 — the user made a deliberate choice.
        delete("work", false, || false).unwrap();
        assert!(dir.exists(), "an aborted delete touches nothing");

        std::fs::write(dir.join("estate.sqlite"), b"ciphertext").unwrap();
        delete("work", false, || true).unwrap();
        assert!(!dir.exists(), "estate dir removed with the database and db.key");
        assert!(EstateCatalog::open().unwrap().record_named("work").is_none());
        assert!(delete("work", true, || true).unwrap_err().contains("no estate named"));
    }

    #[test]
    fn delete_refuses_a_symlinked_estate_file() {
        let s = configuration("delete-symlink");
        create("work", true, 0).unwrap();
        let dir = s.dir.join("databases").join("work");
        let outside = s.dir.join("outside.sqlite");
        std::fs::write(&outside, b"x").unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("estate.sqlite")).unwrap();
        assert!(delete("work", true, || true).is_err(), "a file pointing outside the estate blocks delete");
        assert!(outside.exists());
    }
}
