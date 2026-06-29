import Foundation

/// A graph-edge noun linking two locations in the MemPalace surface.
///
/// `Association` is the edge-shaped noun behind the `association` lexicon
/// entry (`AriaLexiconLib/Acceptance.swift` — association accepts mutate,
/// expunge, recall; it accepts no capture and no withdraw). An
/// association records that two rows belong together — a statistical or
/// dreaming-derived pairing — rather than a typed semantic claim. The
/// dreaming pass creates or strengthens associations from accumulated
/// signals (co-recall, co-confirmation, vector similarity, shared
/// entities, …) per cookbook §10.10; this type is the durable record it
/// produces. Associations are on the *graph* side of the content-vs-graph
/// distinction (cookbook §9.5.1).
///
/// Association verb behaviour (mutate, expunge, recall) is implemented
/// through `EstateVerbs.associate` and `DrawerStore` — the full verb
/// surface is wired.
///
/// `Association` mirrors `Tunnel` structurally — both are directional
/// edges carrying source + target endpoints (wing + room + optional
/// drawer id), three Int64 bitmap columns, and the Rev 1.0 soft-delete
/// reservation (`tombstonedAt` / `removedByBatch`) — with two deliberate
/// differences:
///
/// - **No `kind`.** `Tunnel` carries a typed `TunnelKind` vocabulary in a
///   dedicated `kind_id` column; an association has no equivalent typed
///   relationship vocabulary. All association-specific semantics live in
///   the operational bitmap (`AssociationOperational.swift`): which
///   signals were seen, the decay class, and the arity.
/// - **A required `latticeAnchor`.** `Tunnel` predates cookbook §2.7
///   (I-16); `Association` honours it. Per §2.7 an association is anchored
///   to the lattice-midpoint of its endpoints. The anchor is stored as the
///   same four columns drawers and proposals use; `addAssociation` rejects
///   an empty `udcCode` before insert.
///
/// Conformance note: `Association` is `Equatable, Codable, Sendable` but
/// deliberately **not** `Hashable`, where `Tunnel` is. The difference is
/// the embedded `LatticeAnchor`, which is `Equatable, Codable, Sendable`
/// but not `Hashable` (see `EstateTypes.swift`). Synthesised `Hashable`
/// requires every stored property to be `Hashable`, so `Association`
/// cannot be `Hashable` without a hand-written conformance or widening
/// `LatticeAnchor` — neither warranted here, since nothing keys a
/// `Set`/dictionary on `Association`. This matches `Proposal`, which
/// carries the same anchor and makes the same choice. The Rust port
/// mirrors it: it derives `PartialEq, Eq` but not `Hash`.
///
/// Three Int64 bitmap columns carry the operational axes:
///
/// - `adjectiveBitmap` — the association's own cross-row adjective state
///   (state, sensitivity, exportability, trust) per cookbook §2.3, shared
///   with `Drawer` (accessors in `Adjectives.swift`). Associations are
///   graph-side, so the dreaming/expunge layer sets the
///   `dreaming_recalc_required` adjective when an endpoint is expunged
///   (§9.5.1) — a verb-layer concern carried like every other adjective.
/// - `operationalBitmap` — signal-sources-seen bitset, decay class, and
///   arity per cookbook §2.4 ("Association operational"). See
///   `AssociationOperational.swift`.
/// - `provenanceBitmap` — source type, channel, confirmation, confidence,
///   sensitivity per cookbook §2.5.
///
/// All three bitmaps default to `0` so a caller constructing a bare
/// association gets the safe baseline (no signals seen, decay class
/// `.pinned`, arity `.binary`) without threading every axis through the
/// call site.
public struct Association: Equatable, Codable, Sendable {

    /// Stable identifier for this association. Row identity is a UUID per
    /// cookbook I-29; this mission accepts whatever id the caller supplies.
    public let id: String

    /// Wing of the source endpoint.
    public let sourceWing: String

    /// Room of the source endpoint.
    public let sourceRoom: String

    /// Drawer id at the source endpoint, when the association links a
    /// specific drawer. Nil means the room itself.
    public let sourceDrawerId: String?

    /// Wing of the target endpoint.
    public let targetWing: String

    /// Room of the target endpoint.
    public let targetRoom: String

    /// Drawer id at the target endpoint. Nil means the room itself.
    public let targetDrawerId: String?

    /// Free-form descriptor for the association. Domain-specific; LocusKit
    /// does not validate against a closed catalogue. Unlike `Tunnel`, an
    /// association carries no typed `kind` vocabulary — the operational
    /// bitmap carries its semantics — so `label` is the only human-facing
    /// annotation.
    public let label: String

    /// The association's lattice anchor — required on every row per
    /// cookbook §2.7 (I-16). An association is anchored to the
    /// lattice-midpoint of its endpoints. `udcCode` must be non-empty at
    /// storage; `addAssociation` rejects an empty anchor with
    /// `LocusKitError.invalidContent`, mirroring the capture-path guard in
    /// `EstateVerbs.swift`.
    public let latticeAnchor: LatticeAnchor

    /// Cross-row adjective bitmap (state, sensitivity, exportability,
    /// trust per cookbook §2.3). Stored as a single Int64 column. Default
    /// 0 leaves every axis at its zero-value.
    public let adjectiveBitmap: Int64

    /// Per-noun operational bitmap (cookbook §2.4, association layout).
    /// Stored as a single Int64 column. Accessors in
    /// `AssociationOperational.swift` decode the signal-sources-seen
    /// bitset, decay class, and arity.
    public let operationalBitmap: Int64

    /// Provenance bitmap (cookbook §2.5). Stored as a single Int64 column.
    /// Captures source type, channel, confirmation, confidence, and
    /// sensitivity at row birth.
    public let provenanceBitmap: Int64

    /// Name of the agent or process that filed this association.
    public let addedBy: String

    /// When the association was added. TEXT ISO8601 in SQLite.
    public let filedAt: Date

    /// When this association was tombstoned, if it has been. Reserved for
    /// the Rev 2.0 soft-delete workflow, present from Rev 1.0 so the schema
    /// does not migrate when it lands.
    public let tombstonedAt: Date?

    /// Batch identifier used for receipt-based rollback of a tombstone.
    /// Reserved for the Rev 2.0 soft-delete workflow.
    public let removedByBatch: String?

    /// Designated initializer.
    public init(
        id: String,
        sourceWing: String,
        sourceRoom: String,
        sourceDrawerId: String? = nil,
        targetWing: String,
        targetRoom: String,
        targetDrawerId: String? = nil,
        label: String,
        latticeAnchor: LatticeAnchor,
        adjectiveBitmap: Int64 = 0,
        operationalBitmap: Int64 = 0,
        provenanceBitmap: Int64 = 0,
        addedBy: String,
        filedAt: Date,
        tombstonedAt: Date? = nil,
        removedByBatch: String? = nil
    ) {
        self.id = id
        self.sourceWing = sourceWing
        self.sourceRoom = sourceRoom
        self.sourceDrawerId = sourceDrawerId
        self.targetWing = targetWing
        self.targetRoom = targetRoom
        self.targetDrawerId = targetDrawerId
        self.label = label
        self.latticeAnchor = latticeAnchor
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.addedBy = addedBy
        self.filedAt = filedAt
        self.tombstonedAt = tombstonedAt
        self.removedByBatch = removedByBatch
    }
}
