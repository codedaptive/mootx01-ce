//! palace_payload_envelope — the lossless encoding scheme for `NoteIR` fields
//! MemPalace's `add_drawer` cannot carry natively. Rust parallel of the Swift
//! `PalacePayloadEnvelope`; byte-identical envelope output for the same note.
//!
//! ## Why an envelope exists
//!
//! MemPalace's `mempalace_add_drawer` accepts exactly `wing`, `room`,
//! `content`, and the optional metadata `source_file` + `added_by`. A `NoteIR`
//! carries far more — frontmatter, wikilinks, an origin date, an attachment
//! ref, a substrate lineage UUID, KG facts, tags, a scope namespace, a kind
//! discriminator, the full path hierarchy, and the stable source key. The
//! pump's mandate is ZERO LOSS: whatever the target cannot accept as a native
//! argument is ENCODED into the payload so a re-import recovers it.
//!
//! ## The encoding (versioned, self-describing, recoverable)
//!
//! The drawer's stored `content` is:
//!
//! ```text
//! <verbatim note body>
//!
//! <!-- MOOT-ENVELOPE v1
//! { ...canonical JSON of the unmappable fields... }
//! MOOT-ENVELOPE -->
//! ```
//!
//! - The body above the marker is the note's verbatim `flattened_body`, so a
//!   MemPalace `search` (which embeds the whole content) still indexes the
//!   real prose and a human sees their note first.
//! - The marker is an HTML comment so Markdown viewers hide it; MemPalace
//!   stores content verbatim, so it survives byte-for-byte.
//! - The JSON is canonical (sorted keys, serde_json default — no slash
//!   escaping), matching Swift's `.sortedKeys`/`.withoutEscapingSlashes`, so
//!   both ports emit byte-identical envelopes.
//! - `v1` is a format version; decode refuses a version it does not know.

use crate::note_ir::{FactIR, NoteIR, OccurredAt, SourceRef, WikiLink};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Current envelope format version. Bumped only when the payload shape
/// changes; [`decode`] refuses any other version.
pub const FORMAT_VERSION: i64 = 1;

/// The opening marker prefix (carries the version digits, then a newline).
const OPEN_MARKER_PREFIX: &str = "<!-- MOOT-ENVELOPE v";
/// The closing marker.
const CLOSE_MARKER: &str = "MOOT-ENVELOPE -->";

/// The recoverable record of a `NoteIR`'s fields that MemPalace's `add_drawer`
/// native argument surface cannot carry. Serialized into the drawer content as
/// a fenced, versioned, canonical-JSON block. Field names match the Swift
/// `PalaceEnvelopePayload` Codable keys verbatim (cross-language conformance).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PalaceEnvelopePayload {
    /// `NoteIR.stable_source_key` — the idempotency key (redundant with the
    /// native `source_file` arg, carried so re-import is exact).
    #[serde(rename = "stableSourceKey")]
    pub stable_source_key: String,

    /// `NoteIR.frontmatter` — the flat provenance/anchor map.
    pub frontmatter: HashMap<String, String>,

    /// `NoteIR.links` — wikilinks (MemPalace has no wikilink concept).
    pub links: Vec<WikiLink>,

    /// `NoteIR.tags` — `#tags` (no native tag arg).
    pub tags: Vec<String>,

    /// `NoteIR.original_path` — the joined hierarchy back-compat view.
    #[serde(rename = "originalPath")]
    pub original_path: String,

    /// `NoteIR.origin_date` — when the content occurred.
    #[serde(rename = "originDate", default, skip_serializing_if = "Option::is_none")]
    pub origin_date: Option<OccurredAt>,

    /// `NoteIR.source` — an attachment ref.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceRef>,

    /// `NoteIR.moot_id` — the substrate lineage UUID. Serialized uppercase to
    /// match Foundation's `UUID` (and the Swift envelope), via the shared
    /// note_ir serializer.
    #[serde(
        rename = "mootID",
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "crate::note_ir::serialize_uuid_uppercase_pub"
    )]
    pub moot_id: Option<uuid::Uuid>,

    /// `NoteIR.facts` — KG facts (ride the envelope, never dropped).
    pub facts: Vec<FactIR>,

    /// `NoteIR.path_components` — the full ordered hierarchy.
    #[serde(rename = "pathComponents")]
    pub path_components: Vec<String>,

    /// `NoteIR.scope` — the source-tool scoping-id namespace. `BTreeMap` so
    /// serialization is deterministic (matches Swift `.sortedKeys`).
    pub scope: std::collections::BTreeMap<String, String>,

    /// `NoteIR.kind` — the entry discriminator.
    pub kind: String,
}

impl PalaceEnvelopePayload {
    /// Build the payload from a `NoteIR`, copying every field the native
    /// `add_drawer` arg surface cannot carry (plus the redundant
    /// `stable_source_key`/`path_components` for a self-sufficient record).
    pub fn from_note(note: &NoteIR) -> Self {
        Self {
            stable_source_key: note.stable_source_key.clone(),
            frontmatter: note.frontmatter.clone(),
            links: note.links.clone(),
            tags: note.tags.clone(),
            original_path: note.original_path.clone(),
            origin_date: note.origin_date.clone(),
            source: note.source.clone(),
            moot_id: note.moot_id,
            facts: note.facts.clone(),
            path_components: note.path_components.clone(),
            scope: note.scope.clone(),
            kind: note.kind.clone(),
        }
    }
}

/// Errors raised while decoding an envelope from stored drawer content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvelopeDecodeError {
    /// The content carried an open marker whose version is unknown. Carries
    /// the offending version (loud failure, never a silent drop).
    UnsupportedVersion(i64),
    /// The open marker was present but the close marker was not.
    Unterminated,
    /// The bytes between the markers were not valid envelope JSON.
    MalformedJson(String),
}

impl std::fmt::Display for EnvelopeDecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EnvelopeDecodeError::UnsupportedVersion(v) => {
                write!(f, "unsupported envelope version {v}")
            }
            EnvelopeDecodeError::Unterminated => write!(f, "unterminated envelope"),
            EnvelopeDecodeError::MalformedJson(m) => write!(f, "malformed envelope JSON: {m}"),
        }
    }
}

impl std::error::Error for EnvelopeDecodeError {}

/// One decoded drawer: the verbatim body with the envelope stripped, plus the
/// recovered payload (`None` when the content carried no envelope).
#[derive(Debug, Clone, PartialEq)]
pub struct Decoded {
    /// The note prose with the fenced envelope removed and surrounding
    /// whitespace trimmed.
    pub body: String,
    /// The recovered unmappable-field record, or `None` when absent.
    pub payload: Option<PalaceEnvelopePayload>,
}

/// Fold a note's body and its unmappable fields into the drawer content
/// MemPalace will store: the verbatim body, a blank line, then the fenced
/// envelope. Inverse of [`decode`].
pub fn encode(body: &str, payload: &PalaceEnvelopePayload) -> Result<String, EnvelopeDecodeError> {
    let json = canonical_json(payload)?;
    Ok(format!(
        "{body}\n\n{OPEN_MARKER_PREFIX}{FORMAT_VERSION}\n{json}\n{CLOSE_MARKER}"
    ))
}

/// One decoded four-noun envelope: the verbatim body with the envelope
/// stripped, plus the recovered per-noun field map (empty when the content
/// carried no envelope). Mirrors Swift `PalacePayloadEnvelope.DecodedFields`.
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedFields {
    /// The native text with the fenced envelope removed and surrounding
    /// whitespace trimmed.
    pub body: String,
    /// The recovered per-noun envelope-field map (empty when none present).
    pub fields: std::collections::BTreeMap<String, serde_json::Value>,
}

/// Fold a `PalaceItem`'s body and its per-noun envelope-field map into the
/// string MemPalace stores for whichever native arg carries the noun's text.
/// The ONE canonical envelope for ALL four nouns — the same versioned
/// `MOOT-ENVELOPE v1` marker as [`encode`]. When `fields` is empty the body is
/// returned UNCHANGED (no empty envelope), mirroring the per-noun mapping's
/// "ride only when there is something to carry" rule and the Swift
/// `encodeFields`. Bytes match Swift for identical input.
pub fn encode_fields(
    body: &str,
    fields: &std::collections::BTreeMap<String, serde_json::Value>,
) -> Result<String, EnvelopeDecodeError> {
    if fields.is_empty() {
        return Ok(body.to_owned());
    }
    let json = canonical_fields_json(fields)?;
    Ok(format!(
        "{body}\n\n{OPEN_MARKER_PREFIX}{FORMAT_VERSION}\n{json}\n{CLOSE_MARKER}"
    ))
}

/// Split a stored four-noun string back into its body and recovered field map.
/// The inverse of [`encode_fields`]. Content with no open marker decodes as
/// `{ body: content, fields: {} }`. Mirrors the Swift `decodeFields`.
pub fn decode_fields(content: &str) -> Result<DecodedFields, EnvelopeDecodeError> {
    let open_idx = match content.find(OPEN_MARKER_PREFIX) {
        Some(i) => i,
        None => {
            return Ok(DecodedFields {
                body: content.to_owned(),
                fields: std::collections::BTreeMap::new(),
            })
        }
    };
    let after_prefix = &content[open_idx + OPEN_MARKER_PREFIX.len()..];
    let line_end = after_prefix
        .find('\n')
        .ok_or(EnvelopeDecodeError::Unterminated)?;
    let version_token = after_prefix[..line_end].trim();
    let version: i64 = version_token.parse().map_err(|_| {
        EnvelopeDecodeError::MalformedJson(format!(
            "envelope version token '{version_token}' is not an integer"
        ))
    })?;
    if version != FORMAT_VERSION {
        return Err(EnvelopeDecodeError::UnsupportedVersion(version));
    }
    let json_start = open_idx + OPEN_MARKER_PREFIX.len() + line_end + 1;
    let close_rel = content[json_start..]
        .find(CLOSE_MARKER)
        .ok_or(EnvelopeDecodeError::Unterminated)?;
    let json_slice = content[json_start..json_start + close_rel].trim();
    let fields: std::collections::BTreeMap<String, serde_json::Value> =
        serde_json::from_str(json_slice)
            .map_err(|e| EnvelopeDecodeError::MalformedJson(e.to_string()))?;
    let body = content[..open_idx].trim().to_owned();
    Ok(DecodedFields { body, fields })
}

/// Encode a per-noun envelope-field map as canonical JSON: sorted keys (the
/// `BTreeMap` is already ordered, and serde_json re-emits in that order), no
/// slash escaping — matching Swift `.sortedKeys`/`.withoutEscapingSlashes`, so
/// both ports emit byte-identical four-noun envelopes.
fn canonical_fields_json(
    fields: &std::collections::BTreeMap<String, serde_json::Value>,
) -> Result<String, EnvelopeDecodeError> {
    // Round-trip through a Value so nested object keys are also BTree-sorted,
    // matching the typed-payload canonical_json path and the Swift output.
    let value = serde_json::to_value(fields)
        .map_err(|e| EnvelopeDecodeError::MalformedJson(e.to_string()))?;
    serde_json::to_string(&value).map_err(|e| EnvelopeDecodeError::MalformedJson(e.to_string()))
}

/// Split stored drawer content back into its body and recovered payload.
/// Content with no open marker decodes as `{ body: content, payload: None }`
/// — a foreign drawer is read as plain prose, never an error.
pub fn decode(content: &str) -> Result<Decoded, EnvelopeDecodeError> {
    let open_idx = match content.find(OPEN_MARKER_PREFIX) {
        Some(i) => i,
        None => {
            return Ok(Decoded {
                body: content.to_owned(),
                payload: None,
            })
        }
    };
    // Version digits run from after the prefix to the end of the marker line.
    let after_prefix = &content[open_idx + OPEN_MARKER_PREFIX.len()..];
    let line_end = after_prefix
        .find('\n')
        .ok_or(EnvelopeDecodeError::Unterminated)?;
    let version_token = after_prefix[..line_end].trim();
    let version: i64 = version_token
        .parse()
        .map_err(|_| EnvelopeDecodeError::MalformedJson(format!(
            "envelope version token '{version_token}' is not an integer"
        )))?;
    if version != FORMAT_VERSION {
        return Err(EnvelopeDecodeError::UnsupportedVersion(version));
    }
    // JSON runs from after the marker line to before the close marker.
    let json_start = open_idx + OPEN_MARKER_PREFIX.len() + line_end + 1;
    let close_rel = content[json_start..]
        .find(CLOSE_MARKER)
        .ok_or(EnvelopeDecodeError::Unterminated)?;
    let json_slice = content[json_start..json_start + close_rel].trim();
    let payload: PalaceEnvelopePayload = serde_json::from_str(json_slice)
        .map_err(|e| EnvelopeDecodeError::MalformedJson(e.to_string()))?;
    let body = content[..open_idx].trim().to_owned();
    Ok(Decoded {
        body,
        payload: Some(payload),
    })
}

/// Reconstruct a full `NoteIR` from a fetched drawer's content. When no
/// envelope is present, a minimal note is built from the prose with
/// `stable_source_key = fallback_key`.
pub fn reconstruct_note(content: &str, fallback_key: &str) -> Result<NoteIR, EnvelopeDecodeError> {
    use crate::note_ir::Block;
    let decoded = decode(content)?;
    match decoded.payload {
        None => Ok(NoteIR::new(
            fallback_key,
            vec![Block::markdown(decoded.body)],
            HashMap::new(),
            Vec::new(),
            Vec::new(),
            "",
            None,
            None,
        )),
        Some(p) => {
            let mut note = NoteIR::with_moot_id(
                p.stable_source_key,
                vec![Block::markdown(decoded.body)],
                p.frontmatter,
                p.links,
                p.tags,
                p.original_path,
                p.origin_date,
                p.source,
                p.moot_id,
            );
            note.facts = p.facts;
            note.path_components = p.path_components;
            note.scope = p.scope;
            note.kind = p.kind;
            Ok(note)
        }
    }
}

/// Encode the payload as canonical JSON: serde_json serializes struct fields
/// in declaration order, but the cross-language anchor requires KEY-SORTED
/// output (matching Swift `.sortedKeys`). We therefore round-trip through a
/// `serde_json::Value` and re-serialize, whose object maps are BTree-backed
/// and thus sorted — and serde_json never escapes '/'.
fn canonical_json(payload: &PalaceEnvelopePayload) -> Result<String, EnvelopeDecodeError> {
    let value: serde_json::Value = serde_json::to_value(payload)
        .map_err(|e| EnvelopeDecodeError::MalformedJson(e.to_string()))?;
    serde_json::to_string(&value).map_err(|e| EnvelopeDecodeError::MalformedJson(e.to_string()))
}
