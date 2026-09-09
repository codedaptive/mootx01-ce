//! core/estate_open.rs — the one call every command makes to open the estate
//! catalog.
//!
//! Both ports execute the same two steps in the same order:
//!
//!   (a) `windows_base_adoption`: move a pre-catalog Windows base directory
//!       into the catalog's base before the catalog can open. On non-Windows
//!       hosts and on already-adopted machines this is a fast no-op.
//!
//!   (b) `catalog_open`: `EstateCatalog::open()` or `EstateCatalog::open_selecting()`
//!       when a name or path is given.
//!
//! Both ports declare the same step list (`STEPS` here, `EstateOpen.steps` in
//! Swift). The parity test reads `Tests/Fixtures/estate_open_steps.json` and
//! verifies both lists match. A mutation that adds, removes, or reorders a
//! step must update the constant, the fixture, and both tests.
//!
//! The adoption logic lives in `core::estate_adoption`; this module is the
//! thin command-layer funnel that combines adoption + open into one call so
//! command code does not need to hold both steps in view.

use genius_locus_kit::EstateCatalog;

// ---------------------------------------------------------------------------
// Step list (parity constant — both ports declare the same list)
// ---------------------------------------------------------------------------

/// The ordered step names that `catalog()` executes.
///
/// Rust twin of Swift `EstateOpen.steps`. Both lists are verified against
/// `Tests/Fixtures/estate_open_steps.json` in each port's test suite.
pub const STEPS: [&str; 2] = ["windows_base_adoption", "catalog_open"];

// ---------------------------------------------------------------------------
// The funnel
// ---------------------------------------------------------------------------

/// Open the estate catalog, running the Windows base-directory adoption first.
///
/// - `selecting`: a registered estate name or `<dir>/<name>` path for a
///   transient estate. `None` opens the active estate.
///
/// Returns `Err(message)` when the adoption capsule refuses (two colliding
/// copies) or when `EstateCatalog::open*` fails. The message is ready to
/// print.
pub fn catalog(selecting: Option<&str>) -> Result<EstateCatalog, String> {
    // step (a): Windows base-directory adoption.
    crate::core::estate_adoption::adopt_before_catalog_open()?;
    // step (b): open the catalog.
    match selecting {
        Some(value) => {
            EstateCatalog::open_selecting(value).map_err(|e| format!("mootx01: {e}"))
        }
        None => EstateCatalog::open().map_err(|e| format!("mootx01: {e}")),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use std::path::PathBuf;
    use std::sync::MutexGuard;

    // The seams and lock live in estate_adoption; all modules in this crate
    // that redirect process-global estate state share the same lock.
    use crate::core::estate_adoption::{
        CONFIGURATION_TEST_LOCK, set_legacy_base_override,
    };

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
        let root = std::env::temp_dir().join(format!(
            "mootx01-open-{tag}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let root = fs::canonicalize(&root).unwrap();
        let legacy = root.join("MOOTx01");
        let configuration = root.join("com.mootx01.ce");
        write_file(&legacy.join("databases/default/estate.sqlite"), "estate-bytes");
        write_file(&legacy.join("lattice/WordClassTable.json"), "{\"merged\":true}");
        set_legacy_base_override(Some(legacy.clone()));
        EstateCatalog::set_configuration_directory_override(Some(configuration.clone()));
        Scratch { root, legacy, configuration, _guard: guard }
    }

    fn write_file(path: &Path, body: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }

    /// `catalog(None)` adopts then opens: the estate moves to the catalog base
    /// before the catalog names it.
    #[test]
    fn catalog_adopts_then_opens() {
        let s = scratch("open");
        let cat = catalog(None).expect("catalog opens after adoption");
        let record = cat.record_named(EstateCatalog::DEFAULT_NAME).expect("default record present");
        assert_eq!(record.directory, s.configuration.join("databases").join("default"));
        assert_eq!(
            fs::read_to_string(record.directory.join("estate.sqlite")).unwrap(),
            "estate-bytes",
            "the adopted estate is at the catalog path"
        );
        assert!(
            s.configuration.join("lattice/WordClassTable.json").exists(),
            "the lattice pool moved with the estate"
        );
        assert!(!s.legacy.exists(), "the emptied old base is gone");
    }

    /// A collision stops the funnel before any catalog open.
    #[test]
    fn collision_stops_before_catalog_open() {
        let s = scratch("refuse");
        // The W-1 scenario: a serve at logon created the catalog base's
        // databases folder before install ran, producing a collision.
        write_file(&s.configuration.join("databases/default/estate.sqlite"), "new-estate");

        let error = catalog(None).expect_err("a colliding base stops the funnel");
        assert!(error.contains("two copies of the same item"), "got: {error}");
        assert_eq!(
            fs::read_to_string(s.legacy.join("databases/default/estate.sqlite")).unwrap(),
            "estate-bytes",
            "a refusal leaves the old base untouched"
        );
        assert!(!s.configuration.join("lattice").exists(), "and moves nothing");
    }

    /// A second call on an adopted machine opens normally.
    #[test]
    fn adopted_machine_opens_normally() {
        let s = scratch("idempotent");
        catalog(None).expect("first open adopts");
        let cat = catalog(None).expect("second open is plain");
        assert_eq!(cat.active().name, EstateCatalog::DEFAULT_NAME);
        assert!(!s.legacy.exists());
    }

    /// The step list matches the JSON fixture both ports share.
    #[test]
    fn step_list_matches_fixture() {
        let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/Fixtures/estate_open_steps.json");
        let raw = fs::read_to_string(&fixture_path).unwrap_or_else(|e| {
            panic!("cannot read {}: {e}", fixture_path.display())
        });
        // The fixture is a compact JSON array of strings.
        let fixture: Vec<String> = serde_json::from_str(&raw).unwrap_or_else(|e| {
            panic!("cannot parse estate_open_steps.json: {e}")
        });
        let got: Vec<&str> = STEPS.to_vec();
        assert_eq!(
            got, fixture,
            "STEPS does not match Fixtures/estate_open_steps.json"
        );
    }

    /// Adoption step must precede catalog open in the step list.
    ///
    /// A mutation that reorders STEPS fails here independently of the fixture
    /// test, so the ordering invariant has two independent guards.
    #[test]
    fn adoption_precedes_catalog_open_in_step_list() {
        let adopt_idx = STEPS.iter().position(|&s| s == "windows_base_adoption")
            .expect("STEPS must include windows_base_adoption");
        let open_idx = STEPS.iter().position(|&s| s == "catalog_open")
            .expect("STEPS must include catalog_open");
        assert!(adopt_idx < open_idx, "windows_base_adoption must precede catalog_open");
    }
}
