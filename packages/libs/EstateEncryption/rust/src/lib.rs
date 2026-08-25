//! estate-encryption — the plaintext-to-encrypted estate conversion.
//!
//! Standalone library, shared by the product (`mootx01 upgrade`) and the
//! benchmark harness.
//!
//!   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//!
//! That invariant is the reason every function below is shaped as it is.
//!
//! The clone is PHYSICAL, via SQLCipher's `sqlcipher_export()` over an
//! ATTACHed encrypted database — never a logical re-import through the
//! capture seam, which would mint new row ids and lose trace rows,
//! fingerprints, and the Merkle rollup.
//!
//! PORT PARITY. `Sources/EstateEncryption/EstateEncryption.swift` is the twin.
//! Same names, same types, same field sets, same failure semantics, same order
//! of operations. When one port changes, the other changes in the same commit.
//!
//!
//! PORT MAPPING. Where the two ports spell one thing differently, it is a
//! language idiom and not a divergence:
//!
//!   Rust                          Swift
//!   this module                   EstateEncryptionMigrator
//!   MigrationResult<T>            throws
//!   DaemonControl::new / ::none   init + static let none
//!   fn default_trash()            static var defaultTrash
//!   retain_original               retainOriginal (systemTrash on macOS)
//!
//! Everything else is name-for-name and field-for-field.
//!
//! PLATFORM. Only the Trash seam differs by platform, and it differs by value
//! rather than by shape: `default_trash` is the system Trash on macOS and
//! retention elsewhere. `SwapOutcome` records which happened, so no caller has
//! to infer it from the target.

use std::fmt;
use std::path::{Path, PathBuf};

use rusqlite::Connection;

// ─────────────────────────────────────────────────────────────────────────────
// Errors — mirrors Swift `MigrationError`
// ─────────────────────────────────────────────────────────────────────────────

/// Why a migration step refused or failed. Messages never carry key material:
/// the ATTACH statement embeds the key hex, so raw SQL is deliberately
/// excluded from every error path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationError {
    /// The source file is not a readable plaintext SQLite database.
    SourceNotPlaintext { path: String },
    /// A sqlite call failed. `step` names the operation, not the SQL.
    Sqlite { step: String, detail: String },
    /// The encrypted copy's row counts did not match the original's. The copy
    /// has been deleted; the original is untouched.
    VerificationFailed { source: String, copy: String },
    /// The swap could not complete. The plaintext original is back at (or
    /// never left) the canonical path.
    SwapFailed { detail: String },
    /// An install key file exists but is not the required length. Treated as
    /// tampered rather than regenerated: regenerating would orphan every
    /// database already encrypted under the real key.
    InstallKeyMalformed { path: String, count: usize },
    /// The install key file could not be created or read.
    InstallKeyUnavailable { path: String, detail: String },
}

impl fmt::Display for MigrationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MigrationError::SourceNotPlaintext { path } => write!(
                f,
                "refusing to migrate {path}: it is not a readable plaintext SQLite database"
            ),
            MigrationError::Sqlite { step, detail } => {
                write!(f, "estate encryption {step} failed: {detail}")
            }
            MigrationError::VerificationFailed { source, copy } => write!(
                f,
                "the encrypted copy does not match the original and has been deleted; \
                 the original estate is untouched. original: {source} copy: {copy}"
            ),
            MigrationError::SwapFailed { detail } => write!(
                f,
                "estate swap failed — the original plaintext estate is still in place: {detail}"
            ),
            MigrationError::InstallKeyMalformed { path, count } => write!(
                f,
                "install key at {path} is {count} bytes, expected {INSTALL_KEY_BYTE_COUNT}"
            ),
            MigrationError::InstallKeyUnavailable { path, detail } => {
                write!(f, "install key at {path} is unavailable: {detail}")
            }
        }
    }
}

impl std::error::Error for MigrationError {}

/// Result alias for every entry point in this crate.
pub type MigrationResult<T> = Result<T, MigrationError>;

// ─────────────────────────────────────────────────────────────────────────────
// Detection — mirrors Swift `detectEstateFileState`
// ─────────────────────────────────────────────────────────────────────────────

/// What the file at an estate path is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateFileState {
    /// No file at that path.
    Absent,
    /// A readable plaintext SQLite database — the conversion's only
    /// acceptable source.
    Plaintext,
    /// Not a plaintext SQLite database. For an existing estate this means
    /// SQLCipher, whose page 1 — including the header — is encrypted.
    Ciphertext,
}

/// The plaintext SQLite file magic: ASCII "SQLite format 3" plus the
/// terminating zero byte, 16 bytes. A SQLCipher database encrypts page 1
/// including this header, so its first 16 bytes never match.
pub const PLAINTEXT_SQLITE_MAGIC: [u8; 16] = *b"SQLite format 3\0";

/// Classify the estate file at `path` by reading its first 16 bytes.
///
/// Reads bytes DIRECTLY and never opens a SQLite connection: a connection
/// cannot classify a file whose key the caller does not have, and
/// guess-then-catch turns an unrelated failure into a misclassification.
/// Unreadable and too-short files classify as `Ciphertext`, never `Absent`,
/// so a caller never creates a fresh estate over a file it does not
/// understand.
pub fn detect_estate_file_state(path: &Path) -> EstateFileState {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => return EstateFileState::Absent,
    };
    // A directory at the estate path is not a plaintext database, and must
    // not be reported as one.
    if meta.is_dir() {
        return EstateFileState::Absent;
    }
    let mut head = [0u8; 16];
    let read = std::fs::File::open(path).and_then(|mut f| {
        use std::io::Read;
        f.read(&mut head)
    });
    match read {
        Ok(n) if n == head.len() => {
            if head == PLAINTEXT_SQLITE_MAGIC {
                EstateFileState::Plaintext
            } else {
                EstateFileState::Ciphertext
            }
        }
        // Exists but unreadable or too short: certainly not a readable
        // plaintext estate.
        _ => EstateFileState::Ciphertext,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw-connection helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Lowercase hex of the raw 32-byte estate key. Never log or embed the result
/// in errors.
pub fn key_hex(key: &[u8]) -> String {
    let mut s = String::with_capacity(key.len() * 2);
    for b in key {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Escape a path for embedding in a single-quoted SQL string literal.
pub fn sql_quoted(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "''"))
}

/// Open a raw connection, keying it first when `key` is given. The step name
/// is reported on failure; SQL (which may embed key hex) never appears in any
/// error.
pub fn open_raw(path: &Path, key: Option<&[u8]>) -> MigrationResult<Connection> {
    let conn = Connection::open(path).map_err(|e| MigrationError::Sqlite {
        step: "open".into(),
        detail: e.to_string(),
    })?;
    if let Some(key) = key {
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", key_hex(key)))
            .map_err(|_| MigrationError::Sqlite {
                step: "keying".into(),
                detail: "keying failed".into(),
            })?;
    }
    Ok(conn)
}

/// Run one statement, mapping failure to `MigrationError`. `step` is the human
/// name reported on failure; the SQL itself is never reported.
pub fn exec(conn: &Connection, sql: &str, step: &str) -> MigrationResult<()> {
    conn.execute_batch(sql).map_err(|e| MigrationError::Sqlite {
        step: step.to_string(),
        detail: e.to_string(),
    })
}

/// Remove a database file and its `-wal`/`-shm` siblings, best-effort.
pub fn remove_database(path: &Path) {
    let _ = std::fs::remove_file(path);
    for suffix in ["-wal", "-shm"] {
        let _ = std::fs::remove_file(sibling(path, suffix));
    }
}

/// `path` with `suffix` appended to the file name (`estate.sqlite-wal`).
fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    path.with_file_name(name)
}

// ─────────────────────────────────────────────────────────────────────────────
// The clone — mirrors Swift `exportEncryptedCopy`
// ─────────────────────────────────────────────────────────────────────────────

/// Clone the plaintext estate at `source` into a NEW encrypted database at
/// `destination`, keyed with `key`, via `sqlcipher_export()`.
///
/// The destination is created by the ATTACH and removed again (with siblings)
/// on any failure, so a failed export leaves no partial ciphertext behind. The
/// source's WAL is checkpointed first so the original is self-contained; its
/// content is never modified.
pub fn export_encrypted_copy(
    source: &Path,
    destination: &Path,
    key: &[u8],
) -> MigrationResult<()> {
    // Refuse anything that is not a readable plaintext database — public entry
    // point, so the gate runs here too, not just in the caller.
    if detect_estate_file_state(source) != EstateFileState::Plaintext {
        return Err(MigrationError::SourceNotPlaintext {
            path: source.display().to_string(),
        });
    }

    let conn = open_raw(source, None)?;
    let result = (|| -> MigrationResult<()> {
        // Fold the WAL into the main file so no sibling carries rows the main
        // file lacks.
        exec(&conn, "PRAGMA wal_checkpoint(TRUNCATE);", "checkpoint")?;
        // ATTACH creates the encrypted destination; sqlcipher_export copies
        // every table, index, and trigger into it row-by-row. The attach SQL
        // embeds key hex — on failure only the step name is reported.
        conn.execute_batch(&format!(
            "ATTACH {} AS encrypted KEY \"x'{}'\";",
            sql_quoted(destination),
            key_hex(key)
        ))
        .map_err(|e| MigrationError::Sqlite {
            step: "attach".into(),
            detail: e.to_string(),
        })?;
        exec(&conn, "SELECT sqlcipher_export('encrypted');", "export")?;
        exec(&conn, "DETACH encrypted;", "detach")?;
        Ok(())
    })();

    if result.is_err() {
        // No partial ciphertext may outlive a failed export.
        remove_database(destination);
    }
    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Verification — mirrors Swift `verifyEncryptedCopy`
// ─────────────────────────────────────────────────────────────────────────────

/// The four row counts that gate the swap: what a user cannot regenerate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerificationCounts {
    pub drawers: i64,
    pub kg_facts: i64,
    pub tunnels: i64,
    pub recall_traces: i64,
}

impl fmt::Display for VerificationCounts {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "drawers={} kg_facts={} tunnels={} recall_trace={}",
            self.drawers, self.kg_facts, self.tunnels, self.recall_traces
        )
    }
}

/// One table's row count. A missing table or a wrong key surfaces as an error,
/// never as zero — a fabricated zero could make a truncated copy "match" an
/// empty table.
pub fn count_rows(conn: &Connection, table: &str) -> MigrationResult<i64> {
    conn.query_row(&format!("SELECT COUNT(*) FROM \"{table}\";"), [], |r| r.get(0))
        .map_err(|e| MigrationError::Sqlite {
            step: format!("count {table}"),
            detail: e.to_string(),
        })
}

/// TOTAL row counts (tombstoned included — the physical clone must preserve
/// every row, so the strictest comparable number is the gate) of the four
/// gated tables. Table names are the substrate schema's.
pub fn verification_counts(path: &Path, key: Option<&[u8]>) -> MigrationResult<VerificationCounts> {
    let conn = open_raw(path, key)?;
    Ok(VerificationCounts {
        drawers: count_rows(&conn, "drawers")?,
        kg_facts: count_rows(&conn, "kg_facts")?,
        tunnels: count_rows(&conn, "tunnels")?,
        recall_traces: count_rows(&conn, "recall_trace")?,
    })
}

/// Every non-table schema object (index, trigger, view) by name.
///
/// Row counts cannot see these. An index dropped by a conversion preserves
/// every row, passes an integrity check, and passes a table-by-table count
/// comparison — and changes retrieval, because the planner no longer has the
/// index. `sqlcipher_export()` copies indexes and triggers, so this comparison
/// is expected to hold; it is here because the failure it catches is silent in
/// every other check.
pub fn schema_objects(path: &Path, key: Option<&[u8]>) -> MigrationResult<Vec<String>> {
    let conn = open_raw(path, key)?;
    let mut stmt = conn
        .prepare(
            "SELECT type || ':' || name FROM sqlite_master \
             WHERE type IN ('index','trigger','view') AND name NOT LIKE 'sqlite_%' \
             ORDER BY type, name;",
        )
        .map_err(|e| MigrationError::Sqlite {
            step: "list schema objects".into(),
            detail: e.to_string(),
        })?;
    stmt.query_map([], |r| r.get::<_, String>(0))
        .and_then(|rows| rows.collect())
        .map_err(|e| MigrationError::Sqlite {
            step: "list schema objects".into(),
            detail: e.to_string(),
        })
}

/// Every user table (name → TOTAL row count), enumerated from `sqlite_master`.
/// Enumerated, not listed: a gate built on a fixed table list goes silently
/// incomplete the day the schema grows a table, and an unfaithful copy could
/// then pass by preserving only the listed four.
pub fn all_table_counts(
    path: &Path,
    key: Option<&[u8]>,
) -> MigrationResult<std::collections::BTreeMap<String, i64>> {
    let conn = open_raw(path, key)?;
    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' \
             AND name NOT LIKE 'sqlite_%' ORDER BY name;",
        )
        .map_err(|e| MigrationError::Sqlite {
            step: "list tables".into(),
            detail: e.to_string(),
        })?;
    let names: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .and_then(|rows| rows.collect())
        .map_err(|e| MigrationError::Sqlite {
            step: "list tables".into(),
            detail: e.to_string(),
        })?;
    let mut counts = std::collections::BTreeMap::new();
    for table in names {
        let n = count_rows(&conn, &table)?;
        counts.insert(table, n);
    }
    Ok(counts)
}

/// `PRAGMA integrity_check`. Errors unless the result is exactly the single
/// row "ok". Structural soundness is a precondition the row-count gate cannot
/// see: counts read intact B-tree paths and say nothing about corruption
/// elsewhere in a page.
pub fn assert_integrity(path: &Path, key: Option<&[u8]>) -> MigrationResult<()> {
    let conn = open_raw(path, key)?;
    let mut stmt = conn
        .prepare("PRAGMA integrity_check;")
        .map_err(|e| MigrationError::Sqlite {
            step: "integrity_check".into(),
            detail: e.to_string(),
        })?;
    let findings: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .and_then(|rows| rows.collect())
        .map_err(|e| MigrationError::Sqlite {
            step: "integrity_check".into(),
            detail: e.to_string(),
        })?;
    if findings != ["ok"] {
        return Err(MigrationError::Sqlite {
            step: "integrity_check".into(),
            detail: if findings.is_empty() {
                "no result rows".to_string()
            } else {
                findings.join("; ")
            },
        });
    }
    Ok(())
}

/// One side of a failed table-complete comparison, with the tables that differ
/// from `other` singled out so the error names the divergence instead of
/// dumping two full maps. Mirrors Swift `tableCountsDescription`.
pub fn table_counts_description(
    counts: &std::collections::BTreeMap<String, i64>,
    other: &std::collections::BTreeMap<String, i64>,
) -> String {
    let mut parts: Vec<String> = counts
        .iter()
        .filter(|(name, n)| other.get(*name) != Some(n))
        .map(|(name, n)| format!("{name}={n}"))
        .collect();
    parts.extend(
        other
            .keys()
            .filter(|name| !counts.contains_key(*name))
            .map(|name| format!("{name}=absent")),
    );
    if parts.is_empty() {
        format!("{} tables, all matching", counts.len())
    } else {
        format!("{} tables; differing: {}", counts.len(), parts.join(" "))
    }
}

/// Compare the plaintext original against the encrypted copy. On any
/// difference the copy is deleted and an error returned — the original is
/// never touched by this function.
///
/// The gate is three layers, strongest first:
///   1. `PRAGMA integrity_check` on the encrypted copy.
///   2. Schema-complete comparison — every user table by name, TOTAL rows.
///   3. The four headline counts, returned for display and logging.
pub fn verify_encrypted_copy(
    original: &Path,
    encrypted_copy: &Path,
    key: &[u8],
) -> MigrationResult<VerificationCounts> {
    let layered = (|| -> MigrationResult<()> {
        assert_integrity(encrypted_copy, Some(key))?;
        // Indexes and triggers first: a dropped index is invisible to every
        // row-count comparison below it.
        let source_schema = schema_objects(original, None)?;
        let copy_schema = schema_objects(encrypted_copy, Some(key))?;
        if source_schema != copy_schema {
            let missing: Vec<&String> =
                source_schema.iter().filter(|o| !copy_schema.contains(o)).collect();
            let extra: Vec<&String> =
                copy_schema.iter().filter(|o| !source_schema.contains(o)).collect();
            return Err(MigrationError::VerificationFailed {
                source: format!(
                    "{} schema objects{}",
                    source_schema.len(),
                    if missing.is_empty() { String::new() }
                    else { format!("; missing from copy: {missing:?}") }
                ),
                copy: format!(
                    "{} schema objects{}",
                    copy_schema.len(),
                    if extra.is_empty() { String::new() }
                    else { format!("; not in source: {extra:?}") }
                ),
            });
        }
        let source_tables = all_table_counts(original, None)?;
        let copy_tables = all_table_counts(encrypted_copy, Some(key))?;
        if source_tables != copy_tables {
            return Err(MigrationError::VerificationFailed {
                source: table_counts_description(&source_tables, &copy_tables),
                copy: table_counts_description(&copy_tables, &source_tables),
            });
        }
        Ok(())
    })();
    if let Err(e) = layered {
        // Any failed layer condemns the copy: never leave a ciphertext file
        // that failed verification where a retry could adopt it.
        remove_database(encrypted_copy);
        return Err(e);
    }
    let source = verification_counts(original, None)?;
    let copy = verification_counts(encrypted_copy, Some(key))?;
    if source != copy {
        remove_database(encrypted_copy);
        return Err(MigrationError::VerificationFailed {
            source: source.to_string(),
            copy: copy.to_string(),
        });
    }
    Ok(copy)
}

// ─────────────────────────────────────────────────────────────────────────────
// Swap seams — mirrors Swift `DaemonControl` / `TrashItem`
// ─────────────────────────────────────────────────────────────────────────────

/// Daemon control seam. The production implementation belongs to the caller
/// (the CLI owns systemd / launchd / Task Scheduler); tests inject recorders
/// and fault throwers so every failure path is drivable without a daemon.
pub struct DaemonControl {
    pub is_running: Box<dyn Fn() -> bool + Send + Sync>,
    pub stop: Box<dyn Fn() -> bool + Send + Sync>,
    pub start: Box<dyn Fn() -> bool + Send + Sync>,
}

impl DaemonControl {
    pub fn new(
        is_running: Box<dyn Fn() -> bool + Send + Sync>,
        stop: Box<dyn Fn() -> bool + Send + Sync>,
        start: Box<dyn Fn() -> bool + Send + Sync>,
    ) -> Self {
        DaemonControl { is_running, stop, start }
    }

    /// A no-daemon environment (also the test default).
    pub fn none() -> Self {
        DaemonControl::new(
            Box::new(|| false),
            Box::new(|| true),
            Box::new(|| true),
        )
    }
}

/// Trash seam. Returns where the item ended up.
pub type TrashItem = Box<dyn Fn(&Path) -> std::io::Result<PathBuf> + Send + Sync>;

/// Retains the original beside the estate instead of trashing it, and reports
/// where it stayed. This is the default where no system Trash exists, and it
/// is the behaviour this port has always had.
pub fn retain_original(url: &Path) -> std::io::Result<PathBuf> {
    Ok(url.to_path_buf())
}

/// The trash seam used when a caller does not supply one. There is no reliable
/// cross-platform Trash on the Rust targets, so this retains. `SwapOutcome`
/// records which happened, so a caller never has to infer it from the target.
pub fn default_trash() -> TrashItem {
    Box::new(retain_original)
}

/// What the swap did, for exact reporting. `untrashed_original_path` is set
/// when the plaintext original could NOT be moved to the Trash and is still
/// sitting beside the estate — the caller MUST surface it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwapOutcome {
    pub daemon_was_running: bool,
    pub daemon_restarted: bool,
    pub trashed_original_url: Option<PathBuf>,
    pub untrashed_original_path: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// The swap — mirrors Swift `swapInEncryptedCopy` (file work only)
// ─────────────────────────────────────────────────────────────────────────────

/// Swap the verified encrypted copy onto the canonical estate path.
///
/// FILE WORK ONLY: the caller (`migrate`) owns the daemon lifecycle and has
/// already stopped it — before the export, so no write can land in the
/// original after the copy was taken.
///
/// Sequence, chosen so the canonical path holds a complete, openable estate at
/// every instant — including across a crash of this process:
///
///   1. move the original's `-wal`/`-shm` siblings aside
///   2. HARD-LINK the original to the aside name — the original's bytes now
///      have two directory entries, so step 3 can replace the canonical entry
///      without ever orphaning the plaintext data
///   3. `rename()` the encrypted copy onto the canonical path (atomic replace
///      on POSIX; on Windows, where rename refuses an existing destination,
///      the canonical entry is removed first — the aside hard link from step 2
///      still holds the original's bytes, so even a crash inside that
///      non-atomic window loses nothing)
///   4. hand the aside original (+ siblings) to the trash seam
///
/// A failure in 1–3 unwinds to the plaintext original at the canonical path
/// and deletes the copy. A trash failure is reported, not fatal: the encrypted
/// estate is already in place and working.
pub fn swap_in_encrypted_copy(
    original: &Path,
    encrypted_copy: &Path,
    trash: &TrashItem,
) -> MigrationResult<(Option<PathBuf>, Option<String>)> {
    let aside = sibling(original, ".pre-encryption");

    let unwind = |moved: &[(PathBuf, PathBuf)], linked: bool| {
        for (from, to) in moved.iter().rev() {
            let _ = std::fs::rename(to, from);
        }
        if linked {
            let _ = std::fs::remove_file(&aside);
        }
        remove_database(encrypted_copy);
    };

    // 1. Plaintext siblings aside — normally absent after the export's
    //    checkpoint(TRUNCATE); moved, not deleted, so an unwind restores them
    //    exactly as found.
    let mut moved: Vec<(PathBuf, PathBuf)> = Vec::new();
    for suffix in ["-wal", "-shm"] {
        let sib = sibling(original, suffix);
        if !sib.exists() {
            continue;
        }
        let sidelined = sibling(&aside, suffix);
        let _ = std::fs::remove_file(&sidelined);
        if let Err(e) = std::fs::rename(&sib, &sidelined) {
            unwind(&moved, false);
            return Err(MigrationError::SwapFailed {
                detail: format!("could not set aside {}: {e}", sib.display()),
            });
        }
        moved.push((sib, sidelined));
    }

    // 2. Second directory entry for the original's bytes.
    let _ = std::fs::remove_file(&aside);
    if let Err(e) = std::fs::hard_link(original, &aside) {
        unwind(&moved, false);
        return Err(MigrationError::SwapFailed {
            detail: format!("could not link the original aside: {e}"),
        });
    }

    // 3. The swap itself.
    #[cfg(windows)]
    {
        // Windows rename refuses an existing destination. Removing the
        // canonical entry first is safe: the aside hard link holds the
        // original's bytes, so no crash inside this window loses data.
        if let Err(e) = std::fs::remove_file(original) {
            unwind(&moved, true);
            return Err(MigrationError::SwapFailed {
                detail: format!("could not clear the canonical entry: {e}"),
            });
        }
    }
    if let Err(e) = std::fs::rename(encrypted_copy, original) {
        // POSIX: original still at canonical (atomic rename never landed).
        // Windows: canonical entry was removed above — put the original back
        // from the aside link before unwinding.
        #[cfg(windows)]
        let _ = std::fs::hard_link(&aside, original);
        unwind(&moved, true);
        return Err(MigrationError::SwapFailed {
            detail: format!("atomic rename onto {} failed: {e}", original.display()),
        });
    }

    // 4. Hand the plaintext original and any sidelined siblings to the trash
    //    seam. Whatever it does, the result is STILL UNENCRYPTED — the
    //    caller's success message must say so.
    match trash(&aside) {
        Ok(dest) => {
            for (_, to) in &moved {
                let _ = trash(to);
            }
            // The retaining seam returns the aside path unchanged: the
            // original was not trashed, it stayed. Report it as untrashed so
            // the caller surfaces it either way.
            if dest == aside {
                Ok((None, Some(aside.display().to_string())))
            } else {
                Ok((Some(dest), None))
            }
        }
        // Keep the original in place and report its path rather than
        // proceeding silently.
        Err(_) => Ok((None, Some(aside.display().to_string()))),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The full migration — mirrors Swift `migrate`
// ─────────────────────────────────────────────────────────────────────────────

/// End-to-end conversion for a plaintext estate at `estate_path`:
/// stop daemon → clone → verify → swap → restart → trash, with `key` already
/// provisioned by the caller (key custody belongs to the caller; this crate
/// never touches a keychain). Errors on any failure that left the plaintext
/// original in place; the error says so explicitly.
///
/// The daemon stops BEFORE the export: never lose data. Stopping only at swap
/// time would leave a window where rows written after the copy was taken exist
/// only in the original that is displaced. With the daemon quiesced first, the
/// encrypted copy is complete relative to every write that ever committed.
pub fn migrate(
    estate_path: &Path,
    key: &[u8],
    daemon: &DaemonControl,
    trash: &TrashItem,
) -> MigrationResult<(VerificationCounts, SwapOutcome)> {
    let copy = sibling(estate_path, ".encrypting");
    // A stale copy from an interrupted earlier run is untrusted by definition —
    // regenerate rather than resume.
    remove_database(&copy);

    // Quiesce FIRST, so nothing can write to the original once the clone
    // exists. Refusing to proceed when the daemon will not stop is the safe
    // direction: nothing has been touched yet.
    let was_running = (daemon.is_running)();
    if was_running && !(daemon.stop)() {
        return Err(MigrationError::SwapFailed {
            detail: "the resident daemon would not stop; nothing was changed".into(),
        });
    }

    let run = (|| -> MigrationResult<(VerificationCounts, Option<PathBuf>, Option<String>)> {
        export_encrypted_copy(estate_path, &copy, key)?;
        let counts = verify_encrypted_copy(estate_path, &copy, key)?;
        let (trashed, untrashed) = swap_in_encrypted_copy(estate_path, &copy, trash)?;
        Ok((counts, trashed, untrashed))
    })();

    match run {
        Ok((counts, trashed, untrashed)) => {
            // Bring the daemon back over the encrypted estate. Failure here is
            // reported, never fatal: the migration itself has succeeded.
            let restarted = if was_running { (daemon.start)() } else { false };
            Ok((
                counts,
                SwapOutcome {
                    daemon_was_running: was_running,
                    daemon_restarted: restarted,
                    trashed_original_url: trashed,
                    untrashed_original_path: untrashed,
                },
            ))
        }
        Err(e) => {
            // Every failure between stop and swap leaves the plaintext original
            // at the canonical path; put the daemon back over it.
            if was_running {
                let _ = (daemon.start)();
            }
            Err(e)
        }
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;

// ─────────────────────────────────────────────────────────────────────────────
// Install key file — HARNESS ONLY (mirrors Swift `MOOTX01_HARNESS_KEYFILE`)
// ─────────────────────────────────────────────────────────────────────────────
//
// WHY THIS IS FENCED
// The product resolves a database key its own way on each platform: a `db.key`
// file beside the databases on the Rust side, the Keychain on the Swift side.
// A benchmark harness needs neither — it serves a database it converted moments
// earlier and deletes minutes later, and durable key custody costs an approval
// prompt per spawned server and leaves residue behind.
//
// So the file-based key lives here, behind the `harness-keyfile` feature, and
// is absent from every production build. What the harness measures is retrieval
// over encrypted pages, which does not depend on where the key came from.

/// Length of an install key. Matches PersistenceKit's `INSTALL_KEY_LEN` and the
/// Swift port's `installKeyByteCount`.
pub const INSTALL_KEY_BYTE_COUNT: usize = 32;

/// Filename of the install key beside the databases it opens. Matches
/// PersistenceKit's `INSTALL_KEY_FILE` and the Swift port's
/// `installKeyFileName`.
pub const INSTALL_KEY_FILE_NAME: &str = "db.key";

/// Path of the install key file for databases held in `directory`.
pub fn install_key_path(directory: &Path) -> PathBuf {
    directory.join(INSTALL_KEY_FILE_NAME)
}

/// Read the install key for `directory`, creating it if absent.
///
/// A file of the wrong length fails loud rather than being regenerated:
/// regeneration would render every database already encrypted under the real
/// key permanently undecryptable.
#[cfg(feature = "harness-keyfile")]
pub fn load_or_create_install_key(directory: &Path) -> MigrationResult<Vec<u8>> {
    let path = install_key_path(directory);
    if let Ok(bytes) = std::fs::read(&path) {
        if bytes.len() != INSTALL_KEY_BYTE_COUNT {
            return Err(MigrationError::InstallKeyMalformed {
                path: path.display().to_string(),
                count: bytes.len(),
            });
        }
        return Ok(bytes);
    }

    // Key bytes come from the OS CSPRNG the same way the rest of the crate's
    // SQLCipher material does; the key never leaves the harness scratch dir.
    let mut key = vec![0u8; INSTALL_KEY_BYTE_COUNT];
    getrandom_bytes(&mut key).map_err(|detail| MigrationError::InstallKeyUnavailable {
        path: path.display().to_string(),
        detail,
    })?;
    write_install_key(&key, directory)?;
    Ok(key)
}

/// Write `key` as the install key for `directory`, replacing any existing one.
///
/// Replacing is required, not incidental: the harness converts a database with
/// a key it chose and then hands that same key to the server, so a file left by
/// an earlier cell must not win. Creation is atomic and owner-only —
/// `O_CREAT | O_EXCL` with mode 0600 sets the mode in the inode before the
/// directory entry is visible, so there is no window where the key is group- or
/// world-readable, and a pre-planted symlink at the path is refused rather than
/// followed.
#[cfg(feature = "harness-keyfile")]
pub fn write_install_key(key: &[u8], directory: &Path) -> MigrationResult<()> {
    use std::io::Write as _;

    let path = install_key_path(directory);
    if key.len() != INSTALL_KEY_BYTE_COUNT {
        return Err(MigrationError::InstallKeyMalformed {
            path: path.display().to_string(),
            count: key.len(),
        });
    }
    std::fs::create_dir_all(directory).map_err(|e| MigrationError::InstallKeyUnavailable {
        path: path.display().to_string(),
        detail: format!("create dir: {e}"),
    })?;
    let _ = std::fs::remove_file(&path);

    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let mut file = options
        .open(&path)
        .map_err(|e| MigrationError::InstallKeyUnavailable {
            path: path.display().to_string(),
            detail: format!("open: {e}"),
        })?;
    file.write_all(key)
        .map_err(|e| MigrationError::InstallKeyUnavailable {
            path: path.display().to_string(),
            detail: format!("write: {e}"),
        })
}

/// Fill `buffer` from the OS CSPRNG. Reads `/dev/urandom` rather than taking a
/// dependency: the crate has one, and the C-1 zero-external-dependency rule is
/// not relaxed for harness-only code.
#[cfg(feature = "harness-keyfile")]
fn getrandom_bytes(buffer: &mut [u8]) -> Result<(), String> {
    use std::io::Read as _;
    let mut source = std::fs::File::open("/dev/urandom")
        .map_err(|e| format!("open /dev/urandom: {e}"))?;
    source
        .read_exact(buffer)
        .map_err(|e| format!("read /dev/urandom: {e}"))
}
