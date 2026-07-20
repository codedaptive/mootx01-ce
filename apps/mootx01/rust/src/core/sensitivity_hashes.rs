//! core/sensitivity_hashes.rs — sidecar storage for the two per-tier
//! password hashes used by `mootx01 unlock private|secret` on Linux/Windows.
//!
//! The sensitivity policy requires that two discrete passwords are set at estate
//! creation and stored as salted PBKDF2-HMAC-SHA256 hashes. This module
//! manages the storage file (`<dataDir>/sensitivity_hashes.json`), hash
//! derivation, and constant-time password verification.
//!
//! Swift/macOS uses LocalAuthentication instead; this module is compiled
//! on all platforms but the sidecar file is only populated by the Rust
//! setup flow.
//!
//! ## File format
//!
//! JSON, version 1:
//!   { "version": 1,
//!     "restricted_salt": "<64 hex chars>",
//!     "restricted_hash": "<64 hex chars>",
//!     "secret_salt":     "<64 hex chars>",
//!     "secret_hash":     "<64 hex chars>" }
//!
//! Hex was chosen over base64 for simplicity: the file never leaves the
//! local data directory, and no external crate is required for either
//! encoding direction.

use std::io;
use std::path::{Path, PathBuf};

use crate::core::sensitivity_crypto::{constant_time_eq, pbkdf2_hmac_sha256};

// --- Constants ---

/// PBKDF2 iteration count.
///
/// 260 000 is OWASP's 2024 recommended minimum for PBKDF2-HMAC-SHA256
/// (OWASP Password Storage Cheat Sheet). The 80 000-iteration RFC 7914
/// test vector in `sensitivity_crypto.rs` takes ~1 ms on Apple Silicon;
/// 260 000 takes roughly 3 ms — acceptable for a single interactive unlock.
pub const PBKDF2_ITERATIONS: u32 = 260_000;

/// Per-hash salt length in bytes (256 bits).
pub const SALT_LEN: usize = 32;

/// Derived-key length / stored-hash length in bytes (256 bits).
pub const HASH_LEN: usize = 32;

/// JSON schema version. Reject any file whose `version` differs so a
/// format change can be detected cleanly.
const SCHEMA_VERSION: u32 = 1;

// --- Types ---

/// The two password hashes loaded from the sidecar file.
#[derive(Debug, Clone)]
pub struct SensitivityHashes {
    pub restricted_salt: [u8; SALT_LEN],
    pub restricted_hash: [u8; HASH_LEN],
    pub secret_salt:     [u8; SALT_LEN],
    pub secret_hash:     [u8; HASH_LEN],
}

// --- Paths ---

/// Path of the sensitivity-hashes sidecar file in the mootx01 data directory.
///
/// Lives next to the estate file so the CLI can read it without opening the
/// full estate stack. Named distinctly from the estate file so it is not
/// accidentally treated as an estate.
pub fn hashes_path(data_dir: &Path) -> PathBuf {
    data_dir.join("sensitivity_hashes.json")
}

// --- Load / save ---

/// Load and parse the sidecar file.
///
/// Returns `None` if the file does not exist (not yet configured), if the
/// version field differs (unknown schema), or if any field is corrupt or the
/// wrong length. The caller surfaces `None` as "sensitivity passwords not set".
pub fn load(data_dir: &Path) -> Option<SensitivityHashes> {
    let path = hashes_path(data_dir);
    let text = std::fs::read_to_string(path).ok()?;
    let obj: serde_json::Value = serde_json::from_str(&text).ok()?;

    // Schema version gate.
    if obj.get("version")?.as_u64()? != u64::from(SCHEMA_VERSION) {
        return None;
    }

    let rs = hex_dec(obj.get("restricted_salt")?.as_str()?)?;
    let rh = hex_dec(obj.get("restricted_hash")?.as_str()?)?;
    let ss = hex_dec(obj.get("secret_salt")?.as_str()?)?;
    let sh = hex_dec(obj.get("secret_hash")?.as_str()?)?;

    if rs.len() != SALT_LEN || rh.len() != HASH_LEN
        || ss.len() != SALT_LEN || sh.len() != HASH_LEN
    {
        return None;
    }

    let mut h = SensitivityHashes {
        restricted_salt: [0u8; SALT_LEN],
        restricted_hash: [0u8; HASH_LEN],
        secret_salt:     [0u8; SALT_LEN],
        secret_hash:     [0u8; HASH_LEN],
    };
    h.restricted_salt.copy_from_slice(&rs);
    h.restricted_hash.copy_from_slice(&rh);
    h.secret_salt.copy_from_slice(&ss);
    h.secret_hash.copy_from_slice(&sh);
    Some(h)
}

/// Write the sidecar to disk.
///
/// On Unix the file is created with mode 0600 (owner read/write only) so
/// the hashes are not readable by other users. On Windows a write to the
/// data directory is used; file ACLs are managed by the existing per-
/// directory permissions already applied during install.
pub fn save(data_dir: &Path, hashes: &SensitivityHashes) -> io::Result<()> {
    let path = hashes_path(data_dir);
    let json = serde_json::json!({
        "version":          SCHEMA_VERSION,
        "restricted_salt":  hex_enc(&hashes.restricted_salt),
        "restricted_hash":  hex_enc(&hashes.restricted_hash),
        "secret_salt":      hex_enc(&hashes.secret_salt),
        "secret_hash":      hex_enc(&hashes.secret_hash),
    });
    let text = serde_json::to_string_pretty(&json)?;
    write_private(&path, text.as_bytes())
}

// --- Derive + verify ---

/// Derive a PBKDF2-HMAC-SHA256 hash of `password` using `salt`.
///
/// Uses `PBKDF2_ITERATIONS` (260 000) — the OWASP-recommended minimum for
/// PBKDF2-HMAC-SHA256 as of 2024. The cost is ~3 ms on modern hardware,
/// which is acceptable for a single interactive unlock but meaningful enough
/// to slow a brute-force attack.
pub fn derive_hash(password: &str, salt: &[u8; SALT_LEN]) -> [u8; HASH_LEN] {
    let dk = pbkdf2_hmac_sha256(password.as_bytes(), salt, PBKDF2_ITERATIONS, HASH_LEN);
    let mut out = [0u8; HASH_LEN];
    out.copy_from_slice(&dk);
    out
}

/// Verify `password` against a stored `(salt, hash)` pair.
///
/// Uses constant-time comparison from `sensitivity_crypto::constant_time_eq`
/// to prevent a timing oracle.
pub fn verify_password(password: &str, salt: &[u8; SALT_LEN], stored_hash: &[u8; HASH_LEN]) -> bool {
    let derived = derive_hash(password, salt);
    constant_time_eq(&derived, stored_hash)
}

// --- Encoding helpers (std-only, no external crate) ---

/// Lowercase hex encode.
pub fn hex_enc(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Hex decode. Returns `None` on non-hex input or odd-length strings.
pub fn hex_dec(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 2);
    for i in (0..s.len()).step_by(2) {
        let byte = u8::from_str_radix(&s[i..i + 2], 16).ok()?;
        out.push(byte);
    }
    Some(out)
}

// --- Platform-specific private-file write ---

/// Write `data` to `path` with owner-only read/write permissions.
///
/// On Unix: creates with mode 0600 via `OpenOptions::mode`.
/// On non-Unix: plain `std::fs::write` (relies on directory permissions
/// set by the installer).
fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::fs::OpenOptions;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600) // owner read/write only — same as the estate encryption-key file
            .open(path)?;
        file.write_all(data)
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, data)
    }
}

// --- Tests ---

#[cfg(test)]
mod tests {
    use super::*;

    /// Determinism: same password + same salt → same hash, always.
    #[test]
    fn derive_hash_is_deterministic() {
        let salt = [0x42u8; SALT_LEN];
        let h1 = derive_hash("test-password", &salt);
        let h2 = derive_hash("test-password", &salt);
        assert_eq!(h1, h2);
    }

    /// Correct password verifies.
    #[test]
    fn verify_password_correct_returns_true() {
        let salt = [0x1au8; SALT_LEN];
        let hash = derive_hash("correct-horse-battery-staple", &salt);
        assert!(verify_password("correct-horse-battery-staple", &salt, &hash));
    }

    /// Wrong password does not verify.
    #[test]
    fn verify_password_wrong_returns_false() {
        let salt = [0x1bu8; SALT_LEN];
        let hash = derive_hash("the-real-password", &salt);
        assert!(!verify_password("wrong-password", &salt, &hash));
    }

    /// Different salts produce different hashes for the same password.
    #[test]
    fn different_salts_produce_different_hashes() {
        let salt_a = [0x01u8; SALT_LEN];
        let salt_b = [0x02u8; SALT_LEN];
        let h_a = derive_hash("password", &salt_a);
        let h_b = derive_hash("password", &salt_b);
        assert_ne!(h_a, h_b);
    }

    /// Save and load round-trip preserves all four fields exactly.
    #[test]
    fn save_load_round_trip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let hashes = SensitivityHashes {
            restricted_salt: [0xAAu8; SALT_LEN],
            restricted_hash: [0xBBu8; HASH_LEN],
            secret_salt:     [0xCCu8; SALT_LEN],
            secret_hash:     [0xDDu8; HASH_LEN],
        };
        save(dir.path(), &hashes).expect("save");
        let loaded = load(dir.path()).expect("load");
        assert_eq!(loaded.restricted_salt, hashes.restricted_salt);
        assert_eq!(loaded.restricted_hash, hashes.restricted_hash);
        assert_eq!(loaded.secret_salt, hashes.secret_salt);
        assert_eq!(loaded.secret_hash, hashes.secret_hash);
    }

    /// Missing file → None (not configured case).
    #[test]
    fn load_returns_none_when_file_absent() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert!(load(dir.path()).is_none());
    }

    /// Corrupt JSON → None.
    #[test]
    fn load_returns_none_on_corrupt_json() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("sensitivity_hashes.json"), b"not json").unwrap();
        assert!(load(dir.path()).is_none());
    }

    /// Wrong schema version → None.
    #[test]
    fn load_returns_none_on_unknown_version() {
        let dir = tempfile::tempdir().expect("tempdir");
        let json = serde_json::json!({
            "version": 999,
            "restricted_salt": hex_enc(&[0u8; SALT_LEN]),
            "restricted_hash": hex_enc(&[0u8; HASH_LEN]),
            "secret_salt":     hex_enc(&[0u8; SALT_LEN]),
            "secret_hash":     hex_enc(&[0u8; HASH_LEN]),
        });
        std::fs::write(
            dir.path().join("sensitivity_hashes.json"),
            serde_json::to_string(&json).unwrap(),
        ).unwrap();
        assert!(load(dir.path()).is_none());
    }

    /// hex_enc → hex_dec round-trip.
    #[test]
    fn hex_roundtrip() {
        let bytes = [0x00u8, 0xffu8, 0x7eu8, 0x80u8, 0xabu8, 0xcd_u8];
        let enc = hex_enc(&bytes);
        let dec = hex_dec(&enc).expect("hex_dec");
        assert_eq!(dec, bytes);
    }

    /// Odd-length hex → None.
    #[test]
    fn hex_dec_rejects_odd_length() {
        assert!(hex_dec("abc").is_none());
    }

    /// Non-hex chars → None.
    #[test]
    fn hex_dec_rejects_non_hex() {
        assert!(hex_dec("zz").is_none());
    }
}
