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

/// One ordered fragment of a note's body.
///
/// `kind` is an open string vocabulary; `"markdown"` is the V1 default and
/// the only kind the Obsidian adapter produces.
#[derive(Debug, Clone, PartialEq, Eq)]
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WikiLink {
    /// The link target — the note name to the left of any pipe.
    pub target: String,

    /// The display alias to the right of a `|`, or `None` when the link
    /// is a bare `[[Target]]`.
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceRef {
    /// Filesystem (or vault-relative) path of the referenced artifact.
    pub path: String,

    /// Content hash of the artifact. Format is adapter-defined; the
    /// Obsidian adapter does not populate this in V1.
    pub content_hash: String,

    /// MIME type of the artifact, when known.
    pub mime: Option<String>,

    /// Size of the artifact in bytes, when known.
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
#[derive(Debug, Clone, PartialEq, Eq)]
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

/// The canonical intermediate representation of one note.
///
/// `NoteIR` is the pivot of the bridge: every adapter maps vault files
/// ⇄ `NoteIR`, and `DrawerMapping` maps `NoteIR` ⇄ a substrate `Drawer`
/// (+ `.references` tunnels). Its shape is frozen-by-convention — flat,
/// no language-specific boundary types. See ADR-VAULTKIT-001 (f).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NoteIR {
    /// The stable identity of this note across re-imports. For the Obsidian
    /// adapter this is the vault-relative path without the `.md` extension.
    /// `DrawerMapping` derives a deterministic `lineage_id` from this key
    /// so a re-import supersedes the existing drawer rather than duplicating
    /// it (idempotency).
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
    pub original_path: String,

    /// When the note's content occurred/was authored, when the frontmatter
    /// carried a `created:` or `date:` key.
    pub origin_date: Option<OccurredAt>,

    /// Optional pointer to an external source artifact (attachment).
    /// `None` for plain notes; populated by producers that carry attachments.
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
    pub moot_id: Option<uuid::Uuid>,
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
