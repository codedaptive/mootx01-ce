import Foundation

// PalaceItem.swift — the language-neutral, four-noun unit the canonical palace
// pump moves. The generalization of the drawers-only `NoteIR` pump path to the
// WHOLE mootx01 data model (drawer, tunnel, KG fact, diary entry).
//
// ## Why a generic carrier alongside NoteIR
//
// `NoteIR` is the drawer/Obsidian IR — it models a note (body, frontmatter,
// wikilinks, tags) and is the right shape for the vault bridge. The palace
// pump must also move tunnels, KG facts, and diary entries, whose shapes are
// nothing like a note. Rather than overload `NoteIR` with four nouns' fields,
// the pump consumes a flat `PalaceItem`: a noun discriminator plus the
// native-field / envelope-field split the mapper needs. A drawer `PalaceItem`
// carries the same envelope a `NoteIR` drawer would, so the two paths agree on
// drawer bytes.
//
// ## The read seam
//
// VaultKit does NOT read the four nouns itself — that would invert the layering
// (it sits above GeniusLocusKit and would have to reach down for tunnels / KG
// facts / diary entries). The operator driver's `EstateReader` reads each noun
// through GLK public verbs and projects it to a `PalaceItem`; the driver hands
// the `[PalaceItem]` stream to `PalacePump`. The per-noun read knowledge stays
// in the driver; the per-noun WIRE knowledge (tool, native args, envelope,
// verify) stays here in the kit.

/// Which mootx01 noun a ``PalaceItem`` carries. Drives the mapper's choice of
/// MemPalace tool, the response parser, the verify strategy, and the report's
/// per-noun counts.
public enum PalaceNoun: String, Sendable, CaseIterable, Codable, Equatable {
    case drawer
    case tunnel
    case kgFact
    case diaryEntry
}

/// One unit of the data model, ready to write to MemPalace. `sourceID` is the
/// mootx01 row id (stable for the lifetime of the source row), used as the
/// checkpoint key. `nativeFields` are the values the mapper places into native
/// MemPalace tool arguments; `envelopeFields` are every remaining field,
/// preserved losslessly in the content envelope. The split is decided by the
/// caller's per-noun projection (which knows the noun's schema); the mapper
/// consumes both without per-field knowledge.
///
/// `Equatable`/`Sendable` so projection vectors can assert an exact item shape
/// across the Swift and Rust ports.
public struct PalaceItem: Sendable, Equatable {
    /// The noun kind.
    public let noun: PalaceNoun
    /// The source row id (`drawer.id`, `tunnel.id`, `kgFact.id`,
    /// `diaryEntry.id`). The checkpoint/idempotency key.
    public let sourceID: String
    /// The native body text for this item: a drawer's/diary's content; for a
    /// fact or tunnel a human-readable rendering (the structured truth rides
    /// native args + envelope, the body is the searchable surface).
    public let body: String
    /// Values destined for native MemPalace tool arguments, keyed by the
    /// mootx01 field name (the mapper translates to the MemPalace arg name).
    public let nativeFields: [String: PalaceJSONValue]
    /// Every other field, preserved in the content envelope (never dropped).
    public let envelopeFields: [String: PalaceJSONValue]

    public init(
        noun: PalaceNoun,
        sourceID: String,
        body: String,
        nativeFields: [String: PalaceJSONValue],
        envelopeFields: [String: PalaceJSONValue]
    ) {
        self.noun = noun
        self.sourceID = sourceID
        self.body = body
        self.nativeFields = nativeFields
        self.envelopeFields = envelopeFields
    }
}
