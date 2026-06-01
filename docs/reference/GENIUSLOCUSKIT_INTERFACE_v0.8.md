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
**Rust:** the surface is split across synchronous types — `EstateCoordinator`
(`open` / `close` / `handles` / `open_estate_count` / `state_for`), the
stateless verb `Surface` (the nine verbs returning `Result<…, VerbError>`),
`LatticeRegion` + `EstateRecallContribution` fan-out, `SerialLaneScheduler`,
and the grant, federation, branch, and migration surfaces (SPEC § 8).

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
**Rust:** `pub struct EstateHandle { estate_uuid, zoom_window_low,
zoom_window_high, estate_name }` with `pub fn new(...)`.

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
**Rust:** `pub struct CaptureFrame`, `RecallFrame`, `LearnFrame`,
`WithdrawFrame`, `MutateFrame`, `ExpungeFrame`, `ReanchorFrame`,
`ProposeFrame`, `AssociateFrame`, `pub enum MutationKind`, `LatticeAnchor`
mirror these in the `verbs` module.

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
**Rust:** `pub enum SchedulerProposalKind` (re-exported under the scheduler
prefix) with the same raw strings.

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
**Rust:** `pub enum VerbError` mirrors these cases (`verbs/surface.rs`).

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
**Rust:** `pub struct LatticeRegion`, `EstateRecallContribution` (`fan_out.rs`).

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
**Rust:** `pub struct FederatedRecallResult`, `pub enum
FederatedReadRefusalReason`, `pub struct IssueGrantResult` mirror these in
the `federation` module.

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
**Rust:** `pub struct Grant`, `GrantOptions`, `pub enum GrantScope`,
`GrantLifetime`, `CustodyMode`, `ReSharePermission`, `DriftRate`,
`GrantError` mirror these in the `grants` module.

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
**Rust:** `pub trait BranchHandle`, `pub enum BranchStatus`, `pub struct
MergeReport`, `BranchScore`, `DifferentialReport` mirror these in the
`branch` module.

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
**Rust:** `EstateCoordinator::branch_handle_for(branch_id: BranchId) ->
Option<&EstateBranch>` (`branches.rs`).

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
**Rust:** `pub struct UnifiedAuditLog`, `UnifiedAuditEntry`, `UnifiedHLC`,
`pub enum UnifiedAuditValue`, `UnifiedAuditVerb`, `AuditTier` mirror these in
the `audit` module; the chain verifier is the audit module's `verify`.

#### Migration: `ExternalCorpus`, `ExternalEntry`, `MigrationReport`, `MigrationVerification`, `MigrationDivergence`, `MigrationError`, `UnmappedConcept`, `MigrationWarning`, `ParallelCaptureMode`, `ParallelRunHandle`

The MemPalace migration API DTOs and the parallel-run handle (SPEC § 2,
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
**Rust:** `pub struct ExternalCorpus`, `ExternalEntry`, `MigrationReport`,
`pub enum MigrationVerification`, `MigrationError`, `pub struct
ParallelRunHandle` mirror these in the `migration` module.

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
**Rust:** `pub enum GeniusLocusKitError` (`coordinator.rs`) mirrors the full
case set across the lifecycle, fan-out, scheduler, grant, branch, and
federation surfaces. Meaning: SPEC § 6.

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
**Rust:** `pub enum GeniusLocusKitError`, `VerbError`, `GrantError`,
`MigrationError`, `MatrixPersistenceError`, and `SchedulerError` mirror the
full error surface. Meaning: SPEC § 6.

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
