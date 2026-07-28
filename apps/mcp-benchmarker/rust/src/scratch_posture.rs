// scratch_posture.rs — at-rest encryption posture for benchmark scratch estates.
//
// Twin of Swift `ScratchPosture.swift`.
//
// WHY THIS EXISTS
// mootx01 creates new estates ENCRYPTED by default (CE-1.0.35). Key resolution
// goes through the macOS keychain (EstateKeyProvider), and keychain ACLs are
// bound to the binary's code signature. Every rebuild re-signs the binary ad
// hoc, so every freshly-spawned `mootx01 serve` (one per benchmark question)
// triggers a keychain prompt at the operator. Synthetic benchmark data deleted
// minutes later needs zero keychain contact.
//
// THE MECHANISM (contract with the product, verified against
// apps/mootx01/Sources/MootInstallerCore/EstateOpenPosture.swift):
//   - Marker filename: EstateKeyProvider.encryptionOptOutMarkerName == "no-encrypt".
//   - Location: the estate file's PARENT directory. Runners launch serve with
//     MOOTX01_DATA_DIR=<scratch_dir> and the default estate, whose file is
//     <scratch_dir>/estate.sqlite — so the marker path is
//     <scratch_dir>/no-encrypt.
//   - Consulted ONLY on the absent-file branch of resolveOpenPosture: a
//     not-yet-created estate with the marker present is created plaintext
//     (posture `newPlaintextByOptOut`). The marker must exist BEFORE the first
//     serve launch — which is exactly when the runners write it.
//
// The chosen posture is recorded in every report JSON as the run-level
// "estate_encryption" key.

use std::path::{Path, PathBuf};

use crate::mcp_client::MCPError;

/// Filename of mootx01's per-estate encryption opt-out marker.
/// MUST match `EstateKeyProvider.encryptionOptOutMarkerName`.
pub const MOOT_ENCRYPTION_OPT_OUT_MARKER_NAME: &str = "no-encrypt";

/// At-rest posture for a benchmark scratch estate.
/// Recorded as the "estate_encryption" key in every report JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ScratchEstatePosture {
    /// Default. The runner writes mootx01's `no-encrypt` opt-out marker into
    /// the scratch data dir before serve launch; the estate is created
    /// plaintext and never touches the macOS keychain.
    PlaintextOptOut,
    /// Deliberate opt-out of the opt-out (--no-plaintext-scratch): no marker
    /// is written, the estate is created encrypted through the keychain.
    /// Use only to benchmark encrypted-estate overhead on purpose.
    EncryptedDefault,
}

impl ScratchEstatePosture {
    /// The raw string value written to report JSON ("estate_encryption") and
    /// used as the cache-key component. Matches the Swift rawValues.
    pub fn as_str(&self) -> &'static str {
        match self {
            ScratchEstatePosture::PlaintextOptOut => "plaintext-optout",
            ScratchEstatePosture::EncryptedDefault => "encrypted-default",
        }
    }
}

impl Default for ScratchEstatePosture {
    fn default() -> Self {
        ScratchEstatePosture::PlaintextOptOut
    }
}

/// Path of the opt-out marker inside a benchmark scratch data dir.
/// The default estate's file is `<scratch_dir>/estate.sqlite`, so the marker's
/// parent-of-estate-file location IS the scratch dir itself.
pub fn scratch_opt_out_marker_path(scratch_dir: &Path) -> PathBuf {
    scratch_dir.join(MOOT_ENCRYPTION_OPT_OUT_MARKER_NAME)
}

/// Applies the posture to a freshly-created scratch data dir, BEFORE any
/// mootx01 serve is launched against it.
///
/// PlaintextOptOut: writes the `no-encrypt` marker (idempotent).
/// EncryptedDefault: writes nothing — the product's default (encrypted) applies.
pub fn apply_scratch_posture(
    posture: ScratchEstatePosture,
    scratch_dir: &Path,
) -> Result<(), MCPError> {
    if posture != ScratchEstatePosture::PlaintextOptOut {
        return Ok(());
    }
    let marker = scratch_opt_out_marker_path(scratch_dir);
    // Idempotent: an existing marker already encodes the same choice.
    if marker.exists() {
        return Ok(());
    }
    let body = "Benchmark scratch estate: created with the encryption opt-out marker so\n\
                mootx01 serve creates it PLAINTEXT (posture newPlaintextByOptOut) and\n\
                never touches the macOS keychain. This directory holds synthetic\n\
                benchmark data and is torn down by the harness.\n";
    std::fs::write(&marker, body).map_err(|e| MCPError {
        description: format!(
            "apply_scratch_posture: could not write opt-out marker {}: {e}",
            marker.display()
        ),
    })
}

/// True when the scratch dir currently carries the opt-out marker. Used by the
/// estate cache to verify that a restored snapshot's posture matches the run's
/// expected posture (the marker travels with the snapshot).
pub fn scratch_has_opt_out_marker(scratch_dir: &Path) -> bool {
    scratch_opt_out_marker_path(scratch_dir).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(prefix: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("{prefix}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn marker_name_matches_product_contract() {
        // EstateKeyProvider.encryptionOptOutMarkerName in MootInstallerCore.
        assert_eq!(MOOT_ENCRYPTION_OPT_OUT_MARKER_NAME, "no-encrypt");
    }

    #[test]
    fn marker_path_is_directly_inside_scratch_dir() {
        let p = scratch_opt_out_marker_path(Path::new("/tmp/lme-bench-x"));
        assert_eq!(p, PathBuf::from("/tmp/lme-bench-x/no-encrypt"));
    }

    #[test]
    fn plaintext_writes_marker_and_is_idempotent() {
        let dir = tmp_dir("posture-plain");
        apply_scratch_posture(ScratchEstatePosture::PlaintextOptOut, &dir).unwrap();
        assert!(scratch_has_opt_out_marker(&dir));
        // Second application must not fail.
        apply_scratch_posture(ScratchEstatePosture::PlaintextOptOut, &dir).unwrap();
        assert!(scratch_has_opt_out_marker(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn encrypted_writes_no_marker() {
        let dir = tmp_dir("posture-enc");
        apply_scratch_posture(ScratchEstatePosture::EncryptedDefault, &dir).unwrap();
        assert!(!scratch_has_opt_out_marker(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn raw_values_are_the_report_vocabulary() {
        assert_eq!(ScratchEstatePosture::PlaintextOptOut.as_str(), "plaintext-optout");
        assert_eq!(ScratchEstatePosture::EncryptedDefault.as_str(), "encrypted-default");
    }

    #[test]
    fn default_is_plaintext() {
        assert_eq!(ScratchEstatePosture::default(), ScratchEstatePosture::PlaintextOptOut);
    }
}
