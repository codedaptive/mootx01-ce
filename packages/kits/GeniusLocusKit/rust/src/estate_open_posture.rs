// estate_open_posture.rs — the at-rest posture of an estate about to be
// opened, decided once beside the catalog.
//
// Twin of `Sources/GeniusLocusKit/EstateOpenPosture.swift`. The Swift port's
// key custody is the Keychain; this port's is the key file `db.key` beside
// the database (`persistence_kit::INSTALL_KEY_FILE`), which PersistenceKit's
// SQLite backend adopts at open when it is present. So the decision here is
// whether that file may exist, must exist, or must be minted:
//
// - A transient record (`--db <dir>/<name>`) is plaintext: no key is minted.
//   A ciphertext file with no key beside it is refused rather than guessed
//   at; one with its key beside it opens (the harness converts and serves
//   scratch estates this way).
// - A registered record whose manifest declares plaintext is created and
//   kept plaintext: the choice made at install or `db create` is honoured
//   rather than encrypting behind the user's back; `mootx01 upgrade` is the
//   only way to change it.
// - Any other registered record is created encrypted: the key is minted on
//   first open, the EXISTING key only is used for a ciphertext file, and a
//   missing key fails closed. Minting a key for a file encrypted under
//   another would hand SQLCipher a wrong key and the open would fail looking
//   like corruption.
//
// Never prompts and never migrates: serve runs as a service with no TTY.

use std::fmt;
use std::path::{Path, PathBuf};

use persistence_kit::estate_migration::{detect_estate_file_state, EstateFileState};
use persistence_kit::{ensure_install_key, INSTALL_KEY_FILE};

use crate::estate_catalog::{EstateBackend, EstateCatalog, EstateManifestEncryption, EstateRecord, EstateRecordKind};

/// Which branch the decision took, so a caller can log it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstateOpenPostureKind {
    /// No file yet; the key was minted and the estate will be created encrypted.
    NewEncrypted,
    /// No file yet; the estate will be created plaintext because it is
    /// transient or its manifest declares plaintext.
    NewPlaintextDeclared,
    /// The file is encrypted and its key is beside it.
    ExistingEncrypted,
    /// The file is plaintext and stays plaintext.
    ExistingPlaintext,
}

/// The decision: the posture taken and whether the open is plaintext.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EstateOpenPosture {
    pub kind: EstateOpenPostureKind,
}

impl EstateOpenPosture {
    /// Whether the estate opens without a key (the manifest's `encryption`
    /// value the refresh records).
    pub fn is_plaintext(&self) -> bool {
        matches!(self.kind, EstateOpenPostureKind::NewPlaintextDeclared | EstateOpenPostureKind::ExistingPlaintext)
    }

    /// The manifest word for this posture.
    pub fn manifest_encryption(&self) -> EstateManifestEncryption {
        if self.is_plaintext() { EstateManifestEncryption::Plaintext } else { EstateManifestEncryption::Encrypted }
    }
}

/// Why no posture could be decided. Every case is fail-closed: the caller
/// aborts and never opens plaintext by mistake.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EstateOpenPostureError {
    /// The database is encrypted but its key file is not beside it.
    EncryptedEstateKeyMissing { database: PathBuf, key: PathBuf, detail: String },
    /// The key file could not be created or read.
    KeyFileUnavailable { key: PathBuf, detail: String },
    /// The record's backend keeps no database file (PostgreSQL); there is no
    /// file posture to resolve.
    BackendHasNoDatabaseFile { name: String, backend: String },
}

impl fmt::Display for EstateOpenPostureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EncryptedEstateKeyMissing { database, key, detail } => write!(
                f,
                "the estate at {} is encrypted but its key file ({}) is missing ({detail}). \
                 Refusing to continue: opening it without the correct key would fail, and \
                 minting a new key would not decrypt it. If the estate was moved, move its \
                 {INSTALL_KEY_FILE} with it.",
                database.display(), key.display()
            ),
            Self::KeyFileUnavailable { key, detail } =>
                write!(f, "cannot prepare the estate encryption key at {}: {detail}", key.display()),
            Self::BackendHasNoDatabaseFile { name, backend } =>
                write!(f, "estate '{name}' runs on {backend}, which keeps no database file; nothing to resolve"),
        }
    }
}

impl std::error::Error for EstateOpenPostureError {}

impl EstateOpenPosture {
    /// Resolve the posture for a catalog record. The record's kind decides
    /// whether a key may be minted at all, and its manifest, when present,
    /// carries the plaintext declaration made at create.
    pub fn resolve(record: &EstateRecord) -> Result<Self, EstateOpenPostureError> {
        if let EstateBackend::Postgresql { .. } = record.backend {
            return Err(EstateOpenPostureError::BackendHasNoDatabaseFile {
                name: record.name.clone(),
                backend: record.backend.kind_name().to_string(),
            });
        }
        let declares_plaintext = EstateCatalog::read_manifest(record)
            .map(|m| m.encryption == EstateManifestEncryption::Plaintext)
            .unwrap_or(false);
        Self::resolve_file(&record.database_path(), record.kind == EstateRecordKind::Registered, declares_plaintext)
    }

    /// Resolve the posture for a database file. `registered` says whether this
    /// machine owns the estate and so may mint a key for it.
    pub fn resolve_file(database: &Path, registered: bool, declares_plaintext: bool) -> Result<Self, EstateOpenPostureError> {
        let directory = database.parent().unwrap_or_else(|| Path::new(""));
        let key = directory.join(INSTALL_KEY_FILE);
        let kind = match detect_estate_file_state(database) {
            EstateFileState::Plaintext => EstateOpenPostureKind::ExistingPlaintext,
            EstateFileState::Ciphertext => {
                if key.is_file() {
                    EstateOpenPostureKind::ExistingEncrypted
                } else {
                    let detail = if registered {
                        "no key file beside the database".to_string()
                    } else {
                        "transient estates carry no key; only a registered estate may be encrypted".to_string()
                    };
                    return Err(EstateOpenPostureError::EncryptedEstateKeyMissing {
                        database: database.to_path_buf(), key, detail,
                    });
                }
            }
            EstateFileState::Absent => {
                if !registered || declares_plaintext {
                    EstateOpenPostureKind::NewPlaintextDeclared
                } else {
                    // A key already beside an absent database is adopted as is;
                    // otherwise it is minted here. The SQLite backend applies it
                    // to the file it creates.
                    std::fs::create_dir_all(directory).map_err(|e| EstateOpenPostureError::KeyFileUnavailable {
                        key: key.clone(), detail: e.to_string(),
                    })?;
                    ensure_install_key(directory).map_err(|e| EstateOpenPostureError::KeyFileUnavailable {
                        key: key.clone(), detail: format!("{e:?}"),
                    })?;
                    EstateOpenPostureKind::NewEncrypted
                }
            }
        };
        Ok(EstateOpenPosture { kind })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("estate-open-posture-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_new_registered_estate_mints_its_key_and_is_encrypted() {
        let dir = scratch("registered");
        let db = dir.join("estate.sqlite");
        let posture = EstateOpenPosture::resolve_file(&db, true, false).unwrap();
        assert_eq!(posture.kind, EstateOpenPostureKind::NewEncrypted);
        assert!(!posture.is_plaintext());
        assert!(dir.join(INSTALL_KEY_FILE).is_file(), "the key is minted beside the database");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_transient_or_declared_plaintext_estate_mints_nothing() {
        let dir = scratch("plaintext");
        let db = dir.join("estate.sqlite");
        let transient = EstateOpenPosture::resolve_file(&db, false, false).unwrap();
        assert_eq!(transient.kind, EstateOpenPostureKind::NewPlaintextDeclared);
        let declared = EstateOpenPosture::resolve_file(&db, true, true).unwrap();
        assert_eq!(declared.kind, EstateOpenPostureKind::NewPlaintextDeclared);
        assert!(declared.is_plaintext());
        assert_eq!(declared.manifest_encryption(), EstateManifestEncryption::Plaintext);
        assert!(!dir.join(INSTALL_KEY_FILE).exists(), "no key for a plaintext estate");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn an_existing_plaintext_file_stays_plaintext_and_ciphertext_needs_its_key() {
        let dir = scratch("existing");
        let db = dir.join("estate.sqlite");
        std::fs::write(&db, b"SQLite format 3\0 and a body").unwrap();
        assert_eq!(EstateOpenPosture::resolve_file(&db, true, false).unwrap().kind, EstateOpenPostureKind::ExistingPlaintext);
        // Ciphertext: anything that is not the plaintext magic.
        std::fs::write(&db, [0x9au8; 64]).unwrap();
        let refused = EstateOpenPosture::resolve_file(&db, true, false);
        assert!(matches!(refused, Err(EstateOpenPostureError::EncryptedEstateKeyMissing { .. })));
        let refused_transient = EstateOpenPosture::resolve_file(&db, false, false);
        assert!(matches!(refused_transient, Err(EstateOpenPostureError::EncryptedEstateKeyMissing { .. })));
        std::fs::write(dir.join(INSTALL_KEY_FILE), [0x11u8; 32]).unwrap();
        assert_eq!(EstateOpenPosture::resolve_file(&db, true, false).unwrap().kind, EstateOpenPostureKind::ExistingEncrypted);
        assert_eq!(EstateOpenPosture::resolve_file(&db, false, false).unwrap().kind, EstateOpenPostureKind::ExistingEncrypted);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_postgresql_record_has_no_file_posture() {
        let record = EstateRecord::with("pg", "/tmp/pg", EstateRecordKind::Registered,
                                        EstateBackend::Postgresql { connection_string: "postgresql://h/d".into() });
        assert!(matches!(EstateOpenPosture::resolve(&record), Err(EstateOpenPostureError::BackendHasNoDatabaseFile { .. })));
    }
}
