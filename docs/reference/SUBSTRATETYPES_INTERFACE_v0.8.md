---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateTypes
languages: [swift, rust]
relates_to:
  - SUBSTRATETYPES_SPEC_v0.8.md  (the contract this interface implements)
  - SUBSTRATEKERNEL_INTERFACE_v0.8.md  (sibling: hot-path bit operations)
  - SUBSTRATEML_INTERFACE_v0.8.md      (sibling: cold-path algorithms)
  - SUBSTRATELIB_INTERFACE_v0.8.md     (umbrella: orchestration)
purpose: |
  Public API surface of SubstrateTypes in both ports. Twenty-four
  Swift files publish forty-two top-level types and eight algebra-
  primitive namespaces; the Rust mirror exposes the same shapes with
  Rust-idiomatic names. The companion SPEC carries the behavioral
  contracts (invariants I-1…I-30, conformance vectors).
---

# SubstrateTypes Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateTypes/`

- `Sources/SubstrateTypes/` — 24 files, one per type family.
- `Tests/SubstrateTypesTests/` — unit + conformance tests.
- `Package.swift` — manifest. No dependencies on other substrate
  packages.

**Rust:** `packages/libs/SubstrateTypes/rust/`

- `src/lib.rs` — crate root, declares one `pub mod` per type family.
- `src/<family>.rs` — per-family module (`fingerprint256.rs`,
  `hlc.rs`, `audit_event.rs`, `gset.rs`, `row.rs`, `row_state.rs`,
  `lattice_anchor.rs`, `noun_type.rs`, `matrix_*.rs`, `hyperplane.rs`,
  `simhash.rs`, `hamming.rs`, `or_reduce.rs`, `bitwise.rs`, `fnv.rs`,
  `count_vector.rs`, `bit_tensor.rs`, `time_range.rs`, `recall_types`
  inline with `partial_state_recall` in `substrate-ml`).
- `tests/` — conformance tests, shared vectors.
- `Cargo.toml` — declares only `serde`, `serde_json`, `uuid`,
  standard library.

Naming differs by port convention (Swift `Fingerprint256` /
`hammingDistance256`; Rust `Fingerprint256` / `hamming_distance_256`);
the *results* are bit-for-bit identical (SPEC § 7, I-7).

## § 2 — Public types

### `Fingerprint256`

256-bit value type. SPEC § 5.1.

**Swift:**

```swift
public struct Fingerprint256: Hashable, Sendable, Codable {
    public static let bitWidth: Int = 256
    public static let byteWidth: Int = 32
    public static let zero: Fingerprint256
    public init(words: (UInt64, UInt64, UInt64, UInt64))
    public init(bytes: [UInt8]) throws  // 32 bytes required
    public func toBytes() -> [UInt8]
    public func toHex() -> String
    public static func xor(_ a: Self, _ b: Self) -> Self
    public static func == (lhs: Self, rhs: Self) -> Bool
    public var isZero: Bool { get }
}

public enum Fingerprint256Error: Error, Sendable {
    case invalidByteCount(expected: Int, got: Int)
}
```

**Rust:**

```rust
pub struct Fingerprint256(pub [u8; 32]);
impl Fingerprint256 {
    pub const BIT_WIDTH: usize = 256;
    pub const BYTE_WIDTH: usize = 32;
    pub const ZERO: Self;
    pub fn from_words(words: (u64, u64, u64, u64)) -> Self;
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, Fingerprint256Error>;
    pub fn to_bytes(&self) -> [u8; 32];
    pub fn to_hex(&self) -> String;
    pub fn xor(&self, other: &Self) -> Self;
    pub fn is_zero(&self) -> bool;
}
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
    public func wireBytes() -> [UInt8]            // 16-byte LE wire format
    public init(wireBytes bytes: [UInt8]) throws  // throws on bad length
}

public struct HLCGenerator: Sendable {
    public init(nodeID: Int32, lastPhysical: Int64 = 0, lastLogical: Int32 = 0)
    public mutating func send(now: Int64) -> HLC
    public mutating func receive(remote: HLC, now: Int64) -> HLC
}

public enum HLCError: Error, Sendable, Equatable {
    case invalidWireLength(Int)
}
```

**Rust:**

```rust
pub struct HLC { pub physical_time: i64, pub logical_count: i32, pub node_id: i32 }
impl HLC {
    pub fn new(physical_time: i64, logical_count: i32, node_id: i32) -> Self;
    pub fn wire_bytes(&self) -> [u8; 16];
    pub fn from_wire_bytes(bytes: &[u8]) -> Result<Self, HLCError>;
}

pub struct HLCGenerator { /* internal */ }
impl HLCGenerator {
    pub fn new(node_id: i32) -> Self;
    pub fn send(&mut self, now: i64) -> HLC;
    pub fn receive(&mut self, remote: HLC, now: i64) -> HLC;
}

pub enum HLCError { InvalidWireLength(usize) }
```

### `AuditEvent`

Single audit row, structured form. SPEC § 5.3.

**Swift:**

```swift
public struct AuditEvent: Sendable {
    public let rowId: UUID
    public let hlc: HLC
    public let verb: RowVerb
    public let nounType: NounType
    public let priorBitmaps: BitmapFields?
    public let afterBitmaps: BitmapFields
    public let priorLatticeAnchor: LatticeAnchor?
    public let afterLatticeAnchor: LatticeAnchor?
    public let actor: String
    public let contentId: UInt128
}
```

`BitmapFields` is declared in SubstrateLib's `RowStateAutomaton.swift`
(legacy placement, eligible for relocation to this package in a
future cleanup) — see SubstrateLib INTERFACE § 2.

**Rust:**

```rust
pub struct AuditEvent {
    pub row_id: RowId,
    pub hlc: HLC,
    pub verb: RowVerb,
    pub noun_type: NounType,
    pub prior_bitmaps: Option<BitmapFields>,
    pub after_bitmaps: BitmapFields,
    pub prior_lattice_anchor: Option<LatticeAnchor>,
    pub after_lattice_anchor: Option<LatticeAnchor>,
    pub actor: String,
    pub content_id: u128,
}
```

### `GSetAuditLog`, `AuditEntry`, `AuditVerb`, `AuditValue`

G-Set audit log CRDT plus entry shape. SPEC § 5.3.

**Swift:**

```swift
public struct AuditEntry: Hashable, Sendable, Codable {
    public let rowId: UUID
    public let hlc: HLC
    public let verb: AuditVerb
    public let prior: AuditValue?
    public let after: AuditValue
    public let eventId: UInt128
}

public enum AuditVerb: String, Sendable, Codable {
    case capture, mutate, retract, sync, pair, unpair
    case derive, decay, promote, migrate, dreamCompact
    case withdraw, expunge, recall, propose, associate, learn
    case reanchor
}

public enum AuditValue: Hashable, Sendable, Codable {
    case bitmap(Int64)
    case string(String)
    case fingerprint(Fingerprint256)
    case integer(Int64)
    case bytes(Data)        // added 2026-05-29 per DECISION_GLK_UNIFIED_AUDIT_LOG (A) widening
}

public struct GSetAuditLog: Sendable, Codable {
    public init()
    public mutating func add(_ entry: AuditEntry)
    public func contains(_ entry: AuditEntry) -> Bool
    public var count: Int { get }
    public func entries() -> [AuditEntry]
    public static func merge(_ a: Self, _ b: Self) -> Self
}
```

**Rust:**

```rust
pub struct AuditEntry { /* same fields, snake_case */ }
pub enum AuditVerb { Capture, Mutate, Retract, /* … */ }
pub enum AuditValue { Bitmap(i64), String(String), Fingerprint(Fingerprint256), Integer(i64), Bytes(Vec<u8>) }
pub struct GSetAuditLog { /* internal */ }
impl GSetAuditLog {
    pub fn new() -> Self;
    pub fn add(&mut self, entry: AuditEntry);
    pub fn contains(&self, entry: &AuditEntry) -> bool;
    pub fn len(&self) -> usize;
    pub fn entries(&self) -> impl Iterator<Item = &AuditEntry>;
    pub fn merge(a: &Self, b: &Self) -> Self;
}
```

### `Row`, `RowId`, `RowBitmaps`, `BitVector216`

Row identity + bitmap carriers. SPEC § 5.4.

**Swift:**

```swift
public typealias RowId = UUID

public struct Row: Sendable {
    public let id: RowId
    public let nounType: NounType
    public let bitmaps: RowBitmaps
    public let latticeAnchor: LatticeAnchor?
    public let createdAt: HLC
}

public struct RowBitmaps: Sendable, Hashable, Codable {
    public let adjective: Int64       // 72 bits, packed in Int64 with mask
    public let operational: Int64     // 72 bits
    public let provenance: Int64      // 72 bits
}

public struct BitVector216: Sendable, Hashable {
    public let bytes: [UInt8]         // 27 bytes = 216 bits
    public init(adjective: Int64, operational: Int64, provenance: Int64)
    public func toRowBitmaps() -> RowBitmaps
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

### `RowState`, `RowVerb`, `RowStateError`

Row lifecycle enumerations. SPEC § 5.4.

**Swift:**

```swift
public enum RowState: UInt8, Sendable, Codable, CaseIterable {
    case active = 0, pending = 1, contested = 2, accepted = 3
    case withdrawn = 16, decayed = 17, expired = 18, rejected = 19
    case superseded = 32, tombstoned = 33
}

public enum RowVerb: String, Sendable, Codable, CaseIterable {
    case capture, reanchor, mutate, withdraw, expunge
    case recall, propose, associate, learn
    case retract, promote, sync, derive, dreamCompact, tombstone
    case migrate
}

public enum RowStateError: Error, Sendable, Equatable {
    case illegalTransition(RowState, RowVerb)
    case forbiddenCombination(state: RowState, fields: String)
}
```

**Rust:** `RowState` (repr(u8)), `RowVerb`, `RowStateError` — same
shape.

### `NounType`

Eight noun categories. SPEC § 5 (background); cookbook §2.1.

**Swift:**

```swift
public enum NounType: UInt8, Sendable {
    case drawer = 0
    case tunnel = 1
    case diary = 2
    case keystone = 3
    case adjective = 4
    case lexicon = 5
    case ambientSample = 6
    case branchHandle = 7
}
```

**Rust:** `pub enum NounType { Drawer, Tunnel, ... }` with `repr(u8)`.

### `LatticeAnchor`

Cookbook §2.7 anchor reference. SPEC § 5.5.

**Swift:**

```swift
public struct LatticeAnchor: Hashable, Sendable {
    public let udcCode: String
    public let wikidataQID: String?
    public init(udcCode: String, wikidataQID: String? = nil)
    public static let unknown: LatticeAnchor  // udcCode = ""
    public static func udc(_ code: String) -> LatticeAnchor
}
```

**Rust:**

```rust
pub struct LatticeAnchor { pub udc_code: String, pub wikidata_qid: Option<String> }
impl LatticeAnchor {
    pub fn new(udc: String, qid: Option<String>) -> Self;
    pub fn unknown() -> Self;
    pub fn udc(code: &str) -> Self;
}
```

### `MatrixF`, `MatrixC`, `MatrixO`, `MatrixT`

The four matrix carriers. SPEC § 5.6.

**Swift:**

```swift
public struct MatrixF: Sendable, Equatable {
    public let rows: Int
    public let cols: Int
    public let cells: [Float]          // row-major, count = rows * cols
}
public struct MatrixC: Sendable, Equatable { /* cooccurrence counts */ }
public struct CooccurrenceKey: Hashable, Comparable, Sendable {
    public let row: UInt32
    public let col: UInt32
}
public struct MatrixO: Sendable, Equatable {
    public let pairs: [CooccurrenceKey: Int64]
}
public struct CausalityKey: Hashable, Comparable, Sendable {
    public let cause: UInt32
    public let effect: UInt32
    public let lag: UInt32
}
public struct MatrixT: Sendable, Equatable {
    public let triples: [CausalityKey: Double]
}
```

**Rust:** equivalent shapes with snake_case fields, `HashMap` in place
of Swift's keyed dictionary.

### `RecallScore`, `DistanceBreakdown`, `RecallResult`, `RowProjection`

Recall vocabulary for ranking primitives and federation wire types.
Promoted from SubstrateLib/CognitionKit 2026-05-19; relocated to
SubstrateTypes 2026-05-29 per the four-package split. Both Swift and
Rust carry these types from this package (PAR-3A-ST force-mirror
ruling, 2026-06-05).

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
public struct ThreeDBitTensor: Sendable {
    public let xDim: Int
    public let yDim: Int
    public let zDim: Int
    public let bits: [UInt8]          // packed
    public init(xDim: Int, yDim: Int, zDim: Int)
    public mutating func set(x: Int, y: Int, z: Int)
    public func get(x: Int, y: Int, z: Int) -> Bool
}
```

**Rust:** same shape.

### `TimeRange`

Closed HLC interval. SPEC § 5 (background).

**Swift:**

```swift
public struct TimeRange: Sendable, Equatable {
    public let start: HLC
    public let end: HLC                // inclusive
    public func contains(_ hlc: HLC) -> Bool
    public func overlaps(_ other: TimeRange) -> Bool
}
```

**Rust:** same shape.

### `CountVector256`

256-element count vector for fingerprint aggregation. SPEC § 5
(background).

**Swift:**

```swift
public struct CountVector256: Sendable, Equatable, Codable {
    public let counts: [UInt32]        // count = 256
    public let n: UInt32               // number of source fingerprints folded
    public static func fold(_ fingerprints: [Fingerprint256]) -> CountVector256
}
```

**Rust:** same shape.

### `BlockMask`

Per-block fingerprint slicing mask. SPEC § 5 (background).

**Swift:**

```swift
public struct BlockMask: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public static let block0: Self
    public static let block1: Self
    public static let block2: Self
    public static let block3: Self
    public static let all: Self        // block0 | block1 | block2 | block3
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
    public let bits: [UInt8]           // 256 bits
}
public struct HyperplaneFamily: Sendable, Codable, Equatable {
    public let planes: [Hyperplane]    // typically 256 planes per family
    public init(seed: UInt64, count: Int)
}
```

**Rust:** same shape.

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
public enum SimHash {
    public static func sign(input: SimHashInput, family: HyperplaneFamily) -> Fingerprint256
}
public enum SimHashInput {
    case features([(weight: Double, vector: [UInt8])])
    case fingerprint(Fingerprint256, weight: Double)
}
```

**Rust:**

```rust
pub fn simhash_sign(input: &SimHashInput, family: &HyperplaneFamily) -> Fingerprint256;
pub enum SimHashInput<'a> {
    Features(&'a [(f64, &'a [u8])]),
    Fingerprint(Fingerprint256, f64),
}
```

### `ORReduce`

Bitwise OR-reduce across a set of fingerprints. SPEC § 5.7.

**Swift:**

```swift
public enum ORReduce {
    public static func reduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256
}
```

**Rust:**

```rust
pub fn or_reduce_256(fingerprints: &[Fingerprint256]) -> Fingerprint256;
```

### `BitwiseArithmetic`

Bitwise rotates and masked arithmetic. SPEC § 5.7.

**Swift:**

```swift
public enum BitwiseArithmetic {
    public static func rotateLeft(_ value: UInt64, by: Int) -> UInt64
    public static func rotateRight(_ value: UInt64, by: Int) -> UInt64
}
```

**Rust:** equivalent free functions on `u64`.

### `FNV`

FNV-1a hash. SPEC § 5.7.

**Swift:**

```swift
public enum FNV {
    public static func hash32(_ bytes: [UInt8]) -> UInt32
    public static func hash64(_ bytes: [UInt8]) -> UInt64
}
```

**Rust:**

```rust
pub fn fnv1a_32(bytes: &[u8]) -> u32;
pub fn fnv1a_64(bytes: &[u8]) -> u64;
```

## § 4 — Errors

The package raises only these errors:

| Error | Raised by | Cause |
|---|---|---|
| `Fingerprint256Error.invalidByteCount(expected: 32, got: N)` | `Fingerprint256(bytes:)` | byte input is not 32 bytes |
| `HLCError.invalidWireLength(Int)` | `HLC.init(wireBytes:)` / Rust `from_wire_bytes` | wire byte buffer was not the required 16-byte length |
| `RowStateError.illegalTransition(RowState, RowVerb)` | `RowStateAutomaton.validate` (in SubstrateLib; the enum lives here) | the (prior state, verb) pair is absent from the transition table |
| `RowStateError.forbiddenCombination(state:, fields:)` | `RowStateAutomaton.validate` (in SubstrateLib) | resulting bitmap violates I-22 |

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

Shared conformance vector files live at the SubstrateLib repo root
historically (cookbook §17.6) and are loaded by both legs' tests.

## § 6 — Examples

```swift
// Construct a fingerprint from words, XOR two fingerprints, check zero.
let a = Fingerprint256(words: (0x1234_5678_9abc_def0, 0, 0, 0))
let b = Fingerprint256(words: (0xfedc_ba98_7654_3210, 0, 0, 0))
let c = Fingerprint256.xor(a, b)
let dist = Hamming.distance256(a, b)

// Generate an HLC.
var gen = HLCGenerator(nodeID: 0xABCDEF)
let h1 = gen.send(now: Int64(Date().timeIntervalSince1970 * 1000))

// Build an audit entry.
let entry = AuditEntry(
    rowId: UUID(),
    hlc: h1,
    verb: .capture,
    prior: nil,
    after: .bitmap(0x0001),
    eventId: UInt128(0xDEADBEEF)
)

// G-Set audit log, merge.
var log1 = GSetAuditLog()
log1.add(entry)
var log2 = GSetAuditLog()
log2.add(entry)  // same entry, dedup-merged
let merged = GSetAuditLog.merge(log1, log2)
assert(merged.count == 1)
```

```rust
use substrate_types::{Fingerprint256, BlockMask, hamming, hlc::HLCGenerator,
                      audit_event::AuditEntry, gset::{GSetAuditLog, AuditVerb, AuditValue}};

let a = Fingerprint256::from_words((0x1234_5678_9abc_def0, 0, 0, 0));
let b = Fingerprint256::from_words((0xfedc_ba98_7654_3210, 0, 0, 0));
let c = a.xor(&b);
// distance() and similarity() take a u8 block-mask; use BlockMask::ALL.bits()
// for the common full-256-bit case.
let dist = hamming::distance(&a, &b, BlockMask::ALL.bits());
let sim  = hamming::similarity(&a, &b, BlockMask::ALL.bits());

let mut gen = HLCGenerator::new(0xABCDEF);
let h1 = gen.send(/* now millis */ 1_700_000_000_000);
```

## § 7 — Swift/Rust Concordance

Completed 2026-06-05 per Bob's force-mirror parity standard: one row
per top-level PUBLIC CONCEPT, read-anchored to both ports (Swift
`public struct|enum|protocol|class|actor|typealias` under
`Sources/SubstrateTypes/**`; Rust top-level `pub struct|enum|trait|type`
plus the namespace-equivalent free functions under `rust/src/**`). Each
Swift symbol and Rust symbol named below is a real declaration found in
source at the cited file:line. "Shape rule" states how the two ports are
allowed to differ; "Test/vector binding" cites the actual conformance /
unit test that proves Swift==Rust. No type in this package is an Apple
platform binding — SubstrateTypes is pure value types and algebra
namespaces, so there are no `Exempt` rows. No genuine drift was found:
every public concept is present in both ports (the names the audit
flagged "swift-only"/"rust-only" are port-naming idioms — Swift caseless
`enum` namespaces vs. Rust module free functions, and the `RowId`/`RowID`
casing pair — not missing counterparts).

Swift file paths are under `Sources/SubstrateTypes/`; Rust paths under
`rust/src/`. All listed Rust types are re-exported from the crate root
(`lib.rs`) except the algebra free functions, which are reached through
their module path (`hamming::distance`, `fnv::hash64`, …).

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| 256-bit fingerprint | `Fingerprint256` (`Fingerprint256.swift:43`) | `Fingerprint256` (`fingerprint256.rs:41`) | both `public`/`pub` | identical — 256-bit value; Swift 4×`UInt64` words / Rust `[u8;32]` newtype, byte-identical XOR/hex/bytes | `Fingerprint256CombinatorsTests.swift`; `fingerprint256.rs` tests (16) | Confirmed |
| Fingerprint error | `Fingerprint256Error` (`Fingerprint256.swift:197`) | `Fingerprint256Error` (`fingerprint256.rs:127`) | both public | identical — `invalidByteCount(expected,got)` | `Fingerprint256CombinatorsTests.swift`; `fingerprint256.rs` tests | Confirmed |
| Hybrid logical clock | `HLC` (`HLC.swift:37`) | `HLC` (`hlc.rs:41`) | both public | identical — `physicalTime`/`logicalCount`/`nodeID` ↔ snake_case; 16-byte LE wire format | `HLCTests.swift`; `hlc.rs` tests (6) | Confirmed |
| HLC generator | `HLCGenerator` (`HLC.swift:125`) | `HLCGenerator` (`hlc.rs:178`) | both public | identical — `send`/`receive` mutating clock advance | `HLCTests.swift`; `hlc.rs` tests | Confirmed |
| HLC error | `HLCError` (`HLC.swift:249`) | `HLCError` (`hlc.rs:151`) | both public | identical — `invalidWireLength(Int)` | `HLCTests.swift`; `hlc.rs` tests | Confirmed |
| Audit event (wire row) | `AuditEvent` (`AuditEvent.swift:15`) | `AuditEvent` (`audit_event.rs:18`) | both public | identical concept — canonical wire/audit row; snake_case fields (Rust carries `estate_uuid`/`event_id` explicitly; Swift `contentId`/`rowId`) | `AuditEventTests.swift` | Confirmed |
| G-Set audit entry | `AuditEntry` (`GSetAuditLog.swift:35`) | `AuditEntry` (`gset.rs:86`) | both public | identical — 32-byte content id, HLC, verb, rowID, field path, before/after value; Swift `rowID: UUID` ↔ Rust `row_id: RowID (u128)` with UUID-string serde | `GSetAuditLogTests.swift`; `gset.rs` tests (5) | Confirmed |
| Audit verb | `AuditVerb` (`GSetAuditLog.swift:62`) | `AuditVerb` (`gset.rs:35`) | both public | identical — same case set, Swift camelCase ↔ Rust PascalCase variants | `GSetAuditLogTests.swift`; `gset.rs` tests | Confirmed |
| Audit value | `AuditValue` (`GSetAuditLog.swift:95`) | `AuditValue` (`gset.rs:67`) | both public | identical — `bitmap`/`string`/`fingerprint`/`integer`/`bytes`; Swift `Data` ↔ Rust `Vec<u8>` | `GSetAuditLogTests.swift`; `gset.rs` tests | Confirmed |
| G-Set audit log CRDT | `GSetAuditLog` (`GSetAuditLog.swift:134`) | `GSetAuditLog` (`gset.rs:114`) | both public | identical — add/contains/count/entries/merge; Swift `count: Int` ↔ Rust `len()`, Swift `[AuditEntry]` ↔ Rust iterator | `GSetAuditLogTests.swift`; `gset.rs` tests | Confirmed |
| Row id | `RowId` (typealias `UUID`, `Row.swift:19`) | `RowId` (`row.rs:14`) + alias `RowID` (`gset.rs:75`) | both public | idiom — Swift `RowId = UUID`; Rust `RowId(u128)` newtype plus `RowID = u128` alias used by the gset wire layer (UUID-string serde bridges the two) | `RowTests.swift`; `gset.rs` tests | Confirmed |
| Row entity | `Row` (`Row.swift:23`) | `Row` (`row.rs:17`) | both public | identical concept — pure data row; Rust inlines bitmap `i64`s + `lineage_id`/`content`, Swift carries `RowBitmaps`/`createdAt` (same logical fields, port-local grouping) | `RowTests.swift` | Confirmed |
| Row bitmaps carrier | `RowBitmaps` (`RowBitmaps.swift:37`) | `RowBitmaps` (`row_bitmaps.rs:31`) | both public | identical — three `i64` fields; same 216-bit layout constants, `field()`/`bit()`/`field_values()`/`bit_vector()`; reserved-field shift-guard | `RowBitmapsTests.swift`; `row_bitmaps.rs` tests (15) | Confirmed |
| 216-bit vector | `BitVector216` (`RowBitmaps.swift:134`) | `BitVector216` (`row_bitmaps.rs:128`) | both public | identical — `[u8;27]` storage; `from_row_bitmaps`/`from_presence_bytes`/`bit_at`/`bit` mirror Swift inits + accessors | `RowBitmapsTests.swift`; `row_bitmaps.rs` tests | Confirmed |
| Row lifecycle state | `RowState` (`RowState.swift:35`) | `RowState` (`row_state.rs:28`) | both public | identical — `repr(u8)`/`UInt8` raw values, same case ordinals | `RowStateTests.swift` | Confirmed |
| Row verb | `RowVerb` (`RowState.swift:50`) | `RowVerb` (`row_state.rs:66`) | both public | identical — same case set, camelCase ↔ PascalCase | `RowStateTests.swift` | Confirmed |
| Row state error | `RowStateError` (`RowState.swift:65`) | `RowStateError` (`row_state.rs:104`) | both public | identical — `illegalTransition`/`forbiddenCombination` | `RowStateTests.swift` | Confirmed |
| Noun type | `NounType` (`NounType.swift:12`) | `NounType` (`noun_type.rs:8`) | both public | identical — eight `repr(u8)` cases, same ordinals | `NounTypeTests.swift` | Confirmed |
| Lattice anchor | `LatticeAnchor` (`LatticeAnchor.swift:12`) | `LatticeAnchor` (`lattice_anchor.rs:9`) | both public | identical — `udcCode`/`wikidataQID` ↔ snake_case; `unknown`/`udc` constructors | `LatticeAnchorTests.swift` | Confirmed |
| Float matrix | `MatrixF` (`MatrixF.swift:24`) | `MatrixF` (`matrix_f.rs:7`) | both public | identical — row-major `[Float]`/`Vec<f32>` cells, rows×cols | `MatrixFTests.swift`; `matrix_f.rs` tests (5) | Confirmed |
| Cooccurrence-count matrix | `MatrixC` (`MatrixC.swift:27`) | `MatrixC` (`matrix_c.rs:9`) | both public | identical concept — cooccurrence counts; Swift keyed dictionary ↔ Rust `HashMap` | `MatrixCTests.swift`; `matrix_c.rs` tests (4) | Confirmed |
| Odds/pairs matrix | `MatrixO` (`MatrixO.swift:70`) | `MatrixO` (`matrix_o.rs:41`) | both public | identical — `[CooccurrenceKey: Int64]` ↔ `HashMap<CooccurrenceKey,i64>` | `MatrixOTests.swift`; `matrix_o.rs` tests (6) | Confirmed |
| Cooccurrence key | `CooccurrenceKey` (`MatrixO.swift:38`) | `CooccurrenceKey` (`matrix_o.rs:10`) | both public | identical — `row`/`col` `UInt32` ↔ `u32` | `MatrixOTests.swift`; `matrix_o.rs` tests | Confirmed |
| Triple/causality matrix | `MatrixT` (`MatrixT.swift:84`) | `MatrixT` (`matrix_t.rs:51`) | both public | identical — `[CausalityKey: Double]` ↔ `HashMap<CausalityKey,f64>` | `MatrixTTests.swift`; `matrix_t.rs` tests (5) | Confirmed |
| Causality key | `CausalityKey` (`MatrixT.swift:43`) | `CausalityKey` (`matrix_t.rs:7`) | both public | identical — `cause`/`effect`/`lag` `UInt32` ↔ `u32` | `MatrixTTests.swift`; `matrix_t.rs` tests | Confirmed |
| Recall score | `RecallScore` (`RecallTypes.swift:61`) | `RecallScore` (`recall_types.rs:40`) | both public | identical — `(rowId: RowId, score: Float32)` ↔ `(row_id, score: f32)` | `RecallTypesTests.swift`; `recall_types.rs` tests (8) | Confirmed |
| Distance breakdown | `DistanceBreakdown` (`RecallTypes.swift:75`) | `DistanceBreakdown` (`recall_types.rs:63`) | both public | identical — four `Float32`/`f32` contributions; Swift default init ↔ Rust `ZERO`/`Default` | `RecallTypesTests.swift`; `recall_types.rs` tests | Confirmed |
| Recall result | `RecallResult` (`RecallTypes.swift:95`) | `RecallResult` (`recall_types.rs:109`) | both public | identical — `rows`/`breakdown`/`confidenceInterval`/`primitiveName`; Rust adds `simple()` convenience ctor | `RecallTypesTests.swift`; `recall_types.rs` tests | Confirmed |
| Row projection | `RowProjection` (`RecallTypes.swift:118`) | `RowProjection` (`recall_types.rs:156`) | both public | identical — `rowId`/`captureHLC`/`fingerprint`/`lattice`/`bitmaps:(u64,u64,u64)`/`rowState:u8` | `RecallTypesTests.swift`; `recall_types.rs` tests | Confirmed |
| 3-D bit tensor | `ThreeDBitTensor` (`ThreeDBitTensor.swift:36`) | `ThreeDBitTensor` (`bit_tensor.rs:12`) | both public | identical — `xDim`/`yDim`/`zDim` packed bits; `set`/`get` | `ThreeDBitTensorTests.swift` | Confirmed |
| Time range | `TimeRange` (`TimeRange.swift:11`) | `TimeRange` (`time_range.rs:10`) | both public | identical — closed `[start,end]` HLC interval; `contains`/`overlaps` | `TimeRangeTests.swift` | Confirmed |
| Count vector | `CountVector256` (`CountVector256.swift:42`) | `CountVector256` (`count_vector.rs:35`) | both public | identical — 256 `UInt32`/`u32` counts + `n`; `fold` over fingerprints | `CountVector256Tests.swift`; `count_vector.rs` tests (6) | Confirmed |
| Block selection mask | `BlockMask` (`BlockMask.swift:27`) | `BlockMask` (`block_mask.rs:32`) | both public | identical — `u8` mask; Swift `OptionSet` ↔ Rust transparent newtype with same `BLOCK0/1/2/3`/`ALL`/`NONE`, `contains`/`union`/`intersection`/`block_count` | `BlockMaskTests.swift`; `block_mask.rs` tests (8) | Confirmed |
| Hyperplane | `Hyperplane` (`HyperplaneFamily.swift:30`) | `Hyperplane` (`hyperplane.rs:25`) | both public | identical — 256-bit plane | `HyperplaneFamilyTests.swift`; `hyperplane.rs` tests (3) | Confirmed |
| Hyperplane family | `HyperplaneFamily` (`HyperplaneFamily.swift:68`) | `HyperplaneFamily` (`hyperplane.rs:68`) | both public | identical — seeded family of planes | `HyperplaneFamilyTests.swift`; `hyperplane.rs` tests | Confirmed |
| Fingerprint builder ADT | `FingerprintBuilder` (`public indirect enum`, `BitwiseArithmetic.swift:77`) | `FingerprintBuilder` (`bitwise.rs:75`) | both public | identical — `literal`/`intersect`/`difference`/`prototypeOf` ↔ `Literal`/`Intersect`/`Difference`/`PrototypeOf`; same `evaluate()` interpreter. (Audit lists this Rust-only only because its `SWIFT_DECL` regex skips the `indirect` keyword.) | `BitwiseArithmeticTests.swift`; `bitwise.rs` tests (6) | Confirmed |
| Hamming distance/similarity | `Hamming` namespace + `HammingDistance` alias (`Hamming.swift:23`,`:21`) | `hamming::distance` / `hamming::similarity` free fns (`hamming.rs:38`,`:53`) | both public | idiom — Swift caseless-`enum` namespace with static methods ↔ Rust module free functions; identical results, per-block `BlockMask`/`u8` | `HammingTests.swift`; `hamming.rs` tests (5) | Confirmed |
| SimHash signing | `SimHash` namespace (`SimHash.swift:25`) | `simhash::*` free fns (`simhash.rs:38`+) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions (`block`/`fingerprint`/`fingerprint_batch`); identical signing | `SimHashTests.swift`; `simhash.rs` tests (2) | Confirmed |
| SimHash input builders | `SimHashInput` namespace (`SimHash.swift:124`) | `simhash::bitmap_input`/`lattice_input`/`lineage_temporal_input`/`channel_source_input` free fns (`simhash.rs:127`+) | both public | idiom — Swift caseless-`enum` of static `[UInt64]` factories ↔ Rust `Vec<u64>` free functions, one per block; identical packing | `SimHashTests.swift`; `simhash.rs` tests | Confirmed |
| Bitwise fingerprint algebra | `BitwiseArithmetic` namespace (`BitwiseArithmetic.swift:21`) | `bitwise::intersect`/`difference`/`prototype` free fns (`bitwise.rs:29`,`:42`,`:59`) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions; identical AND/XOR/weighted-majority | `BitwiseArithmeticTests.swift`; `bitwise.rs` tests (6) | Confirmed |
| OR-reduce | `ORReduce` namespace (`ORReduce.swift:22`) | `or_reduce::reduce`/`reduce_blocks` free fns (`or_reduce.rs:29`,`:43`) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions; identical bitwise OR fold | `ORReduceTests.swift`; `or_reduce.rs` tests (4) | Confirmed |
| FNV-1a hash | `FNV` namespace (`FNV.swift:18`) | `fnv::hash64`/`hash32`/`hash16` free fns (`fnv.rs:18`,`:31`,`:45`) | both public | idiom — Swift caseless-`enum` namespace ↔ Rust module free functions; identical FNV-1a output | `FNVTests.swift`; `fnv.rs` tests (6) | Confirmed |

The earlier PAR-1A + PAR-3A-ST force-mirror rows (`BlockMask`,
`RowBitmaps`, `BitVector216`, `RecallScore`, `DistanceBreakdown`,
`RecallResult`, `RowProjection`) are folded into the table above with
their file:line anchors and test bindings; no information was dropped.
