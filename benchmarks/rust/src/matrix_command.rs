//! matrix_command.rs — estate-encryption conversion helpers for benchmark
//! scratch estates. Used by the posture-equivalence lane
//! (`posture_equivalence_runner`) to convert a restored plaintext working
//! copy to an encrypted one before measurement.
//!
//! The conversion is the product's own, through the shared `estate-encryption`
//! library. Nothing here is grafted into the product, and the conversion itself
//! is never timed — the encryption cost in latency belongs to the timing
//! benchmark.

use std::path::{Path, PathBuf};

/// A deterministic 32-byte key for a benchmark encryption run.
///
/// Derived from the run seed rather than minted randomly, and never written to
/// a key store: the encrypted working copies exist for the length of one
/// measurement and are deleted with the scratch directory. Recording the seed
/// in the report is enough to recreate the key.
pub fn matrix_key(seed: u64) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(32);
    let mut state = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
    while bytes.len() < 32 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        bytes.extend_from_slice(&state.to_be_bytes());
    }
    bytes.truncate(32);
    bytes
}

/// The estate database file inside a restored working copy.
///
/// Named rather than searched: the store's layout is fixed by the artifact
/// writer, and a search would silently pick a sibling if the expected file were
/// ever absent.
pub fn estate_database_path(scratch: &Path) -> PathBuf {
    scratch.join("estate.sqlite")
}

/// Converts every database in a scratch directory, not only the estate.
///
/// An estate directory holds more than one database — the estate itself and
/// the queue beside it — and the product opens both under the same posture.
/// Converting only `estate.sqlite` leaves a plaintext queue next to an
/// encrypted estate, which the server will not open.
///
/// Only the estate's row counts are returned. The queue is working state
/// rather than data under measurement, so it is verified by structure instead
/// of by the four gated counts, whose tables it does not have.
pub fn convert_scratch_directory_to_encrypted(
    scratch_dir: &Path,
    key: &[u8],
) -> Result<estate_encryption::VerificationCounts, estate_encryption::MigrationError> {
    // Main database files only: the -wal and -shm siblings belong to whichever
    // main file they sit beside and are folded in by the export's checkpoint.
    let mut databases: Vec<PathBuf> = std::fs::read_dir(scratch_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().and_then(|x| x.to_str()) == Some("sqlite"))
                .collect()
        })
        .unwrap_or_default();
    databases.sort();

    let estate = estate_database_path(scratch_dir);
    let mut estate_counts = None;
    for db in &databases {
        if estate_encryption::detect_estate_file_state(db)
            != estate_encryption::EstateFileState::Plaintext
        {
            continue;
        }
        if db == &estate {
            estate_counts = Some(convert_scratch_to_encrypted(db, key)?);
        } else {
            convert_auxiliary_database(db, key)?;
        }
    }

    estate_counts.ok_or_else(|| estate_encryption::MigrationError::SourceNotPlaintext {
        path: estate.display().to_string(),
    })
}

/// Converts a database that is not the estate.
///
/// Same physical clone and the same integrity and schema checks, but not the
/// four gated row counts: those name tables that exist only in the estate.
/// Skipping them is not skipping verification — the table-by-table comparison
/// covers whatever tables this database does have.
pub fn convert_auxiliary_database(
    plaintext_db: &Path,
    key: &[u8],
) -> Result<(), estate_encryption::MigrationError> {
    let encrypted = plaintext_db.with_extension("sqlite.encrypted");
    estate_encryption::remove_database(&encrypted);
    estate_encryption::export_encrypted_copy(plaintext_db, &encrypted, key)?;

    let checked = (|| {
        estate_encryption::assert_integrity(&encrypted, Some(key))?;
        let source_schema = estate_encryption::schema_objects(plaintext_db, None)?;
        let copy_schema = estate_encryption::schema_objects(&encrypted, Some(key))?;
        let source_tables = estate_encryption::all_table_counts(plaintext_db, None)?;
        let copy_tables = estate_encryption::all_table_counts(&encrypted, Some(key))?;
        if source_schema != copy_schema || source_tables != copy_tables {
            return Err(estate_encryption::MigrationError::VerificationFailed {
                source: plaintext_db.display().to_string(),
                copy: encrypted.display().to_string(),
            });
        }
        Ok(())
    })();
    if let Err(e) = checked {
        estate_encryption::remove_database(&encrypted);
        return Err(e);
    }

    estate_encryption::remove_database(plaintext_db);
    std::fs::rename(&encrypted, plaintext_db).map_err(|e| {
        estate_encryption::MigrationError::SwapFailed {
            detail: format!("rename encrypted auxiliary database into place: {e}"),
        }
    })
}

/// Converts a restored working copy to an encrypted database in place.
///
/// The conversion is `estate_encryption::export_encrypted_copy` — the same
/// physical `sqlcipher_export()` clone the product performs — followed by the
/// same verification the product runs before it swaps: an integrity check, a
/// schema-complete table comparison, and the four headline counts.
pub fn convert_scratch_to_encrypted(
    plaintext_db: &Path,
    key: &[u8],
) -> Result<estate_encryption::VerificationCounts, estate_encryption::MigrationError> {
    let encrypted = plaintext_db.with_extension("sqlite.encrypted");
    estate_encryption::remove_database(&encrypted);

    estate_encryption::export_encrypted_copy(plaintext_db, &encrypted, key)?;
    let counts = estate_encryption::verify_encrypted_copy(plaintext_db, &encrypted, key)?;

    // Replace the plaintext file with its verified encrypted twin so the
    // scratch directory is a working encrypted estate.
    estate_encryption::remove_database(plaintext_db);
    std::fs::rename(&encrypted, plaintext_db).map_err(|e| {
        estate_encryption::MigrationError::SwapFailed { detail: e.to_string() }
    })?;
    Ok(counts)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The key is a pure function of the seed and is 32 bytes, which is what
    /// the cipher requires.
    #[test]
    fn matrix_key_is_deterministic_and_32_bytes() {
        assert_eq!(matrix_key(7).len(), 32);
        assert_eq!(matrix_key(7), matrix_key(7));
        assert_ne!(matrix_key(7), matrix_key(8));
    }

    fn scratch_directory(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("matrix-test-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create scratch dir");
        dir
    }

    /// The key the harness hands the server is the key it converted with. A
    /// round trip that returned anything else would open the database with the
    /// wrong key and read as corruption.
    #[test]
    fn install_key_round_trips() {
        let dir = scratch_directory("keyroundtrip");
        let key = matrix_key(11);
        estate_encryption::write_install_key(&key, &dir).expect("write");
        assert_eq!(
            estate_encryption::load_or_create_install_key(&dir).expect("load"),
            key
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Writing replaces rather than honours an existing file. A key left by an
    /// earlier run is not the key this database was converted with.
    #[test]
    fn install_key_write_replaces() {
        let dir = scratch_directory("keyreplace");
        estate_encryption::write_install_key(&matrix_key(1), &dir).expect("first");
        let second = matrix_key(2);
        estate_encryption::write_install_key(&second, &dir).expect("second");
        assert_eq!(
            estate_encryption::load_or_create_install_key(&dir).expect("load"),
            second
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file of the wrong length is tampered, not a prompt to regenerate:
    /// regenerating would leave every database encrypted under the real key
    /// permanently unopenable.
    #[test]
    fn malformed_install_key_fails_loud() {
        let dir = scratch_directory("keymalformed");
        std::fs::write(estate_encryption::install_key_path(&dir), [1u8, 2, 3]).expect("plant");
        assert!(matches!(
            estate_encryption::load_or_create_install_key(&dir),
            Err(estate_encryption::MigrationError::InstallKeyMalformed { .. })
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Created owner-only, so a key sitting in a shared temp directory is not
    /// readable by other users on the machine.
    #[test]
    fn created_install_key_is_owner_only() {
        let dir = scratch_directory("keycreate");
        let key = estate_encryption::load_or_create_install_key(&dir).expect("create");
        assert_eq!(key.len(), estate_encryption::INSTALL_KEY_BYTE_COUNT);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(estate_encryption::install_key_path(&dir))
                .expect("stat")
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }

        // A second call returns the SAME key rather than minting a new one.
        assert_eq!(
            estate_encryption::load_or_create_install_key(&dir).expect("reload"),
            key
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
