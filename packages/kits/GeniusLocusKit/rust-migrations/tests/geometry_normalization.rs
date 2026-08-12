// geometry_normalization.rs
//
// Failing fixtures for the Rust geometry normalization capsule (Part 2 RED step).
//
// Covers:
//   1. Injected-reserve fixture: SQLite file with per-page reserve=12 written via
//      rusqlite's file-control API before the first page write.
//   2. Normalization: run_geometry_normalization returns a report showing the estate
//      was normalized; file header byte 20 is 0 after the capsule runs.
//   3. Pass-through: reserve=0 estate produces no normalization work.
//   4. Idempotence: second call returns no-op outcome.
//   5. Row-count parity: all rows survive the sqlcipher_export swap.
//
// RED state (before Part 4 lands): `run_geometry_normalization` is not defined.
// These tests will fail to compile until Part 4 adds `geometry_normalization.rs`
// to rust-migrations/src/ and wires the export in lib.rs.

use rusqlite::{Connection, OpenFlags};
use rusqlite::ffi as sqlite_ffi;
use std::ffi::c_void;
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

// MARK: - File-header reserve reader (no SQLite connection)

/// Read byte 20 from the SQLite 3 file header: "Reserved space per page."
/// Returns None when the file is absent or shorter than 100 bytes.
fn read_reserve_bytes(path: &PathBuf) -> Option<u8> {
    let data = fs::read(path).ok()?;
    if data.len() < 100 {
        return None;
    }
    // SQLite file format 3 specification §1.3.8: offset 20 = reserved bytes per page.
    // Apple's SEE sqlite3 sets this to 12 (per-page IV). Our estate files set this to 0.
    Some(data[20])
}

// MARK: - Raw-SQLite injected-reserve fixture builder

/// Create a plaintext SQLite file with per-page reserved bytes set to 12 BEFORE the
/// first page write. The rusqlite `file_control` API calls sqlite3_file_control with
/// opcode SQLITE_FCNTL_RESERVE_BYTES (38). After setting the reserve, write `row_count`
/// rows to `fixture_rows` and checkpoint so the header propagates to the main file.
fn make_raw_reserve_estate(path: &PathBuf, row_count: usize) -> rusqlite::Result<()> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
    )?;
    // SQLITE_FCNTL_RESERVE_BYTES (opcode 38, sqlite3.h): set per-page reserved bytes
    // before the first write so the header (byte 20) records reserve=12. This is the
    // same opcode Apple's SEE sqlite3 uses implicitly when it reserves 12 bytes per
    // page for per-page IVs. Must be called before the first page write.
    let mut reserve_bytes: i32 = 12;
    let rc = unsafe {
        sqlite_ffi::sqlite3_file_control(
            conn.handle(),
            std::ptr::null(), // NULL = main database ("main")
            38,               // SQLITE_FCNTL_RESERVE_BYTES
            &mut reserve_bytes as *mut i32 as *mut c_void,
        )
    };
    if rc != sqlite_ffi::SQLITE_OK {
        return Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rc),
            Some(format!("SQLITE_FCNTL_RESERVE_BYTES rc={rc}")),
        ));
    }
    conn.execute_batch("PRAGMA journal_mode = WAL;")?;
    conn.execute_batch(
        "CREATE TABLE fixture_rows (id INTEGER PRIMARY KEY, value TEXT NOT NULL);",
    )?;
    for i in 0..row_count {
        conn.execute(
            "INSERT INTO fixture_rows (value) VALUES (?1)",
            [format!("row{}", i)],
        )?;
    }
    // Checkpoint: propagates WAL pages (including the reserve=12 header) to main file.
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    Ok(())
}

/// Scratch path in the system temp dir, named with a UUID to avoid collisions.
fn scratch_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("glk-geo-{}-{}.sqlite3", label, Uuid::new_v4()))
}

// MARK: - Tests
//
// RED: these tests reference `run_geometry_normalization` from
// `genius_locus_kit_migrations` — a symbol that does not exist until Part 4 lands.
// They are compiled unconditionally (no `required-features` gate) because geometry
// normalization is format-agnostic and not a 1.0→1.1 schema concern.

#[test]
fn injected_reserve_estate_normalizes() {
    let path = scratch_path("inject");

    make_raw_reserve_estate(&path, 5).expect("make_raw_reserve_estate");

    let reserve_before = read_reserve_bytes(&path);
    assert_eq!(reserve_before, Some(12), "fixture must have reserve=12 before capsule");

    // RED: `run_geometry_normalization` is not defined until Part 4.
    let report = genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("run_geometry_normalization must succeed on a reserve=12 plaintext estate");

    assert!(
        report.normalized,
        "capsule must report normalized=true for a reserve=12 estate"
    );
    let reserve_after = read_reserve_bytes(&path);
    assert_eq!(reserve_after, Some(0), "reserve must be 0 after normalization");

    // Clean up.
    let _ = fs::remove_file(&path);
    let _ = fs::remove_file(path.with_extension("sqlite3-wal"));
    let _ = fs::remove_file(path.with_extension("sqlite3-shm"));
}

#[test]
fn pass_through_reserve_zero_estate_no_work() {
    let path = scratch_path("passthru");

    // Create via rusqlite without setting reserve (defaults to 0).
    let conn = Connection::open(&path).expect("open");
    conn.execute_batch(
        "PRAGMA journal_mode = WAL; CREATE TABLE t (id INTEGER PRIMARY KEY);",
    )
    .expect("setup");
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
        .expect("checkpoint");
    drop(conn);

    assert_eq!(
        read_reserve_bytes(&path),
        Some(0),
        "reserve must be 0 before capsule"
    );

    let report = genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("run_geometry_normalization must not fail on reserve=0 estate");

    assert!(
        !report.normalized,
        "pass-through estate must not report normalized=true"
    );

    let _ = fs::remove_file(&path);
}

#[test]
fn idempotence_second_call_no_work() {
    let path = scratch_path("idem");

    make_raw_reserve_estate(&path, 3).expect("make_raw_reserve_estate");

    let r1 = genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("first call");
    assert!(r1.normalized, "first call must normalize");

    let r2 = genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("second call");
    assert!(
        !r2.normalized,
        "second call must be a no-op (estate already at reserve=0)"
    );

    let _ = fs::remove_file(&path);
}

/// Verify that a sibling-creation failure (read-only parent directory) returns an error
/// rather than panicking, so the estate_registry caller can park it with `let _ = ...`.
// Unix-only: the failure this test induces -- a read-only parent directory
// blocking sibling creation -- has no portable equivalent. On Windows the
// directory stays writable, a correct implementation creates the sibling and
// returns Ok, and the assertion below fails spuriously.
#[cfg(unix)]
#[test]
fn sibling_creation_failure_returns_error() {
    // Use a dedicated subdirectory so we can mark it read-only while the test-process
    // user owns the directory — the already-created reserve=12 file stays readable
    // (open descriptors are not affected), but creating any new file in the dir fails.
    let dir = std::env::temp_dir().join(format!("glk-geo-sib-{}", Uuid::new_v4()));
    fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir.join("estate.sqlite3");

    make_raw_reserve_estate(&path, 2).expect("make_raw_reserve_estate");

    // Make the parent directory read-only — blocks the capsule from creating its
    // .geo_normalize_tmp.sqlite3 sibling file (the Connection::open_with_flags call
    // with SQLITE_OPEN_CREATE will fail if the directory is not writable).
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o555))
            .expect("set dir read-only");
    }

    let result = genius_locus_kit_migrations::run_geometry_normalization(&path);

    // Restore write permission before the test returns so `fs::remove_file` can clean up.
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o755));
    }

    // The function must return an error — not panic — when the sibling cannot be created.
    // The estate_registry caller discards this error with `let _ = ...` (parking pattern).
    assert!(
        result.is_err(),
        "run_geometry_normalization must return Err when sibling creation fails"
    );

    let _ = fs::remove_file(&path);
    let _ = fs::remove_dir(&dir);
}

#[test]
fn row_count_parity_after_normalization() {
    let path = scratch_path("parity");
    let row_count: usize = 7;

    make_raw_reserve_estate(&path, row_count).expect("make_raw_reserve_estate");

    genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("run_geometry_normalization");

    let conn = Connection::open(&path).expect("open normalized file");
    let count: usize = conn
        .query_row("SELECT COUNT(*) FROM fixture_rows", [], |r| r.get(0))
        .expect("count");
    assert_eq!(count, row_count, "all rows must survive the sqlcipher_export swap");

    let _ = fs::remove_file(&path);
}

// MARK: - Part 4: key-backed skip, sibling permissions, cleanup

/// An estate with a sibling `db.key` and nonzero reserve is left byte-identical.
/// The guard fires and nothing is rewritten. No `#[cfg(unix)]` gate — the
/// INSTALL_KEY_FILE predicate is platform-agnostic.
#[test]
fn key_backed_estate_skip_guard() {
    let path = scratch_path("keybacked");

    make_raw_reserve_estate(&path, 3).expect("make_raw_reserve_estate");

    // Place a db.key sibling — marks this as a whole-file-encrypted estate.
    // The normalization guard must detect this file and return a no-op report
    // without touching the estate (normalizing would corrupt SQLCipher's per-page
    // IV structure, which lives in the reserved bytes we would otherwise zero out).
    let key_path = path.parent().unwrap().join("db.key");
    fs::write(&key_path, b"sentinel").expect("write db.key");

    let report = genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("run_geometry_normalization must succeed (no-op) on key-backed estate");

    assert!(
        !report.normalized,
        "key-backed estate must not be normalized"
    );
    // Reserve must remain 12 — the guard must prevent any file modification.
    assert_eq!(
        read_reserve_bytes(&path),
        Some(12),
        "key-backed estate must remain at reserve=12 after guard fires"
    );

    let _ = fs::remove_file(&path);
    let _ = fs::remove_file(&key_path);
}

/// While normalization is running, the sibling is mode 0600.
/// The pre-create step creates the sibling at 0600 before Connection::open_with_flags
/// — this test asserts the sibling's mode directly, not the result's.
#[cfg(unix)]
#[test]
fn sibling_mode_is_owner_only_while_normalizing() {
    use std::os::unix::fs::MetadataExt;
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    let path = scratch_path("sibmode");
    // 1000 rows: gives the observer thread a reliable window to catch the sibling
    // before normalization completes and renames it away.
    make_raw_reserve_estate(&path, 1000).expect("make_raw_reserve_estate");

    let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
    let sibling_path = path.parent().unwrap()
        .join(format!("{stem}.geo_normalize_tmp.sqlite3"));

    let observed_mode: Arc<Mutex<Option<u32>>> = Arc::new(Mutex::new(None));

    let mode_t = observed_mode.clone();
    let sib_t = sibling_path.clone();
    // Run normalization on a background thread so the observer can poll the
    // sibling file while normalization is in progress.
    let path_bg = path.clone();
    let norm_handle = thread::spawn(move || {
        genius_locus_kit_migrations::run_geometry_normalization(&path_bg)
    });

    // Poll the sibling path. Once it appears, record its mode. The sibling is
    // pre-created at 0600 before Connection::open_with_flags, so it is 0600
    // from the moment of first existence.
    for _ in 0..10_000 {
        if sib_t.exists() {
            if let Ok(meta) = fs::metadata(&sib_t) {
                *mode_t.lock().unwrap() = Some(meta.mode());
                break;
            }
        }
        thread::sleep(Duration::from_millis(1));
    }

    norm_handle.join().unwrap().expect("run_geometry_normalization");

    let mode = observed_mode
        .lock()
        .unwrap()
        .expect("sibling must have been observed during normalization — increase row count if this fails");
    assert_eq!(
        mode & 0o777,
        0o600,
        "sibling must have mode 0o600 while normalization is running"
    );

    let _ = fs::remove_file(&path);
}

/// After normalization the canonical file is mode 0600.
/// The step-9 permission block sets 0600 on the canonical path after the atomic
/// rename — this test asserts the canonical's mode after a successful run.
#[cfg(unix)]
#[test]
fn canonical_mode_is_owner_only_after_normalization() {
    use std::os::unix::fs::MetadataExt;

    let path = scratch_path("canperm");
    make_raw_reserve_estate(&path, 5).expect("make_raw_reserve_estate");

    genius_locus_kit_migrations::run_geometry_normalization(&path)
        .expect("run_geometry_normalization");

    let mode = fs::metadata(&path)
        .expect("canonical file must exist after normalization")
        .mode();
    assert_eq!(
        mode & 0o777,
        0o600,
        "canonical file must have mode 0o600 after normalization"
    );

    let _ = fs::remove_file(&path);
}

/// A run that fails after the sibling exists leaves no `.geo_normalize_tmp.sqlite3`
/// behind. The observer thread waits for the sibling to appear, then makes the
/// canonical path a directory so fs::rename fails with EISDIR. Part 3's cleanup
/// in the rename error path removes the sibling before returning Err.
#[cfg(unix)]
#[test]
fn failed_run_leaves_no_sibling() {
    use std::thread;
    use std::time::Duration;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    let dir = std::env::temp_dir().join(format!("glk-geo-fail-{}", Uuid::new_v4()));
    fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir.join("estate.sqlite3");
    let stem = path.file_stem().unwrap().to_string_lossy().into_owned();
    let sibling_path = dir.join(format!("{stem}.geo_normalize_tmp.sqlite3"));

    // 1000 rows: gives the observer thread time to fire before normalization
    // completes and renames the sibling away.
    make_raw_reserve_estate(&path, 1000).expect("make_raw_reserve_estate");

    let disrupted = Arc::new(AtomicBool::new(false));
    let disrupted_t = disrupted.clone();
    let sibling_t = sibling_path.clone();
    let path_t = path.clone();
    // Observer: once the sibling exists, atomically replace the canonical file
    // with a directory. fs::rename(sibling_file, directory) fails with EISDIR —
    // the rename cleanup path in Part 3 must then remove the sibling.
    let path_bg = path.clone();
    let norm_handle = thread::spawn(move || {
        genius_locus_kit_migrations::run_geometry_normalization(&path_bg)
    });

    for _ in 0..10_000 {
        if sibling_t.exists() {
            let _ = fs::remove_file(&path_t);
            let _ = fs::create_dir(&path_t);
            disrupted_t.store(true, Ordering::SeqCst);
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }

    let _ = norm_handle.join().unwrap(); // Ok or Err, both are valid outcomes

    // Whether normalization succeeded (sibling renamed away — disruption raced)
    // or failed with EISDIR (Part 3 cleanup ran), no sibling must remain on disk.
    assert!(
        !sibling_path.exists(),
        "sibling must not be left on disk after normalization completes (success or failure)"
    );

    // Cleanup: canonical might be a directory (if disruption fired) or absent.
    let _ = fs::remove_file(&path);
    let _ = fs::remove_dir(&path);
    let _ = fs::remove_dir_all(&dir);
}
