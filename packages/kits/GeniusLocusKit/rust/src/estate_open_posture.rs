// estate_open_posture.rs — the at-rest posture of an estate about to be
// opened, decided once beside the catalog.
//
// Twin of `Sources/GeniusLocusKit/EstateOpenPosture.swift`. The Swift port's
// key custody is the Keychain; this port's is the key file `db.key` beside
// the database (`persistence_kit::INSTALL_KEY_FILE`), which PersistenceKit's
// SQLite backend adopts at open when it is present. So the decision here is
// whether that file may exist, must exist, or must be minted:
//
// - A transient record (`--db <dir>/<name>`) is plaintext: no key is minted
//   and no key is used. A ciphertext file is refused whether or not a key
//   file sits beside it: a transient estate has no custody to use one with,
//   the same rule the Swift port applies to the Keychain (spec
//   § ESTATE_OPEN_POSTURE, "transient: plaintext only").
// - A registered record whose manifest declares plaintext is created and
//   kept plaintext: the choice made at install or `db create` is honoured
//   rather than encrypting behind the user's back; `mootx01 upgrade` is the
//   only way to change it.
// - Any other registered record is created encrypted: the key is minted on
//   first open, the EXISTING key only is used for a ciphertext file, and a
//   missing key fails closed. Minting a key for a file encrypted under
//   another would hand SQLCipher a wrong key and the open would fail looking
//   like corruption.
// - The manifest is a gate, not a hint: `resolve` refuses a record whose
//   `estate.json` the catalog refuses (unknown key, foreign name, symbolic
//   link among the estate files) with `ManifestRefused` instead of reading
//   it as "declares nothing". An absent manifest declares nothing.
//
// HARNESS BUILDS (`--features harness-keyfile`, twin of the Swift
// `MOOTX01_HARNESS_KEYFILE` compile condition) consult the key file beside
// the database before the record's kind, for every record: the benchmark
// harness serves scratch estates it converted moments earlier. Off in every
// shipping build; the feature is declared in this crate's Cargo.toml and no
// product crate enables it.
//
// The decision table is pinned by `Tests/Conformance/estate_open_posture_fixture.json`,
// which the Swift tests read too, so the two ports cannot drift row by row.
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
    /// The record's `estate.json`, or the files beside it, failed the
    /// catalog's manifest gate. Carries the catalog's refusal; the open does
    /// not proceed on a guessed declaration.
    ManifestRefused(crate::estate_catalog::EstateCatalogError),
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
            Self::ManifestRefused(underlying) =>
                write!(f, "estate manifest refused before the open posture could be decided: {underlying}"),
        }
    }
}

impl std::error::Error for EstateOpenPostureError {}

impl EstateOpenPosture {
    /// Resolve the posture for a catalog record. The record's kind decides
    /// whether a key may be minted at all, and its manifest, when present,
    /// carries the plaintext declaration made at create.
    ///
    /// The manifest read is the catalog's gate: a present manifest the
    /// catalog refuses, or a symbolic link among the estate files, fails with
    /// `ManifestRefused` instead of resolving as "declares nothing". An absent
    /// manifest declares nothing (the encrypted default) and the files are
    /// still required to be regular files inside the directory.
    pub fn resolve(record: &EstateRecord) -> Result<Self, EstateOpenPostureError> {
        if let EstateBackend::Postgresql { .. } = record.backend {
            return Err(EstateOpenPostureError::BackendHasNoDatabaseFile {
                name: record.name.clone(),
                backend: record.backend.kind_name().to_string(),
            });
        }
        let declares_plaintext = Self::manifest_declares_plaintext(record)?;
        Self::resolve_file(&record.database_path(), record.kind == EstateRecordKind::Registered, declares_plaintext)
    }

    /// The record's plaintext declaration, or `ManifestRefused` when the
    /// catalog refuses the manifest or the files beside it. Twin of the Swift
    /// `manifestDeclaresPlaintext`; both ports refuse the same manifests.
    pub fn manifest_declares_plaintext(record: &EstateRecord) -> Result<bool, EstateOpenPostureError> {
        let outcome = if record.manifest_path().exists() {
            EstateCatalog::read_manifest(record).map(|m| m.encryption == EstateManifestEncryption::Plaintext)
        } else {
            EstateCatalog::verify_files_stay_inside(record).map(|()| false)
        };
        outcome.map_err(EstateOpenPostureError::ManifestRefused)
    }

    /// Resolve the posture for a database file. `registered` says whether this
    /// machine owns the estate and so may mint or use a key for it.
    pub fn resolve_file(database: &Path, registered: bool, declares_plaintext: bool) -> Result<Self, EstateOpenPostureError> {
        let directory = database.parent().unwrap_or_else(|| Path::new(""));
        let key = directory.join(INSTALL_KEY_FILE);
        #[cfg(feature = "harness-keyfile")]
        {
            // HARNESS BUILDS ONLY. A key file beside the database is custody for
            // any record kind, consulted before the transient rule below, so
            // the harness can serve a scratch estate it converted. The file's
            // state and the manifest's declaration still decide as below.
            // Swift twin: the `MOOTX01_HARNESS_KEYFILE` branch of `resolve`.
            if key.is_file() {
                let kind = match detect_estate_file_state(database) {
                    EstateFileState::Plaintext => EstateOpenPostureKind::ExistingPlaintext,
                    EstateFileState::Ciphertext => EstateOpenPostureKind::ExistingEncrypted,
                    EstateFileState::Absent if declares_plaintext => EstateOpenPostureKind::NewPlaintextDeclared,
                    EstateFileState::Absent => EstateOpenPostureKind::NewEncrypted,
                };
                return Ok(EstateOpenPosture { kind });
            }
        }
        let kind = match detect_estate_file_state(database) {
            EstateFileState::Plaintext => EstateOpenPostureKind::ExistingPlaintext,
            EstateFileState::Ciphertext => {
                // The EXISTING key only, and only for a registered record: a
                // transient estate has no custody, so a key file beside a
                // transient ciphertext database is not consulted (Swift:
                // `!registered` returns before any Keychain path).
                if registered && key.is_file() {
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
    use crate::estate_catalog::EstateCatalogError;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("estate-open-posture-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The name of an outcome as the shared fixture spells it.
    fn outcome_name(result: &Result<EstateOpenPosture, EstateOpenPostureError>) -> &'static str {
        match result {
            Ok(p) => match p.kind {
                EstateOpenPostureKind::NewEncrypted => "newEncrypted",
                EstateOpenPostureKind::NewPlaintextDeclared => "newPlaintextDeclared",
                EstateOpenPostureKind::ExistingEncrypted => "existingEncrypted",
                EstateOpenPostureKind::ExistingPlaintext => "existingPlaintext",
            },
            Err(EstateOpenPostureError::EncryptedEstateKeyMissing { .. }) => "encryptedEstateKeyMissing",
            Err(EstateOpenPostureError::KeyFileUnavailable { .. }) => "keyFileUnavailable",
            Err(EstateOpenPostureError::BackendHasNoDatabaseFile { .. }) => "backendHasNoDatabaseFile",
            Err(EstateOpenPostureError::ManifestRefused(_)) => "manifestRefused",
        }
    }

    /// Every row of the shared decision table, driven through `resolve_file`.
    /// The Swift twin (`EstateOpenPostureTests.postureTableMatchesTheSharedFixture`)
    /// reads the same file, so a row that changes in one port fails in the other.
    #[test]
    fn posture_table_matches_the_shared_fixture() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../Tests/Conformance/estate_open_posture_fixture.json");
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
        let fixture: serde_json::Value = serde_json::from_str(&text).expect("fixture is JSON");
        let rows = fixture["rows"].as_array().expect("rows");
        assert!(rows.len() >= 12, "the table has at least the twelve shipping rows");
        let harness_build = cfg!(feature = "harness-keyfile");
        let mut exercised = 0;
        for row in rows {
            let id = row["id"].as_str().unwrap();
            if row["harness"].as_bool().unwrap() != harness_build {
                // A harness row runs only in a harness build; a shipping row
                // only in a shipping build (a present key file would take the
                // harness branch first).
                continue;
            }
            let dir = scratch(id);
            let db = dir.join("estate.sqlite");
            match row["file"].as_str().unwrap() {
                "absent" => {}
                "plaintext" => std::fs::write(&db, b"SQLite format 3\0 and a body").unwrap(),
                "ciphertext" => std::fs::write(&db, [0x9au8; 64]).unwrap(),
                other => panic!("{id}: unknown file state {other}"),
            }
            if row["key"].as_bool().unwrap() {
                std::fs::write(dir.join(INSTALL_KEY_FILE), [0x11u8; 32]).unwrap();
            }
            let result = EstateOpenPosture::resolve_file(
                &db, row["registered"].as_bool().unwrap(), row["declaresPlaintext"].as_bool().unwrap());
            assert_eq!(outcome_name(&result), row["expected"].as_str().unwrap(), "row {id}");
            exercised += 1;
            let _ = std::fs::remove_dir_all(dir);
        }
        assert!(exercised >= 6, "the build exercised its half of the table ({exercised} rows)");
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

    /// The transient-ciphertext row with a key file beside the database: the
    /// row the ports once decided differently (Swift refused, Rust opened).
    /// Both refuse in a shipping build; the harness build takes the key file.
    #[test]
    fn a_transient_ciphertext_estate_is_refused_even_with_a_key_file() {
        let dir = scratch("transient-ciphertext");
        let db = dir.join("estate.sqlite");
        std::fs::write(&db, [0x9au8; 64]).unwrap();
        std::fs::write(dir.join(INSTALL_KEY_FILE), [0x11u8; 32]).unwrap();
        let result = EstateOpenPosture::resolve_file(&db, false, false);
        if cfg!(feature = "harness-keyfile") {
            assert_eq!(result.unwrap().kind, EstateOpenPostureKind::ExistingEncrypted);
        } else {
            assert!(matches!(result, Err(EstateOpenPostureError::EncryptedEstateKeyMissing { .. })),
                    "a transient estate has no custody; the key file beside it is not consulted");
            // The registered record beside the same bytes uses the key.
            assert_eq!(EstateOpenPosture::resolve_file(&db, true, false).unwrap().kind,
                       EstateOpenPostureKind::ExistingEncrypted);
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_postgresql_record_has_no_file_posture() {
        let record = EstateRecord::with("pg", "/tmp/pg", EstateRecordKind::Registered,
                                        EstateBackend::Postgresql { connection_string: "postgresql://h/d".into() });
        assert!(matches!(EstateOpenPosture::resolve(&record), Err(EstateOpenPostureError::BackendHasNoDatabaseFile { .. })));
    }

    /// The manifest gate: a refused manifest refuses the open with the
    /// catalog's error inside; an absent manifest is not a refusal; a
    /// symbolic link among the estate files is refused with or without one.
    #[test]
    fn a_refused_manifest_refuses_the_open_and_an_absent_one_does_not() {
        let dir = scratch("manifest-gate");
        let record = EstateRecord::with("scratch", dir.join("scratch"), EstateRecordKind::Transient, EstateBackend::Sqlite);
        std::fs::create_dir_all(&record.directory).unwrap();
        // Absent manifest, absent database: plaintext, nothing refused.
        assert_eq!(EstateOpenPosture::resolve(&record).unwrap().kind, EstateOpenPostureKind::NewPlaintextDeclared);
        // A manifest carrying a redirect key: refused, typed, with the catalog's detail.
        std::fs::write(record.manifest_path(),
            r#"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":8},"encryption":"plaintext","created":"2026-09-08T00:00:00Z","path":"/elsewhere"}"#).unwrap();
        match EstateOpenPosture::resolve(&record) {
            Err(EstateOpenPostureError::ManifestRefused(EstateCatalogError::UnreadableEstateManifest { detail, .. })) =>
                assert!(detail.contains("path"), "{detail}"),
            other => panic!("expected ManifestRefused, got {other:?}"),
        }
        // A manifest for another estate: refused too.
        std::fs::write(record.manifest_path(),
            r#"{"fileVersion":1,"name":"other","schemaVersion":1,"formatVersion":{"major":1,"minor":8},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"}"#).unwrap();
        assert!(matches!(EstateOpenPosture::resolve(&record), Err(EstateOpenPostureError::ManifestRefused(_))));
        // A correct manifest declaring plaintext: read.
        std::fs::write(record.manifest_path(),
            r#"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":8},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"}"#).unwrap();
        assert!(EstateOpenPosture::manifest_declares_plaintext(&record).unwrap());
        // No manifest but a symlinked database: refused by the same gate.
        std::fs::remove_file(record.manifest_path()).unwrap();
        let elsewhere = dir.join("elsewhere.sqlite");
        std::fs::write(&elsewhere, b"x").unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&elsewhere, record.database_path()).unwrap();
            assert!(matches!(EstateOpenPosture::resolve(&record), Err(EstateOpenPostureError::ManifestRefused(_))));
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}
