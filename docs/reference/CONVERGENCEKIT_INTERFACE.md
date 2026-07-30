---
status: active
authors: MOOTx01 maintainers
date: 2026-07-17
version: 1.8
description: Public API surface for ConvergenceKit in both the Swift and Rust ports.
package: ConvergenceKit
languages: [swift, rust]
relates_to:
  - CONVERGENCEKIT_SPEC.md  (the contract this interface implements)
purpose: |
  Public API surface of ConvergenceKit in both ports: the SyncEngine
  protocol, the SyncManifest declaration model, the SyncRecord wire
  format and TypedValue boxing, the SyncReceipt / SyncEvent / SyncState
  value types, the SyncError enum, and the three backends (None,
  CloudKit, Federation). The companion SPEC carries the behavioral
  contracts (invariants I-1…I-12, conformance C-1…C-15).
---

# ConvergenceKit Interface

## § 1 — Package layout

**Swift:** `packages/kits/ConvergenceKit/`

- `Sources/ConvergenceKit/` — core: protocol + types + wire format
  - `SyncEngine.swift` — the `SyncEngine` protocol (SPEC § 4, I-1…I-3)
  - `SyncTypes.swift` — `SyncManifest`, `SyncedTable`, `SyncDirection`,
    `ConflictPolicy`, `SyncReceipt`, `SyncEvent`, `SyncState`, `SyncError`
  - `SyncRecord.swift` — `SyncRecord`, `SyncEventKind`, `PackedHLC`,
    `SyncValueMap`, `SyncValueBox`, `FingerprintWire`
  - `FieldLWW/ColumnHLCMap.swift` — `ColumnHLCMap`, `PackedHLC.Comparable`
  - `FieldLWW/FieldLWWMerge.swift` — `FieldLWWMerge` (pure stateless merge)
  - `FieldLWW/ColumnHLCStore.swift` — `ColumnHLCStore` (side-table CRUD)
- `Sources/ConvergenceKitNone/` — `NoSyncEngine` (default, SPEC § 5 B-1)
- `Sources/ConvergenceKitCloudKit/` — `CloudKitSyncEngine`,
  `CKRecordMapping`, `DecodedRecord`
- `Sources/ConvergenceKitFederation/` — `FederationSyncEngine`,
  `Relay` (transport protocol), `FederationRelay` (in-process `Relay`),
  `SignedEnvelope`, `PayloadKind`, `envelopeSigningBytes(...)`,
  `LocalIdentity`, `PeerIdentity`, `FederationSignature`,
  `HyperplaneFamilySpec`, `PairingProposal`, `PairingAcceptance`
- `Tests/ConvergenceKitConformance/` — shared fixtures; per-backend test
  targets; `Package.swift`

Four library products: `ConvergenceKit`, `ConvergenceKitNone`,
`ConvergenceKitCloudKit`, `ConvergenceKitFederation`.

**Rust:** `packages/kits/ConvergenceKit/rust/` (crate `convergence-kit`)

- `src/types.rs` — `SyncDirection`, `ConflictPolicy`, `SyncedTable`,
  `SyncManifest`, `SyncReceipt`, `SyncEvent`, `SyncState`, `SyncError`,
  `SyncResult`
- `src/record.rs` — `SyncRecord`, `SyncEventKind`, `PackedHLC`,
  `FingerprintWire`, `SyncValueBox`, `SyncValueMap`, `ColumnHLCMap`
- `src/engine.rs` — the `SyncEngine` trait
- `src/none.rs` — `NoSyncEngine`
- `src/federation.rs` — `FederationSyncEngine`, `Relay` (transport
  trait), `FederationRelay` (in-process `impl Relay`), `SignedEnvelope`,
  `PayloadKind`, `envelope_signing_bytes`, `LocalIdentity`,
  `PeerIdentity`, `verify_signature`, `PairedPeer`
- `src/pairing.rs` — `HyperplaneFamilySpec`, `PairingProposal`,
  `PairingAcceptance`, `proposal_signing_bytes`

CloudKit is Apple-only and is intentionally omitted from the Rust version.

## § 2 — Public types

### `SyncEngine`

The lifecycle protocol every backend conforms to (SPEC § 4, § 5).

**Swift:**

```swift
public protocol SyncEngine: Sendable {
    func enable(manifest: SyncManifest, storage: any Storage) async throws
    func disable() async throws
    func push() async throws -> SyncReceipt
    func pull() async throws -> SyncReceipt
    func subscribe() -> AsyncStream<SyncEvent>
    var state: SyncState { get async }
}
```

**Rust:** (synchronous, like PersistenceKit's port; `subscribe` returns
an mpsc `Receiver` rather than an `AsyncStream`). The bound is `Send`,
not `Send + Sync`: the engine owns `!Sync` mpsc ends and is driven through
exclusive `&mut self`, so the mutating verbs take `&mut self` (only the
read-only `state` is `&self`).

```rust
pub trait SyncEngine: Send {
    fn enable(&mut self, manifest: SyncManifest, storage: Arc<dyn Storage>) -> SyncResult<()>;
    fn disable(&mut self) -> SyncResult<()>;
    fn push(&mut self) -> SyncResult<SyncReceipt>;
    fn pull(&mut self) -> SyncResult<SyncReceipt>;
    fn subscribe(&mut self) -> std::sync::mpsc::Receiver<SyncEvent>;
    fn state(&self) -> SyncState;
}
```

### `SyncManifest`, `SyncedTable`, `SyncDirection`, `ConflictPolicy`

The declarative configuration of a sync session (SPEC § 4, I-4, I-5).

**Swift:**

```swift
public enum SyncDirection: String, Sendable, Codable {
    case bidirectional, pushOnly, pullOnly
}

public enum ConflictPolicy: String, Sendable, Codable {
    // default; incoming HLC vs durable local side metadata. Stale inbound
    // (incoming HLC < stored HLC) is silently dropped for both upserts and deletes.
    // Every winning apply writes the side metadata so the next comparison has durable
    // state. Delete path: stale delete leaves the row intact; newer delete
    // hard-deletes it. Both CloudKit and Federation implement identical semantics.
    case lastWriterWinsByHLC
    case appendOnly            // (eventID, hlc) idempotent; audit log; remote deletes rejected
    case localWins             // receiver discards remote on conflict; remote deletes rejected
    case remoteWins            // receiver overwrites local on conflict unconditionally
    // Per-column HLC LWW. Wire carries ColumnHLCMap on SyncRecord (B-8).
    // Array/blob columns are atomic whole values — concurrent writes to the
    // same column lose the lower-HLC side. Rust twin: FieldLevelLWW (C-8).
    // Side tables: _ck_sync_meta_cols (CloudKit), _fed_sync_meta_cols (Federation).
    case fieldLevelLWW
}

public struct SyncedTable: Sendable, Codable {
    public let name: String
    public let direction: SyncDirection
    public let primaryKeyColumn: String
    public let conflictPolicy: ConflictPolicy
    /// Columns excluded from sync; locally recomputed on every device.
    /// Matches Playground Rule 4: derived columns never sync.
    public let excludedColumns: Set<String>
    public init(name: String, direction: SyncDirection = .bidirectional,
                primaryKeyColumn: String, conflictPolicy: ConflictPolicy = .lastWriterWinsByHLC,
                excludedColumns: Set<String> = [])
}

public struct SyncManifest: Sendable {
    public let kitID: String
    public let schemaVersion: Int
    public let zoneIdentifier: String
    public let tables: [SyncedTable]
    /// Columns to route through `CKRecord.encryptedValues` (CloudKit backend only).
    /// Key: table name. Value: set of column names to encrypt. Default `[:]` →
    /// byte-identical to pre-encryption behavior. Not wire-carried (local CloudKit
    /// encoding directive only). `moot_sync_*` columns and `_ck_*` tables are rejected
    /// by `validateEncryptedColumns()`. Registry records always stay plaintext.
    public let encryptedContentColumns: [String: Set<String>]
    /// Optional hook run after each inbound pull batch applies;
    /// use to restore cross-row or cross-table structural invariants that
    /// sync cannot maintain (Playground Rule 3). Not `Codable` — closures
    /// cannot be serialized; set at construction only.
    public var postApplyIntegrityHook: (@Sendable (AppliedBatch) async throws -> Void)?
    public init(kitID: String, schemaVersion: Int, zoneIdentifier: String, tables: [SyncedTable],
                encryptedContentColumns: [String: Set<String>] = [:],
                postApplyIntegrityHook: (@Sendable (AppliedBatch) async throws -> Void)? = nil)
    public func table(named name: String) -> SyncedTable?
    /// Validate `encryptedContentColumns`: rejects the entire `moot_sync_`
    /// namespace and `_ck_*` tables.
    public func validateEncryptedColumns() throws
}
```

**Rust:**

```rust
pub enum SyncDirection { Bidirectional, PushOnly, PullOnly }
pub enum ConflictPolicy {
    LastWriterWinsByHLC, AppendOnly, LocalWins, RemoteWins,
    FieldLevelLWW,  // per-column HLC LWW; see B-8
}

pub struct SyncedTable {
    pub name: String,
    pub direction: SyncDirection,           // serde default: Bidirectional
    pub primary_key_column: String,
    pub conflict_policy: ConflictPolicy,     // serde default: LastWriterWinsByHLC
    pub excluded_columns: HashSet<String>,   // serde default: empty
}
impl SyncedTable {
    pub fn new(name: impl Into<String>, primary_key_column: impl Into<String>) -> Self;
    pub fn with_direction(self, direction: SyncDirection) -> Self;
    pub fn with_conflict_policy(self, policy: ConflictPolicy) -> Self;
    pub fn with_excluded_columns(self, cols: impl IntoIterator<Item = impl Into<String>>) -> Self;
}

pub struct SyncManifest {
    pub kit_id: String,
    pub schema_version: i32,
    pub zone_identifier: String,
    pub tables: Vec<SyncedTable>,
    // post-apply hook: Rust equivalent would be a boxed fn; not serializable.
    // Deferred — Swift ships postApplyIntegrityHook; Rust port does not carry it.
    // pub post_apply_hook: Option<Box<dyn Fn(&dyn Storage) -> Result<(), SyncError> + Send>>,
}
impl SyncManifest {
    pub fn new(kit_id: impl Into<String>, schema_version: i32,
               zone_identifier: impl Into<String>, tables: Vec<SyncedTable>) -> Self;
    pub fn table_named(&self, name: &str) -> Option<&SyncedTable>;
}
```

**Note — `TableChange.origin`:** ConvergenceKit's echo suppression (SPEC
I-10) depends on an `origin: ChangeOrigin` field on PersistenceKit's
`TableChange` type. `ChangeOrigin` is either `local` (all caller-initiated
writes) or `syncApply` (writes issued by `applyInbound`). Shipped in
P1-M1 (CVK-ICLOUD P1-M1, 2026-07-16); see `PERSISTENCEKIT_INTERFACE.md`
for the full `ChangeOrigin` signature.

### `SyncReceipt`, `SyncEvent`, `SyncState`

Cycle result, event stream payload, and coarse UI state (SPEC § 5,
B-2, B-3).

**Swift:**

```swift
public struct SyncReceipt: Sendable {
    public let pushed: Int
    public let pulled: Int
    public let conflicts: Int
    public let timestamp: Date
    public init(pushed: Int, pulled: Int, conflicts: Int, timestamp: Date = Date())
    public static let empty: SyncReceipt
}

public enum SyncEvent: Sendable {
    case remoteChangesApplied(count: Int)
    case pushCompleted(receipt: SyncReceipt)
    case peerConnected(identity: String)
    case peerDisconnected(identity: String, reason: String)
    case error(SyncError)
    /// Emitted when ≥1 record was held in the schema-skew queue during a
    /// pull cycle (future-schema records), or when the queue is non-empty
    /// after enable-time replay (records waiting for a further schema bump).
    /// count: total entries held/remaining across all schema versions.
    /// SPEC: B-3, B-10. Rust twin: SyncEvent::RecordsHeldForMigration.
    /// CVK-ICLOUD P3-M4.
    case recordsHeldForMigration(count: Int)
    /// A CloudKit silent-push notification arrived for this engine's zone
    /// and the engine responded by nudging the poll scheduler. Emitted
    /// before the pull that follows nudge(). CloudKit-only: never emitted
    /// by NoSyncEngine or FederationSyncEngine.
    case remoteWakeReceived
}

public enum SyncState: Sendable {
    case disabled
    case enabled(zone: String, lastPushAt: Date?, lastPullAt: Date?)
    case syncing(direction: SyncDirection)
    case error(SyncError, retryAt: Date?)
}
```

**Rust:** (timestamps are Unix epoch seconds, not `Date`)

```rust
pub struct SyncReceipt { pub pushed: usize, pub pulled: usize,
                         pub conflicts: usize, pub timestamp_secs: i64 }
impl SyncReceipt {
    pub const fn empty() -> Self;
    pub fn now(pushed: usize, pulled: usize, conflicts: usize) -> Self;
}

pub enum SyncEvent {
    RemoteChangesApplied { count: usize },
    PushCompleted { receipt: SyncReceipt },
    PeerConnected { identity: String },
    PeerDisconnected { identity: String, reason: String },
    Error(SyncError),
    /// Records held in the schema-skew queue (R9, CVK-ICLOUD P3-M4).
    /// Swift twin: SyncEvent.recordsHeldForMigration(count:). SPEC B-3, B-10.
    RecordsHeldForMigration { count: usize },
    /// Vocabulary-parity arm for CloudKit remote-wake. Never constructed
    /// on the Rust side (CloudKit is Swift-only per § 7 Exempt).
    RemoteWakeReceived,
}

pub enum SyncState {
    Disabled,
    Enabled { zone: String, last_push_secs: Option<i64>, last_pull_secs: Option<i64> },
    Syncing { direction: SyncDirection },
    Errored { error: SyncError, retry_at_secs: Option<i64> },
}
```

### `SyncRecord` and the `TypedValue` boxing

The wire unit and its discriminated value encoding (SPEC § 5, B-5).

**Swift:**

```swift
public enum SyncEventKind: String, Sendable, Codable {
    case insert, update, delete
    public init(from event: StorageEvent)
    public var asStorageEvent: StorageEvent { get }
}

public struct PackedHLC: Sendable, Codable, Hashable {
    public let physicalTime: Int64
    public let logicalCount: Int32
    public let nodeID: Int32
    public init(_ hlc: HLC)
    public var asHLC: HLC { get }
}

public struct FingerprintWire: Sendable, Codable, Hashable {
    public let block0, block1, block2, block3: UInt64
    public init(_ fp: Fingerprint256)
    public var asFingerprint: Fingerprint256 { get }
}

public struct SyncValueBox: Sendable, Codable {
    public let kind: String
    public let payload: Payload
    public enum Payload: Sendable, Codable {
        case null, bool(Bool), int(Int64), bitmap(Int64), float(Double)
        case text(String), bytes(Data), uuid(UUID), timestamp(Date)
        case hlc(PackedHLC), fingerprint(FingerprintWire), array([SyncValueBox])
    }
    public init(_ v: TypedValue)
    public var asTypedValue: TypedValue { get }
}

public struct SyncValueMap: Sendable, Codable {
    public let entries: [String: SyncValueBox]
    public init(_ raw: [String: TypedValue])
    public var asTypedValues: [String: TypedValue] { get }
}

/// Per-column HLC map for fieldLevelLWW conflict policy (B-8).
/// Wire shape: {"entries": {"colName": PackedHLC, ...}}
/// Matches Rust ColumnHLCMap { entries: BTreeMap<String, PackedHLC> }.
public struct ColumnHLCMap: Sendable, Codable, Equatable {
    public var entries: [String: PackedHLC]
    public init(entries: [String: PackedHLC] = [:])
    /// Merge keeping highest HLC per column. Commutative.
    public func merge(with other: ColumnHLCMap) -> ColumnHLCMap
    /// Stamp all given keys with hlc. Used at outbox observe time.
    public static func stampAll(keys: some Sequence<String>, hlc: PackedHLC) -> ColumnHLCMap
    public var isEmpty: Bool { get }
}

/// Comparable conformance for PackedHLC: (physicalTime, logicalCount, nodeID) lexicographic.
/// Parity: Rust PackedHLC derives PartialOrd on the same field order.
extension PackedHLC: Comparable { /* < operator */ }

public struct SyncRecord: Sendable, Codable {
    public let table: String
    public let event: SyncEventKind
    public let rowKey: UUID
    public let values: SyncValueMap?
    public let hlc: PackedHLC
    public let schemaVersion: Int
    public let kitID: String
    /// Per-column HLC map for fieldLevelLWW tables (B-8). Nil for row-grain
    /// LWW tables — omitted from JSON encoding (encodeIfPresent).
    public let columnHLCs: ColumnHLCMap?
    public init(table: String, event: SyncEventKind, rowKey: UUID,
                values: SyncValueMap?, hlc: PackedHLC, schemaVersion: Int, kitID: String,
                syncDeleted: Bool? = nil, columnHLCs: ColumnHLCMap? = nil)
}
```

**Rust:** (`SyncValueBox` is an internally-tagged enum; timestamps are
epoch seconds)

```rust
pub enum SyncEventKind { Insert, Update, Delete }  // From<StorageEvent>, Into<StorageEvent>

pub struct PackedHLC { pub physical_time: i64, pub logical_count: i32, pub node_id: i32 }
// From<HLC> / Into<HLC>

pub struct FingerprintWire { pub block0: u64, pub block1: u64, pub block2: u64, pub block3: u64 }
// From<Fingerprint256> / Into<Fingerprint256>

#[serde(tag = "kind", content = "payload", rename_all = "lowercase")]
pub enum SyncValueBox {
    Null, Bool(bool), Int(i64), Bitmap(i64), Float(f64), Text(String),
    Blob(Vec<u8>), Uuid(Uuid), Timestamp(i64), Json(Vec<u8>),
    Hlc(PackedHLC), Fingerprint(FingerprintWire), Array(Vec<SyncValueBox>),
}  // From<TypedValue> / Into<TypedValue>

pub struct SyncValueMap { pub entries: BTreeMap<String, SyncValueBox> }
impl SyncValueMap {
    pub fn from_typed(raw: BTreeMap<String, TypedValue>) -> Self;
    pub fn into_typed(self) -> BTreeMap<String, TypedValue>;
}

/// Per-column HLC map for fieldLevelLWW conflict policy (B-8).
/// Wire shape: {"entries": {"colName": PackedHLC, ...}} (BTreeMap = alphabetical key order).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ColumnHLCMap {
    pub entries: BTreeMap<String, PackedHLC>,
}
impl ColumnHLCMap {
    pub fn new() -> Self;
    pub fn is_empty(&self) -> bool;
    /// Merge keeping highest HLC per column. Commutative.
    pub fn merge(&self, other: &ColumnHLCMap) -> ColumnHLCMap;
}

pub struct SyncRecord {
    pub table: String, pub event: SyncEventKind, pub row_key: Uuid,
    pub values: Option<SyncValueMap>, pub hlc: PackedHLC,
    pub schema_version: i32, pub kit_id: String,
    /// Per-column HLC map for fieldLevelLWW tables (B-8). None for row-grain
    /// LWW tables. serde: skip_serializing_if = "Option::is_none", default.
    pub column_hlcs: Option<ColumnHLCMap>,
}
impl SyncRecord {
    pub fn new(table: impl Into<String>, event: SyncEventKind, row_key: Uuid,
               values: Option<SyncValueMap>, hlc: HLC, schema_version: i32,
               kit_id: impl Into<String>) -> Self;
}
```

### Backend types

The three backends and their backend-specific public surface.

**None — `NoSyncEngine`** (SPEC § 5, B-1):

```swift
public final class NoSyncEngine: SyncEngine, Sendable {
    public init()
}
```
```rust
pub struct NoSyncEngine { /* … */ }
impl NoSyncEngine { pub fn new() -> Self; }   // also Default
```

**CloudKit — `CloudKitSyncEngine`** (Apple-platform; SPEC § 5, B-6):

```swift
public final class CloudKitSyncEngine: SyncEngine, Sendable {
    /// Pass nil to resolve CKContainer.default() at enable() time.
    /// enablePolling: false (default) — polling does not auto-start; the
    /// host app or test drives push/pull manually. Pass true to start
    /// AdaptivePollScheduler on enable() (intended for production use only).
    public init(containerIdentifier: String? = nil, enablePolling: Bool = false)

    // Host-app accelerator surface (shipped CVK-ICLOUD P3-M2/P3-M3).
    // Correctness does NOT depend on nudge delivery; the engine is always
    // sound under polling alone (SPEC B-11). These entry points are for
    // host apps that hold APNs entitlements and want to reduce inbound
    // latency.

    /// Nudge the engine to run a pull cycle immediately, bypassing the
    /// current idle-cadence timer. If a scheduler is running, delegates
    /// to it (interrupt sleep + pull). If no scheduler is running
    /// (enablePolling: false), fires a one-shot pull directly.
    public func nudge() async

    /// Register a `CKRecordZoneSubscription` for the engine's sync zone.
    ///
    /// Idempotent: the subscription ID is derived from the zone name
    /// ("ck-zone-wake-<zoneIdentifier>") so CloudKit deduplicates on
    /// repeated saves. Safe to call on every app launch without tracking
    /// whether the subscription was already registered.
    ///
    /// Routes through the `CloudKitDatabaseProtocol` seam (no `CKDatabase`
    /// argument needed; the seam resolves the correct database internally).
    ///
    /// Host-app responsibilities before calling:
    /// 1. Declare the `com.apple.developer.icloud-services` → CloudKit entitlement.
    /// 2. Call `UIApplication.registerForRemoteNotifications()` (or AppKit equivalent).
    /// 3. Forward notification payloads via `handleRemoteNotification(userInfo:)`.
    public func registerZoneSubscription() async throws

    /// Remove the zone subscription for this engine's zone.
    /// Safe to call even if no subscription is currently registered.
    public func deregisterZoneSubscription() async throws

    /// Process a remote-notification `userInfo` dict from the host app's
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    ///
    /// Returns `true` if the notification was a CloudKit zone-change event
    /// for this engine's zone (emits `SyncEvent.remoteWakeReceived` and
    /// calls `nudge()`); `false` if unrelated (wrong zone, unparseable,
    /// or engine not enabled). A `false` return is not an error — it means
    /// the notification was not for this engine.
    ///
    /// Call pattern:
    /// ```swift
    /// func application(_ app: UIApplication,
    ///                  didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    ///                  fetchCompletionHandler handler: @escaping (UIBackgroundFetchResult) -> Void) {
    ///     Task {
    ///         let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
    ///         handler(consumed ? .newData : .noData)
    ///     }
    /// }
    /// ```
    public func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool
}

public enum CKRecordMapping {
    public static func recordType(kitID: String, table: String) -> String   // "kitID_table"
    public static func recordID(rowKey: UUID, zone: CKRecordZone.ID) -> CKRecord.ID
    public static func record(from values: [String: TypedValue], table: String,
        rowKey: UUID, hlc: HLC, schemaVersion: Int, kitID: String,
        zone: CKRecordZone.ID) throws -> CKRecord
    public static func decode(_ record: CKRecord) throws -> DecodedRecord
}

/// Sync metadata extracted from the `moot_sync_*` reserved fields of a CKRecord.
/// Carried separately from `values` so `values` remains clean (no `moot_sync_*` keys)
/// while the engine retains what it needs for conflict resolution and HLC
/// persistence.
public struct SyncMeta: Sendable {
    public let hlc: HLC
    public let schemaVersion: Int
    public let kitID: String
}

/// Decoded CKRecord: app-data values plus sync metadata. `hlc`, `schemaVersion`,
/// and `kitID` are computed convenience accessors backed by `syncMeta`.
public struct DecodedRecord: Sendable {
    public let table: String
    public let rowKey: UUID
    /// App-data values. Contains no `moot_sync_*` keys.
    public let values: [String: TypedValue]
    /// Sync metadata extracted during decode.
    public let syncMeta: SyncMeta
    /// Convenience: `syncMeta.hlc`
    public var hlc: HLC { syncMeta.hlc }
    /// Convenience: `syncMeta.schemaVersion`
    public var schemaVersion: Int { syncMeta.schemaVersion }
    /// Convenience: `syncMeta.kitID`
    public var kitID: String { syncMeta.kitID }
}
```

**Federation — `FederationSyncEngine`** (SPEC § 5, B-7; § 4 I-7, I-8):

```swift
public final class FederationSyncEngine: SyncEngine, Sendable {
    /// - Parameter relay: shared transport for all send/drain operations.
    ///   For in-process tests, two engines must share the same relay instance.
    ///   Defaults to a private `FederationRelay` (single-engine or stub tests).
    public init(relay: any Relay = FederationRelay())

    /// Signed pairing handshake (WC6). Both sides verify each other's Ed25519
    /// signatures over canonical proposal bytes. Throws `authenticationFailed`
    /// if either signature fails or the accepter echoes a different family.
    /// On success both sides persist the peer to `_fed_peers`.
    public func pair(with peer: FederationSyncEngine, family: HyperplaneFamilySpec) async throws

    /// Accepter leg of the pairing handshake. Verifies the proposer's signature,
    /// persists the proposer, and returns a signed `PairingAcceptance`.
    /// Called by `pair(with:family:)` internally; also the entry point for
    /// relay-based pairing (WC7 extension).
    public func acceptPairingProposal(
        _ proposal: PairingProposal,
        proposerSignature: Data
    ) async throws -> PairingAcceptance

    public var identity: LocalIdentity { get async }
}

// Transport abstraction (hosted-sync hook): the engine pairs over `any
// Relay`, so a hosted HTTPS/gRPC SyncServer relay drops in with no engine
// change. `FederationRelay` is the in-process implementation (local + tests);
// `HostedRelay` is the HTTPS conformer (CVK-WC7, injected via `init(relay:)`).
public protocol Relay: Sendable {
    /// Deliver `message` to `recipient`'s inbox. Throws on transport failure
    /// (e.g. `SyncError.transportFailure`); the durable outbox retains the
    /// record for retry. In-process `FederationRelay` never throws.
    func send(to recipient: Data, message: SignedEnvelope) throws
    func drain(for recipient: Data) -> [SignedEnvelope]
}

public final class FederationRelay: Relay, @unchecked Sendable {
    public init()
    public func send(to recipient: Data, message: SignedEnvelope) throws
    public func drain(for recipient: Data) -> [SignedEnvelope]
}

/// Discriminator for the opaque payload carried by `SignedEnvelope`.
/// `syncRecordBatch` (0x01) is the only v1.0 sync payload.
/// `fieldWriteEventBatch` (0x02) reserved for next-gen write-path (C1).
/// Pairing payload kinds (0x10, 0x11) are WC7 extension points for
/// relay-based handshake transport; silently ignored by `pull()` in v1.0.
public enum PayloadKind: UInt8, Sendable, Codable, Hashable {
    case syncRecordBatch   = 0x01
    case pairingProposal   = 0x10
    case pairingAcceptance = 0x11
}

/// Build the canonical deterministic byte sequence that `SignedEnvelope.signature`
/// covers. Byte-identical to Rust `envelope_signing_bytes`. Layout: see comment
/// in `FederationSyncEngine.swift`.
public func envelopeSigningBytes(
    senderPublicKey: Data, payloadKind: PayloadKind,
    payload: Data, hlc: PackedHLC
) -> Data

public struct SignedEnvelope: Sendable, Codable {
    public let senderPublicKey: Data
    public let payloadKind: PayloadKind  // discriminator for opaque payload
    public let payload: Data             // opaque batch bytes (JSON [SyncRecord] for .syncRecordBatch)
    public let signature: Data           // Ed25519 over envelopeSigningBytes(...), not raw payload
    public let hlc: PackedHLC            // batch-level HLC, strictly after per-record HLCs
    public init(senderPublicKey: Data, payloadKind: PayloadKind, payload: Data,
                signature: Data, hlc: PackedHLC)
}

public struct PeerIdentity: Sendable, Hashable {
    public let publicKey: Data          // 32 bytes Ed25519
    public init(publicKey: Data)
}

public struct LocalIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey
    public let publicKey: Data
    public init()
    public init(privateKeyBytes: Data) throws
    public func sign(_ data: Data) throws -> Data
}

public enum FederationSignature {
    public static func verify(_ signature: Data, of data: Data, by peerPublicKey: Data) -> Bool
}

public struct HyperplaneFamilySpec: Sendable, Codable, Hashable {
    public let seed: UInt64
    public let dimension: Int           // default 256
    public init(seed: UInt64, dimension: Int = 256)
}

public struct PairingProposal: Sendable, Codable {
    public let proposerPublicKey: Data
    public let proposedFamily: HyperplaneFamilySpec
    public let nonce: Data
    public init(proposerPublicKey: Data, proposedFamily: HyperplaneFamilySpec, nonce: Data)
}

public struct PairingAcceptance: Sendable, Codable {
    public let accepterPublicKey: Data
    public let acceptedFamily: HyperplaneFamilySpec
    public let signatureOfProposal: Data
    public init(accepterPublicKey: Data, acceptedFamily: HyperplaneFamilySpec,
                signatureOfProposal: Data)
}
```
```rust
pub struct FederationSyncEngine { /* … */ }
impl FederationSyncEngine {
    pub fn new(identity: Arc<LocalIdentity>, relay: Arc<dyn Relay>) -> Self;
    pub fn peer_identity(&self) -> &PeerIdentity;
    /// Explicit outbox entry point for direct-record callers. `enable` also
    /// subscribes the storage observer and auto-populates the outbox on every
    /// observed write — parity with the Swift port (SPEC § 5, B-7).
    pub fn enqueue(&mut self, record: SyncRecord) -> SyncResult<()>;
    /// Record a paired peer. The relay is shared at construction; this call
    /// only registers the peer's public key and family so `push` knows who
    /// to route to. Must be called symmetrically on both engines (Swift parity:
    /// `pair(with:via:family:)` calls `acceptPeering` on the remote engine).
    pub fn pair(&mut self, peer: &FederationSyncEngine,
                family: HyperplaneFamilySpec) -> SyncResult<()>;
}

// Transport abstraction (hosted-sync hook): the engine holds `Arc<dyn
// Relay>`, so a hosted SyncServer relay drops in with no engine change.
// `FederationRelay` is the in-process implementation (local + tests).
pub trait Relay: Send + Sync {
    fn register(&self, identity: PeerIdentity) -> std::sync::mpsc::Receiver<SignedEnvelope>;
    fn broadcast(&self, from: &PeerIdentity, envelope: SignedEnvelope);
    /// Deliver to one specific peer (by public key). Used by `push` to route
    /// envelopes only to explicitly paired peers rather than broadcasting to
    /// all relay participants.
    fn send_to(&self, from: &PeerIdentity, to_public_key: &[u8; 32], envelope: SignedEnvelope);
}

pub struct FederationRelay { /* … */ }                         // also Default
impl FederationRelay {
    pub fn new() -> Self;
}
impl Relay for FederationRelay {
    fn register(&self, identity: PeerIdentity) -> std::sync::mpsc::Receiver<SignedEnvelope>;
    fn broadcast(&self, from: &PeerIdentity, envelope: SignedEnvelope);
    fn send_to(&self, from: &PeerIdentity, to_public_key: &[u8; 32], envelope: SignedEnvelope);
}

/// Discriminator for the opaque payload carried by `SignedEnvelope`.
/// `SyncRecordBatch` (0x01) is the only v1.0 variant. `FieldWriteEventBatch`
/// (0x02) is reserved for the next-gen write-path payload (C1 extension point).
#[repr(u8)]
pub enum PayloadKind { SyncRecordBatch = 0x01 }

/// Build the canonical deterministic byte sequence that `SignedEnvelope.signature`
/// covers. Byte-identical to Swift `envelopeSigningBytes`. Layout: see comment
/// in `federation.rs`.
pub fn envelope_signing_bytes(
    sender_public_key: &[u8; 32], payload_kind: PayloadKind,
    payload: &[u8], hlc: &PackedHLC,
) -> Vec<u8>;

pub struct SignedEnvelope {
    pub sender_public_key: [u8; 32],
    pub payload_kind: PayloadKind,   // discriminator for opaque payload
    pub payload: Vec<u8>,            // opaque batch bytes (JSON [SyncRecord] for SyncRecordBatch)
    pub signature: [u8; 64],         // Ed25519 over envelope_signing_bytes(...), not raw payload
    pub hlc: PackedHLC,              // batch-level HLC, strictly after per-record HLCs
}

pub struct PeerIdentity { pub public_key: [u8; 32] }
impl PeerIdentity { pub fn new(public_key: [u8; 32]) -> Self; }

pub struct LocalIdentity { /* Ed25519 signing key */ }
impl LocalIdentity {
    pub fn generate() -> Self;
    pub fn from_secret(secret: [u8; 32]) -> Self;
    pub fn public_key_bytes(&self) -> [u8; 32];
    pub fn secret_bytes(&self) -> [u8; 32];
    pub fn sign(&self, data: &[u8]) -> [u8; 64];
}

pub fn verify_signature(signature: &[u8], data: &[u8], peer_public_key: &[u8]) -> bool;

/// A peer that has been explicitly paired via `pair()`. Re-exported from
/// `federation.rs` via `pub use federation::*`. The engine only pushes when
/// at least one `PairedPeer` exists; `push` returns an empty receipt when
/// `paired_peers` is empty. No Swift public counterpart — the Swift analog
/// (`FederationStateActor.PairedPeer`) is an internal actor-nested type.
#[derive(Debug, Clone)]
pub struct PairedPeer {
    pub public_key: [u8; 32],
    pub family: HyperplaneFamilySpec,
}

pub struct HyperplaneFamilySpec { pub seed: u64, pub dimension: u32 }
impl HyperplaneFamilySpec {
    pub fn new(seed: u64) -> Self;                       // dimension = 256
    pub fn with_dimension(seed: u64, dimension: u32) -> Self;
}

pub struct PairingProposal {
    pub proposer_public_key: Vec<u8>,
    pub proposed_family: HyperplaneFamilySpec,
    pub nonce: Vec<u8>,
}
pub struct PairingAcceptance {
    pub accepter_public_key: Vec<u8>,
    pub accepted_family: HyperplaneFamilySpec,
    pub signature_of_proposal: Vec<u8>,
}
pub fn proposal_signing_bytes(proposal: &PairingProposal) -> Vec<u8>;
```

## § 3 — Public functions

ConvergenceKit exposes no free functions beyond the engine methods
(§ 2 `SyncEngine`), the backend constructors and helpers (§ 2 backend
types), and the Rust pairing/signature helpers `verify_signature` and
`proposal_signing_bytes`. Behavioral contracts for the lifecycle methods
are in SPEC § 4 (I-1…I-9) and § 5 (B-1…B-7).

## § 4 — Errors

The `SyncError` enum. Conceptual meaning of each category: SPEC § 6.

**Swift:**

```swift
public enum SyncError: Error, Sendable, Equatable {
    case notEnabled
    case alreadyEnabled
    case schemaMismatch(expected: Int, received: Int)
    case kitMismatch(expected: String, received: String)
    case transportFailure(detail: String)
    case decodingFailure(detail: String)
    case encodingFailure(detail: String)
    case peerUnreachable(identity: String)
    case authenticationFailed(detail: String)
    case unsupportedTable(name: String)
    /// CloudKit-only. A CKRecord whose `recordName` could not be parsed as
    /// a UUID. Fabricating a UUID from a corrupt recordName would create a
    /// phantom local row that diverges on every subsequent sync round; the
    /// pull loop quarantines the record, counts it as a conflict, and
    /// continues to the next record rather than aborting the batch.
    case corruptRemoteIdentity(recordName: String)
    /// CloudKit-only. The device's `(slot, epoch)` pair has
    /// been superseded: the slot was evicted and its epoch bumped while this
    /// device was inactive. Raised before any inbound records are applied.
    /// Recovery: the engine re-claims a fresh slot, re-mints pending outbox
    /// entries under the new identity, then resumes the pull cycle.
    case reenrollRequired(slot: Int, staleEpoch: Int, currentEpoch: Int)
    /// CloudKit-only. All 15 assignable node-ID slots (1–15)
    /// are occupied by recently-active devices. No records are applied.
    /// Surfaced loud to the caller; the engine retries after a slot is freed.
    case slotExhausted(activeCount: Int)
}
```

**Rust:** (`SyncError` implements `std::error::Error` + `Display`;
`SyncResult<T> = Result<T, SyncError>`)

```rust
pub enum SyncError {
    NotEnabled,
    AlreadyEnabled,
    SchemaMismatch { expected: i32, received: i32 },
    KitMismatch { expected: String, received: String },
    TransportFailure { detail: String },
    DecodingFailure { detail: String },
    EncodingFailure { detail: String },
    PeerUnreachable { identity: String },
    AuthenticationFailed { detail: String },
    UnsupportedTable { name: String },
}
pub type SyncResult<T> = Result<T, SyncError>;
```

ConvergenceKit names its error enum `SyncError` (not `ConvergenceKitError`):
the type predates the `<Package>Error` naming convention and is the
stable wire-and-API name across both ports.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/ConvergenceKit
```

Test targets: `ConvergenceKitTests` (core types), `ConvergenceKitNoneTests`,
`ConvergenceKitCloudKitTests` (CloudKit gated on a configured test
container), `ConvergenceKitFederationTests`. Shared fixtures live in the
`ConvergenceKitConformance` target over InMemory PersistenceKit.

**Rust:**

```
cargo test -p convergence-kit
```

Test files: `tests/none_engine_tests.rs`, `tests/federation_tests.rs`,
`tests/federation_lww_tests.rs`, `tests/federation_inbound_event_tests.rs`,
`tests/federation_observer_outbox_tests.rs`, `tests/wire_format_tests.rs`,
`tests/json_conformance_tests.rs`.

## § 6 — Examples

```swift
import ConvergenceKit
import ConvergenceKitNone        // or …CloudKit / …Federation
import PersistenceKit

// Declare which tables sync, the zone, and conflict policy.
let manifest = SyncManifest(
    kitID: "Corpus",
    schemaVersion: 3,
    zoneIdentifier: "GeniusLocus-\(estateUUID)",
    tables: [
        SyncedTable(name: "chunks", primaryKeyColumn: "id",
                    conflictPolicy: .lastWriterWinsByHLC)
    ]
)

// Local-first default: no sync code paths active.
let engine: any SyncEngine = NoSyncEngine()
try await engine.enable(manifest: manifest, storage: storage)

// Drive one cycle and read the receipt.
let receipt = try await engine.push()        // pulled == 0
print(receipt.pushed, receipt.conflicts)

// Wake on remote activity.
Task {
    for await event in engine.subscribe() {
        if case .remoteChangesApplied(let n) = event { handle(n) }
    }
}

// Federation: pair two estates over a relay. `relay` is typed `any Relay`,
// so a hosted SyncServer relay drops in here; FederationRelay is in-process.
let a = FederationSyncEngine(), b = FederationSyncEngine()
let relay: any Relay = FederationRelay()
try await a.pair(with: b, via: relay, family: HyperplaneFamilySpec(seed: 0x5EED))
```

## § 7 — Swift/Rust Concordance

One row per public contract concept. Each Swift symbol and Rust symbol
is a real top-level declaration in source. "Shape rule" states the
sanctioned port difference.

### Core protocol + lifecycle

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Sync engine lifecycle contract | `SyncEngine` (`Sources/ConvergenceKit/SyncEngine.swift`) | `SyncEngine` (`rust/src/engine.rs`) | public protocol / pub trait | Swift async (`async throws`, `: Sendable`) / Rust sync (`&mut self`, `: Send`; `subscribe` → mpsc `Receiver` vs `AsyncStream`) — sanctioned, cf. PersistenceKit no-async-runtime seam | Confirmed |

### Manifest / configuration value types

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Sync direction | `SyncDirection` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncDirection` (`rust/src/types.rs`) | public enum / pub enum | Swift `String`-raw lowerCamel cases / Rust UpperCamel cases — identical variant set | Confirmed |
| Conflict policy | `ConflictPolicy` (`Sources/ConvergenceKit/SyncTypes.swift`) | `ConflictPolicy` (`rust/src/types.rs`) | public enum / pub enum | Swift `String`-raw / Rust plain enum; 5 variants including `fieldLevelLWW` / `FieldLevelLWW`; both default LWW-by-HLC; wire encodes as camelCase "fieldLevelLWW" (both legs) | Confirmed |
| Synced-table declaration | `SyncedTable` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncedTable` (`rust/src/types.rs`) | public struct / pub struct | Swift memberwise `init` w/ defaults / Rust `new` + builder (`with_direction`, `with_conflict_policy`, `with_excluded_columns`); `excludedColumns: Set<String>` (Swift) / `excluded_columns: HashSet<String>` (Rust) — serde default empty | Confirmed |
| Sync manifest | `SyncManifest` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncManifest` (`rust/src/types.rs`) | public struct / pub struct | identical fields; Swift `table(named:)` / Rust `table_named`; `schemaVersion: Int` vs `schema_version: i32`; `postApplyIntegrityHook` Swift-only closure (shipped; Rust `post_apply_hook` deferred — closures not serializable) | Confirmed |

### Cycle result + observation value types

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Cycle receipt | `SyncReceipt` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncReceipt` (`rust/src/types.rs`) | public struct / pub struct | Swift `timestamp: Date` / Rust `timestamp_secs: i64` (Unix epoch); counts `Int` vs `usize`; both expose `empty` | Confirmed |
| Event-stream payload | `SyncEvent` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncEvent` (`rust/src/types.rs`) | public enum / pub enum | Swift labelled-associated cases / Rust struct-variant cases; 6 variants: 5 shared + `remoteWakeReceived` (Swift) / `RemoteWakeReceived` (Rust parity arm, never constructed on Rust side — CloudKit is Swift-only) | Confirmed |
| Coarse UI state | `SyncState` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncState` (`rust/src/types.rs`) | public enum / pub enum | Swift `case error` / Rust `Errored`; Swift `Date?` / Rust `Option<i64>` secs; same 4 states | Confirmed |

### Wire format (`SyncRecord` and TypedValue boxing)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Wire record | `SyncRecord` (`Sources/ConvergenceKit/SyncRecord.swift`) | `SyncRecord` (`rust/src/record.rs`) | public struct / pub struct | identical fields; `rowKey: UUID` vs `row_key: Uuid`; `columnHLCs: ColumnHLCMap?` vs `column_hlcs: Option<ColumnHLCMap>` (B-8); Codable JSON ↔ serde_json wire-compatible | Confirmed |
| Column HLC map | `ColumnHLCMap` (`Sources/ConvergenceKit/FieldLWW/ColumnHLCMap.swift`) | `ColumnHLCMap` (`rust/src/record.rs`) | public struct / pub struct | Swift `[String: PackedHLC]` under `entries` key / Rust `BTreeMap<String, PackedHLC>` under `entries` key; both JSON-encode as `{"entries":{…}}`. Rust BTreeMap = alphabetical key order for deterministic encoding (C-8). | Confirmed |
| Event kind | `SyncEventKind` (`Sources/ConvergenceKit/SyncRecord.swift`) | `SyncEventKind` (`rust/src/record.rs`) | public enum / pub enum | Swift `init(from:)`/`asStorageEvent` / Rust `From`/`Into<StorageEvent>`; same insert/update/delete | Confirmed |
| Packed HLC | `PackedHLC` (`Sources/ConvergenceKit/SyncRecord.swift`) | `PackedHLC` (`rust/src/record.rs`) | public struct / pub struct | Swift `Int64`/`Int32` fields / Rust `i64`/`i32`; both bridge `HLC` | Confirmed |
| Fingerprint wire | `FingerprintWire` (`Sources/ConvergenceKit/SyncRecord.swift`) | `FingerprintWire` (`rust/src/record.rs`) | public struct / pub struct | Swift 4×`UInt64` blocks / Rust 4×`u64`; both bridge `Fingerprint256` | Confirmed |
| Typed-value box | `SyncValueBox` (`Sources/ConvergenceKit/SyncRecord.swift`) | `SyncValueBox` (`rust/src/record.rs`) | public struct / pub enum | Swift outer `struct{kind,payload}` wrapping nested `enum Payload` / Rust flat `enum` w/ `#[serde(tag="kind",content="payload")]` — same tagged JSON wire; Swift `.bytes`/`.timestamp` ↔ Rust `Blob`/`Timestamp`(i64), Swift array nesting ↔ Rust `Array` | Confirmed |
| Typed-value map | `SyncValueMap` (`Sources/ConvergenceKit/SyncRecord.swift`) | `SyncValueMap` (`rust/src/record.rs`) | public struct / pub struct | Swift `[String:SyncValueBox]` / Rust `BTreeMap`; Swift `asTypedValues` / Rust `from_typed`/`into_typed` | Confirmed |

### Backends — None

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| No-op engine (local-first default) | `NoSyncEngine` (`Sources/ConvergenceKitNone/ConvergenceKitNone.swift`) | `NoSyncEngine` (`rust/src/none.rs`) | public final class / pub struct | Swift `final class` / Rust `struct` (+`Default`); both conform to the engine contract, all cycles return `.empty` | Confirmed |

### Backends — Federation

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Federation engine | `FederationSyncEngine` (`Sources/ConvergenceKitFederation/FederationSyncEngine.swift`) | `FederationSyncEngine` (`rust/src/federation.rs`) | public final class / pub struct | Both ports auto-populate the outbox by subscribing the storage observer at `enable` (SPEC § 5, B-7); Rust also exposes an explicit `enqueue` for direct-record callers; `init()` vs `new(identity, relay)`. Both ports have a `pair` method: Swift `pair(with:via:family:)` takes a peer engine, relay, and family and calls `acceptPeering` on the remote to make it symmetric; Rust `pair(&mut self, peer:, family:)` takes a peer ref and records the public key — relay is shared at construction so no relay arg; each side must call `pair` on the other. | Confirmed |
| Transport abstraction | `Relay` (`Sources/ConvergenceKitFederation/FederationSyncEngine.swift`) | `Relay` (`rust/src/federation.rs`) | public protocol / pub trait | Same hosted-relay seam, different verb shape: Swift inbox `send`/`drain` (poll) / Rust `register`(→`Receiver`)/`broadcast` + `send_to` (push, targeted). Rust has an additional `send_to(from:to_public_key:envelope:)` that routes to one specific peer by public key — used by `push` to honor the pairing boundary. Both carry the signed envelope; bound `Sendable` vs `Send + Sync` | Confirmed |
| In-process relay | `FederationRelay` (`Sources/ConvergenceKitFederation/FederationSyncEngine.swift`) | `FederationRelay` (`rust/src/federation.rs`) | public final class / pub struct | Swift `NSLock`-guarded inboxes / Rust `Mutex` + mpsc senders (+`Default`); same in-process semantics | Confirmed |
| HTTPS relay (hosted) | `HostedRelay` (`Sources/ConvergenceKitFederation/Relay/HostedRelay.swift`) | Rust twin deferred (WC7 charter — client conformer Swift-first) | public final class / n/a | Conforms to `Relay`. Three-endpoint client: `register(publicKey:) throws` (POST /v1/register), `send(to:message:) throws` (POST /v1/send/{hex}), `drain(for:) → [SignedEnvelope]` (GET /v1/inbox/{hex}?after={cursor}). Injectable `RelayHTTPTransport` seam: `URLSessionRelayHTTPTransport` (production, DispatchSemaphore bridge) / `FakeRelayHTTPTransport` (tests, in-memory). Spec: `docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md`. Cursor in-memory (non-persisted); LWW gate handles at-least-once re-delivery on restart. 409 dedup treated as success per §3.2. HTTP status → SyncError per §4. Delivered CVK-WC7. | Confirmed |
| HTTP transport seam | `RelayHTTPTransport` (`Sources/ConvergenceKitFederation/Relay/RelayHTTPTransport.swift`) | n/a | public protocol / n/a | Synchronous execute(request:) throws → response. Bridges the async URLSession API (production) to the sync Relay protocol contract. FakeRelayHTTPTransport (test target) is the in-memory implementation. | Confirmed |
| Signed wire envelope | `SignedEnvelope` (`Sources/ConvergenceKitFederation/FederationSyncEngine.swift`), `PayloadKind` (same file), `envelopeSigningBytes(...)` (same file) | `SignedEnvelope` (`rust/src/federation.rs`), `PayloadKind` (same file), `envelope_signing_bytes` (same file) | public struct+enum+func / pub struct+enum+fn | Unified batch envelope: both ports carry `sender_public_key` (32B Ed25519), `payload_kind` (C1 tag: `syncRecordBatch`=0x01), opaque `payload` (JSON `[SyncRecord]` batch), `signature` (Ed25519 over canonical bytes — NOT raw JSON), `hlc` (batch-level). Canonical signing bytes are deterministic and byte-identical cross-port; golden vector in both test suites. `payload_kind` is the C1 extension point for `fieldWriteEventBatch`. Shape rule: Swift `Data`/`UInt8` vs Rust `Vec<u8>`/`u8` — same encoding | Confirmed |
| Peer identity | `PeerIdentity` (`Sources/ConvergenceKitFederation/FederationIdentity.swift`) | `PeerIdentity` (`rust/src/federation.rs`) | public struct / pub struct | Swift `publicKey: Data` (32B Ed25519) / Rust `public_key: [u8;32]` | Confirmed |
| Local identity (signing key) | `LocalIdentity` (`Sources/ConvergenceKitFederation/FederationIdentity.swift`) | `LocalIdentity` (`rust/src/federation.rs`) | public struct / pub struct | Swift `Curve25519.Signing.PrivateKey` (CryptoKit) / Rust ed25519-dalek key; Swift `init()`/`init(privateKeyBytes:)`/`sign` ↔ Rust `generate`/`from_secret`/`secret_bytes`/`public_key_bytes`/`sign`. Crypto backend differs by platform but both are Ed25519, byte-compatible keys/signatures | Confirmed |
| Signature verification | `FederationSignature` (`Sources/ConvergenceKitFederation/FederationIdentity.swift`) | `verify_signature` (`rust/src/federation.rs`, free `pub fn`) | public enum (static `verify`) / pub free fn | Swift wraps verify in a caseless namespace enum / Rust exposes a free function — same Ed25519 verify behavior, no Rust namespace type by idiom | Confirmed |

### Federation pairing handshake

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Hyperplane family spec | `HyperplaneFamilySpec` (`Sources/ConvergenceKitFederation/HyperplaneFamilyExchange.swift`) | `HyperplaneFamilySpec` (`rust/src/pairing.rs`) | public struct / pub struct | Swift `seed: UInt64`, `dimension: Int=256` (default init) / Rust `seed: u64`, `dimension: u32`; `new(seed)`=256 + `with_dimension` | Confirmed |
| Pairing proposal | `PairingProposal` (`Sources/ConvergenceKitFederation/HyperplaneFamilyExchange.swift`) | `PairingProposal` (`rust/src/pairing.rs`) | public struct / pub struct | Swift `Data` fields / Rust `Vec<u8>`; same `proposerPublicKey`/`proposedFamily`/`nonce` | Confirmed |
| Pairing acceptance | `PairingAcceptance` (`Sources/ConvergenceKitFederation/HyperplaneFamilyExchange.swift`) | `PairingAcceptance` (`rust/src/pairing.rs`) | public struct / pub struct | Swift `Data` / Rust `Vec<u8>`; same accepter/acceptedFamily/signatureOfProposal | Confirmed |
| Proposal signing bytes | (Swift: inline in `HyperplaneFamilyExchange` pairing path) | `proposal_signing_bytes` (`rust/src/pairing.rs`, free `pub fn`) | n/a / pub free fn | Canonical signing-byte helper; Swift computes the same bytes inline during pairing rather than as a standalone symbol | Confirmed |

### Error model

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| Sync error enum | `SyncError` (`Sources/ConvergenceKit/SyncTypes.swift`) | `SyncError` (`rust/src/types.rs`) | public enum / pub enum | Swift `Error, Equatable` w/ labelled associated values / Rust struct-variant enum + `std::error::Error`+`Display`; 10 shared categories + Swift-only CloudKit cases: `corruptRemoteIdentity(recordName:)` (shipped), `reenrollRequired(slot:staleEpoch:currentEpoch:)` (CloudKit-only, shipped), `slotExhausted(activeCount:)` (CloudKit-only, shipped). Named `SyncError` (not `ConvergenceKitError`) by stable wire convention | Confirmed |
| Result alias | (Swift: `throws` — no result type) | `SyncResult<T>` (`rust/src/types.rs`) | n/a / pub type alias | Swift uses `throws`; Rust port has no async runtime so it returns `Result<T, SyncError>` aliased as `SyncResult` — sanctioned async/throws ↔ Result seam | Confirmed |

### CloudKit backend — Apple-platform-bound (Exempt)

CloudKit is an Apple framework with no Rust counterpart by design
(ConvergenceKit exposes CloudKit/Federation/None behind one protocol;
only Federation/None have Rust ports).

**`CloudKitSyncEngine` init signature (P3-M2):**

```swift
public init(containerIdentifier: String? = nil, enablePolling: Bool = false)
```

`enablePolling: Bool = false` — when `true`, `enable()` auto-starts an
`AdaptivePollScheduler`. Default `false` preserves existing test behavior
(manual push/pull drive).

**`CloudKitSyncEngine.nudge()` — external accelerator seam (B-11):**

```swift
public func nudge() async
```

Fire an immediate inbound pull and reset the poll tier to `fast`. This is
THE SEAM for external accelerators (SPEC B-11):

- **P3-M3** — `OutboxDrainDebouncer` calls `nudge()` after each push cycle
  so the remote peer's response arrives sooner than idle cadence.
- **Future** — APNs silent-push wakeup handlers call `nudge()` rather than
  `pull()` directly; the scheduler manages tier accounting.
- **Future** — Local IPC from a companion process calls `nudge()` to wake
  the poll loop.

Behavior: if a scheduler is active (`enablePolling: true`), delegates to
`AdaptivePollScheduler.nudge()` (interrupt sleep + reset tier). If no
scheduler is running, fires a one-shot `pull()` directly — safe to call
even without background polling.

**`AdaptivePollScheduler` — the poll loop actor (P3-M2):**

```swift
public typealias SchedulerPullFn = @Sendable () async throws -> SyncReceipt
public typealias SchedulerSleepFn = @Sendable (Duration) async throws -> Void

public actor AdaptivePollScheduler {
    public init(pull: @escaping SchedulerPullFn,
                sleep: @escaping SchedulerSleepFn = { d in try await Task.sleep(for: d) })
    public func start()              // idempotent
    public func stop()               // deterministic; satisfies I-2
    public func nudge()              // interrupt sleep + reset tier to fast
    public var currentTier: PollTier { get }
    public var nextIntervalMs: Int64 { get }
}
```

Injection seam: pass `sleep: { _ in }` in tests for immediate-return loops.
Sleep interruption: `nudge()` cancels an internal sleep sub-task WITHOUT
cancelling the main loop task.

**`PollTierPolicy` — pure tier decision table (P3-M2):**

```swift
public enum PollTier: Equatable, Sendable, CustomStringConvertible {
    case fast   // 20 s — recent remote or local activity
    case mid    // 90 s — activity receding
    case idle   // 5 min — zone quiescent
}

public struct PollTierPolicy: Sendable {
    public static let fastIntervalMs:     Int64 = 20_000   // 20 s
    public static let midIntervalMs:      Int64 = 90_000   // 90 s
    public static let idleIntervalMs:     Int64 = 300_000  // 5 min
    public static let activityWindowMs:   Int64 = 120_000  // 2 min hold-fast window

    public init()
    public var tier: PollTier { get }
    public var lastActivityMs: Int64? { get }
    public var nextIntervalMs: Int64 { get }

    public mutating func recordNonEmptyPull(nowMs: Int64)  // → fast, stamp activity
    public mutating func recordEmptyPull(nowMs: Int64)     // → hold fast (in window) or decay
    public mutating func recordNudge(nowMs: Int64)         // → fast, stamp activity
}
```

All mutation methods take `nowMs: Int64` (milliseconds since Unix epoch)
so the full transition table is deterministically testable without OS time
calls. `AdaptivePollScheduler` owns the clock and feeds `nowMs` here.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Status |
|---|---|---|---|---|---|
| CloudKit engine | `CloudKitSyncEngine` (`Sources/ConvergenceKitCloudKit/CloudKitSyncEngine.swift`) | — | public final class / — | Rust: none — Apple platform binding (CloudKit). `init(containerIdentifier:enablePolling:)` P3-M2. `nudge()` P3-M2 (B-11 seam). `registerZoneSubscription()`, `deregisterZoneSubscription()`, `handleRemoteNotification(userInfo:)` shipped P3-M3 (zone subscription + remote-wake accelerator). | Exempt |
| Adaptive poll scheduler | `AdaptivePollScheduler` (`Sources/ConvergenceKitCloudKit/Engine/AdaptivePollScheduler.swift`) | — | public actor / — | Rust: none — Apple platform binding. `SchedulerPullFn`, `SchedulerSleepFn` typealias. Injected sleep for testability. Shipped P3-M2 | Exempt |
| Poll tier policy | `PollTierPolicy`, `PollTier` (`Sources/ConvergenceKit/Loop/PollTierPolicy.swift`) | — | public struct, public enum / — | Rust: none — CloudKit-specific. Pure table, no OS calls, `nowMs: Int64` injection. Shipped P3-M2 | Exempt |
| CKRecord ↔ row mapping | `CKRecordMapping` (`Sources/ConvergenceKitCloudKit/CKRecordMapping.swift`) | — | public enum / — | Rust: none — Apple platform binding (CloudKit) | Exempt |
| Decoded CKRecord | `DecodedRecord` (`Sources/ConvergenceKitCloudKit/CKRecordMapping.swift`) — stored: `table`, `rowKey`, `values`, `syncMeta: SyncMeta`; computed: `hlc`, `schemaVersion`, `kitID` | — | public struct / — | Rust: none — Apple platform binding (CloudKit). `hlc`/`schemaVersion`/`kitID` are computed accessors backed by `syncMeta`, not stored fields. | Exempt |
| CloudKit sync metadata | `SyncMeta` (`Sources/ConvergenceKitCloudKit/CKRecordMapping.swift`) — fields: `hlc: HLC`, `schemaVersion: Int`, `kitID: String` | — | public struct / — | Rust: none — Apple platform binding (CloudKit). Introduced to separate sync metadata from app-data values in `DecodedRecord`. | Exempt |

---

*End of ConvergenceKit Interface.*

## Changelog

### 1.7 -- 2026-07-17 (CVK-WC-FIX)
- **`FederationSyncEngine.init`**: corrected signature from `init()` to
  `init(relay: any Relay = FederationRelay())`. The relay parameter was
  added in WC7 (CVK-WC7) so two engines share a transport; the no-arg
  form never existed in shipped code.
- **`FederationSyncEngine.pair`**: removed stale `via relay: any Relay`
  parameter. Shipped WC6 API is `pair(with:family:)` — relay is set at
  `init(relay:)` time, not per-call.
- **`FederationSyncEngine.acceptPairingProposal`**: added public method
  (shipped WC6). Accepter-side leg of the Ed25519 handshake; called by
  `pair(with:family:)` internally and by relay-based pairing (WC7).
- **`Relay.send`**: changed to `throws`. Durable outbox (WC2) retains
  records on transport failure; `FederationRelay` never throws in-process.
- **`PayloadKind`**: added `pairingProposal = 0x10` and
  `pairingAcceptance = 0x11` (shipped WC6 — reserved byte values for
  relay-based pairing transport, silently ignored by `pull()` in v1.0).

### 1.6 -- 2026-07-17 (CVK-ICLOUD P5-M4)
- Promoted 1.6-draft to 1.6 (status: active). All `(v1.2-draft)` markers
  removed: `excludedColumns` / `postApplyIntegrityHook` / `FieldLevelLWW`
  (all shipped in CVK-ICLOUD P2-M1..P2-M2); `reenrollRequired` /
  `slotExhausted` (shipped P3-M3/P4-M5); `TableChange.origin` note
  updated from forward-reference to shipped status (P1-M1). Conformance
  table Status cells updated to "Confirmed" throughout.

### 1.6-draft -- 2026-07-17 (CVK-ICLOUD P4-M6)
- Updated `purpose` frontmatter: corrected SPEC conformance range from
  C-1…C-8 to C-1…C-15 to reflect the executable conformance table added
  in SPEC P4-M6 (C-9..C-15 with named green tests).
- `subscribeAttached()` NOT added: method was specified for this pass but
  does not exist in `CloudKitSyncEngine.swift` at this revision. Per
  SPEC-BEFORE-REALITY, the INTERFACE is not updated until the
  implementation lands.

### 1.5-draft -- 2026-07-16 (CVK-ICLOUD P3-M3)
- Added `SyncEvent.remoteWakeReceived` (Swift) and `SyncEvent::RemoteWakeReceived`
  (Rust parity arm, never constructed on Rust side) to § 2 `SyncEvent` listing.
- Updated `SyncEvent` concordance row: 5 → 6 variants; parity-arm note added.
- Updated `CloudKitSyncEngine` in § 2: corrected `init` signature to
  `init(containerIdentifier:enablePolling:)`, replaced future-only
  `registerZoneSubscription(database:)` and `handleRemoteNotification` with
  shipped signatures (`registerZoneSubscription()` — no CKDatabase arg,
  routes through the protocol seam; `deregisterZoneSubscription()` new;
  `handleRemoteNotification(userInfo:)` now with full host-app call pattern).
- Updated `CloudKitSyncEngine` concordance table row: P3-M3 APIs marked shipped.

### 1.4-draft -- 2026-07-16 (CVK-ICLOUD P3-M2)
- Added `CloudKitSyncEngine.init(containerIdentifier:enablePolling:)` —
  `enablePolling: Bool = false` opt-in for auto-starting the poll scheduler.
- Added formal `nudge()` API documentation to CloudKit section (shipped;
  previously listed as planned in 1.3-draft changelog only).
- Added `AdaptivePollScheduler` actor (`SchedulerPullFn`, `SchedulerSleepFn`
  typealias; `start()`, `stop()`, `nudge()`, `currentTier`, `nextIntervalMs`)
  to CloudKit section. Injected sleep for testability; interruptible sleep
  sub-task for `nudge()`.
- Added `PollTierPolicy` struct and `PollTier` enum (pure tier decision
  table: fast/mid/idle + 2-min activity window; `nowMs: Int64` injection
  for deterministic testing) to CloudKit section.
- Updated `CloudKitSyncEngine` concordance table row: `nudge()` shipped,
  `registerZoneSubscription`/`handleRemoteNotification` marked future-only.
- Added `AdaptivePollScheduler` and `PollTier`/`PollTierPolicy` rows to
  concordance table.

### 1.3-draft -- 2026-07-16 (updated CVK-ICLOUD P3-M4)
- Added `SyncEvent.recordsHeldForMigration(count: Int)` to `SyncEvent` enum
  (Swift); added `SyncEvent::RecordsHeldForMigration { count: usize }` to Rust
  `SyncEvent`. Emitted by CloudKit and Federation backends when future-schema
  records are held in the pending-skew queue during pull, or when the queue
  remains non-empty after enable-time replay. SPEC B-3, B-10.

### 1.3-draft -- 2026-07-16
- Added `ConflictPolicy.fieldLevelLWW` (Swift and Rust; v1.2-draft) to § 2.
- Added `SyncedTable.excludedColumns` / `excluded_columns` (Swift and Rust;
  v1.2-draft) and `with_excluded_columns` Rust builder to § 2.
- Changed `SyncManifest` from `Codable` to non-Codable (closure property
  `postApplyIntegrityHook` is not serializable); added `postApplyIntegrityHook`
  (Swift-only, v1.2-draft) to § 2.
- Added `TableChange.origin` cross-reference note to § 2 (PersistenceKit
  P1-M1; do not edit PersistenceKit docs here).
- Added `SyncError.reenrollRequired(slot:staleEpoch:currentEpoch:)` and
  `SyncError.slotExhausted(activeCount:)` (Swift-only, CloudKit, v1.2-draft)
  to § 4.
- Added `CloudKitSyncEngine` host-app accelerator surface: `nudge()`,
  `registerZoneSubscription(database:)`, `handleRemoteNotification(userInfo:)`
  (v1.2-draft) to § 2.
- Updated concordance table in § 7 for all of the above.

### 1.1 -- 2026-07-16
- Added Swift-only `SyncError.corruptRemoteIdentity(recordName:)` case to § 4 (CloudKit pull guard, thrown when `recordName` cannot parse as UUID).
- Added `SyncMeta` public struct to CloudKit backend types in § 2.
- Fixed `DecodedRecord` signature: `syncMeta: SyncMeta` is the stored property; `hlc`/`schemaVersion`/`kitID` are computed `var` accessors, not stored `let` fields.
- Added `send_to(from:to_public_key:envelope:)` to Rust `Relay` trait and `FederationRelay` implementation in § 2.
- Added Rust `FederationSyncEngine.pair` method to § 2.
- Expanded Rust test-file list in § 5 (four additional test files).
- Updated concordance table in § 7 for all of the above.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
