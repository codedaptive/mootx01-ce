import Foundation

// VaultKit — the canonical interchange envelope.
//
// `CorpusDocument` is THE versioned canonical JSON document mandated by
// ADR-007 Decision 1: "NoteIR is the single interchange representation …
// Its serialized form is a versioned canonical JSON document — the JSON
// is the payload, never a per-tool mapping DSL." `[NoteIR]` passed in
// memory has no version or identity; this envelope gives a corpus both,
// so a serialized corpus can be stored, shipped, and decoded years later
// with an explicit compatibility contract.
//
// ## Canonical form (cross-language conformance contract)
//
// Both ports must produce byte-identical bytes for the same document.
// The canonical form is defined as:
//
// - Object keys sorted ascending (Swift `.sortedKeys`; the Rust port
//   serializes through `serde_json::Value`, whose map is BTree-backed
//   and therefore sorted).
// - Compact output — no insignificant whitespace.
// - Forward slashes NOT escaped (`.withoutEscapingSlashes`; Foundation
//   escapes `/` as `\/` by default, serde_json never does — without
//   this option byte-equality is impossible).
// - Optional fields omit their key entirely when nil.
// - The four full-fidelity NoteIR fields always serialize, even when
//   empty (`facts: []`, `pathComponents: []`, `scope: {}`,
//   `kind: "note"`), so a document's shape does not depend on content.
// - `mootID` serializes as the uppercase hyphenated UUID string —
//   Foundation's `UUID` encoding; the Rust port uppercases to match.
//
// The shared golden fixture
// `Tests/VaultKitTests/Fixtures/corpus_document_v1.json` is exercised
// byte-for-byte by BOTH test suites and is the executable form of this
// contract.

// MARK: - VaultKitError

/// Structured error enum for VaultKit (Swift home).
///
/// Mirrors the Rust `VaultKitError` in `rust/src/error.rs` per the
/// MOOTx01Error pattern — named cases, no bare strings as the only
/// diagnostic. Adapter/bridge paths rethrow GLK and Foundation errors.
public enum VaultKitError: Error, Equatable, Sendable {

    /// A `CorpusDocument` payload declared a `formatVersion` this build
    /// does not understand. Decoding is strict by design: an unknown
    /// version fails loudly with the offending value rather than
    /// best-effort parsing a shape this code has never seen.
    case unsupportedFormatVersion(Int)

    /// A vault adapter rejected the vault or a note within it (missing
    /// store, malformed file, unsupported direction). Mirrors the Rust
    /// `VaultKitError::AdapterError(String)`.
    case adapterError(String)

    /// Export aborted because the estate's corpus appears bricked: recall
    /// returned 0 drawers but raw storage contains at least one drawer row.
    /// The most common cause is a poison timestamp in a drawer row that the
    /// scan-resilience path skips but the COUNT(*) still sees. An empty
    /// export would be a silent data loss; we fail loud so the caller can
    /// investigate and repair before exporting. Mirrors the Rust
    /// `VaultKitError::ExportBrickedEstate { drawer_count, reason }`.
    ///
    /// - Parameters:
    ///   - drawerCount: raw row count from `COUNT(*)` on the drawers table
    ///   - reason: human-readable explanation of why the export was aborted
    case exportBrickedEstate(drawerCount: Int, reason: String)
}

// MARK: - CorpusDocument

/// The versioned canonical envelope around a corpus of `NoteIR` entries.
///
/// `{ formatVersion, name, notes }` — nothing else. The envelope is the
/// unit of mass data movement (ADR-007 Decision 1): exporters produce
/// one, importers consume one, and `formatVersion` is the explicit
/// compatibility gate between producers and consumers built years apart.
public struct CorpusDocument: Codable, Sendable, Equatable {

    /// The format version this build reads and writes. Bumping it is a
    /// deliberate act recorded in `docs/decisions/` — shapes froze at
    /// v0.9 beta (ADR-007 Decision 4, deliverable 2).
    public static let currentFormatVersion = 1

    /// The document's declared format version. Always
    /// `currentFormatVersion` for documents this build produces.
    public var formatVersion: Int

    /// Human-readable corpus name — typically the estate or vault name
    /// the corpus was produced from. Identification only; carries no
    /// routing semantics.
    public var name: String

    /// The corpus content, in producer order.
    public var notes: [NoteIR]

    public init(name: String, notes: [NoteIR]) {
        self.formatVersion = Self.currentFormatVersion
        self.name = name
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, notes
    }

    /// Strict versioned decode: `formatVersion` is read FIRST and an
    /// unknown value throws `VaultKitError.unsupportedFormatVersion`
    /// before any note is parsed — never silent best-effort decoding
    /// of a shape this build does not know.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version == Self.currentFormatVersion else {
            throw VaultKitError.unsupportedFormatVersion(version)
        }
        self.formatVersion = version
        self.name = try c.decode(String.self, forKey: .name)
        self.notes = try c.decode([NoteIR].self, forKey: .notes)
    }

    /// Encode to the canonical interchange bytes (see the canonical-form
    /// contract in the file header). Deterministic: the same document
    /// always yields the same bytes, in both ports.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        // sortedKeys: deterministic key order. withoutEscapingSlashes:
        // match serde_json, which never escapes '/'.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode a canonical interchange payload. Throws
    /// `VaultKitError.unsupportedFormatVersion` for unknown versions,
    /// `DecodingError` for malformed JSON.
    public static func decode(_ data: Data) throws -> CorpusDocument {
        try JSONDecoder().decode(CorpusDocument.self, from: data)
    }
}
