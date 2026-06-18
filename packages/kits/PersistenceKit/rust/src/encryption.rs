//! At-rest encryption types and the swappable AEAD seam (PAR-5-PK).
//!
//! This module mirrors Swift's `EncryptionMode.swift` and
//! `AeadProvider.swift` from the `PersistenceKitSQLite` target.
//!
//! # Design
//!
//! The `AeadProvider` trait is the FedRAMP swap point: a future
//! FIPS-validated hand-rolled AEAD drops in by implementing this trait,
//! with ZERO changes to `RowCrypto` or any storage call site.
//!
//! `AesGcmAeadProvider` is the default concrete provider, backed by
//! the `aes-gcm` RustCrypto crate (the first approved external crypto
//! crate; see `DECISION_RUST_AEAD_CRATE_2026-06-05.md` for the C-1
//! per-crate exception).
//!
//! # Ciphertext layout
//!
//! `[12-byte nonce][16-byte GCM tag][ciphertext]`
//!
//! This matches the Swift layout byte-for-byte. An alternate provider
//! MUST produce and consume the same layout so persisted rows are
//! cross-decryptable by the Swift side.
//!
//! # Nonce discipline
//!
//! `AesGcmAeadProvider::encrypt` generates a fresh random 96-bit nonce
//! per call (never reused under a given key — the fundamental GCM safety
//! requirement). The nonce is stored as the first 12 bytes of every
//! ciphertext envelope.
//!
//! # Key security
//!
//! Keys are never logged or stored beyond the scope of the encrypt/decrypt
//! call. The `EncryptionMode` / `EstateEncryptionConfig` types carry raw
//! `Vec<u8>` key bytes at the `pub(crate)` visibility level, not exported
//! in the public API.

use aes_gcm::{
    aead::{Aead, AeadCore, KeyInit, OsRng},
    Aes256Gcm, Key, Nonce,
};
use std::path::Path;

use crate::{StorageError, StorageResult};

/// The whole-file key file name. A resident service writes this beside the
/// estate `.sqlite` files (`<estates-dir>/db.key`); its presence marks every
/// estate in that directory as whole-file encrypted, and both resident services
/// resolve the identical path so they share one key.
pub const INSTALL_KEY_FILE: &str = "db.key";

/// The whole-file key length in bytes (AES-256).
const INSTALL_KEY_LEN: usize = 32;

// ─────────────────────────────────────────────────────────────────────────────
// EncryptionMode — mirrors Swift's EncryptionMode enum
// ─────────────────────────────────────────────────────────────────────────────

/// The estate's at-rest encryption mode. One AEAD mechanism, three
/// key-distribution choices — not three systems.
///
/// Mirrors Swift `EncryptionMode` (PersistenceKit core, `EncryptionMode.swift`).
///
/// Mode 4 (database + threshold) is deliberately absent: adding a fourth
/// case is a deliberate, reviewed act, not a silent extension.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EncryptionMode {
    /// Mode 1 — plaintext at rest; encryption happens only at the share
    /// fence. The content column is stored verbatim; crypto is a no-op.
    Plaintext,
    /// Mode 2 — per-row content ciphertext under a per-row or per-estate
    /// key; the row carries the key identifier.
    RowEncryption,
    /// Mode 3 — whole-database at-rest encryption under a per-install key.
    /// The entire SQLite file (including page 1, the schema) is encrypted by
    /// SQLCipher at the connection layer via `PRAGMA key`; the per-row content
    /// seam is a no-op for this mode because the file itself — schema and
    /// content — is ciphertext on disk.
    FullDatabase,
}

// ─────────────────────────────────────────────────────────────────────────────
// EstateEncryptionConfig — mirrors Swift's EstateEncryptionConfig struct
// ─────────────────────────────────────────────────────────────────────────────

/// Per-estate encryption configuration. Carries the mode, the public key
/// identifier recorded on each encrypted row, and the raw data key bytes.
///
/// The key is `pub(crate)`: it must reach the SQLite backend but is never
/// part of the public API surface. `.plaintext()` mints neither key nor
/// identifier; the two encrypting modes mint a fresh 256-bit key and a
/// UUID identifier.
///
/// Debug is implemented manually to redact the `key` field — the raw key
/// bytes must never appear in logs or debug output.
///
/// Mirrors Swift `EstateEncryptionConfig` (`EncryptionMode.swift`).
#[derive(Clone)]
pub struct EstateEncryptionConfig {
    /// The at-rest encryption mode.
    pub mode: EncryptionMode,
    /// Stable identifier recorded in the row's keyID column and the key
    /// registry. `None` for `.Plaintext`.
    pub key_identifier: Option<String>,
    /// The AES-GCM-256 data key (32 raw bytes). `pub(crate)` and never part
    /// of the public API surface. `None` for `.Plaintext`.
    ///
    /// The Rust `sqlite.rs` backend reads this key in `encrypted_for_write`
    /// and `decrypted_for_read` to encrypt the `content` column at rest,
    /// mirroring Swift's `encryptedForWrite`/`decryptedForRead` seam on
    /// `SQLiteBackend`. The envelope layout `[nonce][tag][ciphertext]` is
    /// byte-identical between Swift and Rust so a cell encrypted by one
    /// side decrypts correctly on the other.
    ///
    /// Never log or expose this field outside the crate.
    pub(crate) key: Option<Vec<u8>>,
}

/// Manually implemented Debug that redacts the `key` field.
///
/// The raw key bytes must never appear in logs, debug output, or panic
/// messages. `key_identifier` is shown (it is public and non-secret — it
/// is the row's key ID column, written to disk). `key` is replaced by
/// `"<REDACTED>"` regardless of whether it is `Some` or `None`.
impl std::fmt::Debug for EstateEncryptionConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EstateEncryptionConfig")
            .field("mode", &self.mode)
            .field("key_identifier", &self.key_identifier)
            .field("key", &"<REDACTED>")
            .finish()
    }
}

impl EstateEncryptionConfig {
    /// Plaintext mode — no key minted. The default for all estates.
    pub fn plaintext() -> Self {
        EstateEncryptionConfig {
            mode: EncryptionMode::Plaintext,
            key_identifier: None,
            key: None,
        }
    }

    /// Row-encryption mode — generates a fresh full-entropy 256-bit key
    /// and a UUID key identifier (the FileVault / crypto-wallet model:
    /// the key is generated for the user, never chosen as a passphrase).
    pub fn row_encryption() -> Self {
        let key = Aes256Gcm::generate_key(OsRng);
        EstateEncryptionConfig {
            mode: EncryptionMode::RowEncryption,
            key_identifier: Some(uuid::Uuid::new_v4().to_string()),
            key: Some(key.to_vec()),
        }
    }

    /// Full-database mode — mints a fresh full-entropy 256-bit key used as the
    /// SQLCipher whole-file key (supplied via `PRAGMA key` at open). The key
    /// identifier records provenance; the per-row content seam is bypassed for
    /// this mode because the whole file, schema included, is encrypted.
    pub fn full_database() -> Self {
        let key = Aes256Gcm::generate_key(OsRng);
        EstateEncryptionConfig {
            mode: EncryptionMode::FullDatabase,
            key_identifier: Some(uuid::Uuid::new_v4().to_string()),
            key: Some(key.to_vec()),
        }
    }

    /// Full-database mode under a caller-supplied key — the per-install key
    /// loaded from the shared `db.key`, so every handle on the same estates
    /// directory (across both resident services) opens the file with the same
    /// SQLCipher key. The key identifier is a fixed, non-secret marker (the
    /// whole-file mode writes no per-row keyID, so it is provenance only).
    pub fn full_database_with_key(key: Vec<u8>) -> Self {
        EstateEncryptionConfig {
            mode: EncryptionMode::FullDatabase,
            key_identifier: Some("install-whole-file".to_string()),
            key: Some(key),
        }
    }

    /// True for Mode 1 (Plaintext) — no key, no crypto applied.
    pub(crate) fn is_plaintext(&self) -> bool {
        matches!(self.mode, EncryptionMode::Plaintext)
    }

    /// True only for the per-row encrypting mode (Mode 2 / RowEncryption).
    ///
    /// Plaintext (Mode 1) carries no crypto. FullDatabase (Mode 3) protects the
    /// whole file via SQLCipher at the connection layer, so the per-row
    /// content/keyID seam is a no-op for it. Centralising the test here keeps
    /// the three seam call sites (`encrypted_for_write`, `decrypted_for_read`,
    /// `assert_content_key_id_invariant`) consistent.
    pub(crate) fn uses_row_crypto(&self) -> bool {
        matches!(self.mode, EncryptionMode::RowEncryption)
    }

    /// The whole-file SQLCipher key as a lowercase hex string, for FullDatabase
    /// estates only. `None` for every other mode (no whole-file key is set, so
    /// the database is a normal unencrypted SQLite file). The hex is consumed by
    /// the SQLite backend as `PRAGMA key = "x'<hex>'"`, which uses the bytes as
    /// the raw 256-bit cipher key (no passphrase KDF — the key is already
    /// full-entropy). Never logged; the raw key stays redacted in Debug.
    pub(crate) fn full_database_key_hex(&self) -> Option<String> {
        if self.mode != EncryptionMode::FullDatabase {
            return None;
        }
        self.key.as_ref().map(|k| {
            let mut s = String::with_capacity(k.len() * 2);
            for b in k {
                s.push_str(&format!("{b:02x}"));
            }
            s
        })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Whole-file key source — the shared per-install SQLCipher key
// ─────────────────────────────────────────────────────────────────────────────

/// Ensure the per-install whole-file key exists at `<estates_dir>/db.key`,
/// creating it (32 random bytes) if absent, and return the key bytes.
///
/// Each resident service calls this once at startup against the estates
/// directory it manages. Because both services resolve the same estates
/// directory, they create/read the same key file and therefore open every
/// estate with the same SQLCipher key. After this runs, `SqliteStorage::new`
/// resolves the sibling key for every estate it opens, so the estates are
/// whole-file encrypted with no per-call-site wiring.
pub fn ensure_install_key(estates_dir: &Path) -> StorageResult<Vec<u8>> {
    load_or_create_install_key(&estates_dir.join(INSTALL_KEY_FILE))
}

/// Read the key file, creating it with fresh random bytes (0600 on unix) if
/// absent. A key file of the wrong length is a tampered/corrupt key: fail loud
/// rather than silently regenerate (which would orphan every existing estate).
fn load_or_create_install_key(key_path: &Path) -> StorageResult<Vec<u8>> {
    if let Ok(bytes) = std::fs::read(key_path) {
        if bytes.len() == INSTALL_KEY_LEN {
            return Ok(bytes);
        }
        return Err(StorageError::BackendError {
            underlying: format!(
                "install key at {key_path:?} is {} bytes, expected {INSTALL_KEY_LEN}",
                bytes.len()
            ),
        });
    }
    if let Some(parent) = key_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| StorageError::BackendError {
                underlying: format!("install key: create dir {parent:?}: {e}"),
            })?;
        }
    }
    let key = Aes256Gcm::generate_key(OsRng).to_vec();
    std::fs::write(key_path, &key).map_err(|e| StorageError::BackendError {
        underlying: format!("install key: write {key_path:?}: {e}"),
    })?;
    // Restrict to owner read/write so a non-owner cannot read the key. On
    // Windows the file inherits the per-user profile ACL of its LOCALAPPDATA
    // location; tightening beyond that needs a platform ACL call (follow-on).
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(key_path, std::fs::Permissions::from_mode(0o600)).map_err(
            |e| StorageError::BackendError {
                underlying: format!("install key: chmod {key_path:?}: {e}"),
            },
        )?;
    }
    Ok(key)
}

/// Resolve the whole-file encryption config for an estate file at `db_path`,
/// IF a sibling `db.key` is present. Returns `None` when the key is absent — the
/// estate is then a normal unencrypted SQLite file (the test / pre-lockdown
/// path). Never creates the key; creation is the explicit `ensure_install_key`
/// act performed by the resident services.
pub(crate) fn resolve_install_encryption(
    db_path: &str,
) -> StorageResult<Option<EstateEncryptionConfig>> {
    // In-memory databases have no directory and are never key-backed.
    if db_path == ":memory:" || db_path.is_empty() {
        return Ok(None);
    }
    let parent = match Path::new(db_path).parent() {
        Some(p) if !p.as_os_str().is_empty() => p.to_path_buf(),
        _ => return Ok(None),
    };
    let key_path = parent.join(INSTALL_KEY_FILE);
    match std::fs::read(&key_path) {
        Ok(bytes) if bytes.len() == INSTALL_KEY_LEN => {
            Ok(Some(EstateEncryptionConfig::full_database_with_key(bytes)))
        }
        Ok(bytes) => Err(StorageError::BackendError {
            underlying: format!(
                "install key at {key_path:?} is {} bytes, expected {INSTALL_KEY_LEN}",
                bytes.len()
            ),
        }),
        Err(_) => Ok(None),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// AeadProvider trait — the swappable seam
// ─────────────────────────────────────────────────────────────────────────────

/// Abstract AEAD provider. A concrete type implementing this trait is the
/// single extension point for swapping the at-rest encryption algorithm
/// without changing any `RowCrypto` or storage call site.
///
/// Implementors MUST:
/// - Generate a fresh random nonce on every `encrypt` call (never reuse a
///   nonce under a given key — the fundamental GCM safety requirement).
/// - Return `[12-byte nonce][16-byte GCM tag][ciphertext]` (the layout
///   shared with the Swift side for cross-decryptability). An alternate
///   layout is permitted only if the same provider's `decrypt` consumes it.
/// - Return `Err` on authentication failure — never return corrupted
///   plaintext on a tampered or incorrect-key input.
/// - Never log the key or intermediate key material.
///
/// Mirrors Swift's `AeadProvider` protocol (`AeadProvider.swift`).
pub trait AeadProvider: Send + Sync {
    /// Encrypt `plaintext` under the 256-bit `key` bytes (32 bytes raw).
    /// Returns `[nonce][tag][ciphertext]`. A fresh random nonce is generated
    /// per call.
    fn encrypt(&self, plaintext: &[u8], key: &[u8]) -> Result<Vec<u8>, String>;

    /// Decrypt `ciphertext` (layout `[nonce][tag][payload]`) under the
    /// 256-bit `key` bytes. Returns an error on authentication failure or
    /// a malformed envelope.
    fn decrypt(&self, ciphertext: &[u8], key: &[u8]) -> Result<Vec<u8>, String>;
}

// ─────────────────────────────────────────────────────────────────────────────
// AesGcmAeadProvider — default provider backed by RustCrypto `aes-gcm`
// ─────────────────────────────────────────────────────────────────────────────

/// The default `AeadProvider` backed by the `aes-gcm` RustCrypto crate
/// (AES-GCM-256). This is the concrete type used in the absence of an
/// injected alternative.
///
/// A FedRAMP/FIPS-validated replacement drops in by implementing
/// `AeadProvider` and injecting it at `RowCrypto` call time. The
/// ciphertext layout (`[nonce][tag][ciphertext]`) is identical to the
/// Swift `CryptoKitAeadProvider`, so existing persisted rows are
/// cross-decryptable between Swift and Rust.
///
/// C-1 per-crate exception: `aes-gcm` is the first approved external
/// crypto crate. Rationale: at-rest AEAD, not conformance-gated (random
/// nonce makes per-call output non-deterministic); hand-rolling an AEAD
/// is never acceptable. See `DECISION_RUST_AEAD_CRATE_2026-06-05.md`.
pub struct AesGcmAeadProvider;

/// Byte counts fixed by AES-GCM-256. These match the Swift layout.
const NONCE_LEN: usize = 12; // 96-bit AES-GCM nonce
const TAG_LEN: usize = 16;   // 128-bit GCM authentication tag

impl AeadProvider for AesGcmAeadProvider {
    /// Encrypt `plaintext` under `key` (32 raw bytes).
    /// Generates a cryptographically random 96-bit nonce per call.
    /// Returns `[12-byte nonce][16-byte tag][ciphertext]`.
    ///
    /// Never logs `key` or intermediate material.
    fn encrypt(&self, plaintext: &[u8], key: &[u8]) -> Result<Vec<u8>, String> {
        let k = Key::<Aes256Gcm>::from_slice(key);
        let cipher = Aes256Gcm::new(k);
        // Generate a fresh cryptographically random nonce per call.
        let nonce_arr = Aes256Gcm::generate_nonce(&mut OsRng);
        // `aes-gcm` returns ciphertext + appended tag in one slice.
        let ct_with_tag = cipher
            .encrypt(&nonce_arr, plaintext)
            .map_err(|e| format!("AesGcmAeadProvider::encrypt: {e}"))?;

        // `ct_with_tag` layout: ciphertext ‖ tag (tag appended last by aes-gcm).
        // Our wire layout: [nonce][tag][ciphertext] — rearrange to match the
        // Swift CryptoKit layout so the stored format is portable.
        let ct_len = ct_with_tag.len().saturating_sub(TAG_LEN);
        let (ct_bytes, tag_bytes) = ct_with_tag.split_at(ct_len);

        let mut out = Vec::with_capacity(NONCE_LEN + TAG_LEN + ct_bytes.len());
        out.extend_from_slice(&nonce_arr);  // 12 bytes
        out.extend_from_slice(tag_bytes);   // 16 bytes
        out.extend_from_slice(ct_bytes);    // payload
        Ok(out)
    }

    /// Decrypt `ciphertext` (layout `[12-byte nonce][16-byte tag][payload]`)
    /// under `key` (32 raw bytes). Returns an error on authentication failure
    /// or a truncated envelope.
    ///
    /// Never logs `key` or intermediate material.
    fn decrypt(&self, ciphertext: &[u8], key: &[u8]) -> Result<Vec<u8>, String> {
        let header = NONCE_LEN + TAG_LEN;
        if ciphertext.len() < header {
            return Err(format!(
                "RowCrypto: ciphertext shorter than nonce+tag header ({} bytes)",
                ciphertext.len()
            ));
        }
        let nonce_bytes = &ciphertext[..NONCE_LEN];
        let tag_bytes   = &ciphertext[NONCE_LEN..header];
        let payload     = &ciphertext[header..];

        let k = Key::<Aes256Gcm>::from_slice(key);
        let cipher = Aes256Gcm::new(k);
        let nonce = Nonce::from_slice(nonce_bytes);

        // `aes-gcm` expects ciphertext ‖ tag (tag appended). Reconstruct
        // that layout from our wire format ([nonce][tag][ct]).
        let mut ct_with_tag = Vec::with_capacity(payload.len() + TAG_LEN);
        ct_with_tag.extend_from_slice(payload);
        ct_with_tag.extend_from_slice(tag_bytes);

        cipher
            .decrypt(nonce, ct_with_tag.as_slice())
            .map_err(|e| format!("AesGcmAeadProvider::decrypt: authentication failure: {e}"))
    }
}

// Inherent impl block for test-only helpers on AesGcmAeadProvider.
#[cfg(test)]
impl AesGcmAeadProvider {
    /// Encrypt `plaintext` under `key` with a caller-supplied `nonce` (12 bytes).
    /// Exposed only for tests that need a deterministic ciphertext to verify
    /// cross-port envelope format parity. Production callers always use the
    /// `AeadProvider::encrypt` method, which generates a fresh random nonce
    /// via OsRng — never call this in non-test code.
    ///
    /// # Security note
    /// Reusing a nonce under the same key breaks AES-GCM confidentiality and
    /// authenticity. This seam exists only so tests can produce a known-nonce
    /// envelope matching the Swift fixture; it is compiled out of release builds.
    pub fn encrypt_with_nonce(
        &self,
        plaintext: &[u8],
        key: &[u8],
        nonce_bytes: &[u8; 12],
    ) -> Result<Vec<u8>, String> {
        let k = Key::<Aes256Gcm>::from_slice(key);
        let cipher = Aes256Gcm::new(k);
        let nonce = Nonce::from_slice(nonce_bytes);
        let ct_with_tag = cipher
            .encrypt(nonce, plaintext)
            .map_err(|e| format!("AesGcmAeadProvider::encrypt_with_nonce: {e}"))?;
        let ct_len = ct_with_tag.len().saturating_sub(TAG_LEN);
        let (ct_bytes, tag_bytes) = ct_with_tag.split_at(ct_len);
        let mut out = Vec::with_capacity(NONCE_LEN + TAG_LEN + ct_bytes.len());
        out.extend_from_slice(nonce_bytes);
        out.extend_from_slice(tag_bytes);
        out.extend_from_slice(ct_bytes);
        Ok(out)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RowCrypto — mirrors Swift's RowCrypto enum
// ─────────────────────────────────────────────────────────────────────────────

/// Per-row AES-GCM-256 encrypt/decrypt, delegating to the injected
/// `AeadProvider`. Defaults to `AesGcmAeadProvider` when no provider is
/// supplied, so existing call sites compile and behave identically to before
/// the seam was introduced.
///
/// Mirrors Swift's `RowCrypto` enum (`RowCrypto.swift`, `PersistenceKitSQLite`).
pub struct RowCrypto;

impl RowCrypto {
    /// Encrypt `plaintext` under `key` (raw key bytes), returning
    /// `[nonce][tag][ciphertext]`. Uses `AesGcmAeadProvider` by default.
    ///
    /// Never logs `key`.
    pub fn encrypt(
        plaintext: &[u8],
        key: &[u8],
        provider: &dyn AeadProvider,
    ) -> Result<Vec<u8>, String> {
        provider.encrypt(plaintext, key)
    }

    /// Decrypt `ciphertext` (layout `[nonce][tag][ciphertext]`) under `key`
    /// (raw key bytes). Throws on a malformed envelope or authentication
    /// failure. Uses `AesGcmAeadProvider` by default.
    ///
    /// Never logs `key`.
    pub fn decrypt(
        ciphertext: &[u8],
        key: &[u8],
        provider: &dyn AeadProvider,
    ) -> Result<Vec<u8>, String> {
        provider.decrypt(ciphertext, key)
    }
}
