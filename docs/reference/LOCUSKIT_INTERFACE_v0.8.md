---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: LocusKit
languages: [swift, rust]
relates_to:
  - LOCUSKIT_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of LocusKit in both ports, in two tiers within
  § 2. Tier 1 is the CONSUMED CONTRACT — the types GeniusLocusKit,
  NeuronKit, and ARIA_MCP actually import (the Estate actor, the four
  nouns, the verb frames, the recall stream, the filter algebra, the
  bitmap value enums, the manifest, and the error surfaces) —
  documented with bilingual signatures. Tier 2 (§ 2's closing
  subsection) is the BROADER SURFACE — the internal stores, validators,
  fingerprint machinery, and bitmap helpers that are public for testing
  and intra-kit use, consumed by the kit's own pipeline and tests rather
  than another package; a table of
  contents (name + role + source file). The companion SPEC carries the
  behavioral contracts (invariants I-1…I-11, conformance C-1…C-7).
---

# LocusKit Interface

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

> **Two-tier surface.** LocusKit declares 74 public types in the Swift version,
> of which 33 are referenced by another package (GeniusLocusKit, NeuronKit,
> ARIA_MCP; measured 2026-05-27). Several of those measured hits are
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

    // Verbs (extension Estate, EstateVerbs.swift):
    public func capture(_ frame: CaptureFrame) async throws -> Drawer
    public func recall(_ frame: RecallFrame) async -> RecallStream
    public func withdraw(rowID: RowID, reason: String? = nil) async throws
    public func mutate(rowID: RowID, kind: MutationKind, payload: String? = nil) async throws
    public func expunge(rowID: RowID, reason: String, confirmation: Bool) async throws
    public func reanchor(rowID: RowID, toRoom: RoomID? = nil, toLattice: LatticeAnchor? = nil) async throws
    public func learn(_ frame: LearnFrame) async throws

    // History (extension Estate, EstateAudit.swift):
    public func auditTrail(rowID: RowID) async throws -> [AuditRow]
    public func auditTrail(since: Date, until: Date? = nil) async throws -> [AuditRow]
    public func bitmapState(rowID: RowID, at timestamp: Date) async throws -> BitmapState

    // Association graph (extension Estate, Estate.swift):
    public func tunnelsFromWing(_ wing: String) async throws -> [Tunnel]

    // Dreaming substrate reads (extension Estate, Estate.swift):
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem]
    public func allTunnels() async throws -> [Tunnel]
}
```
**Rust:** `pub struct Estate` with `open`, `create`, `close`, `manifest`,
`estate_uuid`, and verbs `capture(frame, now: i64)`, `recall(frame, now: i64)`,
`withdraw(...)`, `mutate(...)`, `expunge(...)`, `reanchor(...)`, `learn(...)`,
each taking `now: i64`, plus the association-graph read
`tunnels_from_wing(wing: &str) -> Result<Vec<Tunnel>, LocusKitError>`.
All synchronous (SPEC § 8). `propose` / `associate`
are reached through the tunnel and KG-fact store paths, not as dedicated verb
methods.

#### `Drawer`

The atomic, content-immutable memory unit (SPEC § 1, I-3). Three Int64
bitmaps carry all categorical/boolean state (I-2).

```swift
public struct Drawer: Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let lineageID: UUID
    public let content: String                 // verbatim, never mutated (I-3)
    public let wing: String
    public let room: String
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
    public init(id: String = UUID().uuidString, content: String, wing: String, room: String,
                sourceFile: String? = nil, chunkIndex: Int? = nil, addedBy: String,
                filedAt: Date, eventTime: Date? = nil, embeddingModelID: String,
                tombstonedAt: Date? = nil, removedByBatch: String? = nil,
                provenance: Int64 = 0, adjectiveBitmap: Int64 = 0, operationalBitmap: Int64 = 0,
                lineageID: UUID = UUID(), udcCode: String = "", udcFacets: String? = nil,
                wikidataQID: String? = nil, wikidataQidsSecondary: String? = nil)

    // Computed accessors (no Bool stored property, I-2):
    public var sourceType: SourceType; public var confirmation: ConfirmationState
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
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
    public let filedAt: Date
    public init(id: String = UUID().uuidString, subject: String, predicate: String, object: String,
                sourceDrawerID: String, adjectiveBitmap: Int64 = 0, operationalBitmap: Int64 = 0,
                provenanceBitmap: Int64 = 0, filedAt: Date)
    public var trust: Trust   // operational accessors in KGFactOperational.swift (Tier 2)
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
    public init(id: String, sourceWing: String, sourceRoom: String, sourceDrawerId: String? = nil,
                targetWing: String, targetRoom: String, targetDrawerId: String? = nil,
                label: String, kind: TunnelKind = .references, adjectiveBitmap: Int64 = 0,
                operationalBitmap: Int64 = 0, provenanceBitmap: Int64 = 0, addedBy: String,
                filedAt: Date, tombstonedAt: Date? = nil, removedByBatch: String? = nil)
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
```
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
    public var lineageID: LineageID?; public var room: RoomID; public var latticeAnchor: LatticeAnchor
    public var addedBy: String; public var embeddingModelID: String; public var eventTime: Date?
    public init(content: String, channel: CaptureChannel, room: RoomID, latticeAnchor: LatticeAnchor,
                addedBy: String, embeddingModelID: String, sensitivity: AdjectiveSensitivity = .normal,
                kind: ContentKind = .prose, lineageID: LineageID? = nil, eventTime: Date? = nil)
}
public struct RecallFrame: Sendable {
    public var filterChain: [Filter]            // implicit AND (B-4)
    public var hydrationLevel: HydrationLevel; public var limit: Int?
    public var ordering: Ordering; public var asOf: Date?
    public init(filterChain: [Filter], hydrationLevel: HydrationLevel = .structured,
                limit: Int? = nil, ordering: Ordering = .byCaptureTimeDesc, asOf: Date? = nil)
}
public struct LearnFrame: Sendable { public var handle: String; public init(handle: String) }
public enum MutationKind: Sendable {
    // Confirmation axis (provenance bits 18–23):
    case confirm                                   // → userConfirmed
    // State axis (adjectiveBitmap bits 0–5 via DrawerStore.mutateState):
    case reject                                    // → rejected (automaton: from pending only)
    case contest                                   // → contested (from active, pending)
    case resolve                                   // contested → active (guard: must be contested)
    case supersede                                 // → superseded (from active, accepted)
    case revive                                    // Cluster B → active (guard: isKnewPast;
                                                   //   automaton supports decayed only — follow-up
                                                   //   mission extends for withdrawn/expired)
    case accept                                    // → accepted (guard: trust ≥ canonical, S-1)
    // Adjective axis (adjectiveBitmap via DrawerStore.mutateAdjective):
    case correctSensitivity(AdjectiveSensitivity)  // bits 6–11
    case correctTrust(Trust)                       // bits 18–23
}
```
**Rust:** `pub struct CaptureFrame`, `RecallFrame`, `LearnFrame`,
`pub enum MutationKind` mirror these. Rust verbs add an explicit `now: i64`
parameter (SPEC § 8).

#### `Filter`, `StateCluster`, and the recall enums

The named recall-filter algebra (SPEC § 5, B-4). Every case is a named value
or a domain argument — no raw masks or thresholds.

```swift
public indirect enum Filter: Sendable {
    // state:       currentlyBelieve, usedToBelieve, knewOnceAndErased, state(State), stateInCluster(StateCluster)
    // trust:       trustworthy, requiresConfirmation, trust(Trust), trustAtMost(Trust)
    // sensitivity: sensitivity(AdjectiveSensitivity), sensitivityAtMost(AdjectiveSensitivity)
    // export:      exportable, contained
    // provenance:  userConfirmed, modelConfirmedOnly, unconfirmed, sourceType(SourceType),
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
public enum Ordering: Sendable { case byCaptureTimeDesc, byCaptureTimeAsc, byRelevanceDesc, byRoomAsc }
```
**Rust:** `pub enum Filter` (and `StateCluster`, `HydrationLevel`, `Ordering`)
mirror these cases.

#### `RecallStream` / `RecallPage`

The paged async result sequence (SPEC § 5, B-5/B-6).

```swift
public struct RecallStream: AsyncSequence, Sendable {
    public typealias Element = RecallPage
    public static let defaultPageSize = 50
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
Bit layouts per architecture spec § 5.5 / § 5.6 and `Q1_DECISION_PROVENANCE_BITMAP`.

```swift
// adjective bitmap (Adjectives.swift)
public enum State: Int { case active=0, pending, contested, superseded, decayed, withdrawn, expired, rejected, accepted, tombstoned }
public enum Trust: Int, Comparable { case verbatim=0, observed, imported, canonical, derived, proposed }
public enum AdjectiveSensitivity: Int { case normal=0, elevated=4, restricted=8, secret=12 }   // scale-gapped
public enum AdjectiveExportability: Int { case private_=0, public_=8 }
// operational bitmap (DrawerOperational.swift)
public enum CaptureChannel: Int { case typed=0, voiced, ocr, importedFile, sensor }
public enum ContentKind: Int { case prose=0, code, transcript, list, structuredJSON, imageCaption }
public struct DrawerFeatureFlags: OptionSet { /* hasAttachments(8), hasVoice(9), hasImage(10), hasLinks(11), isPinned(12) */ }
public typealias FeatureFlag = DrawerFeatureFlags
// provenance bitmap (Provenance.swift)
public enum SourceType: Int { case unknown=0, observed, userStated, modelInferred, externalDoc, instruction, imported, derived }
public enum ConfirmationState: Int { case unconfirmed=0, modelConfirmed, userConfirmed, contested, superseded, tombstoned }
public enum Confidence: Int, Comparable { case unknown=0, low, mediumLow, medium, mediumHigh, high, certain }
public enum Channel: Int { case unknown=0, directChat, slack, email, teams, discord, matrix, telegram, whatsapp, cli, api, mcp, fileImport, web, voice }
public enum Sensitivity: Int { case normal=0, elevated, restricted, secret }   // 2-bit, distinct from AdjectiveSensitivity
public typealias ProvenanceChannel = Channel
public typealias Vector = [Float]      // vector recall composes via VectorKit
```
**Rust:** identical enums and raw values (`snake_case` cases); `DrawerFeatureFlags`
is a Rust bitflags-style struct with the same bit positions.

#### Audit history: `AuditRow`, `BitmapState`, `BitmapColumn`, `AuditActor`

Returned by `Estate.auditTrail` / `bitmapState` (SPEC § 5, B-9; append-only I-8).

```swift
public struct AuditRow: Sendable {
    public let auditID: Int64; public let rowID: RowID; public let timestamp: Date
    public let actor: AuditActor; public let beforeBitmap, afterBitmap: Int64
    public let bitmapColumn: BitmapColumn; public let reason: String; public let isTombstoned: Bool
}
public struct BitmapState: Sendable {
    public let rowID: RowID; public let asOf: Date
    public let adjectiveBitmap, operationalBitmap, provenanceBitmap: Int64
}
public enum BitmapColumn: String, Codable { case adjective = "adjectiveBitmap", operational = "operationalBitmap", provenance = "provenanceBitmap" }
public struct AuditActor: Sendable, Equatable { public let identifier: String; public init(_ identifier: String) }
```
**Rust:** `pub struct AuditRow`, `BitmapState`, `pub enum BitmapColumn`,
`pub struct AuditActor` mirror these.

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
public enum LocusKitSchema { public static let kitID = "LocusKit"; public static let version = 1
                             public static var schema: SchemaDeclaration { get } }
public actor DrawerStore {
    public init(storage: any Storage) async throws
    public func addDrawer(_ d: Drawer, now: Date = Date()) async throws
    public func getDrawer(id: String) async throws -> Drawer?
    public func drawersIn(wing: String) async throws -> [Drawer]
    public func drawersIn(wing: String, room: String) async throws -> [Drawer]
    public func allDrawers() async throws -> [Drawer]
    public func mutateAdjective(...) async throws; public func mutateOperational(...) async throws
    public func mutateProvenance(...) async throws; public func mutateState(...) async throws
    public func addTunnel(_ t: Tunnel) async throws; public func getTunnel(id: String) async throws -> Tunnel?
    public func addKGFact(_ f: KGFact) async throws; public func kgFacts(forDrawerID: String) async throws -> [KGFact]
    public func withdrawKGFact(id: String) async throws  // GLK-VERB-EXT-01: transitions adjectiveBitmap to State.withdrawn (exits g_state_cluster < 7 filter)
    public func addDiaryEntry(_ e: DiaryEntry) async throws; public func readDiary(agentName: String, lastN: Int = 10) async throws -> [DiaryEntry]
    public func insertRecallTrace(_ item: RecallTraceItem) async throws
    public func getRecallTrace(id: String) async throws -> RecallTraceItem?
    public func recallTraceSince(_ since: Date) async throws -> [RecallTraceItem]
    public func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem]
    public func markRecallTraceUsed(id: String, now: Date) async throws
    public func allTunnels() async throws -> [Tunnel]
    public func listWings() async throws -> [WingSummary]; public func listRooms(in wing: String?) async throws -> [RoomSummary]
    public func readManifest() async throws -> ManifestValues; public func setMeta(key: String, value: String) async throws
    public func bitmapAuditTrail(rowID: String) async throws -> [AuditRow]
    public func bitmapAuditTrail(since: Date, until: Date?) async throws -> [AuditRow]
    // … full CRUD + audit surface, see DrawerStore.swift
}
```
**Rust:** `pub trait DrawerStore: Send + Sync` with `InMemoryDrawerStore`
(plus `SqliteDrawerStore` and `PostgresDrawerStore` delegation wrappers);
methods are synchronous and take `now: i64`. The Swift `DrawerStore` is a
concrete actor over any injected `Storage` (SQLite in production); the Rust
version realises the same store contract through the trait (SPEC § 8).
GLK-RUST-WRITE-PATH-01 added `withdraw_kg_fact(id: &str, now: i64)` to the
trait with a `DatabaseUnavailable` default; `DrawerStoreCore` carries the
live implementation (sets bits 0–5 of `adjective_bitmap` to `State::Withdrawn`
raw 18, preserving upper bits — mirrors `withdrawKGFact` in the Swift actor).

### Tier 2 — broader surface (table of contents)

The following public types are part of the kit's surface and consumed by its
own pipeline and tests, not (yet) by another package (measured 2026-05-27).
They are public for `@testable` intra-kit use and conformance tests. Recorded
as a navigable index — name, role, source file. Full signatures live in the
cited file.

- **Recall-pruning fingerprints:** `ContainerFingerprint`,
  `ContainerFingerprintStore` (per-container OR aggregate, recall pruning,
  SPEC B-7), `EstateFingerprintFamilies` (per-drawer fingerprint via SubstrateLib
  `HyperplaneFamily`) — `ContainerFingerprintStore.swift`, `DrawerFingerprint.swift`.
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
}
public enum EstateError: Error, Sendable, Equatable {
    case substrateUnavailable(String)
    case manifestMismatch(key: String, found: String, expected: String)
    case emptyOwnerIdentifier
}
```
**Rust:** `pub enum LocusKitError` and `pub enum EstateError` mirror these
cases (`error.rs`, `estate.rs`). Meaning: SPEC § 6.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/LocusKit
```

(Target: `LocusKitTests`.)

**Rust:**

```
cargo test -p locus-kit
```

(Exercises the `DrawerStore` contract — SPEC § 8.)

## § 6 — Examples

```swift
import LocusKit
import PersistenceKit

let storage = try await SQLiteStorage(/* … */)            // caller builds the backend (I-10)
let estate = try await Estate.create(storage: storage,
                                     owner: OwnerCredentials(ownerIdentifier: "icloud:bob"))

// Capture — validated, then written; bitmaps assembled from named slots.
let drawer = try await estate.capture(CaptureFrame(
    content: "Organic chemistry covers carbon compounds.",
    channel: .typed,
    room: "chemistry",
    latticeAnchor: .udc("547"),                            // udcCode required (I-5)
    addedBy: "bob",
    embeddingModelID: "text-embedding-3-small"))           // required (I-4)

// Recall — implicit-AND filter chain; defaults to currently-believed,
// trustworthy, user-confirmed when those axes are unspecified (B-4).
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
| `drawers` table | `LocusKitSchema.drawersTable` (LocusKitSchema.swift:118) | `drawers_table()` (schema.rs:91) | Present | Generated columns and indices match |
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
| `keys` table (ENC-01) | `LocusKitSchema.keysTable` (LocusKitSchema.swift:532) | `keys_table()` (schema.rs:559) | Present | Added PAR-4-LK: key_id TEXT PK, algorithm TEXT, wrapped BLOB, created_at TIMESTAMP (ISO8601); no bitmap columns; no generated columns |

**Date storage invariant:** all `timestamp` / `created_at` / `filedAt` columns use
`ColumnType::Timestamp` in Rust (emitted as TEXT ISO8601 by PersistenceKit backends),
matching Swift's `.timestamp(...)` — never REAL (Unix timestamp).

**Schema version:** both ports declare `version = 1` with no migration ladder
(`migrations` list is empty in Rust; no `ALTER TABLE` history in Swift). The ENC-01
`keys` table was present in the Swift v1 declaration from the outset; this concordance
row records that the Rust port now matches.

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
| Tunnel capture frame | `TunnelCaptureFrame` (Frames.swift:138) | `TunnelCaptureFrame` (frames.rs:147) | public / pub | identical | `CaptureTunnelTests.swift` ↔ `capture_tunnel_tests.rs` | Confirmed |
| Recall frame | `RecallFrame` (Frames.swift:197) | `RecallFrame` (filter.rs:194) | public / pub | identical (different source file per port) | `RecallPaginationTests.swift` ↔ `lp0_vectors.rs::lp0_recall_stream` | Confirmed |
| Mutation kind | `MutationKind` (Frames.swift:236) | `MutationKind` (frames.rs:213) | public / pub | identical | `MutateMutationKindTests.swift` | Confirmed |
| Learn frame | `LearnFrame` (Frames.swift:267) | `LearnFrame` (frames.rs:244) | public / pub | identical | `FrameTests.swift` | Confirmed |
| Propose frame | `ProposeFrame` (Frames.swift:285) | `ProposeFrame` (frames.rs:265) | public / pub | identical | `FrameTests.swift` | Confirmed |
| Associate frame | `AssociateFrame` (Frames.swift:306) | `AssociateFrame` (frames.rs:290) | public / pub | identical | `FrameTests.swift` | Confirmed |
| Hydration level | `HydrationLevel` (Frames.swift:325) | `HydrationLevel` (filter.rs:56) | public / pub | identical (different source file per port) | `FrameTests.swift` | Confirmed |
| Ordering | `Ordering` (Frames.swift:337) | `Ordering` (filter.rs:69) | public / pub | identical (different source file per port) | `RecallPaginationTests.swift` | Confirmed |
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
| Estate facade | `Estate` (Estate.swift:29, `public actor`) | `Estate` (estate.rs:48, `pub struct`) | public / pub | Swift `actor` (async, compiler-serialized) / Rust `struct` (sync; no async runtime — sanctioned, cf. NeuronKit policy-store seam) | `EstateTests.swift` / `EstateVerbTests.swift` ↔ `lp0_vectors.rs` (`Estate::create`) | Confirmed |
| Owner credentials | `OwnerCredentials` (EstateTypes.swift:28) | `OwnerCredentials` (estate_types.rs:31) | public / pub | identical | `EstateTests.swift` | Confirmed |
| Lattice anchor | `LatticeAnchor` (EstateTypes.swift:55) | `LatticeAnchor` (estate_types.rs:62) | public / pub | identical | `LatticeAnchorTests.swift` | Confirmed |
| Estate error | `EstateError` (EstateTypes.swift:96) | `EstateError` (estate_types.rs:111) | public / pub | identical case set | `EstateTests.swift` | Confirmed |
| Estate fingerprint families | `EstateFingerprintFamilies` (DrawerFingerprint.swift:68) | `EstateFingerprintFamilies` (drawer_fingerprint.rs:73) | public / pub | identical | `DrawerFingerprintTests.swift` | Confirmed |
| Kit error | `LocusKitError` (LocusKitError.swift:11) | `LocusKitError` (error.rs:21) | public / pub | identical case set | `LocusKitVectorsTests.swift` (error paths) | Confirmed |
| Bitmap state snapshot | `BitmapState` (AuditTypes.swift:27) | `BitmapState` (audit_types.rs:13) | public / pub | identical | `BitmapAuditTests.swift` ↔ `two_clock_ingest_tests.rs` | Confirmed |
| Drawer store | `DrawerStore` (DrawerStore.swift:54, `public actor` over PersistenceKit `Storage`) | `DrawerStore` trait (drawer_store.rs:75) + `DrawerStoreCore` (drawer_store_inmemory.rs:138) + `InMemoryDrawerStore` (…:2177) + `SqliteDrawerStore` (drawer_store_sqlite.rs:75) + `PostgresDrawerStore` (drawer_store_postgres.rs:87) | public / pub | Architectural seam: Swift is ONE actor that abstracts the backend through PersistenceKit's `Storage` protocol (SQLite/Postgres/InMemory chosen at the PersistenceKit layer); Rust splits the backend into a `DrawerStore` trait with per-backend structs sharing `DrawerStoreCore`. Same backends reached at different layers — sanctioned, no async runtime in Rust. | `DrawerStoreTests.swift` ↔ `lp0_vectors.rs` (drives `InMemoryDrawerStore` via `dyn DrawerStore`) + `rust/tests/drawer_store_sqlite.rs` | Confirmed |
| Container fingerprint store | `ContainerFingerprintStore` (ContainerFingerprintStore.swift:88, `actor`) | `ContainerFingerprintStore` (container_fingerprint_store.rs:130, `struct`) | public / pub | Swift `actor` / Rust `struct` (sync; no async runtime — sanctioned) | `ContainerFingerprintStoreTests.swift` | Confirmed |
| Room-level fingerprint entry | `roomLevelEntries()` returns tuple `(wing, room, fingerprint)` (ContainerFingerprintStore.swift:124) | `RoomLevelEntry` (container_fingerprint_store.rs:122) | public / pub | Swift labelled tuple / Rust named `pub struct` (same fields) | `ContainerFingerprintStoreTests.swift` | Confirmed |
| Node bundle store | `NodeBundleStore` (NodeBundleStore.swift:28, `actor`) | `NodeBundleStore` (node_bundle_store.rs:109, `struct`) | public / pub | Swift `actor` / Rust `struct` (sync; no async runtime — sanctioned) | `BundleMaterializerTests.swift` (exercises the store) | Confirmed |
| Bundle kind | `BundleKind` (NodeBundleStore.swift:33, nested) | `BundleKind` (node_bundle_store.rs:68, flat) | public / pub | Swift nested in `NodeBundleStore` / Rust flat top-level (same case set) | `BundleMaterializerTests.swift` | Confirmed |
| Room bundle | `rooms()` returns tuple `(room, bundle)` (NodeBundleStore.swift:120) | `RoomBundle` (node_bundle_store.rs:103) | public / pub | Swift labelled tuple / Rust named `pub struct` (same fields) | `BundleMaterializerTests.swift` | Confirmed |
| Bundle materializer | `BundleMaterializer` (BundleMaterializer.swift:35) | `BundleMaterializer` (bundle_materializer.rs:65, `<'a, K: SubstrateKernel>`) | public / pub | identical concept; Rust is generic over the substrate kernel (lifetime + `K` param) | `BundleMaterializerTests.swift` | Confirmed |

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
as Confirmed rather than DRIFT — but the asymmetry is flagged here so a
future pass can decide whether Rust should narrow it to `pub(crate)`.

---

*End of LocusKit Interface v0.8.*
