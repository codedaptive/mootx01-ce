use super::*;
use std::path::{Path, PathBuf};

/// A minimal plaintext estate carrying the four gated tables with known
/// row counts. The substrate schema is not required: the migration
/// primitives operate on files and counts, never on row semantics.
fn make_plaintext_estate(dir: &Path, drawers: usize) -> PathBuf {
    let path = dir.join("estate.sqlite");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE drawers (id TEXT PRIMARY KEY, adjectiveBitmap INTEGER);
         CREATE TABLE kg_facts (id TEXT PRIMARY KEY);
         CREATE TABLE tunnels (id TEXT PRIMARY KEY);
         CREATE TABLE recall_trace (id TEXT PRIMARY KEY);",
    )
    .unwrap();
    for i in 0..drawers {
        conn.execute(
            "INSERT INTO drawers VALUES (?1, ?2);",
            rusqlite::params![format!("drawer-{i}"), i as i64],
        )
        .unwrap();
    }
    for i in 0..6 {
        conn.execute("INSERT INTO kg_facts VALUES (?1);", [format!("fact-{i}")]).unwrap();
    }
    for i in 0..2 {
        conn.execute("INSERT INTO tunnels VALUES (?1);", [format!("tunnel-{i}")]).unwrap();
    }
    path
}

fn tmp_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir()
        .join(format!("estate-migration-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

const KEY: [u8; 32] = [7u8; 32];

#[test]
fn detection_classifies_all_three_states() {
    let dir = tmp_dir("detect");
    let estate = make_plaintext_estate(&dir, 20);
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Plaintext);
    assert_eq!(
        detect_estate_file_state(&dir.join("nope.sqlite")),
        EstateFileState::Absent
    );
    // A directory at the estate path is not a plaintext database.
    assert_eq!(detect_estate_file_state(&dir), EstateFileState::Absent);
    // Garbage bytes are ciphertext, never absent.
    let garbage = dir.join("garbage.sqlite");
    std::fs::write(&garbage, [0xAAu8; 64]).unwrap();
    assert_eq!(detect_estate_file_state(&garbage), EstateFileState::Ciphertext);
    // Too short to hold the magic: ciphertext, so nothing overwrites it.
    let short = dir.join("short.sqlite");
    std::fs::write(&short, b"SQL").unwrap();
    assert_eq!(detect_estate_file_state(&short), EstateFileState::Ciphertext);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn export_produces_openable_ciphertext_with_matching_counts() {
    let dir = tmp_dir("export");
    let estate = make_plaintext_estate(&dir, 20);
    let copy = dir.join("estate.sqlite.encrypting");

    export_encrypted_copy(&estate, &copy, &KEY).unwrap();
    assert_eq!(detect_estate_file_state(&copy), EstateFileState::Ciphertext);

    let counts = verify_encrypted_copy(&estate, &copy, &KEY).unwrap();
    assert_eq!(counts.drawers, 20);
    assert_eq!(counts.kg_facts, 6);
    assert_eq!(counts.tunnels, 2);
    assert_eq!(counts.recall_traces, 0);
    // Source stays plaintext and untouched.
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Plaintext);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn export_refuses_ciphertext_source_and_wrong_key_errors() {
    let dir = tmp_dir("refuse");
    let estate = make_plaintext_estate(&dir, 5);
    let copy = dir.join("estate.sqlite.encrypting");
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();

    // Refuse to double-wrap an already-encrypted estate.
    let again = dir.join("again.sqlite");
    assert!(export_encrypted_copy(&copy, &again, &KEY).is_err());
    assert!(!again.exists(), "a refused export must leave nothing behind");

    // A wrong key must error, never read as zero counts.
    assert!(verification_counts(&copy, Some(&[9u8; 32])).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn damaged_copy_is_rejected_and_deleted_original_survives() {
    let dir = tmp_dir("damaged");
    let estate = make_plaintext_estate(&dir, 20);
    let copy = dir.join("estate.sqlite.encrypting");
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();

    // Model a partial export: rows missing, file still a valid
    // encrypted database.
    let conn = open_raw(&copy, Some(&KEY)).unwrap();
    conn.execute_batch(
        "DELETE FROM drawers WHERE rowid IN (SELECT rowid FROM drawers LIMIT 3);",
    )
    .unwrap();
    drop(conn);

    assert!(verify_encrypted_copy(&estate, &copy, &KEY).is_err());
    assert!(!copy.exists(), "a rejected copy must be deleted, never left for a later swap");
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Plaintext);
    assert_eq!(verification_counts(&estate, None).unwrap().drawers, 20);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn swap_places_ciphertext_at_canonical_path_and_retains_plaintext_aside() {
    let dir = tmp_dir("swap");
    let estate = make_plaintext_estate(&dir, 20);
    let copy = dir.join("estate.sqlite.encrypting");
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();
    verify_encrypted_copy(&estate, &copy, &KEY).unwrap();

    let (trashed, untrashed) =
        swap_in_encrypted_copy(&estate, &copy, &default_trash()).unwrap();
    // The default seam retains rather than trashes, and says so.
    assert!(trashed.is_none());
    let retained = std::path::PathBuf::from(untrashed.expect("retained path reported"));

    // Canonical path now holds ciphertext that opens with the key.
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Ciphertext);
    assert_eq!(verification_counts(&estate, Some(&KEY)).unwrap().drawers, 20);
    // The retained original is a complete readable plaintext estate.
    assert_eq!(
        detect_estate_file_state(&retained),
        EstateFileState::Plaintext
    );
    assert_eq!(
        verification_counts(&retained, None).unwrap().drawers,
        20
    );
    // No leftover working copy.
    assert!(!copy.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn failed_swap_unwinds_to_the_plaintext_original() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tmp_dir("unwind");
    let estate = make_plaintext_estate(&dir, 20);
    let copy = dir.join("estate.sqlite.encrypting");
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();

    // A read-only estate directory fails the aside hard link — the same
    // unwind path a failed rename takes.
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o555)).unwrap();
    let result = swap_in_encrypted_copy(&estate, &copy, &default_trash());
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();

    assert!(result.is_err());
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Plaintext);
    assert_eq!(verification_counts(&estate, None).unwrap().drawers, 20);
    let _ = std::fs::remove_dir_all(&dir);
}

// ─── migrate: the end-to-end path Rust previously had no equivalent for ─────

/// A DaemonControl that records what was asked of it.
fn recording_daemon(
    running: bool,
    stop_succeeds: bool,
) -> (DaemonControl, std::sync::Arc<std::sync::Mutex<Vec<&'static str>>>) {
    let log = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let l1 = log.clone();
    let l2 = log.clone();
    let l3 = log.clone();
    let d = DaemonControl::new(
        Box::new(move || {
            l1.lock().unwrap().push("is_running");
            running
        }),
        Box::new(move || {
            l2.lock().unwrap().push("stop");
            stop_succeeds
        }),
        Box::new(move || {
            l3.lock().unwrap().push("start");
            true
        }),
    );
    (d, log)
}

#[test]
fn migrate_converts_verifies_swaps_and_reports() {
    let dir = tmp_dir("migrate-ok");
    let estate = make_plaintext_estate(&dir, 20);
    let (daemon, log) = recording_daemon(true, true);

    let (counts, outcome) = migrate(&estate, &KEY, &daemon, &default_trash()).unwrap();

    assert_eq!(counts.drawers, 20);
    // Canonical path now holds ciphertext that opens with the key.
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Ciphertext);
    assert_eq!(verification_counts(&estate, Some(&KEY)).unwrap().drawers, 20);
    // The daemon was quiesced before the clone and brought back after.
    assert!(outcome.daemon_was_running);
    assert!(outcome.daemon_restarted);
    let seen = log.lock().unwrap().clone();
    assert_eq!(seen.first(), Some(&"is_running"));
    assert!(seen.contains(&"stop"));
    assert_eq!(seen.last(), Some(&"start"));
    // The default seam retains, and the outcome says so rather than implying
    // the original was trashed.
    assert!(outcome.trashed_original_url.is_none());
    let retained = outcome.untrashed_original_path.expect("retained path reported");
    assert_eq!(
        detect_estate_file_state(std::path::Path::new(&retained)),
        EstateFileState::Plaintext
    );
    // No leftover working copy.
    assert!(!sibling(&estate, ".encrypting").exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn migrate_refuses_when_the_daemon_will_not_stop_and_changes_nothing() {
    let dir = tmp_dir("migrate-nostop");
    let estate = make_plaintext_estate(&dir, 20);
    let (daemon, _log) = recording_daemon(true, false);

    let err = migrate(&estate, &KEY, &daemon, &default_trash()).unwrap_err();

    assert!(matches!(err, MigrationError::SwapFailed { .. }));
    // Nothing was touched: the estate is still plaintext and complete.
    assert_eq!(detect_estate_file_state(&estate), EstateFileState::Plaintext);
    assert_eq!(verification_counts(&estate, None).unwrap().drawers, 20);
    assert!(!sibling(&estate, ".encrypting").exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn migrate_refuses_a_ciphertext_source_and_restarts_the_daemon() {
    let dir = tmp_dir("migrate-ciphertext");
    let estate = make_plaintext_estate(&dir, 5);
    let copy = dir.join("already.sqlite");
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();
    let (daemon, log) = recording_daemon(true, true);

    let err = migrate(&copy, &KEY, &daemon, &default_trash()).unwrap_err();

    assert!(matches!(err, MigrationError::SourceNotPlaintext { .. }));
    // The daemon was stopped for the attempt and put back afterwards.
    let seen = log.lock().unwrap().clone();
    assert!(seen.contains(&"stop"));
    assert_eq!(seen.last(), Some(&"start"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_trashing_seam_is_reported_as_trashed_not_retained() {
    let dir = tmp_dir("migrate-trash");
    let estate = make_plaintext_estate(&dir, 7);
    let graveyard = dir.join("graveyard");
    std::fs::create_dir_all(&graveyard).unwrap();
    let g = graveyard.clone();
    // A seam that moves the original elsewhere, as macOS's Trash does.
    let trash: TrashItem = Box::new(move |p: &std::path::Path| {
        let dest = g.join(p.file_name().unwrap());
        std::fs::rename(p, &dest)?;
        Ok(dest)
    });
    let (daemon, _log) = recording_daemon(false, true);

    let (_counts, outcome) = migrate(&estate, &KEY, &daemon, &trash).unwrap();

    assert!(outcome.untrashed_original_path.is_none());
    let trashed = outcome.trashed_original_url.expect("trashed path reported");
    assert!(trashed.starts_with(&graveyard));
    assert_eq!(detect_estate_file_state(&trashed), EstateFileState::Plaintext);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A conversion that loses an index preserves every row and every count, and
/// changes retrieval. Only the schema-object comparison sees it.
#[test]
fn a_dropped_index_fails_verification() {
    let dir = tmp_dir("dropped-index");
    let estate = make_plaintext_estate(&dir, 20);

    // Give the source an index, then export a copy and drop it from the copy.
    {
        let conn = Connection::open(&estate).unwrap();
        conn.execute_batch("CREATE INDEX idx_drawers_probe ON drawers(id);").unwrap();
    }
    let copy = dir.join("estate.sqlite.encrypting");
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();

    // The faithful copy verifies.
    assert!(verify_encrypted_copy(&estate, &copy, &KEY).is_ok());

    // Re-export onto a clean destination, then drop the index from the copy
    // only. The export refuses a destination that already holds tables, which
    // is itself the right behaviour — it just has to be respected here.
    remove_database(&copy);
    export_encrypted_copy(&estate, &copy, &KEY).unwrap();
    {
        let conn = open_raw(&copy, Some(&KEY)).unwrap();
        conn.execute_batch("DROP INDEX idx_drawers_probe;").unwrap();
    }
    let err = verify_encrypted_copy(&estate, &copy, &KEY).unwrap_err();
    assert!(
        matches!(err, MigrationError::VerificationFailed { .. }),
        "a dropped index must fail verification, got {err:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
