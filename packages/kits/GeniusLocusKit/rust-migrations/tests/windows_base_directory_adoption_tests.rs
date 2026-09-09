//! Windows base-directory adoption capsule, over scratch directories.
//!
//! Every test fabricates the OLD Windows base layout
//! (`<scratch>/MOOTx01/databases/default/estate.sqlite`, `<scratch>/MOOTx01/
//! lattice/pool/…`, `<scratch>/MOOTx01/moot-mgr/…`, `<scratch>/MOOTx01/
//! daemon.port`) beside an empty new base and drives the capsule over the two
//! explicit paths. The capsule's move logic carries no `cfg`, so these run on
//! every host; only `legacy_windows_base_directory()` is Windows-gated, and
//! the path rule behind it is pinned separately below.

use genius_locus_kit_migrations::{
    legacy_windows_base_directory, legacy_windows_base_directory_from, run_windows_base_adoption,
    windows_base_adoption_pending, WindowsBaseAdoptionOutcome, LEGACY_WINDOWS_BASE_FOLDER,
};
use std::fs;
use std::path::{Path, PathBuf};

/// A unique scratch root per test; removed and recreated so a crashed run
/// leaves nothing behind for the next one.
fn scratch(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("moot-winbase-{label}"));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("scratch root");
    dir
}

fn write(path: &Path, body: &str) {
    fs::create_dir_all(path.parent().expect("a parent")).expect("parent dirs");
    fs::write(path, body).expect("write");
}

/// The old base as a pre-catalog Windows install left it: an estate under
/// `databases`, the LatticeLib pool with its merged table, the moot-mgr
/// history store and the daemon port file.
fn fabricate_legacy_base(root: &Path) -> PathBuf {
    let legacy = root.join(LEGACY_WINDOWS_BASE_FOLDER);
    write(&legacy.join("databases/default/estate.sqlite"), "estate-bytes");
    write(&legacy.join("databases/default/estate.sqlite-wal"), "wal-bytes");
    write(&legacy.join("databases/scratch/estate.sqlite"), "second-estate");
    write(&legacy.join("lattice/pool/pool_1700000000_1.json"), "{}");
    write(&legacy.join("lattice/WordClassTable.json"), "{\"merged\":true}");
    write(&legacy.join("moot-mgr/stats.sqlite"), "mgr-bytes");
    write(&legacy.join("daemon.port"), "4242");
    legacy
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

#[test]
fn an_absent_old_base_is_nothing_to_move() {
    let root = scratch("absent");
    let legacy = root.join(LEGACY_WINDOWS_BASE_FOLDER);
    let configuration = root.join("com.mootx01.ce");

    assert!(!windows_base_adoption_pending(&legacy), "an absent old base has no work");
    assert_eq!(
        run_windows_base_adoption(&legacy, &configuration).expect("no error"),
        WindowsBaseAdoptionOutcome::NothingToMove
    );
    assert!(!configuration.exists(), "a no-op run creates nothing");
}

#[test]
fn an_empty_old_base_is_nothing_to_move() {
    let root = scratch("empty");
    let legacy = root.join(LEGACY_WINDOWS_BASE_FOLDER);
    fs::create_dir_all(&legacy).expect("legacy base");
    let configuration = root.join("com.mootx01.ce");

    assert!(!windows_base_adoption_pending(&legacy), "an empty old base has no work");
    assert_eq!(
        run_windows_base_adoption(&legacy, &configuration).expect("no error"),
        WindowsBaseAdoptionOutcome::NothingToMove
    );
}

#[test]
fn the_whole_old_base_moves_estates_and_lattice_pool_together() {
    let root = scratch("move");
    let legacy = fabricate_legacy_base(&root);
    let configuration = root.join("com.mootx01.ce");

    assert!(windows_base_adoption_pending(&legacy));
    let outcome = run_windows_base_adoption(&legacy, &configuration).expect("no error");
    assert_eq!(
        outcome,
        WindowsBaseAdoptionOutcome::Moved {
            entries: vec![
                "daemon.port".to_string(),
                "databases".to_string(),
                "lattice".to_string(),
                "moot-mgr".to_string(),
            ]
        },
        "every child of the old base is adopted, not a named subset"
    );

    // The estate root arrived whole, both records.
    assert_eq!(read(&configuration.join("databases/default/estate.sqlite")), "estate-bytes");
    assert_eq!(read(&configuration.join("databases/default/estate.sqlite-wal")), "wal-bytes");
    assert_eq!(read(&configuration.join("databases/scratch/estate.sqlite")), "second-estate");
    // The lattice pool and the merged WordClassTable the reducer accumulated
    // came with it (C1b-5): the table is what silently regressed to the
    // bundled snapshot without this capsule.
    assert_eq!(read(&configuration.join("lattice/pool/pool_1700000000_1.json")), "{}");
    assert_eq!(read(&configuration.join("lattice/WordClassTable.json")), "{\"merged\":true}");
    assert_eq!(read(&configuration.join("moot-mgr/stats.sqlite")), "mgr-bytes");
    assert_eq!(read(&configuration.join("daemon.port")), "4242");

    assert!(!legacy.exists(), "the emptied old base is removed");
}

#[test]
fn a_colliding_child_refuses_and_touches_nothing() {
    let root = scratch("collide");
    let legacy = fabricate_legacy_base(&root);
    let configuration = root.join("com.mootx01.ce");
    // A `serve` under the new base already created a default estate: two
    // directories claim the same slot, which is the operator's call.
    write(&configuration.join("databases/default/estate.sqlite"), "new-estate");

    let outcome = run_windows_base_adoption(&legacy, &configuration).expect("a refusal is not an error");
    assert_eq!(
        outcome,
        WindowsBaseAdoptionOutcome::Refused {
            legacy: legacy.join("databases"),
            current: configuration.join("databases"),
        }
    );

    // Nothing moved, in either direction, including the children that would
    // not have collided: a refusal leaves the machine as it was found.
    assert_eq!(read(&legacy.join("databases/default/estate.sqlite")), "estate-bytes");
    assert_eq!(read(&legacy.join("lattice/WordClassTable.json")), "{\"merged\":true}");
    assert_eq!(read(&configuration.join("databases/default/estate.sqlite")), "new-estate");
    assert!(!configuration.join("lattice").exists(), "no child moved past the refusal");
    assert!(windows_base_adoption_pending(&legacy), "the work is still due after a refusal");
}

#[test]
fn a_second_run_after_a_move_is_a_no_op() {
    let root = scratch("idempotent");
    let legacy = fabricate_legacy_base(&root);
    let configuration = root.join("com.mootx01.ce");

    assert!(matches!(
        run_windows_base_adoption(&legacy, &configuration).expect("no error"),
        WindowsBaseAdoptionOutcome::Moved { .. }
    ));
    assert!(!windows_base_adoption_pending(&legacy));
    assert_eq!(
        run_windows_base_adoption(&legacy, &configuration).expect("no error"),
        WindowsBaseAdoptionOutcome::NothingToMove,
        "an adopted machine does nothing on every later run"
    );
    // The second run did not disturb what the first one placed.
    assert_eq!(read(&configuration.join("databases/default/estate.sqlite")), "estate-bytes");
    assert_eq!(read(&configuration.join("lattice/WordClassTable.json")), "{\"merged\":true}");
}

#[test]
fn a_run_interrupted_between_renames_resumes() {
    let root = scratch("resume");
    let legacy = fabricate_legacy_base(&root);
    let configuration = root.join("com.mootx01.ce");
    // Simulate an interruption after `databases` was renamed and before
    // `lattice` was: the new base holds one child, the old base holds the
    // rest. The collision check must not see the already-moved child, because
    // it is no longer at the source.
    fs::create_dir_all(&configuration).expect("new base");
    fs::rename(legacy.join("databases"), configuration.join("databases")).expect("partial move");

    assert!(windows_base_adoption_pending(&legacy), "the remaining children are still due");
    let outcome = run_windows_base_adoption(&legacy, &configuration).expect("no error");
    assert_eq!(
        outcome,
        WindowsBaseAdoptionOutcome::Moved {
            entries: vec![
                "daemon.port".to_string(),
                "lattice".to_string(),
                "moot-mgr".to_string(),
            ]
        }
    );
    assert_eq!(read(&configuration.join("databases/default/estate.sqlite")), "estate-bytes");
    assert_eq!(read(&configuration.join("lattice/WordClassTable.json")), "{\"merged\":true}");
    assert!(!legacy.exists());
}

#[test]
fn the_old_windows_base_path_rule_is_pinned() {
    // `%LOCALAPPDATA%\MOOTx01`, the folder the retired `core::paths::data_dir()`
    // resolved. The literal is the capsule's whole reason to exist, so it is
    // pinned rather than trusted.
    assert_eq!(LEGACY_WINDOWS_BASE_FOLDER, "MOOTx01");
    assert_eq!(
        legacy_windows_base_directory_from(PathBuf::from("C:\\Users\\bo"), |name| {
            (name == "LOCALAPPDATA").then(|| "C:\\Users\\bo\\AppData\\Local".to_string())
        }),
        PathBuf::from("C:\\Users\\bo\\AppData\\Local").join("MOOTx01")
    );
    // LOCALAPPDATA unset: the home-relative fallback, the same one the
    // product identity's configuration directory uses.
    assert_eq!(
        legacy_windows_base_directory_from(PathBuf::from("C:\\Users\\bo"), |_| None),
        PathBuf::from("C:\\Users\\bo").join("AppData").join("Local").join("MOOTx01")
    );
}

#[test]
fn only_windows_hosts_have_an_old_base() {
    // Linux resolved `${XDG_DATA_HOME:-~/.local/share}/mootx01` before the
    // catalog and after it, and macOS is a developer-run target for this
    // port; neither has an old base to adopt.
    let resolved = legacy_windows_base_directory();
    if cfg!(target_os = "windows") {
        assert!(resolved.is_some(), "a Windows host resolves the old base");
    } else {
        assert!(resolved.is_none(), "no non-Windows host has an old base");
    }
}
