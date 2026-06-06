---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-05-29
version: v0.8
package: SubstrateML
languages: [swift, rust]
relates_to:
  - SUBSTRATEML_SPEC_v0.8.md  (the contract this interface implements)
  - SUBSTRATETYPES_INTERFACE_v0.8.md  (Layer 1 types consumed)
  - SUBSTRATEKERNEL_INTERFACE_v0.8.md  (Layer 2 primitives consumed)
purpose: |
  Public API surface of SubstrateML in both ports. Twenty-five Swift
  files publish the cold-path algorithms over substrate types: the
  audit-log fold, matrix decay, Bradley-Terry estimation, NMF, FFT,
  eigenvalue centrality, lattice distance, anomaly / community
  detection, feature extractors, float-input SimHash, moment summary,
  partial-state recall, pairing handshake, tier-contribution
  fingerprint, tier-ascending query, action-outcome matrix, DP-OR
  reduction, LLM calibration curve, information theory, temporal
  compression, pairwise association-rule mining, and bounded formal
  concept analysis. The Rust mirror exposes the same shapes.
---

# SubstrateML Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateML/`

- `Sources/SubstrateML/` — 25 files, one per algorithm or family.
- `Tests/SubstrateMLTests/` — unit + conformance.
- `Package.swift` — depends on `SubstrateTypes`, `SubstrateKernel`.

**Rust:** `packages/libs/SubstrateML/rust/`

- `src/lib.rs` — crate root.
- `src/<algorithm>.rs` — per-algorithm module.
- `tests/` — conformance.
- `Cargo.toml` — depends on `substrate-types`, `substrate-kernel`.

Naming differs by port convention; *results* are bit-for-bit
identical for federation-affecting algorithms (SPEC § 7, ML-5).

## § 2 — Public types

This section lists the top-level public types per algorithm. Where
an algorithm exposes only a namespace `enum X { static func ... }`
plus its result type(s), the namespace is listed but signatures
live in § 3.

### `ProjectedRowState`, `AuditLogFold`

SPEC § 5.1.

```swift
public struct ProjectedRowState: Sendable, Equatable {
    public let rowId: RowId
    public let bitmaps: BitmapFields
    public let latticeAnchor: LatticeAnchor?
    public let state: RowState
    public let asOf: HLC
}

public enum AuditLogFold {
    public static func projectStateAt(
        rowId: RowId,
        asOf: HLC,
        log: GSetAuditLog
    ) -> ProjectedRowState?
    public static func projectCurrentState(
        rowId: RowId,
        log: GSetAuditLog
    ) -> ProjectedRowState?
}
```

```rust
pub struct ProjectedRowState { /* same fields */ }
pub fn project_state_at(row_id: RowId, as_of: HLC, log: &GSetAuditLog) -> Option<ProjectedRowState>;
pub fn project_current_state(row_id: RowId, log: &GSetAuditLog) -> Option<ProjectedRowState>;
```

### `DecayingMatrix`, `MatrixDecay`, `DecayHalfLives`

SPEC § 5.2.

```swift
public struct DecayingMatrix: Sendable {
    public let matrix: MatrixC          // or MatrixO, MatrixT — see overloads
    public let lastTouched: HLC
}
public enum MatrixDecay {
    public static func decay(_ m: DecayingMatrix, halfLife: TimeInterval, asOf: HLC) -> DecayingMatrix
}
public enum DecayHalfLives {
    public static let matrixC: TimeInterval = 30 * 86_400  // 30 days
    public static let matrixO: TimeInterval = 14 * 86_400
    public static let matrixT: TimeInterval =  7 * 86_400
}
```

```rust
pub struct DecayingMatrix { /* same */ }
pub fn decay(m: &DecayingMatrix, half_life_secs: f64, as_of: HLC) -> DecayingMatrix;
pub mod decay_half_lives { pub const MATRIX_C: f64 = 30.0 * 86_400.0; /* ... */ }
```

### `PreferenceObservation`, `BradleyTerryEstimator`

SPEC § 5.3.

```swift
public struct PreferenceObservation: Sendable {
    public let winner: UInt32
    public let loser: UInt32
    public let weight: Double           // > 0
}
public struct BradleyTerryEstimator: Sendable {
    public init(itemCount: Int)
    public mutating func update(_ obs: PreferenceObservation) throws
    public func strength(_ item: UInt32) -> Double
    public func strengths() -> [Double]
}
```

```rust
pub struct PreferenceObservation { pub winner: u32, pub loser: u32, pub weight: f64 }
pub struct BradleyTerryEstimator { /* internal */ }
impl BradleyTerryEstimator {
    pub fn new(item_count: usize) -> Self;
    pub fn update(&mut self, obs: PreferenceObservation) -> Result<(), &'static str>;
    pub fn strength(&self, item: u32) -> f64;
    pub fn strengths(&self) -> Vec<f64>;
}
```

### `NMFFactorization`, `NMFAlternatingLeastSquares`

SPEC § 5.4.

```swift
public struct NMFFactorization: Sendable {
    public let W: [[Float32]]   // m × k
    public let H: [[Float32]]   // k × n
    public let rank: Int
    public let iterations: Int
    public let finalError: Float32
}
public enum NMFAlternatingLeastSquares {
    // Precondition: V rectangular, all entries finite, all entries ≥ 0
    // (Lee-Seung theorem requires V ≥ 0). Violations trigger precondition.
    public static func factorize(V: [[Float32]],
                                 rank: Int,
                                 maxIterations: Int = 100,
                                 tolerance: Float32 = 1e-4,
                                 seed: UInt64 = 0xDEADBEEFCAFEBABE) -> NMFFactorization
}
```

```rust
pub struct NMFFactorization { pub w: Vec<Vec<f32>>, pub h: Vec<Vec<f32>>,
                              pub rank: usize, pub iterations: usize, pub final_error: f32 }
// Same preconditions as Swift; violations panic.
pub fn factorize(v: &[Vec<f32>], rank: usize, max_iterations: usize,
                 tolerance: f32, seed: u64) -> NMFFactorization;
```

### `Complex`, `FFT`, `RhythmResult`

SPEC § 5.5.

```swift
public struct Complex: Hashable, Sendable {
    public let real: Double
    public let imag: Double
}
public enum FFT {
    public static func forward(_ signal: [Complex]) -> [Complex]
    public static func inverse(_ spectrum: [Complex]) -> [Complex]
    public static func detectRhythm(signal: [Double], samplingRate: Double) -> RhythmResult
}
public struct RhythmResult: Sendable, Hashable {
    public let dominantFrequencyHz: Double
    public let confidence: Double
}
public enum RhythmAnalysis {
    public static func analyze(signal: [Double], samplingRate: Double) -> RhythmResult
}
```

```rust
pub struct Complex { pub real: f64, pub imag: f64 }
pub fn fft_forward(signal: &[Complex]) -> Vec<Complex>;
pub fn fft_inverse(spectrum: &[Complex]) -> Vec<Complex>;
pub fn detect_rhythm(signal: &[f64], sampling_rate: f64) -> RhythmResult;
pub struct RhythmResult { pub dominant_frequency_hz: f64, pub confidence: f64 }
```

### `EigenvalueCentrality`

SPEC § 5.6.

```swift
public enum EigenvalueCentrality {
    public static func computeCentrality(graph: MatrixF, iterations: Int) -> [Double]
}
```

```rust
pub fn eigenvalue_centrality(graph: &MatrixF, iterations: usize) -> Vec<f64>;
```

### `RandomWalks`, `SplitMix64`

SPEC § 5 (background).

```swift
public struct SplitMix64 {
    public init(seed: UInt64)
    public mutating func next() -> UInt64
}
public enum RandomWalks {
    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]
    // Precondition: every neighbor index in [0, N); every weight finite and ≥ 0.
    public static func walk(adjacency: Adjacency, start: Int, length: Int,
                            restartProb: Double = defaultRestartProb, seed: UInt64) -> [Int]
    // Precondition: neighbors must be non-empty.
    public static func sampleWeighted(_ neighbors: [(neighbor: Int, weight: Double)],
                                      rng: inout SplitMix64) -> Int
}
```

```rust
pub struct SplitMix64 { pub state: u64 }
impl SplitMix64 { pub fn new(seed: u64) -> Self; pub fn next(&mut self) -> u64; }
// Same preconditions as Swift; violations panic.
pub fn walk(adjacency: &[Vec<(usize, f64)>], start: usize, length: usize,
            restart_prob: f64, seed: u64) -> Vec<usize>;
pub fn sample_weighted(neighbors: &[(usize, f64)], rng: &mut SplitMix64) -> usize;
```

### `LatticeAnchorStr`, `UDCTreeDistance`, `LatticeDistance`, `WikidataAdjacencyProvider`

SPEC § 5.7.

```swift
public struct LatticeAnchorStr: Hashable, Sendable {
    public let udcCode: String
}
public enum UDCTreeDistance {
    public static func distance(_ a: LatticeAnchorStr, _ b: LatticeAnchorStr) -> Double
}
public protocol WikidataAdjacencyProvider {
    func areAdjacent(_ a: String, _ b: String) -> Bool
}
public enum LatticeDistance {
    public static func combined(
        _ a: LatticeAnchorStr,
        _ b: LatticeAnchorStr,
        wikidataAdjacency: (any WikidataAdjacencyProvider)?
    ) -> Double
}
public enum WikidataGraphDistance {
    public static func distance(_ a: String, _ b: String, provider: any WikidataAdjacencyProvider) -> Double
}
```

```rust
pub struct LatticeAnchorStr { pub udc_code: String }
pub fn udc_tree_distance(a: &LatticeAnchorStr, b: &LatticeAnchorStr) -> f64;
pub trait WikidataAdjacencyProvider { fn are_adjacent(&self, a: &str, b: &str) -> bool; }
pub fn lattice_combined_distance(a: &LatticeAnchorStr, b: &LatticeAnchorStr, wikidata: Option<&dyn WikidataAdjacencyProvider>) -> f64;
```

### `CompositeDistance`

SPEC § 5.8.

```swift
public enum CompositeDistance {
    public static func score(
        semantic: Double,
        temporal: Double,
        lattice: Double,
        weights: (Double, Double, Double)
    ) -> Double
}
```

```rust
pub fn composite_score(semantic: f64, temporal: f64, lattice: f64, weights: (f64, f64, f64)) -> f64;
```

### `StreamSourceFlag`, `AmbientSampleRow`, the five extractors + their samples, `FeatureExtractors`

SPEC § 5.9. Five platform-specific extractor structs each take a typed
`*Sample` and produce an `AmbientSampleRow`; `FeatureExtractors` is the
namespace facade over them.

```swift
public enum StreamSourceFlag: UInt8, Sendable {
    case coreLocation = 0, eventKit = 1, healthKit = 2, screenTime = 3, systemTelemetry = 4
}
public struct AmbientSampleRow: Sendable {
    public let source: StreamSourceFlag
    public let hlc: HLC
    public let payload: Data
    public let derivedFingerprint: Fingerprint256
}
// Typed per-source samples (each `Sendable`, per cookbook §11.4):
public struct HealthKitSample: Sendable { /* … */ }
public struct CoreLocationSample: Sendable { /* … */ }
public struct EventKitSample: Sendable { /* … */ }
public struct ScreenTimeSample: Sendable { /* … */ }
public struct SystemTelemetrySample: Sendable { /* … */ }
// Concrete extractor structs, one per source:
public struct CoreLocationExtractor { /* extract(_:CoreLocationSample) -> AmbientSampleRow */ }
public struct EventKitExtractor { /* extract(_:EventKitSample) -> AmbientSampleRow */ }
public struct HealthKitExtractor { /* extract(_:HealthKitSample) -> AmbientSampleRow */ }
public struct ScreenTimeExtractor { /* extract(_:ScreenTimeSample) -> AmbientSampleRow */ }
public struct SystemTelemetryExtractor { /* extract(_:SystemTelemetrySample) -> AmbientSampleRow */ }
public enum FeatureExtractors {
    public static func extractAmbientSample(source: StreamSourceFlag, rawRecord: Data, hlc: HLC) -> AmbientSampleRow
    public static func extractHealthKit(sample: HealthKitSample) -> AmbientSampleRow
}
```

```rust
pub enum StreamSourceFlag { CoreLocation, EventKit, HealthKit, ScreenTime, SystemTelemetry }
pub struct AmbientSampleRow { /* same fields, snake_case */ }
pub struct CoreLocationSample { /* … */ } pub struct EventKitSample { /* … */ }
pub struct HealthKitSample { /* … */ } pub struct ScreenTimeSample { /* … */ }
pub struct SystemTelemetrySample { /* … */ }
pub struct CoreLocationExtractor; pub struct EventKitExtractor; pub struct HealthKitExtractor;
pub struct ScreenTimeExtractor; pub struct SystemTelemetryExtractor;
pub fn extract_ambient_sample(source: StreamSourceFlag, raw: &[u8], hlc: HLC) -> AmbientSampleRow;
```

### `FloatSimHash`

SPEC § 5.10.

```swift
public enum FloatSimHash {
    public static func sign(embedding: [Float], family: HyperplaneFamily) -> Fingerprint256
}
```

```rust
pub fn float_simhash_sign(embedding: &[f32], family: &HyperplaneFamily) -> Fingerprint256;
```

### `RowLite`, `MomentSummary`

SPEC § 5.11.

```swift
public struct RowLite: Sendable, Hashable {
    public let count: Int
    public let meanFingerprint: Fingerprint256
    public let dominantLatticeAnchor: LatticeAnchor?
}
public enum MomentSummary {
    public static func summarize(rows: [Row], window: TimeRange, asOf: HLC) -> RowLite
}
```

```rust
pub struct RowLite { /* same */ }
pub fn moment_summarize(rows: &[Row], window: &TimeRange, as_of: HLC) -> RowLite;
```

### `PartialStateRecall`

SPEC § 5.12.

```swift
public enum PartialStateRecall {
    public static func recall(
        query: Fingerprint256,
        mask: Fingerprint256,
        candidates: [Fingerprint256],
        topK: Int
    ) -> [HammingNNHit]
}
```

```rust
pub fn partial_state_recall(query: &Fingerprint256, mask: &Fingerprint256, candidates: &[Fingerprint256], top_k: usize) -> Vec<HammingNNHit>;
```

### `PairingNonce`, `PairingRecord`, `PairingHandshake`

SPEC § 5.13.

```swift
public struct PairingNonce: Sendable, Equatable {
    public let bytes: [UInt8]
    public let issuedAt: HLC
}
public struct PairingRecord: Sendable, Equatable {
    public let peerId: String
    public let establishedAt: HLC
    public let signature: [UInt8]
}
public enum PairingHandshake {
    public static func generateNonce(now: HLC) -> PairingNonce
    public static func validate(nonce: PairingNonce, response: [UInt8]) -> Bool
    // PairingAuditPayload — the audit record a handshake emits (nested):
    public struct PairingAuditPayload: Sendable, Equatable {
        public let peerId: String; public let nonce: PairingNonce; public let acceptedAt: HLC
    }
}
```

```rust
pub struct PairingNonce { pub bytes: Vec<u8>, pub issued_at: HLC }
pub struct PairingRecord { pub peer_id: String, pub established_at: HLC, pub signature: Vec<u8> }
pub fn pairing_generate_nonce(now: HLC) -> PairingNonce;
pub fn pairing_validate(nonce: &PairingNonce, response: &[u8]) -> bool;
```

### `FederationCase`, `TierContribution`, `TierContributionFingerprint`

SPEC § 5.14.

```swift
public enum FederationCase: UInt32, Sendable {
    case selfOnly = 0
    case selfPlusPeers = 1
    case peersOnly = 2
}
public struct TierContribution: Sendable, Equatable {
    public let tier: UInt8
    public let fingerprints: [Fingerprint256]
}
public enum TierContributionFingerprint {
    public static func combine(_ contributions: [TierContribution]) -> Fingerprint256
}
```

```rust
pub enum FederationCase { SelfOnly, SelfPlusPeers, PeersOnly }
pub struct TierContribution { pub tier: u8, pub fingerprints: Vec<Fingerprint256> }
pub fn tier_contribution_combine(contributions: &[TierContribution]) -> Fingerprint256;
```

### `TargetTier`, `TierAscendingQuery`, `PeerResponse`

SPEC § 5.14.

```swift
public enum TargetTier: String, Sendable {
    case t1, t2, t3
}
public struct PeerResponse: Sendable {
    public let peerId: String
    public let contribution: TierContribution
}
public struct TierAscendingQuery: Sendable {
    public let target: TargetTier
    public let issuer: String
    public let issuedAt: HLC
    public func aggregate(_ responses: [PeerResponse]) -> Fingerprint256
}
public enum TierAscendingQueryProtocol {
    // the wire-protocol namespace: request/response framing for a tier-ascending query
    public static func frame(_ query: TierAscendingQuery) -> Data
}
public struct PrivacyLedger: Sendable {
    // running record of what crossed estate/tier boundaries during a query (DP accounting)
    public init()
    public mutating func record(source: StreamSourceFlag, epsilonSpent: Double)
    public var totalEpsilon: Double { get }
}
```

```rust
pub enum TargetTier { T1, T2, T3 }
pub struct PeerResponse { /* … */ }
pub struct TierAscendingQuery { /* … */ }
impl TierAscendingQuery { pub fn aggregate(&self, responses: &[PeerResponse]) -> Fingerprint256; }
```

### `ActionOutcomeKey`, `ActionOutcomeCell`, `ActionOutcomeMatrix`

SPEC § 5.15.

The matrix is keyed by `(actionKind, outcomeCategory)` — both 6-bit fields
(bitmaps o07/o08, each `< 64`). A cell counts successes against totals; the
empirical `successRate` and a 95 % `wilsonLowerBound` are derived. `topActions`
ranks by the Wilson lower bound (so under-observed cells don't float to the
top) and returns all four signals together, so callers rank and read from the
same values.

```swift
public struct ActionOutcomeKey: Hashable, Comparable, Sendable {
    public let actionKind: UInt8        // 6-bit field (bitmap o07), < 64
    public let outcomeCategory: UInt8   // 6-bit field (bitmap o08), < 64
    public init(actionKind: UInt8, outcomeCategory: UInt8)
    public var packed: UInt16           // (actionKind << 8) | outcomeCategory
}
public struct ActionOutcomeCell: Equatable, Sendable {
    public var successCount: UInt32
    public var totalCount: UInt32
    public var lastUpdateHLC: HLC
    public var successRate: Float32       // successCount/totalCount; 0 when empty
    public var wilsonLowerBound: Float32  // 95 % Wilson interval LB; always ≤ successRate
}
public struct ActionOutcomeMatrix: Sendable {
    public private(set) var cells: [ActionOutcomeKey: ActionOutcomeCell]
    public init()
    public mutating func observe(action: UInt8, outcome: UInt8, success: Bool, at hlc: HLC)
    public func successRate(action: UInt8, outcome: UInt8) -> Float32?
    public func observationCount(action: UInt8, outcome: UInt8) -> UInt32
    // Ranked by Wilson lower bound; ties broken by count desc, then action asc.
    public func topActions(forOutcome outcome: UInt8, k: Int, minObservations: UInt32 = 1)
        -> [(action: UInt8, rate: Float32, wilsonLowerBound: Float32, count: UInt32)]
}
```

```rust
pub struct ActionOutcomeKey { pub action_kind: u8, pub outcome_category: u8 }  // each < 64
pub struct ActionOutcomeCell {
    pub success_count: u32,
    pub total_count: u32,
    pub last_update_hlc: HLC,
    // success_rate() and wilson_lower_bound() -> f32 are methods
}
pub struct ActionOutcomeMatrix { /* keyed (action_kind, outcome_category) cells */ }
impl ActionOutcomeMatrix {
    pub fn new() -> Self;
    pub fn observe(&mut self, action: u8, outcome: u8, success: bool, hlc: HLC);
    pub fn success_rate(&self, action: u8, outcome: u8) -> Option<f32>;
    pub fn observation_count(&self, action: u8, outcome: u8) -> u32;
    // Returns (action_kind, success_rate, wilson_lower_bound, total_count), Wilson-ranked.
    pub fn top_actions(&self, outcome: u8, k: usize, min_observations: u32) -> Vec<(u8, f32, f32, u32)>;
}
```

### `DPParameters`, `DPORReduction`

SPEC § 5.16.

```swift
public struct DPParameters: Sendable {
    public let epsilon: Double
    public let delta: Double
}
public enum DPORReduction {
    public static func reduce(window: [Fingerprint256], params: DPParameters) -> Fingerprint256
}
```

```rust
pub struct DPParameters { pub epsilon: f64, pub delta: f64 }
pub fn dp_or_reduce(window: &[Fingerprint256], params: &DPParameters) -> Fingerprint256;
```

### `LLMCalibrationCurve`

SPEC § 5.17.

```swift
public struct LLMCalibrationCurve: Sendable {
    public init(observations: [(predicted: Double, actual: Double)])
    public func calibrate(_ prediction: Double) -> Double
}
```

```rust
pub struct LLMCalibrationCurve { /* internal */ }
impl LLMCalibrationCurve {
    pub fn new(observations: &[(f64, f64)]) -> Self;
    pub fn calibrate(&self, prediction: f64) -> f64;
}
```

### `InformationTheory`

SPEC § 5.18.

```swift
public enum InformationTheory {
    public static func entropy(_ distribution: [Double]) -> Double
    public static func klDivergence(_ p: [Double], _ q: [Double]) -> Double
    public static func mutualInformation(_ p: [Double], _ q: [Double], joint: [[Double]]) -> Double
}
```

```rust
pub fn entropy(distribution: &[f64]) -> f64;
pub fn kl_divergence(p: &[f64], q: &[f64]) -> f64;
pub fn mutual_information(p: &[f64], q: &[f64], joint: &[Vec<f64>]) -> f64;
```

### `WindowLevel`, `TemporalWindow`, `TemporalCompression`

SPEC § 5.19.

```swift
public enum WindowLevel: Int, Comparable, Sendable {
    case hour = 0, day = 1, week = 2, month = 3, season = 4, year = 5
}
public struct TemporalWindow: Equatable, Sendable {
    public let level: WindowLevel
    public let range: TimeRange
}
public enum TemporalCompression {
    public static func compress(events: [AuditEvent], to: WindowLevel) -> [TemporalWindow: [AuditEvent]]
}
```

```rust
pub enum WindowLevel { Hour, Day, Week, Month, Season, Year }
pub struct TemporalWindow { /* … */ }
pub fn temporal_compress(events: &[AuditEvent], to: WindowLevel) -> HashMap<TemporalWindow, Vec<AuditEvent>>;
```

### `AnomalyDetection`, `CommunityDetection`, `Calibration`

SPEC § 5 (background).

```swift
public enum AnomalyDetection { /* … */ }
public enum CommunityDetection { /* … */ }
public struct LLMCalibrationCurve { /* … see § 5.17 */ }
```

```rust
pub mod anomaly { /* … */ }
pub mod community_detection { /* … */ }
pub mod calibration { /* … */ }
```

### `Item`, `AssociationRule`, `MiningThresholds`, `mineAssociationRules`

SPEC § 5.20.

```swift
public struct Item: Hashable, Comparable, Sendable, Codable {
    public let field: UInt8
    public let value: UInt8
    public init(field: UInt8, value: UInt8)
    public var packed: UInt16      // (field << 8) | value; ordering basis
    public static func < (a: Item, b: Item) -> Bool
}

public struct AssociationRule: Equatable, Sendable, Codable {
    public let antecedent: Item
    public let consequent: Item
    public let support: Double
    public let confidence: Double
    public let lift: Double
    public let conviction: Double    // +infinity when confidence == 1.0
    public let leverage: Double
    public init(antecedent:consequent:support:confidence:lift:conviction:leverage:)
}

public struct MiningThresholds: Equatable, Sendable, Codable {
    public let minSupport: Double
    public let minConfidence: Double
    public init(minSupport: Double, minConfidence: Double)
}

/// Mines pairwise rules. Free function (no namespace wrapper).
public func mineAssociationRules(
    matrix: MatrixO,
    activeRowCount: Int64,
    thresholds: MiningThresholds
) -> [AssociationRule]
```

```rust
// In substrate_ml::association_rule_mining
pub struct Item { pub field: u8, pub value: u8 }
impl Item { pub fn new(field: u8, value: u8) -> Self; pub fn packed(&self) -> u16; }

pub struct AssociationRule {
    pub antecedent: Item, pub consequent: Item,
    pub support: f64, pub confidence: f64, pub lift: f64,
    pub conviction: f64, pub leverage: f64,
}

pub struct MiningThresholds { pub min_support: f64, pub min_confidence: f64 }
impl MiningThresholds { pub fn new(min_support: f64, min_confidence: f64) -> Self; }

pub fn mine_association_rules(
    matrix: &MatrixO,
    active_row_count: i64,
    thresholds: MiningThresholds,
) -> Vec<AssociationRule>
```

### `RowAuditValue`, `RowAuditEntry`, `RowAttributeView`

SPEC § 5.20a.

```swift
public enum RowAuditValue: Sendable, Equatable {
    case bitmap(UInt64)
    case integer(Int64)
    case null
}

/// One audit event, SubstrateML-native. GeniusLocusKit converts
/// `UnifiedAuditEntry` to this at the kit boundary.
public struct RowAuditEntry: Sendable, Equatable {
    public let rowID: UUID
    public let tier: String
    public let fieldPath: String
    public let hlc: HLC
    public let value: RowAuditValue
    public init(rowID: UUID, tier: String, fieldPath: String, hlc: HLC, value: RowAuditValue)
}

/// Row-replay shape: one (tier, rowID) pair, categorical attributes extracted.
public struct RowAttributeView: Sendable, Equatable, Hashable {
    public let rowID: UUID
    public let tier: String
    /// Sorted [(field: UInt8, value: UInt8)] attribute list. Bitmap fields
    /// expand to one item per set bit (value = bit position). Integer fields
    /// use low byte as value.
    public let attributes: [(field: UInt8, value: UInt8)]
    public init(rowID: UUID, tier: String, attributes: [(field: UInt8, value: UInt8)])

    /// Factory: convert audit entries to row-replay shapes.
    /// Builds a vocabulary (sorted fieldPaths, capped at 64), groups by
    /// (tier, rowID), deduplicates by latest HLC, extracts attributes.
    /// Output sorted by (tier, rowID.uuidString).
    public static func from(auditEntries: [RowAuditEntry]) -> [RowAttributeView]
}
```

### `AprioriThresholds`, `AprioriRule`, `AprioriMining`, `mineAprioriRules`

SPEC § 5.20b.

```swift
public struct AprioriThresholds: Equatable, Sendable, Codable {
    public let minSupport: Double
    public let minConfidence: Double
    public let minLift: Double
    public let maxK: Int              // minimum effective value: 2
    public init(minSupport: Double, minConfidence: Double,
                minLift: Double = 1.0, maxK: Int = 3)
}

public struct AprioriRule: Equatable, Sendable, Codable {
    public let antecedent: [Item]     // sorted ascending on packed key
    public let consequent: Item
    public let support: Double
    public let confidence: Double
    public let lift: Double
    public let conviction: Double     // +infinity when confidence == 1.0
    public let leverage: Double
    public let evidenceCount: Int     // raw row count: rows containing antecedent ∪ consequent
}

public enum AprioriMining {
    /// Pure engine. Rows come from RowAttributeView.attributes.
    /// Output is a total order: sorted by lift ↓, confidence ↓,
    /// evidenceCount ↓, then lexicographic (antecedent packed keys ↑,
    /// consequent packed key ↑). Equal-metric ties resolve
    /// deterministically rather than by dictionary hash order, so
    /// Swift and Rust produce bit-identical output.
    public static func mine(
        rows: [RowAttributeView],
        thresholds: AprioriThresholds
    ) -> [AprioriRule]
}

/// Free function: thin wrapper around `AprioriMining.mine`.
public func mineAprioriRules(
    rows: [RowAttributeView],
    thresholds: AprioriThresholds
) -> [AprioriRule]
```

```rust
// In substrate_ml::apriori_mining  (re-uses association_rule_mining::Item)
pub struct AprioriThresholds { pub min_support: f64, pub min_confidence: f64,
                               pub min_lift: f64, pub max_k: usize }
impl AprioriThresholds { pub fn new(min_support, min_confidence, min_lift, max_k) -> Self; }

pub struct AprioriRule { pub antecedent: Vec<Item>, pub consequent: Item,
    pub support: f64, pub confidence: f64, pub lift: f64,
    pub conviction: f64, pub leverage: f64, pub evidence_count: usize }

pub fn mine_apriori_rules(rows: &[Vec<Item>], thresholds: &AprioriThresholds) -> Vec<AprioriRule>
```

### `FormalAttribute`, `FormalConcept`, `FormalContext`, `BoundedConceptMiner`, `StabilityEstimator`, `SeedMode`, `CoverDelta`, `ConceptCoverDeltas`

SPEC § 5.21.

```swift
public struct FormalAttribute: Hashable, Codable, Sendable, Comparable {
    public let namespace: String
    public let key: String
    public let value: String
    public init(namespace: String, key: String, value: String)
    public static func < (lhs: FormalAttribute, rhs: FormalAttribute) -> Bool
}

public struct FormalConcept: Hashable, Codable, Sendable {
    public let extent: [FormalContext.RowID]   // sorted ascending
    public let intent: [FormalAttribute]        // sorted ascending
    public let support: Int
    public let stability: Double?              // nil when stabilityBudget == 0 (default)
    public init(extent:intent:support:stability:)
}

public enum SeedMode: Hashable, Codable, Sendable {
    case single  // v1 default — frequent single attributes only
    case multi   // additionally seeds from frequent 2-attribute pairs
}

public struct CoverDelta: Hashable, Codable, Sendable {
    public let lowerIntent: Set<FormalAttribute>
    public let addedAttributes: Set<FormalAttribute>
    public init(lowerIntent: Set<FormalAttribute>, addedAttributes: Set<FormalAttribute>)
}

public struct ConceptCoverDeltas: Sendable {
    public let coverDeltas: [CoverDelta]
    public init(coverDeltas: [CoverDelta])
    /// Cover-delta set over an emitted concept set — structural lens over
    /// the concept order. Not universally sound. See SPEC § 5.21.
    public static func covering(concepts: [FormalConcept]) -> ConceptCoverDeltas
}

public struct FormalContext: Sendable {
    public typealias RowID = UInt32
    public let attributes: [FormalAttribute]
    public let rowCount: Int
    public init(rows: [[FormalAttribute]])
    /// Build a context from RowAttributeView row data. Each (field, value)
    /// pair maps to FormalAttribute(namespace:"row", key:String(field),
    /// value:String(value)).
    public static func from(rowAttributeViews: [RowAttributeView]) -> FormalContext
    public func extent(of intent: [FormalAttribute]) -> [RowID]
    public func intent(of extent: [RowID]) -> [FormalAttribute]
    public func closure(of intent: [FormalAttribute]) -> [FormalAttribute]
}

public struct BoundedConceptMiner: Sendable {
    public let minSupport: Int
    public let maxIntentSize: Int
    public let maxConcepts: Int
    public let seedMode: SeedMode         // default .single
    public let maxSeeds: Int              // default Int.max; caps pair-seed pass
    public let stabilityBudget: Int       // default 0 — no stability estimation
    public let stabilitySeed: UInt64      // default 0xCAFEBABEDEADBEEF
    public init(minSupport: Int, maxIntentSize: Int, maxConcepts: Int,
                seedMode: SeedMode = .single, maxSeeds: Int = Int.max,
                stabilityBudget: Int = 0,
                stabilitySeed: UInt64 = 0xCAFEBABEDEADBEEF)
    public func mine(context: FormalContext) -> [FormalConcept]
}

/// Sampled Kuznetsov stability estimator. Bernoulli(p=0.5) sampling
/// over a concept's extent; hit when intent(subset) == concept.intent.
/// Per-concept seed: globalSeed XOR fnv64(canonicalKey(concept)).
/// Returns 0.0 when budget == 0 or extent is empty. See SPEC § 5.21.
public enum StabilityEstimator {
    public static func estimate(
        concept: FormalConcept, context: FormalContext,
        budget: Int, seed: UInt64
    ) -> Double
}

/// One sound logical implication from the D-G canonical basis.
/// `conclusion = closure_context(premise) \ premise`.
/// `premise` and `conclusion` are disjoint. See SPEC § 5.21 (FormalConceptAnalysis).
public struct Implication: Hashable, Codable, Sendable {
    public let premise: Set<FormalAttribute>
    public let conclusion: Set<FormalAttribute>
    public init(premise: Set<FormalAttribute>, conclusion: Set<FormalAttribute>)
}

/// Bounded Duquenne–Guigues canonical basis over a `FormalContext`.
/// Every emitted implication is sound. `isTruncated` is true when
/// `maxImplications` terminated enumeration early. See SPEC § 5.21 (FormalConceptAnalysis).
public struct ConceptImplications: Sendable {
    public let implications: [Implication]  // sorted: premise-size asc, lex premise, lex conclusion
    public let isTruncated: Bool
    public init(implications: [Implication], isTruncated: Bool)
    /// Compute the bounded D-G canonical basis for `context`.
    /// `over:` accepts the pre-mined concepts (may be empty).
    /// `maxImplications`: hard cap; set to `Int.max` for uncapped.
    /// `maxPremiseSize`: size filter; does not set `isTruncated`.
    public static func conceptImplications(
        over concepts: [FormalConcept],
        context: FormalContext,
        maxImplications: Int,
        maxPremiseSize: Int
    ) -> ConceptImplications
}
```

```rust
// In substrate_ml::formal_concept_analysis
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FormalAttribute { pub namespace: String, pub key: String, pub value: String }
impl FormalAttribute { pub fn new(namespace: &str, key: &str, value: &str) -> Self; }

pub type RowId = u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeedMode { Single, Multi }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverDelta {
    pub lower_intent: Vec<FormalAttribute>,     // sorted
    pub added_attributes: Vec<FormalAttribute>, // sorted, non-empty
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConceptCoverDeltas {
    pub cover_deltas: Vec<CoverDelta>,
}
impl ConceptCoverDeltas {
    pub fn covering(concepts: &[FormalConcept]) -> ConceptCoverDeltas;
}

// In substrate_ml::concept_implications
/// One sound logical implication from the D-G canonical basis.
/// `conclusion = closure_context(premise) \ premise`. See SPEC § 5.21 (FormalConceptAnalysis).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Implication {
    pub premise: Vec<FormalAttribute>,    // sorted ascending
    pub conclusion: Vec<FormalAttribute>, // sorted ascending
}

/// Bounded Duquenne–Guigues canonical basis over a `FormalContext`.
/// Every emitted implication is sound. `is_truncated` is true when
/// `max_implications` terminated enumeration early. See SPEC § 5.21 (FormalConceptAnalysis).
#[derive(Debug, Clone, PartialEq)]
pub struct ConceptImplications {
    pub implications: Vec<Implication>, // sorted: premise-size asc, lex premise, lex conclusion
    pub is_truncated: bool,
}
impl ConceptImplications {
    /// Compute the bounded D-G canonical basis for `context`.
    /// `max_implications`: hard cap; set to `usize::MAX` for uncapped.
    /// `max_premise_size`: size filter; does not set `is_truncated`.
    pub fn compute(
        context: &FormalContext,
        max_implications: usize,
        max_premise_size: usize,
    ) -> ConceptImplications;
}

#[derive(Debug, Clone, PartialEq)]
pub struct FormalConcept {
    pub extent: Vec<RowId>,
    pub intent: Vec<FormalAttribute>,
    pub support: usize,
    pub stability: Option<f64>,   // None when stability_budget == 0 (default)
}

pub struct FormalContext { /* internal */ }
impl FormalContext {
    pub fn new(rows: &[Vec<FormalAttribute>]) -> Self;
    /// Build from (field, value) pair rows — mirrors Swift from(rowAttributeViews:).
    pub fn from_row_attribute_views(views: &[Vec<(u8, u8)>]) -> Self;
    pub fn attributes(&self) -> &[FormalAttribute];
    pub fn row_count(&self) -> usize;
    pub fn extent(&self, intent: &[FormalAttribute]) -> Vec<RowId>;
    pub fn intent(&self, extent: &[RowId]) -> Vec<FormalAttribute>;
    pub fn closure(&self, intent: &[FormalAttribute]) -> Vec<FormalAttribute>;
}

pub struct BoundedConceptMiner {
    pub min_support: usize,
    pub max_intent_size: usize,
    pub max_concepts: usize,
    pub seed_mode: SeedMode,        // default Single
    pub max_seeds: usize,           // default usize::MAX
    pub stability_budget: usize,    // default 0 — no stability estimation
    pub stability_seed: u64,        // default 0xCAFE_BABE_DEAD_BEEF
}
impl BoundedConceptMiner {
    pub fn new(min_support: usize, max_intent_size: usize, max_concepts: usize) -> Self;
    pub fn new_with_seed_mode(min_support: usize, max_intent_size: usize,
        max_concepts: usize, seed_mode: SeedMode, max_seeds: usize) -> Self;
    pub fn mine(&self, context: &FormalContext) -> Vec<FormalConcept>;
}

/// Sampled Kuznetsov stability estimator. Mirrors Swift StabilityEstimator.
/// Per-concept seed: seed XOR fnv::hash64(canonical_key(concept)).
pub struct StabilityEstimator;
impl StabilityEstimator {
    pub fn estimate(
        concept: &FormalConcept, context: &FormalContext,
        budget: usize, seed: u64
    ) -> f64;
}
```

## § 3 — Public functions

`mineAssociationRules` / `mine_association_rules` is a free function in
this package (SPEC § 5.20). All other public function signatures appear
under their owning type in § 2.

## § 4 — Errors

Domain-enforcement preconditions terminate the process on programmer
error (the substrate convention); the table notes both forms.

| Error site | Trigger |
|---|---|
| `NMFAlternatingLeastSquares.factorize` precondition | non-rectangular, non-finite, or negative cell in `V` |
| `RandomWalks.walk` precondition | neighbor index outside `[0, N)`, or non-finite/negative weight |
| `RandomWalks.sampleWeighted` precondition | empty neighbor list |
| `FFT.forward` / `.inverse` throws | non-power-of-two signal length |
| `BradleyTerryEstimator.update` throws | `weight ≤ 0` |
| `PairingHandshake.validate` returns `false` | signature mismatch |

No other public surface raises errors; failure modes are non-error
returns (empty, `nil`, default-valued).

## § 5 — Conformance test entry points

- **Swift:** `Tests/SubstrateMLTests/`
  - `AuditLogFoldTests.swift`
  - `MatrixDecayTests.swift`
  - `BradleyTerryTests.swift`
  - `NMFTests.swift`
  - `FFTTests.swift`
  - `EigenvalueCentralityTests.swift`
  - `LatticeDistanceTests.swift`
  - `FeatureExtractorsTests.swift`
  - `FloatSimHashTests.swift`
  - `MomentSummaryTests.swift`
  - `PartialStateRecallTests.swift`
  - `PairingHandshakeTests.swift`
  - `TierContributionFingerprintTests.swift`
  - `TierAscendingQueryTests.swift`
  - `ActionOutcomeMatrixTests.swift`
  - `DPORReductionTests.swift`
  - `LLMCalibrationCurveTests.swift`
  - `InformationTheoryTests.swift`
  - `TemporalCompressionTests.swift`
  - `ConceptImplicationsTests.swift`
- **Rust:** per-module `#[cfg(test)] mod tests` blocks, plus
  `tests/` for cross-port conformance.
  - `row_attribute_view::tests` — 15 tests for `RowAttributeView::from`, dedup, sort, extraction rules.
  - `tier_query::tests` — 9 tests for `TierAscendingQueryProtocol` (DP, combine, CI) and `PrivacyLedger`.
  - `temporal_causality_fold::tests` — existing 7 tests; now uses canonical `substrate_types::HLC`.

## § 6 — Examples

```swift
import SubstrateTypes
import SubstrateKernel
import SubstrateML

// Project a row's state as of a specific HLC.
let projection = AuditLogFold.projectStateAt(rowId: someRowId, asOf: someHLC, log: log)

// Decay a cooccurrence matrix over 7 days.
let aged = MatrixDecay.decay(decaying, halfLife: DecayHalfLives.matrixC, asOf: now)

// Train a Bradley-Terry estimator on five preference observations.
var bt = BradleyTerryEstimator(itemCount: 4)
for obs in observations { try bt.update(obs) }
let strengths = bt.strengths()

// Combine peer tier contributions into a federation fingerprint.
let combined = TierContributionFingerprint.combine([peerA, peerB, peerC])
```

```rust
use substrate_types::*;
use substrate_ml::{audit_log_fold, decay, bradley_terry, tier_contribution_fingerprint};

let projection = audit_log_fold::project_state_at(row_id, as_of, &log);
let aged = decay::decay(&decaying, decay::half_lives::MATRIX_C, now);

let mut bt = bradley_terry::BradleyTerryEstimator::new(4);
for obs in &observations { bt.update(*obs)?; }
let strengths = bt.strengths();

let combined = tier_contribution_fingerprint::combine(&[peer_a, peer_b, peer_c]);
```

## § 7 — Swift/Rust Concordance

This section enumerates the COMPLETE top-level public surface of SubstrateML
in both ports, one row per public concept. Each Swift symbol and each Rust
symbol below was read from source (file:line cited inline in the prose under
§ 2 and verified against the live tree on 2026-06-05). Every row is anchored
to the real conformance test that proves the two ports agree.

Cross-cutting Rust idioms (do not constitute drift): snake_case identifiers,
`Vec<T>` for Swift arrays, `Option<T>` for Swift optionals, `u128` for Swift
`UUID`, unit-struct namespaces (`pub struct X;` + `impl X`) where Swift uses
`enum X { static func … }`, and Rust free functions / `pub mod` constants
where Swift attaches the same call to a namespace enum. These are sanctioned
per SPEC § 1 ("naming differs by port convention; results are bit-for-bit
identical for federation-affecting algorithms").

Test-binding convention below: `Foo.swift` denotes the Swift conformance
suite `Tests/SubstrateMLTests/Foo.swift`; `rust:<module>::tests` denotes the
inline `#[cfg(test)] mod tests` block in `rust/src/<module>.rs`. Bit-for-bit
cross-port agreement for the federation-affecting algorithms is asserted by
the Swift suites against the same canonical inputs the Rust module tests use.

### § 7.1 — Full concept table

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Projected row state | `ProjectedRowState` | `ProjectedRowState` | public | identical (snake_case fields) | `AuditLogFoldTests.swift` / `rust:audit_log_fold::tests` | Confirmed |
| Audit-log fold namespace | `AuditLogFold` (enum) | `AuditLogFold` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `AuditLogFoldTests.swift` / `rust:audit_log_fold::tests` | Confirmed |
| Decaying matrix | `DecayingMatrix` | `DecayingMatrix` | public | identical (f64 cells) | `MatrixDecayTests.swift` / `rust:decay::tests` | Confirmed |
| Matrix-decay namespace | `MatrixDecay` (enum) | — (`decay::apply`/`decay_factor` free fns) | public | Swift enum namespace / Rust free fn (no type) | `MatrixDecayTests.swift` / `rust:decay::tests` | Confirmed |
| Decay half-lives | `DecayHalfLives` (enum) | `decay::half_lives` (pub mod consts) | public | Swift enum-of-statics / Rust `pub mod` constants | `MatrixDecayTests.swift` / `rust:decay::tests` | Confirmed |
| Preference observation | `PreferenceObservation` | `PreferenceObservation` | public | identical | `BradleyTerryTests.swift` / `rust:bradley_terry::tests` | Confirmed |
| Bradley-Terry estimator | `BradleyTerryEstimator` | `BradleyTerryEstimator` | public | Swift `throws` / Rust `Result<…,&'static str>` | `BradleyTerryTests.swift` / `rust:bradley_terry::tests` | Confirmed |
| NMF factorization result | `NMFFactorization` | `NMFFactorization` | public | identical (W/H → w/h) | `NMFTests.swift`, `NMFDomainTests.swift` / `rust:nmf::tests` | Confirmed |
| NMF-ALS namespace | `NMFAlternatingLeastSquares` (enum) | `NMFAlternatingLeastSquares` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; Swift precondition / Rust panic | `NMFTests.swift` / `rust:nmf::tests` | Confirmed |
| Complex number | `Complex` | `Complex` | public | identical | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| FFT namespace | `FFT` (enum) | — (`fft::forward`/`inverse` free fns) | public | Swift enum namespace / Rust free fn (no type) | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| Rhythm result | `RhythmResult` | `RhythmResult` | public | identical | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| Rhythm-analysis namespace | `RhythmAnalysis` (enum) | — (`fft::analyze` free fn) | public | Swift enum namespace / Rust free fn (no type) | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| Eigenvalue centrality namespace | `EigenvalueCentrality` (enum) | `EigenvalueCentrality` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `EigenvalueCentralityTests.swift`, `EigenvalueCentralityDirectedTests.swift` / `rust:eigenvalue_centrality::tests` | Confirmed |
| SplitMix64 RNG | `SplitMix64` | `SplitMix64` | public | identical (deterministic seed) | `RandomWalksTests.swift` / `rust:random_walks::tests` | Confirmed |
| Random-walks namespace | `RandomWalks` (enum) | `RandomWalks` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; Swift precondition / Rust panic | `RandomWalksTests.swift`, `RandomWalksDomainTests.swift` / `rust:random_walks::tests` | Confirmed |
| Lattice anchor (string) | `LatticeAnchorStr` | `LatticeAnchorStr` | public | identical | `LatticeDistanceTests.swift` / `rust:lattice_distance::tests` | Confirmed |
| UDC tree distance namespace | `UDCTreeDistance` (enum) | `UDCTreeDistance` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `LatticeDistanceTests.swift` / `rust:lattice_distance::tests` | Confirmed |
| Wikidata adjacency provider | `WikidataAdjacencyProvider` (protocol) | `WikidataAdjacencyProvider` (trait) | public | Swift protocol / Rust trait | `LatticeDistanceTests.swift` / `rust:lattice_distance::tests` | Confirmed |
| Lattice distance namespace | `LatticeDistance` (enum) | `LatticeDistance` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `LatticeDistanceTests.swift` / `rust:lattice_distance::tests` | Confirmed |
| Wikidata graph distance namespace | `WikidataGraphDistance` (enum) | `WikidataGraphDistance` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `LatticeDistanceTests.swift` / `rust:lattice_distance::tests` | Confirmed |
| Composite distance namespace | `CompositeDistance` (enum) | `CompositeDistance` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `CompositeDistanceTests.swift` / `rust:composite_distance::tests` | Confirmed |
| Stream-source flag | `StreamSourceFlag` (enum: UInt8) | `StreamSourceFlag` (enum) | public | identical (Rust drops explicit discriminants) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| Ambient sample row | `AmbientSampleRow` | `AmbientSampleRow` | public | identical (snake_case fields) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| HealthKit sample | `HealthKitSample` | `HealthKitSample` | public | identical | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| CoreLocation sample | `CoreLocationSample` | `CoreLocationSample` | public | identical | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| EventKit sample | `EventKitSample` | `EventKitSample` | public | identical | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| ScreenTime sample | `ScreenTimeSample` | `ScreenTimeSample` | public | identical | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| SystemTelemetry sample | `SystemTelemetrySample` | `SystemTelemetrySample` | public | identical | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| CoreLocation extractor | `CoreLocationExtractor` | `CoreLocationExtractor<'a>` | public | identical (Rust borrows via lifetime) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| EventKit extractor | `EventKitExtractor` | `EventKitExtractor<'a>` | public | identical (Rust borrows via lifetime) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| HealthKit extractor | `HealthKitExtractor` | `HealthKitExtractor<'a>` | public | identical (Rust borrows via lifetime) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| ScreenTime extractor | `ScreenTimeExtractor` | `ScreenTimeExtractor<'a>` | public | identical (Rust borrows via lifetime) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| SystemTelemetry extractor | `SystemTelemetryExtractor` | `SystemTelemetryExtractor<'a>` | public | identical (Rust borrows via lifetime) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| Feature-extractors facade | `FeatureExtractors` (enum) | — (`feature_extractors::extract_ambient_sample` free fn) | public | Swift enum namespace / Rust free fn (no type) | `FeatureExtractorsTests.swift` / `rust:feature_extractors::tests` | Confirmed |
| Float SimHash namespace | `FloatSimHash` (enum) | — (`float_simhash::project` free fn) | public | Swift enum namespace / Rust free fn (no type) | `FloatSimHashTests.swift` / `rust:float_simhash::tests` | Confirmed |
| Row-lite summary | `RowLite` | `RowLite` | public | identical | `MomentSummaryTests.swift` / `rust:moment_summary::tests` | Confirmed |
| Moment-summary namespace | `MomentSummary` (enum) | `MomentSummary` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `MomentSummaryTests.swift` / `rust:moment_summary::tests` | Confirmed |
| Partial-state recall namespace | `PartialStateRecall` (enum) | `PartialStateRecall` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `PartialStateRecallTests.swift`, `PartialStateRecallValidationTests.swift` / `rust:partial_state_recall::tests` | Confirmed |
| Pairing nonce | `PairingNonce` | `PairingNonce` | public | identical | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Pairing record | `PairingRecord` | `PairingRecord` | public | identical | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Pairing-handshake namespace | `PairingHandshake` (enum) | `PairingHandshake` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Pairing audit payload | `PairingHandshake.PairingAuditPayload` (nested) | `PairingAuditPayload` (flat) | public | Swift nested `Handshake.Payload` / Rust flat `PairingAuditPayload` | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Federation case | `FederationCase` (enum: UInt32) | `FederationCase` (enum) | public | identical (Rust drops discriminants) | `TierContributionFingerprintTests.swift` / `rust:tier_contribution::tests` | Confirmed |
| Tier contribution | `TierContribution` | `TierContribution` | public | identical | `TierContributionFingerprintTests.swift` / `rust:tier_contribution::tests` | Confirmed |
| Tier-contribution fingerprint namespace | `TierContributionFingerprint` (enum) | `TierContributionFingerprint` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `TierContributionFingerprintTests.swift` / `rust:tier_contribution::tests` | Confirmed |
| Target tier | `TargetTier` (enum: String) | `TargetTier` (enum) | public | identical (Rust drops raw values) | `TierAscendingQueryTests.swift` / `rust:tier_query::tests` | Confirmed |
| Peer response | `PeerResponse` | `PeerResponse` | public | identical | `TierAscendingQueryTests.swift` / `rust:tier_query::tests` | Confirmed |
| Tier-ascending query | `TierAscendingQuery` | `TierAscendingQuery` | public | identical | `TierAscendingQueryTests.swift` / `rust:tier_query::tests` | Confirmed |
| Tier-ascending query protocol namespace | `TierAscendingQueryProtocol` (enum) | `TierAscendingQueryProtocol` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `TierAscendingQueryTests.swift` / `rust:tier_query::tests` | Confirmed |
| Privacy ledger (DP accounting) | `PrivacyLedger` | `PrivacyLedger` | public | identical | `TierAscendingQueryTests.swift` / `rust:tier_query::tests` | Confirmed |
| Action-outcome key | `ActionOutcomeKey` | `ActionOutcomeKey` | public | identical (6-bit fields, < 64) | `ActionOutcomeMatrixTests.swift` / `rust:action_outcome::tests` | Confirmed |
| Action-outcome cell | `ActionOutcomeCell` | `ActionOutcomeCell` | public | Swift stored `successRate`/`wilsonLowerBound` / Rust methods | `ActionOutcomeMatrixTests.swift` / `rust:action_outcome::tests` | Confirmed |
| Action-outcome matrix | `ActionOutcomeMatrix` | `ActionOutcomeMatrix` | public | identical (Wilson-ranked topActions) | `ActionOutcomeMatrixTests.swift` / `rust:action_outcome::tests` | Confirmed |
| DP parameters | `DPParameters` | `DPParameters` | public | identical | `DPORReductionTests.swift` / `rust:dp_or_reduce::tests` | Confirmed |
| DP-OR reduction namespace | `DPORReduction` (enum) | `DPORReduction` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `DPORReductionTests.swift` / `rust:dp_or_reduce::tests` | Confirmed |
| LLM calibration curve | `LLMCalibrationCurve` | `LLMCalibrationCurve` (mod `calibration`) | public | identical (Rust in `calibration` module) | `LLMCalibrationCurveTests.swift` / `rust:calibration::tests` | Confirmed |
| Information-theory namespace | `InformationTheory` (enum) | `InformationTheory` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `InformationTheoryTests.swift`, `NormalizedMutualInformationGuardTests.swift` / `rust:info_theory::tests` | Confirmed |
| Window level | `WindowLevel` (enum: Int) | `WindowLevel` (enum) | public | identical (Rust drops discriminants) | `TemporalCompressionTests.swift` / `rust:temporal_compression::tests` | Confirmed |
| Temporal window | `TemporalWindow` | `TemporalWindow` | public | identical | `TemporalCompressionTests.swift` / `rust:temporal_compression::tests` | Confirmed |
| Temporal-compression namespace | `TemporalCompression` (enum) | `TemporalCompression` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `TemporalCompressionTests.swift` / `rust:temporal_compression::tests` | Confirmed |
| Anomaly-detection namespace | `AnomalyDetection` (enum) | `AnomalyDetection` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `AnomalyDetectionTests.swift` / `rust:anomaly` (inline asserts) | Confirmed |
| Community-detection namespace | `CommunityDetection` (enum) | `CommunityDetection` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `CommunityDetectionTests.swift` / `rust:community_detection::tests` | Confirmed |
| Association-rule item | `Item` | `Item` (mod `association_rule_mining`) | public | identical (packed UInt16/u16 key) | `AssociationRuleMiningTests.swift` / `rust:association_rule_mining::tests` | Confirmed |
| Association rule | `AssociationRule` | `AssociationRule` | public | identical | `AssociationRuleMiningTests.swift` / `rust:association_rule_mining::tests` | Confirmed |
| Mining thresholds | `MiningThresholds` | `MiningThresholds` | public | identical | `AssociationRuleMiningTests.swift` / `rust:association_rule_mining::tests` | Confirmed |
| Row-audit value | `RowAuditValue` (enum) | `RowAuditValue` (enum, mod `row_attribute_view`) | public | identical (`bitmap`/`integer`/`null` → `Bitmap`/`Integer`/`Null`) | `RowAttributeViewTests.swift` / `rust:row_attribute_view::tests` | Confirmed |
| Row-audit entry | `RowAuditEntry` | `RowAuditEntry` | public | Swift `UUID` / Rust `u128` row id | `RowAttributeViewTests.swift` / `rust:row_attribute_view::tests` | Confirmed |
| Row-attribute view | `RowAttributeView` | `RowAttributeView` | public | identical (vocab cap 64, latest-HLC dedup) | `RowAttributeViewTests.swift` / `rust:row_attribute_view::tests` | Confirmed |
| Apriori thresholds | `AprioriThresholds` | `AprioriThresholds` (mod `apriori_mining`) | public | identical | `AprioriMiningTests.swift` / `rust:apriori_mining::tests` | Confirmed |
| Apriori rule | `AprioriRule` | `AprioriRule` | public | identical (Swift `evidenceCount: Int` / Rust `evidence_count: usize`) | `AprioriMiningTests.swift`, `AprioriMiningTieBreakTests.swift` / `rust:apriori_mining::tests` | Confirmed |
| Apriori-mining namespace | `AprioriMining` (enum) | — (`apriori_mining::mine_apriori_rules` free fn) | public | Swift enum namespace / Rust free fn (no type) | `AprioriMiningTests.swift`, `AprioriMiningTieBreakTests.swift` / `rust:apriori_mining::tests` | Confirmed |
| Formal attribute | `FormalAttribute` | `FormalAttribute` (mod `formal_concept_analysis`) | public | identical (Comparable/Ord) | `FormalConceptAnalysisTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Formal concept | `FormalConcept` | `FormalConcept` | public | identical (`stability: Double?` / `Option<f64>`) | `FormalConceptAnalysisTests.swift`, `FormalConceptStabilityTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Formal context | `FormalContext` | `FormalContext` | public | Swift nested `RowID` typealias / Rust flat `RowId` type | `FormalConceptAnalysisTests.swift`, `FormalContextFromRowAttributeViewTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Formal-context row id | `FormalContext.RowID` (nested typealias = UInt32) | `RowId` (flat `pub type RowId = u32`) | public | Swift nested typealias / Rust flat type alias | `FormalConceptAnalysisTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Bounded concept miner | `BoundedConceptMiner` | `BoundedConceptMiner` | public | identical (Swift default-arg init / Rust `new` + `new_with_seed_mode`) | `FormalConceptAnalysisTests.swift`, `FormalConceptAnalysisMultiSeedTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Stability estimator namespace | `StabilityEstimator` (enum) | `StabilityEstimator` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `FormalConceptStabilityTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Seed mode | `SeedMode` (enum) | `SeedMode` (enum) | public | identical (`single`/`multi` → `Single`/`Multi`) | `FormalConceptAnalysisMultiSeedTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Cover delta | `CoverDelta` | `CoverDelta` | public | Swift `Set<FormalAttribute>` / Rust sorted `Vec` | `FormalConceptAnalysisCoverDeltasTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Concept cover deltas | `ConceptCoverDeltas` | `ConceptCoverDeltas` | public | identical | `FormalConceptAnalysisCoverDeltasTests.swift` / `rust:formal_concept_analysis::tests` | Confirmed |
| Implication | `Implication` | `Implication` (mod `concept_implications`) | public | Swift `Set<FormalAttribute>` / Rust sorted `Vec` | `ConceptImplicationsTests.swift` / `rust:concept_implications::tests` | Confirmed |
| Concept implications | `ConceptImplications` | `ConceptImplications` | public | Swift `conceptImplications(over:context:…)` static / Rust `compute(context:…)` (no pre-mined arg) | `ConceptImplicationsTests.swift` / `rust:concept_implications::tests` | Confirmed |
| Temporal field coordinate | `TemporalFieldCoord` | `TemporalFieldCoord` | public | identical | `TemporalCausalityFoldTests.swift` / `rust:temporal_causality_fold::tests` | Confirmed |
| Temporal audit entry | `TemporalAuditEntry` | `TemporalAuditEntry` | public | identical | `TemporalCausalityFoldTests.swift` / `rust:temporal_causality_fold::tests` | Confirmed |
| Temporal causality key | `TemporalCausalityKey` | `TemporalCausalityKey` | public | identical | `TemporalCausalityFoldTests.swift` / `rust:temporal_causality_fold::tests` | Confirmed |
| Temporal-causality fold namespace | `TemporalCausalityFold` (enum) | `TemporalCausalityFold` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `TemporalCausalityFoldTests.swift` / `rust:temporal_causality_fold::tests` | Confirmed |
| Temporal-causality fold result | `(deltas:, newWatermark:)` tuple return | `FoldResult` (flat struct) | public | Swift anonymous tuple return / Rust named result struct (same fields: `deltas`, `new_watermark`) | `TemporalCausalityFoldTests.swift` / `rust:temporal_causality_fold::tests` | Confirmed |

### § 7.2 — Notes on apparent asymmetries (verified non-drift)

- **Swift namespace enums with no Rust type** (`MatrixDecay`, `FFT`,
  `RhythmAnalysis`, `FeatureExtractors`, `FloatSimHash`, `AprioriMining`):
  Swift groups the static functions under an empty `enum`; Rust exposes the
  same calls as module-level `pub fn`s (and `DecayHalfLives` as a `pub mod`
  of constants). No Rust top-level *type* is created. Behavior is bound by
  the shared conformance suites cited above — not drift.
- **Rust unit-struct namespaces** (`AuditLogFold`, `NMFAlternatingLeastSquares`,
  `EigenvalueCentrality`, `RandomWalks`, `UDCTreeDistance`, `LatticeDistance`,
  `WikidataGraphDistance`, `CompositeDistance`, `MomentSummary`,
  `PartialStateRecall`, `PairingHandshake`, `TierContributionFingerprint`,
  `TierAscendingQueryProtocol`, `DPORReduction`, `InformationTheory`,
  `TemporalCompression`, `AnomalyDetection`, `CommunityDetection`,
  `StabilityEstimator`, `TemporalCausalityFold`): Rust names the namespace as
  `pub struct X;` with an `impl X`; Swift uses `enum X`. Same call surface.
- **`FoldResult`** (Rust) and **`PairingAuditPayload`** (flat in Rust, nested
  `PairingHandshake.PairingAuditPayload` in Swift) and **`RowId`** (flat Rust
  `pub type`, nested `FormalContext.RowID` in Swift) are idiomatic
  flattening / named-return shapes, NOT Swift-only/Rust-only contract gaps.
  Each is paired in the table above with Status=Confirmed and the test that
  proves the shapes carry identical data.
- **No DRIFT and no Apple-platform-bound (Exempt) types** exist in
  SubstrateML. The package is pure cold-path math/CRDT with no Metal/BNNS/
  CoreML/CloudKit/Keychain surface; every concept has a real counterpart in
  both ports.

### § 7.3 — Prior-wave reconciliation history

Populated by PAR-1C + PAR-3A-SM (2026-06-05). Lists the symbols added or
reconciled in earlier waves. All rows are functionally 1:1; Rust idioms differ
(snake_case, `Vec` for Swift arrays, `u128` for Swift `UUID`, `Option` for
Swift optionals).

### Audit-projection types (new in PAR-1C)

| Swift | Rust module | Rust type/fn | Notes |
|---|---|---|---|
| `RowAuditValue` | `row_attribute_view` | `pub enum RowAuditValue` | `Bitmap(u64)`, `Integer(i64)`, `Null` |
| `RowAuditEntry` | `row_attribute_view` | `pub struct RowAuditEntry` | `row_id: u128` mirrors Swift `UUID`; `hlc: HLC` from `substrate_types` |
| `RowAttributeView` | `row_attribute_view` | `pub struct RowAttributeView` | `attributes: Vec<(u8, u8)>` sorted ascending |
| `RowAttributeView.from(auditEntries:)` | `row_attribute_view` | `RowAttributeView::from(audit_entries: &[RowAuditEntry])` | Same algorithm: vocab cap 64, latest-HLC dedup, sorted output by (tier, row_id UUID string) |

### Recall vocabulary (reconciled in PAR-3A-SM — Lite types removed)

The prior `RecallScoreLite` / `RecallResultLite` stand-ins in
`tier_query.rs` have been removed. The module now uses the canonical
recall vocabulary from `substrate_types`, which is the force-mirror of
the Swift vocabulary in `SubstrateTypes/RecallTypes.swift`.

| Swift (SubstrateTypes) | Rust (`substrate_types`) | Notes |
|---|---|---|
| `RecallScore` | `RecallScore` | `row_id: RowId` (newtype `u128`), `score: f32` |
| `RecallResult` | `RecallResult` | `rows`, `breakdown: DistanceBreakdown`, `confidence_interval: Option<(f32,f32)>`, `primitive_name` |
| `DistanceBreakdown` | `DistanceBreakdown` | Four `f32` contributions; `ZERO` constant |
| `RowProjection` | `RowProjection` | `row_id`, `capture_hlc`, `fingerprint`, `lattice`, `bitmaps: (u64,u64,u64)`, `row_state: u8` |

`TierAscendingQuery`, `PeerResponse`, `TierAscendingQueryProtocol`, and
`PrivacyLedger` in `tier_query.rs` now use `RecallResult` and
`RecallScore` from `substrate_types` throughout.

### HLC deduplication (PAR-1E fix, applied in PAR-1C)

| Was | Now |
|---|---|
| Local `HLC` struct in `temporal_causality_fold.rs` | `use substrate_types::HLC` |

The local struct was a compilation convenience from before `substrate-types`
was a declared dependency of `substrate-ml`. It duplicated the canonical
`HLC` fields (`physical_time: i64`, `logical_count: i32`, `node_id: i32`)
but prevented the canonical type from being used across module boundaries.
Removed in favor of the canonical type; no semantic change (identical
field layout, identical ordering implementation).
