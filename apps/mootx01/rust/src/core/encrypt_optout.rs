//! core/encrypt_optout.rs — the `no-encrypt` opt-out marker and the shared
//! at-rest open posture (Rust twin of Swift `EstateKeyProvider` +
//! `EstateOpenPosture` in MootInstallerCore).
//!
//! THE RULE — DO NOT FORCE THE FLIP (same contract as the Swift twin):
//!
//!   file absent (first run)  → mint the install key (db.key), estate is
//!                              created encrypted — UNLESS an opt-out marker
//!                              is present, in which case no key is minted and
//!                              the estate is created plaintext
//!   file present, ciphertext → the EXISTING key only; FAIL CLOSED if db.key
//!                              is missing (minting here would hand SQLCipher
//!                              a brand-new wrong key for a file already
//!                              encrypted under a different one)
//!   file present, plaintext  → untouched. Never mint beside an existing
//!                              plaintext estate: PersistenceKit's
//!                              `resolve_install_encryption` fails closed on
//!                              the plaintext-file-plus-key mismatch, so a
//!                              mint here would brick the next open. Migration
//!                              is `mootx01 upgrade`, never implicit.
//!
//! WHY A MARKER AND NOT A FLAG ON THE OPENING COMMAND
//! Neither `install` nor `db create` creates an estate FILE — `db create`
//! makes the estate DIRECTORY and the substrate writes the SQLite file lazily
//! on first serve. So the surface that offers the opt-out is never the surface
//! that creates the thing being opted out of, and the choice has to survive
//! the gap between them. A marker file in the estate's own directory does
//! that, is visible to the user, and travels with the estate.
//!
//! The marker is consulted ONLY on the absent-file branch. An estate that
//! already exists is never re-postured by it: an existing plaintext estate
//! stays plaintext because it is plaintext, and an existing encrypted estate
//! is never downgraded by dropping a file next to it.

use std::io;
use std::path::{Path, PathBuf};

use aria_mcp::estate_migration::{detect_estate_file_state, EstateFileState};

/// Filename of the per-estate encryption opt-out marker, written beside the
/// estate file by `install --no-encrypt` and `db create --no-encrypt`.
/// Same name as Swift `EstateKeyProvider.encryptionOptOutMarkerName`.
pub const ENCRYPTION_OPT_OUT_MARKER_NAME: &str = "no-encrypt";

/// The posture chosen for a given estate file, so a caller can log WHICH
/// branch it took rather than just the outcome. Mirrors Swift
/// `EstateKeyProvider.OpenPosture` case for case.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenPosture {
    /// No file yet: the install key was minted and the estate will be created
    /// encrypted.
    NewEncrypted,
    /// No file yet, and the user explicitly opted out with `--no-encrypt`
    /// (or a data-dir-root marker — see `has_opt_out`). No key is minted; the
    /// estate will be created as plaintext. Reversible with `mootx01 upgrade`.
    NewPlaintextByOptOut,
    /// The file is already encrypted and its existing db.key is present.
    ExistingEncrypted,
    /// The file is plaintext and stays plaintext. Migration is
    /// `mootx01 upgrade`, never implicit.
    ExistingPlaintext,
}

/// Path of the opt-out marker beside the estate file at `estate_path`.
pub fn marker_path(estate_path: &Path) -> PathBuf {
    estate_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(ENCRYPTION_OPT_OUT_MARKER_NAME)
}

/// True when the estate at `estate_path` carries the opt-out, in EITHER of
/// two places:
///
/// 1. Beside the estate file (`<data>/databases/<name>/no-encrypt`) — the
///    per-estate marker written by `install --no-encrypt` and
///    `db create --no-encrypt`, same placement as the Swift twin.
/// 2. At the DATA-DIR ROOT (`<data>/no-encrypt`) — a blanket opt-out covering
///    every estate this serve creates under that data dir. The Rust estate
///    lives at `<data>/databases/<name>/estate.sqlite`, two levels below the
///    data dir, so a harness that provisions a scratch data dir can drop ONE
///    marker at the root instead of pre-creating each estate directory.
pub fn has_opt_out(estate_path: &Path, data_dir: &Path) -> bool {
    marker_path(estate_path).exists() || data_dir.join(ENCRYPTION_OPT_OUT_MARKER_NAME).exists()
}

/// Record the opt-out for the estate that will be created at `estate_path`.
/// Idempotent. Creates the estate directory if needed, because the marker has
/// to exist before the estate file does.
pub fn write_opt_out(estate_path: &Path) -> io::Result<()> {
    let marker = marker_path(estate_path);
    if let Some(dir) = marker.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // Idempotent: re-recording the same choice must not rewrite the marker.
    if marker.exists() {
        return Ok(());
    }
    // User-facing file: it must explain itself, including how to reverse the
    // choice (`mootx01 upgrade` is the only migration vehicle).
    std::fs::write(
        &marker,
        "This estate was created with --no-encrypt and is NOT encrypted at rest.\n\
         Run `mootx01 upgrade` to encrypt it. Deleting this file does not encrypt\n\
         an estate that already exists; it only affects an estate that has not\n\
         been created yet.\n",
    )
}

/// Remove a recorded opt-out beside the estate at `estate_path`, if present.
/// Returns true when a marker existed and was removed.
///
/// The marker records a choice about an estate that does not exist yet. When
/// a NEW estate is requested with encryption (the default), a marker left
/// over from an earlier estate at the same path must not survive to downgrade
/// the estate the current invocation promised would be encrypted (the
/// stale-marker downgrade the Swift twin sweeps for the same reason).
///
/// Deliberately estate-local: a DATA-DIR-ROOT marker is a standing blanket
/// choice about the whole data dir (a harness posture), not a stale artifact
/// of one estate, and is never swept here.
pub fn remove_opt_out(estate_path: &Path) -> io::Result<bool> {
    let marker = marker_path(estate_path);
    if !marker.exists() {
        return Ok(false);
    }
    std::fs::remove_file(&marker)?;
    Ok(true)
}

/// Resolve the at-rest posture for the estate at `estate_path` and settle key
/// custody accordingly. This is THE shared decision the serve path takes
/// before exporting `ARIA_MCP_SQLITE_PATH` — the Rust twin of Swift
/// `EstateKeyProvider.resolveOpenPosture`. It never prompts and never
/// migrates.
///
/// Rust key custody is the `db.key` file beside the estate
/// (PersistenceKit `resolve_install_encryption` reads it at open), so
/// "provision a key" here means `ensure_install_key` on the estate directory,
/// and "skip the key" means NOT minting — the runtime then opens/creates the
/// estate plaintext because no db.key is present.
///
/// A db.key that ALREADY exists beside an absent estate wins over the marker:
/// the runtime keys any estate it creates under an existing key, and the
/// marker's only lever on this side of the seam is preventing the mint. That
/// is the same "never re-posture existing custody" stance as the Swift twin.
pub fn prepare_estate_key(estate_path: &Path, data_dir: &Path) -> Result<OpenPosture, String> {
    let dir = match estate_path.parent() {
        Some(d) if !d.as_os_str().is_empty() => d,
        _ => return Err(format!("estate path {} has no parent directory", estate_path.display())),
    };
    match detect_estate_file_state(estate_path) {
        EstateFileState::Absent => {
            // Explicit opt-out recorded at install or `db create` time (or a
            // data-dir-root marker). The user chose plaintext; honor it rather
            // than encrypting behind their back. Reversible via `mootx01 upgrade`.
            if has_opt_out(estate_path, data_dir) {
                return Ok(OpenPosture::NewPlaintextByOptOut);
            }
            // First run. Mint (creating if needed) and the estate is created
            // encrypted — the default posture.
            aria_mcp::ensure_install_key(dir).map_err(|e| {
                format!("cannot prepare estate encryption key in {}: {e}", dir.display())
            })?;
            Ok(OpenPosture::NewEncrypted)
        }
        EstateFileState::Ciphertext => {
            // Already encrypted. The EXISTING key only — minting here would
            // hand SQLCipher a fresh wrong key for a file encrypted under a
            // different one, and the open would fail looking like corruption.
            // Fail closed when the key is missing: the caller must abort, NOT
            // create a new estate and NOT retry as plaintext.
            let key = dir.join(aria_mcp::INSTALL_KEY_FILE);
            if key.exists() {
                Ok(OpenPosture::ExistingEncrypted)
            } else {
                Err(format!(
                    "the estate at {} is encrypted but its key file ({}) is missing. \
                     Refusing to continue: opening it without the correct key would fail, \
                     and minting a new key would not decrypt it. If the estate was moved, \
                     move its db.key with it.",
                    estate_path.display(),
                    key.display()
                ))
            }
        }
        EstateFileState::Plaintext => {
            // Unchanged behavior: an existing plaintext estate keeps opening.
            // No mint — a db.key beside a plaintext estate is the mismatched
            // state PersistenceKit fails closed on. `mootx01 upgrade` is the
            // only migration vehicle.
            Ok(OpenPosture::ExistingPlaintext)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Rust twin of Swift `EstateEncryptionOptOutTests` — the applicable
    /// cases (Keychain-custody-only cases have no Rust analogue; key custody
    /// here is the db.key file).

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "mootx01-optout-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn estate_in(data: &Path) -> PathBuf {
        data.join("databases").join("default").join("estate.sqlite")
    }

    /// "Default creation posture is encrypted when no opt-out is recorded":
    /// no marker → NewEncrypted, and the db.key is minted.
    #[test]
    fn default_creation_is_encrypted_and_mints_a_key() {
        let data = tmp("default-enc");
        let estate = estate_in(&data);
        std::fs::create_dir_all(estate.parent().unwrap()).unwrap();
        assert!(!has_opt_out(&estate, &data), "test premise: no opt-out recorded");

        let posture = prepare_estate_key(&estate, &data).unwrap();
        assert_eq!(posture, OpenPosture::NewEncrypted);
        assert!(
            estate.parent().unwrap().join(aria_mcp::INSTALL_KEY_FILE).exists(),
            "absent an explicit opt-out, a new estate must get an install key"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// "A recorded opt-out yields a plaintext creation posture": marker + no
    /// estate → NewPlaintextByOptOut and NO db.key.
    #[test]
    fn opt_out_yields_plaintext_creation_and_no_key() {
        let data = tmp("optout-plain");
        let estate = estate_in(&data);
        write_opt_out(&estate).unwrap();
        assert!(has_opt_out(&estate, &data));

        let posture = prepare_estate_key(&estate, &data).unwrap();
        assert_eq!(
            posture,
            OpenPosture::NewPlaintextByOptOut,
            "an explicit --no-encrypt must be honored, not overridden by the default"
        );
        assert!(
            !estate.parent().unwrap().join(aria_mcp::INSTALL_KEY_FILE).exists(),
            "--no-encrypt must not mint a key"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// A marker at the DATA-DIR ROOT covers an estate two levels below it —
    /// the serve/harness blanket form of the opt-out.
    #[test]
    fn data_dir_root_marker_covers_estates_below_it() {
        let data = tmp("root-marker");
        std::fs::write(data.join(ENCRYPTION_OPT_OUT_MARKER_NAME), b"blanket opt-out\n").unwrap();
        let estate = estate_in(&data);
        std::fs::create_dir_all(estate.parent().unwrap()).unwrap();

        assert!(has_opt_out(&estate, &data));
        let posture = prepare_estate_key(&estate, &data).unwrap();
        assert_eq!(posture, OpenPosture::NewPlaintextByOptOut);
        assert!(!estate.parent().unwrap().join(aria_mcp::INSTALL_KEY_FILE).exists());
        let _ = std::fs::remove_dir_all(&data);
    }

    /// "writeEncryptionOptOut is idempotent and creates the directory", and
    /// the marker must tell the reader how to encrypt the estate later.
    #[test]
    fn write_opt_out_is_idempotent_creates_dir_and_explains_itself() {
        let data = tmp("idempotent");
        // Parent does NOT exist yet: the marker has to be writable before the
        // estate directory is populated.
        let estate = data.join("databases").join("named").join("estate.sqlite");

        write_opt_out(&estate).unwrap();
        let first = std::fs::read(marker_path(&estate)).unwrap();
        write_opt_out(&estate).unwrap();
        let second = std::fs::read(marker_path(&estate)).unwrap();
        assert_eq!(first, second, "re-recording the same choice must not rewrite the marker");

        let text = String::from_utf8(first).unwrap();
        assert!(
            text.contains("mootx01 upgrade"),
            "the marker must tell the reader how to encrypt the estate later"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// "The opt-out marker never re-postures an estate that already exists":
    /// marker + existing encrypted estate (with its key) → stays encrypted.
    #[test]
    fn marker_does_not_downgrade_an_existing_encrypted_estate() {
        let data = tmp("no-downgrade");
        let estate = estate_in(&data);
        std::fs::create_dir_all(estate.parent().unwrap()).unwrap();
        // Ciphertext: any 16+ bytes that are not the plaintext SQLite magic.
        std::fs::write(&estate, [0xAAu8; 64]).unwrap();
        std::fs::write(estate.parent().unwrap().join(aria_mcp::INSTALL_KEY_FILE), [0x11u8; 32])
            .unwrap();

        write_opt_out(&estate).unwrap();
        let posture = prepare_estate_key(&estate, &data).unwrap();
        assert_eq!(
            posture,
            OpenPosture::ExistingEncrypted,
            "an existing encrypted estate must stay encrypted regardless of the marker"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// The ciphertext branch fails CLOSED when db.key is missing — it must
    /// not mint a fresh (wrong) key.
    #[test]
    fn ciphertext_without_key_fails_closed_and_mints_nothing() {
        let data = tmp("fail-closed");
        let estate = estate_in(&data);
        std::fs::create_dir_all(estate.parent().unwrap()).unwrap();
        std::fs::write(&estate, [0xAAu8; 64]).unwrap();

        let err = prepare_estate_key(&estate, &data).unwrap_err();
        assert!(err.contains("encrypted"), "error must name the real state: {err}");
        assert!(
            !estate.parent().unwrap().join(aria_mcp::INSTALL_KEY_FILE).exists(),
            "fail-closed means no key is minted"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// "An existing plaintext estate is unaffected by the absence of a
    /// marker": stays plaintext, and no key is minted beside it.
    #[test]
    fn existing_plaintext_estate_needs_no_marker_and_gets_no_key() {
        let data = tmp("plain-stays");
        let estate = estate_in(&data);
        std::fs::create_dir_all(estate.parent().unwrap()).unwrap();
        // A minimal plaintext SQLite header: the 16-byte magic + padding.
        let mut bytes = b"SQLite format 3\0".to_vec();
        bytes.extend_from_slice(&[0u8; 48]);
        std::fs::write(&estate, bytes).unwrap();
        assert!(!has_opt_out(&estate, &data), "test premise: no marker");

        let posture = prepare_estate_key(&estate, &data).unwrap();
        assert_eq!(
            posture,
            OpenPosture::ExistingPlaintext,
            "no marker must not mean 'require a key' for an existing plaintext estate"
        );
        assert!(
            !estate.parent().unwrap().join(aria_mcp::INSTALL_KEY_FILE).exists(),
            "minting beside a plaintext estate would fail the next open closed"
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    /// Stale-marker sweep: remove_opt_out reports whether a marker existed,
    /// and never touches a data-dir-root marker.
    #[test]
    fn remove_opt_out_sweeps_estate_marker_only() {
        let data = tmp("sweep");
        let estate = estate_in(&data);
        write_opt_out(&estate).unwrap();
        std::fs::write(data.join(ENCRYPTION_OPT_OUT_MARKER_NAME), b"blanket\n").unwrap();

        assert!(remove_opt_out(&estate).unwrap(), "a present marker is removed and reported");
        assert!(!marker_path(&estate).exists());
        assert!(
            data.join(ENCRYPTION_OPT_OUT_MARKER_NAME).exists(),
            "the data-dir-root marker is a standing choice, never swept per-estate"
        );
        assert!(!remove_opt_out(&estate).unwrap(), "absent marker reports false");
        let _ = std::fs::remove_dir_all(&data);
    }
}
