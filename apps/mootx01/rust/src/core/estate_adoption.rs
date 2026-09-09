//! core/estate_adoption.rs — Windows base-directory adoption helper.
//!
//! Provides `adopt_before_catalog_open`, which moves a pre-catalog Windows
//! install's data from the old base into the catalog's base directory before
//! any catalog open. This module is consumed by `core::estate_open`, which
//! sequences the adoption step before the catalog open for every command.
//! The funnel that every command uses is in `core::estate_open`, not here.
//!
//! A pre-catalog Windows install kept everything under `%LOCALAPPDATA%\MOOTx01`;
//! the catalog's base directory is `%LOCALAPPDATA%\com.mootx01.ce`. The
//! capsule that moves the old base lives in `genius-locus-kit-migrations`
//! (`windows_base_directory_adoption`); this module is the command layer's
//! single entry point to it.
//!
//! Why every command and not just `install` and `upgrade`: ruling R4 says
//! "first run", and on Windows the first run after an upgrade is not a
//! command the operator typed. The Inno Setup installer swaps the executable
//! and the Scheduled Task fires `mootx01 serve --http auto` at the next
//! logon. That serve opens the catalog, creates
//! `%LOCALAPPDATA%\com.mootx01.ce\databases\default\`, and the post-install
//! `mootx01 install` then meets a `databases` collision it can only refuse.
//! The adoption has to be ahead of whichever command opens the catalog first,
//! so it is ahead of all of them.
//!
//! Cost on a machine with nothing to adopt: one `Option` that is `None`.
//! `legacy_windows_base_directory()` returns `None` on every non-Windows host
//! before touching the filesystem, and on Windows an adopted machine fails
//! `windows_base_adoption_pending` on one `read_dir`.

use std::path::PathBuf;

use genius_locus_kit::EstateCatalog;
use genius_locus_kit_migrations::WindowsBaseAdoptionOutcome;

/// Test seam: the old base directory the capsule reads, so a test on any host
/// can drive the Windows-only path over a fabricated layout. Process-global,
/// so tests that set it serialize on their own lock.
#[cfg(test)]
static LEGACY_BASE_OVERRIDE: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

/// The one lock every test in this crate takes before it redirects the estate
/// catalog's configuration directory or this module's legacy-base seam.
///
/// Both seams are process-global and `cargo test` runs the crate's unit tests
/// on many threads, so two modules guarding one global with two different
/// mutexes serialize against themselves and race each other. That is not
/// hypothetical: it is what `commands::db::tests` and this module's tests did
/// on their first full-suite run, and two db tests read another test's
/// scratch directory. One global, one lock.
#[cfg(test)]
pub(crate) static CONFIGURATION_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Test seam setter. `None` restores the real per-host resolution.
#[cfg(test)]
pub fn set_legacy_base_override(dir: Option<PathBuf>) {
    *LEGACY_BASE_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner()) = dir;
}

fn legacy_base() -> Option<PathBuf> {
    #[cfg(test)]
    if let Some(dir) = LEGACY_BASE_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner()).clone() {
        return Some(dir);
    }
    genius_locus_kit_migrations::legacy_windows_base_directory()
}

/// Move a pre-catalog Windows base directory into the catalog's. Call this
/// before the command's first `EstateCatalog::open` or `open_selecting`.
///
/// A no-op on every non-Windows host and on every adopted machine, so the
/// call is unconditional and carries no command-specific reasoning.
///
/// Returns `Err(message)` when the capsule refused (both bases hold the same
/// child) or a rename failed. The message is ready to print and names what
/// the operator must do; the caller stops the command there, before the
/// catalog opens, because an estate the command cannot see is worse than a
/// command that will not start.
pub fn adopt_before_catalog_open() -> Result<(), String> {
    let Some(legacy) = legacy_base() else { return Ok(()) };
    if !genius_locus_kit_migrations::windows_base_adoption_pending(&legacy) {
        return Ok(());
    }
    let configuration = EstateCatalog::configuration_directory();
    match genius_locus_kit_migrations::run_windows_base_adoption(&legacy, &configuration) {
        Ok(WindowsBaseAdoptionOutcome::NothingToMove) => Ok(()),
        Ok(WindowsBaseAdoptionOutcome::Moved { entries }) => {
            println!(
                "  ✓ data directory: moved {} item(s) from {} into {}",
                entries.len(),
                legacy.display(),
                configuration.display()
            );
            Ok(())
        }
        Ok(WindowsBaseAdoptionOutcome::Refused { legacy, current }) => Err(format!(
            "mootx01: two copies of the same item and nothing was changed.\n  \
             old: {}\n  new: {}\n  Move or remove one of them, then run the command again.",
            legacy.display(),
            current.display()
        )),
        Err(e) => Err(format!(
            "mootx01: data directory adoption failed: {e}\n  \
             The old directory is still in place. Run the command again to resume."
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use std::sync::MutexGuard;

    struct Scratch {
        root: PathBuf,
        legacy: PathBuf,
        configuration: PathBuf,
        _guard: MutexGuard<'static, ()>,
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            set_legacy_base_override(None);
            EstateCatalog::set_configuration_directory_override(None);
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    /// An old Windows base holding one estate and the lattice pool, beside an
    /// empty catalog base. Both seams point at them.
    fn scratch(tag: &str) -> Scratch {
        let guard = CONFIGURATION_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let root = std::env::temp_dir().join(format!("mootx01-adopt-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        let legacy = root.join("MOOTx01");
        let configuration = root.join("com.mootx01.ce");
        write(&legacy.join("databases/default/estate.sqlite"), "estate-bytes");
        write(&legacy.join("lattice/WordClassTable.json"), "{\"merged\":true}");
        set_legacy_base_override(Some(legacy.clone()));
        EstateCatalog::set_configuration_directory_override(Some(configuration.clone()));
        Scratch { root, legacy, configuration, _guard: guard }
    }

    fn write(path: &Path, body: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }

    #[test]
    fn the_db_command_adopts_before_its_catalog_open() {
        let s = scratch("db-open");

        // `db` reaches the catalog through one function, so this covers every
        // db subcommand. A successful open must find the estate already at
        // the catalog's base.
        let catalog = crate::commands::db::open_catalog().expect("the catalog opens");
        let record = catalog.record_named(EstateCatalog::DEFAULT_NAME).expect("the default record");
        assert_eq!(record.directory, s.configuration.join("databases").join("default"));
        assert_eq!(
            fs::read_to_string(record.directory.join("estate.sqlite")).unwrap(),
            "estate-bytes",
            "the adopted estate sits where the record names it"
        );
        assert!(
            s.configuration.join("lattice/WordClassTable.json").exists(),
            "the lattice pool came with the estate"
        );
        assert!(!s.legacy.exists(), "the emptied old base is gone");
    }

    #[test]
    fn a_refusal_stops_the_db_command_before_it_gets_a_catalog() {
        let s = scratch("db-refuse");
        // The W-1 scenario: a serve at logon already created the catalog base's
        // databases folder, so the two bases collide.
        write(&s.configuration.join("databases/default/estate.sqlite"), "new-estate");

        let error = crate::commands::db::open_catalog()
            .expect_err("a colliding base must stop the command");
        assert!(error.contains("two copies of the same item"), "got: {error}");
        // A refusal is all-or-nothing: no db subcommand gets a catalog, and
        // the machine is exactly as it was. Ordering within the function is
        // guarded separately, by the source scan below.
        assert_eq!(
            fs::read_to_string(s.legacy.join("databases/default/estate.sqlite")).unwrap(),
            "estate-bytes",
            "a refusal leaves the old base untouched"
        );
        assert!(!s.configuration.join("lattice").exists(), "and moves nothing");
    }

    #[test]
    fn an_adopted_machine_opens_normally() {
        let s = scratch("db-idempotent");
        crate::commands::db::open_catalog().expect("first open adopts");
        let catalog = crate::commands::db::open_catalog().expect("second open is plain");
        assert_eq!(catalog.active().name, EstateCatalog::DEFAULT_NAME);
        assert!(!s.legacy.exists());
    }
}
