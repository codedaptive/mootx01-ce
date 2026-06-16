//! CorpusDocument — the versioned canonical interchange envelope.
//!
//! THE versioned canonical JSON document mandated by ADR-007 Decision 1:
//! "NoteIR is the single interchange representation … Its serialized form
//! is a versioned canonical JSON document — the JSON is the payload,
//! never a per-tool mapping DSL." `Vec<NoteIR>` passed in memory has no
//! version or identity; this envelope gives a corpus both. Mirrors Swift
//! `CorpusDocument` (`Sources/VaultKit/CorpusDocument.swift`).
//!
//! ## Canonical form (cross-language conformance contract)
//!
//! Both ports must produce byte-identical bytes for the same document:
//!
//! - Object keys sorted ascending. Rust achieves this via an explicit
//!   recursive `sort_keys` pass on the `serde_json::Value` after
//!   `to_value`. The explicit sort is required because Cargo feature
//!   unification may activate `serde_json`'s `preserve_order` feature
//!   (GeniusLocusKit requests it), which switches `Value`'s map from
//!   `BTreeMap` to `IndexMap` — breaking the implicit sort the old
//!   two-step relied on. Sorting explicitly is independent of which map
//!   type backs `Value`, matching Swift's `.sortedKeys` unconditionally.
//! - Compact output — `serde_json::to_string`, no insignificant
//!   whitespace (Swift compact is the encoder default).
//! - Forward slashes unescaped (serde_json never escapes them; Swift
//!   opts out of Foundation's `\/` escaping with
//!   `.withoutEscapingSlashes`).
//! - Optional fields omit their key when `None`; the four full-fidelity
//!   `NoteIR` fields always serialize, even when empty.
//! - `mootID` serializes as the UPPERCASE hyphenated UUID string
//!   (Foundation's casing; see `note_ir::serialize_uuid_uppercase`).
//!
//! The shared golden fixture
//! `../Tests/VaultKitTests/Fixtures/corpus_document_v1.json` is exercised
//! byte-for-byte by BOTH test suites and is the executable form of this
//! contract.

use serde::{Deserialize, Serialize};

use crate::error::VaultKitError;
use crate::note_ir::NoteIR;

/// Sort all JSON object keys recursively, producing a new Value where every
/// object's keys appear in ascending lexicographic order.
///
/// Required because `serde_json`'s `Value` map may be `IndexMap`-backed when
/// the `preserve_order` feature is active via Cargo feature unification (e.g.
/// GeniusLocusKit enables it, and feature unification propagates the flag to
/// every crate in the workspace). With `preserve_order` active, `to_value`
/// preserves struct declaration order rather than sorting — making the
/// two-step `to_value → to_string` pattern emit unsorted keys. This helper
/// restores the invariant explicitly, independent of serde_json's internal
/// map type, so canonical output is deterministic regardless of which crates
/// happen to be linked.
pub(crate) fn sort_keys(v: serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(map) => {
            let mut pairs: Vec<(String, serde_json::Value)> =
                map.into_iter().map(|(k, v)| (k, sort_keys(v))).collect();
            pairs.sort_by(|a, b| a.0.cmp(&b.0));
            serde_json::Value::Object(pairs.into_iter().collect())
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(sort_keys).collect())
        }
        other => other,
    }
}

/// The format version this build reads and writes. Bumping it is a
/// deliberate act recorded in `docs/decisions/` — shapes froze at v0.9
/// beta (ADR-007 Decision 4, deliverable 2). Mirrors Swift
/// `CorpusDocument.currentFormatVersion`.
pub const CURRENT_FORMAT_VERSION: i64 = 1;

/// The versioned canonical envelope around a corpus of `NoteIR` entries.
///
/// `{ formatVersion, name, notes }` — nothing else. The envelope is the
/// unit of mass data movement (ADR-007 Decision 1): exporters produce
/// one, importers consume one, and `formatVersion` is the explicit
/// compatibility gate between producers and consumers built years apart.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CorpusDocument {
    /// The document's declared format version. Always
    /// `CURRENT_FORMAT_VERSION` for documents this build produces.
    /// Decode-side validation lives in [`CorpusDocument::decode`] —
    /// construct documents via [`CorpusDocument::new`] and decode via
    /// `decode`, never via raw `serde_json::from_str` (which would
    /// bypass the strict version gate).
    #[serde(rename = "formatVersion")]
    pub format_version: i64,

    /// Human-readable corpus name — typically the estate or vault name
    /// the corpus was produced from. Identification only; carries no
    /// routing semantics.
    pub name: String,

    /// The corpus content, in producer order.
    pub notes: Vec<NoteIR>,
}

impl CorpusDocument {
    /// Construct a document at the current format version.
    pub fn new(name: impl Into<String>, notes: Vec<NoteIR>) -> Self {
        Self { format_version: CURRENT_FORMAT_VERSION, name: name.into(), notes }
    }

    /// Encode to the canonical interchange bytes (see the canonical-form
    /// contract in the module header). Deterministic: the same document
    /// always yields the same bytes, in both ports.
    pub fn canonical_json(&self) -> Result<String, VaultKitError> {
        // Two-step: struct → Value, then explicit sort_keys, then to_string.
        // The explicit sort_keys pass is required because Cargo feature
        // unification may activate serde_json's `preserve_order` feature
        // (GeniusLocusKit requests it), which makes `to_value` emit keys in
        // struct declaration order instead of sorted order. sort_keys
        // reconstructs every Object from a sorted Vec, so the result is
        // always ascending-lexicographic regardless of the underlying map
        // type — matching Swift's `.sortedKeys` unconditionally.
        let value = serde_json::to_value(self)
            .map_err(|e| VaultKitError::Serialization(e.to_string()))?;
        let sorted = sort_keys(value);
        serde_json::to_string(&sorted).map_err(|e| VaultKitError::Serialization(e.to_string()))
    }

    /// Strict versioned decode: `formatVersion` is read FIRST and an
    /// unknown value returns `VaultKitError::UnsupportedFormatVersion`
    /// before any note is parsed — never silent best-effort decoding of
    /// a shape this build does not know. Mirrors Swift
    /// `CorpusDocument.decode(_:)`.
    pub fn decode(json: &str) -> Result<Self, VaultKitError> {
        // Version probe: deserializes ONLY the version field; serde skips
        // the remaining tokens (including `notes`) without shaping them,
        // so a future-versioned document with notes this build cannot
        // parse still reports the version error, not a shape error.
        #[derive(Deserialize)]
        struct VersionProbe {
            #[serde(rename = "formatVersion")]
            format_version: i64,
        }
        let probe: VersionProbe = serde_json::from_str(json)
            .map_err(|e| VaultKitError::Serialization(e.to_string()))?;
        if probe.format_version != CURRENT_FORMAT_VERSION {
            return Err(VaultKitError::UnsupportedFormatVersion(probe.format_version));
        }
        serde_json::from_str(json).map_err(|e| VaultKitError::Serialization(e.to_string()))
    }
}
