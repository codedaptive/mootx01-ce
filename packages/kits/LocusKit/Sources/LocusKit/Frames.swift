import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes

// MARK: - CaptureFrame

/// Slots for the `capture` verb. Per spec § 7.1 and § 7.8.3.
///
/// Every slot is named; no raw bitmap value crosses this boundary.
/// The `capture` verb (in EstateVerbs.swift) translates these slots
/// into a storage `Drawer` and writes it via `DrawerStore.addDrawer`.
public struct CaptureFrame: Sendable {
    /// Verbatim content to store (rung 1 — exact bytes preserved).
    public var content: String
    /// How this content was captured. Lives in bits 0–5 of the
    /// resulting drawer's `operationalBitmap`.
    public var channel: CaptureChannel
    /// Adjective sensitivity tier. Defaults to `.normal`.
    public var sensitivity: AdjectiveSensitivity
    /// Content kind. Defaults to `.prose`.
    public var kind: ContentKind
    /// Provenance Channel (cookbook §2.5, provenance bitmap bits 6–11).
    /// The capture-time origin axis — UI vs MCP agent vs file import vs
    /// federation inbound, etc. Distinct from the operational
    /// `CaptureChannel` above; defaults to `.uiTyped` (raw 0) so existing
    /// callers continue to produce zero-provenance drawers as before.
    public var provenanceChannel: Channel
    /// Provenance SourceType (cookbook §2.5, provenance bitmap bits 0–5).
    /// Who/what produced this content — user, agent, system,
    /// derivedAggregate, importedExternal, federationReplica, ambient.
    /// Defaults to `.user` (raw 0).
    public var sourceType: SourceType
    /// Provenance Sensitivity (cookbook §2.5, provenance bitmap bits
    /// 30–35). The estate-level access posture at capture time, distinct
    /// from the access-control `sensitivity` adjective above (which is
    /// mutable post-capture). Defaults to `.normal` (raw 0).
    public var provenanceSensitivity: Sensitivity
    /// Provenance Confirmation (cookbook §2.5, provenance bitmap bits
    /// 18–23). Review status at capture time — a daemon or agent that
    /// captures already-confirmed content (e.g. `.userConfirmed`,
    /// `.automatedConfirmed`) records it here rather than relying on a
    /// later `confirm` mutation. Defaults to `.unconfirmed` (raw 0) so
    /// existing callers continue to produce zero-confirmation drawers,
    /// byte-identical to before this slot existed.
    public var confirmation: Confirmation
    /// Provenance Confidence (cookbook §2.5, provenance bitmap bits
    /// 24–29). System posterior at capture time — a daemon capturing
    /// with a known confidence band (e.g. `.high`, `.verified`) records
    /// it at birth rather than leaving the field at `.null` for a later
    /// enrichment pass. Defaults to `.null` (raw 0) so existing callers
    /// remain byte-identical to before this slot existed.
    public var confidence: Confidence
    /// Lineage identifier shared with any prior version of this
    /// content. When present and an active predecessor with the
    /// same lineageID exists, `capture` triggers the supersession
    /// cascade in `DrawerStore.addDrawerWithCascade`. When nil,
    /// the verb stamps a fresh `UUID()` so each drawer is its own
    /// lineage by default (spec § 5.10).
    public var lineageID: LineageID?
    /// Room within the estate the drawer is filed under.
    public var room: RoomID
    /// Lattice anchor — `udcCode` required per invariant I-5.
    public var latticeAnchor: LatticeAnchor
    /// Actor identifier written into the drawer's `addedBy` field
    /// and into any `AuditEvent` rows this capture produces in `audit_log`.
    public var addedBy: String
    /// Embedding model ID for the modelID-tagging contract (I-4).
    /// Required even before vectors are generated so a future
    /// model bump cannot accidentally compare across versions.
    public var embeddingModelID: String
    /// Optional event time for historical ingestion (ING-01). When
    /// nil, the `capture` verb uses the capture instant — the
    /// streaming-capture semantic where event time and ingest time
    /// coincide. Bulk importers supply the original authorship date.
    public var eventTime: Date?
    /// Feature flags to set on the resulting drawer at capture time.
    /// Encodes directly into bits 12–23 of the drawer's
    /// `operationalBitmap` (cookbook §2.4 feature_flags field). Because
    /// `DrawerFeatureFlags` rawValues are pre-shifted (e.g. `hasLinks`
    /// is `1 << 15`), the merge is a direct bitwise OR masked to the
    /// 12-bit feature region — the inverse of the
    /// `DrawerFeatureFlags(rawValue: extractField(op,12,12) << 12)` decoder
    /// in `DrawerOperational.swift`. Defaults to `[]` (no flags set) so
    /// all existing callers continue to produce zero feature-flag bits.
    public var featureFlags: DrawerFeatureFlags
    /// Exportability of the resulting drawer at capture time.
    /// Encodes into bits 12–17 of the drawer's `adjectiveBitmap`
    /// (cookbook §2.3, 6-bit scale-gapped field; raw 0 = private_,
    /// raw 32 = public_). Defaults to `.private_` (non-exportable) so
    /// all existing callers continue to produce private drawers — the
    /// privacy-preserving default. Supply `.public_` to birth a drawer
    /// that is immediately visible to `filter:exportable` recall
    /// (DEBT-1 write-side fix).
    public var exportability: AdjectiveExportability
    /// Wing to file the drawer into. When `nil` the capture
    /// verb uses `defaultWing()` — "Agentic Memory" — preserving
    /// byte-identical behaviour for all existing callers. Supply a
    /// non-nil value to route a drawer into a specific wing at capture
    /// time (e.g. "User Canon", "Personal") without a post-capture
    /// reanchor step. The follow-up VaultKit/file_memory wiring threads
    /// this field through from the ARIA surface.
    public var wing: String?

    public init(
        content: String,
        channel: CaptureChannel,
        room: RoomID,
        latticeAnchor: LatticeAnchor,
        addedBy: String,
        embeddingModelID: String,
        sensitivity: AdjectiveSensitivity = .normal,
        kind: ContentKind = .prose,
        provenanceChannel: Channel = .uiTyped,
        sourceType: SourceType = .user,
        provenanceSensitivity: Sensitivity = .normal,
        confirmation: Confirmation = .unconfirmed,
        confidence: Confidence = .null,
        lineageID: LineageID? = nil,
        eventTime: Date? = nil,
        featureFlags: DrawerFeatureFlags = [],
        exportability: AdjectiveExportability = .private_,
        wing: String? = nil
    ) {
        self.content = content
        self.channel = channel
        self.room = room
        self.latticeAnchor = latticeAnchor
        self.addedBy = addedBy
        self.embeddingModelID = embeddingModelID
        self.sensitivity = sensitivity
        self.kind = kind
        self.provenanceChannel = provenanceChannel
        self.sourceType = sourceType
        self.provenanceSensitivity = provenanceSensitivity
        self.confirmation = confirmation
        self.confidence = confidence
        self.lineageID = lineageID
        self.eventTime = eventTime
        self.featureFlags = featureFlags
        self.exportability = exportability
        self.wing = wing
    }
}

// MARK: - TunnelCaptureFrame

/// Slots for the `capture` verb applied to a **tunnel** (a graph edge).
/// Per spec § 7.1 / § 7.8.3.
///
/// `capture` is legal on exactly two nouns — drawer and tunnel
/// (AriaLexiconLib `Acceptance.swift`). The drawer path uses
/// `CaptureFrame`; this is the edge-shaped sibling. A tunnel links two
/// locations, so the frame carries source + target endpoints (wing + room
/// + optional drawer id), a free-form `label`, and the typed `kind`.
///
/// There are deliberately no content, lattice-anchor, or embedding slots:
/// a tunnel row stores no content blob, the `tunnels` table has no
/// lattice-anchor columns (the endpoint drawers carry the anchors), and a
/// tunnel has no embedding. The adjective and provenance bitmaps are not
/// exposed; standalone capture initialises them to 0. The operational
/// bitmap exposes `originClass` (bits 6–8), written by
/// `EstateVerbs.capture(TunnelCaptureFrame)` via `BitField.writeField`.
/// Defaults to `.userExplicit` (raw 0) so all existing callers produce
/// a zero operational bitmap byte-identically. One tunnel shape, two
/// entry points (standalone capture and the supersession cascade in
/// `DrawerStore.addDrawerWithCascade`).
public struct TunnelCaptureFrame: Sendable {
    /// Wing of the source endpoint.
    public var sourceWing: String
    /// Room of the source endpoint.
    public var sourceRoom: String
    /// Drawer id at the source endpoint. Nil means "the room itself".
    public var sourceDrawerId: String?
    /// Wing of the target endpoint.
    public var targetWing: String
    /// Room of the target endpoint.
    public var targetRoom: String
    /// Drawer id at the target endpoint. Nil means "the room itself".
    public var targetDrawerId: String?
    /// Free-form relationship label. Domain-specific; not validated
    /// against a closed catalogue (matches `Tunnel.label`).
    public var label: String
    /// Typed relationship kind from the closed vocabulary. Defaults to
    /// `.references` — the same default `Tunnel`'s designated initializer
    /// uses for non-cascade tunnels.
    public var kind: TunnelKind
    /// Actor identifier written into the tunnel's `addedBy` field.
    public var addedBy: String
    /// How this tunnel entered the substrate — user assertion, agent
    /// derivation, import path, sync replication, or schema migration.
    /// Encodes into bits 6–8 of the tunnel's `operationalBitmap` at
    /// capture (via `BitField.writeField`; decoder is `TunnelOriginClass`
    /// in `TunnelOperational.swift`). Defaults to `.userExplicit` (raw 0)
    /// so all existing callers continue to produce a zero operational
    /// bitmap byte-identically.
    public var originClass: TunnelOriginClass
    /// Lifecycle state stamped at capture. Encodes into bits 3–5 of the
    /// tunnel's `operationalBitmap` (decoder is `TunnelLifecycle` in
    /// `TunnelOperational.swift`). Defaults to `.active` (raw 0) so all
    /// existing callers continue to produce a zero operational bitmap
    /// byte-identically. `.proposed` is the agent-derived review state:
    /// the contradiction hunter captures `contradicts` tunnels as
    /// `.proposed` and `respondToTunnel` moves them to `.active`
    /// (accepted) or `.withdrawn` (rejected).
    public var lifecycle: TunnelLifecycle

    public init(
        sourceWing: String,
        sourceRoom: String,
        targetWing: String,
        targetRoom: String,
        label: String,
        addedBy: String,
        sourceDrawerId: String? = nil,
        targetDrawerId: String? = nil,
        kind: TunnelKind = .references,
        originClass: TunnelOriginClass = .userExplicit,
        lifecycle: TunnelLifecycle = .active
    ) {
        self.sourceWing = sourceWing
        self.sourceRoom = sourceRoom
        self.sourceDrawerId = sourceDrawerId
        self.targetWing = targetWing
        self.targetRoom = targetRoom
        self.targetDrawerId = targetDrawerId
        self.label = label
        self.kind = kind
        self.addedBy = addedBy
        self.originClass = originClass
        self.lifecycle = lifecycle
    }
}

// MARK: - RecallFrame

/// Slots for the `recall` verb. Per spec § 7.8.3.
public struct RecallFrame: Sendable {
    /// Filter chain interpreted as implicit conjunction
    /// (equivalent to `Filter.all(filterChain)`). Per spec § 7.9.1.
    /// An empty chain is accepted: `BitmapEvaluator.insertDefaults`
    /// prepends default state, trust, and sensitivity filters before
    /// evaluation, so an empty chain recalls currently-believed content.
    public var filterChain: [Filter]
    /// How much of each row to hydrate. Per spec § 7.3.
    public var hydrationLevel: HydrationLevel
    /// Maximum rows per page. nil = implementation default.
    public var limit: Int?
    /// Ordering of results.
    public var ordering: Ordering
    /// Historical reconstruction — return rows as they were at
    /// this timestamp. nil = current state. Per spec § 6.8.
    public var asOf: HLC?
    /// How many of the surfaced rows to write as recall-trace rows.
    /// nil = write NO trace rows (the default). n = write at most the
    /// first n rows that were returned to the caller. Only the
    /// GLK RecallDirector primary locus call sets this; all other
    /// estate.recall calls leave it nil to avoid silent write amplification.
    /// Zero trace rows is correct for internal or VaultBridge-style scans
    /// that do not participate in the reward cycle.
    public var traceLimit: Int?

    public init(
        filterChain: [Filter],
        hydrationLevel: HydrationLevel = .structured,
        limit: Int? = nil,
        ordering: Ordering = .byCaptureTimeDesc,
        asOf: HLC? = nil,
        traceLimit: Int? = nil
    ) {
        self.filterChain = filterChain
        self.hydrationLevel = hydrationLevel
        self.limit = limit
        self.ordering = ordering
        self.asOf = asOf
        self.traceLimit = traceLimit
    }
}

// MARK: - MutationKind

/// Named mutation operations for the `mutate` verb. Per spec § 7.8.3.
///
/// Callers express intent in named cases; the evaluator translates
/// each case into the appropriate bitmap mutation (state field,
/// confirmation axis, sensitivity tier, trust axis). No caller-facing
/// raw bit value participates in this enum.
public enum MutationKind: Sendable {
    /// Move the row's confirmation axis to `.userConfirmed`.
    case confirm
    /// Move the row's state to `.rejected` (terminal cluster).
    case reject
    /// Move the row's state to `.contested` (still currently-believed
    /// cluster, but flagged for resolution).
    case contest
    /// Resolve a contested row back to `.active` once the contest is
    /// settled.
    case resolve
    /// Explicit supersession (used when the caller knows the new
    /// version's lineageID does not match, but the semantic
    /// supersession relationship should still be recorded).
    case supersede
    /// Restore a historical (Cluster-B) row to `.active`. Legal from
    /// `.decayed`, `.withdrawn`, and `.expired` unconditionally; legal
    /// from `.superseded` only when no living successor holds the
    /// lineage head (otherwise it raises `disciplineViolation` naming
    /// the lineage conflict). Refused from live (Cluster-A) and terminal
    /// (`.rejected` / `.tombstoned`) states. See `Estate.mutate`.
    case revive
    /// Move the row's state to `.accepted` (terminal cluster — the
    /// row is canonical and will not move again).
    case accept
    /// Set the row's sensitivity axis to the supplied tier.
    case correctSensitivity(AdjectiveSensitivity)
    /// Set the row's trust axis to the supplied value.
    case correctTrust(Trust)
    /// Set the row's exportability axis to the supplied value.
    ///
    /// Exportability lives in adjectiveBitmap bits 12–17 (cookbook §2.3,
    /// 6-bit scale-gapped field; raw 0 = private_, raw 32 = public_).
    /// Default is `.private_` (non-exportable) — this mutation is the
    /// only path to mark a drawer public after capture, completing the
    /// exportability write side (DEBT-1).
    case correctExportability(AdjectiveExportability)
}

// MARK: - LearnFrame

/// Slots for the `learn` verb. Per spec § 7.8.2
/// (`LearnFrame { source, handle, mode, refreshPolicy }`).
///
/// `learn` brings an authoritative external reference into the estate. The
/// reference's genuine lattice anchor comes from `source` — a
/// `SourceCatalogEntry` carries the source's classified lattice position,
/// which every reference learned from it inherits. This is how `learn`
/// derives a real anchor instead of fabricating a sentinel from a bare
/// handle (P1 mandate). The verb catalogs `source` durably (if not already
/// present) and writes a `LearnedReference` anchored to it.
public struct LearnFrame: Sendable {
    /// The source this reference is learned from. Carries the genuine
    /// lattice anchor the learned reference inherits. `Estate.learn`
    /// catalogs it (keyed by `source.handle`) if no entry exists yet.
    public var source: SourceCatalogEntry

    /// The reference handle — the URI / locator the learned reference
    /// points at. Distinct from `source.handle` (the source's own
    /// locator). Must be non-empty; `Estate.learn` rejects an empty handle
    /// with `LocusKitError.invalidContent`.
    public var handle: String

    /// Whether the reference is held by pointer (`.byReference`) or its
    /// content was ingested (`.byIngestion`). Encoded into the learned
    /// reference's operational bitmap (cookbook § 2.4 bit 12).
    public var mode: LearnMode

    /// How often the reference is re-grounded against its source. Encoded
    /// into the learned reference's operational bitmap (cookbook § 2.4
    /// bits 0–5).
    public var refreshPolicy: RefreshPolicy

    public init(
        source: SourceCatalogEntry,
        handle: String,
        mode: LearnMode = .byReference,
        refreshPolicy: RefreshPolicy = .weekly
    ) {
        self.source = source
        self.handle = handle
        self.mode = mode
        self.refreshPolicy = refreshPolicy
    }
}

// MARK: - ProposeFrame

/// Slots for the `propose` verb at the LocusKit substrate. Per spec § 7.8.3.
///
/// Distinct from `GeniusLocusKit.ProposeFrame`, which carries a Brain-layer
/// `ProposalKind` (String-based routing labels). This LocusKit type carries
/// a substrate-axis `ProposalKind` (Int-based, cookbook §2.4 bits 0–5).
/// The GLK boundary maps Brain-kind to substrate-kind at the
/// `mapBrainKindToSubstrate` translation point.
public struct ProposeFrame: Sendable {
    /// The row this proposal is about. Must be non-empty; Estate.propose
    /// throws LocusKitError.drawerNotFound if no drawer with this id exists.
    public var target: RowID
    /// Substrate-axis proposal kind (cookbook §2.4 bits 0–5).
    public var kind: ProposalKind
    /// Optional free-text justification.
    public var justification: String?
    /// Who or what confirms this proposal (cookbook §2.4 bits 12–17). Defaults
    /// to `.human` — the same value the operational bitmap held implicitly
    /// before this slot existed, so callers that omit it stay byte-identical.
    public var confirmation: ProposalConfirmationSource
    /// What class of producer generated this proposal (cookbook §2.4 bits
    /// 18–23). Defaults to `.dreamingDaemon` (raw 0) — the implicit pre-slot
    /// value. Daemon-emitted proposals should set this to their true producer
    /// class so provenance reflects reality rather than the zero fallback.
    public var generatedBy: ProposalGeneratedByClass
    /// Coarse confidence bucket for this proposal (cookbook §2.4 bits 24–29).
    /// Defaults to `.null` (raw 0) — the implicit pre-slot value.
    public var confidence: ProposalConfidenceBucket

    /// - Parameters:
    ///   - target: the row this proposal is about.
    ///   - kind: substrate-axis proposal kind.
    ///   - justification: optional free-text justification.
    ///   - confirmation: confirmation source (default `.human`).
    ///   - generatedBy: producer class (default `.dreamingDaemon`).
    ///   - confidence: confidence bucket (default `.null`).
    ///
    /// The three provenance defaults reproduce the exact zero values the
    /// propose verb wrote implicitly before these slots were wired, so any
    /// caller that omits them produces a byte-identical operational bitmap.
    public init(
        target: RowID,
        kind: ProposalKind,
        justification: String? = nil,
        confirmation: ProposalConfirmationSource = .human,
        generatedBy: ProposalGeneratedByClass = .dreamingDaemon,
        confidence: ProposalConfidenceBucket = .null
    ) {
        self.target = target
        self.kind = kind
        self.justification = justification
        self.confirmation = confirmation
        self.generatedBy = generatedBy
        self.confidence = confidence
    }
}

// MARK: - AssociateFrame

/// Slots for the `associate` verb at the LocusKit substrate.
///
/// Creates or strengthens an Association row between two rows (cookbook §10.8).
public struct AssociateFrame: Sendable {
    /// One endpoint of the association.
    public var a: RowID
    /// The other endpoint.
    public var b: RowID
    /// Coarse weight in [0, 1]. The Brain layer interprets this; the substrate
    /// stores it opaquely.
    public var weight: Double

    public init(a: RowID, b: RowID, weight: Double) {
        self.a = a
        self.b = b
        self.weight = weight
    }
}

// MARK: - HydrationLevel

/// How much of a row to include in a recall response. Per spec § 7.3.
public enum HydrationLevel: Sendable {
    /// Bitmap columns + structured-row fields only. No blob reads.
    case structured
    /// All rungs hydrated on demand.
    case full
    /// Bitmap columns only — the lightest tier.
    case bitmapOnly
}

// MARK: - Ordering

/// Result ordering for recall. Per spec § 7.8.3.
///
/// Relevance ordering (`byRelevanceDesc`) is not present on this enum.
/// Relevance requires the vector index from VectorKit; LocusKit is a
/// bitmap-filter engine with no scoring signal. Callers that need
/// relevance-ranked results must go through GLK RecallDirector's scored
/// lane (NeuronKit/HybridRecall), which composes VectorKit on top of
/// LocusKit. Exposing a relevance case here produced input-order results
/// advertised as relevance-ordered — an honest API must either implement
/// the behaviour or remove the case. It was removed.
public enum Ordering: Sendable {
    /// Newest captured first.
    case byCaptureTimeDesc
    /// Oldest captured first.
    case byCaptureTimeAsc
    /// Lexicographic ascending by `room`.
    case byRoomAsc
}
