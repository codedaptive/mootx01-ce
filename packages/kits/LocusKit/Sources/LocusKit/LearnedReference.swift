import Foundation

/// A learned reference: the durable record of an external reference brought
/// into the estate by the grounding-driven `learn` verb.
///
/// `LearnedReference` is the noun behind the `learnedReference` lexicon entry
/// (`AriaLexiconLib/Acceptance.swift` — it is the only noun that accepts
/// `learn`, plus mutate / withdraw / expunge / recall). The `learn` verb is
/// grounding-driven (`AriaLexiconLib/Verb.swift` — `Flow.groundingDriven`):
/// it brings authoritative external reference in. This type is the substrate
/// that verb writes to. It is a *product* noun in the language taxonomy
/// (`AriaLexiconLib/Noun.swift` — `learnedReference.role == .product`).
///
/// This mission ships only the value type, its operational accessors, the
/// `learned_references` table, and store persistence. No verb behaviour
/// (learn / mutate / withdraw / expunge / recall) is implemented here — the
/// verb missions target this substrate later.
///
/// ## Field shape — source-grounded
///
/// The mission brief sketched a KGFact-shaped triple with a `grounding_ref`
/// column. Source is ground truth (mission "Read First"): the architecture
/// spec (`docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.8.md` § 7.8.2)
/// defines `LearnedReference` as a *reference* noun, not a triple:
///
/// ```
/// struct LearnedReference {
///     rowID, source: SourceCatalogEntry, handle: String, mode: LearnMode,
///     adjectiveBitmap, operationalBitmap, provenanceBitmap
/// }
/// ```
///
/// This type follows the spec shape, with two reconciliations:
///
/// - `source: SourceCatalogEntry` → `sourceCatalogID: String`. The
///   `SourceCatalogEntry` type is not implemented anywhere in the codebase
///   (spec-only). The substrate stores a reference to the catalog entry as
///   an identifier string, the same way `KGFact` stores `sourceDrawerID`
///   rather than embedding a `Drawer`.
/// - `mode: LearnMode` lives in the operational bitmap (bit 12), not as a
///   stored struct field. Cookbook v1.0 § 2.4 (which supersedes the v0.8
///   spec on bitmap layout) places `mode` in the LearnedReference
///   operational bitmap alongside `refresh_policy`, `drift_severity`, and
///   `source`. Every other LocusKit noun keeps its operational axes in the
///   bitmap with computed accessors (see `KGFactOperational.swift`,
///   `AssociationOperational.swift`); `LearnedReference` follows suit. The
///   accessors live in `LearnedReferenceOperational.swift`.
///
/// No `grounding_ref` column: no `GroundingSpec` / `groundingColumn` /
/// `grounding_ref` exists anywhere in the codebase or the cookbook. The
/// grounding nature of `learn` is captured by `Flow.groundingDriven`, which
/// describes how the verb is *initiated*, not a storage column.
///
/// ## Structure — mirrors `Association`
///
/// `LearnedReference` mirrors `Association` structurally: an id, content
/// columns, a required `latticeAnchor` (cookbook § 2.7 / I-16 — every row
/// has an anchor), three Int64 bitmap columns, `addedBy` / `filedAt`, and
/// the Rev 1.0 soft-delete reservation (`tombstonedAt` / `removedByBatch`).
/// `Association` (not `KGFact`) is the template because it is the freshest
/// content-bearing noun that already honours the § 2.7 anchor requirement;
/// `KGFact` predates it and carries no anchor.
///
/// Like `Association` it is `Equatable, Codable, Sendable` but deliberately
/// **not** `Hashable`: the embedded `LatticeAnchor` is `Equatable, Codable,
/// Sendable` but not `Hashable` (see `EstateTypes.swift`), and synthesised
/// `Hashable` requires every stored property to be `Hashable`. Nothing keys
/// a `Set`/dictionary on `LearnedReference`. The Rust port mirrors this:
/// it derives `PartialEq, Eq` but not `Hash`.
///
/// Three Int64 bitmap columns carry the operational axes:
///
/// - `adjectiveBitmap` — cross-row adjective state (state, sensitivity,
///   exportability, trust) per cookbook § 2.3, shared with `Drawer`.
/// - `operationalBitmap` — refresh policy, drift severity, learn mode, and
///   acquisition source per cookbook § 2.4 ("LearnedReference operational").
///   See `LearnedReferenceOperational.swift`.
/// - `provenanceBitmap` — source type, channel, confirmation, confidence,
///   sensitivity per cookbook § 2.5.
///
/// All three bitmaps default to `0` so a caller constructing a bare learned
/// reference gets the safe baseline (refresh `.none`, drift `.none`, mode
/// `.byReference`, source `.user`) without threading every axis through the
/// call site.
public struct LearnedReference: Equatable, Codable, Sendable {

    /// Stable identifier for this learned reference. Row identity is a UUID
    /// per cookbook I-29; this mission accepts whatever id the caller supplies.
    public let id: String

    /// Reference to the `SourceCatalogEntry` this reference was learned from
    /// (spec § 7.8.2 `source`). Stored as the catalog entry's identifier
    /// string — the `SourceCatalogEntry` value type is not implemented in
    /// the substrate, so the reference is carried the way `KGFact` carries
    /// `sourceDrawerID`. Indexed (`idx_learned_references_source`) so a
    /// refresh sweep can resolve every reference from one source.
    public let sourceCatalogID: String

    /// The reference handle — the URI / locator string the reference points
    /// at (spec § 7.8.2 `handle`). Indexed (`idx_learned_references_handle`)
    /// so the learn verb can resolve "do we already hold this handle?".
    public let handle: String

    /// The learned reference's lattice anchor — required on every row per
    /// cookbook § 2.7 (I-16). `udcCode` must be non-empty at storage;
    /// `addLearnedReference` rejects an empty anchor with
    /// `LocusKitError.invalidContent`, mirroring `addAssociation`.
    public let latticeAnchor: LatticeAnchor

    /// Cross-row adjective bitmap (state, sensitivity, exportability, trust
    /// per cookbook § 2.3). Stored as a single Int64 column. Default 0
    /// leaves every axis at its zero-value.
    public let adjectiveBitmap: Int64

    /// Per-noun operational bitmap (cookbook § 2.4, LearnedReference layout).
    /// Stored as a single Int64 column. Accessors in
    /// `LearnedReferenceOperational.swift` decode refresh policy, drift
    /// severity, learn mode, and acquisition source.
    public let operationalBitmap: Int64

    /// Provenance bitmap (cookbook § 2.5). Stored as a single Int64 column.
    /// Captures source type, channel, confirmation, confidence, and
    /// sensitivity at row birth.
    public let provenanceBitmap: Int64

    /// Name of the agent or process that filed this reference.
    public let addedBy: String

    /// When the reference was learned. TEXT ISO8601 in SQLite.
    public let filedAt: Date

    /// When this reference was tombstoned, if it has been. Reserved for the
    /// Rev 2.0 soft-delete workflow, present from Rev 1.0 so the schema does
    /// not migrate when it lands.
    public let tombstonedAt: Date?

    /// Batch identifier used for receipt-based rollback of a tombstone.
    /// Reserved for the Rev 2.0 soft-delete workflow.
    public let removedByBatch: String?

    /// Designated initializer.
    public init(
        id: String,
        sourceCatalogID: String,
        handle: String,
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
        self.sourceCatalogID = sourceCatalogID
        self.handle = handle
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
