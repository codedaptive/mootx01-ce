import Foundation

// PalacePayloadEnvelope.swift — the lossless encoding scheme for NoteIR
// fields MemPalace's `add_drawer` cannot carry natively.
//
// ## Why an envelope exists
//
// MemPalace's `mempalace_add_drawer` accepts exactly: `wing`, `room`,
// `content`, and the optional metadata `source_file` + `added_by`. A
// `NoteIR` carries far more than that — frontmatter, wikilinks, an origin
// date, an attachment ref, a substrate lineage UUID, KG facts, tags, a
// scope namespace, a kind discriminator, the full path hierarchy, and the
// stable source key. The pump's mandate is ZERO LOSS: whatever the target
// cannot accept as a native argument is ENCODED into the payload so a
// re-import recovers it.
//
// The mappable fields (`wing`/`room` derived from `pathComponents`, the
// note body as `content`, the stable key as `source_file`) ride the native
// args; PalacePumpMapping handles those. THIS file owns the rest: the
// fields the native arg surface cannot express are serialized into a single
// fenced block appended to the drawer content.
//
// ## The encoding (versioned, self-describing, recoverable)
//
// The drawer's stored `content` is:
//
//     <verbatim note body>
//     \n
//     <!-- MOOT-ENVELOPE v1
//     { ...canonical JSON of the unmappable fields... }
//     MOOT-ENVELOPE -->
//
// - The body above the marker is the note's verbatim `flattenedBody`, so a
//   MemPalace `search` (which embeds the whole content) still indexes the
//   real prose, and a human reading the drawer sees their note first.
// - The marker is an HTML comment so it renders invisibly in any Markdown
//   viewer (MemPalace stores Markdown-ish prose) yet survives verbatim
//   storage byte-for-byte — MemPalace stores content unmodified (verified:
//   get_drawer returns `content` exactly as written).
// - The JSON is canonical (sorted keys, no slash escaping) so the Swift and
//   Rust ports emit byte-identical envelopes for the same `NoteIR` — the
//   cross-language conformance anchor for this codec.
// - `v1` is a format version: a future field addition bumps it, and decode
//   refuses a version it does not understand rather than silently dropping.
//
// ## What rides the envelope (the unmappable set)
//
// Enumerated against the `add_drawer` native arg surface. Every `NoteIR`
// field that is NOT (`body` → content, `pathComponents` → wing/room,
// `stableSourceKey` → source_file) is carried here:
//
//   frontmatter, links, tags, originDate, source, mootID, facts, scope,
//   kind, originalPath, stableSourceKey, pathComponents.
//
// `stableSourceKey` and `pathComponents` are encoded REDUNDANTLY (they also
// ride native args) so a re-import that reads ONLY the envelope reconstructs
// the full `NoteIR` without having to reverse-engineer wing/room back into a
// path or trust the lossy `source_file` round-trip. Redundancy is cheap and
// makes the envelope a complete, self-sufficient record.

/// The recoverable record of a `NoteIR`'s fields that MemPalace's
/// `add_drawer` native argument surface cannot carry. Serialized into the
/// drawer content as a fenced, versioned, canonical-JSON block by
/// ``PalacePayloadEnvelope`` so a re-import loses nothing.
///
/// Every field mirrors the `NoteIR` field of the same name. `Codable` with
/// canonical output; `Equatable` so the round-trip test asserts
/// `decode(encode(x)) == x`.
public struct PalaceEnvelopePayload: Codable, Sendable, Equatable {

    /// `NoteIR.stableSourceKey` — carried so a re-import recovers the exact
    /// idempotency key (redundant with the native `source_file` arg).
    public var stableSourceKey: String

    /// `NoteIR.frontmatter` — the flat provenance/anchor map. No native arg.
    public var frontmatter: [String: String]

    /// `NoteIR.links` — wikilinks. MemPalace has no wikilink concept.
    public var links: [WikiLink]

    /// `NoteIR.tags` — `#tags`. `add_drawer` carries no tag arg.
    public var tags: [String]

    /// `NoteIR.originalPath` — the joined hierarchy back-compat view.
    public var originalPath: String

    /// `NoteIR.originDate` — when the content occurred. No native arg.
    public var originDate: OccurredAt?

    /// `NoteIR.source` — an attachment ref. No native arg.
    public var source: SourceRef?

    /// `NoteIR.mootID` — the substrate lineage UUID. No native arg.
    public var mootID: UUID?

    /// `NoteIR.facts` — KG facts. MemPalace has its own KG, but the pump
    /// writes drawers; the facts ride the envelope so a re-import recovers
    /// them losslessly rather than dropping the graph layer.
    public var facts: [FactIR]

    /// `NoteIR.pathComponents` — the full ordered hierarchy (redundant with
    /// the native wing/room mapping, carried so re-import is exact).
    public var pathComponents: [String]

    /// `NoteIR.scope` — the source-tool scoping-id namespace. No native arg.
    public var scope: [String: String]

    /// `NoteIR.kind` — the entry discriminator (`note`/`fact`/`journal`).
    public var kind: String

    public init(
        stableSourceKey: String,
        frontmatter: [String: String],
        links: [WikiLink],
        tags: [String],
        originalPath: String,
        originDate: OccurredAt?,
        source: SourceRef?,
        mootID: UUID?,
        facts: [FactIR],
        pathComponents: [String],
        scope: [String: String],
        kind: String
    ) {
        self.stableSourceKey = stableSourceKey
        self.frontmatter = frontmatter
        self.links = links
        self.tags = tags
        self.originalPath = originalPath
        self.originDate = originDate
        self.source = source
        self.mootID = mootID
        self.facts = facts
        self.pathComponents = pathComponents
        self.scope = scope
        self.kind = kind
    }

    /// Build the payload from a `NoteIR`, copying every field the native
    /// `add_drawer` arg surface cannot carry (plus the redundant
    /// `stableSourceKey`/`pathComponents` for a self-sufficient record).
    public init(from note: NoteIR) {
        self.init(
            stableSourceKey: note.stableSourceKey,
            frontmatter: note.frontmatter,
            links: note.links,
            tags: note.tags,
            originalPath: note.originalPath,
            originDate: note.originDate,
            source: note.source,
            mootID: note.mootID,
            facts: note.facts,
            pathComponents: note.pathComponents,
            scope: note.scope,
            kind: note.kind
        )
    }
}

/// The codec that folds a ``PalaceEnvelopePayload`` into (and back out of) a
/// MemPalace drawer's `content`, and reconstructs a full `NoteIR` from a
/// fetched drawer. Pure value transforms — no I/O, deterministic, and
/// byte-identical across the Swift and Rust ports.
public enum PalacePayloadEnvelope {

    /// Current envelope format version. Bumped only when the payload shape
    /// changes; ``decode(content:)`` refuses any other version.
    public static let formatVersion = 1

    /// The opening marker line. Carries the version so a decoder validates
    /// before parsing. An HTML comment so Markdown viewers hide it.
    static let openMarkerPrefix = "<!-- MOOT-ENVELOPE v"

    /// The closing marker line.
    static let closeMarker = "MOOT-ENVELOPE -->"

    /// Errors raised while decoding an envelope from stored drawer content.
    public enum DecodeError: Error, Sendable, Equatable {
        /// The content carried an open marker whose version is not one this
        /// build understands. Carries the offending version (loud failure,
        /// never a silent drop) — symmetry with `CorpusDocument` strictness.
        case unsupportedVersion(Int)
        /// The open marker was present but the matching close marker was not,
        /// so the envelope bytes are truncated/corrupt.
        case unterminated
        /// The bytes between the markers were not valid envelope JSON.
        case malformedJSON(String)
    }

    // MARK: - Encode

    /// Fold a note's body and its unmappable fields into the drawer content
    /// MemPalace will store: the verbatim body, then the fenced envelope.
    ///
    /// When the payload is entirely default (a plain note with nothing the
    /// native args dropped) the envelope is STILL emitted — `stableSourceKey`
    /// is always non-default, so a re-import always has the idempotency key.
    /// The body is emitted verbatim so the searchable prose is unchanged.
    ///
    /// - Parameters:
    ///   - body: the note's `flattenedBody` (the verbatim prose).
    ///   - payload: the unmappable-field record to fold in.
    /// - Returns: the `content` string to send as the `add_drawer` content
    ///   argument.
    public static func encode(body: String, payload: PalaceEnvelopePayload) throws -> String {
        let json = try canonicalJSON(payload)
        // Body, blank line, then the fenced block. A trailing newline after
        // the close marker is omitted so re-encoding is byte-stable.
        return "\(body)\n\n\(openMarkerPrefix)\(formatVersion)\n\(json)\n\(closeMarker)"
    }

    // MARK: - Generic four-noun envelope (drawer / tunnel / KG fact / diary)

    /// Fold a `PalaceItem`'s body and its per-noun envelope-field map into the
    /// string MemPalace stores for whichever native arg carries the noun's text
    /// (a drawer's/diary's `content`/`entry`, a tunnel's `label`, a fact's
    /// `source_closet`).
    ///
    /// This is the ONE canonical envelope for ALL four nouns — the same
    /// versioned `MOOT-ENVELOPE v1` marker as the `NoteIR` drawer envelope
    /// above. The payload is the field map, serialized as canonical JSON
    /// (sorted keys, no slash escaping) so the Swift and Rust ports emit
    /// byte-identical bytes.
    ///
    /// When `fields` is empty the body is returned UNCHANGED (no empty
    /// envelope): a fact with no extra metadata sends a clean `source_closet`,
    /// and a plain item stays plain. This mirrors the per-noun mapping's
    /// "ride only when there is something to carry" rule.
    ///
    /// - Parameters:
    ///   - body: the noun's native text (drawer content, diary entry, tunnel
    ///     label, or "" for a fact whose envelope rides `source_closet`).
    ///   - fields: the per-noun envelope-field map (every field with no native
    ///     MemPalace home).
    /// - Returns: `body` when `fields` is empty; otherwise body, a blank line,
    ///   then the fenced versioned envelope.
    public static func encodeFields(body: String, fields: [String: PalaceJSONValue]) throws -> String {
        guard !fields.isEmpty else { return body }
        let json = try canonicalFieldsJSON(fields)
        return "\(body)\n\n\(openMarkerPrefix)\(formatVersion)\n\(json)\n\(closeMarker)"
    }

    /// One decoded four-noun envelope: the verbatim body with the envelope
    /// stripped, plus the recovered field map (empty when the content carried
    /// no envelope).
    public struct DecodedFields: Sendable, Equatable {
        /// The native text with the fenced envelope removed and surrounding
        /// whitespace trimmed.
        public let body: String
        /// The recovered per-noun envelope-field map (empty when no envelope
        /// was present).
        public let fields: [String: PalaceJSONValue]
    }

    /// Split a stored four-noun string back into its body and recovered field
    /// map. The inverse of ``encodeFields(body:fields:)``. Content with no open
    /// marker decodes as `DecodedFields(body: content, fields: [:])` — a
    /// foreign value is read as plain text, never an error.
    ///
    /// - Throws: ``DecodeError`` when an envelope is present but its version is
    ///   unsupported, it is unterminated, or its JSON is malformed.
    public static func decodeFields(content: String) throws -> DecodedFields {
        guard let openRange = content.range(of: openMarkerPrefix) else {
            return DecodedFields(body: content, fields: [:])
        }
        let afterPrefix = content[openRange.upperBound...]
        guard let lineEnd = afterPrefix.firstIndex(of: "\n") else {
            throw DecodeError.unterminated
        }
        let versionToken = afterPrefix[afterPrefix.startIndex..<lineEnd]
            .trimmingCharacters(in: .whitespaces)
        guard let version = Int(versionToken) else {
            throw DecodeError.malformedJSON("envelope version token '\(versionToken)' is not an integer")
        }
        guard version == formatVersion else {
            throw DecodeError.unsupportedVersion(version)
        }
        let jsonStart = afterPrefix.index(after: lineEnd)
        guard let closeRange = content.range(of: closeMarker, range: jsonStart..<content.endIndex) else {
            throw DecodeError.unterminated
        }
        let jsonSlice = content[jsonStart..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields: [String: PalaceJSONValue]
        do {
            fields = try JSONDecoder().decode(
                [String: PalaceJSONValue].self,
                from: Data(jsonSlice.utf8))
        } catch {
            throw DecodeError.malformedJSON(String(describing: error))
        }
        let body = String(content[content.startIndex..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DecodedFields(body: body, fields: fields)
    }

    // MARK: - Decode

    /// One decoded drawer: the verbatim body with the envelope stripped, plus
    /// the recovered payload (nil when the content carried no envelope, e.g.
    /// a drawer written by something other than this pump).
    public struct Decoded: Sendable, Equatable {
        /// The note prose with the fenced envelope removed and trailing
        /// envelope-separator whitespace trimmed.
        public let body: String
        /// The recovered unmappable-field record, or nil when no envelope was
        /// present in the content.
        public let payload: PalaceEnvelopePayload?
    }

    /// Split stored drawer content back into its body and its recovered
    /// payload. The inverse of ``encode(body:payload:)``:
    /// `decode(encode(body, p)).body == body` and `.payload == p`.
    ///
    /// Content with no open marker decodes as `Decoded(body: content,
    /// payload: nil)` — a foreign drawer is read as plain prose, never an
    /// error.
    ///
    /// - Throws: ``DecodeError`` when an envelope is present but its version
    ///   is unsupported, it is unterminated, or its JSON is malformed.
    public static func decode(content: String) throws -> Decoded {
        guard let openRange = content.range(of: openMarkerPrefix) else {
            return Decoded(body: content, payload: nil)
        }
        // Parse the version digits immediately after the prefix up to the
        // newline that ends the open-marker line.
        let afterPrefix = content[openRange.upperBound...]
        guard let lineEnd = afterPrefix.firstIndex(of: "\n") else {
            throw DecodeError.unterminated
        }
        let versionToken = afterPrefix[afterPrefix.startIndex..<lineEnd]
            .trimmingCharacters(in: .whitespaces)
        guard let version = Int(versionToken) else {
            throw DecodeError.malformedJSON("envelope version token '\(versionToken)' is not an integer")
        }
        guard version == formatVersion else {
            throw DecodeError.unsupportedVersion(version)
        }
        // The JSON runs from just after the open-marker line to just before
        // the close marker.
        let jsonStart = afterPrefix.index(after: lineEnd)
        guard let closeRange = content.range(of: closeMarker, range: jsonStart..<content.endIndex) else {
            throw DecodeError.unterminated
        }
        let jsonSlice = content[jsonStart..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: PalaceEnvelopePayload
        do {
            payload = try JSONDecoder().decode(
                PalaceEnvelopePayload.self,
                from: Data(jsonSlice.utf8))
        } catch {
            throw DecodeError.malformedJSON(String(describing: error))
        }
        // Body is everything before the open marker, trimmed of the blank
        // separator line(s) encode inserted.
        let body = String(content[content.startIndex..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decoded(body: body, payload: payload)
    }

    /// Reconstruct a full `NoteIR` from a fetched drawer's content. Decodes
    /// the envelope and rebuilds the note from the recovered payload, with
    /// the body above the marker as the single markdown block. When the
    /// content carries no envelope (a foreign drawer), a minimal `NoteIR` is
    /// built from the prose alone with `stableSourceKey = fallbackKey`.
    ///
    /// - Parameters:
    ///   - content: the drawer content as returned by `get_drawer`.
    ///   - fallbackKey: the stable key to use when no envelope is present
    ///     (e.g. the drawer id) so the reconstructed note still has identity.
    /// - Returns: the reconstructed `NoteIR`.
    public static func reconstructNote(content: String, fallbackKey: String) throws -> NoteIR {
        let decoded = try decode(content: content)
        guard let payload = decoded.payload else {
            return NoteIR(
                stableSourceKey: fallbackKey,
                body: [Block(kind: "markdown", text: decoded.body)]
            )
        }
        return NoteIR(
            stableSourceKey: payload.stableSourceKey,
            body: [Block(kind: "markdown", text: decoded.body)],
            frontmatter: payload.frontmatter,
            links: payload.links,
            tags: payload.tags,
            originalPath: payload.originalPath,
            originDate: payload.originDate,
            source: payload.source,
            mootID: payload.mootID,
            facts: payload.facts,
            pathComponents: payload.pathComponents,
            scope: payload.scope,
            kind: payload.kind
        )
    }

    // MARK: - Canonical JSON

    /// Encode the payload as canonical JSON: sorted keys, no slash escaping —
    /// the same conventions as `CorpusDocument.canonicalJSON` and the Rust
    /// `serde_json` default, so both ports emit byte-identical envelopes.
    static func canonicalJSON(_ payload: PalaceEnvelopePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Encode a per-noun envelope-field map as canonical JSON: sorted keys, no
    /// slash escaping — the same conventions as ``canonicalJSON(_:)`` and the
    /// Rust `serde_json` default, so both ports emit byte-identical four-noun
    /// envelopes for the same field map.
    static func canonicalFieldsJSON(_ fields: [String: PalaceJSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(fields)
        return String(decoding: data, as: UTF8.self)
    }
}
