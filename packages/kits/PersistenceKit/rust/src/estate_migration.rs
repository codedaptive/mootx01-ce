//! estate_migration.rs — plaintext → SQLCipher estate migration primitives.
//!
//! Rust leg of CE-1.0.35-08 (Swift: `EstateEncryptionMigrator.swift` in
//! MootInstallerCore; Swift leads, this follows). The mission originally
//! scoped migration to macOS, but the estate FILE is portable across legs by
//! design: a plaintext estate created by a Swift macOS install and carried to
//! a Linux/Windows box lands on this leg, where (a) without a sibling
//! `db.key` it would serve plaintext silently forever, and (b) with one it
//! fails `PRAGMA key` in a way that looks like corruption. `mootx01 upgrade`
//! is the ONLY migration vehicle on every platform, so the primitives live
//! here and the CLI's upgrade command drives them.
//!
//! Design invariant, verbatim from the Swift leg:
//!
//!   EVERY FAILURE PATH LEAVES A WORKING ESTATE AT THE CANONICAL PATH.
//!
//! The clone is PHYSICAL, via SQLCipher's `sqlcipher_export()` over an
//! ATTACHed encrypted database — never a logical re-import through the
//! capture seam, which would mint new row ids and lose trace rows,
//! fingerprints, and the Merkle rollup.
//!
//! The daemon lifecycle is the CALLER's job (the CLI owns systemd / Task
//! Scheduler): quiesce BEFORE `export_encrypted_copy` (Bob's ruling: never
//! lose data — no write may land after the clone is taken), restart after
//! the swap or on any failure. These functions do file work only.

use std::path::{Path, PathBuf};

use rusqlite::Connection;

use crate::{StorageError, StorageResult};

// ─────────────────────────────────────────────────────────────────────────────
// Detection — mirrors Swift `EstateKeyProvider.detectEstateFileState`
// ─────────────────────────────────────────────────────────────────────────────

/// What the file at an estate path is. Byte-for-byte the Swift semantics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateFileState {
    /// No file at that path.
    Absent,
    /// A readable plaintext SQLite database — the migration's only
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

/// Lowercase hex of the raw 32-byte estate key. Never log or embed the
/// result in errors.
fn key_hex(key: &[u8]) -> String {
    let mut s = String::with_capacity(key.len() * 2);
    for b in key {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// Escape a path for embedding in a single-quoted SQL string literal.
fn sql_quoted(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "''"))
}

/// Open a raw connection, keying it first when `key` is given. `step` names
/// the operation on failure; SQL (which may embed key hex) never appears in
/// any error.
fn open_raw(path: &Path, key: Option<&[u8]>) -> StorageResult<Connection> {
    let conn = Connection::open(path).map_err(|e| StorageError::BackendError {
        underlying: format!("estate encryption open failed: {e}"),
    })?;
    if let Some(key) = key {
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", key_hex(key)))
            .map_err(|_| StorageError::BackendError {
                underlying: "estate encryption keying failed".into(),
            })?;
    }
    Ok(conn)
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
/// The destination is created by the ATTACH and removed again (with
/// siblings) on any failure, so a failed export leaves no partial
/// ciphertext behind. The source's WAL is checkpointed first so the
/// retained plaintext original is self-contained; its content is never
/// modified.
pub fn export_encrypted_copy(source: &Path, destination: &Path, key: &[u8]) -> StorageResult<()> {
    // Refuse anything that is not a readable plaintext database — public
    // entry point, so the gate runs here too, not just in the caller.
    if detect_estate_file_state(source) != EstateFileState::Plaintext {
        return Err(StorageError::BackendError {
            underlying: format!(
                "refusing to migrate {}: it is not a readable plaintext SQLite database",
                source.display()
            ),
        });
    }

    let conn = open_raw(source, None)?;
    let result = (|| -> StorageResult<()> {
        let step = |sql: &str, name: &str| -> StorageResult<()> {
            conn.execute_batch(sql).map_err(|e| StorageError::BackendError {
                underlying: format!("estate encryption {name} failed: {e}"),
            })
        };
        // Fold the WAL into the main file so no sibling carries rows the
        // main file lacks.
        step("PRAGMA wal_checkpoint(TRUNCATE);", "checkpoint")?;
        // ATTACH creates the encrypted destination; sqlcipher_export copies
        // every table, index, and trigger into it row-by-row. The attach
        // SQL embeds key hex — on failure only the step name is reported.
        conn.execute_batch(&format!(
            "ATTACH {} AS encrypted KEY \"x'{}'\";",
            sql_quoted(destination),
            key_hex(key)
        ))
        .map_err(|e| StorageError::BackendError {
            underlying: format!("estate encryption attach failed: {e}"),
        })?;
        step("SELECT sqlcipher_export('encrypted');", "export")?;
        step("DETACH encrypted;", "detach")?;
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

impl std::fmt::Display for VerificationCounts {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "drawers={} kg_facts={} tunnels={} recall_trace={}",
            self.drawers, self.kg_facts, self.tunnels, self.recall_traces
        )
    }
}

/// TOTAL row counts (tombstoned included — the physical clone must preserve
/// every row, so the strictest comparable number is the gate) of the four
/// gated tables. Table names are the substrate schema's: `drawers`,
/// `kg_facts`, `tunnels`, `recall_trace`. A missing table or a wrong key
/// surfaces as an error, never as zero — a fabricated zero could make a
/// truncated copy "match" an empty table.
pub fn verification_counts(path: &Path, key: Option<&[u8]>) -> StorageResult<VerificationCounts> {
    let conn = open_raw(path, key)?;
    let count = |table: &str| -> StorageResult<i64> {
        conn.query_row(&format!("SELECT COUNT(*) FROM \"{table}\";"), [], |r| r.get(0))
            .map_err(|e| StorageError::BackendError {
                underlying: format!("estate encryption count {table} failed: {e}"),
            })
    };
    Ok(VerificationCounts {
        drawers: count("drawers")?,
        kg_facts: count("kg_facts")?,
        tunnels: count("tunnels")?,
        recall_traces: count("recall_trace")?,
    })
}

/// Every user table (name → TOTAL row count) of the database at `path`,
/// enumerated from `sqlite_master`. Enumerated, not listed: a gate built on
/// a fixed table list goes silently incomplete the day the schema grows a
/// table (audit history, diary, erasure ledger…), and an unfaithful copy
/// could then pass by preserving only the listed four. Mirrors Swift
/// `allTableCounts`.
pub fn all_table_counts(
    path: &Path,
    key: Option<&[u8]>,
) -> StorageResult<std::collections::BTreeMap<String, i64>> {
    let conn = open_raw(path, key)?;
    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' \
             AND name NOT LIKE 'sqlite_%' ORDER BY name;",
        )
        .map_err(|e| StorageError::BackendError {
            underlying: format!("estate encryption list tables failed: {e}"),
        })?;
    let names: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .and_then(|rows| rows.collect())
        .map_err(|e| StorageError::BackendError {
            underlying: format!("estate encryption list tables failed: {e}"),
        })?;
    let mut counts = std::collections::BTreeMap::new();
    for table in names {
        let n: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM \"{table}\";"), [], |r| r.get(0))
            .map_err(|e| StorageError::BackendError {
                underlying: format!("estate encryption count {table} failed: {e}"),
            })?;
        counts.insert(table, n);
    }
    Ok(counts)
}

/// `PRAGMA integrity_check` on the database at `path`. Errors unless the
/// result is exactly the single row "ok". Structural soundness is a
/// precondition the row-count gate cannot see: counts read intact B-tree
/// paths and say nothing about corruption elsewhere in a page. Mirrors
/// Swift `assertIntegrity`.
pub fn assert_integrity(path: &Path, key: Option<&[u8]>) -> StorageResult<()> {
    let conn = open_raw(path, key)?;
    let mut stmt = conn
        .prepare("PRAGMA integrity_check;")
        .map_err(|e| StorageError::BackendError {
            underlying: format!("estate encryption integrity_check failed: {e}"),
        })?;
    let findings: Vec<String> = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .and_then(|rows| rows.collect())
        .map_err(|e| StorageError::BackendError {
            underlying: format!("estate encryption integrity_check failed: {e}"),
        })?;
    if findings != ["ok"] {
        return Err(StorageError::BackendError {
            underlying: format!(
                "estate encryption integrity_check failed: {}",
                if findings.is_empty() {
                    "no result rows".to_string()
                } else {
                    findings.join("; ")
                }
            ),
        });
    }
    Ok(())
}

/// Compare the plaintext original against the encrypted copy. On any
/// difference the copy is deleted and an error returned — the original is
/// never touched by this function.
///
/// The gate is three layers, strongest first (hardened in lockstep with
/// Swift `verifyEncryptedCopy` per Codex 06fa2bc2 — once the swap is live,
/// this comparison is the only thing standing between an unfaithful copy
/// and the plaintext original being displaced):
///   1. `PRAGMA integrity_check` on the encrypted copy — structural
///      soundness of every page, which row counts cannot see.
///   2. Schema-complete comparison — every user table in either database
///      by name, TOTAL rows each. Catches dropped tables, gained tables,
///      and row loss anywhere in the estate, not just the four headline
///      tables.
///   3. The four headline counts, returned for display and logging.
pub fn verify_encrypted_copy(
    original: &Path,
    encrypted_copy: &Path,
    key: &[u8],
) -> StorageResult<VerificationCounts> {
    let layered = (|| -> StorageResult<()> {
        assert_integrity(encrypted_copy, Some(key))?;
        let source_tables = all_table_counts(original, None)?;
        let copy_tables = all_table_counts(encrypted_copy, Some(key))?;
        if source_tables != copy_tables {
            let differing: Vec<String> = source_tables
                .iter()
                .filter(|(name, n)| copy_tables.get(*name) != Some(n))
                .map(|(name, n)| {
                    format!(
                        "{name}: original={n} copy={}",
                        copy_tables
                            .get(name)
                            .map_or_else(|| "absent".to_string(), i64::to_string)
                    )
                })
                .chain(
                    copy_tables
                        .keys()
                        .filter(|name| !source_tables.contains_key(*name))
                        .map(|name| format!("{name}: original=absent copy={}", copy_tables[name])),
                )
                .collect();
            return Err(StorageError::BackendError {
                underlying: format!(
                    "the encrypted copy does not match the original ({} tables compared; \
                     differing: {})",
                    source_tables.len(),
                    differing.join(", ")
                ),
            });
        }
        Ok(())
    })();
    if let Err(e) = layered {
        // Any failed layer condemns the copy: never leave a ciphertext file
        // that failed verification where a retry could adopt it.
        remove_database(encrypted_copy);
        return Err(StorageError::BackendError {
            underlying: format!(
                "{e}; the copy has been deleted and the original estate is untouched"
            ),
        });
    }
    let source = verification_counts(original, None)?;
    let copy = verification_counts(encrypted_copy, Some(key))?;
    if source != copy {
        remove_database(encrypted_copy);
        return Err(StorageError::BackendError {
            underlying: format!(
                "the encrypted copy does not match the original and has been deleted; \
                 the original estate is untouched. original: {source} copy: {copy}"
            ),
        });
    }
    Ok(copy)
}

// ─────────────────────────────────────────────────────────────────────────────
// The swap — mirrors Swift `swapInEncryptedCopy` (file work only)
// ─────────────────────────────────────────────────────────────────────────────

/// What the swap did with the plaintext original. There is no reliable
/// cross-platform Trash on the Rust platforms, so the original is RETAINED
/// beside the estate under the `.pre-encryption` name — never deleted. The
/// caller's success message must state it is still unencrypted and that
/// deleting it is the final step of the migration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwapOutcome {
    /// Where the plaintext original now lives.
    pub retained_original: PathBuf,
}

/// Swap the verified encrypted copy onto the canonical estate path.
///
/// The caller has already stopped the daemon — BEFORE the export, so no
/// write can land in the original after the copy was taken.
///
/// Sequence, chosen so the canonical path holds a complete, openable estate
/// at every instant — including across a crash of this process:
///
///   1. move the original's `-wal`/`-shm` siblings aside (they belong to
///      the plaintext file and must never sit next to the encrypted one)
///   2. HARD-LINK the original to the aside name — the original's bytes now
///      have two directory entries, so step 3 can replace the canonical
///      entry without ever orphaning the plaintext data
///   3. `rename()` the encrypted copy onto the canonical path (atomic
///      replace on POSIX; on Windows, where rename refuses an existing
///      destination, the canonical entry is removed first — the aside hard
///      link from step 2 still holds the original's bytes, so even a crash
///      inside that non-atomic window loses nothing)
///
/// Any failure unwinds to the plaintext original at the canonical path and
/// deletes the copy.
pub fn swap_in_encrypted_copy(original: &Path, encrypted_copy: &Path) -> StorageResult<SwapOutcome> {
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
    //    checkpoint(TRUNCATE); moved, not deleted, so an unwind restores
    //    them exactly as found.
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
            return Err(StorageError::BackendError {
                underlying: format!("estate swap failed — the original plaintext estate is still in place: could not set aside {}: {e}", sib.display()),
            });
        }
        moved.push((sib, sidelined));
    }

    // 2. Second directory entry for the original's bytes.
    let _ = std::fs::remove_file(&aside);
    if let Err(e) = std::fs::hard_link(original, &aside) {
        unwind(&moved, false);
        return Err(StorageError::BackendError {
            underlying: format!("estate swap failed — the original plaintext estate is still in place: could not link the original aside: {e}"),
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
            return Err(StorageError::BackendError {
                underlying: format!("estate swap failed — the original plaintext estate is still in place: could not clear the canonical entry: {e}"),
            });
        }
    }
    if let Err(e) = std::fs::rename(encrypted_copy, original) {
        // POSIX: original still at canonical (atomic rename never landed).
        // Windows: canonical entry was removed above — put the original
        // back from the aside link before unwinding.
        #[cfg(windows)]
        let _ = std::fs::hard_link(&aside, original);
        unwind(&moved, true);
        return Err(StorageError::BackendError {
            underlying: format!(
                "estate swap failed — the original plaintext estate is still in place: rename onto {} failed: {e}",
                original.display()
            ),
        });
    }

    Ok(SwapOutcome { retained_original: aside })
}

#[cfg(test)]
mod tests {
    use super::*;

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

        let outcome = swap_in_encrypted_copy(&estate, &copy).unwrap();

        // Canonical path now holds ciphertext that opens with the key.
        assert_eq!(detect_estate_file_state(&estate), EstateFileState::Ciphertext);
        assert_eq!(verification_counts(&estate, Some(&KEY)).unwrap().drawers, 20);
        // The retained original is a complete readable plaintext estate.
        assert_eq!(
            detect_estate_file_state(&outcome.retained_original),
            EstateFileState::Plaintext
        );
        assert_eq!(
            verification_counts(&outcome.retained_original, None).unwrap().drawers,
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
        let result = swap_in_encrypted_copy(&estate, &copy);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();

        assert!(result.is_err());
        assert_eq!(detect_estate_file_state(&estate), EstateFileState::Plaintext);
        assert_eq!(verification_counts(&estate, None).unwrap().drawers, 20);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
