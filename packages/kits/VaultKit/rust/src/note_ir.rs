//! NoteIR and companion types — the language-neutral IR boundary contract.
//!
//! `NoteIR` is the pivot of the whole bridge: every adapter maps vault
//! files ⇄ `NoteIR`, and `DrawerMapping` maps `NoteIR` ⇄ a substrate
//! `Drawer` (+ `.references` tunnels). Because it is the shared contract
//! for future adapters and a future non-Swift producer, its shape is
//! frozen-by-convention: flat, JSON-serializable (all fields are
//! primitive or collections of primitives), no language-specific types.
//!
//! Per ADR-VAULTKIT-001 (f): `Block.kind` is an **open string vocabulary**
//! rather than a closed enum so an outliner adapter can introduce a new
//! block kind without reshaping `NoteIR`. The degenerate case — a single
//! block whose `kind` is `"markdown"` and whose `text` is the whole page
//! — represents a flat page, which is exactly what the Obsidian adapter
//! emits and consumes in V1.

use serde::{Deserialize, Serialize};

// ## Canonical JSON (cross-language conformance contract)
//
// All IR types serialize to the Swift Codable key names verbatim —
// camelCase via explicit `rename` attributes where the Rust field name
// disagrees (notably `mootID`, which `rename_all = "camelCase"` would
// wrongly emit as `mootId`). Optional fields omit their key when `None`
// (Swift synthesized `encodeIfPresent` omits nil keys). The four
// full-fidelity fields decode with defaults when absent so JSON produced
// before the VK_IR_01 extension still parses. Deterministic key ORDER is
// the envelope's job: `CorpusDocument::canonical_json` applies a recursive
// `sort_keys` pass before serialization, matching Swift's `.sortedKeys`.

/// One ordered fragment of a note's body.
///
/// `kind` is an open string vocabulary; `"markdown"` is the V1 default and
/// the only kind the Obsidian adapter produces.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Block {
    /// Open-vocabulary block type. `"markdown"` is the V1 Obsidian shape.
    pub kind: String,

    /// Verbatim block text. Preserved unchanged across round-trips so
    /// `to_ir(from_ir(x)) == x` holds for the fields Obsidian represents.
    pub text: String,
}

impl Block {
    /// Construct a `Block`. `kind` defaults to `"markdown"` when called
    /// via `Block::markdown(text)` — the V1 Obsidian convenience.
    pub fn new(kind: impl Into<String>, text: impl Into<String>) -> Self {
        Self { kind: kind.into(), text: text.into() }
    }

    /// Convenience: a plain `"markdown"` block.
    pub fn markdown(text: impl Into<String>) -> Self {
        Self::new("markdown", text)
    }
}

/// A parsed Obsidian-style wikilink.
///
/// Obsidian writes links as `[[Target]]` or `[[Target|Alias]]`. The `raw`
/// field preserves the exact text between the brackets so a re-render is
/// byte-faithful; `target` and `alias` are the parsed view used by
/// `DrawerMapping` to build `.references` tunnels.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WikiLink {
    /// The link target — the note name to the left of any pipe.
    pub target: String,

    /// The display alias to the right of a `|`, or `None` when the link
    /// is a bare `[[Target]]`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alias: Option<String>,

    /// The exact text between the `[[` and `]]`, preserved verbatim so
    /// emission round-trips. This is the string carried into a tunnel's
    /// `label` on import.
    pub raw: String,
}

impl WikiLink {
    pub fn new(target: impl Into<String>, alias: Option<String>, raw: impl Into<String>) -> Self {
        Self { target: target.into(), alias, raw: raw.into() }
    }
}

/// A pointer to an external source artifact — a file reference, never
/// the bytes.
///
/// Per ADR-VAULTKIT-001 (b), VaultKit references attachments by path +
/// content hash rather than copying blobs into the substrate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceRef {
    /// Filesystem (or vault-relative) path of the referenced artifact.
    pub path: String,

    /// Content hash of the artifact. Format is adapter-defined; the
    /// Obsidian adapter does not populate this in V1.
    #[serde(rename = "contentHash")]
    pub content_hash: String,

    /// MIME type of the artifact, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime: Option<String>,

    /// Size of the artifact in bytes, when known.
    #[serde(rename = "byteSize", default, skip_serializing_if = "Option::is_none")]
    pub byte_size: Option<i64>,
}

impl SourceRef {
    pub fn new(
        path: impl Into<String>,
        content_hash: impl Into<String>,
        mime: Option<String>,
        byte_size: Option<i64>,
    ) -> Self {
        Self { path: path.into(), content_hash: content_hash.into(), mime, byte_size }
    }
}

/// An ISO8601 instant marking when a note's content *occurred* or was
/// authored in the world — distinct from substrate capture time.
///
/// Serialized as the ISO8601 string itself (not a `SystemTime`) so the
/// boundary is language-neutral. The string format matches LocusKit's
/// `LKISO8601` (`.withInternetDateTime` + `.withFractionalSeconds`) so
/// the same instant round-trips identically through the substrate's date
/// columns.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OccurredAt {
    /// The instant as an ISO8601 string in LocusKit's canonical format,
    /// e.g. `"2024-03-04T05:06:07.000Z"`.
    pub iso8601: String,
}

impl OccurredAt {
    pub fn new(iso8601: impl Into<String>) -> Self {
        Self { iso8601: iso8601.into() }
    }
}

/// One subject / predicate / object assertion riding a note.
///
/// `FactIR` is the IR-level representation of a knowledge-graph fact —
/// a KG fact in our substrate, a graph relation (entity → relationship →
/// entity) in programmatic external memory tools. Per ADR-007 Decision 1,
/// the full-fidelity IR carries facts as first-class data so a
/// programmatic exporter's graph layer survives the interchange boundary.
/// Mapping facts to substrate nouns is adapter/bridge territory
/// (VK-ADAPT-01+); the IR only guarantees no fact is lost in transit.
/// Mirrors Swift `FactIR`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FactIR {
    /// The assertion's subject — an entity name or identifier, verbatim
    /// from the producing tool.
    pub subject: String,

    /// The relationship between subject and object.
    pub predicate: String,

    /// The assertion's object — an entity name, identifier, or literal.
    pub object: String,

    /// Start of the assertion's validity window, when known, as an
    /// ISO8601 string in LocusKit's canonical format (consistent with
    /// `OccurredAt.iso8601`). `None` means "valid since unknown/always".
    #[serde(rename = "validFrom", default, skip_serializing_if = "Option::is_none")]
    pub valid_from: Option<String>,

    /// End of the assertion's validity window, when known, as an ISO8601
    /// string. `None` means "still valid / no recorded end".
    #[serde(rename = "validTo", default, skip_serializing_if = "Option::is_none")]
    pub valid_to: Option<String>,

    /// Producer-reported confidence in [0, 1], when the source tool
    /// scores its assertions. `None` means unscored.
    /// `f64` is why `FactIR` (and therefore `NoteIR`) derives `PartialEq`
    /// but not `Eq` — float equality is partial by definition.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
}

impl FactIR {
    /// Construct a fact with no validity window and no confidence —
    /// the bare s/p/o triple.
    pub fn new(
        subject: impl Into<String>,
        predicate: impl Into<String>,
        object: impl Into<String>,
    ) -> Self {
        Self {
            subject: subject.into(),
            predicate: predicate.into(),
            object: object.into(),
            valid_from: None,
            valid_to: None,
            confidence: None,
        }
    }
}

/// The JSON-absent default for `NoteIR.kind` — the discriminator value
/// for an ordinary note (matches the Swift init default).
fn default_kind() -> String {
    "note".to_owned()
}

/// The canonical intermediate representation of one note.
///
/// `NoteIR` is the pivot of the bridge: every adapter maps vault files
/// ⇄ `NoteIR`, and `DrawerMapping` maps `NoteIR` ⇄ a substrate `Drawer`
/// (+ `.references` tunnels). Its shape is frozen-by-convention — flat,
/// no language-specific boundary types. See ADR-VAULTKIT-001 (f).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NoteIR {
    /// The stable identity of this note across re-imports. For the Obsidian
    /// adapter this is the vault-relative path without the `.md` extension.
    /// `DrawerMapping` uses this as the FNV-1a lineage fallback; `moot_id`
    /// frontmatter takes priority, and byte-identical active content skips
    /// supersession without writing.
    #[serde(rename = "stableSourceKey")]
    pub stable_source_key: String,

    /// Ordered body blocks. A single `"markdown"` block is a whole flat
    /// page — the V1 Obsidian shape.
    pub body: Vec<Block>,

    /// Parsed YAML frontmatter as a flat string map. Carries provenance,
    /// anchors, wing/room placement, and the origin date on export, and is
    /// the source of the same on import.
    pub frontmatter: std::collections::HashMap<String, String>,

    /// Parsed wikilinks. Become `.references` tunnels on import; are
    /// produced from `.references` tunnels on export.
    pub links: Vec<WikiLink>,

    /// Parsed `#tags` from the body.
    pub tags: Vec<String>,

    /// The note's folder path within the vault (vault-relative directory).
    /// Mirrors / is mirrored by the drawer's wing/room.
    #[serde(rename = "originalPath")]
    pub original_path: String,

    /// When the note's content occurred/was authored, when the frontmatter
    /// carried a `created:` or `date:` key.
    #[serde(rename = "originDate", default, skip_serializing_if = "Option::is_none")]
    pub origin_date: Option<OccurredAt>,

    /// Optional pointer to an external source artifact (attachment).
    /// `None` for plain notes; populated by producers that carry attachments.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceRef>,

    /// The substrate lineage UUID from the `moot_id` frontmatter key.
    ///
    /// When present (populated by `ObsidianAdapter::to_ir` or set explicitly
    /// by `DrawerMapping::note_ir_from` on export), this UUID is used as the
    /// `lineage_id` for the capture frame on re-import — making the note's
    /// identity rename-safe. The FNV derivation from `stable_source_key` is
    /// the fallback when this is `None`.
    ///
    /// Decision B1: `moot_id` carries `drawer.lineage_id` (the STABLE UUID),
    /// not `drawer.id` (which the supersession cascade re-mints on every
    /// capture). This is the cross-language conformance anchor for identity.
    /// Mirrors Swift `NoteIR.mootID: UUID?`.
    ///
    /// Serializes UPPERCASE-hyphenated (custom serializer) because
    /// Foundation's `UUID` encodes uppercase while the `uuid` crate's
    /// `Serialize` emits lowercase — byte-equality of the canonical JSON
    /// requires one casing. Decoding is case-insensitive in both ports.
    #[serde(
        rename = "mootID",
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "serialize_uuid_uppercase"
    )]
    pub moot_id: Option<uuid::Uuid>,

    /// Subject / predicate / object assertions carried by this note.
    /// Empty for plain Markdown vaults (Obsidian emits none); populated
    /// by programmatic-tool adapters whose source has a graph layer.
    /// Full-fidelity field per ADR-007 Decision 1. Mirrors Swift
    /// `NoteIR.facts: [FactIR]`. Decodes to `[]` when the key is absent
    /// (pre-extension JSON).
    #[serde(default)]
    pub facts: Vec<FactIR>,

    /// The full source hierarchy as ordered components (ancestor → leaf),
    /// e.g. `["projects", "alpha", "notes"]`. `original_path` remains the
    /// joined back-compat view, but components are the authoritative
    /// representation — the substrate mapping may still flatten to the
    /// leaf, but the IR is not the lossy layer. Mirrors Swift
    /// `NoteIR.pathComponents`. Decodes to `[]` when absent.
    #[serde(rename = "pathComponents", default)]
    pub path_components: Vec<String>,

    /// Generic namespace map for source-tool scoping dimensions
    /// (e.g. per-user / per-agent / per-session ids). Key names are
    /// tool-defined — the IR deliberately does not hardcode any
    /// vocabulary. Empty for Obsidian. `BTreeMap` (not `HashMap`) so
    /// iteration — and therefore any serialization path — is
    /// deterministic by construction. Mirrors Swift `NoteIR.scope`.
    /// Decodes to `{}` when absent.
    #[serde(default)]
    pub scope: std::collections::BTreeMap<String, String>,

    /// Discriminator distinguishing what this entry IS. Open string
    /// vocabulary (same rationale as `Block.kind`); well-known values
    /// are `"note"` (default), `"fact"`, and `"journal"`. Mirrors Swift
    /// `NoteIR.kind`. Decodes to `"note"` when absent.
    #[serde(default = "default_kind")]
    pub kind: String,
}

/// Serialize an optional UUID as its UPPERCASE hyphenated string, matching
/// Foundation's `UUID` Codable output. Only reached when the option is
/// `Some` (the field is skipped entirely when `None`).
fn serialize_uuid_uppercase<S: serde::Serializer>(
    id: &Option<uuid::Uuid>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    match id {
        Some(u) => serializer.serialize_str(&u.hyphenated().to_string().to_uppercase()),
        None => serializer.serialize_none(),
    }
}

/// Public re-export of the uppercase-UUID serializer so sibling modules (the
/// outbound pump's `PalaceEnvelopePayload`) emit `moot_id` with the same
/// Foundation-matching casing as `NoteIR`. Same behavior as the private
/// `serialize_uuid_uppercase` above.
pub fn serialize_uuid_uppercase_pub<S: serde::Serializer>(
    id: &Option<uuid::Uuid>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serialize_uuid_uppercase(id, serializer)
}

impl NoteIR {
    pub fn new(
        stable_source_key: impl Into<String>,
        body: Vec<Block>,
        frontmatter: std::collections::HashMap<String, String>,
        links: Vec<WikiLink>,
        tags: Vec<String>,
        original_path: impl Into<String>,
        origin_date: Option<OccurredAt>,
        source: Option<SourceRef>,
    ) -> Self {
        Self::with_moot_id(stable_source_key, body, frontmatter, links, tags, original_path, origin_date, source, None)
    }

    /// Construct a `NoteIR` with an explicit `moot_id`. Used by
    /// `ObsidianAdapter::to_ir` when the frontmatter carries `moot_id` and by
    /// `DrawerMapping::note_ir_from` on export.
    pub fn with_moot_id(
        stable_source_key: impl Into<String>,
        body: Vec<Block>,
        frontmatter: std::collections::HashMap<String, String>,
        links: Vec<WikiLink>,
        tags: Vec<String>,
        original_path: impl Into<String>,
        origin_date: Option<OccurredAt>,
        source: Option<SourceRef>,
        moot_id: Option<uuid::Uuid>,
    ) -> Self {
        Self {
            stable_source_key: stable_source_key.into(),
            body,
            frontmatter,
            links,
            tags,
            original_path: original_path.into(),
            origin_date,
            source,
            moot_id,
            // Full-fidelity fields (VK_IR_01) start at their documented
            // defaults; producers that carry them set the fields directly.
            // Constructor arity is deliberately unchanged so every
            // pre-extension call site compiles unmodified.
            facts: Vec::new(),
            path_components: Vec::new(),
            scope: std::collections::BTreeMap::new(),
            kind: default_kind(),
        }
    }

    /// The note body flattened to a single string — blocks joined in order
    /// with newlines. This is the verbatim content `DrawerMapping` files
    /// into a drawer's `content` field (and what export splits back out).
    /// Matches Swift `NoteIR.flattenedBody`.
    pub fn flattened_body(&self) -> String {
        self.body.iter().map(|b| b.text.as_str()).collect::<Vec<_>>().join("\n")
    }
}
