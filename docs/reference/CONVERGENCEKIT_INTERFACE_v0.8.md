---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: ConvergenceKit
languages: [swift, rust]
relates_to:
  - CONVERGENCEKIT_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of ConvergenceKit in both ports: the SyncEngine
  protocol, the SyncManifest declaration model, the SyncRecord wire
  format and TypedValue boxing, the SyncReceipt / SyncEvent / SyncState
  value types, the SyncError enum, and the three backends (None,
  CloudKit, Federation). The companion SPEC carries the behavioral
  contracts (invariants I-1…I-9, conformance C-1…C-8).
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
- `Sources/ConvergenceKitNone/` — `NoSyncEngine` (default, SPEC § 5 B-1)
- `Sources/ConvergenceKitCloudKit/` — `CloudKitSyncEngine`,
  `CKRecordMapping`, `DecodedRecord`
- `Sources/ConvergenceKitFederation/` — `FederationSyncEngine`,
  `FederationRelay`, `SignedMessage`, `LocalIdentity`, `PeerIdentity`,
  `FederationSignature`, `HyperplaneFamilySpec`, `PairingProposal`,
  `PairingAcceptance`
- `Tests/ConvergenceKitConformance/` — shared fixtures; per-backend test
  targets; `Package.swift`

Four library products: `ConvergenceKit`, `ConvergenceKitNone`,
`ConvergenceKitCloudKit`, `ConvergenceKitFederation`.

**Rust:** `packages/kits/ConvergenceKit/rust/` (crate `convergence-kit`)

- `src/types.rs` — `SyncDirection`, `ConflictPolicy`, `SyncedTable`,
  `SyncManifest`, `SyncReceipt`, `SyncEvent`, `SyncState`, `SyncError`,
  `SyncResult`
- `src/record.rs` — `SyncRecord`, `SyncEventKind`, `PackedHLC`,
  `FingerprintWire`, `SyncValueBox`, `SyncValueMap`
- `src/engine.rs` — the `SyncEngine` trait
- `src/none.rs` — `NoSyncEngine`
- `src/federation.rs` — `FederationSyncEngine`, `FederationRelay`,
  `SignedRecord`, `LocalIdentity`, `PeerIdentity`, `verify_signature`
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
an mpsc `Receiver` rather than an `AsyncStream`)

```rust
pub trait SyncEngine: Send + Sync {
    fn enable(&self, manifest: SyncManifest, storage: Arc<dyn Storage>) -> SyncResult<()>;
    fn disable(&self) -> SyncResult<()>;
    fn push(&self) -> SyncResult<SyncReceipt>;
    fn pull(&self) -> SyncResult<SyncReceipt>;
    fn subscribe(&self) -> std::sync::mpsc::Receiver<SyncEvent>;
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
    case lastWriterWinsByHLC   // default; HLC of incoming vs local wins
    case appendOnly            // (eventID, hlc) idempotent; audit log
    case localWins             // receiver discards remote on conflict
    case remoteWins            // receiver overwrites local on conflict
}

public struct SyncedTable: Sendable, Codable {
    public let name: String
    public let direction: SyncDirection
    public let primaryKeyColumn: String
    public let conflictPolicy: ConflictPolicy
    public init(name: String, direction: SyncDirection = .bidirectional,
                primaryKeyColumn: String, conflictPolicy: ConflictPolicy = .lastWriterWinsByHLC)
}

public struct SyncManifest: Sendable, Codable {
    public let kitID: String
    public let schemaVersion: Int
    public let zoneIdentifier: String
    public let tables: [SyncedTable]
    public init(kitID: String, schemaVersion: Int, zoneIdentifier: String, tables: [SyncedTable])
    public func table(named name: String) -> SyncedTable?
}
```

**Rust:**

```rust
pub enum SyncDirection { Bidirectional, PushOnly, PullOnly }
pub enum ConflictPolicy { LastWriterWinsByHLC, AppendOnly, LocalWins, RemoteWins }

pub struct SyncedTable {
    pub name: String,
    pub direction: SyncDirection,           // serde default: Bidirectional
    pub primary_key_column: String,
    pub conflict_policy: ConflictPolicy,     // serde default: LastWriterWinsByHLC
}
impl SyncedTable {
    pub fn new(name: impl Into<String>, primary_key_column: impl Into<String>) -> Self;
    pub fn with_direction(self, direction: SyncDirection) -> Self;
    pub fn with_conflict_policy(self, policy: ConflictPolicy) -> Self;
}

pub struct SyncManifest {
    pub kit_id: String,
    pub schema_version: i32,
    pub zone_identifier: String,
    pub tables: Vec<SyncedTable>,
}
impl SyncManifest {
    pub fn new(kit_id: impl Into<String>, schema_version: i32,
               zone_identifier: impl Into<String>, tables: Vec<SyncedTable>) -> Self;
    pub fn table_named(&self, name: &str) -> Option<&SyncedTable>;
}
```

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

public struct SyncRecord: Sendable, Codable {
    public let table: String
    public let event: SyncEventKind
    public let rowKey: UUID
    public let values: SyncValueMap?
    public let hlc: PackedHLC
    public let schemaVersion: Int
    public let kitID: String
    public init(table: String, event: SyncEventKind, rowKey: UUID,
                values: SyncValueMap?, hlc: PackedHLC, schemaVersion: Int, kitID: String)
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

pub struct SyncRecord {
    pub table: String, pub event: SyncEventKind, pub row_key: Uuid,
    pub values: Option<SyncValueMap>, pub hlc: PackedHLC,
    pub schema_version: i32, pub kit_id: String,
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
    public init(containerIdentifier: String? = nil)
}

public enum CKRecordMapping {
    public static func recordType(kitID: String, table: String) -> String   // "kitID_table"
    public static func recordID(rowKey: UUID, zone: CKRecordZone.ID) -> CKRecord.ID
    public static func record(from values: [String: TypedValue], table: String,
        rowKey: UUID, hlc: HLC, schemaVersion: Int, kitID: String,
        zone: CKRecordZone.ID) throws -> CKRecord
    public static func decode(_ record: CKRecord) throws -> DecodedRecord
}

public struct DecodedRecord: Sendable {
    public let table: String
    public let rowKey: UUID
    public let values: [String: TypedValue]
    public let hlc: HLC
    public let schemaVersion: Int
    public let kitID: String
}
```

**Federation — `FederationSyncEngine`** (SPEC § 5, B-7; § 4 I-7, I-8):

```swift
public final class FederationSyncEngine: SyncEngine, Sendable {
    public init()
    public func pair(with peer: FederationSyncEngine, via relay: FederationRelay,
                     family: HyperplaneFamilySpec) async throws
    public var identity: LocalIdentity { get async }
}

public final class FederationRelay: @unchecked Sendable {
    public init()
    public func send(to recipient: Data, message: SignedMessage)
    public func drain(for recipient: Data) -> [SignedMessage]
}

public struct SignedMessage: Sendable, Codable {
    public let senderPublicKey: Data
    public let payload: Data            // JSON-encoded [SyncRecord]
    public let signature: Data          // Ed25519 over payload
    public let hlc: PackedHLC
    public init(senderPublicKey: Data, payload: Data, signature: Data, hlc: PackedHLC)
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
    pub fn new(identity: Arc<LocalIdentity>, relay: Arc<FederationRelay>) -> Self;
    pub fn peer_identity(&self) -> &PeerIdentity;
    /// Rust v1.0 outbox is explicit; observer-driven path is deferred (SPEC § 9).
    pub fn enqueue(&self, record: SyncRecord) -> SyncResult<()>;
}

pub struct FederationRelay { /* … */ }                         // also Default
impl FederationRelay {
    pub fn new() -> Self;
    pub fn register(&self, identity: PeerIdentity) -> std::sync::mpsc::Receiver<SignedRecord>;
    pub fn broadcast(&self, from: &PeerIdentity, envelope: SignedRecord);
}

pub struct SignedRecord {
    pub record: SyncRecord,
    pub signer: [u8; 32],
    pub signature: [u8; 64],
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
`tests/wire_format_tests.rs`.

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

// Federation: pair two estates over an in-process relay.
let a = FederationSyncEngine(), b = FederationSyncEngine()
let relay = FederationRelay()
try await a.pair(with: b, via: relay, family: HyperplaneFamilySpec(seed: 0x5EED))
```

---

*End of ConvergenceKit Interface v0.8.*
