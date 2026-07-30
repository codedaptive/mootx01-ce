//! The writable WordClassTable artifact must never be loaded from a
//! CWD-relative path.
//!
//! The writable table takes precedence over the bundled one and seeds the
//! process-global classifier, so a relative artifact path — which is what
//! `default_table_artifact()` produces when per-user base resolution falls back
//! to the process working directory — would let anyone able to influence that
//! directory plant a `WordClassTable.json` and steer every classification.
//! The load must fail closed to the bundled table instead.

use lattice_lib::load_writable_table;
use std::fs;
use std::path::PathBuf;

/// A minimal but valid writable artifact: `dinner` reclassified as a Verb
/// (bundled classifies it as a Noun), so a successful load is observable.
const POISON_TABLE: &str = r#"{"table_version":"1.0.0","min_os_version":"14.0","snapshot_date":"2026-07-30","nouns":["breakfast"],"verbs":["dinner"]}"#;

#[test]
fn writable_table_is_not_loaded_from_a_relative_path() {
    // Unique name so parallel test binaries cannot collide in the shared CWD.
    let name = "wct_path_guard_probe_a41f.json";
    let cwd = std::env::current_dir().expect("cwd must resolve");
    let absolute: PathBuf = cwd.join(name);
    fs::write(&absolute, POISON_TABLE).expect("probe artifact must write");

    // Absolute path: the table is a legitimate per-user artifact and loads.
    let via_absolute = load_writable_table(&absolute);

    // Relative path naming the SAME file: must be refused, not loaded.
    let via_relative = load_writable_table(&PathBuf::from(name));

    let _ = fs::remove_file(&absolute);

    assert!(
        via_absolute.is_some(),
        "an absolute writable artifact path must still load"
    );
    assert!(
        via_relative.is_none(),
        "a CWD-relative artifact path must fail closed to the bundled table"
    );
}
