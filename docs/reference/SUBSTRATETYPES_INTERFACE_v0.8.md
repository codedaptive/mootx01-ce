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
  Public API surface of SubstrateTypes in both legs. Twenty-four
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

**Rust:** `RowId(u128)`, `Row`, `RowBitmaps`, `BitVector216` — same
shape, snake_case fields.

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

Recall scoring tuple. SPEC § 5 (background).

**Swift:**

```swift
public struct RecallScore: Equatable, Sendable {
    public let total: Double
    public let breakdown: DistanceBreakdown
}
public struct DistanceBreakdown: Equatable, Sendable {
    public let semantic: Double       // SimHash Hamming distance
    public let temporal: Double       // HLC distance
    public let lattice: Double        // UDC tree distance
}
public struct RecallResult: Sendable {
    public let rowId: RowId
    public let score: RecallScore
    public let projection: RowProjection
}
public struct RowProjection: Sendable {
    public let bitmaps: BitmapFields
    public let latticeAnchor: LatticeAnchor?
    public let state: RowState
    public let asOf: HLC
}
```

**Rust:** same shapes, snake_case.

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

**Rust:** bitflags-style.

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

Bit-difference count between two fingerprints. SPEC § 5.7.

**Swift:**

```swift
public enum Hamming {
    public static func distance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int
    public static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int
}
public typealias HammingDistance = Hamming
```

**Rust:**

```rust
pub fn hamming_distance_256(a: &Fingerprint256, b: &Fingerprint256) -> u32;
pub fn hamming_distance(a: &[u8], b: &[u8]) -> u32;
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
use substrate_types::{Fingerprint256, hamming, hlc::HLCGenerator,
                      audit_event::AuditEntry, gset::{GSetAuditLog, AuditVerb, AuditValue}};

let a = Fingerprint256::from_words((0x1234_5678_9abc_def0, 0, 0, 0));
let b = Fingerprint256::from_words((0xfedc_ba98_7654_3210, 0, 0, 0));
let c = a.xor(&b);
let dist = hamming::hamming_distance_256(&a, &b);

let mut gen = HLCGenerator::new(0xABCDEF);
let h1 = gen.send(/* now millis */ 1_700_000_000_000);
```
