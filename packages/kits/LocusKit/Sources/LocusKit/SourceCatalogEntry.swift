import Foundation

/// A source catalog entry: the durable, queryable record of an external
/// source from which references are learned. The substrate behind the
/// `source` slot of the grounding-driven `learn` verb (spec § 7.8.2 —
/// `LearnFrame.source: SourceCatalogEntry`, `LearnedReference.source:
/// SourceCatalogEntry`).
///
/// ## Why it exists
///
/// `learn` brings an authoritative external reference into the estate.
/// Every learned reference must carry a *genuine* lattice anchor — never
/// a sentinel — per the P1 mandate ("a sentinel identity that persists IS
/// a fabricated identity"). The anchor is a property of the *source*, not
/// of each individual handle: a web domain, a document corpus, a paired
/// estate each classify to one lattice position, and every reference
/// learned from that source inherits it. `SourceCatalogEntry` is where
/// that genuine anchor is recorded once, so `learn` can derive each
/// `LearnedReference`'s anchor from the catalog entry rather than
/// fabricating one from a bare handle.
///
/// ## Field shape — spec § 7.8.2 intent
///
/// The spec names `SourceCatalogEntry` as the `source` of a
/// `LearnedReference` without enumerating its columns. The fields here
/// realise the spec's intent (a source identifier, its kind, its anchor,
/// and when it was first seen):
///
/// - `id` — stable source identifier (the value `LearnedReference`
///   stores in `sourceCatalogID`). UUID per cookbook I-29; the caller
///   supplies it.
/// - `kind` — what class of source this is (`SourceKind`).
/// - `handle` — the canonical locator for the source itself (the domain,
///   corpus root, or estate URI). Distinct from a learned reference's
///   per-item `handle`.
/// - `latticeAnchor` — the source's genuine lattice position. Required
///   and non-empty: `addSourceCatalogEntry` rejects an empty `udcCode`
///   with `LocusKitError.invalidContent`, mirroring every other anchored
///   noun. This is the anchor `learn` copies onto each `LearnedReference`.
/// - `firstSeen` — when this source was first cataloged. TEXT ISO8601 in
///   SQLite per the fleet date rule.
/// - `addedBy` — the agent or process that cataloged the source.
///
/// ## Structure — mirrors `Association` / `LearnedReference`
///
/// Like the other anchored content nouns it is `Equatable, Codable,
/// Sendable` but deliberately **not** `Hashable` (the embedded
/// `LatticeAnchor` is not `Hashable`). The Rust port mirrors this: it
/// derives `PartialEq, Eq` but not `Hash`.
public struct SourceCatalogEntry: Equatable, Codable, Sendable {

    /// Stable source identifier — the value a `LearnedReference` carries
    /// in `sourceCatalogID`. Row identity is a UUID per cookbook I-29.
    public let id: String

    /// What class of source this is.
    public let kind: SourceKind

    /// The canonical locator for the source itself (domain, corpus root,
    /// or estate URI). Indexed (`idx_source_catalog_handle`) so the learn
    /// verb can resolve "do we already catalog this source?".
    public let handle: String

    /// The source's genuine lattice anchor — required and non-empty per
    /// cookbook § 2.7 (I-16). `addSourceCatalogEntry` rejects an empty
    /// `udcCode`. Every `LearnedReference` learned from this source
    /// inherits this anchor; it is never a fabricated sentinel.
    public let latticeAnchor: LatticeAnchor

    /// When this source was first cataloged. TEXT ISO8601 in SQLite.
    public let firstSeen: Date

    /// The agent or process that cataloged this source.
    public let addedBy: String

    /// Designated initializer.
    public init(
        id: String,
        kind: SourceKind,
        handle: String,
        latticeAnchor: LatticeAnchor,
        firstSeen: Date,
        addedBy: String
    ) {
        self.id = id
        self.kind = kind
        self.handle = handle
        self.latticeAnchor = latticeAnchor
        self.firstSeen = firstSeen
        self.addedBy = addedBy
    }
}

/// What class of external source a `SourceCatalogEntry` records.
///
/// Stored as its raw `Int` so the column round-trips a stable integer,
/// and decoded with a fail-closed fallback to `.user` for unrecognised
/// raws — the same safe-baseline convention every operational enum in
/// LocusKit follows. The cases mirror `LearnedReferenceSource`
/// (`LearnedReferenceOperational.swift`): the acquisition channel a
/// reference was learned through is the same vocabulary as the kind of
/// source it came from.
public enum SourceKind: Int, Equatable, Codable, Sendable, CaseIterable {
    /// A source the user supplied directly.
    case user = 0
    /// A federated peer estate.
    case federation = 1
    /// A source shared through household pairing.
    case householdPairing = 2
    /// A source shared through fleet pairing.
    case fleetPairing = 3
    /// A source inherited from a tier aggregator.
    case tierInheritance = 4
    /// A directly paired estate.
    case pairedEstate = 5

    /// Decode a stored raw with a fail-closed fallback to `.user` for
    /// unrecognised values, matching the operational-enum convention.
    public static func fromRaw(_ raw: Int) -> SourceKind {
        SourceKind(rawValue: raw) ?? .user
    }
}
