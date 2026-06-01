---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: GeniusLocusKit
languages: [swift, rust]
relates_to:
  - GENIUSLOCUSKIT_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of GeniusLocusKit in both ports, in two tiers within
  § 2. Tier 1 is the CONSUMED CONTRACT — the types NeuronKit and ARIA_MCP
  actually import (the GeniusLocusKit actor, the unified verb surface and
  its frames, the recall results, the fan-out and grant-gated federated
  read, the grant model, COW branching, the unified audit log, and the
  migration API) — documented with bilingual signatures. Tier 2 (§ 2's
  closing subsection) is the BROADER SURFACE — the Brain-layer scheduler,
  the six standing-signal specs, the matrix tier, the training daemon, the
  scope-key/decay-key internals, and the audit projection/recovery
  machinery that are public for intra-kit and conformance use, consumed
  by the kit's own pipeline rather than another package; a table of
  contents (name + role + source
  file). The companion SPEC carries the behavioral contracts (invariants
  I-1…I-15, conformance C-1…C-12).
---

# GeniusLocusKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/GeniusLocusKit/`

- `Sources/GeniusLocusKit/` — 46 files. The `GeniusLocusKit` actor and
  its registry (`GeniusLocusKit.swift`), the coordinator/verb/fan-out/
  federation/grant/branch/migration extensions, and the Brain layer under
  `Brain/`, `Matrix/`, `Training/`, `Audit/`.
- `Tests/GeniusLocusKitTests/`
- `Package.swift`

**Rust:** `packages/kits/GeniusLocusKit/rust/`

- `src/` — one module per surface (`coordinator.rs`, `handle.rs`,
  `fan_out.rs`, `verbs/`, `audit/`, `brain/`, `matrix/`, `training/`);
  crate `genius-locus-kit`, lib `genius_locus_kit`.

Naming differs by port convention (Swift `glkDeriveBranch` /
`registerStandingSignal`; Rust `snake_case`). The two versions also differ
in *shape* — Swift is the `GeniusLocusKit` actor with `async` methods; the
Rust version is synchronous (`EstateCoordinator` struct, a stateless verb
`Surface`, `SerialLaneScheduler`). Value-level results agree across the
whole surface (SPEC § 8, I-15).

> **Two-tier surface.** GeniusLocusKit declares 116 public types in the
> Swift version, of which 36 are referenced by another package (NeuronKit,
> ARIA_MCP; measured 2026-05-27). One of those 36 (`Key`, i.e.
> `UnifiedProjection.Key`) is a common-word coincidence; the genuinely
> consumed contract is the ~35 types in Tier 1 below — the actor, the verb
> frames, the recall results, the fan-out/federation/grant/branch/audit/
> migration types. § 2 Tier 1 documents that contract in full. The Tier 2
> subsection at the end of § 2 is a table of contents for the rest: the
> Brain-layer scheduler, signal specs, matrix tier, training daemon, and
> grant/audit internals, public for intra-kit and conformance use but not
> yet a cross-package dependency.

## § 2 — Public types

### Tier 1 — consumed contract

#### `GeniusLocusKit`

The composition actor that coordinates N estates and runs the Brain layer
(SPEC § 1, I-1…I-5). Its verb, fan-out, federation, grant, branch, signal,
and migration methods are declared across sibling extensions.

```swift
public actor GeniusLocusKit {
    public init()
    public var openEstateCount: Int { get }
    public var handles: [EstateHandle] { get }

    // Lifecycle (EstateCoordinator.swift) — SPEC B-1:
    public func open(storage: any Storage, owner: OwnerCredentials) async throws -> EstateHandle
    public func close(_ handle: EstateHandle) async throws
    public func estate(for handle: EstateHandle) throws -> LocusKit.Estate

    // Unified nine-verb surface (VerbSurface.swift) — SPEC B-2/B-3:
    public func capture(_ handle: EstateHandle, _ frame: CaptureFrame) async throws -> Drawer
    public func recall(_ handle: EstateHandle, _ frame: RecallFrame) async throws -> [Drawer]
    public func mutate(_ handle: EstateHandle, _ frame: MutateFrame) async throws
    public func withdraw(_ handle: EstateHandle, _ frame: WithdrawFrame) async throws
    public func expunge(_ handle: EstateHandle, _ frame: ExpungeFrame) async throws      // .expungeNotConfirmed
    public func reanchor(_ handle: EstateHandle, _ frame: ReanchorFrame) async throws    // .emptyReanchor
    public func learn(_ handle: EstateHandle, _ frame: LearnFrame) async throws
    public func propose(_ handle: EstateHandle, _ frame: ProposeFrame) async throws
    public func associate(_ handle: EstateHandle, _ frame: AssociateFrame) async throws

    // Association-graph read (VerbSurface.swift) — the edges the structural
    // reasoning-lens recipes read; parallels `recall`, read-only:
    public func recallTunnels(_ handle: EstateHandle, wing: String) async throws -> [Tunnel]

    // Read fan-out (CrossEstateRead.swift) — SPEC B-4:
    public func estatesOverlapping(_ region: LatticeRegion) throws -> [EstateHandle]
    public func fanOutRecall(_ frame: RecallFrame, region: LatticeRegion) async throws -> [EstateRecallContribution]

    // Grant-gated federated read (CrossEstateFederation.swift) — SPEC B-7:
    public func federatedRecall(_ frame: RecallFrame, from source: EstateHandle,
                                requestedBy requester: EstateHandle, now: Date = Date()) async throws -> FederatedRecallResult

    // Grants (VerbSurface.swift grant extension) — SPEC B-8:
    public func issueGrant(_ handle: EstateHandle, _ options: GrantOptions, now: Date = Date()) async throws -> IssueGrantResult
    public func revokeGrant(_ handle: EstateHandle, grantID: UUID, now: Date = Date()) async throws

    // Unified audit log (GeniusLocusKit.swift, VerbSurface.swift) — SPEC B-9/B-10:
    public func auditLog(for handle: EstateHandle) throws -> UnifiedAuditLog
    public func feedAuditLog(for handle: EstateHandle) async throws
    public func verifyAuditChain(_ handle: EstateHandle) async throws -> AuditChainReport

    // COW branching (VerbSurface.swift branch extension) — SPEC B-11:
    public func glkDeriveBranch(name: String, from handle: EstateHandle) async throws -> any BranchHandle
    public func glkDeriveBranch(name: String, fromBranch parentBranch: any BranchHandle) async throws -> any BranchHandle
    public func glkPromoteBranch(_ branch: any BranchHandle, replacing handle: EstateHandle) async throws
    @discardableResult
    public func glkMergeDrawers(_ drawerIDs: [RowID], from branch: any BranchHandle, into handle: EstateHandle) async throws -> MergeReport
    public func branchHandle(for branchID: BranchID) -> (any BranchHandle)?    // read accessor: resolve a tracked branch by id (stateless ARIA_MCP recipe callers)

    // Standing-signals API (SignalAPI.swift / DefaultStandingSignals.swift) — SPEC B-5/B-6:
    public func registerStandingSignal(_ spec: SignalSpec, in handle: EstateHandle, now: Date) async throws -> SignalID
    @discardableResult
    public func registerDefaultStandingSignals(in handle: EstateHandle, now: Date) async throws -> [String: SignalID]
    public func signalStatus(in handle: EstateHandle) async throws -> [SignalReport]
    public func signalTick(in handle: EstateHandle, now: Date) async throws
    public func signalRequestFire(_ signalID: SignalID, in handle: EstateHandle, now: Date) async throws
    @discardableResult
    public func signalSubscribe(_ signalID: SignalID, in handle: EstateHandle, callback: @escaping @Sendable (SignalEmission) -> Void) async throws -> SubscriptionID
    public func signalUnsubscribe(_ signalID: SignalID, subscription: SubscriptionID, in handle: EstateHandle) async throws
    public var openSchedulerCount: Int { get }

    // Migration (MigrationAPI.swift) — SPEC B-14:
    public func importFromMemPalace(_ corpus: ExternalCorpus, targetStorage: any Storage,
                                    owner: OwnerCredentials, now: Date) async throws -> (EstateHandle, MigrationReport)
    public func runParallel(source: EstateHandle, target: EstateHandle, mode: ParallelCaptureMode) async throws -> ParallelRunHandle
    public func verifyMigration(estate: EstateHandle, against corpus: ExternalCorpus, now: Date) async throws -> MigrationVerification
}
```
**Rust:** the Swift actor splits across synchronous types. The estate registry plus live verb dispatch is `EstateCoordinator` (`coordinator.rs`); `now: i64` and the zoom window are explicit per the Rust substrate's determinism convention.

```rust
pub struct EstateCoordinator { /* estate registry + COW-branch registry */ }

impl EstateCoordinator {
    pub fn new() -> Self;
    pub fn open_estate_count(&self) -> usize;
    pub fn handles(&self) -> Vec<EstateHandle>;

    // Lifecycle:
    pub fn open(&mut self, store: Arc<dyn DrawerStore>, owner: OwnerCredentials,
                zoom_window_low: i64, zoom_window_high: i64)
        -> Result<EstateHandle, GeniusLocusKitError>;
    pub fn close(&mut self, handle: &EstateHandle) -> Result<(), GeniusLocusKitError>;
    pub fn estate_for(&self, handle: &EstateHandle) -> Result<&Estate, GeniusLocusKitError>;

    // Six live verbs — delegate to the Rust LocusKit estate, returning
    // VerbDispatchError = EstateNotOpen | Verb(VerbError):
    pub fn capture(&self, handle: &EstateHandle, frame: CaptureFrame, now: i64) -> Result<Drawer, VerbDispatchError>;
    pub fn recall(&self, handle: &EstateHandle, frame: RecallFrame, now: i64) -> Result<Vec<Drawer>, VerbDispatchError>;
    pub fn recall_tunnels(&self, handle: &EstateHandle, wing: &str) -> Result<Vec<Tunnel>, VerbDispatchError>;
    pub fn mutate(&self, handle: &EstateHandle, row_id: &str, kind: MutationKind, payload: Option<&str>) -> Result<(), VerbDispatchError>;
    pub fn withdraw(&self, handle: &EstateHandle, row_id: &str, reason: Option<&str>, now: i64) -> Result<(), VerbDispatchError>;
    pub fn expunge(&self, handle: &EstateHandle, row_id: &str, reason: &str, confirmation: bool) -> Result<(), VerbDispatchError>;
    pub fn reanchor(&self, handle: &EstateHandle, row_id: &str, to_room: Option<&str>, to_lattice: Option<LatticeAnchor>) -> Result<(), VerbDispatchError>;

    // COW branch verbs (branches.rs):
    pub fn glk_derive_branch(&mut self, name: &str, from: &EstateHandle, now: i64) -> Result<BranchId, BranchError>;
    pub fn glk_derive_branch_from_branch(&mut self, name: &str, parent: BranchId, now: i64) -> Result<BranchId, BranchError>;
    pub fn glk_promote_branch(&mut self, branch_id: BranchId, replacing: &EstateHandle, now: i64) -> Result<(), BranchError>;
    pub fn glk_merge_drawers(&mut self, drawer_ids: &[String], from: BranchId, into: &EstateHandle, now: i64) -> Result<MergeReport, BranchError>;
    pub fn glk_discard_branch(&mut self, branch_id: BranchId) -> Result<(), BranchError>;
    pub fn branch_handle_for(&self, branch_id: BranchId) -> Option<&EstateBranch>;
}
```

Divergences from the Swift surface, stated honestly:

- **`learn` / `propose` / `associate` are not dispatched in Rust.** They raise `VerbError::NotSupportedByEstate` on the stateless lexicon `Surface` (`verbs/surface.rs`), which carries the nine-verb name-identity (`VERB_NAMES`) and the boundary guards (empty-reanchor, unconfirmed-expunge). The Brain layer wires live dispatch later. `recall_tunnels` (Rust `EstateCoordinator`) and `recallTunnels` (Swift) are matching association-graph read accessors on both legs — a dedicated tunnel read, distinct from `recall`.
- **Standing-signals API lives on `SerialLaneScheduler`** (`brain/scheduler/serial_lane.rs`): `register` / `tick` / `request_fire` / `subscribe` / `unsubscribe` — not on the coordinator. Default-set registration is `default_standing_signal_specs()` (`brain/signals`).
- **Rust parity pending** for the grant surface (`issueGrant` / `revokeGrant`), the grant-gated `federatedRecall`, the migration API, and the coordinator-level audit accessors (`auditLog(for:)` / `feedAuditLog` / `verifyAuditChain`). The Swift contract above is authoritative; the Rust port conforms to it as each surface lands. Read fan-out (`estatesOverlapping` / `fanOutRecall`) is already present (`fan_out.rs`), and the standalone audit verifier is `AuditRecovery::verify`.

#### `EstateHandle`

The value-type ticket addressing one estate (SPEC § 1, I-1). Carries a
cached manifest snapshot; not the live estate.

```swift
public struct EstateHandle: Sendable, Hashable {
    public let estateUUID: UUID
    public let zoomWindowLow: Int
    public let zoomWindowHigh: Int
    public let estateName: String
    // internal init(manifest:) — only the coordinator issues handles
}
```
**Rust:** (`handle.rs`)

```rust
pub type EstateUuid = [u8; 16];

pub struct EstateHandle {
    pub estate_uuid: EstateUuid,
    pub zoom_window_low: i64,
    pub zoom_window_high: i64,
}

impl EstateHandle {
    // Returns Err(InvalidManifest) when low > high.
    pub fn new(estate_uuid: EstateUuid, zoom_window_low: i64, zoom_window_high: i64)
        -> Result<Self, GeniusLocusKitError>;
}
```

The Rust handle carries no `estate_name` (the Swift handle's `estateName` has no Rust counterpart at v0.8); `estate_uuid` is a raw 16-byte array rather than a `UUID` type.

#### Verb frames: `CaptureFrame`, `RecallFrame`, `LearnFrame`, `MutationKind`, `WithdrawFrame`, `MutateFrame`, `ExpungeFrame`, `ReanchorFrame`, `ProposeFrame`, `AssociateFrame`

The named-slot inputs to the nine verbs (SPEC § 2, B-2). `CaptureFrame`,
`RecallFrame`, `LearnFrame`, `MutationKind`, `LatticeAnchor`, `RowID`,
`RoomID`, and `Drawer` are re-exported `typealias` of the LocusKit types so
callers need only `import GeniusLocusKit`. The remaining frames are
GLK-native (LocusKit's verb signatures for these are positional).

```swift
public typealias CaptureFrame = LocusKit.CaptureFrame
public typealias RecallFrame  = LocusKit.RecallFrame
public typealias LearnFrame   = LocusKit.LearnFrame
public typealias MutationKind = LocusKit.MutationKind
public typealias LatticeAnchor = LocusKit.LatticeAnchor
public typealias RowID = LocusKit.RowID          // String
public typealias RoomID = LocusKit.RoomID         // String
public typealias Drawer = LocusKit.Drawer

public struct WithdrawFrame: Sendable, Equatable {
    public let rowID: RowID; public let reason: String?
    public init(rowID: RowID, reason: String? = nil)
}
public struct MutateFrame: Sendable {
    public let rowID: RowID; public let kind: MutationKind; public let payload: String?
    public init(rowID: RowID, kind: MutationKind, payload: String? = nil)
}
public struct ExpungeFrame: Sendable, Equatable {
    public let rowID: RowID; public let reason: String; public let confirmation: Bool   // transient input, not a stored Bool (I-10)
    public init(rowID: RowID, reason: String, confirmation: Bool)
}
public struct ReanchorFrame: Sendable, Equatable {
    public let rowID: RowID; public let toRoom: RoomID?; public let toLattice: LatticeAnchor?
    public init(rowID: RowID, toRoom: RoomID? = nil, toLattice: LatticeAnchor? = nil)
}
public struct ProposeFrame: Sendable, Equatable {
    public let target: RowID; public let kind: ProposalKind; public let justification: String?
    public init(target: RowID, kind: ProposalKind, justification: String? = nil)
}
public struct AssociateFrame: Sendable, Equatable {
    public let a: RowID; public let b: RowID; public let weight: Double
    public init(a: RowID, b: RowID, weight: Double)
}
```
**Rust:** the `verbs` module (`verbs/frames.rs`) publishes the frame mirrors. Ids and content stay string-typed, and axis values are raw `i64` codes, until the LocusKit Rust port publishes the nominal types.

```rust
pub type RowId = String;
pub type RoomId = String;

pub struct LatticeAnchor {
    pub udc_code: String, pub udc_facets: Option<String>,
    pub wikidata_qid: Option<String>, pub wikidata_qids_secondary: Option<String>,
}
impl LatticeAnchor { pub fn udc(code: impl Into<String>) -> Self; }

pub enum MutationKind {
    Confirm, Reject, Contest, Resolve, Supersede, Revive, Accept,
    CorrectSensitivity(i64),   // Swift carries a Sensitivity enum; Rust a raw 0/4/8/12 value
    CorrectTrust(i64),         // Swift carries a Trust enum; Rust a raw 0..=5 value
}

pub struct CaptureFrame {
    pub content: String, pub channel: i64, pub kind: i64, pub sensitivity: i64,
    pub lineage_id: Option<String>, pub room: RoomId, pub lattice_anchor: LatticeAnchor,
    pub added_by: String, pub embedding_model_id: String,
}
pub struct RecallFrame {
    pub filter_chain: Vec<String>,   // opaque string tokens at this tier (see note)
    pub hydration_level: HydrationLevel, pub limit: Option<i64>,
    pub ordering: Ordering, pub as_of: Option<String>,   // ISO-8601 string until an HLC type lands
}
pub enum HydrationLevel { Structured, Full, BitmapOnly }
pub enum Ordering { ByCaptureTimeDesc, ByCaptureTimeAsc, ByRelevanceDesc, ByRoomAsc }

pub struct LearnFrame    { pub handle: String }   // full slot set lands with the Rust learn port
pub struct WithdrawFrame { pub row_id: RowId, pub reason: Option<String> }
pub struct MutateFrame   { pub row_id: RowId, pub kind: MutationKind, pub payload: Option<String> }
pub struct ExpungeFrame  { pub row_id: RowId, pub reason: String, pub confirmation: bool }
pub struct ReanchorFrame { pub row_id: RowId, pub to_room: Option<RoomId>, pub to_lattice: Option<LatticeAnchor> }
pub struct ProposeFrame  { pub target: RowId, pub kind: SchedulerProposalKind, pub justification: Option<String> }
pub struct AssociateFrame { pub a: RowId, pub b: RowId, pub weight: f64 }
```

Two divergences to note: (1) the `verbs`-module `RecallFrame.filter_chain` is an opaque `Vec<String>` at the scaffold tier, whereas the *live* `EstateCoordinator` verbs consume LocusKit's own frames — `locus_kit::filter::RecallFrame` with the typed `Vec<Filter>` (Swift's `[Filter]`); the two converge when the unified Rust port lands. (2) `LearnFrame` carries only `handle` in Rust so far.

#### `ProposalKind`

Typed taxonomy for a proposal's `kind`, replacing a stringly-typed field
(SPEC § 9). Round-trips through Codable as its `rawValue`; decode is total
(unknown strings → `.other`).

```swift
public enum ProposalKind: Sendable, Hashable, Codable {
    case byReferenceDrift, tournamentUpdate, miningPattern, disciplineViolation, mutateCandidate
    case amend, testPropose
    case other(String)
    public var rawValue: String { get }
    public init(rawValue: String)
}
```
**Rust:** `brain::scheduler::api::ProposalKind`, re-exported as `SchedulerProposalKind` (`lib.rs`), with the same raw wire strings.

```rust
pub enum ProposalKind {   // re-exported as SchedulerProposalKind
    ByReferenceDrift, TournamentUpdate, MiningPattern, DisciplineViolation,
    MutateCandidate, Amend, TestPropose, Other(String),
}
impl ProposalKind {
    pub fn raw_value(&self) -> &str;       // e.g. ByReferenceDrift => "by_reference_drift"
    pub fn from_raw(s: &str) -> Self;      // unknown strings => Other(s); total, like Swift's init(rawValue:)
}
```

#### `VerbError`

The verb-dispatch error surface (SPEC § 6). Distinct from
`GeniusLocusKitError`, which passes through unchanged.

```swift
public enum VerbError: Error, Sendable, CustomStringConvertible {
    case underlyingEstateFailure(verb: String, reason: String)
    case notSupportedByEstate(verb: String)
    case rejectedByLexicon(verb: String, noun: String)
    case emptyReanchor(rowID: RowID)
    case expungeNotConfirmed(rowID: RowID)
}
```
**Rust:** (`verbs/surface.rs`) — case-for-case parity (the parity test asserts the case-name set).

```rust
pub enum VerbError {
    UnderlyingEstateFailure { verb: String, reason: String },
    NotSupportedByEstate { verb: String },
    RejectedByLexicon { verb: String, noun: String },
    EmptyReanchor { row_id: RowId },
    ExpungeNotConfirmed { row_id: RowId },
}
```

The live coordinator wraps this as `VerbDispatchError` (`coordinator.rs`): `EstateNotOpen { estate_uuid }` | `Verb(VerbError)` — encoding the Swift split between `estate(for:)` throwing `estateNotOpen` and the verb body throwing `VerbError`.

#### `LatticeRegion` / `EstateRecallContribution`

The fan-out region and per-estate result (SPEC § 2, B-4).

```swift
public struct LatticeRegion: Sendable, Equatable {        // closed interval [low, high]
    public let low: Int; public let high: Int
    public init(low: Int, high: Int)
}
public struct EstateRecallContribution: Sendable {
    public let handle: EstateHandle; public let drawers: [Drawer]
}
```
**Rust:** (`fan_out.rs`)

```rust
pub struct LatticeRegion { pub low: i64, pub high: i64 }   // closed interval [low, high]
impl LatticeRegion { pub fn new(low: i64, high: i64) -> Self; }

pub struct EstateRecallContribution { pub handle: EstateHandle, pub drawers: Vec<Drawer> }

impl EstateCoordinator {
    pub fn estates_overlapping(&self, region: LatticeRegion) -> Result<Vec<EstateHandle>, GeniusLocusKitError>;
    pub fn fan_out_recall(&self, region: LatticeRegion) -> Result<Vec<EstateRecallContribution>, GeniusLocusKitError>;
}
```

#### `FederatedRecallResult` / `FederatedReadRefusalReason` / `IssueGrantResult`

The grant-gated read outcome and the refusal vocabulary (SPEC § 2, B-7),
plus the grant-issue result (B-8). The refusal reason is the payload of
`GeniusLocusKitError.crossEstateReadRefused`.

```swift
public struct FederatedRecallResult: Sendable {
    public let drawers: [Drawer]        // the SOURCE estate's rows only
    public let grant: Grant             // the authorizing grant (advisory scope)
    public let sourceHandle: EstateHandle; public let requesterHandle: EstateHandle
    public init(drawers: [Drawer], grant: Grant, sourceHandle: EstateHandle, requesterHandle: EstateHandle)
}
public enum FederatedReadRefusalReason: Sendable, Equatable { case noActiveGrant, grantExpired, grantRevoked }
public struct IssueGrantResult: Sendable {
    public let grant: Grant; public let scopeKey: Data?   // non-nil only for handed-over / decay-derived custody
}
```
**Rust:** parity pending — the port mirrors this Swift contract (`FederatedRecallResult`, `FederatedReadRefusalReason`, `IssueGrantResult`) when the grant-gated read surface lands. Unscoped read fan-out (`estatesOverlapping` / `fanOutRecall`) is already present (`fan_out.rs`, above).

#### Grant model: `Grant`, `GrantOptions`, `GrantScope`, `GrantLifetime`, `CustodyMode`, `ReSharePermission`, `DriftRate`, `GrantError`

The unit of sharing and its options (SPEC § 2, B-8). A `Grant` is signed,
audited, and persisted; `GrantOptions` is the issue-time input.

```swift
public struct Grant: Sendable, Codable, Equatable {
    public let id: UUID; public let granteeEstateID: UUID
    public let scope: GrantScope; public let contentLevel: Int
    public let lifetime: GrantLifetime; public let custodyMode: CustodyMode
    public let reSharePermission: ReSharePermission; public let inferenceRemainingBudget: Double
    public let issuedAt: Date; public let signature: Data
    public init(...); public var signingPayload: Data { get }
}
public struct GrantOptions: Sendable {
    public let granteeEstateID: UUID; public let scope: GrantScope
    public let custodyMode: CustodyMode; public let lifetime: GrantLifetime
    public let contentLevel: Int; public let reSharePermission: ReSharePermission
    public init(granteeEstateID: UUID, scope: GrantScope, custodyMode: CustodyMode = .mediated,
                lifetime: GrantLifetime = .permanent, contentLevel: Int = 0,
                reSharePermission: ReSharePermission = .none)
}
public enum GrantScope: Sendable, Codable, Equatable {
    case wholeEstate, wing(String), room(String), latticeSubtree(udcCode: String), singleRow(UUID)
}
public enum GrantLifetime: Sendable, Codable, Equatable {
    case permanent, until(Date), decayWindow(seconds: Int)
    // func expiry(issuedAt:) -> Date?
}
public enum CustodyMode: Sendable, Codable, Equatable {
    case mediated, handedOver                                   // production
    case decayDerived(threshold: Int, totalShares: Int, driftRatePerDay: DriftRate,
                      experimentalIPClearanceConfirmed: Bool)   // mode 3 (ENC-02, gated)
    case physicalDecay(experimentalIPClearanceConfirmed: Bool)  // mode 4 (gated, hardwareNotSupported)
}
public enum ReSharePermission: Sendable, Codable, Equatable { case none, withAudit, free }
public enum DriftRate: Sendable, Codable, Equatable { case slow, moderate, fast }
public enum GrantError: Error, Sendable, Equatable {
    case grantRevoked(id: UUID), grantExpired(id: UUID), experimentalModeNotActivated
    case hardwareNotSupported, grantNotFound(id: UUID), scopeKeyUnavailable(id: UUID), keyDecayed
}
```
**Rust:** parity pending — the port mirrors this Swift contract (`Grant`, `GrantOptions`, `GrantScope`, `GrantLifetime`, `CustodyMode`, `ReSharePermission`, `DriftRate`, `GrantError`, including the mode-3/4 decay-key machinery) when the sharing/custody surface lands.

#### COW branching: `BranchHandle`, `BranchID`, `DrawerID`, `BranchStatus`, `MergeReport`, `BranchScore`, `DifferentialReport`

The branch surface (SPEC § 2, B-11; parent never modified, I-7). The handle
is a reference type; the kit tracks concrete branches internally.

```swift
public typealias BranchID = UUID
public typealias DrawerID = RowID
public protocol BranchHandle: Sendable, AnyObject {
    var branchID: BranchID { get }; var name: String { get }
    var status: BranchStatus { get }; var lineageDepth: Int { get }
    func capture(_ frame: CaptureFrame) async throws -> Drawer
    func recall(_ frame: RecallFrame) async throws -> [Drawer]
    func discard() async throws
    func compareToParent(over interval: DateInterval) async throws -> DifferentialReport
}
public enum BranchStatus: String, Sendable, Codable, Equatable { case active, won, merged, discarded }
public struct MergeReport: Sendable { public let merged, conflicts, skipped: [DrawerID]; public init(...) }
public struct BranchScore: Sendable { public let quality: Double; public let newDrawerCount: Int; public init(...) }
public struct DifferentialReport: Sendable {
    public let newInBranch, modifiedInBranch, withdrawnInBranch: [DrawerID]
    public let period: DateInterval; public init(...)
}
```
**Rust:** the `branches` module (`branches.rs`). Rust has **no `BranchHandle` trait** — a branch is the concrete `EstateBranch` struct, minted and retained by the coordinator's branch verbs (shown in the `EstateCoordinator` block above); there is no `BranchID`/`DrawerID` alias pair beyond `BranchId = Uuid`.

```rust
pub type BranchId = Uuid;
pub enum BranchStatus { Active, Won, Merged, Discarded }
pub struct BranchScore { pub quality: f64, pub new_drawer_count: usize }
pub struct DifferentialReport {
    pub new_in_branch: Vec<String>, pub modified_in_branch: Vec<String>,   // modified_* always empty until content-hash compare ships
    pub withdrawn_in_branch: Vec<String>,
}
pub struct MergeReport { pub merged: Vec<String>, pub conflicts: Vec<String>, pub skipped: Vec<String> }  // conflicts reserved (empty)
pub enum BranchError { Estate(EstateError), Locus(LocusKitError), EstateNotOpen,
    NotTracked { branch_id: BranchId }, PromotionTargetMismatch { branch_id: BranchId } }
pub struct EstateBranch { pub branch_id: BranchId, pub name: String, pub lineage_depth: usize, /* + private estates, snapshot, status */ }
```

The coordinator also exposes a read accessor resolving a tracked branch by
id (branches are retained through every lifecycle state until the kit is
released, I-15):

```swift
public func branchHandle(for branchID: BranchID) -> (any BranchHandle)?
```
Returns nil when no branch with that id was derived by this kit instance.
Read-only — it neither mints nor mutates branch state; promotion / merge /
discard remain the write surface. Supports stateless callers (notably the
ARIA_MCP recipe surface, where a recipe's `run` and its human-confirmed
promotion arrive as two separate `tools/call` invocations against one
long-lived kit).
**Rust:** (`branches.rs`)

```rust
impl EstateCoordinator {
    pub fn branch_handle_for(&self, branch_id: BranchId) -> Option<&EstateBranch>;  // None if not derived by this coordinator
}
```

#### Unified audit log: `UnifiedAuditLog`, `UnifiedAuditEntry`, `UnifiedHLC`, `UnifiedAuditValue`, `UnifiedAuditVerb`, `AuditTier`, `AuditChainReport`, `AuditChainVerifier`

The per-estate G-Set CRDT and its verifier (SPEC § 2, B-9/B-10; I-11/I-12).
`UnifiedHLC`/`UnifiedAuditLog` are local mirrors of the SubstrateLib shapes
(SPEC § 8).

```swift
public struct UnifiedAuditLog: Sendable, Codable, Equatable {
    public private(set) var entries: [UnifiedAuditEntryKey: UnifiedAuditEntry]
    public init(entries: [UnifiedAuditEntry] = [])
    public var count: Int { get }; public var isEmpty: Bool { get }
    public mutating func add(_ entry: UnifiedAuditEntry)
    public mutating func add<S: Sequence>(contentsOf seq: S) where S.Element == UnifiedAuditEntry
    public mutating func merge(_ other: UnifiedAuditLog)
    public var orderedEntries: [UnifiedAuditEntry] { get }
    public func entries(tier: AuditTier) -> [UnifiedAuditEntry]
    public func entries(forRow rowID: UUID, tier: AuditTier) -> [UnifiedAuditEntry]
    public func entries(since cutoff: UnifiedHLC) -> [UnifiedAuditEntry]
    public func entries(asOf cutoff: UnifiedHLC) -> [UnifiedAuditEntry]
}
public struct UnifiedAuditEntry: Hashable, Sendable, Codable {
    public let id: [UInt8]                 // 32-byte SHA-256 content hash
    public let tier: AuditTier; public let hlc: UnifiedHLC; public let verb: UnifiedAuditVerb
    public let rowID: UUID; public let fieldPath: String
    public let beforeValue, afterValue: UnifiedAuditValue; public let originRowID: UUID?
    public init(tier:hlc:verb:rowID:fieldPath:beforeValue:afterValue:originRowID:)        // computes id
    public init(id:tier:hlc:verb:rowID:fieldPath:beforeValue:afterValue:originRowID:)     // trusts wire id
}
public struct UnifiedHLC: Hashable, Sendable, Codable, Comparable {
    public let physicalTime: Int64; public let logicalCount: Int32; public let nodeID: Int32
    public init(physicalTime:logicalCount:nodeID:); public static let zero: UnifiedHLC
    public var wireBytes: [UInt8] { get }
}
public enum UnifiedAuditValue: Hashable, Sendable, Codable { case null, bitmap(UInt64), integer(Int64), string(String), bytes([UInt8]) }
public enum UnifiedAuditVerb: String, Sendable, Codable, Hashable {
    case capture, recall, mutate, withdraw, expunge, reanchor, learn, propose, associate, migrate, dreamCompact
    case grantIssued, grantRevoked, keyDecayed, physicalKeyDecayed
}
public enum AuditTier: String, Sendable, Codable, Hashable, CaseIterable { case locus, rag }
public struct AuditChainReport: Sendable, Equatable {
    public let valid: Bool; public let entryCount: Int
    public let firstEntryAt, lastEntryAt: Date; public let firstBrokenAt: Date?
    public init(...)
}
public enum AuditChainVerifier { public static func verify(_ log: UnifiedAuditLog) -> AuditChainReport }
```
**Rust:** the `audit` module (`audit/log.rs`, `audit/recovery.rs`, `audit/projection.rs`), re-exported from `lib.rs`. Full definitions live in those files.

```rust
// audit/log.rs — the G-Set CRDT and its entries:
pub struct UnifiedAuditLog;     // add / merge / ordered_entries / entries(tier|row|since|as_of)
pub struct UnifiedAuditEntry;   // 32-byte content-hash id (EntryUUID), tier, verb, row, field, before/after, origin
pub enum   UnifiedAuditValue;   // Null | Bitmap | Integer | String | Bytes
pub enum   UnifiedAuditVerb;    // the verb taxonomy written to the log
pub enum   AuditTier;           // Locus | Rag
// audit/projection.rs + audit/recovery.rs:
pub struct AuditProjectionFold; pub struct UnifiedProjection; pub struct UnifiedProjectionKey;
pub struct UnifiedRowProjection; pub struct AuditRecovery; pub struct AuditRecoveryResult;
pub struct AuditRecoveryDivergence; pub struct RowMismatch;
```

The chain verifier is `AuditRecovery::verify` (`audit/recovery.rs`). Two notes: Rust exposes **no `UnifiedHLC` type** (the Swift HLC has no re-exported Rust counterpart at v0.8), and there are **no coordinator-level audit accessors** (`auditLog(for:)` / `feedAuditLog` / `verifyAuditChain` are Swift-only) — Rust callers use `AuditRecovery::verify` directly.

#### Migration: `ExternalCorpus`, `ExternalEntry`, `MigrationReport`, `MigrationVerification`, `MigrationDivergence`, `MigrationError`, `UnmappedConcept`, `MigrationWarning`, `ParallelCaptureMode`, `ParallelRunHandle`

The external-corpus migration API DTOs and the parallel-run handle (SPEC § 2,
B-14). `ParallelRunHandle` is an actor.

```swift
public struct ExternalEntry: Sendable, Codable, Equatable { public let id, content: String; public let tags: [String]; public init(...) }
public struct ExternalCorpus: Sendable, Codable, Equatable {
    public let name: String; public let entries: [ExternalEntry]; public init(...)
    public static func load(from url: URL) throws -> ExternalCorpus
    public func asRecallFrames() -> [LocusKit.RecallFrame]
}
public struct MigrationReport: Sendable, Codable {
    public let rowsByNoun: [String: Int]; public let unmappedConcepts: [UnmappedConcept]; public let warnings: [MigrationWarning]
    public init(...)
}
public enum MigrationVerification: Sendable { case identical, diverged([MigrationDivergence]) }
public struct MigrationDivergence: Sendable { public let entryID, reason: String; public init(...) }
public struct UnmappedConcept: Sendable, Codable { public let entryID, reason: String; public init(...) }
public struct MigrationWarning: Sendable, Codable { public let message: String; public init(...) }
public enum ParallelCaptureMode: Sendable, Codable { case writeToTarget, readFromSource, mirrorBoth }
public actor ParallelRunHandle {
    public let source, target: EstateHandle; public let mode: ParallelCaptureMode
    public func capture(_ frame: CaptureFrame) async throws -> Drawer    // throws MigrationError.parallelRunStopped after stop()
    public func stop()
}
public enum MigrationError: Error, Sendable, Equatable, CustomStringConvertible {
    case corpusUnreadable(reason: String), parallelRunStopped, targetEstateNotOpen
}
```
**Rust:** parity pending — the port mirrors this Swift contract (`ExternalCorpus`, `ExternalEntry`, `MigrationReport`, `MigrationVerification`, `MigrationDivergence`, `MigrationError`, `UnmappedConcept`, `MigrationWarning`, `ParallelCaptureMode`, `ParallelRunHandle`) when the external-corpus migration surface lands.

#### `GeniusLocusKitError`

The coordinator/lifecycle error surface (SPEC § 6). Carries the federated-
read refusal reason and the branch-promotion guards.

```swift
public enum GeniusLocusKitError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidManifest(key: String, detail: String)
    case estateNotOpen(estateUUID: UUID)
    case duplicateEstate(estateUUID: UUID)
    case underlyingEstateFailure(reason: String)
    case invalidLatticeRegion(low: Int, high: Int)
    case schedulerSignalNotRegistered(SignalID)
    case schedulerNotStarted(estateUUID: UUID)
    case branchNotTracked(branchID: BranchID)
    case invalidPromotionTarget(branchID: BranchID, expectedEstateUUID: UUID, actualEstateUUID: UUID)
    case crossEstateReadRefused(source: UUID, requester: UUID, reason: FederatedReadRefusalReason)
}
```
**Rust:** (`coordinator.rs`) — the Rust enum covers the **lifecycle + fan-out** subset only; it does **not** mirror the full Swift case set. The scheduler, grant, branch, and federation error cases live on their own Rust error types (or are unported), not folded into `GeniusLocusKitError`.

```rust
pub enum GeniusLocusKitError {
    InvalidManifest { key: String, detail: String },
    EstateNotOpen { estate_uuid: EstateUuid },
    DuplicateEstate { estate_uuid: EstateUuid },
    InvalidLatticeRegion { low: i64, high: i64 },
    EstateOpenFailed { detail: String },
}
```

Swift's `schedulerSignalNotRegistered` / `schedulerNotStarted` map to Rust `SchedulerError`; `branchNotTracked` / `invalidPromotionTarget` map to `BranchError::{NotTracked, PromotionTargetMismatch}`; `crossEstateReadRefused` has no Rust case (federation is unported). Meaning: SPEC § 6.

### Tier 2 — broader surface (table of contents)

The following public types are part of the kit's surface, consumed by its
own pipeline and the cross-version conformance harness rather than another
package (measured 2026-05-27). They are public for intra-kit use, or are
Brain-layer machinery a consumer reaches only indirectly through the
`GeniusLocusKit` actor's methods. Recorded as a navigable index — name,
role, source file. Full signatures live in the cited file.

- **Standing-signal scheduler:** `StandingSignalScheduler` (actor, one per
  estate, owns the QueueKit serial lane — SPEC I-4/I-5), `SignalDispatcher`
  (the routing protocol the scheduler calls back through) —
  `Brain/StandingSignalScheduler.swift`. (Consumers drive it through the
  `GeniusLocusKit` signal methods in Tier 1, not directly.)
- **Signal model:** `SignalSpec`, `SignalTrigger`, `ConditionPredicate`,
  `SignalContext`, `SignalEmission`, `SignalReport`, `SignalState`,
  `SignalRouteOutcome`, `ConcurrencyPolicy`, `ResourceCostEstimate`,
  `DiagnosticReport`, `ProposalFrame`, `AssociationFrame`, `SignalID`,
  `SubscriptionID` — `Brain/SignalSchedule.swift`. (`SignalSpec`,
  `SignalEmission`, `SignalReport`, `SignalID`, `SubscriptionID` are
  threaded through the Tier-1 signal methods; the rest are the
  emission/report vocabulary.)
- **Six v1 standing signals (architecture § 11.2):** `DreamingSignal`,
  `MaintenanceSignal`, `VectorSimilaritySignal`, `DecaySweepSignal`,
  `ByReferenceValiditySignal`, `EndOfDayTournamentSignal` — each
  `Brain/Signals/*.swift`; registered together by
  `registerDefaultStandingSignals` (Tier 1). Names: `dreaming-daemon`,
  `maintenance-daemon`, `vector-similarity`, `decay-sweep`,
  `by-reference-validity`, `end-of-day-tournament`.
- **Matrix tier (architecture § 12, GLK-06):** `MatrixTier`,
  `MatrixFieldCell`, `MatrixValueCoord`, `MatrixCoOccurKey`,
  `MatrixTemporalKey` (the F/C/O/T coordinate model), `MatrixCalibrationCurve`/
  `MatrixCalibrationBucket`/`MatrixCalibrationOutcome`/`MatrixCalibrationRegistry`,
  `MatrixNMF`/`MatrixNMFFactorization`, `MatrixSnapshot`/`MatrixPersistenceBackend`/
  `MatrixPersistenceMode`/`MatrixPersistenceError` — `Matrix/*.swift`.
- **Training daemon (architecture § 11, GLK-07):** `TrainingDaemon`,
  `TrainingThresholdGate`, `TrainingThresholdDecision`, `TrainingDaemonTick`,
  `TrainingDaemonReport`, `EnrichmentPipeline`, `EnrichmentPassResult` —
  `Training/*.swift`.
- **Audit projection / recovery:** `AuditProjectionFold`, `UnifiedProjection`
  (+ nested `Key`, the common-word measured hit), `UnifiedRowProjection`,
  `AuditRecovery`, `AuditRecoveryResult`, `AuditRecoveryDivergence`
  (+ nested `RowMismatch`), `UnifiedAuditEntryKey` — `Audit/*.swift`.
- **Grant custody internals:** `GrantStore` (actor, the `grants` table over
  the estate's storage), `StoredGrant`, `ScopeKeyVault` (actor, mode-1 key
  custody and cryptographic clawback) — `Grants/GrantStore.swift`,
  `Grants/ScopeKeyVault.swift`. (The Lagrange-decay key math —
  `DecayFieldElement`, `LagrangeDecayKey`, `DecayShareProvider`,
  `ReferenceDecayShareProvider` — is `internal`, not public, in
  `Grants/LagrangeDecayKey.swift`.)
- **Lexicon conformance:** `AriaLexiconConformance` (the data-only
  verb↔`AriaLexiconLib.Verb` mapping and the § 7.2 acceptance-matrix
  helpers — SPEC I-13) — `Verbs/AriaLexiconConformance.swift`.

## § 3 — Public functions

The principal Tier-1 entry points are the `GeniusLocusKit` actor methods
(§ 2): the lifecycle trio, the nine verbs, `fanOutRecall`/`federatedRecall`,
the grant pair, the audit trio, the four branch methods, the signal API,
and the three migration verbs. Standalone helpers:

```swift
LatticeAnchor.udc(_ code: String) -> LatticeAnchor      // re-exported from LocusKit
ExternalCorpus.load(from: URL) throws -> ExternalCorpus
AuditChainVerifier.verify(_ log: UnifiedAuditLog) -> AuditChainReport
AuditProjectionFold.project(_ log: UnifiedAuditLog) -> UnifiedProjection         // Tier 2
MatrixTier.rebuild(from log: UnifiedAuditLog) -> MatrixTier                       // Tier 2
TrainingThresholdGate.transitionCount(in log: UnifiedAuditLog) -> Int            // Tier 2
GeniusLocusKit.defaultStandingSignalNames -> [String]                            // static
```

## § 4 — Errors

The behavioral meaning of each case is in SPEC § 6. GLK has five error
types: the coordinator surface, the verb surface, and three additive
sub-surfaces (declared standalone because Swift cannot add enum cases by
extension).

```swift
public enum GeniusLocusKitError: Error, Sendable, Equatable, CustomStringConvertible { /* § 2 */ }
public enum VerbError: Error, Sendable, CustomStringConvertible { /* § 2 */ }
public enum GrantError: Error, Sendable, Equatable { /* § 2 */ }
public enum MigrationError: Error, Sendable, Equatable, CustomStringConvertible { /* § 2 */ }
public enum MatrixPersistenceError: Error, Equatable, Sendable    // snapshot load/save (Tier 2)
```
**Rust:** the ported error types are `GeniusLocusKitError` and `VerbError` (+ the dispatch-union `VerbDispatchError`), `BranchError`, `SchedulerError`, and `MatrixPersistenceError`. There is **no `GrantError` or `MigrationError`** — those subsystems are Swift-only at v0.8 (above). So the Rust error surface is *not* a case-for-case mirror of the five Swift error types. Meaning: SPEC § 6.

```rust
pub enum GeniusLocusKitError { /* lifecycle + fan-out, § 2 */ }
pub enum VerbError { /* verb surface, § 2 */ }
pub enum VerbDispatchError { EstateNotOpen { estate_uuid: EstateUuid }, Verb(VerbError) }
pub enum BranchError { /* § 2 COW branching */ }
pub enum SchedulerError { /* standing-signal scheduler */ }
pub enum MatrixPersistenceError { /* snapshot load/save (Tier 2) */ }
```

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/GeniusLocusKit
```

(Target: `GeniusLocusKitTests`.)

**Rust:**

```
cargo test -p genius-locus-kit
```

(Targets include `verb_parity`, `audit_parity`, `scheduler_parity`,
`standing_signals_parity`, `matrix_parity`, `training_parity`,
`composition_conformance_tests`, and `theorems_tests` — the shared `glref`
vectors; SPEC § 8, C-12.)

## § 6 — Examples

```swift
import GeniusLocusKit
import LocusKit
import PersistenceKit

let kit = GeniusLocusKit()
let storage = try await SQLiteStorage(/* … */)          // caller builds the backend
let handle = try await kit.open(storage: storage,
                                owner: OwnerCredentials(ownerIdentifier: "icloud:bob"))

// One verb applied to one estate (SPEC B-2).
let drawer = try await kit.capture(handle, CaptureFrame(
    content: "Carbon chemistry note.", channel: .typed, room: "chemistry",
    latticeAnchor: .udc("547"), addedBy: "bob", embeddingModelID: "text-embedding-3-small"))
let rows = try await kit.recall(handle, RecallFrame(filterChain: [.inRoom("chemistry")]))

// Brain layer: register the six v1 signals and advance the serial lane (SPEC B-5).
let now = Date()
_ = try await kit.registerDefaultStandingSignals(in: handle, now: now)
try await kit.signalTick(in: handle, now: now)          // deterministic, FIFO, single lane (I-5)

// Verify the unified audit chain (SPEC B-10).
let report = try await kit.verifyAuditChain(handle)     // valid == true on a clean chain

// Grant-gated federated read between two locally-open estates (SPEC B-7).
let other = try await kit.open(storage: otherStorage, owner: OwnerCredentials(ownerIdentifier: "icloud:bob"))
_ = try await kit.issueGrant(handle, GrantOptions(granteeEstateID: other.estateUUID, scope: .wing("chemistry")), now: now)
let federated = try await kit.federatedRecall(RecallFrame(filterChain: [.inWing("chemistry")]),
                                              from: handle, requestedBy: other, now: now)  // refuses absent a grant
```

---

*End of GeniusLocusKit Interface v0.8.*
