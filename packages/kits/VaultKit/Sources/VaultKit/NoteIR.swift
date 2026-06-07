import Foundation

// VaultKit — the canonical intermediate representation.
//
// `NoteIR` is the language-neutral contract that every vault adapter
// (Obsidian today; Joplin / Bear / Logseq / plain-Markdown later) and
// every non-Swift content producer (the Feature-B archive/email engine,
// which may be Rust or Python-via-Rust) emits and consumes. It is the
// one decision in this kit that is expensive to reverse, so its shape is
// deliberately serializable JSON: every type is `Codable`, fields are
// flat, and no boundary type uses a Swift-only enum with associated
// values. The Swift types here are the V1 *home* of the contract, not
// the contract itself — a non-Swift producer round-trips the same IR
// through a mechanical port.
//
// ## Bidirectional identity (Decision cp-vault-bidir)
//
// `NoteIR.mootID` carries the STABLE lineage UUID from the substrate —
// the `lineageID` of the originating drawer, not `drawer.id` (which the
// supersession cascade re-mints). On export, `DrawerMapping.noteIR`
// writes `moot_id: <lineageID>` into frontmatter and sets this field. On
// import, `ObsidianAdapter.toIR` reads `moot_id` from frontmatter and
// sets this field. `DrawerMapping.makeCaptureFrame` uses it as the
// frame's `lineageID` so a re-import of an exported note maps to the
// same substrate lineage — even after the human renames the file
// (filename is no longer the identity anchor; `moot_id` is).

// MARK: - Block

/// One ordered fragment of a note's body.
///
/// `kind` is an open string vocabulary rather than a closed Swift enum
/// precisely so the boundary stays language-neutral and so an outliner
/// adapter (Logseq, Roam) can introduce a new block kind later without
/// reshaping `NoteIR`. The degenerate case — a single block whose `kind`
/// is `"markdown"` and whose `text` is the whole page — represents a
/// flat page, which is exactly what the Obsidian adapter emits and
/// consumes in V1.
public struct Block: Codable, Sendable, Equatable {

    /// Open-vocabulary block type. `"markdown"` is the V1 default and
    /// the only kind the Obsidian adapter produces.
    public var kind: String

    /// Verbatim block text. Preserved unchanged across round-trips so
    /// `toIR(fromIR(x)) == x` holds for the fields Obsidian represents.
    public var text: String

    public init(kind: String = "markdown", text: String) {
        self.kind = kind
        self.text = text
    }
}

// MARK: - WikiLink

/// A parsed Obsidian-style wikilink.
///
/// Obsidian writes links as `[[Target]]` or `[[Target|Alias]]`. The
/// `raw` field preserves the exact text between the brackets so a
/// re-render is byte-faithful; `target` and `alias` are the parsed
/// view used by `DrawerMapping` to build `.references` tunnels.
public struct WikiLink: Codable, Sendable, Equatable {

    /// The link target — the note name to the left of any pipe.
    public var target: String

    /// The display alias to the right of a `|`, or nil when the link
    /// is a bare `[[Target]]`.
    public var alias: String?

    /// The exact text between the `[[` and `]]`, preserved verbatim so
    /// emission round-trips. This is the string carried into a tunnel's
    /// `label` on import.
    public var raw: String

    public init(target: String, alias: String? = nil, raw: String) {
        self.target = target
        self.alias = alias
        self.raw = raw
    }
}

// MARK: - SourceRef

/// A pointer to an external source artifact — a file reference, never
/// the bytes.
///
/// Per ADR-VAULTKIT-001 (b), VaultKit references attachments by path +
/// content hash rather than copying blobs into the substrate. Promotion
/// of `SourceRef` to a substrate primitive is a future Tier-1 mission
/// (Stream bp); here it is a kit-level value type that rides frontmatter.
public struct SourceRef: Codable, Sendable, Equatable {

    /// Filesystem (or vault-relative) path of the referenced artifact.
    public var path: String

    /// Content hash of the artifact, so a re-import can detect drift
    /// without re-reading the bytes. Format is adapter-defined; the
    /// Obsidian adapter does not populate this in V1 (attachments are
    /// out of scope for the core), but the field is on the boundary
    /// from day one so a producer that does carry attachments needs no
    /// reshape.
    public var contentHash: String

    /// MIME type of the artifact, when known.
    public var mime: String?

    /// Size of the artifact in bytes, when known.
    public var byteSize: Int?

    public init(path: String, contentHash: String, mime: String? = nil, byteSize: Int? = nil) {
        self.path = path
        self.contentHash = contentHash
        self.mime = mime
        self.byteSize = byteSize
    }
}

// MARK: - OccurredAt

/// An ISO8601 instant marking when a note's content *occurred* or was
/// authored in the world — distinct from substrate capture time.
///
/// Serialized as the ISO8601 string itself (not a `Date`) so the JSON
/// boundary is language-neutral. The string format matches LocusKit's
/// `LKISO8601` (`.withInternetDateTime` + `.withFractionalSeconds`) so
/// the same instant round-trips identically through the substrate's
/// date columns. A substrate-level origin-date field is out of scope for
/// this mission; here `OccurredAt` rides note frontmatter only.
public struct OccurredAt: Codable, Sendable, Equatable {

    /// The instant as an ISO8601 string in LocusKit's canonical format.
    public var iso8601: String

    public init(iso8601: String) {
        self.iso8601 = iso8601
    }

    /// Construct from a `Date`, formatting with LocusKit's canonical
    /// ISO8601 representation so substrate and vault agree byte-for-byte.
    public init(date: Date) {
        self.iso8601 = OccurredAt.makeFormatter().string(from: date)
    }

    /// Parse back to a `Date`, or nil when the stored string is not a
    /// valid ISO8601 instant in the canonical format.
    public var date: Date? {
        OccurredAt.makeFormatter().date(from: iso8601)
    }

    /// Build LocusKit's canonical ISO8601 formatter. Returned fresh per
    /// call rather than cached in a `static let`, because
    /// `ISO8601DateFormatter` is not `Sendable`; a per-call instance keeps
    /// `OccurredAt` concurrency-safe under Swift 6 strict concurrency with
    /// no shared mutable global state. Options match LocusKit's `LKISO8601`
    /// (`DrawerStore.swift`): internet date-time with fractional seconds,
    /// so a `Date` formatted here is parsed identically by the substrate
    /// and vice versa.
    static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

// MARK: - NoteIR

/// The canonical intermediate representation of one note.
///
/// `NoteIR` is the pivot of the whole bridge: every adapter maps
/// vault files ⇄ `NoteIR`, and `DrawerMapping` maps `NoteIR` ⇄ a
/// substrate `Drawer` (+ `.references` tunnels). Because it is the
/// shared contract for future adapters and a future non-Swift producer,
/// its shape is frozen-by-convention: flat, `Codable`, no Swift-only
/// boundary types. See ADR-VAULTKIT-001 (f).
public struct NoteIR: Codable, Sendable, Equatable {

    /// The stable identity of this note across re-imports. For the
    /// Obsidian adapter this is the vault-relative path without the
    /// `.md` extension. `DrawerMapping` derives a deterministic
    /// `lineageID` from this key so a re-import supersedes the existing
    /// drawer rather than duplicating it (idempotency).
    public var stableSourceKey: String

    /// Ordered body blocks. A single `"markdown"` block is a whole
    /// flat page — the V1 Obsidian shape.
    public var body: [Block]

    /// Parsed YAML frontmatter as a flat string map. Carries provenance,
    /// anchors, wing/room placement, and the origin date on export, and
    /// is the source of the same on import.
    public var frontmatter: [String: String]

    /// Parsed wikilinks. Become `.references` tunnels on import; are
    /// produced from `.references` tunnels on export.
    public var links: [WikiLink]

    /// Parsed `#tags` from the body.
    public var tags: [String]

    /// The note's folder path within the vault (vault-relative
    /// directory). Mirrors / is mirrored by the drawer's wing/room.
    public var originalPath: String

    /// When the note's content occurred/was authored, when the
    /// frontmatter carried a `created:` or `date:` key. Rides
    /// frontmatter; not a substrate column.
    public var originDate: OccurredAt?

    /// Optional pointer to an external source artifact (attachment).
    /// nil for plain notes; populated by producers that carry
    /// attachments. Drives the `.hasAttachments` feature flag on import.
    public var source: SourceRef?

    /// The substrate lineage UUID of the originating drawer, when known.
    ///
    /// Set by `DrawerMapping.noteIR` on export (from `drawer.lineageID`)
    /// and by `ObsidianAdapter.toIR` on import (parsed from the `moot_id`
    /// frontmatter key). `DrawerMapping.makeCaptureFrame` uses this value
    /// as the import frame's `lineageID` so the substrate's supersession
    /// cascade maps the re-import to the same lineage even after a human
    /// renames the file. When absent (a note that was never exported by
    /// VaultKit), the stable-source-key FNV derivation is used as the
    /// lineage fallback — same as the original behaviour.
    public var mootID: UUID?

    public init(
        stableSourceKey: String,
        body: [Block],
        frontmatter: [String: String] = [:],
        links: [WikiLink] = [],
        tags: [String] = [],
        originalPath: String = "",
        originDate: OccurredAt? = nil,
        source: SourceRef? = nil,
        mootID: UUID? = nil
    ) {
        self.stableSourceKey = stableSourceKey
        self.body = body
        self.frontmatter = frontmatter
        self.links = links
        self.tags = tags
        self.originalPath = originalPath
        self.originDate = originDate
        self.source = source
        self.mootID = mootID
    }

    /// The note body flattened to a single string — blocks joined in
    /// order. This is the verbatim content `DrawerMapping` files into a
    /// drawer's `content` field (and what export splits back out).
    public var flattenedBody: String {
        body.map(\.text).joined(separator: "\n")
    }
}
