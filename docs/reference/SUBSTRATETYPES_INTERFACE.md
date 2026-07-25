---
title: SubstrateTypes Interface
version: 1.4.0
status: active
date: 2026-07-16
description: Public API surface for SubstrateTypes in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
package: SubstrateTypes
languages: [swift, rust]
relates_to:
  - SUBSTRATETYPES_SPEC.md  (the contract this interface implements)
  - SUBSTRATEKERNEL_INTERFACE.md  (sibling: hot-path bit operations)
  - SUBSTRATEML_INTERFACE.md      (sibling: cold-path algorithms)
  - SUBSTRATELIB_INTERFACE.md     (umbrella: orchestration)
purpose: |
  Public API surface of SubstrateTypes in both ports. Twenty-nine
  Swift files publish the top-level types and eight algebra-
  primitive namespaces; the Rust mirror exposes the same shapes with
  Rust-idiomatic names. The companion SPEC carries the behavioral
  contracts (invariants and conformance vectors).
---

# SubstrateTypes Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateTypes/`

- `Sources/SubstrateTypes/` — 30 files, one per type family.
- `Tests/SubstrateTypesTests/` — unit + conformance tests.
- `Package.swift` — manifest. No dependencies on other substrate
  packages.

**Rust:** `packages/libs/SubstrateTypes/rust/`

- `src/lib.rs` — crate root, declares one `pub mod` per type family.
- `src/<family>.rs` — per-family module (`fingerprint256.rs`,
  `hlc.rs`, `audit_event.rs`, `gset.rs`, `row.rs`, `row_bitmaps.rs`,
  `row_state.rs`, `lattice_anchor.rs`, `noun_type.rs`, `matrix_*.rs`,
  `hyperplane.rs`, `block_mask.rs`, `simhash.rs`, `hamming.rs`,
  `or_reduce.rs`, `bitwise.rs`, `fnv.rs`, `count_vector.rs`,
  `bit_tensor.rs`, `time_range.rs`, `recall_types.rs`,
  `content_hash.rs`, `merkle_root.rs`, `snapshot_id.rs`,
  `as_of_coordinate.rs`, `merkle_domain.rs`,
  `float_simhash_planes.rs`).
- `tests/` — conformance tests, shared vectors.
- `Cargo.toml` — declares only `serde`, `serde_json`, `uuid`,
  standard library.

Naming differs by port convention (Swift `Hamming.distance` caseless-enum
namespace; Rust `hamming::distance` module free function); the *results*
are bit-for-bit identical (SPEC § 7, I-7).

## § 2 — Public types

### `Fingerprint256`

256-bit value type. SPEC § 5.1.

**Swift:**

```swift
public struct Fingerprint256: Hashable, Sendable, Codable {
    public var block0: UInt64
    public var block1: UInt64
    public var block2: UInt64
    public var block3: UInt64
    public init(block0: UInt64, block1: UInt64, block2: UInt64, block3: UInt64)
    public static let zero: Fingerprint256
    public var words: [UInt64] { get }                 // [block0, block1, block2, block3]
    public func bit(at index: Int) -> Bool
    public func testBit(at index: Int) -> Bool         // alias of bit(at:)
    public func with(bit index: Int, set on: Bool = true) -> Fingerprint256
    public func union(_ other: Fingerprint256) -> Fingerprint256
    public func block(at index: Int) -> UInt64
    public static func fromBits(_ bits: [Bool]) -> Fingerprint256
    public var wireBytes: [UInt8] { get }              // 32-byte LE wire format
    public init(wireBytes bytes: [UInt8]) throws       // throws on bad length
    public func toBytes() -> [UInt8]                   // == wireBytes
    public static func fromBytes(_ bytes: [UInt8]) -> Fingerprint256?
    public func popcount() -> Int
    // word-wise combinators (zip4 / reduce4 / map4 and *Batch variants)
}

public enum Fingerprint256Error: Error, Sendable {
    case invalidByteCount(expected: Int, got: Int)
}
```

**Rust:**

```rust
pub struct Fingerprint256 {
    pub block0: u64,
    pub block1: u64,
    pub block2: u64,
    pub block3: u64,
}
impl Fingerprint256 {
    pub const ZERO: Fingerprint256;
    pub const fn new(block0: u64, block1: u64, block2: u64, block3: u64) -> Self;
    pub fn bit(&self, index: usize) -> bool;
    pub fn block(&self, index: usize) -> u64;
    pub fn from_bits(bits: &[bool]) -> Self;
    pub fn wire_bytes(&self) -> [u8; 32];
    pub fn from_wire_bytes(bytes: &[u8]) -> Result<Self, Fingerprint256Error>;
    pub fn popcount(&self) -> u32;
    // word-wise combinators: zip4 / reduce4 / map4 (+ free fns zip4_batch / map4_batch)
}

pub enum Fingerprint256Error { /* invalid_byte_count(expected, got) */ }
```

### `HLC`, `HLCGenerator`

Hybrid Logical Clock. SPEC § 5.2.

**Swift:**

```swift
public struct HLC: Hashable, Sendable, Codable, Comparable {
    public let physicalTime: Int64   // milliseconds since Unix epoch
    public let logicalCount: Int32   // monotonic counter (cookbook §5.2)
    public let nodeID: Int32         // per-replica identifier
    public init(physicalTime: Int64, logicalCount: Int32, nodeID: Int32)
    public static func < (lhs: HLC, rhs: HLC) -> Bool
    public static let zero: HLC
    public var packed: UInt64 { get }             // 64-bit packed form (lossy: 40+16+8 bits)
    public init(packed: UInt64)
    public var wireBytes: [UInt8] { get }         // 16-byte LE wire format (lossless)
    public init(wireBytes bytes: [UInt8]) throws  // throws on bad length
    public func advanced() -> HLC                 // logical counter +1, physical/node unchanged
    public func physicalSecondsSinceEpoch() -> Int64  // physicalTime / 1000
    /// Compatibility alias: accepts `nodeId` (lowercase 'd') as a label;
    /// forwards to the canonical `nodeID` initializer.
    public init(physicalTime: Int64, logicalCount: Int32, nodeId: Int32)
}

public struct HLCGenerator: Sendable {
    public let nodeID: Int32
    public init(nodeID: Int32, lastPhysical: Int64 = 0, lastLogical: Int32 = 0)
    public mutating func send(now: Int64) -> HLC
    public mutating func receive(remote: HLC, now: Int64) -> HLC
    public func currentTime() -> HLC
}

public enum HLCError: Error, Sendable, Equatable {
    case invalidWireLength(Int)
}
```

**Rust:**

```rust
pub struct HLC { pub physical_time: i64, pub logical_count: i32, pub node_id: i32 }
impl HLC {
    pub const ZERO: HLC;
    pub const fn new(physical_time: i64, logical_count: i32, node_id: i32) -> Self;
    pub fn packed(self) -> u64;
    pub fn from_packed(packed: u64) -> Self;
    pub fn wire_bytes(&self) -> [u8; 16];
    pub fn from_wire_bytes(bytes: &[u8]) -> Result<Self, HLCError>;
    pub fn advanced(self) -> Self;                        // logical counter +1
    pub fn physical_seconds_since_epoch(self) -> i64;    // physical_time / 1000
    // Note: no `nodeId` alias in Rust (only Swift has it for back-compat).
}

pub struct HLCGenerator { pub node_id: i32, /* + internal last_physical/last_logical */ }
impl HLCGenerator {
    pub fn new(node_id: i32) -> Self;
    pub fn with_state(node_id: i32, last_physical: i64, last_logical: i32) -> Self;
    pub fn send(&mut self, now: i64) -> HLC;
    pub fn receive(&mut self, remote: &HLC, now: i64) -> HLC;
    pub fn current_time(&self) -> HLC;
}

pub enum HLCError { InvalidWireLength(usize) }
```

### `AuditEvent`

Single audit row, structured form. SPEC § 5.3.

**Swift:**

```swift
public struct AuditEvent: Sendable {
    public let eventID: UUID
    public let estateUuid: UUID
    public let rowId: UUID
    public let hlc: HLC
    public let verb: String
    public let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
    public let afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)
    public let beforeLatticeAnchor: LatticeAnchor?
    public let afterLatticeAnchor: LatticeAnchor
    public let actor: String
    /// Human-readable reason for the mutation; nil when the caller supplied none.
    /// Persisted as nullable TEXT in the `reason` column of `_storagekit_audit`.
    public let reason: String?
    public init(eventID: UUID = UUID(),
                estateUuid: UUID, rowId: UUID, hlc: HLC, verb: String,
                beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?,
                afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64),
                beforeLatticeAnchor: LatticeAnchor?,
                afterLatticeAnchor: LatticeAnchor,
                actor: String,
                reason: String? = nil)
    /// Return a copy of this event with the given reason set (or cleared).
    public func withReason(_ reason: String?) -> AuditEvent
}
```

The before/after bitmaps are carried inline as three-`Int64` tuples
(adjective, operational, provenance); the compound key (`eventID`,
`hlc`) gives append idempotence in PersistenceKit's AuditLog.
The `reason` field is nil for the vast majority of mutations; it is
non-nil only for expunge and explicit audit annotations where the
verb call site passes a caller-supplied rationale.

**Rust:**

```rust
pub struct AuditEvent {
    pub event_id: u128,
    pub estate_uuid: u128,
    pub row_id: RowId,
    pub hlc: HLC,
    pub verb: String,
    pub before_bitmaps: Option<(i64, i64, i64)>,
    pub after_bitmaps: (i64, i64, i64),
    pub before_lattice_anchor: Option<LatticeAnchor>,
    pub after_lattice_anchor: LatticeAnchor,
    pub actor: String,
    /// Human-readable reason for the mutation; None when the caller supplied none.
    /// Persisted as nullable TEXT in the `reason` column of `_storagekit_audit`.
    pub reason: Option<String>,
}
```

### `GSetAuditLog`, `AuditEntry`, `AuditVerb`, `AuditValue`

G-Set audit log CRDT plus entry shape. SPEC § 5.3.

**Swift:**

```swift
public struct AuditEntry: Hashable, Sendable, Codable {
    public let id: [UInt8]                  // 32-byte SHA-256 content hash
    public let hlc: HLC
    public let verb: AuditVerb
    public let rowID: UUID
    public let fieldPath: String            // e.g. "adjective.state"
    public let beforeValue: AuditValue?     // nil at capture boundaries
    public let afterValue: AuditValue?      // nil at retract boundaries
    public let originRowID: UUID?           // for derived mutations
    public init(id: [UInt8], hlc: HLC, verb: AuditVerb,
                rowID: UUID, fieldPath: String,
                beforeValue: AuditValue?, afterValue: AuditValue?,
                originRowID: UUID? = nil)
}

public enum AuditVerb: String, Sendable, Codable {
    case capture, mutate, retract, sync, pair, unpair
    case derive, decay, promote
    case migrate            // schema migration (cookbook § 16)
    case dreamCompact       // dreaming-daemon § 15 compaction
}

public enum AuditValue: Hashable, Sendable, Codable {
    case bitmap(UInt64)
    case string(String)
    case fingerprint(Fingerprint256)
    case integer(Int64)
    // Custom Codable emits externally-tagged camelCase JSON to match
    // Rust serde; absence is represented by Optional<AuditValue> at the
    // AuditEntry level rather than an in-enum null case.
}

public struct GSetAuditLog: Sendable, Codable {
    private(set) public var entries: [[UInt8]: AuditEntry]  // keyed by content hash
    public init(entries: [AuditEntry] = [])
    public mutating func add(_ entry: AuditEntry)
    public mutating func merge(_ other: GSetAuditLog)
    public var count: Int { get }
    public var orderedEntries: [AuditEntry] { get }         // sorted by id byte-lex
    public func entries(forRow rowID: UUID) -> [AuditEntry]
    public func entries(since cutoff: HLC) -> [AuditEntry]
}
```

**Rust:**

```rust
pub struct AuditEntry {
    pub id: [u8; 32],
    pub hlc: HLC,
    pub verb: AuditVerb,
    pub row_id: RowID,
    pub field_path: String,
    pub before_value: Option<AuditValue>,
    pub after_value: Option<AuditValue>,
    pub origin_row_id: Option<RowID>,
}
pub enum AuditVerb { Capture, Mutate, Retract, Sync, Pair, Unpair, Derive, Decay, Promote, Migrate, DreamCompact }
pub enum AuditValue { Bitmap(u64), String(String), Fingerprint(Fingerprint256), Integer(i64) }
pub struct GSetAuditLog { /* HashMap<[u8;32], AuditEntry> */ }
impl GSetAuditLog {
    pub fn new() -> Self;
    pub fn from_entries(entries: Vec<AuditEntry>) -> Self;
    pub fn add(&mut self, entry: AuditEntry);
    pub fn merge(&mut self, other: &Self);
    pub fn len(&self) -> usize;
    pub fn ordered_entries(&self) -> Vec<AuditEntry>;          // sorted by id byte-lex
    pub fn entries_for_row(&self, row_id: RowID) -> Vec<AuditEntry>;
    pub fn entries_since(&self, cutoff: &HLC) -> Vec<AuditEntry>;
}
```

### `Row`, `RowId`, `RowBitmaps`, `BitVector216`

Row identity + bitmap carriers. SPEC § 5.4.

**Swift:**

```swift
public typealias RowId = UUID

public struct Row: Sendable {
    public let id: UUID
    public let nounType: NounType
    public var state: RowState              // see § 9.1
    public var adjectiveBitmap: Int64
    public var operationalBitmap: Int64
    public var provenanceBitmap: Int64
    public var fingerprint: Fingerprint256
    public var latticeAnchor: LatticeAnchor
    public var lineageId: UUID?
    public var content: Data?
    public init(id: UUID, nounType: NounType, state: RowState, /* …all fields… */)
}

public struct RowBitmaps: Sendable, Hashable, Codable {
    public static let fieldCount      = 36
    public static let bitsPerField    = 6
    public static let bitmapsCount    = 3
    public static let fieldsPerBitmap = 12          // 36 / 3
    public static let totalBits       = 216         // 36 * 6
    public static let fieldValueMask: Int64 = 0x3F  // (1 << 6) - 1
    public let adjective:   Int64                   // 12 packed 6-bit fields
    public let operational: Int64
    public let provenance:  Int64
    public init(adjective: Int64, operational: Int64, provenance: Int64)
    public static let zero: RowBitmaps
    public func field(_ idx: Int) -> UInt8          // 6-bit value of field idx
    public func bit(field fieldIdx: Int, bit: Int) -> Bool
    public func fieldValues() -> [(field: UInt8, value: UInt8)]
    public func bitVector() -> BitVector216
}

public struct BitVector216: Sendable, Hashable {
    public static let bitCount  = RowBitmaps.totalBits   // 216
    public static let byteCount = (bitCount + 7) / 8      // 27 bytes
    public init(rowBitmaps: RowBitmaps)
    public init(presenceBytes: [UInt8])
    public func bit(at index: Int) -> Bool
    public func bit(field: Int, bit: Int) -> Bool
}
```

**Rust:**

```rust
pub struct RowBitmaps {
    pub adjective:   i64,
    pub operational: i64,
    pub provenance:  i64,
}
impl RowBitmaps {
    pub const FIELD_COUNT: usize = 36;
    pub const BITS_PER_FIELD: usize = 6;
    pub const FIELDS_PER_BITMAP: usize = 12;
    pub const TOTAL_BITS: usize = 216;
    pub const FIELD_VALUE_MASK: i64 = 0x3F;
    pub const ZERO: RowBitmaps;
    pub fn new(adjective: i64, operational: i64, provenance: i64) -> Self;
    pub fn field(&self, idx: usize) -> u8;       // 6-bit value of field idx
    pub fn bit(&self, field_idx: usize, bit: usize) -> bool;
    pub fn field_values(&self) -> Vec<(u8, u8)>; // all 36 (field, value) pairs
    pub fn bit_vector(&self) -> BitVector216;
}

pub struct BitVector216 {
    // 27 bytes = 216 bits, packed LSB-first
}
impl BitVector216 {
    pub const BIT_COUNT: usize = 216;
    pub const BYTE_COUNT: usize = 27;
    pub fn from_row_bitmaps(rb: &RowBitmaps) -> Self;
    pub fn from_presence_bytes(presence_bytes: &[u8]) -> Self; // panics if len != 27
    pub fn as_bytes(&self) -> &[u8; 27];
    pub fn bit_at(&self, index: usize) -> bool;
    pub fn bit(&self, field: usize, bit: usize) -> bool;
}
```

`RowId(u128)` and `Row` — same shape as documented above, snake_case fields.

### `RowState`, `RowStateCluster`, `RowVerb`, `RowStateError`

Row lifecycle enumerations. SPEC § 5.4.

**Swift:**

```swift
public enum RowState: UInt8, Sendable, Codable, CaseIterable {
    // Cluster A (active / becoming): raw 0–3
    case active = 0, pending = 1, contested = 2, accepted = 3
    // Cluster B (superseded / historical): raw 16–19
    case superseded = 16, decayed = 17, withdrawn = 18, expired = 19
    // Cluster C (terminal): raw 32–33
    case rejected = 32, tombstoned = 33

    // Lifecycle cluster helpers (canonical partition; consumers must not
    // re-derive cluster membership from raw-value magic numbers).
    public static let activeClusterUpperBoundRaw: UInt8   // == superseded.rawValue (16)
    public var cluster: RowStateCluster { get }           // shift-and-mask (raw >> 4) & 0x3
    public var isActiveCluster: Bool { get }              // cluster == .a
    public static func cluster(ofRawState raw: UInt8) -> RowStateCluster?  // nil if undefined raw

    // CustomStringConvertible (lowercase English, matching RowVerb.rawValue casing)
    public var description: String { get }
}

/// Groups RowState cases into lifecycle bands: A (active), B (historical), C (terminal).
public enum RowStateCluster: UInt8, Sendable, Codable, CaseIterable {
    case a = 0   // active / becoming
    case b = 1   // superseded / historical — retired, revivable
    case c = 2   // terminal — retired, non-revivable
    public var isActive: Bool { self == .a }
}

public enum RowVerb: String, Sendable, Codable, CaseIterable {
    case capture, observe, mutate, retract, promote, reject
    case supersede, decay, expire, contest, resolveContest, tombstone
}

public enum RowStateError: Error, Sendable, Equatable {
    case illegalTransition(RowState, RowVerb)
    case violatesInvariant(String)
    // CustomStringConvertible — produces "active --reject-->" style tokens
    // that the AriaMcpKit describe_gate_rejection parser expects.
    public var description: String { get }
}
```

**Rust:** `RowState` (`repr(u8)`, same ordinals) with these additional
`impl` members (parity with Swift helpers, plus one Rust-only):

```rust
impl RowState {
    pub const ACTIVE_CLUSTER_UPPER_BOUND_RAW: u8; // == Superseded as u8 (16)
    pub fn from_raw(raw: u8) -> Option<Self>;     // Rust only; Swift uses CaseIterable init
    pub fn cluster(self) -> RowStateCluster;
    pub fn is_active_cluster(self) -> bool;
    pub fn cluster_of_raw_state(raw: u8) -> Option<RowStateCluster>;
}
```

`RowStateCluster` (`A`/`B`/`C` PascalCase variants, same ordinals) with
`is_active(self) -> bool` (Rust spelling of Swift `.isActive`).
`RowVerb` (`PascalCase` variants, same 12-case set) with `token(&self) ->
&'static str` (Rust-only — returns the lowercase English verb string
matching Swift's `rawValue`; used for content-ID hashing parity with M8).
`RowStateError` (`IllegalTransition` / `ViolatesInvariant`) — same shapes.

### `NounType`

Eight noun categories. SPEC § 5 (background); cookbook §2.1.

**Swift:**

```swift
public enum NounType: UInt8, Sendable {
    case drawer = 0
    case tunnel = 1
    case kgFact = 2
    case diaryEntry = 3
    case proposal = 4
    case association = 5
    case learnedReference = 6
    case ambientSample = 7
}
```

**Rust:** `pub enum NounType { Drawer, Tunnel, KgFact, DiaryEntry,
Proposal, Association, LearnedReference, AmbientSample }` with
`repr(u8)`, same ordinals.

### `LatticeAnchor`

Cookbook §2.7 anchor reference. SPEC § 5.5.

**Swift:**

```swift
public struct LatticeAnchor: Hashable, Sendable {
    public let udcCode: UInt64          // packed UDC code
    public let qidPointer: UInt64       // 0 indicates null
    public init(udcCode: UInt64, qidPointer: UInt64 = 0)
    public var isNull: Bool { get }
    public static func udc(_ udcString: String) -> LatticeAnchor
    public static func udcQid(_ udcString: String, qid qidString: String) -> LatticeAnchor
}
```

**Rust:**

```rust
pub struct LatticeAnchor { pub udc_code: u64, pub qid_pointer: u64 }   // qid_pointer 0 = null
impl LatticeAnchor {
    pub fn new(udc_code: u64, qid_pointer: u64) -> Self;
    pub fn udc(udc_string: &str) -> Self;
    pub fn udc_qid(udc_string: &str, qid_string: &str) -> Self;
    pub fn is_null(&self) -> bool;
    pub fn fnv1a64(s: &str) -> u64;  // Rust-only helper; Swift callers use FNV.hash64(_:)
}
```

### `MatrixF`, `MatrixC`, `MatrixO`, `MatrixT`

The four matrix carriers. SPEC § 5.6.

**Swift:**

```swift
// Field-presence matrix F (cookbook § 6.1): flat 36×6 = 216 Int64 cells.
public struct MatrixF: Sendable, Equatable {
    public static let fieldCount = RowBitmaps.fieldCount     // 36
    public static let bitsPerField = RowBitmaps.bitsPerField // 6
    public static let cellCount = RowBitmaps.totalBits       // 216
    public private(set) var cells: [Int64]                   // cells[field*6 + bit]
    public init()
    public init(cells: [Int64])                              // count must == 216
    public subscript(field: Int, bit: Int) -> Int64 { get }
}

// Confidence matrix C (cookbook § 6.2): 216 Float cells derived from F.
public struct MatrixC: Sendable, Equatable {
    public private(set) var cells: [Float]
    public init()
    public init(cells: [Float])
}

// Cooccurrence key: a pair of (field, value) coordinates.
public struct CooccurrenceKey: Hashable, Comparable, Sendable {
    public let fieldI: UInt8
    public let valueI: UInt8
    public let fieldJ: UInt8
    public let valueJ: UInt8
    public var packed: UInt32 { get }
}
// Cooccurrence matrix O: sorted sparse list of non-zero cells.
public struct MatrixO: Sendable, Equatable {
    public private(set) var entries: [(key: CooccurrenceKey, count: Int64)]
    public init()
    public init(entries: [(key: CooccurrenceKey, count: Int64)])
}

// Causality key: directed (source → target) (field, value) pair plus lag bucket.
public struct CausalityKey: Hashable, Comparable, Sendable {
    public let sourceField: UInt8
    public let sourceValue: UInt8
    public let targetField: UInt8
    public let targetValue: UInt8
    public let lagBucket: UInt8          // 0..7
    public var packed: UInt64 { get }
}
// Causality matrix T: sorted sparse list of non-zero cells.
public struct MatrixT: Sendable, Equatable {
    public private(set) var entries: [(key: CausalityKey, count: Int64)]
    public init()
    public init(entries: [(key: CausalityKey, count: Int64)])
}
```

**Rust:** equivalent shapes with snake_case fields. `MatrixF`/`MatrixC`
carry flat `Vec<i64>`/`Vec<f32>` cells; `MatrixO`/`MatrixT` carry sorted
sparse entry lists keyed by `CooccurrenceKey`/`CausalityKey` (same
`field_i`/`value_i`/… and `source_field`/…/`lag_bucket` fields).

### `RecallScore`, `DistanceBreakdown`, `RecallResult`, `RowProjection`

Recall vocabulary for ranking primitives and federation wire types.
Both the Swift and Rust ports carry these types from this package.

**Swift** (authoritative — `Sources/SubstrateTypes/RecallTypes.swift`):

```swift
public struct RecallScore: Equatable, Sendable {
    public let rowId: RowId
    public let score: Float32
    public init(rowId: RowId, score: Float32)
}
public struct DistanceBreakdown: Equatable, Sendable {
    public var latticeContribution: Float32
    public var fingerprintContribution: Float32
    public var temporalContribution: Float32
    public var bitmapContribution: Float32
    public init(lattice: Float32 = 0, fingerprint: Float32 = 0,
                temporal: Float32 = 0, bitmap: Float32 = 0)
}
public struct RecallResult: Sendable {
    public let rows: [RecallScore]
    public let breakdown: DistanceBreakdown
    public let confidenceInterval: (lower: Float32, upper: Float32)?
    public let primitiveName: String
    public init(rows: [RecallScore], breakdown: DistanceBreakdown = DistanceBreakdown(),
                confidenceInterval: (Float32, Float32)? = nil, primitiveName: String)
}
public struct RowProjection: Sendable {
    public let rowId: RowId
    public let captureHLC: HLC
    public let fingerprint: Fingerprint256
    public let lattice: LatticeAnchor
    public let bitmaps: (adjective: UInt64, operational: UInt64, provenance: UInt64)
    public let rowState: UInt8
    public init(rowId: RowId, captureHLC: HLC, fingerprint: Fingerprint256,
                lattice: LatticeAnchor, bitmaps: (UInt64, UInt64, UInt64), rowState: UInt8)
}
```

**Rust** (`src/recall_types.rs`, re-exported from crate root):

```rust
pub struct RecallScore {
    pub row_id: RowId,
    pub score: f32,
}
impl RecallScore {
    pub fn new(row_id: RowId, score: f32) -> Self;
}

pub struct DistanceBreakdown {
    pub lattice_contribution: f32,
    pub fingerprint_contribution: f32,
    pub temporal_contribution: f32,
    pub bitmap_contribution: f32,
}
impl DistanceBreakdown {
    pub const ZERO: DistanceBreakdown;
    pub fn new(lattice: f32, fingerprint: f32, temporal: f32, bitmap: f32) -> Self;
}
impl Default for DistanceBreakdown { /* returns ZERO */ }

pub struct RecallResult {
    pub rows: Vec<RecallScore>,
    pub breakdown: DistanceBreakdown,
    pub confidence_interval: Option<(f32, f32)>,
    pub primitive_name: String,
}
impl RecallResult {
    pub fn new(rows, breakdown, confidence_interval, primitive_name) -> Self;
    pub fn simple(rows, primitive_name) -> Self; // ZERO breakdown, no CI
}

pub struct RowProjection {
    pub row_id: RowId,
    pub capture_hlc: HLC,
    pub fingerprint: Fingerprint256,
    pub lattice: LatticeAnchor,
    pub bitmaps: (u64, u64, u64),   // (adjective, operational, provenance)
    pub row_state: u8,
}
impl RowProjection {
    pub fn new(row_id, capture_hlc, fingerprint, lattice, bitmaps, row_state) -> Self;
}
```

### `ThreeDBitTensor`

Three-D bit tensor. Cookbook §6.7. SPEC § 5 (background).

**Swift:**

```swift
// Bit-sliced N-row × 36-field × 6-bit tensor (cookbook § 6.7).
public struct ThreeDBitTensor: Sendable {
    public static let fieldCount = 36
    public static let bitsPerField = 6
    public var slices: [[UInt8]]                  // 6 bit-slices, one per bit position
    public init(rowCount: Int)
    public func valueAt(row: Int, field: Int) -> UInt8
    public mutating func setValue(row: Int, field: Int, value: UInt8)
    public func bitSet(row: Int, field: Int, bit: Int) -> Bool
    public mutating func setBit(row: Int, field: Int, bit: Int, on: Bool)
    public func scanFieldEquals(field: Int, value: UInt8) -> [UInt8]
    public func enumerateMatches(_ mask: [UInt8]) -> [Int]
    public mutating func reserveCapacity(_ newRowCount: Int)
    public var byteSize: Int { get }
}
```

**Rust:** same shape — `row_count: usize`, `slices: Vec<Vec<u8>>`,
`new(row_count)`, `value_at`/`set_value`/`bit_set`/`set_bit`,
`scan_field_equals`/`enumerate_matches`/`reserve_capacity`/`byte_size`.

### `TimeRange`

Closed HLC interval. SPEC § 5 (background).

**Swift:**

```swift
public struct TimeRange: Sendable, Equatable {
    public let start: HLC
    public let end: HLC                // inclusive
    public init(start: HLC, end: HLC)
    public func contains(_ hlc: HLC) -> Bool
}
```

**Rust:** same shape — `start`/`end: HLC`, `new(start, end)`,
`contains(&self, hlc: HLC) -> bool`.

### `CountVector256`

256-element count vector for fingerprint aggregation. SPEC § 5
(background).

**Swift:**

```swift
public struct CountVector256: Sendable, Equatable, Codable {
    public private(set) var counts: [UInt32]   // exactly 256 per-bit set counts
    public private(set) var n: UInt32          // number of source fingerprints folded
    public static let zero: CountVector256
    public init()
    public init(counts: [UInt32], n: UInt32)
    public mutating func accumulate(_ fingerprint: Fingerprint256)
    public mutating func merge(_ other: CountVector256)
    public static func + (lhs: CountVector256, rhs: CountVector256) -> CountVector256
    public func majorityVote() -> Fingerprint256
    public func profile() -> [Float]
    public static func fold(_ fingerprints: [Fingerprint256]) -> CountVector256
}
```

**Rust:** same shape — `counts: Vec<u32>` (256), `n: u32`, plus
`accumulate`/`merge`/`majority_vote`/`profile`/`fold`.

### `BlockMask`

Per-block fingerprint slicing mask. SPEC § 5 (background).

**Swift:**

```swift
public struct BlockMask: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let block0: BlockMask   // 0b0001
    public static let block1: BlockMask   // 0b0010
    public static let block2: BlockMask   // 0b0100
    public static let block3: BlockMask   // 0b1000
    public static let all:  BlockMask     // [block0, block1, block2, block3]
    public static let none: BlockMask     // []
    public var blockCount: Int { get }
}
```

**Rust** (`src/block_mask.rs`, re-exported from crate root):

```rust
#[repr(transparent)]
pub struct BlockMask(pub u8);
impl BlockMask {
    pub const BLOCK0: BlockMask;   // 0b0001
    pub const BLOCK1: BlockMask;   // 0b0010
    pub const BLOCK2: BlockMask;   // 0b0100
    pub const BLOCK3: BlockMask;   // 0b1000
    pub const ALL: BlockMask;      // 0b1111
    pub const NONE: BlockMask;     // 0b0000
    pub fn bits(self) -> u8;
    pub fn block_count(self) -> u32;
    pub fn contains(self, other: BlockMask) -> bool;
    pub fn union(self, other: BlockMask) -> BlockMask;
    pub fn intersection(self, other: BlockMask) -> BlockMask;
    pub fn is_empty(self) -> bool;
}
// Implements: BitOr, BitAnd, BitOrAssign, BitAndAssign, Default (= NONE)
```

### `Hyperplane`, `HyperplaneFamily`

Hyperplane family for SimHash projections. Cookbook §17. SPEC §5
(background).

**Swift:**

```swift
public struct Hyperplane: Sendable, Codable, Equatable {
    public let positiveMask: [UInt64]
    public let negativeMask: [UInt64]
    public let bitLength: Int
    public init(positiveMask: [UInt64], negativeMask: [UInt64], bitLength: Int)
    public func sign(over v: [UInt64]) -> Bool
}
public struct HyperplaneFamily: Sendable, Codable, Equatable {
    public let blockIndex: Int          // 0, 1, 2, or 3
    public let inputBitLength: Int      // 192 for block 0, 64 for blocks 1–3
    public let planes: [Hyperplane]     // exactly 64 planes
    public init(blockIndex: Int, inputBitLength: Int, planes: [Hyperplane])
    public static func generate(seed: [UInt8], /* … */) -> HyperplaneFamily
    public func canonicalHash() -> UInt64
}
```

**Rust:** same shape — `Hyperplane { positive_mask: Vec<u64>,
negative_mask: Vec<u64>, bit_length: usize }` with `sign`;
`HyperplaneFamily { block_index, input_bit_length, planes }` with
`generate`/`canonical_hash`.

### `FloatSimHashPlanes`

Materialized ±1 hyperplane set for the float-input SimHash projection.
Lives in SubstrateTypes (the lowest layer) so both consumers reach it
without a layering inversion: `SubstrateKernel.floatSimHashProject`
applies it (no RNG), and `SubstrateML.FloatSimHash` generates it from a
seed. SUBSTRATEKERNEL_SPEC § 5.4.

**Swift** (`Sources/SubstrateTypes/FloatSimHashPlanes.swift`):

```swift
/// A materialized ±1 hyperplane set for `SubstrateKernel.floatSimHashProject`.
/// `signBits` packs `256 * dim` bits (row-major: hyperplane outer,
/// coordinate inner). A set bit means plane sign +1; a clear bit means -1.
public struct FloatSimHashPlanes: Sendable, Equatable {
    public let dim: Int          // dimensionality; must equal the projected vector's length
    public let signBits: [UInt64] // ceil(256 * dim / 64) words; bit k*dim+i ↔ plane k, coord i
    public init(dim: Int, signBits: [UInt64])
}
```

**Rust** (`rust/src/float_simhash_planes.rs`, re-exported from crate root):

```rust
pub struct FloatSimHashPlanes {
    pub dim: usize,
    pub sign_bits: Vec<u64>,  // ceil(256 * dim / 64) words
}
impl FloatSimHashPlanes {
    pub fn new(dim: usize, sign_bits: Vec<u64>) -> Self;
}
```

Shape is identical across ports. The planes are seed-immutable; callers
materialize them once per `(seed, dim)` and reuse them across every
projection under that seed. Generation lives in `SubstrateML.FloatSimHash`.

### `ContentHash`

Typed 32-byte SHA-256 leaf digest. SPEC § 5.8. the node-integrity contract §16.

**Swift:**

```swift
public struct ContentHash: Hashable, Sendable, Codable, CustomStringConvertible {
    public init(bytes: [UInt8])            // exactly 32 bytes
    public var bytes: [UInt8] { get }
    public static let tombstone: ContentHash   // SHA-256([0x02])
    public var hexString: String { get }
    public var description: String { get }     // == hexString
}

public enum ContentHashError: Error, Sendable {
    case invalidHexLength(Int)
    case invalidHexCharacter
}
```

**Rust:**

```rust
pub struct ContentHash { /* [u8; 32] */ }
impl ContentHash {
    pub const fn new(bytes: [u8; 32]) -> Self;
    pub const fn bytes(&self) -> &[u8; 32];
    pub const TOMBSTONE: ContentHash;           // SHA-256([0x02])
    pub fn hex_string(&self) -> String;
    pub fn from_hex(hex: &str) -> Result<Self, ContentHashError>;
}

pub enum ContentHashError { InvalidHexLength(usize), InvalidHexCharacter }
```

### `MerkleRoot`

Typed 32-byte subtree root hash. SPEC § 5.9. the node-integrity contract §16.

**Swift:**

```swift
public struct MerkleRoot: Hashable, Sendable, Codable, CustomStringConvertible {
    public init(bytes: [UInt8])            // exactly 32 bytes
    public var bytes: [UInt8] { get }
    public static let empty: MerkleRoot    // SHA-256([0x01])
    public var hexString: String { get }
    public var description: String { get }
}

public enum MerkleRootError: Error, Sendable {
    case invalidHexLength(Int)
    case invalidHexCharacter
}
```

**Rust:**

```rust
pub struct MerkleRoot { /* [u8; 32] */ }
impl MerkleRoot {
    pub const fn new(bytes: [u8; 32]) -> Self;
    pub const fn bytes(&self) -> &[u8; 32];
    pub const EMPTY: MerkleRoot;                // SHA-256([0x01])
    pub fn hex_string(&self) -> String;
    pub fn from_hex(hex: &str) -> Result<Self, MerkleRootError>;
}

pub enum MerkleRootError { InvalidHexLength(usize), InvalidHexCharacter }
```

### `SnapshotId`

Typed UUID wrapper for snapshot identifiers. SPEC § 5.10. the node-integrity contract §15.

**Swift:**

```swift
public struct SnapshotId: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID
    public init(_ uuid: UUID)
    public init()                              // random
    public init?(uuidString: String)
    public var uuidString: String { get }
    public var description: String { get }     // == uuidString
}

public enum SnapshotIdError: Error, Sendable {
    case invalidUUID(String)
}
```

**Rust:**

```rust
pub struct SnapshotId { /* [u8; 16] */ }
impl SnapshotId {
    pub const fn from_bytes(bytes: [u8; 16]) -> Self;
    pub const fn bytes(&self) -> &[u8; 16];
    pub fn from_uuid_string(s: &str) -> Result<Self, SnapshotIdError>;
    pub fn uuid_string(&self) -> String;
}

pub enum SnapshotIdError { InvalidUUID(String) }
```

### `AsOfCoordinate`

Temporal query coordinate. SPEC § 5.11. the node-integrity contract §15–§17.

**Swift:**

```swift
public enum AsOfCoordinate: Hashable, Sendable, Codable {
    case present
    case asOf(HLC)
}
```

**Rust:**

```rust
pub enum AsOfCoordinate {
    Present,
    AsOf(HLC),
}
```

Serialized as `{"kind":"present"}` or `{"kind":"asOf","hlc":{...}}` in
both ports.

### `MerkleDomain`

Frozen domain-separation tag constants. SPEC § 5.12. the node-integrity contract §16.

**Swift:**

```swift
public enum MerkleDomain {
    public static let leaf: UInt8       // 0x00
    public static let interior: UInt8   // 0x01
    public static let tombstone: UInt8  // 0x02
    public static let commitment: UInt8 // 0x03
}
```

**Rust:**

```rust
pub struct MerkleDomain;
impl MerkleDomain {
    pub const LEAF: u8;       // 0x00
    pub const INTERIOR: u8;   // 0x01
    pub const TOMBSTONE: u8;  // 0x02
    pub const COMMITMENT: u8; // 0x03
}
```

## § 3 — Public functions (algebra primitives)

### `Hamming`

Bit-difference count and similarity between two fingerprints.
SPEC § 5.7. Per-block selection via `BlockMask`.

**Swift** (`Sources/SubstrateTypes/Hamming.swift`):

```swift
public enum Hamming {
    /// Distance in [0, 64 * blocks.blockCount]. Defaults to all 4 blocks.
    public static func distance(_ a: Fingerprint256, _ b: Fingerprint256,
                                blocks: BlockMask = .all) -> Int
    /// Similarity in [0.0, 1.0]. 1.0 = identical, 0.0 = maximally distant.
    public static func similarity(_ a: Fingerprint256, _ b: Fingerprint256,
                                  blocks: BlockMask = .all) -> Double
}
public typealias HammingDistance = Hamming
```

**Rust** (`src/hamming.rs`):

```rust
/// Distance in [0, 64 * blocks.count_ones()]. Pass ALL_BLOCKS (0b1111)
/// for the full 256-bit distance. `blocks` accepts raw u8 or
/// `BlockMask::bits()` — same bit-pattern.
pub fn distance(a: &Fingerprint256, b: &Fingerprint256, blocks: u8) -> u32;
/// Similarity in [0.0, 1.0]. 1.0 = identical, 0.0 = maximally distant.
pub fn similarity(a: &Fingerprint256, b: &Fingerprint256, blocks: u8) -> f64;
```

### `SimHash`

SimHash signing of a feature set against a hyperplane family. SPEC
§ 5.7.

**Swift:**

```swift
// Caseless-enum namespaces (not data enums).
public enum SimHash {
    public static func block(over v: [UInt64], family: HyperplaneFamily) -> UInt64
    public static func fingerprint(bitmapInput: [UInt64], /* …per-block families… */) -> Fingerprint256
    public static func fingerprintBatch(bitmapInputs: [[UInt64]], /* … */) -> [Fingerprint256]
    public static func fingerprint(fromSubhashes subhashes: [UInt64], /* … */) -> Fingerprint256
}
public enum SimHashInput {
    public static func bitmap(adjective: UInt64, operational: UInt64, provenance: UInt64) -> [UInt64]
    public static func lattice(udcPrefixHash: UInt16, /* … */) -> [UInt64]
    public static func lineageTemporal(lineageHash: UInt16, /* … */) -> [UInt64]
    public static func channelSource(channel: UInt8, /* … */) -> [UInt64]
}
```

**Rust** (`src/simhash.rs`, module free functions):

```rust
pub fn block(v: &[u64], family: &HyperplaneFamily) -> u64;
pub fn fingerprint(/* per-block inputs + families */) -> Fingerprint256;
pub fn fingerprint_batch(/* … */) -> Vec<Fingerprint256>;
pub fn fingerprint_from_subhashes(/* … */) -> Fingerprint256;
// input builders, one per block:
pub fn bitmap_input(adjective: u64, operational: u64, provenance: u64) -> Vec<u64>;
pub fn lattice_input(udc_prefix_hash: u16, qid_direct_hash: u16, /* … */) -> Vec<u64>;
pub fn lineage_temporal_input(/* … */) -> Vec<u64>;
pub fn channel_source_input(/* … */) -> Vec<u64>;
```

### `ORReduce`

Bitwise OR-reduce across a set of fingerprints. SPEC § 5.7.

**Swift:**

```swift
public enum ORReduce {
    public static func reduce<S: Sequence>(_ fingerprints: S) -> Fingerprint256
        where S.Element == Fingerprint256
    public static func reduce<S: Sequence>(_ fingerprints: S, blocks: BlockMask) -> Fingerprint256
        where S.Element == Fingerprint256
}
```

**Rust** (`src/or_reduce.rs`, module free functions):

```rust
pub fn reduce<I: IntoIterator<Item = Fingerprint256>>(fingerprints: I) -> Fingerprint256;
pub fn reduce_blocks<I: IntoIterator<Item = Fingerprint256>>(fingerprints: I, blocks: u8) -> Fingerprint256;
```

### `BitwiseArithmetic`, `FingerprintBuilder`

Fingerprint set algebra (AND / set-difference / weighted-majority
prototype) plus a composable builder ADT. SPEC § 5.7.

**Swift:**

```swift
public enum BitwiseArithmetic {
    public static func intersect(_ a: Fingerprint256, _ b: Fingerprint256) -> Fingerprint256
    public static func difference(_ a: Fingerprint256, _ b: Fingerprint256) -> Fingerprint256
    public static func prototype<S: Sequence>(_ cohort: S) -> Fingerprint256
        where S.Element == Fingerprint256
}

public indirect enum FingerprintBuilder: Sendable {
    case literal(Fingerprint256)
    case intersect(FingerprintBuilder, FingerprintBuilder)
    case difference(FingerprintBuilder, FingerprintBuilder)
    case prototypeOf([Fingerprint256])
    public func evaluate() -> Fingerprint256
}
```

**Rust** (`src/bitwise.rs`, module free functions + ADT):

```rust
pub fn intersect(a: &Fingerprint256, b: &Fingerprint256) -> Fingerprint256;
pub fn difference(a: &Fingerprint256, b: &Fingerprint256) -> Fingerprint256;
pub fn prototype<I: IntoIterator<Item = Fingerprint256>>(cohort: I) -> Fingerprint256;

pub enum FingerprintBuilder {
    Literal(Fingerprint256),
    Intersect(Box<FingerprintBuilder>, Box<FingerprintBuilder>),
    Difference(Box<FingerprintBuilder>, Box<FingerprintBuilder>),
    PrototypeOf(Vec<Fingerprint256>),
}
impl FingerprintBuilder { pub fn evaluate(&self) -> Fingerprint256; }
```

### `FNV`

FNV-1a hash. SPEC § 5.7.

**Swift:**

```swift
public enum FNV {
    public static func hash64(_ s: String) -> UInt64
    public static func hash32(_ s: String) -> UInt32
    public static func hash16(_ s: String) -> UInt16
}
```

**Rust** (`src/fnv.rs`, module free functions):

```rust
pub fn hash64(s: &str) -> u64;
pub fn hash32(s: &str) -> u32;
pub fn hash16(s: &str) -> u16;
```

## § 4 — Errors

The package raises only these errors:

| Error | Raised by | Cause |
|---|---|---|
| `Fingerprint256Error.invalidByteCount(expected: 32, got: N)` | `Fingerprint256(wireBytes:)` | byte input is not 32 bytes |
| `HLCError.invalidWireLength(Int)` | `HLC.init(wireBytes:)` / Rust `from_wire_bytes` | wire byte buffer was not the required 16-byte length |
| `RowStateError.illegalTransition(RowState, RowVerb)` | `RowStateAutomaton.validate` (in SubstrateLib; the enum lives here) | the (prior state, verb) pair is absent from the transition table |
| `RowStateError.violatesInvariant(String)` | `RowStateAutomaton.validate` (in SubstrateLib) | resulting bitmap violates a schema invariant (e.g. I-22) |
| `ContentHashError.invalidHexLength(Int)` | `ContentHash(from:)` / Rust `from_hex` | hex string is not 64 characters |
| `ContentHashError.invalidHexCharacter` | `ContentHash(from:)` / Rust `from_hex` | non-hex character in input |
| `MerkleRootError.invalidHexLength(Int)` | `MerkleRoot(from:)` / Rust `from_hex` | hex string is not 64 characters |
| `MerkleRootError.invalidHexCharacter` | `MerkleRoot(from:)` / Rust `from_hex` | non-hex character in input |
| `SnapshotIdError.invalidUUID(String)` | `SnapshotId(from:)` / Rust `from_uuid_string` | input is not a valid UUID string |

## § 5 — Conformance test entry points

Per SPEC § 7, every algebra primitive is conformance-gated against
shared vectors. Test entry points:

- **Swift:** `Tests/SubstrateTypesTests/`
  - `Fingerprint256Tests.swift`
  - `HLCTests.swift`
  - `HammingTests.swift`
  - `SimHashTests.swift`
  - `ORReduceTests.swift`
  - `FNVTests.swift`
  - `GSetAuditLogTests.swift`
  - `BitwiseArithmeticTests.swift`
- **Rust:** `tests/` plus per-module `#[cfg(test)] mod tests` blocks
  inside each `src/<family>.rs`.

Shared conformance vector files live at the SubstrateLib package root
and are loaded by both the Swift and Rust legs' tests.

## § 6 — Examples

```swift
// Construct fingerprints from blocks, intersect, measure distance.
let a = Fingerprint256(block0: 0x1234_5678_9abc_def0, block1: 0, block2: 0, block3: 0)
let b = Fingerprint256(block0: 0xfedc_ba98_7654_3210, block1: 0, block2: 0, block3: 0)
let c = BitwiseArithmetic.intersect(a, b)        // bitwise AND
let dist = Hamming.distance(a, b)                 // all 4 blocks by default

// Generate an HLC.
var gen = HLCGenerator(nodeID: 0xABCDEF)
let h1 = gen.send(now: Int64(Date().timeIntervalSince1970 * 1000))

// Build an audit entry (id is the 32-byte content hash).
let entry = AuditEntry(
    id: [UInt8](repeating: 0, count: 32),
    hlc: h1,
    verb: .capture,
    rowID: UUID(),
    fieldPath: "adjective.state",
    beforeValue: nil,
    afterValue: .bitmap(0x0001)
)

// G-Set audit log, merge (mutating).
var log1 = GSetAuditLog()
log1.add(entry)
var log2 = GSetAuditLog()
log2.add(entry)        // same entry, dedup on content hash
log1.merge(log2)
assert(log1.count == 1)
```

```rust
use substrate_types::{Fingerprint256, BlockMask, hamming, bitwise, hlc::HLCGenerator,
                      gset::{GSetAuditLog, AuditEntry, AuditVerb, AuditValue}};

let a = Fingerprint256::new(0x1234_5678_9abc_def0, 0, 0, 0);
let b = Fingerprint256::new(0xfedc_ba98_7654_3210, 0, 0, 0);
let c = bitwise::intersect(&a, &b);   // bitwise AND
// distance() and similarity() take a u8 block-mask; use BlockMask::ALL.bits()
// for the common full-256-bit case.
let dist = hamming::distance(&a, &b, BlockMask::ALL.bits());
let sim  = hamming::similarity(&a, &b, BlockMask::ALL.bits());

let mut gen = HLCGenerator::new(0xABCDEF);
let h1 = gen.send(/* now millis */ 1_700_000_000_000);
```

## § 7 — Swift/Rust Concordance

One row per top-level public concept, anchored to both ports (Swift
`public struct|enum|protocol|class|actor|typealias`; Rust top-level
`pub struct|enum|trait|type` plus the namespace-equivalent free
functions). "Shape rule" states how the two ports are allowed to differ;
"Test/vector binding" cites the conformance / unit test that proves the
two ports agree. SubstrateTypes is pure value types and algebra
namespaces. Every public concept is present in both ports; the only
permitted differences are port-naming idioms — Swift caseless `enum`
namespaces vs. Rust module free functions.

Swift file paths are under `Sources/SubstrateTypes/`; Rust paths under
`rust/src/`. All listed Rust types are re-exported from the crate root
(`lib.rs`) except the algebra free functions, which are reached through
their module path (`hamming::distance`, `fnv::hash64`, …).

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| 256-bit fingerprint | `Fingerprint256` (`Fingerprint256.swift:43`) | `Fingerprint256` (`fingerprint256.rs:41`) | both `public`/`pub` | identical — 256-bit value; Swift 4×`UInt64` named fields (`block0`–`block3`) / Rust 4×`u64` named fields (`block0`–`block3`), byte-identical XOR/hex/bytes | `Fingerprint256CombinatorsTests.swift`; `fingerprint256.rs` tests (16) | Confirmed |
| Fingerprint error | `Fingerprint256Error` (`Fingerprint256.swift:197`) | `Fingerprint256Error` (`fingerprint256.rs:127`) | both public | identical — `invalidByteCount(expected,got)` | `Fingerprint256CombinatorsTests.swift`; `fingerprint256.rs` tests | Confirmed |
| Hybrid logical clock | `HLC` (`HLC.swift:37`) | `HLC` (`hlc.rs:41`) | both public | identical — `physicalTime`/`logicalCount`/`nodeID` ↔ snake_case; 16-byte LE wire format; `advanced()`/`physical_seconds_since_epoch()` identical both ports; `init(nodeId:)` alias is Swift-only (back-compat) | `HLCTests.swift`; `hlc.rs` tests (6) | Confirmed |
| HLC generator | `HLCGenerator` (`HLC.swift:125`) | `HLCGenerator` (`hlc.rs:178`) | both public | identical — `send`/`receive` mutating clock advance | `HLCTests.swift`; `hlc.rs` tests | Confirmed |
| HLC error | `HLCError` (`HLC.swift:249`) | `HLCError` (`hlc.rs:151`) | both public | identical — `invalidWireLength(Int)` | `HLCTests.swift`; `hlc.rs` tests | Confirmed |
| Audit event (wire row) | `AuditEvent` (`AuditEvent.swift:15`) | `AuditEvent` (`audit_event.rs:18`) | both public | identical concept — canonical wire/audit row; `eventID`/`estateUuid`/`rowId` ↔ `event_id`/`estate_uuid`/`row_id`; before/after bitmaps as three-`Int64`/`i64` tuples; `reason: String?` / `reason: Option<String>` nullable annotation field; `withReason(_:)` copy helper (Swift only) | `AuditEventTests.swift` | Confirmed |
| G-Set audit entry | `AuditEntry` (`GSetAuditLog.swift:35`) | `AuditEntry` (`gset.rs:86`) | both public | identical — 32-byte content id, HLC, verb, rowID, field path, before/after value; Swift `rowID: UUID` ↔ Rust `row_id: RowID (u128)` with UUID-string serde | `GSetAuditLogTests.swift`; `gset.rs` tests (5) | Confirmed |
| Audit verb | `AuditVerb` (`GSetAuditLog.swift:62`) | `AuditVerb` (`gset.rs:35`) | both public | identical — same case set, Swift camelCase ↔ Rust PascalCase variants | `GSetAuditLogTests.swift`; `gset.rs` tests | Confirmed |
| Audit value | `AuditValue` (`GSetAuditLog.swift:95`) | `AuditValue` (`gset.rs:67`) | both public | identical — `bitmap(UInt64)`/`string`/`fingerprint`/`integer(Int64)` ↔ `Bitmap(u64)`/`String`/`Fingerprint`/`Integer(i64)`; externally-tagged camelCase wire format | `GSetAuditLogTests.swift`; `gset.rs` tests | Confirmed |
| G-Set audit log CRDT | `GSetAuditLog` (`GSetAuditLog.swift:134`) | `GSetAuditLog` (`gset.rs:114`) | both public | identical — content-hash-keyed store; `add`/`merge`/`count`/`orderedEntries`/`entries(forRow:)`/`entries(since:)` ↔ `add`/`merge`/`len`/`ordered_entries`/`entries_for_row`/`entries_since` | `GSetAuditLogTests.swift`; `gset.rs` tests (5) | Confirmed |
| Row id | `RowId` (typealias `UUID`, `Row.swift:19`) | `RowId` (`row.rs:14`) | both public | idiom — Swift `RowId = UUID`; Rust `RowId(u128)` newtype; UUID and u128 are byte-equivalent 16-byte representations. The Rust `gset` module uses the canonical `RowId` newtype throughout. | `RowTests.swift`; `gset.rs` tests | Confirmed |
| Row entity | `Row` (`Row.swift:23`) | `Row` (`row.rs:17`) | both public | identical concept — pure data row; both ports inline the three bitmap fields directly (`adjectiveBitmap`/`adjective_bitmap`, `operationalBitmap`/`operational_bitmap`, `provenanceBitmap`/`provenance_bitmap` as `Int64`/`i64`) plus `fingerprint`, `latticeAnchor`/`lattice_anchor`, `lineageId`/`lineage_id`, and `content`; neither port wraps bitmaps in a `RowBitmaps` carrier; no `createdAt` field in either port | `RowTests.swift` | Confirmed |
| Row bitmaps carrier | `RowBitmaps` (`RowBitmaps.swift:37`) | `RowBitmaps` (`row_bitmaps.rs:31`) | both public | identical — three `i64` fields; same 216-bit layout constants, `field()`/`bit()`/`field_values()`/`bit_vector()`; reserved-field shift-guard | `RowBitmapsTests.swift`; `row_bitmaps.rs` tests (15) | Confirmed |
| 216-bit vector | `BitVector216` (`RowBitmaps.swift:134`) | `BitVector216` (`row_bitmaps.rs:128`) | both public | identical — `[u8;27]` storage; `from_row_bitmaps`/`from_presence_bytes`/`bit_at`/`bit` mirror Swift inits + accessors | `RowBitmapsTests.swift`; `row_bitmaps.rs` tests | Confirmed |
| Row lifecycle state | `RowState` (`RowState.swift:35`) | `RowState` (`row_state.rs:28`) | both public | identical — `repr(u8)`/`UInt8` raw values, same case ordinals; `cluster`/`isActiveCluster`/`activeClusterUpperBoundRaw`/`cluster(ofRawState:)` ↔ Rust `cluster()`/`is_active_cluster()`/`ACTIVE_CLUSTER_UPPER_BOUND_RAW`/`cluster_of_raw_state()`; `from_raw()` is Rust-only; `description` / `token()` surface verb strings (Swift via rawValue, Rust via explicit `token()`) | `RowStateTests.swift`; `row_state.rs` tests | Confirmed |
| Row verb | `RowVerb` (`RowState.swift:50`) | `RowVerb` (`row_state.rs:66`) | both public | identical — same case set, camelCase ↔ PascalCase | `RowStateTests.swift` | Confirmed |
| Row state error | `RowStateError` (`RowState.swift:137`) | `RowStateError` (`row_state.rs:185`) | both public | identical — `illegalTransition`/`violatesInvariant` (Rust `IllegalTransition`/`ViolatesInvariant`) | `RowStateTests.swift` | Confirmed |
| Row state cluster | `RowStateCluster` (`RowState.swift:63`) | `RowStateCluster` (`row_state.rs:58`) | both public | identical — `a`/`b`/`c` ↔ `A`/`B`/`C` (`repr(u8)` 0/1/2); `isActive` / `is_active()` property; groups `RowState` cases into lifecycle bands | `RowStateTests.swift`; `row_state.rs` cluster tests | Confirmed |
| Noun type | `NounType` (`NounType.swift:12`) | `NounType` (`noun_type.rs:8`) | both public | identical — eight `repr(u8)` cases, same ordinals | `NounTypeTests.swift` | Confirmed |
| Lattice anchor | `LatticeAnchor` (`LatticeAnchor.swift:12`) | `LatticeAnchor` (`lattice_anchor.rs:9`) | both public | identical — `udcCode: UInt64`/`qidPointer: UInt64` ↔ `udc_code`/`qid_pointer: u64`; `udc(_)` constructor + `isNull`/`is_null`; `udcQid(_:qid:)` / `udc_qid()` both present; `fnv1a64` is Rust-only helper (Swift callers use `FNV.hash64`) | `LatticeAnchorTests.swift` | Confirmed |
| Field-presence matrix F | `MatrixF` (`MatrixF.swift:24`) | `MatrixF` (`matrix_f.rs:7`) | both public | identical — flat 216-cell `[Int64]`/`Vec<i64>`, indexed `field*6+bit` | `MatrixFTests.swift`; `matrix_f.rs` tests (5) | Confirmed |
| Confidence matrix C | `MatrixC` (`MatrixC.swift:27`) | `MatrixC` (`matrix_c.rs:9`) | both public | identical — flat 216-cell `[Float]`/`Vec<f32>` derived from F | `MatrixCTests.swift`; `matrix_c.rs` tests (4) | Confirmed |
| Cooccurrence matrix O | `MatrixO` (`MatrixO.swift:70`) | `MatrixO` (`matrix_o.rs:41`) | both public | identical — sorted sparse `[(CooccurrenceKey, Int64)]` ↔ `Vec<(CooccurrenceKey, i64)>` | `MatrixOTests.swift`; `matrix_o.rs` tests (6) | Confirmed |
| Cooccurrence key | `CooccurrenceKey` (`MatrixO.swift:38`) | `CooccurrenceKey` (`matrix_o.rs:10`) | both public | identical — `fieldI`/`valueI`/`fieldJ`/`valueJ` `UInt8` ↔ `u8` | `MatrixOTests.swift`; `matrix_o.rs` tests | Confirmed |
| Causality matrix T | `MatrixT` (`MatrixT.swift:84`) | `MatrixT` (`matrix_t.rs:51`) | both public | identical — sorted sparse `[(CausalityKey, Int64)]` ↔ `Vec<(CausalityKey, i64)>` | `MatrixTTests.swift`; `matrix_t.rs` tests (5) | Confirmed |
| Causality key | `CausalityKey` (`MatrixT.swift:43`) | `CausalityKey` (`matrix_t.rs:7`) | both public | identical — `sourceField`/`sourceValue`/`targetField`/`targetValue`/`lagBucket` `UInt8` ↔ `u8` | `MatrixTTests.swift`; `matrix_t.rs` tests | Confirmed |
| Recall score | `RecallScore` (`RecallTypes.swift:61`) | `RecallScore` (`recall_types.rs:40`) | both public | identical — `(rowId: RowId, score: Float32)` ↔ `(row_id, score: f32)` | `RecallTypesTests.swift`; `recall_types.rs` tests (8) | Confirmed |
| Distance breakdown | `DistanceBreakdown` (`RecallTypes.swift:75`) | `DistanceBreakdown` (`recall_types.rs:63`) | both public | identical — four `Float32`/`f32` contributions; Swift default init ↔ Rust `ZERO`/`Default` | `RecallTypesTests.swift`; `recall_types.rs` tests | Confirmed |
| Recall result | `RecallResult` (`RecallTypes.swift:95`) | `RecallResult` (`recall_types.rs:109`) | both public | identical — `rows`/`breakdown`/`confidenceInterval`/`primitiveName`; Rust adds `simple()` convenience ctor | `RecallTypesTests.swift`; `recall_types.rs` tests | Confirmed |
| Row projection | `RowProjection` (`RecallTypes.swift:118`) | `RowProjection` (`recall_types.rs:156`) | both public | identical — `rowId`/`captureHLC`/`fingerprint`/`lattice`/`bitmaps:(u64,u64,u64)`/`rowState:u8` | `RecallTypesTests.swift`; `recall_types.rs` tests | Confirmed |
| 3-D bit tensor | `ThreeDBitTensor` (`ThreeDBitTensor.swift:36`) | `ThreeDBitTensor` (`bit_tensor.rs:12`) | both public | identical — bit-sliced N-row × 36-field × 6-bit tensor; `slices` storage with `valueAt`/`setValue` accessors | `ThreeDBitTensorTests.swift` | Confirmed |
| Time range | `TimeRange` (`TimeRange.swift:11`) | `TimeRange` (`time_range.rs:10`) | both public | identical — closed `[start,end]` HLC interval; `contains` | `TimeRangeTests.swift` | Confirmed |
| Count vector | `CountVector256` (`CountVector256.swift:42`) | `CountVector256` (`count_vector.rs:35`) | both public | identical — 256 `UInt32`/`u32` counts + `n`; `fold` over fingerprints | `CountVector256Tests.swift`; `count_vector.rs` tests (6) | Confirmed |
| Block selection mask | `BlockMask` (`BlockMask.swift:27`) | `BlockMask` (`block_mask.rs:32`) | both public | identical — `u8` mask; Swift `OptionSet` ↔ Rust transparent newtype with same `BLOCK0/1/2/3`/`ALL`/`NONE`, `contains`/`union`/`intersection`/`block_count` | `BlockMaskTests.swift`; `block_mask.rs` tests (8) | Confirmed |
| Hyperplane | `Hyperplane` (`HyperplaneFamily.swift:30`) | `Hyperplane` (`hyperplane.rs:25`) | both public | identical — 256-bit plane | `HyperplaneFamilyTests.swift`; `hyperplane.rs` tests (3) | Confirmed |
| Hyperplane family | `HyperplaneFamily` (`HyperplaneFamily.swift:68`) | `HyperplaneFamily` (`hyperplane.rs:68`) | both public | identical — seeded family of planes | `HyperplaneFamilyTests.swift`; `hyperplane.rs` tests | Confirmed |
| Float-input SimHash planes | `FloatSimHashPlanes` (`FloatSimHashPlanes.swift:30`) | `FloatSimHashPlanes` (`float_simhash_planes.rs:24`) | both public | identical — `dim: Int`/`signBits: [UInt64]` ↔ `dim: usize`/`sign_bits: Vec<u64>`; seed-immutable; generated by `SubstrateML.FloatSimHash`, applied by `SubstrateKernel.floatSimHashProject` | (applied in SubstrateKernel tests) | Confirmed |
| Fingerprint builder ADT | `FingerprintBuilder` (`public indirect enum`, `BitwiseArithmetic.swift:77`) | `FingerprintBuilder` (`bitwise.rs:75`) | both public | identical — `literal`/`intersect`/`difference`/`prototypeOf` ↔ `Literal`/`Intersect`/`Difference`/`PrototypeOf`; same `evaluate()` interpreter. | `BitwiseArithmeticTests.swift`; `bitwise.rs` tests (6) | Confirmed |
| Hamming distance/similarity | `Hamming` namespace + `HammingDistance` alias (`Hamming.swift:23`,`:21`) | `hamming::distance` / `hamming::similarity` free fns (`hamming.rs:38`,`:53`) | both public | idiom — Swift caseless-`enum` namespace with static methods ↔ Rust module free functions; identical results, per-block `BlockMask`/`u8` | `HammingTests.swift`; `hamming.rs` tests (5) | Confirmed |
| SimHash signing | `SimHash` namespace (`SimHash.swift:25`) | `simhash::*` free fns (`simhash.rs:38`+) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions (`block`/`fingerprint`/`fingerprint_batch`); identical signing | `SimHashTests.swift`; `simhash.rs` tests (2) | Confirmed |
| SimHash input builders | `SimHashInput` namespace (`SimHash.swift:124`) | `simhash::bitmap_input`/`lattice_input`/`lineage_temporal_input`/`channel_source_input` free fns (`simhash.rs:127`+) | both public | idiom — Swift caseless-`enum` of static `[UInt64]` factories ↔ Rust `Vec<u64>` free functions, one per block; identical packing | `SimHashTests.swift`; `simhash.rs` tests | Confirmed |
| Bitwise fingerprint algebra | `BitwiseArithmetic` namespace (`BitwiseArithmetic.swift:21`) | `bitwise::intersect`/`difference`/`prototype` free fns (`bitwise.rs:29`,`:42`,`:59`) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions; identical AND/XOR/weighted-majority | `BitwiseArithmeticTests.swift`; `bitwise.rs` tests (6) | Confirmed |
| OR-reduce | `ORReduce` namespace (`ORReduce.swift:22`) | `or_reduce::reduce`/`reduce_blocks` free fns (`or_reduce.rs:29`,`:43`) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions; identical bitwise OR fold | `ORReduceTests.swift`; `or_reduce.rs` tests (4) | Confirmed |
| FNV-1a hash | `FNV` namespace (`FNV.swift:18`) | `fnv::hash64`/`hash32`/`hash16` free fns (`fnv.rs:18`,`:31`,`:45`) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions; identical FNV-1a output | `FNVTests.swift`; `fnv.rs` tests (6) | Confirmed |
| Content hash | `ContentHash` (`ContentHash.swift`) | `ContentHash` (`content_hash.rs`) | both public | identical — 32-byte SHA-256 leaf digest; `tombstone`/`TOMBSTONE` sentinel byte-identical; hex display + Codable/serde | `ContentHashTests.swift`; `content_hash.rs` tests (7) | Confirmed |
| Content hash error | `ContentHashError` (`ContentHash.swift`) | `ContentHashError` (`content_hash.rs`) | both public | identical — `invalidHexLength`/`invalidHexCharacter` ↔ `InvalidHexLength`/`InvalidHexCharacter` | `ContentHashTests.swift`; `content_hash.rs` tests | Confirmed |
| Merkle root | `MerkleRoot` (`MerkleRoot.swift`) | `MerkleRoot` (`merkle_root.rs`) | both public | identical — 32-byte subtree root hash; `empty`/`EMPTY` sentinel byte-identical; hex display + Codable/serde | `MerkleRootTests.swift`; `merkle_root.rs` tests (6) | Confirmed |
| Merkle root error | `MerkleRootError` (`MerkleRoot.swift`) | `MerkleRootError` (`merkle_root.rs`) | both public | identical — `invalidHexLength`/`invalidHexCharacter` ↔ `InvalidHexLength`/`InvalidHexCharacter` | `MerkleRootTests.swift`; `merkle_root.rs` tests | Confirmed |
| Snapshot id | `SnapshotId` (`SnapshotId.swift`) | `SnapshotId` (`snapshot_id.rs`) | both public | idiom — Swift wraps `UUID` with random init; Rust wraps `[u8;16]` with `from_bytes`; UUID string round-trip identical | `SnapshotIdTests.swift`; `snapshot_id.rs` tests (5) | Confirmed |
| Snapshot id error | `SnapshotIdError` (`SnapshotId.swift`) | `SnapshotIdError` (`snapshot_id.rs`) | both public | identical — `invalidUUID(String)` ↔ `InvalidUUID(String)` | `SnapshotIdTests.swift`; `snapshot_id.rs` tests | Confirmed |
| Temporal coordinate | `AsOfCoordinate` (`AsOfCoordinate.swift`) | `AsOfCoordinate` (`as_of_coordinate.rs`) | both public | identical — `.present`/`.asOf(HLC)` ↔ `Present`/`AsOf(HLC)`; JSON `{"kind":"present"}` / `{"kind":"asOf","hlc":{...}}` identical | `AsOfCoordinateTests.swift`; `as_of_coordinate.rs` tests (6) | Confirmed |
| Domain tags | `MerkleDomain` (`MerkleDomain.swift`) | `MerkleDomain` (`merkle_domain.rs`) | both public | identical — `leaf`/`interior`/`tombstone`/`commitment` = 0x00/0x01/0x02/0x03; conformance-frozen | `MerkleDomainTests.swift`; `merkle_domain.rs` tests (2) | Confirmed |

## Changelog

### 1.3.0 -- 2026-07-16
Added missing public surface found during full audit. (1) `FloatSimHashPlanes` — a public type in both ports absent from the doc (Swift 30th file, Rust `float_simhash_planes.rs`; §1 file count corrected, §2 new section, §7 concordance row added). (2) `HLC.advanced()` / `HLC.physicalSecondsSinceEpoch()` — present in both ports since initial commit, not documented; added to §2 HLC block and concordance. (3) `HLC.init(physicalTime:logicalCount:nodeId:)` — Swift-only back-compat alias; documented with note. (4) `RowState` cluster helpers — `cluster`, `isActiveCluster`, `activeClusterUpperBoundRaw`, `cluster(ofRawState:)` and `description` conformance (Swift); Rust `ACTIVE_CLUSTER_UPPER_BOUND_RAW`, `from_raw`, `cluster`, `is_active_cluster`, `cluster_of_raw_state` equivalents added with parity notes. (5) `RowVerb::token()` — Rust-only method returning the lowercase verb string; documented with parity note. (6) `LatticeAnchor.udcQid(_:qid:)` / `udc_qid()` — both ports, omitted since initial doc; added to §2 and concordance. (7) `LatticeAnchor::fnv1a64()` — Rust-only helper; documented with parity note. (8) `RowStateError.description` — `CustomStringConvertible` conformance; added to §2.

### 1.2.0 -- 2026-06-20
Added five new types for the node-integrity contract content-integrity and snapshots: ContentHash, MerkleRoot, SnapshotId, AsOfCoordinate, MerkleDomain (§2). Updated §1 file count from 24 to 29. Added ContentHashError, MerkleRootError, SnapshotIdError to §4. Added nine concordance rows to §7. Updated Rust module list.

### 1.1.0 -- 2026-06-17
Added `reason: String?` / `reason: Option<String>` field to `AuditEvent` in both ports (A-8: audit reason persistence). The field is nil/None when no caller reason is supplied and is persisted as nullable TEXT in the `_storagekit_audit` table's `reason` column. Added `withReason(_:) -> AuditEvent` copy helper (Swift). Updated concordance table row and init signature accordingly.

### 1.0.1 -- 2026-06-14
§ 7 Concordance: corrected the stale `RowStateError` source-line citations (Swift `RowState.swift:65`→`:137`, Rust `row_state.rs:104`→`:185`) to the actual enum definition lines, and named the Rust variants (`IllegalTransition`/`ViolatesInvariant`). Variant names were already correct throughout (`illegalTransition`/`violatesInvariant`); no `forbiddenCombination` case exists in the source.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
