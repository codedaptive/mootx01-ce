---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-27
version: v0.8
package: SubstrateLib
languages: [swift, rust]
relates_to:
  - SUBSTRATELIB_SPEC_v0.8.md  (the contract this interface implements)
purpose: |
  Public API surface of SubstrateLib in both ports, in two tiers within
  § 2. Tier 1 is the CONSUMED CONTRACT — the 18 types other packages
  actually import — documented in full with bilingual signatures. Tier 2
  (§ 2's closing subsection) is the BROADER LIBRARY SURFACE — the
  remaining ~99 public types that exist in the library but are not yet
  consumed by the system; a table of contents (name + role + source
  file) for future builders, not full signatures. The companion SPEC
  carries the behavioral contracts (invariants I-1…I-7, conformance
  C-1…C-6).
---

# SubstrateLib Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateLib/`

- `Sources/SubstrateLib/` — 44 files, one per primitive or algorithm
  family.
- `Tests/SubstrateLibTests/`, `Tests/SubstrateLibConformanceTests/`
- `Package.swift`

**Rust:** `packages/libs/SubstrateLib/rust/`

- `rust/lib.rs` plus per-family `rust/glref-rust-*.rs` reference files
  (crate `substrate-lib`).

Naming differs by port convention (Swift `ScalarKernel()` /
`hammingDistance256`; Rust `ScalarKernel` / `hamming_distance_256`); the
*results* are bit-for-bit identical (SPEC § 4, I-1 / I-7).

> **Two-tier surface.** SubstrateLib declares 117 public types, but only
> 18 are consumed by other packages today. § 2 Tier 1 documents those 18
> in full — the contract the system actually depends on. The Tier 2
> subsection at the end of § 2 is a table of contents for the rest:
> present in the library, not yet consumed, kept so future builders can
> find them.

## § 2 — Public types

### Tier 1 — consumed contract

#### `Fingerprint256`

The universal 256-bit hash unit (SPEC § 4, I-2).

```swift
public struct Fingerprint256: Hashable, Sendable, Codable {
    public var block0, block1, block2, block3: UInt64
    public init(block0: UInt64, block1: UInt64, block2: UInt64, block3: UInt64)
    public static let zero: Fingerprint256
    public var words: [UInt64] { get }
    public func bit(at index: Int) -> Bool
    public func testBit(at index: Int) -> Bool
    public mutating func setBit(at index: Int, to on: Bool = true)
    public func block(at index: Int) -> UInt64
    public func bitwiseOR(_ other: Fingerprint256) -> Fingerprint256
    public static func fromBits(_ bits: [Bool]) -> Fingerprint256
    public var wireBytes: [UInt8] { get }
    public init(wireBytes bytes: [UInt8]) throws   // Fingerprint256Error.invalidWireLength
}
```
**Rust:** `pub struct Fingerprint256 { block0..block3: u64 }` with `ZERO`,
`bit`, `set_bit`, `bitwise_or`, `wire_bytes`, `from_wire_bytes`.

#### `Hamming`

```swift
public enum Hamming {
    public static func distance(_ a: Fingerprint256, _ b: Fingerprint256) -> Int   // 0…256
    public static func similarity(_ a: Fingerprint256, _ b: Fingerprint256) -> Double // 1 − d/256
}
```

#### `CountVector256`

Per-bit count fold over a set of fingerprints; majority vote.

```swift
public struct CountVector256: Sendable, Equatable, Codable {
    public static let zero: CountVector256
    public init()
    public init(counts: [UInt32], n: UInt32)
    public static func + (lhs: CountVector256, rhs: CountVector256) -> CountVector256
    public func majorityVote() -> Fingerprint256
    public func profile() -> [Float]
    public static func fold(_ fingerprints: [Fingerprint256]) -> CountVector256
}
```

#### `SimHash` / `SimHashInput` / `FloatSimHash` / `HyperplaneFamily`

The SimHash fingerprinting family — block projection from typed inputs.

```swift
public enum SimHash {
    public static func block(over v: [UInt64], /* planes */ …) -> UInt64
    public static func fingerprint(bitmapInput: [UInt64], …) -> Fingerprint256
    public static func fingerprintBatch(bitmapInputs: [[UInt64]], …) -> [Fingerprint256]
    public static func fingerprint(fromSubhashes subhashes: [UInt64], …) -> Fingerprint256
}
public enum SimHashInput {   // builds the [UInt64] input vector per block
    public static func bitmap(adjective: UInt64, …) -> [UInt64]
    public static func lattice(udcPrefixHash: UInt16, …) -> [UInt64]
    public static func lineageTemporal(lineageHash: UInt16, …) -> [UInt64]
    public static func channelSource(channel: UInt8, …) -> [UInt64]
}
public enum FloatSimHash {
    public static func project(vector: [Float], seed: UInt64) -> Fingerprint256
}
public struct Hyperplane: Sendable, Codable, Equatable {
    public let positiveMask: [UInt64]; public let negativeMask: [UInt64]; public let bitLength: Int
    public init(positiveMask: [UInt64], negativeMask: [UInt64], bitLength: Int)
    public func sign(over v: [UInt64]) -> Bool
}
public struct HyperplaneFamily: Sendable, Codable, Equatable {
    public let blockIndex: Int          // 0…3
    public let inputBitLength: Int      // 192 for block 0, 64 for blocks 1–3
    public let planes: [Hyperplane]     // exactly 64
    public static func generate(seed: [UInt8], …) -> HyperplaneFamily
    public func canonicalHash() -> UInt64
}
```

#### `SubstrateKernel` / `PortableKernel`

The compute protocol and dispatcher. Consumers obtain a kernel from
`PortableKernel`; the scalar backend is the reference (SPEC § 4, I-1).
The backend structs themselves (`ScalarKernel`, `SimdKernel`, …) are
Tier 2 — consumers do not name them directly.

```swift
public protocol SubstrateKernel: Sendable {
    var kind: KernelKind { get }
    func popcount64(_ x: UInt64) -> Int
    func hammingDistance256(_ a: Fingerprint256, _ b: Fingerprint256) -> Int
    func orReduce256(_ fingerprints: [Fingerprint256]) -> Fingerprint256
    func hammingTopK(probe: Fingerprint256, candidates: [Fingerprint256], k: Int) -> [HammingNNHit]
    func simhashCompute(subhashes: [UInt64], …) -> Fingerprint256
    func countFold256(_ fingerprints: [Fingerprint256]) -> CountVector256
    // + batch variants (hammingDistanceBatch, simhashBlockBatch, orReduceBatch, countFoldBatch)
}
public enum PortableKernel {
    public static func kernelForCurrentPlatform() -> SubstrateKernel
    public static func kernel(of kind: KernelKind) -> SubstrateKernel
}
```
**Rust:** `pub trait SubstrateKernel: Send + Sync` + dispatcher.

#### `HLC` / `HLCGenerator`

Hybrid Logical Clock; total order; packed form (SPEC § 4, I-5).

```swift
public struct HLC: Hashable, Sendable, Codable, Comparable {
    public let physicalTime: Int64
    public let logicalCount: Int32
    public let nodeID: Int32
    public init(physicalTime: Int64, logicalCount: Int32, nodeID: Int32)
    public static let zero: HLC
    public func advanced() -> HLC
    public var packed: UInt64 { get }
    public init(packed: UInt64)
    public static func < (lhs: HLC, rhs: HLC) -> Bool
}
public struct HLCGenerator: Sendable {
    public let nodeID: Int32
    public init(nodeID: Int32, lastPhysical: Int64 = 0, lastLogical: Int32 = 0)
    public mutating func send(now: Int64) -> HLC
    public mutating func receive(remote: HLC, now: Int64) -> HLC
}
```

#### Row / verb value model: `LatticeAnchor`, `Row`, `AuditEvent`, `AuditVerb`, `Substrate`

The in-memory value model the persistence layer mirrors. `Substrate` is
a value-type facade that applies the nine verbs to a row set and appends
audit events (the runtime ARIA vocabulary lives in `AriaLexiconLib`).

```swift
public struct LatticeAnchor: Hashable, Sendable {
    public let udcCode: UInt64
    public let qidPointer: UInt64      // 0 == null
    public var isNull: Bool { get }
    public static func udc(_ udcString: String) -> LatticeAnchor
}
public struct Row: Sendable {
    public let id: UUID
    public let nounType: NounType            // Tier 2 enum
    public var state: RowStateValue
    public var adjectiveBitmap: Int64
    public var operationalBitmap: Int64
    public var provenanceBitmap: Int64
    public var fingerprint: Fingerprint256
    public var latticeAnchor: LatticeAnchor
    public var lineageId: UUID?
    public var content: Data?
}
public struct AuditEvent: Sendable {
    public let eventID: UUID
    public let estateUuid: UUID
    public let rowId: UUID
    public let hlc: HLC
    public let verb: String
    public let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
    // … afterBitmaps and related fields; compound key (eventID, hlc) gives append idempotence
}
public enum AuditVerb: String, Sendable, Codable {
    case capture, mutate, retract, sync, pair, unpair, derive, decay, promote, migrate, dreamCompact
}
public struct Substrate {
    public let estateUuid: UUID
    public var rows: [UUID: Row]
    public var auditEvents: [AuditEvent]     // appended; treat as G-Set
    public var hlc: HLC
    public var rowCountActive: Int64
    public init(estateUuid: UUID, hlc: HLC)

    public enum MutationKind: String {
        case confirm, reject, contest, supersede
        case automatedConfirm = "automated_confirm"
        case decay, expire
        case lineageAdvance = "lineage_advance"
        case actuatorConfirm = "actuator_confirm"
    }
    // The nine verbs, applied in-memory (mutating; append audit events):
    public mutating func capture(/* … */)
    public mutating func reanchor(/* … */)
    public mutating func mutate(rowId: UUID, mutationKind: MutationKind, /* … */)
    public mutating func withdraw(/* … */)
    public mutating func expunge(/* … */)
    public func recall(matching predicate: (Row) -> Bool, /* … */) -> [Row]
    public mutating func propose(/* … */)
    public mutating func associate(/* … */)
    public mutating func learn(/* … */)
}
```
**Rust:** `verbs` module mirrors `Substrate`, `Row`, `AuditEvent`,
`MutationKind`, `LatticeAnchor`.

#### `SplitMix64`

Deterministic RNG (seeded; no ambient entropy).

```swift
public struct SplitMix64 {
    public var state: UInt64
    public init(seed: UInt64)
    public mutating func next() -> UInt64
}
```

### Tier 2 — broader library surface (table of contents)

The following public types are **present in the library but not yet
consumed by any other package** (measured against all package Sources,
2026-05-27). Recorded here as a navigable index for future builders —
name, role, source file. Full signatures live in the cited file; promote
a type into Tier 1 when a consumer adopts it.

- **Kernel backends:** `ScalarKernel` (the reference impl), `SimdKernel`,
  `NeonKernel`, `BnnsKernel`, `MetalKernel`, `KernelKind` — `PortableKernel*.swift`.
- **Audit CRDT (G-Set):** `GSetAuditLog`, `AuditEntry`, `AuditValue` —
  `GSetAuditLog.swift`. (The consumed audit type is `AuditEvent`, Tier 1.)
- **Row-state machine:** `RowState`, `RowStateValue`, `RowVerb`,
  `RowStateAutomaton`, `RowStateError`, `NounType`, `ProjectedRowState`,
  `RowProjection`, `TransitionKey`, `RowId` — `Verbs.swift`,
  `RowStateAutomaton.swift`, `PartialStateRecall.swift`.
- **Distances:** `CompositeDistance`, `DistanceBreakdown`, `LatticeDistance`,
  `UDCTreeDistance`, `WikidataGraphDistance`, `HammingNN`, `HammingNNHit` —
  `CompositeDistance.swift`, `LatticeDistance.swift`, `HammingNN.swift`.
- **Matrices:** `MatrixF`, `MatrixC`, `MatrixO`, `MatrixT`, `MatrixDecay`,
  `DecayingMatrix` — `Matrix*.swift`.
- **Ranking / graph:** `BradleyTerryEstimator`, `PreferenceObservation`,
  `EigenvalueCentrality`, `CommunityDetection`, `RandomWalks`,
  `ActionOutcomeMatrix`, `ActionOutcomeCell`, `ActionOutcomeKey`,
  `CooccurrenceKey`, `CausalityKey`, `WikidataAdjacencyProvider` —
  `BradleyTerry.swift`, `EigenvalueCentrality.swift`, `CommunityDetection.swift`,
  `RandomWalks.swift`, `ActionOutcomeMatrix.swift`.
- **Signal / info / stats:** `FFT`, `Complex`, `InformationTheory`,
  `MomentSummary`, `AnomalyDetection`, `TemporalCompression`,
  `LLMCalibrationCurve`, `NMFAlternatingLeastSquares`, `NMFFactorization`,
  `DPORReduction`, `DPParameters`, `ORReduce`, `BitwiseArithmetic`,
  `ThreeDBitTensor` — respective `*.swift`.
- **Recall / tier:** `RecallResult`, `RecallScore`, `TierAscendingQuery`,
  `TierAscendingQueryProtocol`, `TargetTier`, `TierContribution`,
  `TierContributionFingerprint`, `PartialStateRecall`, `TimeRange`,
  `TemporalWindow` — `RecallTypes.swift`, `TierAscendingQuery.swift`,
  `TierContributionFingerprint.swift`.
- **Feature extractors (caller-supplied samples, no live I/O):**
  `HealthKitExtractor`/`HealthKitSample`, `CoreLocationExtractor`/`CoreLocationSample`,
  `EventKitExtractor`/`EventKitSample`, `ScreenTimeExtractor`/`ScreenTimeSample`,
  `SystemTelemetryExtractor`/`SystemTelemetrySample`, `AmbientSampleRow`,
  `RhythmAnalysis`/`RhythmResult`, `StreamSourceFlag` — `FeatureExtractors.swift`.
- **Pairing / federation:** `PairingHandshake`, `PairingNonce`,
  `PairingRecord`, `PeerResponse`, `PairingAuditPayload`, `PrivacyLedger`,
  `FederationCase`, `ForbiddenCombinations` — `PairingHandshake.swift`.
- **Decay / misc:** `DecayHalfLives`, `WindowLevel`, `BitmapFields`,
  `LatticeAnchorStr` — respective `*.swift`.

## § 3 — Public functions

The principal Tier-1 entry points (types in § 2):

```swift
PortableKernel.kernelForCurrentPlatform() -> SubstrateKernel
Hamming.distance(_:_:) -> Int            // 0…256
kernel.orReduce256([Fingerprint256]) -> Fingerprint256
CountVector256.fold([Fingerprint256]) -> CountVector256
SimHash.fingerprint(bitmapInput:…) -> Fingerprint256
FloatSimHash.project(vector:seed:) -> Fingerprint256
HyperplaneFamily.generate(seed:…) -> HyperplaneFamily
```

## § 4 — Errors

```swift
public enum Fingerprint256Error: Error, Sendable { case invalidWireLength(Int) }
public enum RowStateError: Error, Sendable, Equatable          // illegal transitions (Tier 2)
public enum SubstrateError: Error, Equatable                   // pairing / precondition (Tier 2)
```
**Rust:** `FingerprintError`, `HLCError`, `SubstrateError`. Meaning: SPEC § 6.

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/libs/SubstrateLib
```

(Targets: `SubstrateLibTests`, `SubstrateLibConformanceTests` — the
latter runs the shared `glref` vectors against each kernel backend.)

**Rust:**

```
cargo test -p substrate-lib
```

## § 6 — Examples

```swift
import SubstrateLib

let kernel = PortableKernel.kernelForCurrentPlatform()   // results == scalar reference
let d = kernel.hammingDistance256(a, b)                  // 0…256
let merged = kernel.orReduce256([a, b, c])               // associative, commutative

var gen = HLCGenerator(nodeID: 1)
let stamp = gen.send(now: 1_716_800_000)                 // time passed in, never read internally
```

---

*End of SubstrateLib Interface v0.8.*
