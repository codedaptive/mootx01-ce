---
status: proposed
question: "How should ConvergenceKit be designed to replicate PersistenceKit operations across device and perimeter boundaries?"
authors: MOOTx01 maintainers
date: 2026-05-19
relates_to:
  - docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md (§4.3)
  - docs/decisions/DECISION_STORAGEKIT_DESIGN_2026-05-19.md (§9 Q7 audit log)
supersedes: none
context:
  - ConvergenceKit replicates PersistenceKit operations across device or perimeter boundaries.
  - Backends at v1.0 are CloudKit (ported from an existing CloudSync precedent), Federation (substrate-native CRDT exchange), and None.
---

# Decision: ConvergenceKit Design

## 1. Summary

ConvergenceKit replicates PersistenceKit operations across device or perimeter boundaries. Its only consumer protocol is PersistenceKit's. Kits using PersistenceKit get sync for free by enabling ConvergenceKit on their PersistenceKit instance; they do not call ConvergenceKit directly.

Backends at v1.0: CloudKit (ported from Fulcrum's existing CloudSync target), Federation (substrate-native CRDT exchange), None (single-device passthrough).

The wire unit is a PersistenceKit row mutation tagged with HLC. The receiver applies the mutation through its local PersistenceKit; PersistenceKit's existing constraints (primary keys, idempotence on the audit log's (eventID, hlc) compound key) produce convergence.

## 2. Scope

ConvergenceKit owns: zone configuration, change observation (via PersistenceKit's StorageObserver), record-mapping per table, transport (CloudKit push/pull or Federation handshake), conflict resolution policy declaration, peer identity for federation.

ConvergenceKit does not own: storage (PersistenceKit's), CRDT mathematics (SubstrateLib's `GSetAuditLog` + GeniusLocusKit's enforcement), encryption at rest (backend-specific), authentication of remote peers beyond what CloudKit or pairing handshake provide.

## 3. Q1: Consumer model

**Decision: ConvergenceKit consumes PersistenceKit; downstream kits do not consume ConvergenceKit directly.**

A kit declares which of its tables sync, which zone they belong to, and how conflicts resolve. ConvergenceKit observes PersistenceKit, ships changes, applies incoming changes through the receiver's PersistenceKit, and fires StorageObserver notifications on the receiver side. Downstream kits like QueueKit, GeniusLocusKit, and Fulcrum see sync as table-level replication, not as their own integration.

```swift
public struct SyncManifest: Sendable {
    public let tables: [SyncedTable]
    public let zoneIdentifier: String
    public let conflictPolicy: ConflictPolicy
    
    public init(tables: [SyncedTable], zoneIdentifier: String, conflictPolicy: ConflictPolicy) { ... }
}

public struct SyncedTable: Sendable {
    public let name: String           // matches PersistenceKit table name
    public let direction: SyncDirection  // .bidirectional, .pushOnly, .pullOnly
    public let primaryKeyColumn: String  // for conflict matching
}

public enum SyncDirection: Sendable {
    case bidirectional
    case pushOnly  // local writes ship out; remote changes ignored
    case pullOnly  // remote writes accepted; local changes don't ship
}

public enum ConflictPolicy: Sendable {
    case lastWriterWinsByHLC      // default; uses HLC from TableChange
    case appendOnly                // (eventID, hlc) compound key; sender wins idempotently (audit log)
    case localWins                 // receiver discards remote on conflict
    case remoteWins                // receiver overwrites local on conflict
}
```

Reason: the kit graph stays clean. ConvergenceKit is a foundation peer of PersistenceKit; consumers compose them, they don't choose between them.

Cost: kits that want fine-grained sync control (sync this row but not that one) need to declare it through the manifest, not through procedural API. v1.0 syncs whole tables; row-level filtering is a v1.x improvement via a `predicate` field on `SyncedTable`.

## 4. Q2: Wire format

**Decision: TypedValue dictionary plus HLC tag plus event type. Schema version mismatch rejects.**

```swift
public struct SyncRecord: Sendable, Codable {
    public let table: String
    public let event: StorageEvent       // insert, update, delete
    public let rowKey: UUID
    public let values: [String: TypedValue]?  // post-image; nil on delete
    public let hlc: HLC
    public let schemaVersion: Int
    public let kitID: String              // for cross-kit safety
}
```

The wire format is `SyncRecord`. Senders construct from `TableChange` notifications. Receivers decode and apply via PersistenceKit. Schema version and kitID must match the receiver's declaration; mismatches throw `SyncError.schemaMismatch` and the record is queued for retry (e.g. after an app update).

Reason: simplest possible wire. Both sides run the same kit graph at the same schema version; sync is replication, not adaptation. The schema-version check is the migration safety net.

Cost: rolling app updates require all devices to update before sync resumes. Documented; the alternative (cross-version adaptation logic) breaks the closed-enum design.

TypedValue is `Codable`-conformant for this. Worth verifying during build; if not, a Codable wrapper around TypedValue is added.

## 5. Q3: Watch/subscribe primitive

**Decision: ConvergenceKit exposes a subscribe-and-wake primitive that maps to backend-specific transport. Filesystem-style watch is in StorageObserver, not ConvergenceKit.**

```swift
public protocol SyncEngine: Sendable {
    func enable(estate: EstateHandle, manifest: SyncManifest, storage: any Storage) async throws
    func disable() async throws
    
    /// One-shot push of all pending local changes.
    func push() async throws -> SyncReceipt
    
    /// One-shot pull of all pending remote changes.
    func pull() async throws -> SyncReceipt
    
    /// Long-running subscription. The stream fires SyncEvent values when
    /// remote changes arrive (after they've been applied through PersistenceKit,
    /// so downstream observers also wake). Closing the stream stops the
    /// subscription.
    func subscribe() -> AsyncStream<SyncEvent>
    
    /// Current state for diagnostics.
    var state: SyncState { get async }
}

public enum SyncEvent: Sendable {
    case remoteChangesApplied(count: Int)
    case pushCompleted(receipt: SyncReceipt)
    case peerConnected(identity: String)
    case peerDisconnected(identity: String, reason: String)
    case error(SyncError)
}

public struct SyncReceipt: Sendable {
    public let pushed: Int
    public let pulled: Int
    public let conflicts: Int
    public let timestamp: Date
}
```

Reason: QueueKit's iPhone-submits-Mac-watches scenario rides on this. iPhone calls `storage.rowStore.insert(table: "jobs", ...)`. ConvergenceKit-CloudKit's subscription notices the row via StorageObserver, pushes via CKModifyRecordsOperation. The Mac's ConvergenceKit-CloudKit subscription receives the push via CKDatabaseSubscription, applies through its PersistenceKit, fires StorageObserver on its side, wakes QueueKit's `watch()`. All four methods of QueueKit work identically locally and across devices.

Cost: subscription requires a long-running task per estate. Document the resource use; iOS apps should pause subscription when backgrounded if not using Background Processing entitlements.

## 6. Q4: Backend lineup

**Decision: CloudKit (port Fulcrum's existing target), Federation, None.**

**ConvergenceKit-CloudKit.** The Apple ecosystem sync stack. Built by porting Fulcrum's existing `Sources/CloudSync/` target into a kit-shaped package. The port preserves Fulcrum's working patterns: `CKContainer` wrapping, `CKDatabaseSubscription` for push notifications, per-entity push and pull engines, per-table `CKRecord` mappers (generated from the SyncManifest), per-zone state tracking. Does not migrate to CKSyncEngine at v1.0; defer that to a v2 evaluation.

Per-estate zone strategy: one CloudKit zone per declared `zoneIdentifier`. Multiple estates on the same device sync to multiple zones independently. Receiving devices subscribe to each zone separately. The zone identifier convention is the caller's responsibility (typical: `GeniusLocus-{estateUUID}`, `Fulcrum-FNode`, `Queue-{factoryID}`).

**ConvergenceKit-Federation.** Substrate-native CRDT exchange. Implements audit-event-exchange (G-Set union), hyperplane family handshake, tier-ascending query protocol, differential privacy at tier aggregation points. This is what makes household federation (case study 1), fleet federation (case study 2), and MSP federation (case study 3) work cross-perimeter.

CloudKit and Federation are not competitors. CloudKit syncs my devices to my other devices. Federation syncs my estate to your estate. Both can run simultaneously on one PersistenceKit instance; the manifest's zone identifier picks which backend a given table flows through.

**ConvergenceKit-None.** No-sync passthrough for single-device deployments, development, and tests. `subscribe()` returns an empty stream; `push()` and `pull()` are no-ops returning empty receipts.

## 7. Q5: Conflict resolution

**Decision: ConflictPolicy declared per SyncedTable; ConvergenceKit applies it at the apply boundary.**

Four policies (defined in §3 above). The audit log uses `.appendOnly` because the (eventID, hlc) compound key in PersistenceKit makes duplicate appends idempotent. The CRDT property is enforced at the storage layer, not the sync layer. Substrate-domain tables (drawers, tunnels, KG facts) use `.lastWriterWinsByHLC` since they project from the audit log and lost writes are recoverable.

Fulcrum's FNode sync currently uses a stored-server-record-based resolver; that translates to `.lastWriterWinsByHLC` plus a per-entity sync_record_name column that ConvergenceKit-CloudKit preserves. The existing Fulcrum behavior is preserved bit-for-bit.

Queue jobs use `.lastWriterWinsByHLC` for state transitions (claimed, completed) since two devices claiming the same job is a real race that needs resolution. The maildir three-directory discipline that QueueKit uses in its filesystem backend gives different conflict properties; QueueKit's PersistenceKit-backed and ConvergenceKit-backed tiers use this policy.

## 8. Q6: Peer identity (Federation only)

**Decision: Per-estate ephemeral identity, established via a pairing handshake.**

Each estate generates an Ed25519 keypair on first launch. Pairing with another estate's owner happens through an out-of-band channel (QR code, NFC tap, AirDrop, or shared link with token) carrying the public key and the proposed hyperplane family parameters. Once paired, federated audit-event exchange is signed by the sender and verified by the receiver.

> **Superseded — signature algorithm (see ADR-013, 2026-06-17).** The signature
> algorithm is **ECDSA P-256**, not Ed25519: Ed25519 is outside the approved
> boundary of the FIPS-validated Apple CoreCrypto module EE must ship (SC-13).
> The per-estate identity, out-of-band pairing, and signed-exchange design here
> are otherwise unchanged.

Identity is per-estate, not per-device or per-user. Multiple estates on one device have distinct identities; the same user's two estates do not implicitly trust each other across the federation channel.

Out-of-band channel choice for v1.0: QR code displayed on one device, scanned by the other, encoding the public key + hyperplane parameters. AirDrop pairing is a v1.x improvement.

## 9. Q7: Sync state and diagnostics

**Decision: SyncState enum exposes coarse state for UI; detailed metrics emitted via Logger.**

```swift
public enum SyncState: Sendable {
    case disabled
    case enabled(zone: String, lastPushAt: Date?, lastPullAt: Date?)
    case syncing(direction: SyncDirection)
    case error(SyncError, retryAt: Date?)
}
```

UI bindings (Fulcrum's sync status indicator, agent dashboards) read SyncState. Detailed telemetry (per-table change counts, conflict resolutions, retry counts, network latency) emit via `Logging.Logger` for operators.

Reason: Fulcrum's existing CloudSync target already does this with `SyncCoordinator` and a `state` AsyncStream. Preserving the pattern minimizes refactor surface.

## 10. Q8: Conformance fixtures

**Decision: ConvergenceKit ships its own conformance fixture suite, sibling to PersistenceKit's.**

Fixtures cover:

- Manifest declaration and acceptance (10)
- One-shot push with N changes; receiver state matches sender (15)
- One-shot pull with N changes (15)
- Bidirectional convergence: two estates with overlapping writes converge after exchange (15)
- Subscription delivers remote changes via the stream (10)
- Conflict resolution: lastWriterWinsByHLC, appendOnly, localWins, remoteWins (20)
- Schema mismatch rejection (5)
- Push direction respected (pushOnly skips remote changes) (5)
- Pull direction respected (pullOnly skips local changes) (5)
- Disable mid-sync cleans up subscriptions and pending state (5)

Backends running fixtures: ConvergenceKit-None (always), ConvergenceKit-CloudKit (gated on `CLOUDKIT_TEST_CONTAINER`), ConvergenceKit-Federation (always, since it doesn't need external service).

The fixtures use InMemory PersistenceKit underneath so they don't pollute disk during runs.

## 11. Construction shape

With these eight decisions settled, ConvergenceKit construction is:

1. Core protocols + types (SyncEngine, SyncManifest, SyncedTable, SyncDirection, ConflictPolicy, SyncRecord, SyncReceipt, SyncEvent, SyncState, SyncError)
2. ConvergenceKit-None implementation (validates protocol surface, used in tests)
3. ConformanceRunner + initial fixtures
4. ConvergenceKit-CloudKit (port Fulcrum's CloudSync target; preserve patterns)
5. ConvergenceKit-Federation (substrate-native CRDT exchange; pairing handshake; tier-ascending query)
6. Verify TypedValue Codable; add wrapper if necessary
7. README + INTERFACE_DOCTRINE

Direct build, same pattern as PersistenceKit. Estimated wall-clock: comparable to PersistenceKit. The CloudKit port is the largest single piece; substantial Fulcrum code mining and adapting required.

## 12. Open items not pre-decided

These surface during construction and get decision records as they resolve:

- TypedValue Codable conformance (test during build; add wrapper if needed)
- CloudKit zone subscription strategy (one CKDatabaseSubscription per zone vs query-based)
- Federation transport (HTTPS-over-relay vs direct peer-to-peer vs IPFS-style routing); the federation protocol is specified but not the wire transport
- Battery and bandwidth budgeting (especially iPhone; document Background Processing entitlement guidance)
- Retry / backoff policy for failed pushes
- Handling of large blobs (PersistenceKit blob store entries) over sync; v1.0 may chunk or skip; documented as v1.x

## 13. Recommendation

Build ConvergenceKit directly, following the same pattern as SubstrateLib and PersistenceKit.

Estimated wall-clock: longer than PersistenceKit. The CloudKit port involves mining Fulcrum's working code and adapting the type-mapping layer from per-Fulcrum-entity to per-table-from-manifest.
