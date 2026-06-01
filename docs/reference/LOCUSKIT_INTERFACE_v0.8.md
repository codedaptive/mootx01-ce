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
}
```
**Rust:** `pub struct Estate` with `open`, `create`, `close`, `manifest`,
`estate_uuid`, and verbs `capture(frame, now: i64)`, `recall(frame, now: i64)`,
`withdraw(...)`, `mutate(...)`, `expunge(...)`, `reanchor(...)`, `learn(...)`,
each taking `now: i64`. All synchronous (SPEC § 8). `propose` / `associate`
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
    case confirm, reject, contest, resolve, supersede, revive, accept
    case correctSensitivity(AdjectiveSensitivity), correctTrust(Trust)
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
    // content:     contentMatches(String), nearVector(Vector, count: Int)   // .nearVector throws until VectorKit
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
    public func addDiaryEntry(_ e: DiaryEntry) async throws; public func readDiary(agentName: String, lastN: Int = 10) async throws -> [DiaryEntry]
    public func insertRecallTrace(_ item: RecallTraceItem) async throws
    public func markRecallTraceUsed(id: String, now: Date) async throws
    public func listWings() async throws -> [WingSummary]; public func listRooms(in wing: String?) async throws -> [RoomSummary]
    public func readManifest() async throws -> ManifestValues; public func setMeta(key: String, value: String) async throws
    public func bitmapAuditTrail(rowID: String) async throws -> [AuditRow]
    public func bitmapAuditTrail(since: Date, until: Date?) async throws -> [AuditRow]
    // … full CRUD + audit surface, see DrawerStore.swift
}
```
**Rust:** `pub trait DrawerStore: Send + Sync` with `InMemoryDrawerStore`;
methods are synchronous and take `now: i64`. The Swift `DrawerStore` is a
concrete actor over any injected `Storage` (SQLite in production); the Rust
version realises the same store contract through the trait (SPEC § 8).

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

---

*End of LocusKit Interface v0.8.*
