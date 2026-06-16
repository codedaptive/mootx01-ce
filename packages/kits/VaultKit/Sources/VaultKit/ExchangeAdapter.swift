import Foundation

// VK-ADAPT-01 (read side) + VK-EXPORT-01 (write side) — the first
// programmatic-tool adapter (ADR-007 Decision 1).
//
// `ExchangeAdapter` teaches VaultKit both directions of the external
// memory-tool JSON export (the MOOT exchange format v1): `toIR`/`decode` read it
// into the canonical `NoteIR`, and `fromIR`/`encode` write `NoteIR` back
// out as the tool's export document — the programmatic exit promise
// (ADR-007 Decision 4, gold item 7). Per ADR-007 Decision 1 this adapter
// is the single owner of the export's codec knowledge: mass import is
// exclusively adapter → `VaultBridge.importVault`, and mass export is
// `VaultBridge.export` → adapter, which applies the Decision 2 tier rules
// and writes the audit receipt BEFORE the adapter sees the notes.
//
// Adapters are pure transforms (`tool format ⇄ NoteIR`): no process
// spawning, no network I/O. `toIR`/`fromIR` touch the filesystem only to
// read/write the export file the caller points at; `decode(_:)` and
// `encode(_:)` are the pure byte-level transforms ARIA_MCP uses when the
// export rides the wire instead of disk.

// MARK: - ExchangeExport

/// A decoded external memory-tool export: the corpus name plus its
/// entries as canonical notes.
///
/// The name is corpus-level metadata (it identifies the source palace,
/// not any one note), so it rides beside the notes rather than being
/// duplicated into each `NoteIR`. `CorpusProjection` consumes both
/// halves to rebuild an `ExternalCorpus` for migration verification
/// and the NeuronKit benchmark.
public struct ExchangeExport: Sendable, Equatable {

    /// Human-readable corpus name, verbatim from the export's `name`.
    public let name: String

    /// One `NoteIR` per export entry, sorted by `stableSourceKey`
    /// (the `VaultAdapter` deterministic-order contract).
    public let notes: [NoteIR]

    public init(name: String, notes: [NoteIR]) {
        self.name = name
        self.notes = notes
    }
}

// MARK: - ExchangeAdapter

/// Decodes the external memory-tool JSON export into `[NoteIR]`, and
/// encodes `[NoteIR]` back into the same export shape.
///
/// Export shape (minimal documented form, extended-field keys optional):
///
/// ```json
/// {
///   "name": String,
///   "entries": [
///     {
///       "id": String,                       // → stableSourceKey
///       "content": String,                  // → body (one markdown block)
///       "tags": [String]?,                  // → tags ([] when absent)
///       "facts": [FactIR]?,                 // → facts ([] when absent)
///       "pathComponents": [String]?,        // → pathComponents ([] when absent)
///       "scope": {String: String}?,         // → scope ([:] when absent)
///       "kind": String?                     // → kind ("note" when absent)
///     }
///   ]
/// }
/// ```
///
/// `id` and `content` are required per entry; `name` is required at the
/// top level. The extended full-fidelity fields (VK-IR-01) are populated
/// when the export carries them and land their documented defaults when
/// it does not, so both legacy flat exports and full-fidelity exports
/// decode through the same path.
///
/// Both sides ship: `toIR`/`decode` (VK-ADAPT-01) and `fromIR`/`encode`
/// (VK-EXPORT-01 — programmatic export-my-data, ADR-007 Decision 4,
/// gold item 7). Write-side output is canonical and deterministic; see
/// `encode(_:)` for the canonical-form contract and the enumeration of
/// `NoteIR` fields the export format cannot carry.
public struct ExchangeAdapter: VaultAdapter {

    public init() {}

    // MARK: - Wire payload (private decode shape)

    /// The export's top-level JSON object. Strict on `name` + `entries`;
    /// throws `DecodingError` when either is missing or mistyped.
    private struct ExportPayload: Decodable {
        let name: String
        let entries: [ExportEntry]
    }

    /// One export entry. `id` and `content` are required; every other
    /// key is optional and lands its `NoteIR` default when absent.
    /// `facts` decodes directly as `[FactIR]` — the IR fact shape IS the
    /// boundary contract (subject/predicate/object + optional validity
    /// window and confidence), so no separate wire struct is needed.
    private struct ExportEntry: Decodable {
        let id: String
        let content: String
        let tags: [String]?
        let facts: [FactIR]?
        let pathComponents: [String]?
        let scope: [String: String]?
        let kind: String?
    }

    // MARK: - Read side

    /// Read an export file into canonical notes.
    ///
    /// `VaultAdapter` conformance: for this adapter the "vault" is a
    /// single JSON export file, so `vaultURL` is the file's URL, not a
    /// directory. The corpus `name` is dropped by this protocol-shaped
    /// entry point (the protocol returns notes only); callers that need
    /// the name use `decode(_:)` and read `ExchangeExport.name`.
    ///
    /// - Parameter vaultURL: the export JSON file.
    /// - Returns: one `NoteIR` per entry, sorted by `stableSourceKey`.
    public func toIR(vaultURL: URL) throws -> [NoteIR] {
        let data = try Data(contentsOf: vaultURL)
        return try decode(data).notes
    }

    /// The pure transform: export bytes → decoded corpus.
    ///
    /// Field mapping per VK-ADAPT-01: `id` → `stableSourceKey` (the
    /// idempotency key the bridge derives the lineage from), `content` →
    /// a single `"markdown"` body block, `tags` → `tags`, and the
    /// VK-IR-01 extended fields populated when present. `originalPath`
    /// is the joined `pathComponents` back-compat view, matching the
    /// `NoteIR` doc contract.
    ///
    /// - Throws: `DecodingError` on malformed JSON or a missing required
    ///   field (`name`, `id`, `content`).
    public func decode(_ data: Data) throws -> ExchangeExport {
        let payload = try JSONDecoder().decode(ExportPayload.self, from: data)
        let notes = payload.entries.map { entry in
            let pathComponents = entry.pathComponents ?? []
            return NoteIR(
                stableSourceKey: entry.id,
                body: [Block(kind: "markdown", text: entry.content)],
                tags: entry.tags ?? [],
                originalPath: pathComponents.joined(separator: "/"),
                facts: entry.facts ?? [],
                pathComponents: pathComponents,
                scope: entry.scope ?? [:],
                kind: entry.kind ?? "note"
            )
        }
        // Deterministic order, sorted by stableSourceKey — the
        // VaultAdapter contract, so repeated decodes are stable.
        .sorted { $0.stableSourceKey < $1.stableSourceKey }
        return ExchangeExport(name: payload.name, notes: notes)
    }

    // MARK: - Write side (VK-EXPORT-01)

    /// One export entry in canonical write form. Encode-only twin of
    /// `ExportEntry`: `id` and `content` always serialize; the extended
    /// keys (`tags`, `facts`, `pathComponents`, `scope`, `kind`) serialize
    /// only when off their documented `NoteIR` defaults, so a legacy flat
    /// note re-encodes in the legacy flat shape and the document's bytes
    /// never carry redundant defaults. `FactIR` uses its synthesized
    /// `Codable`, which already omits nil optional keys.
    private struct ExportEntryOut: Encodable {
        let note: NoteIR

        private enum CodingKeys: String, CodingKey {
            case id, content, tags, facts, pathComponents, scope, kind
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(note.stableSourceKey, forKey: .id)
            try c.encode(note.flattenedBody, forKey: .content)
            if !note.tags.isEmpty { try c.encode(note.tags, forKey: .tags) }
            if !note.facts.isEmpty { try c.encode(note.facts, forKey: .facts) }
            if !note.pathComponents.isEmpty { try c.encode(note.pathComponents, forKey: .pathComponents) }
            if !note.scope.isEmpty { try c.encode(note.scope, forKey: .scope) }
            if note.kind != "note" { try c.encode(note.kind, forKey: .kind) }
        }
    }

    /// The export's top-level JSON object in canonical write form.
    private struct ExportPayloadOut: Encodable {
        let name: String
        let entries: [ExportEntryOut]
    }

    /// The pure transform: decoded corpus → canonical export bytes. The
    /// inverse of `decode(_:)`: `decode(encode(x)) == x` for every
    /// `ExchangeExport` whose notes carry only format-representable
    /// fields, and `encode(decode(bytes))` is the canonical form of any
    /// valid export — idempotent, so re-encoding is byte-stable.
    ///
    /// Canonical form (cross-language byte-equality contract, same
    /// conventions as `CorpusDocument.canonicalJSON`):
    ///
    /// - Entries sorted ascending by `id` (the deterministic-order
    ///   contract), regardless of input order.
    /// - Object keys sorted ascending; compact output; forward slashes
    ///   NOT escaped (matches serde_json in the Rust port).
    /// - Extended entry keys omitted at their documented defaults
    ///   (`tags`/`facts`/`pathComponents` empty, `scope` empty,
    ///   `kind == "note"`); `FactIR` optional keys omitted when nil.
    ///
    /// The shared fixture
    /// `Tests/VaultKitTests/Fixtures/exchange_export_canonical.json`
    /// is the canonical encode of the golden fixture, asserted
    /// byte-for-byte by BOTH test suites.
    ///
    /// Fields the export format CANNOT carry — enumerated per the
    /// VK-EXPORT-01 never-silently-dropped rule. The format's entry shape
    /// is `{ id, content, tags?, facts?, pathComponents?, scope?, kind? }`,
    /// so these `NoteIR` fields do not survive `encode`:
    ///
    /// - `frontmatter` — no frontmatter map in the export shape
    /// - `links` — the tool has no wikilink concept; link relations
    ///   travel as `facts` when the producer models them
    /// - `originDate` — no per-entry timestamp key
    /// - `source` — no attachment/source-ref key
    /// - `mootID` — no lineage key; a re-import resolves identity from
    ///   `id` → `stableSourceKey` (FNV fallback), not `moot_id`
    /// - `body` block structure — `content` is the flattened body
    ///   (blocks joined by newline); multiple blocks collapse to one
    ///   `"markdown"` block on re-read, and non-`"markdown"` block kinds
    ///   are not preserved
    /// - `originalPath` is NOT lost but is derived: it re-materializes as
    ///   `pathComponents.joined(separator: "/")` on decode, so a note
    ///   whose `originalPath` disagrees with its `pathComponents` reads
    ///   back with the components-derived view
    public func encode(_ export: ExchangeExport) throws -> Data {
        let entries = export.notes
            .sorted { $0.stableSourceKey < $1.stableSourceKey }
            .map(ExportEntryOut.init)
        let encoder = JSONEncoder()
        // sortedKeys: deterministic key order. withoutEscapingSlashes:
        // match serde_json, which never escapes '/'.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ExportPayloadOut(name: export.name, entries: entries))
    }

    /// Write canonical notes out as the external tool's export document —
    /// the programmatic exit promise (ADR-007 Decision 4, gold item 7).
    ///
    /// `VaultAdapter` conformance: as with `toIR`, the "vault" is a single
    /// JSON export file, so `vaultURL` is the destination file's URL.
    /// Intermediate directories are created as needed; the adapter writes
    /// only that one file. The protocol carries no corpus name, so the
    /// document's `name` is derived from the destination filename without
    /// its extension (e.g. `…/my-estate.json` → `"my-estate"`); callers
    /// that need an explicit name use `encode(_:)` with a `ExchangeExport`.
    ///
    /// Output is deterministic (see `encode(_:)`), and this is a pure
    /// transform of exactly the notes handed in: tier filtering and audit
    /// receipts happen upstream in `VaultBridge.export` (VK-TIER-01) —
    /// the adapter never re-implements tier logic.
    public func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws {
        let name = vaultURL.deletingPathExtension().lastPathComponent
        let export = ExchangeExport(name: name, notes: notes)
        let data = try encode(export)
        try FileManager.default.createDirectory(
            at: vaultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: vaultURL, options: .atomic)
    }
}
