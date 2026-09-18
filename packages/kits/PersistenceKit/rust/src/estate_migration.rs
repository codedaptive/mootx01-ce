//! estate_migration.rs — re-export of the `estate-encryption` crate.
//!
//! The conversion itself lives in `packages/libs/EstateEncryption/rust`, which
//! the benchmark harness also consumes. It used to live here, and a second
//! divergent copy lived in Swift's MootInstallerCore; there is now one
//! implementation per port and the two ports are the same shape.
//!
//! This module keeps the names PersistenceKit callers already use and maps the
//! crate's `MigrationError` onto `StorageError`, which is the only thing that
//! differs between the crate's surface and this kit's.

use std::path::Path;

use crate::{StorageError, StorageResult};

pub use estate_encryption::{
    all_table_counts as ee_all_table_counts, assert_integrity as ee_assert_integrity,
    detect_estate_file_state, export_encrypted_copy as ee_export_encrypted_copy, key_hex,
    remove_database, sql_quoted, table_counts_description,
    verification_counts as ee_verification_counts,
    verify_encrypted_copy as ee_verify_encrypted_copy, DaemonControl, EstateFileState,
    MigrationError, SwapOutcome, TrashItem, VerificationCounts, PLAINTEXT_SQLITE_MAGIC,
};

/// Map the crate's error onto this kit's, preserving the message verbatim.
fn map(e: MigrationError) -> StorageError {
    StorageError::BackendError { underlying: e.to_string() }
}

/// Clone the plaintext estate at `source` into a NEW encrypted database.
pub fn export_encrypted_copy(source: &Path, destination: &Path, key: &[u8]) -> StorageResult<()> {
    ee_export_encrypted_copy(source, destination, key).map_err(map)
}

/// TOTAL row counts of the four gated tables.
pub fn verification_counts(path: &Path, key: Option<&[u8]>) -> StorageResult<VerificationCounts> {
    ee_verification_counts(path, key).map_err(map)
}

/// Every user table (name → TOTAL row count), enumerated from `sqlite_master`.
pub fn all_table_counts(
    path: &Path,
    key: Option<&[u8]>,
) -> StorageResult<std::collections::BTreeMap<String, i64>> {
    ee_all_table_counts(path, key).map_err(map)
}

/// `PRAGMA integrity_check` on the database at `path`.
pub fn assert_integrity(path: &Path, key: Option<&[u8]>) -> StorageResult<()> {
    ee_assert_integrity(path, key).map_err(map)
}

/// Compare the plaintext original against the encrypted copy.
pub fn verify_encrypted_copy(
    original: &Path,
    encrypted_copy: &Path,
    key: &[u8],
) -> StorageResult<VerificationCounts> {
    ee_verify_encrypted_copy(original, encrypted_copy, key).map_err(map)
}

/// Swap the verified encrypted copy onto the canonical estate path, retaining
/// the plaintext original beside it.
///
/// Kept at the previous signature and return shape for this kit's callers. The
/// crate's `swap_in_encrypted_copy` takes a trash seam and reports which of
/// trash-or-retain happened; here the retaining seam is passed and the retained
/// path is returned, which is what this kit has always done.
pub fn swap_in_encrypted_copy(original: &Path, encrypted_copy: &Path) -> StorageResult<LegacySwap> {
    let trash: TrashItem = estate_encryption::default_trash();
    let (trashed, untrashed) =
        estate_encryption::swap_in_encrypted_copy(original, encrypted_copy, &trash)
            .map_err(map)?;
    let retained = trashed
        .or_else(|| untrashed.map(std::path::PathBuf::from))
        .unwrap_or_else(|| original.to_path_buf());
    Ok(LegacySwap { retained_original: retained })
}

/// What the swap did, in this kit's shape: where the plaintext original lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacySwap {
    pub retained_original: std::path::PathBuf,
}
