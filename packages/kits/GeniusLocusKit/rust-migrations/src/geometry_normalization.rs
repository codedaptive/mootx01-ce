//! Geometry normalization capsule (Rust port).
//!
//! Detects and corrects nonzero SQLite per-page reserved-bytes (file header
//! byte 20 ≠ 0) on plaintext estates. Must run before any capsule that calls
//! VACUUM — VACUUM fails on estates with foreign geometry because SQLCipher's
//! `attachFunc` calls `sqlcipherCodecAttach(nKey=0)` for any keyless ATTACH
//! when the main database has nonzero reserve, failing with SQLITE_ERROR.
//!
//! # Repair sequence
//!
//! The Swift port uses `ATTACH ... KEY ''` from the SOURCE connection to bypass
//! the SQLCipher heuristic. In the Rust bundled SQLCipher, `KEY ''` does not
//! reliably bypass the heuristic — the condition `!zKey || nKey == 0` still
//! evaluates to true because nKey is 0 for an empty string. The Rust port
//! therefore uses the inverse connection order:
//!
//!   1. WAL checkpoint (TRUNCATE) via a short-lived source connection — close
//!      the source connection before opening the destination.
//!   2. Open the DESTINATION as the main connection (fresh file, reserve=0).
//!   3. ATTACH the source to the destination — the heuristic checks
//!      `db->aDb[0].reserve` (the DESTINATION's reserve = 0), so the condition
//!      `> 0` is false and the heuristic does not fire.
//!   4. Copy schema (DDL) and data (row-by-row INSERT) from source to dest.
//!      Writing into the destination produces pages with reserve=0.
//!   5. DETACH source.
//!   6. Verify destination header byte 20 == 0.
//!   7. Close destination connection (must precede rename on Windows).
//!   8. Atomic `rename()` — replace the original with the destination.
//!   9. Remove stale -wal/-shm sidecars from the original path.
//!
//! Key-backed (whole-file encrypted) estates are skipped automatically:
//! a `db.key` sibling file ([`persistence_kit::INSTALL_KEY_FILE`]) marks an
//! estate as key-backed. Normalizing it would corrupt SQLCipher's per-page IV
//! structure, which lives in the reserved bytes we would otherwise zero out.
//! This matches the Swift port's `guard encryptionConfig.mode != .fullDatabase`
//! check in `SQLiteBackend.normalizeGeometry()`.

use rusqlite::{Connection, OpenFlags};
use std::fs;
use std::path::Path;
use std::time::Instant;

/// Outcome of one geometry normalization run.
#[derive(Debug, Clone)]
pub struct GeometryNormalizationReport {
    /// True when the normalization swap ran (reserve was nonzero).
    pub normalized: bool,
    /// The reserve value found before normalization; 0 for pass-through runs.
    pub reserve_bytes_before: i32,
    /// Wall-clock duration in seconds; 0.0 for no-ops.
    pub duration_seconds: f64,
}

impl GeometryNormalizationReport {
    fn no_op() -> Self {
        Self {
            normalized: false,
            reserve_bytes_before: 0,
            duration_seconds: 0.0,
        }
    }
}

/// Error variants for geometry normalization failures.
#[derive(Debug)]
pub enum GeometryNormalizationError {
    /// A file I/O operation failed.
    Io(std::io::Error),
    /// A SQLite-layer operation failed.
    Sqlite(rusqlite::Error),
    /// The sibling file had unexpected nonzero reserve after export.
    SiblingReserveNonZero(i32),
}

impl std::fmt::Display for GeometryNormalizationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "geometry normalization I/O error: {e}"),
            Self::Sqlite(e) => write!(f, "geometry normalization SQLite error: {e}"),
            Self::SiblingReserveNonZero(v) => {
                write!(
                    f,
                    "geometry normalization: sibling reserve={v} after export (expected 0)"
                )
            }
        }
    }
}

impl std::error::Error for GeometryNormalizationError {}

impl From<rusqlite::Error> for GeometryNormalizationError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Sqlite(e)
    }
}

impl From<std::io::Error> for GeometryNormalizationError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

/// Read the SQLite 3 file-header reserved-bytes-per-page field (byte 20).
///
/// Returns 0 when the file is absent, too short, or unreadable — treating
/// any unreadable estate as already-normalized. A downstream VACUUM will
/// surface the real error when the maintenance scheduler runs.
fn read_reserve_bytes(path: &Path) -> i32 {
    let data = match fs::read(path) {
        Ok(d) => d,
        Err(_) => return 0,
    };
    if data.len() < 100 {
        // File too short to be a valid SQLite database — treat as reserve=0.
        return 0;
    }
    // SQLite file format 3 §1.3.8: offset 20 = "Reserved space per page."
    // Apple's SEE-provisioned sqlite3 sets this to 12 for per-page IVs.
    data[20] as i32
}

/// SQL double-quote-escape an identifier (table or column name).
fn sql_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// SQL single-quote-escape a file path for ATTACH … AS … syntax.
fn sql_path(path: &str) -> String {
    format!("'{}'", path.replace('\'', "''"))
}

/// Copy all schema objects and data from the 'source' attached database
/// into the 'main' (destination) database.
///
/// Uses PRAGMA foreign_keys = OFF during the copy to avoid constraint ordering
/// issues; re-enables it after COMMIT. Uses explicit DDL ordering: tables
/// first (so indexes and triggers have a table to reference), then indexes,
/// views, and triggers.
///
/// # ALTER TABLE column handling
///
/// SQLite's `sqlite_schema.sql` column stores the ORIGINAL `CREATE TABLE`
/// statement. Columns added later via `ALTER TABLE ADD COLUMN` do not appear
/// in that DDL, but they ARE returned by `SELECT *` and `PRAGMA table_info`.
/// Without compensation, `INSERT INTO main.t SELECT * FROM source.t` fails
/// with "table has N columns but M values" when M > N.
///
/// Compensation: after creating each table from its DDL we query
/// `PRAGMA source.table_info(t)` to discover any extra columns and add them
/// to the destination with `ALTER TABLE ADD COLUMN` before inserting data.
/// The INSERT then uses an explicit column list built from the live column set.
fn copy_schema_and_data(dest: &Connection) -> Result<(), rusqlite::Error> {
    // Disable foreign key enforcement during bulk copy — rows are inserted
    // before their referents are necessarily present.
    dest.execute_batch("PRAGMA foreign_keys = OFF;")?;
    dest.execute_batch("BEGIN;")?;

    // 1. Collect user table names and DDL in rowid order (dependency order).
    // name and sql fetched together so table ordering is consistent.
    let tables: Vec<(String, String)> = {
        let mut stmt = dest.prepare(
            "SELECT name, sql FROM source.sqlite_schema \
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL \
             ORDER BY rowid",
        )?;
        let v: Vec<(String, String)> = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .filter_map(|r| r.ok())
            .collect();
        v
    };

    // 2. For each table: create from DDL, reconcile ALTER-TABLE columns, copy rows.
    for (table, ddl) in &tables {
        let q_name = sql_ident(table);
        let table_escaped = table.replace('"', "\"\"");

        // Create the table from the sqlite_schema DDL (preserves all original
        // constraints: NOT NULL, CHECK, UNIQUE, REFERENCES).
        dest.execute_batch(ddl)?;

        // Discover all LIVE columns in the source (cid order = insertion order).
        // PRAGMA table_info includes columns added via ALTER TABLE ADD COLUMN that
        // are absent from the sqlite_schema DDL.
        // PRAGMA columns: cid(0) name(1) type(2) notnull(3) dflt_value(4) pk(5)
        let source_cols: Vec<(String, String, Option<String>)> = {
            let mut stmt = dest.prepare(&format!(
                "PRAGMA source.table_info(\"{table_escaped}\")"
            ))?;
            let v: Vec<(String, String, Option<String>)> = stmt
                .query_map([], |r| Ok((
                    r.get::<_, String>(1)?,          // name
                    r.get::<_, String>(2)?,          // type
                    r.get::<_, Option<String>>(4)?,  // dflt_value
                )))?
                .filter_map(|r| r.ok())
                .collect();
            v
        };

        // Discover which columns the DDL-created destination table has.
        let dest_col_names: std::collections::HashSet<String> = {
            let mut stmt = dest.prepare(&format!(
                "PRAGMA table_info(\"{table_escaped}\")"
            ))?;
            let v: std::collections::HashSet<String> = stmt
                .query_map([], |r| r.get::<_, String>(1))?
                .filter_map(|r| r.ok())
                .collect();
            v
        };

        // Add columns from ALTER TABLE ADD COLUMN that are missing from the destination.
        // SQLite requires ALTER-added columns to be nullable or carry a DEFAULT, so the
        // ADD COLUMN here is always valid (the source schema enforces this invariant).
        for (col_name, col_type, dflt) in &source_cols {
            if dest_col_names.contains(col_name) {
                continue;
            }
            let col_escaped = col_name.replace('"', "\"\"");
            let q_col = format!("\"{}\"", col_escaped);
            let dflt_clause = match dflt {
                Some(d) => format!(" DEFAULT {d}"),
                None => String::new(),
            };
            dest.execute_batch(&format!(
                "ALTER TABLE main.{q_name} ADD COLUMN {q_col} {col_type}{dflt_clause};"
            ))?;
        }

        // Copy rows with an explicit column list to avoid SELECT * mismatch.
        let col_list = source_cols
            .iter()
            .map(|(n, _, _)| {
                let e = n.replace('"', "\"\"");
                format!("\"{}\"", e)
            })
            .collect::<Vec<_>>()
            .join(", ");
        if !col_list.is_empty() {
            dest.execute_batch(&format!(
                "INSERT INTO main.{q_name} ({col_list}) \
                 SELECT {col_list} FROM source.{q_name};"
            ))?;
        }
    }

    // 3. Handle sqlite_sequence (implicit AUTOINCREMENT tracker). Not in
    //    sqlite_schema; check by name and copy if present in source.
    let has_seq: bool = dest
        .query_row(
            "SELECT COUNT(*) FROM source.sqlite_schema \
             WHERE name = 'sqlite_sequence' AND type = 'table'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap_or(false);
    if has_seq {
        // sqlite_sequence is auto-created when the first AUTOINCREMENT table
        // has data written; it already exists in dest after the row copies above.
        dest.execute_batch(
            "INSERT OR REPLACE INTO main.sqlite_sequence \
             SELECT * FROM source.sqlite_sequence;",
        )?;
    }

    // 4. Copy indexes (schema DDL only; data is rebuilt automatically).
    let index_ddls: Vec<String> = {
        let mut stmt = dest.prepare(
            "SELECT sql FROM source.sqlite_schema \
             WHERE type = 'index' AND sql IS NOT NULL \
             ORDER BY rowid",
        )?;
        let ddls: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        ddls
    };
    for ddl in &index_ddls {
        dest.execute_batch(ddl)?;
    }

    // 5. Copy views.
    let view_ddls: Vec<String> = {
        let mut stmt = dest.prepare(
            "SELECT sql FROM source.sqlite_schema \
             WHERE type = 'view' AND sql IS NOT NULL \
             ORDER BY rowid",
        )?;
        let ddls: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        ddls
    };
    for ddl in &view_ddls {
        dest.execute_batch(ddl)?;
    }

    // 6. Copy triggers (after tables, indexes, and views).
    let trigger_ddls: Vec<String> = {
        let mut stmt = dest.prepare(
            "SELECT sql FROM source.sqlite_schema \
             WHERE type = 'trigger' AND sql IS NOT NULL \
             ORDER BY rowid",
        )?;
        let ddls: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .filter_map(|r| r.ok())
            .collect();
        ddls
    };
    for ddl in &trigger_ddls {
        dest.execute_batch(ddl)?;
    }

    dest.execute_batch("COMMIT;")?;
    dest.execute_batch("PRAGMA foreign_keys = ON;")?;
    // Checkpoint the destination WAL so all written pages are in the main file
    // (ensures read_reserve_bytes reads from a fully flushed header).
    dest.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;

    Ok(())
}

/// Detect and repair foreign SQLite geometry (nonzero reserved-bytes-per-page).
///
/// # Arguments
///
/// * `path` — Path to the SQLite estate file. The `-wal` and `-shm` sidecars
///   are located by appending their suffixes to this path string.
///
/// # Errors
///
/// Returns `GeometryNormalizationError` on SQLite or I/O failure. The
/// `estate_registry` caller parks this error with `let _ = ...` so a geometry
/// failure never prevents the estate from opening.
pub fn run_geometry_normalization(
    path: &Path,
) -> Result<GeometryNormalizationReport, GeometryNormalizationError> {
    let started = Instant::now();

    let reserve = read_reserve_bytes(path);
    if reserve == 0 {
        return Ok(GeometryNormalizationReport::no_op());
    }

    // Skip key-backed (whole-file encrypted) estates. Their reserved bytes are
    // SQLCipher's per-page IV space; zeroing them would corrupt every page.
    // A `db.key` sibling marks an estate as key-backed — same predicate as
    // the Swift port's `encryptionConfig.mode != .fullDatabase` guard.
    if path
        .parent()
        .map(|parent| parent.join(persistence_kit::INSTALL_KEY_FILE).exists())
        .unwrap_or(false)
    {
        return Ok(GeometryNormalizationReport::no_op());
    }

    // Step 1: WAL checkpoint via a short-lived source connection — consolidate
    // all committed WAL pages into the main file before the schema copy.
    // Drop the connection before opening the destination to avoid two live
    // connections to the same file, which can cause SQLITE_BUSY on Windows.
    {
        let src = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )?;
        src.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
        // `src` drops here — closes the source connection.
    }

    // Step 2: sibling destination path (same directory as the original).
    let path_str = path.to_string_lossy();
    let sibling_path = {
        let stem = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let dir = path.parent().unwrap_or(Path::new("."));
        dir.join(format!("{stem}.geo_normalize_tmp.sqlite3"))
    };
    // Best-effort: remove a stale sibling left by a prior interrupted run.
    let _ = fs::remove_file(&sibling_path);

    // Step 3: Pre-create the sibling at owner-read/write before SQLite opens
    // it. A zero-length file is treated as a fresh empty database by SQLite —
    // SQLITE_OPEN_CREATE on an existing zero-length file is safe, it opens the
    // existing file without changing permissions or truncating it. This ensures
    // the sibling is never briefly world-readable even transiently; the
    // corresponding pattern in sqlite.rs calls set_permissions after open, but
    // the pre-create approach is stronger because the permissive window is zero.
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create(true)
            .mode(0o600)
            .open(&sibling_path)?;
    }
    // Open the DESTINATION first (fresh file, reserve=0 as main).
    // The SQLCipher attachFunc heuristic checks db->aDb[0].reserve — by making
    // the destination (reserve=0) the main connection, the condition `> 0` is
    // false and the heuristic does not fire when we ATTACH the source.
    let dest = Connection::open_with_flags(
        &sibling_path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
    )?;
    // WAL mode on the destination (matches the source's journal mode).
    dest.execute_batch("PRAGMA journal_mode = WAL;")?;

    // Step 4: ATTACH the source — dest (reserve=0) is main, so the SQLCipher
    // attachFunc heuristic condition `reserve > 0` is false → attach succeeds.
    let source_sql = sql_path(&path.to_string_lossy());
    if let Err(e) = dest.execute_batch(&format!("ATTACH {source_sql} AS source;")) {
        drop(dest);
        let _ = fs::remove_file(&sibling_path);
        return Err(GeometryNormalizationError::Sqlite(e));
    }

    // Step 5: Copy schema and data from source to dest.
    if let Err(e) = copy_schema_and_data(&dest) {
        let _ = dest.execute_batch("DETACH source;");
        drop(dest);
        let _ = fs::remove_file(&sibling_path);
        return Err(GeometryNormalizationError::Sqlite(e));
    }

    // Step 6: DETACH source.
    if let Err(e) = dest.execute_batch("DETACH source;") {
        drop(dest);
        let _ = fs::remove_file(&sibling_path);
        return Err(GeometryNormalizationError::Sqlite(e));
    }

    // Step 7: Verify sibling reserve=0 (sibling has been checkpointed in
    // copy_schema_and_data, so the header is in the main file).
    let sibling_reserve = read_reserve_bytes(&sibling_path);
    if sibling_reserve != 0 {
        drop(dest);
        let _ = fs::remove_file(&sibling_path);
        return Err(GeometryNormalizationError::SiblingReserveNonZero(sibling_reserve));
    }

    // Step 8: Close the destination connection before rename. On Windows, a
    // live SQLite connection holds an exclusive lock; rename succeeds only
    // after the connection is closed.
    drop(dest);

    // Step 9: Atomic rename — replaces the original (reserve=12) with the
    // sibling (reserve=0). POSIX rename() is atomic on the same filesystem.
    if let Err(e) = fs::rename(&sibling_path, path) {
        let _ = fs::remove_file(&sibling_path);
        return Err(GeometryNormalizationError::Io(e));
    }
    // Restrict the canonical file and any pre-existing sidecars to
    // owner-read/write. Sidecars written after the engine reopens the estate
    // inherit the process umask; this call tightens any that were already
    // present at the canonical path before they are removed in step 10.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perm = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perm.clone()).ok();
        for suffix in ["-wal", "-shm"] {
            std::fs::set_permissions(format!("{path_str}{suffix}"), perm.clone()).ok();
        }
    }

    // Step 10: Remove stale WAL and SHM sidecars from the original path.
    for suffix in ["-wal", "-shm"] {
        let _ = fs::remove_file(format!("{path_str}{suffix}"));
    }

    Ok(GeometryNormalizationReport {
        normalized: true,
        reserve_bytes_before: reserve,
        duration_seconds: started.elapsed().as_secs_f64(),
    })
}
