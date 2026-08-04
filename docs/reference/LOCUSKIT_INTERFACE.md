---
title: LocusKit Interface
version: 1.18.0
status: active
date: 2026-08-03
description: Public API surface for LocusKit in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/LOCUSKIT_SPEC.md
---

# LocusKit Interface

This document describes the public API surface of LocusKit in both ports,
in two tiers within § 2. Tier 1 is the CONSUMED CONTRACT — the types
GeniusLocusKit, NeuronKit, and aria-mcp actually import (the Estate actor,
the four nouns, the verb frames, the recall stream, the filter algebra, the
bitmap value enums, the manifest, and the error surfaces) — documented with
bilingual signatures. Tier 2 (§ 2's closing subsection) is the BROADER
SURFACE — the internal stores, validators, fingerprint machinery, and bitmap
helpers that are public for testing and intra-kit use, consumed by the kit's
own pipeline and tests rather than another package; a table of contents
(name + role + source file). The companion SPEC carries the behavioral
contracts (invariants I-1…I-13, conformance C-1…C-8).

## § 1 — Package layout

**Swift:** `packages/kits/LocusKit/`

- `Sources/LocusKit/` — 33 files: one per noun, per bitmap-axis family,
  per store, plus the `Estate` actor and its verb / audit extensions.
- `Tests/LocusKitTests/`
- `Package.swift`

**Rust:** `packages/kits/LocusKit/rust/`

- `src/` — one module per Swift file (`drawer.rs`, `estate.rs`,
  `estate_verbs.rs`, `filter.rs`, …) plus `drawer_store_inmemory.rs`
  (crate `locus-kit`).

Naming differs by port convention (Swift `addDrawer` / `bitmapAuditTrail`;
Rust `add_drawer` / `bitmap_audit_trail`). The two ports also differ in
*shape* — Swift is `actor`/`async`, the Rust version is synchronous and takes
`now: i64` explicitly; the Rust `DrawerStore` is a trait with an in-memory
implementation only. The value-level results agree (SPEC § 8, I-11).

### GLK shared-content composition (1.1 target)

LocusKit's public API remains independent of CorpusKit. When composed by GLK,
the existing `Drawer` surface is the canonical content-source surface:

- `Drawer.id` is the identity used by CorpusKit indexes and returned by Corpus
  recall; GLK does not mint a chunk or passage identity for it.
- `Drawer.content` is read through a GLK-owned `CorpusContentSource` adapter.
  CorpusKit receives content for indexing but does not own or copy the Drawer.
- capture, supersession, withdrawal, and expunge are converted by GLK into
  revision/digest/cursor-bearing source changes. Attached Corpus queue payloads
  carry those references, not verbatim Drawer text.
- LocusKit exposes no CorpusKit type and writes no CorpusKit table. CorpusKit
  likewise imports no LocusKit type; GLK owns the adapter and lifecycle.

`Drawer.chunkIndex` is source/provenance metadata already present on a canonical
Drawer. It is not a CorpusKit RAG passage, does not authorize a second content
row, and is not used as GLK recall identity.

> **Two-tier surface.** LocusKit declares 74 public types in the Swift version,
> of which 33 are referenced by another package (GeniusLocusKit, NeuronKit,
> aria-mcp). Several of those measured hits are
> common-word coincidences from unrelated local types in the consumer
> (`State`, `Channel`, `Sensitivity`, `Vector`, `Element`, `AsyncIterator`)
> — the genuinely consumed contract is the ~24 types in Tier 1 below. § 2
> Tier 1 documents that contract in full. The Tier 2 subsection at the end of
> § 2 is a table of contents for the rest: public for testing and intra-kit
> use, consumed by the kit's own pipeline and tests rather than another
> package.

## § 2 — Public types

### Tier 1 — consumed contract

#### `Estate`

The top-level handle to one estate (SPEC § 1, I-1). An actor in Swift; a
synchronous struct in Rust (SPEC § 8).

```swift
public actor Estate {
    public static let expectedBitmapLayoutVersion: String   // "v0.35"

    public static func open(storage: any Storage, owner: OwnerCredentials) async throws -> Estate
    public static func create(storage: any Storage, owner: OwnerCredentials,
                              manifest initialValues: ManifestValues? = nil) async throws -> Estate
    public func close() async throws

    public var manifest: ManifestValues { get async throws }
    public var estateUUID: UUID { get }

    // Estate metadata — consumer key-value surface over the manifest table
    // (Estate.swift). The substrate-owned, durable, lowest-level KV primitive
    // upper layers (e.g. NeuronKit daemons) persist their own state through,
    // rather than reaching around the substrate to a host-owned store. Consumers
    // MUST namespace keys (e.g. "neuronkit.dreaming.policy") to avoid collision
    // with the typed v1 ManifestKey set. Values survive restarts.
    public func meta(key: String) async throws -> String?
    public func setMeta(key: String, value: String) async throws

    // Verbs (extension Estate, EstateVerbs.swift):
    public func capture(_ frame: CaptureFrame) async throws -> Drawer
    // captureBatch: insert all frames in a single storage.transaction() — one
    // write-lock acquisition, one COMMIT, no per-row fsync under WAL mode.
    // Handles with no active lineage predecessor use insertFreshBatch (all in
    // one transaction). Frames with a predecessor fall back to per-item
    // addDrawerCovered for correct supersession cascade. Post-insert coverage
    // (containerFP.orIn + rollupMerkleRoots) runs for fresh-batch drawers.
    // Returns drawers in input order. Callers invoke moot_reindex / moot_dream
    // afterwards to light BM25/vector lanes.
    public func captureBatch(_ frames: [CaptureFrame]) async throws -> [Drawer]
    public func recall(_ frame: RecallFrame) async -> RecallStream
    // Frame-aware by-id load (Estate.swift): O(candidates) by-id load that applies
    // the frame's filter chain via BitmapEvaluator (the exact recall pipeline), so
    // `admissible` is precisely the frame-filtered subset of `ids`. `loadedIDs`
    // reports every id whose row physically loaded (regardless of the frame filter)
    // so callers gate a drop on load success: an id that loaded but is absent from
    // `admissible` failed the frame filter (drop); an id absent from `loadedIDs`
    // did not load (degrade, never drop). Used by GLK RecallDirector to honor the
    // recall frame's state filter on the corpus/vector hydration join.
    public func getDrawers(ids: [String], matchingFrame frame: RecallFrame,
                           hydrationLevel: HydrationLevel) async throws -> FrameFilteredDrawers
    public func withdraw(rowID: RowID, reason: String? = nil) async throws
    public func mutate(rowID: RowID, kind: MutationKind, payload: String? = nil) async throws
    // sealAudit: true (default) → audit sealed atomically inside this call (direct-caller contract).
    // sealAudit: false → audit returned unsealed; caller seals via sealExpungeAudit/sealExpungeOrphanAudit.
    // The GLK orchestration path (§B-2a) uses sealAudit:false to defer the seal until after the
    // cross-kit vector delete, preventing a false-success audit on step-2 failure.
    @discardableResult
    public func expunge(rowID: RowID, reason: String, confirmation: Bool, now: Date = Date(), sealAudit: Bool = true) async throws -> AuditEvent?
    public func sealExpungeAudit(_ event: AuditEvent) async throws
    public func sealExpungeOrphanAudit(rowID: RowID, successEvent: AuditEvent, now: Date) async throws
    // sealExpungeOrphanAuditSynthetic: sweep path — constructs orphan event from current drawer
    // state (beforeBitmaps: nil). Used by GLK runExpungeIntegritySweep (§B-2b) when the
    // original gate event was lost in a crash window.
    func sealExpungeOrphanAuditSynthetic(rowID: RowID, now: Int64) async throws
    // tombstonedRowsWithoutExpungeAudit: sweep path — returns tombstoned drawers with no
    // "tombstone" or "expungeOrphan" audit event (crash-window set for the GLK sweep).
    // NOTE: DrawerStore.tombstonedRowsWithoutExpungeAudit is `public func` (called by GLK);
    // Estate.tombstonedRowsWithoutExpungeAudit is `internal func` (wraps the store, GLK-only).
    func tombstonedRowsWithoutExpungeAudit() async throws -> [Drawer]   // Estate: internal; DrawerStore: public
    public func reanchor(rowID: RowID, toRoom: RoomID? = nil, toLattice: LatticeAnchor? = nil) async throws
    public func learn(_ frame: LearnFrame) async throws

    // History (extension Estate, EstateAudit.swift):
    // Returns the sealed AuditEvent log for one row (HLC order, genesis-forward).
    // The wall-clock range form auditTrail(since:until:) was dropped — HLC is the
    // ordering axis (§11 clock decision; wall-clock is not a fold axis).
    func auditTrail(rowID: RowID) async throws -> [AuditEvent]   // internal
    // Reconstructs bitmaps at a past HLC via AuditLogFold.projectStateAt (SPEC B-9).
    // Parameter label is asOf: (not at:), type is HLC (not Date).
    func bitmapState(rowID: RowID, asOf: HLC) async throws -> BitmapState   // internal

    // Association graph (extension Estate, Estate.swift):
    public func tunnelsFromWing(_ wing: String) async throws -> [Tunnel]

    // Dreaming substrate reads (extension Estate, Estate.swift):
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem]
    public func allTunnels() async throws -> [Tunnel]

    // Dataset handle verbs (public extension Estate, DatasetHandle.swift — MX-TAB-4 / MX-TAB-5):
    // captureDatasetHandle is the ONLY authorised creation path for contentKind == .dataset
    // drawers. The FDC classifier (moot_n_fdc / runReclassifyFDC) is barred from emitting this
    // content kind; dataset handles are skipped during every reclassification sweep (SPEC B-13).
    // Sensitivity floor (v1): rows in the backing dataset table are expected at or below the
    // handle's sensitivity tier — operator convention, no per-row enforcement yet (SPEC B-14).
    func captureDatasetHandle(datasetId: UUID, columns: [DatasetColumnSummary], rowCount: Int,
                              sourceDescription: String, wing: String? = nil, room: String,
                              addedBy: String, sensitivity: AdjectiveSensitivity = .normal,
                              latticeAnchor: LatticeAnchor) async throws -> Drawer
    // Return all .dataset-kind drawers referencing datasetId, ordered by filedAt ascending.
    // Full-corpus scan in v1 (O(datasets), not O(drawers)); targeted index deferred.
    func findDatasetHandles(datasetId: UUID) async throws -> [Drawer]
    // Return the cluster-A (active/pending/contested/accepted) non-tombstoned handle.
    // Throws drawerNotFound when no handle exists for datasetId; withdrawnDatasetHandle when all
    // handles are cluster-B. Withdrawal is a belief-state change — the backing table is NOT
    // dropped (use GLK VerbSurface.expunge to erase both handle and table) (SPEC B-15).
    func resolveActiveDatasetHandle(datasetId: UUID) async throws -> Drawer
    // Patch MX-TAB-5 computed signatures into an existing dataset handle's content JSON.
    // Decodes DatasetHandleContent from rowID, replaces tableSignature / columnSignatures,
    // re-encodes, writes via DrawerStore.updateDatasetContent — no audit event, no supersession
    // cascade. Idempotent: same inputs produce the same hex strings. Called by
    // GeniusLocusKit.computeDatasetSignatures (MX-TAB-5). Throws drawerNotFound when rowID is
    // absent or the update affects zero rows; invalidContent when the stored JSON fails to decode.
    func patchDatasetHandleSignatures(rowID: String, tableSignature: String,
                                      columnSignatures: [String: String], now: Date) async throws -> Drawer
    // Read one drawer by id, unfiltered (tombstoned / content-zeroed rows included). Used by
    // GLK VerbSurface.expunge to read DatasetHandleContent BEFORE the storage expunge zeroes the
    // blob, enabling the dataset-erase cascade to extract datasetId and call
    // DatasetStore.dropDataset (SPEC B-15).
    func drawerById(rowID: String) async throws -> Drawer?
    // Append an arbitrary audit event to this estate's audit log. Semantically distinct from
    // sealExpungeAudit: records supplementary events such as the "datasetTableDrop" annotation
    // that accompanies the erase of a .dataset-kind handle. Used by GLK VerbSurface.expunge
    // Step 2.5 (SPEC B-15).
    func appendAuditEvent(_ event: AuditEvent) async throws
}
```
**Rust:** `pub struct Estate` with `open`, `create`, `close`, `manifest`,
`estate_uuid`, the consumer metadata surface `meta(key: &str) ->
Result<Option<String>, EstateError>` / `set_meta(key: &str, value: &str) ->
Result<(), EstateError>` (mirrors Swift `meta`/`setMeta`), and verbs
`capture(frame, now: i64)`, `recall(frame, now: i64)`,
`withdraw(...)`, `mutate(...)`, `expunge(...)`, `reanchor(...)`, `learn(...)`,
each taking `now: i64`, plus the association-graph read
`tunnels_from_wing(wing: &str) -> Result<Vec<Tunnel>, LocusKitError>`.
The frame-aware by-id load is
`get_drawers_matching_frame(ids: &[RowID], frame: &RecallFrame) ->
Result<FrameFilteredDrawers, LocusKitError>` (`estate_verbs.rs`), where
`FrameFilteredDrawers { admissible: Vec<Drawer>, loaded_ids: HashSet<String> }`
mirrors the Swift struct. The Rust GLK recall path derives its `drawer_index`
from a full `estate.recall(frame)` scan and so does not call this on its hot
path; the capability is mirrored for cross-port surface parity (both ports apply
the same `BitmapEvaluator` filter chain to a by-id candidate set).
All synchronous (SPEC § 8). `propose` / `associate`
are reached through the tunnel and KG-fact store paths, not as dedicated verb
methods.

The Rust port exposes the dataset-handle verbs as `pub fn` on `Estate`
(`estate_verbs.rs`): `capture_dataset_handle(dataset_id: Uuid, columns:
Vec<DatasetColumnSummary>, row_count: i64, source_description: &str,
wing: Option<&str>, room: &str, added_by: &str, sensitivity_raw: i64,
udc_code: &str, now: i64) -> Result<Drawer, LocusKitError>` (the `sensitivity_raw`
parameter carries the `AdjectiveSensitivity` raw value 0/16/32/48 in place of
the Swift named enum — no Rust enum boundary crossing for this seam);
`find_dataset_handles(dataset_id: Uuid) -> Result<Vec<Drawer>, LocusKitError>`;
`resolve_active_dataset_handle(dataset_id: Uuid) -> Result<Drawer, LocusKitError>`;
`drawer_by_id(row_id: &str) -> Result<Option<Drawer>, LocusKitError>`;
`append_audit_event(event: &AuditEvent) -> Result<(), LocusKitError>`.
`patch_dataset_handle_signatures(row_id: &str, table_signature: &str,
column_signatures: HashMap<String,String>, now: i64) -> Result<Drawer, LocusKitError>`
is on `Estate` in the Rust port too (`dataset_handle.rs`). All mirror the Swift
counterparts in semantics; the signed payload format and error cases are identical.

#### `Drawer`

The atomic, content-immutable memory unit (SPEC § 1, I-3). Three Int64
bitmaps carry all categorical/boolean state (I-2).

```swift
public struct Drawer: Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let lineageID: UUID
    public let content: String                 // verbatim, never mutated (I-3)
    // Wing and room are NOT stored on Drawer. The drawer belongs to a room node in
    // the estate containment tree. Display names are resolved via
    // DrawerStore.resolveNodeNames(parentNodeIds:) when needed.
    public let parentNodeId: String            // UUID of the room node (depth=2 in node tree)
    public let sourceFile: String?
    public let chunkIndex: Int?
    public let addedBy: String
    public let filedAt: Date                    // ingest clock; TEXT ISO8601 (I-7)
    public let eventTime: Date                  // authored-in-world clock
    public let embeddingModelID: String         // modelID-tagging (I-4)
    public let tombstonedAt: Date?
    public let removedByBatch: String?
    public let provenance: Int64                // bitmap
    public let adjectiveBitmap: Int64           // bitmap (state/sensitivity/exportability/trust)
    public let operationalBitmap: Int64         // bitmap (channel/kind/flags/state-ext)
    public let udcCode: String                  // lattice anchor, NOT NULL DEFAULT '' (I-5)
    public let udcFacets: String?
    public let wikidataQID: String?
    public let wikidataQidsSecondary: String?
    // Distilled representation quad — derived compression of `content`.
    // NULL-together; every content-touching write clears all four.
    public let distilled: String?
    public let distilledPipelineVersion: String?
    public let distilledTokenCount: Int64?
    public let distilledAt: Date?
    // Subject trio — one-sentence AI-facing summary returned in the
    // progressive-recall dense row. RETURNED, never searched or indexed.
    // NULL-together; cleared by the same content-write invalidation as
    // the distilled quad. NULL `subject` = backfill-eligible.
    public let subject: String?                 // ≤ 120 chars (subjectLengthContract)
    public let subjectPipelineVersion: String?  // producer provenance: "ai-v1", "minillm-v1"
    public let subjectAt: Date?
    public init(id: String = UUID().uuidString, content: String, parentNodeId: String,
                sourceFile: String? = nil, chunkIndex: Int? = nil, addedBy: String,
                filedAt: Date, eventTime: Date? = nil, embeddingModelID: String,
                tombstonedAt: Date? = nil, removedByBatch: String? = nil,
                provenance: Int64 = 0, adjectiveBitmap: Int64 = 0, operationalBitmap: Int64 = 0,
                lineageID: UUID = UUID(), udcCode: String = "", udcFacets: String? = nil,
                wikidataQID: String? = nil, wikidataQidsSecondary: String? = nil,
                distilled: String? = nil, distilledPipelineVersion: String? = nil,
                distilledTokenCount: Int64? = nil, distilledAt: Date? = nil,
                subject: String? = nil, subjectPipelineVersion: String? = nil,
                subjectAt: Date? = nil)

    // Computed accessors (no Bool stored property, I-2):
    public var sourceType: SourceType; public var confirmation: Confirmation
    public var confidence: Confidence; public var channel: Channel; public var sensitivity: Sensitivity
    public var state: State; public var adjectiveSensitivity: AdjectiveSensitivity
    public var exportability: AdjectiveExportability; public var trust: Trust
    public var captureChannel: CaptureChannel; public var contentKind: ContentKind
    public var featureFlags: DrawerFeatureFlags
    public func hasFeatureFlag(_ flag: DrawerFeatureFlags) -> Bool
    public var stateExtensionActive: Bool
    public var isCurrentlyBelieved: Bool; public var isKnewPast: Bool; public var isTerminal: Bool
    public var isUserConfirmed: Bool; public var isInstruction: Bool; public var isContested: Bool
}
```
**Rust:** `pub struct Drawer` with the same fields (`snake_case`) and the
same accessor set; bitmap decode is byte-identical.

#### `KGFact`, `DiaryEntry`, `Tunnel`

The other three nouns. Each is an immutable `Sendable` struct with Int64
bitmaps (I-2) and TEXT ISO8601 dates (I-7).

```swift
public struct KGFact: Equatable, Hashable, Codable, Sendable {
    public let id, subject, predicate, object, sourceDrawerID: String
    // sourceDrawerID holds a LOCAL drawer id or "" — never a host name or a
    // foreign estate's key. Those have their own fields:
    public let addedBy: String            // filing host/agent identity, "" when unrecorded
    public let foreignSourceKey: String   // foreign palace's stable source key, "" when local
    public let foreignRecordID: String    // foreign palace's own record id, "" when local
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
    public let filedAt: Date
    public init(id: String = UUID().uuidString, subject: String, predicate: String, object: String,
                sourceDrawerID: String, addedBy: String = "", foreignSourceKey: String = "",
                foreignRecordID: String = "", adjectiveBitmap: Int64 = 0,
                operationalBitmap: Int64 = 0, provenanceBitmap: Int64 = 0, filedAt: Date)
    // All four adjective-bitmap axes (cookbook §2.3 / §5.5; same encoding as Drawer):
    public var state: State                            // bits 0–5,  default .active
    public var adjectiveSensitivity: AdjectiveSensitivity  // bits 6–11, default .normal
    public var exportability: AdjectiveExportability   // bits 12–17, default .private_
    public var trust: Trust                            // bits 18–23, default .verbatim
    // operational accessors in KGFactOperational.swift (Tier 2)
}

public struct DiaryEntry: Equatable, Hashable, Codable, Sendable {
    public let id, agentName, entry, topic, wing, room: String
    public let filedAt: Date
    public let embeddingModelID: String        // I-4
    public let tombstonedAt: Date?; public let removedByBatch: String?
    public let operationalBitmap: Int64
    public init(id: String = UUID().uuidString, agentName: String, entry: String, topic: String,
                wing: String, room: String, filedAt: Date, embeddingModelID: String,
                tombstonedAt: Date? = nil, removedByBatch: String? = nil, operationalBitmap: Int64 = 0)
    // operational accessors in DiaryOperational.swift (Tier 2)
}

public struct Tunnel: Equatable, Hashable, Codable, Sendable {
    public let id, sourceWing, sourceRoom: String; public let sourceDrawerId: String?
    public let targetWing, targetRoom: String; public let targetDrawerId: String?
    public let label: String; public let kind: TunnelKind
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
    public let addedBy: String; public let filedAt: Date
    public let tombstonedAt: Date?; public let removedByBatch: String?
    public let orderKey: Double?  // fractional-index sibling ordering under parent edges (the node-integrity contract §11)
    public init(id: String, sourceWing: String, sourceRoom: String, sourceDrawerId: String? = nil,
                targetWing: String, targetRoom: String, targetDrawerId: String? = nil,
                label: String, kind: TunnelKind = .references, adjectiveBitmap: Int64 = 0,
                operationalBitmap: Int64 = 0, provenanceBitmap: Int64 = 0, addedBy: String,
                filedAt: Date, tombstonedAt: Date? = nil, removedByBatch: String? = nil,
                orderKey: Double? = nil)
    public var direction: TunnelDirection; public var lifecycle: TunnelLifecycle
    public var originClass: TunnelOriginClass; public var strength: TunnelStrength
    public var hasInverse: Bool   // bit 12, computed (I-2)
}
```
**Rust:** `pub struct KGFact`, `DiaryEntry`, `Tunnel` mirror these fields and
accessors (`snake_case`).

#### `Association`, `Proposal`, `LearnedReference`

The three substrate-derived / grounding nouns behind the `propose`,
`associate`, and `learn` lexicon entries (SPEC § 7.2). Each is an immutable
`Sendable` value type with the three Int64 bitmaps (I-2) and TEXT ISO8601
dates (I-7); verb behaviour lives in `EstateVerbs`, not on the noun. Per the
§ 7.2 acceptance matrix: `Association` accepts mutate / expunge / recall (no
capture, no withdraw); `Proposal` accepts mutate / withdraw / expunge /
recall; `LearnedReference` accepts learn / mutate / withdraw / expunge /
recall.

```swift
public struct Association: Equatable, Codable, Sendable {
    public let id: String
    public let sourceWing, sourceRoom: String; public let sourceDrawerId: String?
    public let targetWing, targetRoom: String; public let targetDrawerId: String?
    public let label: String
    public let latticeAnchor: LatticeAnchor
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
    public let addedBy: String; public let filedAt: Date
    public let tombstonedAt: Date?; public let removedByBatch: String?
    public init(/* memberwise; bitmaps default 0 */)
    // operational axes in AssociationOperational.swift (Tier 2):
    // AssociationSignalSources (OptionSet), AssociationDecayClass, AssociationArity
}

public struct Proposal: Equatable, Codable, Sendable {
    public let id: String
    public let targetRowID: String                 // empty for brand-new-object proposals
    public let justification: String?
    public let candidateState: Int64
    public let latticeAnchor: LatticeAnchor
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
    public let filedAt: Date
    public init(/* memberwise; bitmaps default 0 */)
    // operational axes in ProposalOperational.swift (Tier 2):
    // ProposalKind, ProposalTargetObjectType, ProposalConfirmationSource,
    // ProposalGeneratedByClass, ProposalConfidenceBucket
}

public struct LearnedReference: Equatable, Codable, Sendable {
    public let id: String
    public let sourceCatalogID: String             // SourceCatalogEntry reference
    public let handle: String                      // indexed; learn dedupes on it
    public let latticeAnchor: LatticeAnchor
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
    public let addedBy: String; public let filedAt: Date
    public let tombstonedAt: Date?; public let removedByBatch: String?
    public init(/* memberwise; bitmaps default 0 */)
    // operational axes in LearnedReferenceOperational.swift (Tier 2):
    // RefreshPolicy, DriftSeverity, LearnMode, LearnedReferenceSource
}

public struct SourceCatalogEntry: Equatable, Codable, Sendable {
    public let id: String                          // LearnedReference.sourceCatalogID points here
    public let kind: SourceKind                    // stored as Int raw
    public let handle: String                      // the source's own locator; indexed
    public let latticeAnchor: LatticeAnchor        // genuine, non-empty; learn inherits it
    public let firstSeen: Date
    public let addedBy: String
    public init(/* memberwise */)
}
// SourceKind: .user/.federation/.householdPairing/.fleetPairing/
//   .tierInheritance/.pairedEstate (Int raw; .fromRaw fails closed to .user)
```

`SourceCatalogEntry` is the durable, queryable record of an external source
from which references are learned (spec § 7.8.2). The `learn` verb derives
every `LearnedReference`'s genuine lattice anchor from the matching catalog
entry — never a sentinel. Persisted in the `source_catalog` table
(`idx_source_catalog_handle`). Store surface: `addSourceCatalogEntry`,
`getSourceCatalogEntry(id:)`, `sourceCatalogEntry(forHandle:)`.
**Rust:** `pub struct Association`, `Proposal`, `LearnedReference` (each with
`pub fn new(…)`) mirror these fields (`snake_case`); the operational-axis
enums (`AssociationSignalSources` as an `i64` newtype, `AssociationDecayClass`,
`AssociationArity`, `ProposalKind`, `ProposalTargetObjectType`,
`ProposalConfirmationSource`, `ProposalGeneratedByClass`,
`ProposalConfidenceBucket`, `RefreshPolicy`, `DriftSeverity`, `LearnMode`,
`LearnedReferenceSource`) mirror the Swift raw values byte-identically
(`association.rs`, `proposal.rs`, `learned_reference.rs` + `*_operational.rs`).

#### Verb frames: `CaptureFrame`, `RecallFrame`, `LearnFrame`, `MutationKind`

The named-slot inputs to the verbs (SPEC § 5). No raw bit value crosses these
boundaries.

```swift
public struct CaptureFrame: Sendable {
    public var content: String; public var channel: CaptureChannel
    public var sensitivity: AdjectiveSensitivity; public var kind: ContentKind
    public var exportability: AdjectiveExportability  // bits 12–17; default .private_
    // Provenance axes written at capture time (provenance bitmap, cookbook §2.5):
    public var provenanceChannel: Channel; public var sourceType: SourceType
    public var provenanceSensitivity: Sensitivity   // bits 30–35; default .normal
    public var confirmation: Confirmation            // bits 18–23; default .unconfirmed
    public var confidence: Confidence                // bits 24–29; default .null
    public var lineageID: LineageID?; public var room: RoomID; public var latticeAnchor: LatticeAnchor
    public var addedBy: String; public var embeddingModelID: String; public var eventTime: Date?
    public init(content: String, channel: CaptureChannel, room: RoomID, latticeAnchor: LatticeAnchor,
                addedBy: String, embeddingModelID: String, sensitivity: AdjectiveSensitivity = .normal,
                kind: ContentKind = .prose, provenanceChannel: Channel = .uiTyped,
                sourceType: SourceType = .user, provenanceSensitivity: Sensitivity = .normal,
                confirmation: Confirmation = .unconfirmed, confidence: Confidence = .null,
                lineageID: LineageID? = nil, eventTime: Date? = nil,
                featureFlags: DrawerFeatureFlags = [],
                exportability: AdjectiveExportability = .private_)
}
public struct RecallFrame: Sendable {
    public var filterChain: [Filter]            // implicit AND (B-4)
    public var hydrationLevel: HydrationLevel; public var limit: Int?
    public var ordering: Ordering; public var asOf: HLC?   // HLC, not wall-clock Date (§11 clock decision)
    /// nil = write NO trace rows (default); n = trace at most the first n
    /// surfaced rows. Only the GLK RecallDirector primary locus call sets
    /// this; all other estate.recall calls leave it nil.
    public var traceLimit: Int?
    public init(filterChain: [Filter], hydrationLevel: HydrationLevel = .structured,
                limit: Int? = nil, ordering: Ordering = .byCaptureTimeDesc,
                asOf: HLC? = nil, traceLimit: Int? = nil)
}
public struct LearnFrame: Sendable {
    public var source: SourceCatalogEntry          // carries the genuine anchor learn inherits
    public var handle: String                       // the reference's locator; must be non-empty
    public var mode: LearnMode                       // → operational bit 12
    public var refreshPolicy: RefreshPolicy          // → operational bits 0–5
    public init(source: SourceCatalogEntry, handle: String,
                mode: LearnMode = .byReference, refreshPolicy: RefreshPolicy = .weekly)
}
public enum MutationKind: Sendable {
    // Confirmation axis (provenance bits 18–23):
    case confirm                                   // → userConfirmed
    // State axis (adjectiveBitmap bits 0–5 via DrawerStore.mutateState):
    case reject                                    // → rejected (automaton: from pending only)
    case contest                                   // → contested (from active, pending)
    case resolve                                   // contested → active (guard: must be contested)
    case supersede                                 // → superseded (from active, accepted)
    case revive                                    // historical Cluster-B → active (§9.3):
                                                   //   decayed/withdrawn/expired unconditional;
                                                   //   superseded only if no living successor holds
                                                   //   the lineage head (else disciplineViolation);
                                                   //   live + terminal states refuse by domain rule
    case accept                                    // → accepted (guard: trust ≥ canonical, S-1)
    // Adjective axis (adjectiveBitmap via DrawerStore.mutateAdjective):
    case correctSensitivity(AdjectiveSensitivity)  // bits 6–11
    case correctExportability(AdjectiveExportability) // bits 12–17; raw 0 = .private_, raw 32 = .public_
    case correctTrust(Trust)                       // bits 18–23
}
```
**Rust:** `pub struct CaptureFrame`, `RecallFrame`, `LearnFrame`,
`pub enum MutationKind` mirror these. Rust verbs add an explicit `now: i64`
parameter (SPEC § 8).

#### `Filter`, `StateCluster`, and the recall enums

The named recall-filter algebra (SPEC § 5, B-4, B-4.1). Every case is a named
value or a domain argument — no raw masks or thresholds.

**Recall defaults.** When no sensitivity filter is present in the chain, the
evaluator prepends `.sensitivityAtMost(.elevated)` — the Normal-tier ceiling
per the data-movement contract Decision 2 (Normal tier = `.normal` + `.elevated`;
`.restricted` = Private; `.secret` = Secret). `restricted` and `secret`
drawers are excluded from default (no-claims) recall. They are reachable only
by an explicit sensitivity constraint in the caller's chain, e.g.
`.sensitivity(.secret)` or `.sensitivityAtMost(.secret)`. An explicit
sensitivity constraint suppresses the default entirely (classifier-suppressed
pattern). § 9.2 access-claims plumbing (future aria-mcp) can LOWER this
ceiling; the default is the conservative no-claims posture. Confirmation is
not defaulted: fresh unconfirmed captures remain recallable by ordinary recall.
Callers that need only aging/retention-vouched rows must add
`.userConfirmed` explicitly.

```swift
public indirect enum Filter: Sendable {
    // state:       currentlyBelieve, usedToBelieve, knewOnceAndErased, state(State), stateInCluster(StateCluster)
    // trust:       trustworthy, requiresConfirmation, trust(Trust), trustAtMost(Trust)
    // sensitivity: sensitivity(AdjectiveSensitivity), sensitivityAtMost(AdjectiveSensitivity)
    // export:      exportable, contained
    // provenance:  userConfirmed, automatedConfirmedOnly, unconfirmed, sourceType(SourceType),
    //              channel(ProvenanceChannel), confidenceAtLeast(Confidence)
    // operational: captureChannel(CaptureChannel), contentKind(ContentKind), hasFeatureFlag(FeatureFlag)
    // structural:  inRoom(RoomID), inWing(WingID), lineageID(LineageID), createdAfter(Date),
    //              createdBefore(Date), latticeAnchor(LatticeAnchor), latticeUnder(udcPrefix: String),
    //              wikidataConcept(WikidataQID)
    // content:     contentMatches(String)
    // composition: all([Filter]), any([Filter]), not(Filter)
}
public enum StateCluster: Sendable { case knowNow, knewPast, terminal }
public enum HydrationLevel: Sendable { case structured, full, bitmapOnly }   // B-6
public enum Ordering: Sendable { case byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc }
// Note: byRelevanceDesc was removed. Relevance ordering requires VectorKit's
// scoring signal and lives at the GLK RecallDirector layer (NeuronKit/HybridRecall).
// LocusKit is a bitmap-filter engine; no in-kit relevance score exists.
```
**Rust:** `pub enum Filter` (and `StateCluster`, `HydrationLevel`, `Ordering`)
mirror these cases.

#### `RecallStream` / `RecallPage`

The paged async result sequence (SPEC § 5, B-5/B-6).

```swift
public struct RecallStream: AsyncSequence, Sendable {
    public typealias Element = RecallPage
    public static let defaultPageSize = 50
    // Named fault stages recorded while Estate.recall produced this stream.
    // Empty for a clean result (including the genuine-empty estate); non-empty
    // when an internal read FAILED (naming which stage) OR the opt-in reward
    // trace write was lost. This is how a FAILED recall is distinguished from a
    // GENUINE-EMPTY estate (SPEC § 5 B-3). Read/eval vocabulary (accompany an
    // EMPTY result): locus.liveRows.readFailed, locus.roomFingerprints.readFailed,
    // locus.roomDrawerRead.readFailed, locus.bitmapEval.failed. Reward-path
    // write stage: recall.trace_write_failed — fires AFTER reads/eval succeed,
    // so the rows ARE returned (fail-closed) and only the trace was dropped (B-10).
    public let degradedStages: [String]
    public func makeAsyncIterator() -> AsyncIterator
    public struct RecallPage: Sendable {
        public let rows: [Drawer]; public let pageIndex: Int; public let isLast: Bool
    }
    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async -> RecallPage?
    }
}
```
**Rust:** `pub struct RecallStream` + `pub struct RecallPage` exposing the
same page/`is_last` contract; the Rust iterator is a synchronous pull.
`degraded_stages()` returns the same byte-identical stage vocabulary (the four
read/eval stages plus `recall.trace_write_failed`), and
`collect_all_with_degraded(self) -> (Vec<Drawer>, Vec<String>)` drains the
stream and returns those stages (the GLK coordinator's locus lanes use it).

#### Lattice / identity value types: `LatticeAnchor`, `OwnerCredentials`, `RowID`, `RoomID`, `WingID`, `LineageID`, `WikidataQID`

```swift
public struct LatticeAnchor: Sendable, Equatable, Codable {
    public let udcCode: String; public let udcFacets, wikidataQID, wikidataQidsSecondary: String?
    public init(udcCode: String, udcFacets: String? = nil, wikidataQID: String? = nil,
                wikidataQidsSecondary: String? = nil)
    public static func udc(_ code: String) -> LatticeAnchor
}
public struct OwnerCredentials: Sendable, Equatable { public let ownerIdentifier: String; public init(ownerIdentifier: String) }
public typealias RowID = String          // every noun's TEXT PRIMARY KEY
public typealias RoomID = String          // free-form
public typealias WingID = String          // wings emerge via SELECT DISTINCT
public typealias LineageID = UUID
public typealias WikidataQID = String
```
**Rust:** `pub struct LatticeAnchor`, `OwnerCredentials`; the id aliases are
plain `String`/`Uuid`.

#### Bitmap value enums (the named axes the accessors decode)

All `Int64`-backed; decode with safe fallback to the neutral case (SPEC C-1).
Bit layouts per architecture spec § 5.5 / § 5.6 and `Q1_the provenance-bitmap contract`.

```swift
// adjective bitmap (Adjectives.swift) — scale-gapped raws per cookbook §2.3 (F13/v0.6)
public enum State: Int { case active=0, pending=1, contested=2, accepted=3, superseded=16, decayed=17, withdrawn=18, expired=19, rejected=32, tombstoned=33 }
public enum Trust: Int, Comparable { case verbatim=0, observed, imported, canonical, derived, proposed, ambient }   // ambient=6 NEW in v0.6
public enum AdjectiveSensitivity: Int { case normal=0, elevated=16, restricted=32, secret=48 }   // scale-gapped
// the data-movement contract Decision 2 privacy-tier predicates on AdjectiveSensitivity (no new bits):
var isBulkExportable: Bool           // true for .normal, .elevated  (Normal tier)
var requiresOwnerKeyForBulk: Bool    // true for .restricted          (Private tier)
var isExcludedFromBulk: Bool         // true for .secret              (Secret tier)
// Rust: pub fn is_bulk_exportable(&self) -> bool / requires_owner_key_for_bulk / is_excluded_from_bulk
public enum AdjectiveExportability: Int { case private_=0, public_=32 }
// operational bitmap (DrawerOperational.swift) — cookbook §2.4
public enum CaptureChannel: Int { case typed=0, voiced, ocr, importedFile, sensor, actuator }   // actuator=5 NEW in v0.6
public enum ContentKind: Int { case prose=0, code, transcript, list, structuredJSON, imageCaption, fingerprintOnly, dataset }   // fingerprintOnly=6 NEW in v0.6; dataset=7 NEW in MX-TAB-3
public struct DrawerFeatureFlags: OptionSet { /* hasAttachments(12), hasVoice(13), hasImage(14), hasLinks(15), isPinned(16) */ }
public typealias FeatureFlag = DrawerFeatureFlags
// provenance bitmap (Provenance.swift) — cookbook §2.5 (F13/v0.6)
public enum SourceType: Int { case user=0, observed, imported, canonical, derived, federationAggregate, tierAggregate, pairedEstate, ambient, actuator }
public enum Confirmation: Int { case unconfirmed=0, userConfirmed, automatedConfirmed, peerConfirmed, actuatorConfirmed }   // F13 rename from ConfirmationState
public enum Confidence: Int, Comparable { case null=0, low=16, medium=32, high=48, verified=56 }   // scale-gapped (F13: was unknown=0..certain=6)
public enum Channel: Int { case uiTyped=0, uiVoiced, mcpAgent, fileImport, apiGrounding, federationInbound, dreamProposal, dreamAssociation, dreamMiningResult, deviceSensor=15, actuatorOutcome=16 }
public enum Sensitivity: Int { case normal=0, elevated=16, restricted=32, secret=48 }   // scale-gapped, mirrors AdjectiveSensitivity
public enum EnrichmentStatus: Int { case none=0, qidPending, qidCompleted, closureCached, qidProposed }   // §2.5 (QID resolution lifecycle); qidProposed(4) = terminal in-workflow after an enrichment proposal is filed
public typealias ProvenanceChannel = Channel
public typealias Vector = [Float]      // vector recall composes via VectorKit
```
**Rust:** identical enums and raw values (`snake_case` cases); `DrawerFeatureFlags`
is a Rust bitflags-style struct with the same bit positions.

#### Audit history: `AuditEvent` (SubstrateTypes), `BitmapState`

Returned by `Estate.auditTrail` / `bitmapState` (SPEC § 5, B-9; append-only I-8).

`AuditRow`, `AuditActor`, and `BitmapColumn` have been replaced by `AuditEvent`
(declared in `SubstrateTypes/AuditEvent.swift`). `auditTrail(rowID:)` returns
`[AuditEvent]`; the wall-clock range form `auditTrail(since:until:)` has been
dropped (HLC is the ordering axis per §11 clock decision).

```swift
// SubstrateTypes.AuditEvent — the CRDT audit row (G-Set audit log, cookbook §5.1)
public struct AuditEvent: Sendable {
    public let eventID: UUID
    public let estateUuid: UUID; public let rowId: UUID; public let hlc: HLC
    public let verb: String
    public let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
    public let afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)
    public let beforeLatticeAnchor: LatticeAnchor?; public let afterLatticeAnchor: LatticeAnchor
    public let actor: String   // "capture" | "mcp_agent" | "dreaming_daemon" | …
    public let reason: String?
}
// BitmapState snapshot returned by Estate.bitmapState(rowID:asOf:)
public struct BitmapState: Sendable {
    public let rowID: RowID; public let asOf: HLC  // HLC, not wall-clock Date (§11)
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
}
```
**Rust:** `pub struct AuditEvent` in `substrate_types` mirrors the Swift struct
(`snake_case` fields; `before_bitmaps`/`after_bitmaps` are `Option<(i64,i64,i64)>`
and `(i64,i64,i64)` tuples). `pub struct BitmapState` in `locus-kit` mirrors
the Swift struct with `as_of: substrate_types::hlc::HLC`.

#### `RecallTraceItem`

The two-source reward hook (SPEC § 5, B-10). `used` is bit 0 — computed, never
stored (I-2).

```swift
public struct RecallTraceItem: Equatable, Hashable, Codable, Sendable {
    public static let flagUsed: Int64 = 1 << 0
    public let id, target: String; public let recalledAt: Date
    public let score: Double?; public let operationalBitmap: Int64
    public var used: Bool { operationalBitmap & RecallTraceItem.flagUsed != 0 }
    public init(id: String = UUID().uuidString, target: String, recalledAt: Date,
                score: Double? = nil, operationalBitmap: Int64 = 0)
}
```
**Rust:** `pub struct RecallTraceItem` with the same `flag_used` constant and
`used()` accessor.

#### Manifest: `ManifestKey`, `ManifestValues`

The estate key-value manifest contract (architecture spec § 5.9).

```swift
public enum ManifestKey: String, CaseIterable { /* 18 required + 7 optional keys; static .required, .optional */ }
public struct ManifestValues: Sendable {
    // 18 required fields (manifestVersion, schemaVersion, estateUUID, estateName, ownerIdentifier,
    // latticeCitation, frameworkProfile, frameworkProfileDefinition, zoomWindowLow/High,
    // accessPosture, provenanceDefaults, activeStorageMode, tablesPresent, createdAt, lastModified,
    // bitmapLayoutVersion, provenanceBitmapVersion) + 7 optional (federationGroupID, miningPatternsHash,
    // tinyModelID, tinyModelTrainingCorpusSize, operationalBitmapLayouts, ed25519PublicKey, ed25519PrivateKeyWrapped)
    public init(/* memberwise; two Ed25519 fields default nil */)
}
```
**Rust:** `pub enum ManifestKey`, `pub struct ManifestValues` mirror these.

#### `LocusKitSchema`, `DrawerStore`

The PersistenceKit schema registration and the CRUD store. `DrawerStore` is
consumed directly by GeniusLocusKit; it is an `actor` in Swift and a `trait`
in Rust (SPEC § 8).

```swift
public enum LocusKitSchema { public static let kitID = "LocusKit"; public static let version = 12
                             public static var schema: SchemaDeclaration { get } }
public actor DrawerStore {
    public init(storage: any Storage) async throws
    // addDrawer is internal (not public): the only sanctioned add path for verb-layer
    // callers is Estate.addDrawerCovered(_:now:), which bundles store.addDrawer +
    // containerFP.orIn atomically — the structural §11.5 Option B add-coverage guarantee.
    // Direct use of addDrawer is reserved for rebuild/backfill paths inside LocusKit itself.
    internal func addDrawer(_ d: Drawer, now: Date = Date()) async throws
    public func getDrawer(id: String) async throws -> Drawer?
    public func drawersIn(wing: String) async throws -> [Drawer]
    public func drawersIn(wing: String, room: String) async throws -> [Drawer]
    public func allDrawers() async throws -> [Drawer]
    public func mutateAdjective(...) async throws; public func mutateOperational(...) async throws
    public func mutateProvenance(...) async throws; public func mutateState(...) async throws
    public func addTunnel(_ t: Tunnel) async throws; public func getTunnel(id: String) async throws -> Tunnel?
    public func addKGFact(_ f: KGFact) async throws; public func kgFacts(forDrawerID: String) async throws -> [KGFact]
    public func withdrawKGFact(id: String) async throws  // transitions adjectiveBitmap to State.withdrawn raw 18 (RowState Cluster B), exiting the active-recall filter (g_state_cluster < RowState.activeClusterUpperBoundRaw, 16)
    public func addDiaryEntry(_ e: DiaryEntry) async throws; public func readDiary(agentName: String, lastN: Int = 10) async throws -> [DiaryEntry]
    public func insertRecallTrace(_ item: RecallTraceItem) async throws
    public func getRecallTrace(id: String) async throws -> RecallTraceItem?
    public func recallTraceSince(_ since: Date) async throws -> [RecallTraceItem]
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem]
    public func markRecallTraceUsed(id: String, now: Date) async throws
    /// Bulk-marks every trace row for `target` within [since, now] as used (bit 0 of operationalBitmap).
    /// Returns the count of rows updated. Positive-only; internal callers must not call this (B-10a).
    public func markRecallTracesUsed(target: String, since: Date, now: Date) async throws -> Int
    /// Returns the total number of recall_trace rows in the estate. Used by moot_estate_status.
    public func countRecallTraces() async throws -> Int
    /// Subject trio (progressive recall). Contract cap for `subject` length in characters.
    public static let subjectLengthContract = 120  // = Rust SUBJECT_LENGTH_CONTRACT
    /// Writes subject + pipelineVersion + at in ONE atomic UPDATE. Rejects empty
    /// or > subjectLengthContract subjects. Returns rows updated (0 = unknown id).
    /// No bitmap write, no container-fingerprint rollup — nothing filters on subject.
    public func setSubjectRepresentation(drawerId: String, subject: String,
                                         pipelineVersion: String, at: Date) async throws -> Int
    /// Subject debt: live, non-empty-content drawers whose subject is NULL or
    /// whose subject_pipeline_version differs from `pipelineVersion`.
    public func countMissingSubject(pipelineVersion: String) async throws -> Int
    public func allTunnels() async throws -> [Tunnel]
    // Outline helpers (the node-integrity contract §11) — typed parent edges with fractional ordering
    public func outlineChildren(of parentDrawerId: String) async throws -> [Tunnel]
    public func outlineAncestors(of drawerId: String) async throws -> [String]
    public func reparentDrawer(_ childId: String, newParentId: String?, orderKey: Double,
                               wing: String, room: String, addedBy: String, now: Date) async throws
    public func listWings() async throws -> [WingSummary]; public func listRooms(in wing: String?) async throws -> [RoomSummary]
    public func readManifest() async throws -> ManifestValues; public func setMeta(key: String, value: String) async throws
    // Audit reads — returns SubstrateTypes.AuditEvent rows (not AuditRow; that type is retired)
    public func auditEventsForRow(_ rowID: UUID) async throws -> [AuditEvent]
    public func auditEventCountForRow(_ rowID: UUID) async throws -> Int
    // … full CRUD + audit surface, see DrawerStore.swift
}
```
**Rust:** `pub trait DrawerStore: Send + Sync` with `InMemoryDrawerStore`
(plus `SqliteDrawerStore` and `PostgresDrawerStore` delegation wrappers);
methods are synchronous and take `now: i64`. The Swift `DrawerStore` is a
concrete actor over any injected `Storage` (SQLite in production); the Rust
version realises the same store contract through the trait (SPEC § 8).
The Rust port adds `withdraw_kg_fact(id: &str, now: i64)` to the
trait with a `DatabaseUnavailable` default; `DrawerStoreCore` carries the
live implementation (sets bits 0–5 of `adjective_bitmap` to `State::Withdrawn`
raw 18, preserving upper bits — mirrors `withdrawKGFact` in the Swift actor).

**Newtype-forwarding contract (durable backends).** Every `DrawerStore`
trait method that carries a `DatabaseUnavailable` fail-loud default MUST be
explicitly forwarded to the inner `DrawerStoreCore` by both durable newtypes
(`SqliteDrawerStore`, `PostgresDrawerStore`). The newtypes hand-forward each
method individually — there is no `Deref` — so an omitted forward silently
inherits the fail-loud default and HARD-ERRORS on a real estate. A regression
guard exercises the dreaming-reader B-1 path (`Estate::all_tunnels`) over a
durable SQLite estate. The invariant: no durable-backend read method may
inherit a trait default.

**§11.5 Option B add-coverage guarantee (Swift).** `DrawerStore.addDrawer` is
`internal`, not `public`. The only sanctioned verb-layer add path is
`Estate.addDrawerCovered(_:now:)` (private to `Estate`), which bundles
`store.addDrawer` + `containerFP.orIn` atomically. This structural chokepoint
ensures that no caller outside LocusKit can add a drawer without simultaneously
updating the per-container OR aggregate. External code (GeniusLocusKit, ARIA
surfaces) must reach the add path through `Estate.capture`, never through
`DrawerStore.addDrawer` directly. The `@testable import LocusKit` test gate
gives LocusKit's own test targets access to `internal` in the usual Swift
testing convention; this does not open the method to product code.

**§11.5 Option B add-coverage guarantee (Rust).** `DrawerStoreCore::add_drawer`
folds the FP update inside itself — every call to `add_drawer`, regardless of
which `DrawerStore` trait impl invokes it, atomically calls
`ContainerFingerprintStore::or_in` on success. The trait's
`or_in_container_fingerprint` method remains for rebuild/backfill paths only.

**Compile-required reads (no default at all).** Two `DrawerStore` reads —
`all_drawers` and `room_level_fingerprints` — carry NO trait default. Per the
SDK compile-enforcement ruling, a backend that forgets a corpus-scan /
container-fingerprint read must fail to COMPILE rather than fail loud at
runtime. For these two the omitted-forward failure mode is a build error, not a
runtime `DatabaseUnavailable`; the rest of the read surface retains the
fail-loud default described above. This matches the Swift surface, where both
are bare (non-defaulted) members of the concrete `DrawerStore` actor.

### Tier 2 — broader surface (table of contents)

The following public types are part of the kit's surface and consumed by its
own pipeline and tests, not (yet) by another package.
They are public for `@testable` intra-kit use and conformance tests. Recorded
as a navigable index — name, role, source file. Full signatures live in the
cited file.

- **Recall-pruning fingerprints:** `ContainerFingerprint`,
  `ContainerFingerprintStore` (per-container OR aggregate, recall pruning,
  SPEC B-7), `EstateFingerprintFamilies` (per-drawer fingerprint via SubstrateLib
  `HyperplaneFamily`) — `ContainerFingerprintStore.swift`, `DrawerFingerprint.swift`.
  The lattice block's `qidClosureHash` facet is now live (mission #7b): when a
  drawer's `wikidataQID` has P31/P279 ancestors in LatticeLib's pinned Q-ID
  closure snapshot, the block hashes `FNV.hash16` of the sorted-numeric,
  `"|"`-joined transitive ancestor list (`LatticeLib.QIDClosure.ancestors(of:)`);
  no QID or no ancestors → the deterministic null 0. This adds a
  LocusKit → LatticeLib dependency (downstream → upstream, no cycle; authority
  the package-dependency rule).
- **Bundle materialisation:** `BundleMaterializer`, `NodeBundleStore`,
  `NodeBundleStore.BundleKind` (count-vector roll-ups over rooms/wings) —
  `BundleMaterializer.swift`, `NodeBundleStore.swift`.
- **Validators:** `DrawerStateValidator` + `TransitionVerb` (the
  `(state, verb) → state` automaton), `ForbiddenCombinationValidator`
  (forbidden bitmap combinations) — `DrawerStateValidator.swift`,
  `ForbiddenCombinationValidator.swift`.
- **Bitmap helpers:** free functions `andMask`, `thresholdCompare` + `ThresholdOp`,
  `xor`, `isIdentical`, `hammingDistance`, `shiftExtract`, `simdBallot` —
  `BitmapOps.swift`. (The recall evaluator `BitmapEvaluator` is `internal` in
  the Swift version; the Rust version exposes it as `pub struct BitmapEvaluator`.)
- **KG-fact operational axes:** `KGExtractorClass`, `KGAssertionKind`,
  `KGSpecificity`, `KGConfidenceBand` — `KGFactOperational.swift`.
- **Diary operational axes:** `DiaryEventClass`, `DiarySeverity`,
  `DiaryActorClass`, `DiaryBatchMembership` — `DiaryOperational.swift`.
- **Tunnel operational axes (declared in Tier 1 nouns, indexed here):**
  `TunnelDirection`, `TunnelLifecycle`, `TunnelOriginClass`, `TunnelStrength`
  — `TunnelOperational.swift`.
- **Association operational axes (declared in Tier 1 nouns, indexed here):**
  `AssociationSignalSources` (OptionSet), `AssociationDecayClass`,
  `AssociationArity` — `AssociationOperational.swift`.
- **Proposal operational axes (declared in Tier 1 nouns, indexed here):**
  `ProposalKind`, `ProposalTargetObjectType`, `ProposalConfirmationSource`,
  `ProposalGeneratedByClass`, `ProposalConfidenceBucket` —
  `ProposalOperational.swift`.
- **LearnedReference operational axes (declared in Tier 1 nouns, indexed
  here):** `RefreshPolicy`, `DriftSeverity`, `LearnMode`,
  `LearnedReferenceSource` — `LearnedReferenceOperational.swift`.
- **Dataset handle types (MX-TAB-4):** `DatasetColumnSummary` (column schema
  summary: `name: String`, `dataType: String`), `DatasetHandleContent` (JSON payload
  for `contentKind == .dataset` drawers: `datasetId: UUID`, `columns`, `rowCount`,
  `sourceDescription`, plus reserved `tableSignature`/`columnSignatures` for
  MX-TAB-5), and the module-level constant `datasetHandleEmbeddingModelID = "dataset-handle"`
  (sentinel that satisfies the non-empty embeddingModelID invariant for handle
  drawers, which carry no vector embedding) — `DatasetHandle.swift`.
  `DatasetHandleContent.encode() throws -> String` / `decode(from:) throws`
  round-trip the JSON payload for `Drawer.content` storage.
  Rust: `pub struct DatasetColumnSummary`, `pub struct DatasetHandleContent` (serde
  `rename_all = "camelCase"`), `pub const DATASET_HANDLE_EMBEDDING_MODEL_ID` —
  `dataset_handle.rs`.
- **Vocabulary gate (estate write-gate arming):** `LocusKitVocabulary` — a `public enum`
  namespace (`LocusKitVocabulary.swift`) that declares two members:
  `public static let unionSlots: Set<FieldSlot>` — the operational and provenance field
  slots for drawer estates, with their legal value sets per cookbook §2.4 / §2.5
  (12 slots covering `capture_channel`, `content_kind` including the MX-TAB-3 `.dataset`
  raw 7, `feature_flags`, `state_extension`, `lineage_clustering`, `source_type`, `channel`,
  `prov_capture_channel`, `confirmation`, `confidence`, `sensitivity_at_capture`,
  `enrichment_status`). The adjective-bitmap slots (state / sensitivity / exportability / trust)
  are substrate-owned and supplied by the `AuditGate` itself — `LocusKitVocabulary` declares
  only the consumer operational and provenance slots.
  `public static func frozen() -> Result<Vocabulary, VocabularyError>` — freezes `unionSlots`
  via `VocabularyValidator.freeze`; called at estate open to arm the `AuditGate` before any
  write is admitted. Static and known-valid; always succeeds.
  Rust: module `vocabulary` in `vocabulary.rs` — `pub fn union_slots() -> Vec<FieldSlot>` and
  `pub fn frozen() -> Result<Vocabulary, VocabularyError>` (free functions; Swift-enum-namespace /
  Rust free-fn module sanctioned shape). Both legs carry identical slot declarations and legal
  value sets; the gate uses `union_slots()` / `frozen()` identically at estate open and per-write
  validation time.
- **Default wings (estate provisioning):** `DefaultWings.swift` — module-level public constants
  and a struct used at estate provision time:
  `public let defaultWingName: String = "Agentic Memory"` — the default wing for `capture`
  when no explicit wing is supplied; all new captures without an explicit wing land here.
  `public let hintRoom: String = "AI_Charter_Hint"` — room name for per-wing hint drawers.
  `public let hintUDCCode: String = "001"` — UDC class code stamped on hint drawers.
  `public let hintAddedBy: String = "estate-provision"` — actor string for hint drawer
  provenance (honest provenance only — no code branches on this value).
  `public struct WingDefinition: Sendable, Equatable { name: String; hint: String }` — a wing
  name paired with its hint text.
  `public let defaultWings: [WingDefinition]` — the seven wings seeded at estate provision
  (`"Agentic Memory"`, `"User Canon"`, `"Source Corpus"`, `"Personal"`, `"Professional"`,
  `"Projects"`, `"Temp"`). These are suggestions, not a fixed schema; the AI may create any
  additional wing; nothing enforces this set as complete.
  Rust: `default_wings.rs` — `pub const DEFAULT_WING_NAME: &str`, `pub struct WingDefinition
  { name: &'static str, hint: &'static str }`, `pub const DEFAULT_WINGS: &[WingDefinition]`.
  Hint text is verbatim-identical in both ports.
- **Taxonomy summaries:** `WingSummary`, `RoomSummary` (computed
  `GROUP BY` projections; no wings/rooms table) — `Summaries.swift`.
- **Rust-only helper shapes:** `BitmapAuditPair`, `RoomBundle`,
  `RoomLevelEntry`, `InMemoryDrawerStore` — present in the Rust version where
  the Swift version keeps the equivalent internal (SPEC § 8).

## § 3 — Public functions

The principal Tier-1 entry points are the `Estate` verb and history methods
(§ 2) — `capture`, `recall`, `withdraw`, `auditTrail`, `bitmapState` — plus
the lifecycle `open` / `create` / `close`. Standalone functions:

```swift
LatticeAnchor.udc(_ code: String) -> LatticeAnchor
// BitmapOps (Tier 2 helpers):
andMask(_ bitmap: Int64, mask: Int64, expected: Int64) -> Bool
thresholdCompare(_ value: Int64, op: ThresholdOp, threshold: Int64) -> Bool
xor(_ a: Int64, _ b: Int64) -> Int64
hammingDistance(_ a: Int64, _ b: Int64) -> Int
shiftExtract(_ bitmap: Int64, shift: Int, mask: Int64) -> Int64
```

## § 4 — Errors

The behavioral meaning of each case is in SPEC § 6.

```swift
public enum LocusKitError: Error, Sendable, Equatable {
    case databaseUnavailable(String)
    case drawerNotFound(id: String)
    case tunnelNotFound(id: String)
    case diaryEntryNotFound(id: String)
    case recallTraceItemNotFound(id: String)
    case sqliteError(String)
    case schemaTooNew(found: Int, expected: Int)
    case invalidContent(String)
    case disciplineViolation(from: Int, to: Int, reason: String)
    case corruptStoredValue(table: String, column: String, storedText: String)
    case notSupported(String)
    // A dataset handle exists for `datasetId` but its state is in cluster B
    // (withdrawn/superseded/decayed/expired). Thrown by
    // Estate.resolveActiveDatasetHandle(datasetId:) (MX-TAB-4).
    case withdrawnDatasetHandle(datasetId: UUID)
}
public enum EstateError: Error, Sendable, Equatable {
    case substrateUnavailable(String)
    case manifestMismatch(key: String, found: String, expected: String)
    case emptyOwnerIdentifier
}
```
**Rust:** `pub enum LocusKitError` and `pub enum EstateError` mirror these
cases (`error.rs`, `estate.rs`). `corruptStoredValue` ↔ `CorruptStoredValue
{ table, column, stored_text }`; `notSupported` ↔ `NotSupported`;
`withdrawnDatasetHandle` ↔ `WithdrawnDatasetHandle { dataset_id: Uuid }`.
Meaning: SPEC § 6.

**Manifest `estate_uuid` classification at open.** Opening a `DrawerStore`
(Swift) / `DrawerStoreCore` (Rust) resolves the store's stamping identity
and HLC maker node id from the manifest `estate_uuid` value. Three outcomes,
mutually exclusive — an absent value and a corrupt value are NOT conflated:

| Manifest `estate_uuid` | Outcome |
|---|---|
| Absent (row never written — fresh estate) | Legitimate: a fresh identity is minted and the maker node id is `0`. No error. |
| Present and parses as a UUID | The persisted identity is used; maker node id = `FNV-1a-32(rawText) & 0x7FFF_FFFF`. |
| Present but non-parseable (data corruption) | Fail loud: `corruptStoredValue(table: "manifest", column: "estate_uuid", storedText:)` / Rust `CorruptStoredValue`. Never collapses to node `0` or a random UUID. |

The maker node id is hashed from the raw stored text (not the re-serialised
UUID) so both ports derive byte-identical ids. Both ports enforce this
identically (Swift `DrawerStore.classifyEstateUuid`, Rust
`DrawerStoreCore::classify_estate_uuid`).

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/LocusKit
```

(Targets: `LocusKitTests`, `LocusKitTelemetryTests`.)

**Rust:**

```
cargo test -p locus-kit
```

(Suites: inline `DrawerStore` contract tests — SPEC § 8;
`locuskit_telemetry_tests.rs` — telemetry gate and conformance.)

## § 6 — Examples

```swift
import LocusKit
import PersistenceKit

let storage = try await SQLiteStorage(/* … */)            // caller builds the backend (I-10)
let estate = try await Estate.create(storage: storage,
                                     owner: OwnerCredentials(ownerIdentifier: "icloud:owner"))

// Capture — validated, then written; bitmaps assembled from named slots.
let drawer = try await estate.capture(CaptureFrame(
    content: "Organic chemistry covers carbon compounds.",
    channel: .typed,
    room: "chemistry",
    latticeAnchor: .udc("547"),                            // udcCode required (I-5)
    addedBy: "owner",
    embeddingModelID: "text-embedding-3-small"))           // required (I-4)

// Recall — implicit-AND filter chain; defaults to currently-believed,
// trustworthy, and within the Normal tier (≤ .elevated) when those axes
// are unspecified (B-4, B-4.1). Confirmation is explicit: add
// `.userConfirmed` when the caller wants only user-vouched rows.
// Restricted and secret drawers require an explicit sensitivity
// constraint to surface.
let stream = await estate.recall(RecallFrame(
    filterChain: [.inRoom("chemistry"), .latticeUnder(udcPrefix: "54")],
    hydrationLevel: .structured,
    ordering: .byCaptureTimeDesc))
for await page in stream {                                 // first page synchronous; final page isLast (B-5)
    for row in page.rows { print(row.content) }
}

// History — reconstruct a row's bitmaps as they stood in the past (B-9).
let past = try await estate.bitmapState(rowID: drawer.id, at: someEarlierDate)
```

## § 7 — Swift/Rust Concordance

This section tracks schema-level parity between the Swift and Rust ports.
"Present" means the table or symbol is declared in both ports and produces
bit-identical DDL. Gaps are tracked until resolved.

| Element | Swift | Rust | Status | Notes |
|---------|-------|------|--------|-------|
| `drawers` table | `LocusKitSchema.drawersTable` (LocusKitSchema.swift) | `drawers_table()` (schema.rs) | Present | Generated columns and indices match; distilled quad + subject trio columns match (pinned by `drawers_column_set` and the GLK composite layout-signature fixture) |
| `tunnels` table | `LocusKitSchema.tunnelsTable` (LocusKitSchema.swift:206) | `tunnels_table()` (schema.rs:186) | Present | `kind_id` default 1 matches |
| `diary` table | `LocusKitSchema.diaryTable` (LocusKitSchema.swift:236) | `diary_table()` (schema.rs:222) | Present | |
| `manifest` table | `LocusKitSchema.manifestTable` (LocusKitSchema.swift:257) | `manifest_table()` (schema.rs:250) | Present | |
| `kg_facts` table | `LocusKitSchema.kgFactsTable` (LocusKitSchema.swift:321) | `kg_facts_table()` (schema.rs:271) | Present | `g_state_cluster` generated column matches |
| `proposals` table | `LocusKitSchema.proposalsTable` (LocusKitSchema.swift:367) | `proposals_table()` (schema.rs:321) | Present | `candidateState` bitmap + lattice anchor columns match |
| `associations` table | `LocusKitSchema.associationsTable` (LocusKitSchema.swift:416) | `associations_table()` (schema.rs:377) | Present | |
| `learned_references` table | `LocusKitSchema.learnedReferencesTable` (LocusKitSchema.swift:461) | `learned_references_table()` (schema.rs:428) | Present | |
| `node_bundles` table | `LocusKitSchema.nodeBundlesTable` (LocusKitSchema.swift:308) | `node_bundles_table()` (schema.rs:470) | Present | Three-part composite PK matches |
| `container_fingerprints` table | `LocusKitSchema.containerFingerprintsTable` (LocusKitSchema.swift:283) | `container_fingerprints_table()` (schema.rs:506) | Present | |
| `recall_trace` table | `LocusKitSchema.recallTraceTable` (LocusKitSchema.swift:499) | `recall_trace_table()` (schema.rs:542) | Present | `score` REAL nullable matches |
| `keys` table (ENC-01) | `LocusKitSchema.keysTable` | `keys_table()` | Present | key_id TEXT PK, algorithm TEXT, wrapped BLOB, created_at TIMESTAMP (ISO8601), ext JSON nullable (the forward-compatible ext-slot contract forward-compat slot, schema v2); no bitmap columns; no generated columns |

**Date storage invariant:** all `timestamp` / `created_at` / `filedAt` columns use
`ColumnType::Timestamp` in Rust (emitted as TEXT ISO8601 by PersistenceKit backends),
matching Swift's `.timestamp(...)` — never REAL (Unix timestamp).

**Schema version:** both ports declare `version = 12` (`LocusKitSchema.version`
↔ `SCHEMA_VERSION`, pinned by `schema_version_is_twelve`). The base declaration
carries every column fresh; a three-entry migration ladder covers in-development
estates upgrading across a binary bump: v9 → v10 (associations natural-key
dedup + UNIQUE index, FINDING-3), v10 → v11 (`operationalAND` on
`container_fingerprints`), v11 → v12 (subject trio on `drawers`: `subject`,
`subject_pipeline_version`, `subject_at`, all nullable, no backfill — NULL
`subject` is the backfill-eligibility predicate). Earlier versions (v2 `keys.ext`
forward-compat slot through v9 `content_fingerprint`) pre-date the ladder and
live only in the base declaration; the per-version history is the
`LocusKitSchema.version` doc comment in both ports.

### Public type surface — concept-level concordance

One row per public concept. Each Swift symbol and Rust symbol is a real
top-level declaration found in source; `file:line` cites the declaration
site. **Visibility** is the actual visibility of both sides. **Shape rule**
states how the two ports are allowed to differ. **Test/vector binding** names
the conformance/parity test that proves Swift==Rust for the concept (the
LP0 vector pair `LocusKitVectorsTests.swift` ↔ `rust/tests/lp0_vectors.rs`
exercises the entity lifecycles end to end; the three bitmap-conformance
pairs prove the adjective/operational/provenance enum encodings byte-for-byte).

Recurring sanctioned shapes:
- **Swift-enum-namespace / Rust free-fn module** — Swift uses a caseless
  `public enum` as a namespace for `static func`s; Rust has no namespace-type
  idiom and uses a `pub mod` of `pub fn`s. The Swift type exists; the Rust
  counterpart is the module's functions (free functions are out of the audit's
  type scope by design). Both ports implement the concept.
- **Swift nested / Rust flat** — a type Swift nests inside its owning
  store/stream is declared flat at module top level in Rust.
- **Swift tuple / Rust named struct** — a method that returns an anonymous
  labelled tuple in Swift returns a named `pub struct` in Rust.

#### Entities (nouns)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Drawer | `Drawer` (Drawer.swift:31) | `Drawer` (drawer.rs:65) | public / pub | identical | `LocusKitVectorsTests.swift` ↔ `lp0_vectors.rs::lp0_drawer_lifecycle` | Confirmed |
| Tunnel | `Tunnel` (Tunnel.swift:23) | `Tunnel` (tunnel.rs:39) | public / pub | identical | `LocusKitVectorsTests.swift` ↔ `lp0_vectors.rs::lp0_tunnel_traverse` | Confirmed |
| KG fact | `KGFact` (KGFact.swift:54) | `KGFact` (kg_fact.rs:61) | public / pub | identical | `LocusKitVectorsTests.swift` ↔ `lp0_vectors.rs::lp0_kgfact_temporal` | Confirmed |
| Diary entry | `DiaryEntry` (DiaryEntry.swift:23) | `DiaryEntry` (diary_entry.rs:35) | public / pub | identical | `DiaryEntryTests.swift` (structural; same columns as `diary_table`) | Confirmed |
| Proposal | `Proposal` (Proposal.swift:74) | `Proposal` (proposal.rs:72) | public / pub | identical | `ProposalTests.swift` ↔ `proposal_tests.rs` | Confirmed |
| Association | `Association` (Association.swift:67) | `Association` (association.rs:51) | public / pub | identical | `AssociationTests.swift` ↔ `association_tests.rs` | Confirmed |
| Learned reference | `LearnedReference` (LearnedReference.swift:86) | `LearnedReference` (learned_reference.rs:132) | public / pub | identical | `LearnedReferenceTests.swift` ↔ `learned_reference_tests.rs` | Confirmed |
| Container fingerprint | `ContainerFingerprint` (ContainerFingerprintStore.swift:40) | `ContainerFingerprint` (container_fingerprint_store.rs:62) | public / pub | identical | `ContainerFingerprintStoreTests.swift` | Confirmed |
| Tree node | `Node` (Node.swift:25, `public struct`) | `Node` (node.rs:30, `pub struct`) | public / pub | identical; thirteen fields: `id`, `parentId`/`parent_id`, `displayName`/`display_name`, `lookupName`/`lookup_name`, `depth`, `lifecycle` (lifecycle-state bitmap, no-resurrection guard the node-integrity contract), `createdHlc`/`created_hlc`, `tombstonedHlc`/`tombstoned_hlc`, `tombstonedAt`/`tombstoned_at`, `merkleRoot`/`merkle_root`, `createdAt`/`created_at`, `updatedAt`/`updated_at`, `ext` (JSON forward-compat). `Date?` / `Option<i64>` for date fields — ISO8601-TEXT seam (sanctioned). NT-L1. | `NodeStoreTests.swift` ↔ `node_store_tests.rs` | Confirmed |

#### Adjective enums (proved by `adjective_bitmap_conformance.rs`)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Lifecycle state | `State` (Adjectives.swift:100) | `State` (adjectives.rs:53) | public / pub | identical | `AdjectiveBitmapConformanceTests.swift` ↔ `adjective_bitmap_conformance.rs::state_raw_values_match_verification_table` | Confirmed |
| Trust | `Trust` (Adjectives.swift:144) | `Trust` (adjectives.rs:132) | public / pub | identical | `AdjectiveBitmapConformanceTests.swift` ↔ `adjective_bitmap_conformance.rs` | Confirmed |
| Adjective sensitivity | `AdjectiveSensitivity` (Adjectives.swift:174) | `AdjectiveSensitivity` (adjectives.rs:184) | public / pub | identical | `AdjectiveBitmapConformanceTests.swift` ↔ `adjective_bitmap_conformance.rs` | Confirmed |
| Adjective exportability | `AdjectiveExportability` (Adjectives.swift:192) | `AdjectiveExportability` (adjectives.rs:236) | public / pub | identical | `AdjectiveBitmapConformanceTests.swift` ↔ `adjective_bitmap_conformance.rs` | Confirmed |
| State cluster | `StateCluster` (Filter.swift:46) | `StateCluster` (filter.rs:42) | public / pub | identical | `StateTransitionTests.swift` | Confirmed |

#### Provenance enums (proved by `provenance_bitmap_conformance.rs`)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Source type | `SourceType` (Provenance.swift:68) | `SourceType` (provenance.rs:47) | public / pub | identical | `ProvenanceBitmapConformanceTests.swift` ↔ `provenance_bitmap_conformance.rs` | Confirmed |
| Channel | `Channel` (Provenance.swift:103) | `Channel` (provenance.rs:109) | public / pub | identical | `ProvenanceBitmapConformanceTests.swift` ↔ `provenance_bitmap_conformance.rs` | Confirmed |
| Confirmation | `Confirmation` (Provenance.swift:138) | `Confirmation` (provenance.rs:163) | public / pub | identical | `ProvenanceBitmapConformanceTests.swift` ↔ `provenance_bitmap_conformance.rs` | Confirmed |
| Confidence | `Confidence` (Provenance.swift:156) | `Confidence` (provenance.rs:205) | public / pub | identical | `ProvenanceBitmapConformanceTests.swift` ↔ `provenance_bitmap_conformance.rs` | Confirmed |
| Sensitivity | `Sensitivity` (Provenance.swift:178) | `Sensitivity` (provenance.rs:245) | public / pub | identical | `ProvenanceBitmapConformanceTests.swift` ↔ `provenance_bitmap_conformance.rs` | Confirmed |
| Enrichment status | `EnrichmentStatus` (Provenance.swift:189) | `EnrichmentStatus` (provenance.rs:278) | public / pub | identical | `ProvenanceBitmapConformanceTests.swift` ↔ `provenance_bitmap_conformance.rs` | Confirmed |

#### Operational enums / flag sets (proved by `operational_bitmap_conformance.rs`)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Capture channel | `CaptureChannel` (DrawerOperational.swift:62) | `CaptureChannel` (drawer_operational.rs:57) | public / pub | identical | `OperationalBitmapConformanceTests.swift` ↔ `operational_bitmap_conformance.rs` | Confirmed |
| Content kind | `ContentKind` (DrawerOperational.swift:79) | `ContentKind` (drawer_operational.rs:99) | public / pub | identical | `OperationalBitmapConformanceTests.swift` ↔ `operational_bitmap_conformance.rs` | Confirmed |
| Drawer feature flags | `DrawerFeatureFlags` (DrawerOperational.swift:101) | `DrawerFeatureFlags` (drawer_operational.rs:146) | public / pub | Swift `OptionSet` struct / Rust ZST struct of `const` bit masks (idiomatic; same bit layout) | `OperationalBitmapConformanceTests.swift` ↔ `operational_bitmap_conformance.rs` (FIELD_MASK + per-bit table) | Confirmed |
| Tunnel kind | `TunnelKind` (TunnelOperational.swift:39) | `TunnelKind` (tunnel_operational.rs:54) | public / pub | identical | `TunnelKindTests.swift` ↔ `capture_tunnel_tests.rs` | Confirmed |
| Tunnel direction | `TunnelDirection` (TunnelOperational.swift:54) | `TunnelDirection` (tunnel_operational.rs:99) | public / pub | identical | `TunnelBitmapTests.swift` | Confirmed |
| Tunnel lifecycle | `TunnelLifecycle` (TunnelOperational.swift:64) | `TunnelLifecycle` (tunnel_operational.rs:131) | public / pub | identical | `TunnelBitmapTests.swift` | Confirmed |
| Tunnel origin class | `TunnelOriginClass` (TunnelOperational.swift:74) | `TunnelOriginClass` (tunnel_operational.rs:163) | public / pub | identical | `TunnelBitmapTests.swift` | Confirmed |
| Tunnel strength | `TunnelStrength` (TunnelOperational.swift:88) | `TunnelStrength` (tunnel_operational.rs:201) | public / pub | identical | `TunnelBitmapTests.swift` | Confirmed |
| Diary event class | `DiaryEventClass` (DiaryOperational.swift:34) | `DiaryEventClass` (diary_operational.rs:44) | public / pub | identical | `DiaryOperationalTests.swift` ↔ `diary_operational.rs` tests | Confirmed |
| Diary severity | `DiarySeverity` (DiaryOperational.swift:55) | `DiarySeverity` (diary_operational.rs:94) | public / pub | identical | `DiaryOperationalTests.swift` | Confirmed |
| Diary actor class | `DiaryActorClass` (DiaryOperational.swift:68) | `DiaryActorClass` (diary_operational.rs:135) | public / pub | identical | `DiaryOperationalTests.swift` | Confirmed |
| Diary batch membership | `DiaryBatchMembership` (DiaryOperational.swift:80) | `DiaryBatchMembership` (diary_operational.rs:169) | public / pub | identical | `DiaryOperationalTests.swift` | Confirmed |
| KG extractor class | `KGExtractorClass` (KGFactOperational.swift:49) | `KGExtractorClass` (kg_fact_operational.rs:53) | public / pub | identical | `KGFactTests.swift` ↔ `kg_fact_operational.rs` tests | Confirmed |
| KG assertion kind | `KGAssertionKind` (KGFactOperational.swift:67) | `KGAssertionKind` (kg_fact_operational.rs:98) | public / pub | identical | `KGFactTests.swift` | Confirmed |
| KG specificity | `KGSpecificity` (KGFactOperational.swift:84) | `KGSpecificity` (kg_fact_operational.rs:132) | public / pub | identical | `KGFactTests.swift` | Confirmed |
| KG confidence band | `KGConfidenceBand` (KGFactOperational.swift:107) | `KGConfidenceBand` (kg_fact_operational.rs:181) | public / pub | identical | `KGFactTests.swift` | Confirmed |
| Proposal kind | `ProposalKind` (ProposalOperational.swift:61) | `ProposalKind` (proposal_operational.rs:52) | public / pub | identical | `ProposalTests.swift` ↔ `proposal_tests.rs` | Confirmed |
| Proposal target object type | `ProposalTargetObjectType` (ProposalOperational.swift:82) | `ProposalTargetObjectType` (proposal_operational.rs:97) | public / pub | identical | `ProposalTests.swift` | Confirmed |
| Proposal confirmation source | `ProposalConfirmationSource` (ProposalOperational.swift:101) | `ProposalConfirmationSource` (proposal_operational.rs:134) | public / pub | identical | `ProposalTests.swift` | Confirmed |
| Proposal generated-by class | `ProposalGeneratedByClass` (ProposalOperational.swift:117) | `ProposalGeneratedByClass` (proposal_operational.rs:165) | public / pub | identical | `ProposalTests.swift` | Confirmed |
| Proposal confidence bucket | `ProposalConfidenceBucket` (ProposalOperational.swift:137) | `ProposalConfidenceBucket` (proposal_operational.rs:201) | public / pub | identical | `ProposalTests.swift` | Confirmed |
| Association signal sources | `AssociationSignalSources` (AssociationOperational.swift:48) | `AssociationSignalSources` (association_operational.rs:48) | public / pub | Swift `OptionSet` struct / Rust newtype `struct(i64)` (same bit layout) | `AssociationTests.swift` ↔ `association_tests.rs` | Confirmed |
| Association decay class | `AssociationDecayClass` (AssociationOperational.swift:91) | `AssociationDecayClass` (association_operational.rs:95) | public / pub | identical | `AssociationTests.swift` | Confirmed |
| Association arity | `AssociationArity` (AssociationOperational.swift:107) | `AssociationArity` (association_operational.rs:139) | public / pub | identical | `AssociationTests.swift` | Confirmed |
| Refresh policy | `RefreshPolicy` (LearnedReferenceOperational.swift:48) | `RefreshPolicy` (learned_reference.rs:51) | public / pub | identical | `LearnedReferenceTests.swift` ↔ `learned_reference_tests.rs` | Confirmed |
| Drift severity | `DriftSeverity` (LearnedReferenceOperational.swift:69) | `DriftSeverity` (learned_reference.rs:77) | public / pub | identical | `LearnedReferenceTests.swift` | Confirmed |
| Learn mode | `LearnMode` (LearnedReferenceOperational.swift:86) | `LearnMode` (learned_reference.rs:99) | public / pub | identical | `LearnedReferenceTests.swift` | Confirmed |
| Learned reference source | `LearnedReferenceSource` (LearnedReferenceOperational.swift:97) | `LearnedReferenceSource` (learned_reference.rs:107) | public / pub | identical | `LearnedReferenceTests.swift` | Confirmed |

#### Frames (verb argument bundles)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Capture frame | `CaptureFrame` (Frames.swift:25) | `CaptureFrame` (frames.rs:25) | public / pub | identical | `FrameTests.swift` ↔ `lp0_vectors.rs` (capture path) | Confirmed |
| Tunnel capture frame | `TunnelCaptureFrame` (Frames.swift:138) | `TunnelCaptureFrame` (frames.rs:147) | public / pub | identical | `CaptureTunnelTests.swift` ↔ `capture_tunnel_tests.rs` | Confirmed | carries `originClass` (bits 6–8) and `lifecycle` (bits 3–5, default `.active`); `.proposed` is the agent-derived review state reviewed via `Estate.respondToTunnel` / `Estate::respond_to_tunnel` (accept → `.active`, reject → `.withdrawn`; only `.proposed` is reviewable) — `ProposedTunnelLifecycleTests.swift` ↔ `capture_tunnel_tests.rs` proposed-lifecycle block |
| Recall frame | `RecallFrame` (Frames.swift:197) | `RecallFrame` (filter.rs:194) | public / pub | identical (different source file per port) | `RecallPaginationTests.swift` ↔ `lp0_vectors.rs::lp0_recall_stream` | Confirmed |
| Mutation kind | `MutationKind` (Frames.swift:236) | `MutationKind` (frames.rs:213) | public / pub | identical | `MutateMutationKindTests.swift` | Confirmed |
| Learn frame | `LearnFrame` (Frames.swift:267) | `LearnFrame` (frames.rs:244) | public / pub | identical | `FrameTests.swift` | Confirmed |
| Propose frame | `ProposeFrame` (Frames.swift:352) | `ProposeFrame` (frames.rs:326) | public / pub | identical | `FrameTests.swift`, `ProposeProvenanceTests.swift` ↔ `estate_verbs.rs::propose_*_provenance*` | Confirmed | carries `target`, `kind`, `justification`, plus three provenance axes `confirmation` (default `.human`), `generatedBy` (default `.dreamingDaemon`), `confidence` (default `.null`) wired into the proposal operational bitmap at bits 12–17 / 18–23 / 24–29; defaults reproduce the pre-wire bitmap byte-for-byte |
| Associate frame | `AssociateFrame` (Frames.swift:306) | `AssociateFrame` (frames.rs:290) | public / pub | identical | `FrameTests.swift` | Confirmed |
| Hydration level | `HydrationLevel` (Frames.swift:325) | `HydrationLevel` (filter.rs:56) | public / pub | identical (different source file per port) | `FrameTests.swift` | Confirmed |
| Ordering | `Ordering` (Frames.swift:337) | `Ordering` (filter.rs:69) | public / pub | identical (different source file per port): 3 cases — byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc. byRelevanceDesc removed (no in-kit scoring signal; relevance ordering lives at GLK RecallDirector). | `RecallPaginationTests.swift` | Confirmed |
| Filter | `Filter` (Filter.swift:67, `public indirect enum`) | `Filter` (filter.rs:94) | public / pub | Swift `indirect enum` (recursive) / Rust `enum` with boxed recursion (same case set) | `RecallPaginationTests.swift` ↔ `lp0_vectors.rs` (filtered recall) | Confirmed |
| Threshold op | `ThresholdOp` (BitmapOps.swift:69) | `ThresholdOp` (bitmap_ops.rs:58) | public / pub | identical | `BitmapOpsTests.swift` | Confirmed |

#### Identifier typealiases

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Row id | `RowID` (EstateTypes.swift:15) | `RowID` (estate_types.rs:17) | public / pub | identical (`typealias`/`type` = String) | N/A (structural) | Confirmed |
| Lineage id | `LineageID` (Filter.swift:8, =UUID) | `LineageID` (filter.rs:31, =Uuid) | public / pub | identical alias; Swift `UUID` / Rust `Uuid` (platform UUID type) | `LineageTests.swift` | Confirmed |
| Wikidata QID | `WikidataQID` (Filter.swift:19) | `WikidataQID` (filter.rs:34) | public / pub | identical (alias = String) | N/A (structural) | Confirmed |
| Room id | `RoomID` (Filter.swift:12) | none — Rust passes `&str`/`String` directly at call sites; no port-level alias | public / (none) | Swift convenience alias (=String); Rust has no `type RoomID` alias | N/A (structural) | Confirmed |
| Wing id | `WingID` (Filter.swift:16) | none — Rust passes `&str`/`String` directly at call sites; no port-level alias | public / (none) | Swift convenience alias (=String); Rust has no `type WingID` alias | N/A (structural) | Confirmed |
| Provenance channel alias | `ProvenanceChannel` (Filter.swift:24, =`Channel`) | none — Rust references `Channel` directly | public / (none) | Swift convenience alias of `Channel`; the underlying `Channel` concept is concordant (see Provenance enums) | `ProvenanceBitmapConformanceTests.swift` (via `Channel`) | Confirmed |
| Feature flag alias | `FeatureFlag` (Filter.swift:29, =`DrawerFeatureFlags`) | none — Rust references `DrawerFeatureFlags` directly | public / (none) | Swift convenience alias of `DrawerFeatureFlags`; the underlying flag set is concordant (see Operational) | `OperationalBitmapConformanceTests.swift` (via `DrawerFeatureFlags`) | Confirmed |

#### Estate / store types

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Estate Interface | `Estate` (Estate.swift:29, `public actor`) | `Estate` (estate.rs:48, `pub struct`) | public / pub | Swift `actor` (async, compiler-serialized) / Rust `struct` (sync; no async runtime — sanctioned, cf. NeuronKit policy-store seam) | `EstateTests.swift` / `EstateVerbTests.swift` ↔ `lp0_vectors.rs` (`Estate::create`) | Confirmed |
| Owner credentials | `OwnerCredentials` (EstateTypes.swift:28) | `OwnerCredentials` (estate_types.rs:31) | public / pub | identical | `EstateTests.swift` | Confirmed |
| Lattice anchor | `LatticeAnchor` (EstateTypes.swift:55) | `LatticeAnchor` (estate_types.rs:62) | public / pub | identical | `LatticeAnchorTests.swift` | Confirmed |
| Estate error | `EstateError` (EstateTypes.swift:96) | `EstateError` (estate_types.rs:111) | public / pub | identical case set | `EstateTests.swift` | Confirmed |
| Estate fingerprint families | `EstateFingerprintFamilies` (DrawerFingerprint.swift:68) | `EstateFingerprintFamilies` (drawer_fingerprint.rs:73) | public / pub | identical | `DrawerFingerprintTests.swift` | Confirmed |
| Kit error | `LocusKitError` (LocusKitError.swift:11) | `LocusKitError` (error.rs:21) | public / pub | identical case set | `LocusKitVectorsTests.swift` (error paths) | Confirmed |
| Bitmap state snapshot | `BitmapState` (AuditTypes.swift:27) | `BitmapState` (audit_types.rs:13) | public / pub | identical | `BitmapAuditTests.swift` ↔ `two_clock_ingest_tests.rs` | Confirmed |
| Drawer store | `DrawerStore` (DrawerStore.swift:54, `public actor` over PersistenceKit `Storage`) | `DrawerStore` trait (drawer_store.rs:75) + `DrawerStoreCore` (drawer_store_inmemory.rs:138) + `InMemoryDrawerStore` (…:2177) + `SqliteDrawerStore` (drawer_store_sqlite.rs:75, two constructors: `from_path` (bare/no-cache) and `from_path_with_config(EstateConfiguration, now, hlc)` (cache-accepting)) + `PostgresDrawerStore` (drawer_store_postgres.rs:87) | public / pub | Architectural seam: Swift is ONE actor that abstracts the backend through PersistenceKit's `Storage` protocol (SQLite/Postgres/InMemory chosen at the PersistenceKit layer — cache config threaded through `EstateConfiguration.cacheConfig`); Rust splits the backend into a `DrawerStore` trait with per-backend structs sharing `DrawerStoreCore`. `SqliteDrawerStore::from_path_with_config` enables cache parity with the InMemory path: both backends wrap `row_store()` in `CachingRowStore` when `EstateConfiguration.cache_config.enabled` is true. Same backends reached at different layers — sanctioned, no async runtime in Rust. | `DrawerStoreTests.swift` ↔ `lp0_vectors.rs` (drives `InMemoryDrawerStore` via `dyn DrawerStore`) + `rust/tests/drawer_store_sqlite.rs`; `estate_admin_tests.rs` (`sqlite_live_estate_is_caching`, `sqlite_cache_disabled_reverts_to_bare_store`) | Confirmed |
| Container fingerprint store | `ContainerFingerprintStore` (ContainerFingerprintStore.swift:88, `actor`) | `ContainerFingerprintStore` (container_fingerprint_store.rs:130, `struct`) | public / pub | Swift `actor` / Rust `struct` (sync; no async runtime — sanctioned) | `ContainerFingerprintStoreTests.swift` | Confirmed |
| Room-level fingerprint entry | `roomLevelEntries()` returns tuple `(wing, room, fingerprint)` (ContainerFingerprintStore.swift:124) | `RoomLevelEntry` (container_fingerprint_store.rs:122) | public / pub | Swift labelled tuple / Rust named `pub struct` (same fields) | `ContainerFingerprintStoreTests.swift` | Confirmed |
| Node bundle store | `NodeBundleStore` (NodeBundleStore.swift:28, `actor`) | `NodeBundleStore` (node_bundle_store.rs:109, `struct`) | public / pub | Swift `actor` / Rust `struct` (sync; no async runtime — sanctioned) | `BundleMaterializerTests.swift` (exercises the store) | Confirmed |
| Bundle kind | `BundleKind` (NodeBundleStore.swift:33, nested) | `BundleKind` (node_bundle_store.rs:68, flat) | public / pub | Swift nested in `NodeBundleStore` / Rust flat top-level (same case set) | `BundleMaterializerTests.swift` | Confirmed |
| Room bundle | `rooms()` returns tuple `(room, bundle)` (NodeBundleStore.swift:120) | `RoomBundle` (node_bundle_store.rs:103) | public / pub | Swift labelled tuple / Rust named `pub struct` (same fields) | `BundleMaterializerTests.swift` | Confirmed |
| Bundle materializer | `BundleMaterializer` (BundleMaterializer.swift:35) | `BundleMaterializer` (bundle_materializer.rs:65, `<'a, K: SubstrateKernel>`) | public / pub | identical concept; Rust is generic over the substrate kernel (lifetime + `K` param) | `BundleMaterializerTests.swift` | Confirmed |
| Node store | `NodeStore` (NodeStore.swift:37, `public actor`) | `NodeStore` (node_store.rs:50, `pub struct`) | public / pub | Swift `actor` (async) / Rust `struct` (sync; no async runtime — sanctioned); verbs: `createNode`/`create_node`, `getNode`/`get_node`, `childNodes`/`child_nodes`, `rootNode`/`root_node`, `tombstoneNode`/`tombstone_node`, `updateMerkleRoot`/`update_merkle_root`, `createRoot`/`create_root`. NT-L1. | `NodeStoreTests.swift` ↔ `node_store_tests.rs` | Confirmed |

#### Recall / trace types

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Recall stream | `RecallStream` (RecallStream.swift:23, `AsyncSequence`) | `RecallStream` (recall_stream.rs:57) | public / pub | Swift `AsyncSequence` / Rust sync paginating iterator (no async runtime — sanctioned) | `RecallPaginationTests.swift` ↔ `lp0_vectors.rs::lp0_recall_stream` | Confirmed |
| Recall page | `RecallPage` (RecallStream.swift:58, nested) | `RecallPage` (recall_stream.rs:34, flat) | public / pub | Swift nested in `RecallStream` / Rust flat top-level (same fields, `isLast`/`is_last`) | `RecallPaginationTests.swift` ↔ `lp0_vectors.rs::lp0_recall_stream` | Confirmed |
| Recall trace item | `RecallTraceItem` (RecallTraceItem.swift:22) | `RecallTraceItem` (recall_trace_item.rs:31) | public / pub | identical | `RecallTraceItemTests.swift` ↔ `recall_trace` table | Confirmed |

#### Summaries

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Wing summary | `WingSummary` (Summaries.swift:11) | `WingSummary` (summaries.rs:18) | public / pub | identical | `SummariesTests.swift` | Confirmed |
| Room summary | `RoomSummary` (Summaries.swift:34) | `RoomSummary` (summaries.rs:46) | public / pub | identical | `SummariesTests.swift` | Confirmed |

#### Manifest

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Manifest key | `ManifestKey` (Manifest.swift:6) | `ManifestKey` (manifest.rs:21) | public / pub | identical case set | `ManifestTests.swift` | Confirmed |
| Manifest values | `ManifestValues` (Manifest.swift:78) | `ManifestValues` (manifest.rs:175) | public / pub | identical | `ManifestTests.swift` | Confirmed |

#### Namespace / validator types (Swift-enum-namespace / Rust free-fn module)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---------|--------------|-------------|------------|------------|---------------------|--------|
| Schema declaration | `LocusKitSchema` (LocusKitSchema.swift:74, caseless `enum`) | `mod schema` free fns (`schema()`/`drawers_table()`/… schema.rs:57+) | public / pub | Swift-enum-namespace / Rust free-fn module (same DDL — see § 7 table rows above) | per-table rows in § 7 above; `PackageBuildTests.swift` | Confirmed |
| Drawer state validator | `DrawerStateValidator` (DrawerStateValidator.swift:41, caseless `enum`) | `mod drawer_state_validator` free fns (drawer_state_validator.rs:97) | public / pub | Swift-enum-namespace / Rust free-fn module (thin adapter to substrate row-state, per M1) | `StateTransitionTests.swift` ↔ substrate row-state conformance | Confirmed |
| Forbidden-combination validator | `ForbiddenCombinationValidator` (ForbiddenCombinationValidator.swift:52, caseless `enum`) | `mod forbidden_combination_validator` `pub fn validate` (forbidden_combination_validator.rs:58) | public / pub | Swift-enum-namespace / Rust free-fn module (cookbook §9.5 forbidden combo) | `ForbiddenCombinationTests.swift` ↔ `forbidden_combination_validator.rs` inline tests | Confirmed |
| Kit vocabulary | `LocusKitVocabulary` (LocusKitVocabulary.swift:28, caseless `enum`) | `mod vocabulary` free fns (`frozen()`/`union_slots()`, vocabulary.rs:90/22) | public / pub | Swift-enum-namespace / Rust free-fn module (frozen write-gate vocabulary) | `LocusKitVocabularyTests.swift` | Confirmed |
| Bitmap evaluator | `BitmapEvaluator` (BitmapEvaluator.swift:59) — `internal struct` | `BitmapEvaluator` (bitmap_evaluator.rs:132) — `pub struct` (ZST) | internal / pub | Implementation-detail evaluator. Swift keeps it `internal` (entry point `BitmapEvaluator.evaluate` is module-private; cf. `EstateAudit.swift` note); Rust exposes it `pub` as a module-organisation choice. Not a contract concept either port commits to externally — same algorithm, different chosen visibility. | `EvaluatorTests.swift` ↔ `operational_bitmap_conformance.rs` (evaluation tier) | Confirmed |

**Visibility-asymmetry note (`BitmapEvaluator`):** the only visibility
asymmetry in the surface. Swift declares the evaluator `internal` and the
Rust port declares it `pub`. The behaviour is conformance-bound identically
(`EvaluatorTests.swift` ↔ `operational_bitmap_conformance.rs`), and neither
port advertises it as a consumer-facing contract type, so this is recorded
as Confirmed — but the asymmetry is flagged here so a
future pass can decide whether Rust should narrow it to `pub(crate)`.

### Additional public types

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Recall-filtered result | `FrameFilteredDrawers` (`EstateTypes.swift:27`) | `FrameFilteredDrawers` (`estate_verbs.rs:84`) | Swift public struct / Rust pub struct | identical 2-field struct: `admissible: [Drawer]`/`Vec<Drawer>`, `loadedIDs: Set<String>`/`loaded_ids: HashSet<String>` — the return type of `Estate.recall(frame:)` carrying the admissible drawers and the full set of IDs loaded from storage | `EstateTests.swift` (recall paths) ↔ `lp0_vectors.rs::lp0_recall_*` | Confirmed |
| Source catalog entry | `SourceCatalogEntry` (`SourceCatalogEntry.swift:50`) | `SourceCatalogEntry` (`source_catalog_entry.rs:75`) | both public/pub | identical 6-field struct: `id`, `kind: SourceKind`/`SourceKind`, `handle`, `latticeAnchor`/`lattice_anchor: LatticeAnchor` (the genuine anchor `learn` inherits), `firstSeen`/`first_seen` (Date/i64 ISO8601-TEXT seam — sanctioned), `addedBy`/`added_by: String` | `EstateTests.swift` (source-catalog paths) ↔ `source_catalog_entry.rs #[cfg(test)]` | Confirmed |
| Source kind | `SourceKind` (`SourceCatalogEntry.swift:103`) | `SourceKind` (`source_catalog_entry.rs:42`) | both public/pub | identical 6-case enum stored as Int raw value: `.user`/`User`=0, `.federation`/`Federation`=1, `.householdPairing`/`HouseholdPairing`=2, `.fleetPairing`/`FleetPairing`=3, `.tierInheritance`/`TierInheritance`=4, `.pairedEstate`/`PairedEstate`=5; Swift lowerCamel / Rust UpperCamel — idiom | `EstateTests.swift` ↔ `source_catalog_entry.rs #[cfg(test)]` | Confirmed |
| Recall internal-read fault seam | `Estate.RecallInternalRead` (`Estate.swift:66`, nested public enum; `_testForceInternalReadError` stored property) | `RecallInternalRead` (`estate.rs:100`, `#[cfg(any(test, feature = "test-seams"))]` pub enum; `_test_force_internal_read_error: AtomicU8` field) | Swift public nested in `Estate` actor / Rust pub (test-seams only) | 5-case test fault-injection seam (`liveRows`/`LiveRows`, `roomFingerprints`/`RoomFingerprints`, `roomDrawerRead`/`RoomDrawerRead`, `bitmapEval`/`BitmapEval`, `traceWrite`/`TraceWrite`); Swift lowerCamel / Rust UpperCamel — idiom. Present in both ports; Rust gates behind `#[cfg(any(test, feature="test-seams"))]` (not in the production binary). The seam declaration lives on `Estate` in both ports (Swift stored property, Rust `AtomicU8` field) — not on `EstateVerbs`, which is an extension/impl that cannot own stored properties. | `EstateRecallFaultTests.swift` ↔ `estate_recall_fault_tests.rs` (recall degraded-stage suite) | Confirmed (test-seam; production binary excludes the Rust enum) |
| Wing provisioning definition | `WingDefinition` (DefaultWings.swift:48, `public struct`) | `WingDefinition` (default_wings.rs:48, `pub struct`) | public / pub | identical concept; two fields: `name` (String / `&'static str`), `hint` (String / `&'static str`) — the wing's role-description text, seeded as a NORMAL drawer in the wing's `AI_Charter_Hint` room (no special room/provenance/embedding; see the wing-organization contract §2 amendment 2026-06-23). Swift uses owned `String`; Rust uses static string literals — same semantic values at runtime. Seeded at estate provision as the seven the wing-organization contract default wings. NT-L1. | `EstateTests.swift` (provision path) ↔ `node_store_tests.rs` (estate provision exercises WingDefinition) | Confirmed |
| Snapshot attestation (LocusKit-homed) | — | `SnapshotAttestation` (merkle_rollup.rs:269, `pub struct`) | — / pub | **Layering note:** Rust port places `SnapshotAttestation` in `LocusKit/merkle_rollup.rs`. The Swift equivalent is `PersistenceKit.SnapshotAttestation` (SnapshotRegistry.swift:47). Relocate to PersistenceKit Rust in a future parity mission (NT-P1/L4). Until relocated, this row documents the Rust declaration site so the concordance audit does not flag it as an undocumented gap. | `MerkleRollupTests.swift` ↔ `merkle_rollup_tests.rs` | Documented (layering mismatch — see PersistenceKit concordance for Swift counterpart) |
| Snapshot record (LocusKit-homed) | — | `SnapshotRecord` (merkle_rollup.rs:260, `pub struct`) | — / pub | **Layering note:** same as `SnapshotAttestation` above. Rust port places this in `LocusKit/merkle_rollup.rs`; Swift equivalent is `PersistenceKit.SnapshotRecord` (SnapshotRegistry.swift:32). NT-P1/L4. | `MerkleRollupTests.swift` ↔ `merkle_rollup_tests.rs` | Documented (layering mismatch — see PersistenceKit concordance for Swift counterpart) |

---

## § Telemetry

`DrawerStore` (via `DrawerStoreCore`) emits
`locuskit.*` metrics via IntellectusLib when the global monitoring gate is
enabled. Off by default.

### Dependencies added

- `Package.swift`: `IntellectusLib` in-repo dependency added to the
  `LocusKit` target and `LocusKitTests` test target. Authority:
  `the package-dependency rule`.
- `Cargo.toml`: `intellectus-lib = { path = "…/IntellectusLib/rust" }`
  added under `[dependencies]`.

### Emit surface

| Swift call site | Metric emitted | Tags |
|---|---|---|
| `addDrawer(_:now:)` | `locuskit.drawer.capture_latency_ms` | `estate=<UUID>` |
| `addDrawer(_:now:)` | `locuskit.drawer.capture_count` | `estate=<UUID>` |
| `drawersIn(wing:)` | `locuskit.drawer.query_latency_ms` | `estate=<UUID>`, `query="wing"` |
| `drawersIn(wing:)` | `locuskit.drawer.query_result_count` | `estate=<UUID>`, `query="wing"` |
| `drawersIn(wing:room:)` | `locuskit.drawer.query_latency_ms` | `estate=<UUID>`, `query="wing_room"` |
| `drawersIn(wing:room:)` | `locuskit.drawer.query_result_count` | `estate=<UUID>`, `query="wing_room"` |
| `allDrawers()` | `locuskit.drawer.query_latency_ms` | `estate=<UUID>`, `query="all"` |
| `allDrawers()` | `locuskit.drawer.query_result_count` | `estate=<UUID>`, `query="all"` |
| `addKGFact(_:)` | `locuskit.kgfact.add_count` | `estate=<UUID>` |
| `kgFacts(forDrawerID:)` | `locuskit.kgfact.query_result_count` | `estate=<UUID>`, `query="drawer"` |
| `allKGFacts()` | `locuskit.kgfact.query_result_count` | `estate=<UUID>`, `query="all"` |
| `addTunnel(_:)` | `locuskit.tunnel.add_count` | `estate=<UUID>` |

Rust emit sites mirror Swift exactly (`add_drawer`, `drawers_in_wing`,
`all_drawers`, `add_kg_fact`, `kg_facts_for_drawer`, `all_kg_facts`,
`add_tunnel`). All in `DrawerStoreCore` (shared impl, auto-applies to
`InMemoryDrawerStore`, `SqliteDrawerStore`, `PostgresDrawerStore`).

### Test suite: `LocusKitTelemetryTests` (Swift)

File: `Tests/LocusKitTests/LocusKitTelemetryTests.swift`

Six serialised suites, all bodies serialised under `IntellectusTestMutex`
(async actor mutex in `IntellectusTestLock.swift`). Enabled-path tests
filter emitted metrics by `estate` tag to tolerate concurrent suites.

- `§1 LocusKitTelemetry — disabled gate`: 3 tests — no metrics emitted
  when monitoring is off (process-wide lock ensures zero-count assertion
  is not corrupted by concurrent enabled-path tests).
- `§2 LocusKitTelemetry — drawer capture emissions`: 4 tests — `addDrawer`
  emits latency + count, value=1.0, non-negative latency, two-call=two-count.
- `§3 LocusKitTelemetry — drawer query emissions`: 3 tests — query metrics
  with correct query tags.
- `§4 LocusKitTelemetry — KGFact emissions`: 3 tests — add_count and
  query_result_count with correct query tags.
- `§5 LocusKitTelemetry — tunnel emissions`: 2 tests — `addTunnel` emits
  add_count, two-call=two-count.
- `§6 LocusKitTelemetry — conformance`: 2 tests — results byte-identical
  with monitoring on and off.

### Test suite: `locuskit_telemetry_tests.rs` (Rust)

File: `rust/tests/locuskit_telemetry_tests.rs`

17 tests, all holding `GLOBAL_LOCK` (`OnceLock<Mutex<()>>`). Mirrors Swift
suites §1–§6 above. Enabled-path tests filter by `estate` tag.

---

## Temporal Read APIs (§ 15)

Two new read-only methods on `DrawerStore`. Purely additive — no schema
changes, no new dependencies.

### Swift: `DrawerStore` (actor, `Sources/LocusKit/DrawerStore.swift`)

| Method | Parameters | Returns | Notes |
|---|---|---|---|
| `fingerprintsCaptured(in:)` | `window: ClosedRange<Date>` | `[Fingerprint256]` | Ascending `id` order. OR-predicate handles NULL `eventTime`. |
| `fingerprintBitSeries(bit:bucketSeconds:bucketCount:endingAt:)` | `bit: Int`, `bucketSeconds: Int`, `bucketCount: Int`, `endingAt: Date` | `[Bool]` | Half-open buckets, last bucket inclusive. Throws on invalid `bit` or `bucketSeconds`. |

### Rust: `DrawerStore` trait (`rust/src/drawer_store.rs`)

| Method | Parameters | Returns | Notes |
|---|---|---|---|
| `fingerprints_captured_in` | `start_epoch: i64`, `end_epoch: i64` | `Result<Vec<Fingerprint256>, LocusKitError>` | Ascending id order. Default returns empty; backends override. |
| `fingerprint_bit_series` | `bit: usize`, `bucket_seconds: i64`, `bucket_count: usize`, `ending_at: i64` | `Result<Vec<bool>, LocusKitError>` | Half-open buckets, last inclusive. Returns `Err(InvalidContent)` on invalid bit or bucket_seconds. |

**Backend coverage:** `DrawerStoreCore` (InMemory path) implements both
methods. `SqliteDrawerStore` and `PostgresDrawerStore` delegate to their
inner `DrawerStoreCore`. The `Arc<dyn DrawerStore>` blanket impl delegates
to the inner trait object.

### Test suites

- Swift: `Tests/LocusKitTests/TemporalReadsTests.swift` — 9 tests
  (`fingerprintsCaptured`: full window, narrow, single-point, empty;
  `fingerprintBitSeries`: zero buckets, invalid bit, invalid bucket seconds,
  empty window, bucket-edge semantics).
- Rust: `rust/tests/temporal_reads_tests.rs` — 9 tests mirroring the
  Swift suite (same fixture constants, same boundary checks).

---

## Trace-reward write verbs (§ 16)

Two write methods on `DrawerStore` that close the reward loop between ARIA
dereference verbs and the dreaming daemon's Bradley-Terry sweep.

### Swift: `DrawerStore` (actor, `Sources/LocusKit/DrawerStore.swift`)

| Method | Parameters | Returns | Notes |
|---|---|---|---|
| `markRecallTracesUsed(target:since:now:)` | `target: String`, `since: Date`, `now: Date` | `Int` (rows updated) | Sets bit 0 of `operationalBitmap` on matching rows. B-10a: ARIA boundary only. |
| `countRecallTraces()` | — | `Int` | Row count of `recall_trace` table. Used by `moot_estate_status`. |

### Rust: `DrawerStore` trait (`rust/src/drawer_store.rs`)

| Method | Parameters | Returns | Notes |
|---|---|---|---|
| `mark_recall_traces_used` | `target: &str`, `since: i64`, `now: i64` | `Result<usize, LocusKitError>` | Seconds-since-epoch for time bounds. Default: DatabaseUnavailable. |
| `count_recall_traces` | — | `Result<usize, LocusKitError>` | Default: DatabaseUnavailable. |

**Backend coverage:** `DrawerStoreCore` carries the live implementation;
`SqliteDrawerStore` and `PostgresDrawerStore` delegate to their inner
`DrawerStoreCore`. `InMemoryDrawerStore` inherits via `DrawerStoreCore`.

### Test suites

- Swift: `Tests/GeniusLocusKitTests/TraceRewardWiringTests.swift` — 7 tests
  (bulk mark sets used bits; reward sweep sees 1.0; B-10a conformance — internal
  recall writes zero trace rows on SQLite backend; estate-status trace count).
- Rust: covered via aria-mcp integration tests (`dispatch_tests.rs`).

---

*End of LocusKit Interface.*

## Changelog

### 1.18.0 -- 2026-08-03

- **`KGFact` gains `addedBy`, `foreignSourceKey`, and `foreignRecordID`
  (MXE-KH).** All three default to `""`, so existing call sites are
  unaffected. They give the filing host identity and a palace-imported
  fact's foreign origin their own homes, leaving `sourceDrawerID` to hold a
  local drawer id or nothing. The Rust port adds the peer struct
  `KGFactOrigin` because it has no default arguments.

### 1.17.0 -- 2026-08-02

- PR-10: tier-aware debt surface — `countSubjectDebt(includingPipelines:)`
  and `subjectDebtBatch(limit:includingPipelines:)` across the store
  stack, Rust twins `count_subject_debt_including` /
  `subject_debt_batch_including`.

### 1.16.0 -- 2026-08-02

- PR-09: new DrawerStore/Estate surface — `countSubjectDebt()` (NULL-only
  presence debt; the subject-backfill drain lane's pending) and
  `subjectDebtBatch(limit:)` (deterministic sweep enumerator), with Rust
  twins `count_subject_debt` / `subject_debt_batch` (trait defaults +
  core + all forwarders). New `SubjectRegister` validator
  (`subject_register.rs` twin) — the shared producer gate with paired
  conformance vectors. New constant `subjectPipelineMiniLLMV1` ↔
  `SUBJECT_PIPELINE_MINILLM_V1`; provenance-tier table documented at the
  constants.

### 1.15.0 -- 2026-08-02

- Subject trio (progressive recall PR-01): documented the three new nullable
  `drawers` columns (`subject`, `subject_pipeline_version`, `subject_at`),
  the new `Drawer` stored fields and init parameters, and the new
  `DrawerStore` surface — `subjectLengthContract` (120 chars),
  `setSubjectRepresentation(drawerId:subject:pipelineVersion:at:)` (single
  atomic UPDATE), `countMissingSubject(pipelineVersion:)` — with `Estate`
  passthroughs and Rust twins (`SUBJECT_LENGTH_CONTRACT`,
  `set_subject_representation`, `count_missing_subject`).
- Brought the `Drawer` field listing current: added the previously
  undocumented distilled representation quad (`distilled`,
  `distilledPipelineVersion`, `distilledTokenCount`, `distilledAt`).
- Corrected the stale schema-version paragraph: both ports declare
  `version = 12` with a three-entry migration ladder (v9→v10, v10→v11,
  v11→v12), superseding the `version = 2` / empty-ladder claim.

### 1.14.0 -- 2026-07-20

- Documented the 1.1 GLK shared-content seam: LocusKit owns canonical Drawer
  content and identity while a GLK-owned adapter supplies it to CorpusKit.
- Clarified that `Drawer.chunkIndex` is provenance metadata, not CorpusKit RAG
  chunk storage or result identity.

### 1.13.0 -- 2026-07-16
Closed CRITICAL documentation gaps identified by the post-pass verifier:

- **Estate dataset-handle verbs added to Tier 1** (`DatasetHandle.swift` /
  `estate_verbs.rs`): `captureDatasetHandle`, `findDatasetHandles`,
  `resolveActiveDatasetHandle`, `patchDatasetHandleSignatures`, `drawerById`,
  `appendAuditEvent` — all are `public extension Estate` methods consumed by
  GeniusLocusKit and absent from both Tier 1 and the previous Tier 2 entry for
  dataset handles. Swift signatures, behavioral notes (SPEC B-13/B-14/B-15
  cross-references), and Rust counterparts (`estate_verbs.rs` / `dataset_handle.rs`)
  are now documented in the Estate code block and the Rust parity paragraph.
- **`LocusKitVocabulary` added to Tier 2** (`LocusKitVocabulary.swift` /
  `vocabulary.rs`): `public enum` namespace that declares `unionSlots: Set<FieldSlot>`
  and `frozen() -> Result<Vocabulary, VocabularyError>`, called at estate open to
  arm the `AuditGate`. Rust: module-level free functions `union_slots()` / `frozen()`
  in `vocabulary.rs`.
- **`DefaultWings` surface added to Tier 2** (`DefaultWings.swift` /
  `default_wings.rs`): `defaultWingName`, `hintRoom`, `hintUDCCode`, `hintAddedBy`,
  `WingDefinition`, `defaultWings` — the estate-provisioning constants and struct.
  Rust: `DEFAULT_WING_NAME`, `WingDefinition`, `DEFAULT_WINGS` in `default_wings.rs`.

### 1.12.0 -- 2026-07-16
MX-TAB-4 and HLC audit-model corrections:

- **Drawer struct**: `wing: String` and `room: String` fields replaced by
  `parentNodeId: String` (node-tree containment). Display names are
  resolved via `DrawerStore.resolveNodeNames(parentNodeIds:)` when needed; they
  are no longer stored on the struct. Init signature updated accordingly.
- **RecallFrame.asOf**: type changed from `Date?` to `HLC?` (§11 clock decision
  — state is keyed on HLC, not wall-clock). Init default updated.
- **Audit model**: `AuditRow`, `AuditActor`, and `BitmapColumn` replaced by
  `AuditEvent` from `SubstrateTypes` (G-Set CRDT audit row, cookbook §5.1).
  `Estate.auditTrail(rowID:)` return type is now `[AuditEvent]` (internal).
  The wall-clock range form `auditTrail(since:until:)` was dropped — HLC is the
  ordering axis. `Estate.bitmapState` parameter label changed `at:` → `asOf:`
  and type `Date` → `HLC`; reconstruction now uses `AuditLogFold.projectStateAt`
  rather than XOR-fold. `BitmapState.asOf` is `HLC`, not `Date`.
- **ContentKind.dataset = 7** added (MX-TAB-3).
- **LocusKitError.withdrawnDatasetHandle(datasetId: UUID)** added (MX-TAB-4);
  thrown by `Estate.resolveActiveDatasetHandle(datasetId:)`.
- **Dataset handle types** added to Tier 2: `DatasetColumnSummary`,
  `DatasetHandleContent`, `datasetHandleEmbeddingModelID` (`DatasetHandle.swift`
  / `dataset_handle.rs`).
- **SourceCatalogEntry concordance fields** corrected: was `displayName`,
  `addedAt`, `metadata`; actual fields are `latticeAnchor`, `firstSeen`, `addedBy`.
- **SourceKind concordance** corrected: was "4-case enum" omitting
  `.tierInheritance=4` and `.pairedEstate=5`; corrected to 6-case.

### 1.11.0 -- 2026-06-25
Added the `Estate` consumer metadata surface (`meta(key:)` / `setMeta(key:value:)`
Swift; `meta` / `set_meta` Rust) — the public, durable, lowest-level key-value
primitive over the manifest table that upper layers persist their own state
through (resolves the "future verb surface" the manifest accessor anticipated;
see the daemon-state persistence contract). Additive, both ports.

### 1.10.0 -- 2026-06-23
Charter special-casing removed (the wing-organization contract §2 amendment). `WingDefinition`'s second
field renamed `charter` → `hint` on both ports; the seeded wing hint is now a
NORMAL drawer (filed into the `AI_Charter_Hint` room, normal embedding,
recallable, counted, user-deletable) — no reserved room, no `added_by` sentinel,
no `embeddingModelID = "none"`, no recall/estate_map exclusion. Updated the
WingDefinition concordance row.

### 1.6.0 -- 2026-06-17
`DrawerStore.addDrawer` narrowed from `public` to `internal` in Swift (§11.5
Option B structural add-coverage guarantee). The only sanctioned verb-layer add
path is now `Estate.addDrawerCovered(_:now:)`, a private Estate method that
bundles `store.addDrawer` + `containerFP.orIn` atomically — ensuring every
capture maintains the per-container OR aggregate without a second call site. On
the Rust side, `DrawerStoreCore::add_drawer` folds the FP update inside itself;
`or_in_container_fingerprint` is now the rebuild/backfill path only. Two new
conformance tests added to both ports: `addCoverageGuaranteeAllThreeBitmaps`
asserts `aggregate & drawerBits == drawerBits` for all three bitmap fields at
both room and wing levels; `addCoverageTwoDrawersSameRoom` asserts the aggregate
covers both drawers after two captures into the same room. Both new tests pass
green in both ports.

### 1.5.1 -- 2026-06-17
`CaptureFrame` now exposes the `confirmation` (`Confirmation`, default
`.unconfirmed`) and `confidence` (`Confidence`, default `.null`) provenance
axes in both ports, joining the already-exposed `provenanceChannel`,
`sourceType`, and `provenanceSensitivity`. The `capture` verb writes them into
the provenance bitmap at bits 18–23 / 24–29 (cookbook §2.5) — the exact windows
the drawer's `confirmation` / `confidence` read accessors decode. Additive and
behaviour-preserving: both defaults are raw 0, so an existing caller that omits
them produces the same provenance bytes as before the slots existed. A daemon
or agent capturing already-confirmed content with a known confidence band may
now record both at birth, instead of relying on a later `confirm` mutation or
enrichment pass (the test-only `_setProvenance` backdoor's "capture does not yet
expose this through CaptureFrame" comment is removed). Cross-port round-trip +
default-byte-identity conformance added (`EstateVerbTests.swift` ↔
`estate_verbs.rs` capture-provenance tests). Separately, corrected the stale
`BitmapEvaluator.evaluate` doc comments in both ports that claimed recall hands
in `allDrawers()` and that fingerprint pruning (§ 7.9.4 step 1) was deferred —
container OR-fingerprint pruning has shipped in the recall path (`liveRows` /
`container_survives`); the evaluator already receives the pruned candidate set.

### 1.4.0 -- 2026-06-17
`DrawerFingerprint`'s lattice-block `qidClosureHash` facet is now live in both
ports (mission #7b). When a drawer's `wikidataQID` has P31/P279 ancestors in
LatticeLib's pinned Q-ID closure snapshot, the block hashes `FNV.hash16` of the
sorted-numeric, `"|"`-joined transitive ancestor list
(`LatticeLib.QIDClosure.ancestors(of:)`); no QID or no ancestors → the
deterministic null 0 (preserving the prior behaviour for those rows). Adds a
`LocusKit → LatticeLib` package dependency (downstream → upstream, no cycle;
authority the package-dependency rule, required by the #7
feature). Removed the stale "Q-ID closure cache deferred (I-17)" comments. The
fingerprint output changes only for drawers whose `wikidataQID` has ancestors;
cross-port conformance preserved.

### 1.9.0 -- 2026-06-22
GLK_BATCH1: `Estate.captureBatch(_:)` added — inserts all frames in a single
`storage.transaction()`. Fresh drawers (no active lineage predecessor) go
through `DrawerStore.insertFreshBatch(_:now:)` for a one-lock, one-commit write;
drawers needing supersession cascade fall back to per-item `addDrawerCovered`.
Post-insert coverage (`containerFP.orIn` + `rollupMerkleRoots`) runs for
fresh-batch drawers. `DrawerStore.findActivePredecessor` visibility widened from
`private` to `internal` to support the batch split. Returns drawers in input
order. Callers must invoke `moot_reindex` / `moot_dream` to rebuild BM25/vector
lanes after batch import.

### 1.8.0 -- 2026-06-21
NT-DOC-1: Added 5 the node-integrity contract concordance rows to § 7. Entities section gains `Node`
(tree node entity, 13 fields, ISO8601-TEXT date seam). Estate/store types gains
`NodeStore` (Swift actor / Rust struct, 7 verbs). Additional public types gains
`WingDefinition` (2-field provisioning struct, static string seam), plus
`SnapshotAttestation` and `SnapshotRecord` documented as Rust-only (LocusKit-homed)
with layering-mismatch notes pointing to the PersistenceKit Swift counterparts.

### 1.7.0 -- 2026-06-21
Schema v5 → v6 (the node-integrity contract §11): `TunnelKind.parent` (raw 9) adds typed parent edges to the tunnel graph for outline containment, orthogonal to the node-tree containment hierarchy. `Tunnel` gains `orderKey: Double?` (`order_key: Option<f64>` in Rust) for fractional-index sibling ordering. Schema adds `order_key REAL` nullable column and two new indices (`idx_tunnels_kind_source_drawer`, `idx_tunnels_kind_target_drawer`). Three new `DrawerStore` methods: `outlineChildren(of:)` (children sorted by order_key), `outlineAncestors(of:)` (root-first ancestor walk, 256-depth ceiling), `reparentDrawer(_:newParentId:orderKey:wing:room:addedBy:now:)` (tombstone + recreate). One-parent-per-child enforced in `addTunnel`. All three backends (InMemory, SQLite, Postgres). Rust `Tunnel` uses manual `PartialEq`/`Eq`/`Hash` via `f64::to_bits()` for the `order_key` field.

### 1.3.0 -- 2026-06-17
`ProposeFrame` now carries the three proposal provenance axes in both ports: `confirmation` (`ProposalConfirmationSource`, default `.human`), `generatedBy` (`ProposalGeneratedByClass`, default `.dreamingDaemon`), and `confidence` (`ProposalConfidenceBucket`, default `.null`). The `propose` verb wires all three into the proposal operational bitmap at bits 12–17 / 18–23 / 24–29 — the exact windows the `confirmationSource` / `generatedByClass` / `confidenceBucket` read accessors (cookbook §2.4) decode — replacing the previous behaviour where those windows were hard-zeroed regardless of producer. Additive and behaviour-preserving: the three defaults reproduce the pre-wire bitmap byte-for-byte, so existing callers (NeuronKit daemon sinks, GLK boundary, scheduler) are unaffected. Daemon-emitted proposals may now set their true producer class so provenance reflects reality rather than the zero fallback. Cross-port round-trip + default-byte-identity conformance added (`ProposeProvenanceTests.swift` ↔ `estate_verbs.rs` propose-provenance tests). Removed the stale "a later sub-mission wires them through the Brain layer ProposalFrame" deferral comment in both ports.

### 1.5.1 -- 2026-06-17
`SqliteDrawerStore` gains a second public constructor `from_path_with_config(EstateConfiguration, now, hlc)` that accepts a caller-supplied `EstateConfiguration` (including `cache_config`). When `cache_config.enabled` is true `SqliteStorage::row_store()` wraps the backing store in a `CachingRowStore` LRU hot tier — closing the InMemory/SQLite caching parity gap. The existing `from_path` constructor is unchanged. Updated the Drawer store row in the concordance table to document both constructors and the cache-enable predicate. moot-mgr's `make_storage` now calls `from_path_with_config` for the SQLite backend so the resolved cache config is threaded through (A-16).

### 1.2.0 -- 2026-06-17
`KGFact` now exposes all four adjective-bitmap axes in both ports. Added the `state` (bits 0–5), `adjectiveSensitivity` (bits 6–11), and `exportability` (bits 12–17) computed accessors alongside the existing `trust` (bits 18–23), matching the `Drawer` adjective layout and fail-closed defaults exactly (`.active` / `.normal` / `.private_` / `.verbatim`). Rust: `state()`, `adjective_sensitivity()`, `exportability()`. Additive surface; a fact can now be filtered by the same retrieval-layer predicates as its source drawer. Cross-port conformance added (shared-bitmap coexistence vector). Removed the stale "future sub-mission" comments that claimed these accessors were deferred.

### 1.1.1 -- 2026-06-17
Rust `DrawerStore` brought to Swift parity on compile-enforcement: `all_drawers` and `room_level_fingerprints` are now required trait methods with NO default (a backend that forgets either fails to COMPILE, not at runtime). Documented the compile-required-reads exception alongside the existing fail-loud-default newtype-forwarding contract. No behaviour change for any production backend (all three already implement both); no signature change.

### 1.1.0 -- 2026-06-17
Schema v1 → v2 (the forward-compatible ext-slot contract): added the nullable `.json` `ext` forward-compat slot to the `keys` table, completing the one-`ext`-column-per-persistent-entity convention. Both ports; 1.0 writes NULL and never reads it. Updated the `LocusKitSchema.version` surface and the `keys`-table concordance row.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
