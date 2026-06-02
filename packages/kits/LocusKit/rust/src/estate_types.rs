//! Estate-level primitive types. Ports `EstateTypes.swift`.
//!
//! `RowID`, `OwnerCredentials`, `LatticeAnchor`, and `EstateError`
//! carry no internal LocusKit dependencies — they are true leaves that
//! LP-1B and later missions build on top of.

// MARK: - RowID

/// Stable row identifier — the string id stored on every noun row
/// (drawer, tunnel, kg fact, diary entry). Declared as a type alias
/// rather than a wrapping newtype because every noun's row id column
/// is already TEXT PRIMARY KEY and round-trips through SQLite as a
/// plain string; a newtype would require an extra string conversion on
/// every bind/column call without semantic gain.
///
/// Mirrors `public typealias RowID = String` in `EstateTypes.swift`.
pub type RowID = String;

// MARK: - OwnerCredentials

/// Credentials identifying the owner of an estate.
///
/// The substrate layer validates only that `owner_identifier` is
/// non-empty on open/create; full credential validation (iCloud account
/// matching, key escrow, etc.) is out of scope for LocusKit and lives
/// in the ARIA_MCP outer envelope.
///
/// Per spec § 7.8.1: `Estate::open` takes an `OwnerCredentials` so the
/// kit can stamp the manifest's `owner_identifier` row at create time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnerCredentials {
    /// The owner's identifier — typically an iCloud account string.
    /// Must be non-empty; `Estate::open` and `Estate::create` return
    /// `EstateError::EmptyOwnerIdentifier` if it is empty.
    pub owner_identifier: String,
}

impl OwnerCredentials {
    /// Create credentials with the given identifier.
    pub fn new(owner_identifier: impl Into<String>) -> Self {
        Self {
            owner_identifier: owner_identifier.into(),
        }
    }
}

// MARK: - LatticeAnchor

/// The lattice anchor for a drawer — a UDC classification code plus
/// optional Wikidata and facet enrichment. Every drawer carries one
/// per spec I-5 and § 5.8.
///
/// The four fields are already stored on `Drawer` directly. This type
/// promotes them into a single named value so `CaptureFrame` can pass
/// an anchor as a unit rather than four parallel parameters.
///
/// `udc_code` is required at storage; the substrate enforces
/// `TEXT NOT NULL DEFAULT ''`. Non-emptiness at capture time is enforced
/// by the verb layer, not here. Optional fields are populated by the
/// enrichment daemon when absent; callers may supply them at capture time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LatticeAnchor {
    /// Primary UDC classification code (e.g. "547" for organic chemistry).
    pub udc_code: String,
    /// Additional UDC codes for secondary topics, comma-separated.
    pub udc_facets: Option<String>,
    /// Wikidata Q-ID for the primary concept (e.g. "Q11351").
    pub wikidata_qid: Option<String>,
    /// Additional Wikidata Q-IDs, comma-separated.
    pub wikidata_qids_secondary: Option<String>,
}

impl LatticeAnchor {
    /// Create a fully-specified lattice anchor.
    pub fn new(
        udc_code: impl Into<String>,
        udc_facets: Option<String>,
        wikidata_qid: Option<String>,
        wikidata_qids_secondary: Option<String>,
    ) -> Self {
        Self {
            udc_code: udc_code.into(),
            udc_facets,
            wikidata_qid,
            wikidata_qids_secondary,
        }
    }

    /// Convenience constructor for a bare UDC code with no enrichment —
    /// the common shape for content captured before the enrichment daemon
    /// has run. Mirrors `LatticeAnchor.udc(_:)` in `EstateTypes.swift`.
    pub fn udc(code: impl Into<String>) -> Self {
        Self {
            udc_code: code.into(),
            udc_facets: None,
            wikidata_qid: None,
            wikidata_qids_secondary: None,
        }
    }
}

// MARK: - EstateError

/// Errors thrown by `Estate` lifecycle methods.
///
/// Distinct from `LocusKitError` (substrate-layer SQLite and migration
/// faults) — `EstateError` covers the estate-level contract per spec
/// § 8.1 (`ManifestMismatch`, `SubstrateUnavailable`). The three cases
/// map exactly to the Swift `EstateError` enum.
#[derive(Debug, PartialEq, Eq)]
pub enum EstateError {
    /// The backing SQLite store could not be opened or created. The
    /// associated message is the underlying diagnostic so callers can
    /// log the substrate failure without re-wrapping `LocusKitError`.
    SubstrateUnavailable(String),

    /// A manifest key does not match the expected value. Per spec § 8.1:
    /// "ManifestMismatch — operation requires a manifest value not
    /// present (or incompatible)."
    ManifestMismatch {
        /// The manifest key that did not match (e.g. "bitmap_layout_version").
        key: String,
        /// The value found on disk.
        found: String,
        /// The value this build expects.
        expected: String,
    },

    /// `OwnerCredentials::owner_identifier` was empty. Raised before
    /// any database call is made so callers receive a structurally
    /// distinct error rather than a generic substrate failure.
    EmptyOwnerIdentifier,
}

impl std::fmt::Display for EstateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EstateError::SubstrateUnavailable(msg) => {
                write!(f, "SubstrateUnavailable: {}", msg)
            }
            EstateError::ManifestMismatch {
                key,
                found,
                expected,
            } => {
                write!(
                    f,
                    "ManifestMismatch: key='{}' found='{}' expected='{}'",
                    key, found, expected
                )
            }
            EstateError::EmptyOwnerIdentifier => {
                write!(f, "EmptyOwnerIdentifier")
            }
        }
    }
}

impl std::error::Error for EstateError {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_id_is_string_alias() {
        // RowID is a type alias for String — assignment and equality must work.
        let id: RowID = "abc-123".to_string();
        assert_eq!(id, "abc-123");
    }

    #[test]
    fn owner_credentials_roundtrip() {
        let creds = OwnerCredentials::new("alice@icloud.com");
        assert_eq!(creds.owner_identifier, "alice@icloud.com");
    }

    #[test]
    fn lattice_anchor_udc_convenience() {
        let anchor = LatticeAnchor::udc("547");
        assert_eq!(anchor.udc_code, "547");
        assert!(anchor.udc_facets.is_none());
        assert!(anchor.wikidata_qid.is_none());
        assert!(anchor.wikidata_qids_secondary.is_none());
    }

    #[test]
    fn lattice_anchor_full() {
        let anchor = LatticeAnchor::new(
            "547",
            Some("541".to_string()),
            Some("Q11351".to_string()),
            Some("Q12345".to_string()),
        );
        assert_eq!(anchor.udc_code, "547");
        assert_eq!(anchor.udc_facets.as_deref(), Some("541"));
        assert_eq!(anchor.wikidata_qid.as_deref(), Some("Q11351"));
        assert_eq!(anchor.wikidata_qids_secondary.as_deref(), Some("Q12345"));
    }

    #[test]
    fn estate_error_substrate_unavailable() {
        let err = EstateError::SubstrateUnavailable("disk full".to_string());
        assert_eq!(
            err,
            EstateError::SubstrateUnavailable("disk full".to_string())
        );
    }

    #[test]
    fn estate_error_manifest_mismatch() {
        let err = EstateError::ManifestMismatch {
            key: "bitmap_layout_version".to_string(),
            found: "2".to_string(),
            expected: "1".to_string(),
        };
        match &err {
            EstateError::ManifestMismatch {
                key,
                found,
                expected,
            } => {
                assert_eq!(key, "bitmap_layout_version");
                assert_eq!(found, "2");
                assert_eq!(expected, "1");
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn estate_error_empty_owner_identifier() {
        assert_eq!(
            EstateError::EmptyOwnerIdentifier,
            EstateError::EmptyOwnerIdentifier
        );
    }
}
