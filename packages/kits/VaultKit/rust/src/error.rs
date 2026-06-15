//! VaultKitError — structured error enum for VaultKit.
//!
//! Follows the MOOTx01Error-style pattern: named cases, no raw strings as
//! the only diagnostic. Callers pattern-match; no lossy `unwrap`.

use std::fmt;

/// Errors produced by the VaultKit Rust port.
#[derive(Debug)]
pub enum VaultKitError {
    /// A filesystem operation failed (read, write, enumerate).
    Io(std::io::Error),

    /// The vault adapter rejected the vault or a note within it.
    AdapterError(String),

    /// A note was skipped because it would violate invariant I-5
    /// (empty content, empty room, empty addedBy, etc.).
    I5Violation(String),

    /// The GLK verb surface returned an error while capturing or recalling.
    VerbError(String),

    /// A `CorpusDocument` payload declared a `formatVersion` this build
    /// does not understand. Decoding is strict by design: an unknown
    /// version fails loudly with the offending value rather than
    /// best-effort parsing a shape this code has never seen.
    /// Mirrors Swift `VaultKitError.unsupportedFormatVersion(Int)`.
    UnsupportedFormatVersion(i64),

    /// Canonical corpus JSON could not be encoded or decoded (malformed
    /// JSON, shape mismatch). The Swift port surfaces the analogous
    /// failures as Foundation `EncodingError`/`DecodingError`.
    Serialization(String),
}

impl fmt::Display for VaultKitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VaultKitError::Io(e) => write!(f, "VaultKit I/O error: {e}"),
            VaultKitError::AdapterError(msg) => write!(f, "VaultKit adapter error: {msg}"),
            VaultKitError::I5Violation(msg) => write!(f, "VaultKit I-5 violation: {msg}"),
            VaultKitError::VerbError(msg) => write!(f, "VaultKit verb error: {msg}"),
            VaultKitError::UnsupportedFormatVersion(v) => {
                write!(f, "VaultKit corpus document: unsupported formatVersion {v}")
            }
            VaultKitError::Serialization(msg) => {
                write!(f, "VaultKit corpus serialization error: {msg}")
            }
        }
    }
}

impl std::error::Error for VaultKitError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            VaultKitError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<std::io::Error> for VaultKitError {
    fn from(e: std::io::Error) -> Self {
        VaultKitError::Io(e)
    }
}
