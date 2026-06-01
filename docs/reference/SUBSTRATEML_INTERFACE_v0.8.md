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
  Public API surface of SubstrateML in both ports. Twenty-three Swift
  files publish the cold-path algorithms over substrate types: the
  audit-log fold, matrix decay, Bradley-Terry estimation, NMF, FFT,
  eigenvalue centrality, lattice distance, anomaly / community
  detection, feature extractors, float-input SimHash, moment summary,
  partial-state recall, pairing handshake, tier-contribution
  fingerprint, tier-ascending query, action-outcome matrix, DP-OR
  reduction, LLM calibration curve, information theory, temporal
  compression. The Rust mirror exposes the same shapes.
---

# SubstrateML Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateML/`

- `Sources/SubstrateML/` — 23 files, one per algorithm or family.
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
    public let W: MatrixF
    public let H: MatrixF
}
public enum NMFAlternatingLeastSquares {
    public static func factor(_ matrix: MatrixF, rank: Int, iterations: Int) throws -> NMFFactorization
}
```

```rust
pub struct NMFFactorization { pub w: MatrixF, pub h: MatrixF }
pub fn nmf_als_factor(matrix: &MatrixF, rank: usize, iterations: usize) -> Result<NMFFactorization, &'static str>;
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
    public static func walk(graph: MatrixF, start: Int, steps: Int, prng: inout SplitMix64) -> [Int]
}
```

```rust
pub struct SplitMix64 { /* internal */ }
impl SplitMix64 { pub fn new(seed: u64) -> Self; pub fn next(&mut self) -> u64; }
pub fn random_walk(graph: &MatrixF, start: usize, steps: usize, prng: &mut SplitMix64) -> Vec<usize>;
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

```swift
public struct ActionOutcomeKey: Hashable, Comparable, Sendable {
    public let actionType: UInt32
    public let contextId: UInt32
}
public struct ActionOutcomeCell: Equatable, Sendable {
    public let positive: Int64
    public let negative: Int64
}
public struct ActionOutcomeMatrix: Sendable {
    public init()
    public mutating func record(key: ActionOutcomeKey, positive: Bool, weight: Int64 = 1)
    public func cell(for key: ActionOutcomeKey) -> ActionOutcomeCell
}
```

```rust
pub struct ActionOutcomeKey { pub action_type: u32, pub context_id: u32 }
pub struct ActionOutcomeCell { pub positive: i64, pub negative: i64 }
pub struct ActionOutcomeMatrix { /* internal */ }
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

## § 3 — Public functions

All public function signatures appear under their owning type in § 2.
No free top-level functions outside those namespaces.

## § 4 — Errors

| Error site | Trigger |
|---|---|
| `NMFAlternatingLeastSquares.factor` throws | negative cell in input matrix |
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
- **Rust:** per-module `#[cfg(test)] mod tests` blocks, plus
  `tests/` for cross-port conformance.

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
