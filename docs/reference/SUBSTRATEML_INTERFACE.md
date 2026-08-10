---
title: SubstrateML Interface
version: 1.2.0
status: active
date: 2026-08-06
description: Public API surface for SubstrateML in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
package: SubstrateML
languages: [swift, rust]
relates_to:
  - docs/reference/SUBSTRATEML_SPEC.md
  - docs/reference/SUBSTRATETYPES_INTERFACE.md
  - docs/reference/SUBSTRATEKERNEL_INTERFACE.md
purpose: |
  Public API surface of SubstrateML in both ports. Thirty-nine Swift
  files publish the cold-path algorithms over substrate types: the
  audit-log fold, matrix decay, Bradley-Terry estimation, NMF, FFT,
  eigenvalue centrality, lattice distance, anomaly / community
  detection, feature extractors, float-input SimHash, moment summary,
  partial-state recall, pairing handshake, tier-contribution
  fingerprint, tier-ascending query, action-outcome matrix, DP-OR
  reduction, LLM calibration curve, information theory, temporal
  compression, temporal-causality fold, pairwise association-rule
  mining, Apriori rule mining, row-attribute projection, bounded
  formal concept analysis, the Duquenne–Guigues concept-implication
  basis, a deterministic Jacobi SVD, the five-stage distillation
  pipeline (TypedDecayWeighting, DeltaFeatureExtractor,
  DistillationScorer, DistillationPipeline, DistilledHeader), and the
  ConflictCue pairwise text-conflict screen. The Rust mirror exposes
  the same shapes.
---

# SubstrateML Interface

## § 1 — Package layout

**Swift:** `packages/libs/SubstrateML/`

- `Sources/SubstrateML/` — 39 files, one per algorithm or family
  (including `TemporalCausalityFold.swift`, `RowAttributeView.swift`,
  `AprioriMining.swift`, `ConceptImplications.swift`, `JacobiSVD.swift`,
  `ConflictCue.swift`, `DeltaFeatureExtractor.swift`,
  `TypedDecayWeighting.swift`, `DistillationScorer.swift`, and
  `DistillationPipeline.swift`).
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
    public var rowId: UUID
    public var nounType: NounType
    public var stateRaw: UInt8
    public var adjectiveBitmap: Int64
    public var operationalBitmap: Int64
    public var provenanceBitmap: Int64
    public var latticeAnchor: LatticeAnchor
    public var tombstoned: Bool
    public var lastEventHLC: HLC
    public init(rowId: UUID, nounType: NounType, stateRaw: UInt8, /* … */)
}

public enum AuditLogFold {
    // Project from an unordered [AuditEvent] slice (the fold sorts by HLC).
    public static func projectCurrentState(
        rowId: UUID, nounType: NounType, events: [AuditEvent]
    ) -> ProjectedRowState?
    public static func projectStateAt(
        rowId: UUID, nounType: NounType, events: [AuditEvent], asOf: HLC
    ) -> ProjectedRowState?
    public static func projectAll(
        events: [AuditEvent], asOf: HLC? = nil,
        nounTypeFor: (UUID) -> NounType
    ) -> [UUID: ProjectedRowState]
}
```

```rust
pub struct ProjectedRowState { /* same fields, snake_case */ }
impl AuditLogFold {
    pub fn project_current_state(row_id: u128, noun_type: NounType, events: &[AuditEvent]) -> Option<ProjectedRowState>;
    pub fn project_state_at(row_id: u128, noun_type: NounType, events: &[AuditEvent], as_of: HLC) -> Option<ProjectedRowState>;
    pub fn project_all(events: &[AuditEvent], as_of: Option<HLC>, /* noun_type_for */) -> HashMap<u128, ProjectedRowState>;
}
```

### `DecayingMatrix`, `MatrixDecay`, `DecayHalfLives`

SPEC § 5.2.

```swift
public struct DecayingMatrix: Sendable {
    public let rows: Int
    public let cols: Int
    public var values: [Double]
    public let halfLifeSeconds: Double
    public var lastDecayTimeSeconds: Int64
    public init(rows: Int, cols: Int, /* values, halfLifeSeconds, … */)
}
public enum MatrixDecay {
    public static func apply(to matrix: inout DecayingMatrix, /* asOf … */)
    public static func decayFactor(elapsedSeconds: Double, /* halfLife … */) -> Double
    public static func decayAndAdd(to matrix: inout DecayingMatrix, /* … */)
    // Convenience overloads over the substrate matrices:
    public static func applyExponentialDecay(to matrix: inout MatrixF, /* … */)
    public static func applyExponentialDecay(to matrix: inout MatrixO, /* … */)
    public static func applyExponentialDecay(to matrix: inout MatrixC, /* … */)
}
public enum DecayHalfLives {
    public static let fieldPresenceSeconds:     Double = 90  * 86400
    public static let correlationSeconds:       Double = 180 * 86400
    public static let coActivationSeconds:      Double = 60  * 86400
    public static let temporalCausalitySeconds: Double = 30  * 86400
    public static let actionOutcomesSeconds:    Double = 365 * 86400
    public static let calibrationSeconds:       Double = 730 * 86400
    public static let wRankingSeconds:          Double = 90  * 86400
}
```

```rust
pub struct DecayingMatrix { pub rows: usize, pub cols: usize, pub values: Vec<f64>,
                            pub half_life_seconds: f64, pub last_decay_time_seconds: i64 }
// decay::apply / decay::decay_factor free functions; constants in decay::half_lives.
pub mod half_lives { pub const FIELD_PRESENCE_SECONDS: f64 = 90.0 * 86400.0; /* … */ }
```

### `PreferenceObservation`, `BradleyTerryEstimator`

SPEC § 5.3.

A win-over-a-loser-set observation keyed by `UUID` row identifiers;
the estimator is online SGD over a `[UUID: Double]` strength map.

```swift
public struct PreferenceObservation: Sendable {
    public let winnerID: UUID
    public let losers: [UUID]
    public let weight: Double          // typically 1.0
    public init(winnerID: UUID, losers: [UUID], weight: Double = 1.0)
}
public struct BradleyTerryEstimator: Sendable {
    public private(set) var theta: [UUID: Double]
    public let learningRate: Double
    public let l2: Double
    public init(learningRate: Double = 0.05, l2: Double = 0.001, /* … */)
    public mutating func observe(_ obs: PreferenceObservation)
    public mutating func observeBatch(_ observations: [PreferenceObservation])
    public func strength(of rowID: UUID) -> Double
    public func probability(_ a: UUID, beats b: UUID) -> Double
}
```

```rust
pub struct PreferenceObservation { pub winner_id: RowId, pub losers: Vec<RowId>, pub weight: f64 }
impl PreferenceObservation {
    pub fn new(winner_id: RowId, losers: Vec<RowId>) -> Self;            // weight = 1.0
    pub fn with_weight(winner_id: RowId, losers: Vec<RowId>, weight: f64) -> Self;
}
pub struct BradleyTerryEstimator { /* theta: HashMap<RowId, f64>, learning_rate, l2 */ }
impl BradleyTerryEstimator {
    pub fn new(learning_rate: f64, l2: f64) -> Self;
    pub fn observe(&mut self, obs: &PreferenceObservation);
    pub fn observe_batch(&mut self, observations: &[PreferenceObservation]);
    pub fn strength(&self, row_id: RowId) -> f64;
    pub fn probability_beats(&self, a: RowId, b: RowId) -> f64;
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

### `NMFDoubleFrobeniusSquaredFactorization`, `NMFDoubleFrobeniusSquared`

SPEC § 5.4b. **Not yet wired to production consumers.** An f64/Frobenius²
variant that must pass performance benchmarking before any consumer wires to
it. Correctness-gated: Swift scalar ↔ Rust scalar produce bit-identical output.
Conformance vector: `nmf_double_frobenius_squared.json`.

```swift
public struct NMFDoubleFrobeniusSquaredFactorization: Sendable, Equatable, Codable {
    public let w: [Double]           // rows × rank, row-major
    public let h: [Double]           // rank × cols, row-major
    public let rows: Int
    public let cols: Int
    public let rank: Int
    public let reconstructionError: Double  // raw Frobenius² (NOT RMS)
    public let iterations: Int
    public func loadings(forRow row: Int) -> [Double]
}
// PRODUCTION GATE: do not wire production consumers until benchmarked.
public enum NMFDoubleFrobeniusSquared {
    public static let defaultMaxIterations: Int   // 100
    public static let defaultTolerance: Double    // 1e-6 (Frobenius² delta)
    public static func factorize(
        o: [Double], rows: Int, cols: Int, rank: Int,
        seed: UInt64 = 0xC0FFEE_BABE_BEEF,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Double = defaultTolerance
    ) -> NMFDoubleFrobeniusSquaredFactorization
}
```

```rust
// PRODUCTION GATE: do not wire production consumers until benchmarked.
pub struct NMFDoubleFrobeniusSquaredFactorization {
    pub w: Vec<f64>, pub h: Vec<f64>,
    pub rows: usize, pub cols: usize, pub rank: usize,
    pub reconstruction_error: f64,  // raw Frobenius² (NOT RMS)
    pub iterations: usize,
}
impl NMFDoubleFrobeniusSquaredFactorization {
    pub fn loadings_for_row(&self, row: usize) -> Vec<f64>;
}
pub struct NMFDoubleFrobeniusSquared;
impl NMFDoubleFrobeniusSquared {
    pub const DEFAULT_MAX_ITERATIONS: usize;   // 100
    pub const DEFAULT_TOLERANCE: f64;          // 1e-6
    pub fn factorize(o: &[f64], rows: usize, cols: usize, rank: usize,
                     seed: u64, max_iterations: usize, tolerance: f64)
        -> NMFDoubleFrobeniusSquaredFactorization;
}
```

### `Complex`, `FFT`, `RhythmResult`

SPEC § 5.5.

```swift
public struct Complex: Hashable, Sendable {
    public var real: Double
    public var imag: Double
    public init(real: Double, imag: Double)
    public static let zero: Complex
    public var magnitude: Double { get }
    public var magnitudeSquared: Double { get }
    public static func + (a: Complex, b: Complex) -> Complex
    public static func - (a: Complex, b: Complex) -> Complex
    public static func * (a: Complex, b: Complex) -> Complex
}
public enum FFT {
    public static func forward(real input: [Double]) -> [Complex]   // length must be power of two
    public static func magnitudeSpectrum(real input: [Double]) -> [Double]
}
public struct RhythmResult: Sendable, Hashable {
    public let dominantPeriodSeconds: Double?
    public let spectralEnergy: Double
    public let windowBuckets: Int
    public let bucketDurationSeconds: Double
}
public enum RhythmAnalysis {
    public static func analyze(series: [Double], bucketDurationSeconds: Double) -> RhythmResult
    public static func analyze(fingerprints: [Fingerprint256], block: Int,
                               bitPosition: Int, bucketDurationSeconds: Double) -> RhythmResult
}
```

```rust
pub struct Complex { pub real: f64, pub imag: f64 }
pub fn forward(real_input: &[f64]) -> Vec<Complex>;          // fft::forward
pub fn magnitude_spectrum(real_input: &[f64]) -> Vec<f64>;
pub struct RhythmResult { pub dominant_period_seconds: Option<f64>, pub spectral_energy: f64,
                          pub window_buckets: usize, pub bucket_duration_seconds: f64 }
pub fn analyze(series: &[f64], bucket_duration_seconds: f64) -> RhythmResult;  // fft::analyze
```

### `EigenvalueCentrality`

SPEC § 5.6.

```swift
public enum EigenvalueCentrality {
    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]
    public static let defaultMaxIterations: Int = 100
    public static let defaultTolerance: Double = 1.0e-6
    public static func compute(
        adjacency: Adjacency,
        maxIterations: Int = defaultMaxIterations,
        tolerance: Double = defaultTolerance
    ) -> [Double]
}
```

```rust
impl EigenvalueCentrality {
    pub fn compute(adjacency: &[Vec<(usize, f64)>], max_iterations: usize, tolerance: f64) -> Vec<f64>;
}
```

### `RandomWalks`, `SplitMix64`

SPEC § 5 (background).

```swift
public struct SplitMix64 {
    public var state: UInt64
    public init(seed: UInt64)
    public mutating func next() -> UInt64
}
public enum RandomWalks {
    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]
    public static let defaultRestartProb: Double = 0.15

    // Indexed walk (NeuronKit / FreeAssociation consumer).
    // Precondition: every neighbor index in [0, N); every weight finite and ≥ 0.
    public static func walk(adjacency: Adjacency, start: Int, length: Int,
                            restartProb: Double = defaultRestartProb, seed: UInt64) -> [Int]

    // RowId walk (CognitionKit ExploratoryRecall consumer, cookbook § 19.1).
    // Operates in RowId (UUID) space; accumulates visit counts per RowId.
    // Preconditions: steps ≥ 1; restartProbability in [0, 1).
    public static func walkWithRestart(
        seed: RowId,
        steps: Int,
        restartProbability: Float32,
        rngSeed: UInt64,
        adjacency: [RowId: [RowId]]
    ) -> [RowId: Int]

    // Precondition: neighbors must be non-empty.
    public static func sampleWeighted(_ neighbors: [(neighbor: Int, weight: Double)],
                                      rng: inout SplitMix64) -> Int
    public static func uniform01(_ rng: inout SplitMix64) -> Double
}
```

```rust
pub struct SplitMix64 { pub state: u64 }
impl SplitMix64 { pub fn new(seed: u64) -> Self; pub fn next(&mut self) -> u64; }
impl RandomWalks {
    // Indexed walk (NeuronKit consumer). Same preconditions as Swift; violations panic.
    pub fn walk(adjacency: &[Vec<(usize, f64)>], start: usize, length: usize,
                restart_prob: f64, seed: u64) -> Vec<usize>;

    // RowId walk (CognitionKit ExploratoryRecall consumer, cookbook § 19.1).
    // Returns HashMap<RowId, u64> visit counts. RowId = substrate_types::row::RowId(u128).
    // Preconditions: steps ≥ 1; restart_probability in [0, 1).
    pub fn walk_with_restart(
        seed: RowId,
        steps: usize,
        restart_probability: f32,
        rng_seed: u64,
        adjacency: &HashMap<RowId, Vec<RowId>>,
    ) -> HashMap<RowId, u64>;

    pub fn sample_weighted(neighbors: &[(usize, f64)], rng: &mut SplitMix64) -> usize;
    pub fn uniform01(rng: &mut SplitMix64) -> f64;
}
```

### `Sampling`

SPEC § 5 (continuous-distribution samplers; cookbook §8.17).
Conformance-gated to exact f64 bit-identity (vector `sampling`,
CRC `0xfc883023`). All entry points thread the caller's `SplitMix64`
by reference; deterministic and cross-port reproducible from one seed.
Reuses `RandomWalks.uniform01`; does not re-own the RNG.

```swift
public enum Sampling {
    // Normal(0,1) via Box-Muller (cosine branch; fixed two-uniform draw).
    public static func sampleNormal(rng: inout SplitMix64) -> Double
    // Gamma(shape, scale=1) via Marsaglia-Tsang; Ahrens-Dieter reduction for shape<1.
    // Precondition: shape > 0.
    public static func sampleGamma(shape: Double, rng: inout SplitMix64) -> Double
    // Beta(alpha, beta) via the Gamma ratio. Precondition: alpha > 0, beta > 0.
    public static func sampleBeta(alpha: Double, beta: Double, rng: inout SplitMix64) -> Double
}
```

```rust
pub mod sampling {
    // Same algorithms, same RNG draw order; preconditions panic.
    pub fn sample_normal(rng: &mut SplitMix64) -> f64;
    pub fn sample_gamma(shape: f64, rng: &mut SplitMix64) -> f64;
    pub fn sample_beta(alpha: f64, beta: f64, rng: &mut SplitMix64) -> f64;
}
```

### `ShingleSimilarity`

SPEC § 5 (recall-ranking set similarity; cookbook §8.20).
Conformance-gated to exact f32 bit-identity (vector `shingle_similarity`,
CRC `0x8a5d8888`). The substrate home for the character-shingle Jaccard
used by recall-ranking diversity (MMR) passes — `NeuronKit`'s
`HybridRecallEngine` rerank term and `GeniusLocusKit`'s `RecallDirector`
unionBest dedup term both compute this and should delegate here (both
kits already depend on SubstrateML; the rewire is a follow-up). Pure
function of two strings: 3-character lowercase shingles, `|∩| / |∪|`
as f32; both-empty inputs score 0.0. No locale transforms, no clock,
no randomness.

```swift
public enum ShingleSimilarity {
    public static let windowSize: Int  // 3
    // The set of 3-char lowercase shingles of `s`. 1–2 chars -> single
    // whole-string shingle; "" -> empty set.
    public static func shingles(_ s: String) -> Set<String>
    // Jaccard over the shingle sets. Both empty -> 0.0.
    public static func similarity(_ a: String, _ b: String) -> Float32
}
```

```rust
pub mod shingle_similarity {
    pub const WINDOW_SIZE: usize;  // 3
    pub fn shingles(s: &str) -> std::collections::BTreeSet<String>;
    pub fn similarity(a: &str, b: &str) -> f32;
}
```

### `LatticeAnchorStr`, `UDCTreeDistance`, `LatticeDistance`, `WikidataAdjacencyProvider`

SPEC § 5.7.

```swift
public struct LatticeAnchorStr: Hashable, Sendable {
    public let udc: String
    public let qid: UInt64
    public init(udc: String, qid: UInt64 = 0)
}
public enum UDCTreeDistance {
    public static func longestCommonPrefixLength(_ a: String, _ b: String) -> Int
    public static func distance(_ a: String, _ b: String) -> Double
}
public protocol WikidataAdjacencyProvider {
    /// Q-IDs reachable from `qid` by one {subclass_of, instance_of, part_of} edge.
    func neighbors(of qid: UInt64) -> Set<UInt64>
}
public enum WikidataGraphDistance {
    public static let maxDepth: Int = 4
    public static let normalizationScale: Double = 3.0
    public static func shortestPathLength(from a: UInt64, to b: UInt64,
                                          provider: WikidataAdjacencyProvider, maxDepth: Int) -> Int?
    public static func distance(from a: UInt64, to b: UInt64,
                                provider: WikidataAdjacencyProvider, maxDepth: Int = maxDepth) -> Double
}
public enum LatticeDistance {
    public static let defaultAlphaUDC: Double = 0.5
    public static let defaultAlphaQID: Double = 0.5
    // Hashed-LatticeAnchor proxy (binary equality):
    public static func distance(_ a: LatticeAnchor, _ b: LatticeAnchor) -> Float32
    public static func isInSubtree(_ child: LatticeAnchor, of parent: LatticeAnchor) -> Bool
    // True combined UDC-tree + Wikidata-graph distance over the string form:
    public static func distance(_ a: LatticeAnchorStr, _ b: LatticeAnchorStr,
                                provider: WikidataAdjacencyProvider,
                                alphaUDC: Double = defaultAlphaUDC,
                                alphaQID: Double = defaultAlphaQID) -> Double
}
```

```rust
pub struct LatticeAnchorStr { pub udc: String, pub qid: u64 }
pub trait WikidataAdjacencyProvider { /* neighbor query */ }
impl UDCTreeDistance { pub fn distance(a: &str, b: &str) -> f64; }
impl WikidataGraphDistance { pub fn distance(from: u64, to: u64, provider: &dyn WikidataAdjacencyProvider, max_depth: usize) -> f64; }
impl LatticeDistance {
    pub fn distance_hashed(a: &LatticeAnchor, b: &LatticeAnchor) -> f32;
    pub fn distance(a: &LatticeAnchorStr, b: &LatticeAnchorStr,
                    provider: &dyn WikidataAdjacencyProvider, alpha_udc: f64, alpha_qid: f64) -> f64;
}
```

### `CompositeDistance`

SPEC § 5.8.

```swift
public enum CompositeDistance {
    public static let defaultAlphaLattice: Double = 0.5
    public static let defaultAlphaFingerprint: Double = 0.5
    public static let fingerprintTotalBits: Int = 256
    public static func distance(
        latticeDistance: Double,                 // must be in [0, 1]
        fingerprintHammingDistance: Int,
        alphaLattice: Double = defaultAlphaLattice,
        alphaFingerprint: Double = defaultAlphaFingerprint,
        compatibleSeedScope: Bool = true
    ) -> Double
}
```

```rust
impl CompositeDistance {
    pub fn distance(lattice_distance: f64, fingerprint_hamming_distance: i64,
                    alpha_lattice: f64, alpha_fingerprint: f64,
                    compatible_seed_scope: bool) -> f64;
}
```

### `StreamSourceFlag`, `AmbientSampleRow`, the five extractors + their samples

SPEC § 5.9. Five platform-specific extractor structs each take a typed
`*Sample` and produce an `AmbientSampleRow` via
`extract(_:hlc:rowId:)`. There is no `FeatureExtractors` Interface type;
each extractor is used directly.

`StreamSourceFlag` is a single-bit-per-source bitmap (raw values are
powers of two, not ordinals). `AmbientSampleRow` carries the raw
`streamSource: UInt8` bitmap (field p06), not the enum directly. Each
extractor is constructed with the per-block `[HyperplaneFamily]` and
exposes an `extract` method.

```swift
public enum StreamSourceFlag: UInt8, Sendable {
    case healthkit       = 0b0000_0001
    case corelocation    = 0b0000_0010
    case eventkit        = 0b0000_0100
    case screentime      = 0b0000_1000
    case systemTelemetry = 0b0001_0000
    case latticeLookup   = 0b0010_0000
}
public struct AmbientSampleRow: Sendable {
    public let rowId: RowId
    public let captureHLC: HLC
    public let streamSource: UInt8        // bitmap field p06
    public let fingerprint: Fingerprint256
    public let lattice: LatticeAnchor
    public let payload: Data
    public init(rowId: RowId, /* … */)
}
// Typed per-source samples (each `Sendable`), e.g.:
public struct HealthKitSample: Sendable {
    public let quantityType: String       // "stepCount", "heartRate", …
    public let value: Double
    public let unit: String
    public let startDate: TimeInterval
    public let endDate: TimeInterval
    public let sourceDevice: String
    public init(quantityType: String, value: Double, unit: String, /* … */)
}
// CoreLocationSample / EventKitSample / ScreenTimeSample / SystemTelemetrySample — analogous.
// Concrete extractor structs, one per source, constructed with the hyperplane families:
public struct HealthKitExtractor {
    public init(hyperplanes: [HyperplaneFamily])
    // extract(_:HealthKitSample) -> AmbientSampleRow
}
// CoreLocationExtractor / EventKitExtractor / ScreenTimeExtractor /
// SystemTelemetryExtractor — analogous (each init(hyperplanes:) + extract).
```

```rust
pub enum StreamSourceFlag { Healthkit, Corelocation, Eventkit, ScreenTime, SystemTelemetry, LatticeLookup }
pub struct AmbientSampleRow { /* row_id, capture_hlc, stream_source: u8, fingerprint, lattice, payload */ }
pub struct HealthKitSample { /* quantity_type, value, unit, start_date, end_date, source_device */ }
// CoreLocationSample / EventKitSample / ScreenTimeSample / SystemTelemetrySample — analogous.
pub struct HealthKitExtractor<'a> { /* borrows &[HyperplaneFamily] */ }
impl<'a> HealthKitExtractor<'a> {
    pub fn extract(&self, s: &HealthKitSample, hlc: HLC, row_id: u128) -> AmbientSampleRow;
}
// CoreLocationExtractor / EventKitExtractor / ScreenTimeExtractor /
// SystemTelemetryExtractor<'a> — analogous.
```

### `FloatSimHash`

SPEC § 5.10.

```swift
public enum FloatSimHash {
    public static func project(vector: [Float], seed: UInt64) -> Fingerprint256
}
```

```rust
pub fn project(vector: &[f32], seed: u64) -> Fingerprint256;   // float_simhash::project
```

### `RowLite`, `MomentSummary`

SPEC § 5.11.

`RowLite` is a lightweight (fingerprint, captureHLC) pair.
`MomentSummary.summarize` OR-reduces the fingerprints of rows passing
an `activeDuring` predicate and returns a single `Fingerprint256`.

```swift
public struct RowLite: Sendable, Hashable {
    public let fingerprint: Fingerprint256
    public let captureHLC: HLC
    public init(fingerprint: Fingerprint256, captureHLC: HLC)
}
public enum MomentSummary {
    public static func summarize(rows: [Row], window: TimeRange,
                                 activeDuring: (Row, TimeRange) -> Bool) -> Fingerprint256
    public static func summarize(rows: [RowLite], window: TimeRange,
                                 activeDuring: (RowLite, TimeRange) -> Bool) -> Fingerprint256
    public static func capturedDuring(_ row: RowLite, _ window: TimeRange) -> Bool
    public static func orReduce(_ fps: [Fingerprint256]) -> Fingerprint256
}
```

```rust
pub struct RowLite { pub fingerprint: Fingerprint256, pub capture_hlc: HLC }
impl MomentSummary {
    pub fn summarize(rows: &[RowLite], window: &TimeRange,
                     active_during: impl Fn(&RowLite, &TimeRange) -> bool) -> Fingerprint256;
    pub fn captured_during(row: &RowLite, window: &TimeRange) -> bool;
}
```

### `PartialStateRecall`

SPEC § 5.12.

Per-block match/differ scoring over the four 64-bit blocks: a row
scores high when it matches the anchor on `matchBlocks` and differs on
`differBlocks`.

```swift
public enum PartialStateRecall {
    public static func score(rowFingerprint: Fingerprint256, anchor: Fingerprint256,
                             matchBlocks: Set<Int>, differBlocks: Set<Int>) -> Double
    public static func topK(
        anchor: Fingerprint256,
        rows: [(rowId: UUID, fingerprint: Fingerprint256)],
        matchBlocks: Set<Int>, differBlocks: Set<Int>, k: Int
    ) -> [(rowId: UUID, score: Double)]
    public static func hammingBlocks(_ a: Fingerprint256, _ b: Fingerprint256, blocks: Set<Int>) -> Int
}
```

```rust
impl PartialStateRecall {
    pub fn score(row_fingerprint: &Fingerprint256, anchor: &Fingerprint256,
                 match_blocks: &HashSet<usize>, differ_blocks: &HashSet<usize>) -> f64;
    pub fn top_k(anchor: &Fingerprint256, rows: &[(u128, Fingerprint256)],
                 match_blocks: &HashSet<usize>, differ_blocks: &HashSet<usize>, k: usize) -> Vec<(u128, f64)>;
    pub fn hamming_blocks(a: &Fingerprint256, b: &Fingerprint256, blocks: &HashSet<usize>) -> u32;
}
```

### `PairingNonce`, `PairingRecord`, `PairingHandshake`

SPEC § 5.13.

```swift
public struct PairingNonce: Sendable, Equatable {
    public let bytes: [UInt8]   // 32 bytes
    public init(bytes: [UInt8])
    public func seedWith(estateA: UUID, estateB: UUID) -> UInt64
}
public struct PairingRecord: Sendable, Equatable {
    public let peerEstate: UUID
    public let federationCase: FederationCase
    public let sharedFamilyKey: String     // "H_shared_<case>_<peer_uuid>"
    public let pairedAt: HLC
    public init(peerEstate: UUID, federationCase: FederationCase, /* … */)
}
/// Top-level audit record emitted by a pairing or unpairing handshake.
/// Mirrors Rust top-level `PairingAuditPayload` (pairing.rs). peerEstate
/// is UUID in Swift; [u8; 16] in Rust — byte-equivalent representations.
public struct PairingAuditPayload: Sendable, Equatable {
    public let mutationKind: String          // "pair" | "unpair"
    public let peerEstate: UUID
    public let federationCase: FederationCase
    public let sharedFamilyHash: UInt64
    public let hlc: HLC
    public init(mutationKind: String, peerEstate: UUID, /* … */)
}
public enum PairingHandshake {
    public static func generateSharedFamily(nonce: PairingNonce, estateA: UUID, estateB: UUID,
                                            density: Double = 1.0) -> [HyperplaneFamily]
    public static func sharedFamilyKey(case federationCase: FederationCase, peerEstate: UUID) -> String
    public static func buildPairEvent(peerEstate: UUID, /* … */) -> PairingAuditPayload
    public static func buildUnpairEvent(peerEstate: UUID, /* … */) -> PairingAuditPayload
}
```

```rust
pub struct PairingNonce { pub bytes: Vec<u8> }
impl PairingNonce { pub fn seed_with(&self, estate_a: u128, estate_b: u128) -> u64; }
pub struct PairingRecord { pub peer_estate: u128, pub federation_case: FederationCase,
                           pub shared_family_key: String, pub paired_at: HLC }
pub struct PairingAuditPayload { pub mutation_kind: String, pub peer_estate: u128,
                                 pub federation_case: FederationCase, pub shared_family_hash: u64, pub hlc: HLC }
impl PairingHandshake {
    pub fn generate_shared_family(nonce: &PairingNonce, estate_a: u128, estate_b: u128, density: f64) -> Vec<HyperplaneFamily>;
    pub fn shared_family_key(federation_case: FederationCase, peer_estate: u128) -> String;
}
```

### `FederationCase`, `TierContribution`, `TierContributionFingerprint`

SPEC § 5.14.

```swift
public enum FederationCase: UInt32, Sendable {
    case household = 1
    case fleet     = 2
    case industry  = 3
}
public struct TierContribution: Sendable, Equatable {
    public let estateUUID: UUID
    public let federationCase: FederationCase
    public let rowCount: UInt32
    public let aggregate: Fingerprint256
    public let hlc: HLC
    public init(estateUUID: UUID, federationCase: FederationCase, /* … */)
}
public enum TierContributionFingerprint {
    public static func build(estateUUID: UUID, case federationCase: FederationCase, /* … */) -> TierContribution
    public static func encode(_ contrib: TierContribution) -> Data
    public static func decode(_ data: Data) -> TierContribution?
}
```

```rust
pub enum FederationCase { Household = 1, Fleet = 2, Industry = 3 }
pub struct TierContribution { pub estate_uuid: u128, pub federation_case: FederationCase,
                              pub row_count: u32, pub aggregate: Fingerprint256, pub hlc: HLC }
impl TierContributionFingerprint {
    pub fn build(estate_uuid: u128, federation_case: FederationCase, /* … */) -> TierContribution;
    pub fn encode(contrib: &TierContribution) -> Vec<u8>;
    pub fn decode(data: &[u8]) -> Option<TierContribution>;
}
```

### `TargetTier`, `TierAscendingQuery`, `PeerResponse`

SPEC § 5.14.

```swift
public enum TargetTier: String, Sendable {
    case peer              = "peer"
    case fleetAggregate    = "fleet_aggregate"
    case industryAggregate = "industry_aggregate"
}
public struct TierAscendingQuery: Sendable {
    public let originatingEstate: UUID
    public let primitiveName: String
    public let primitiveInput: Data         // canonical-encoded primitive params
    public let targetTier: TargetTier
    public let privacyBudget: DPParameters
    public let queryHLC: HLC
    public init(originatingEstate: UUID, primitiveName: String, /* … */)
}
public struct PeerResponse: Sendable {
    public let peerEstate: UUID
    public let contribution: RecallResult   // canonical recall vocabulary (SubstrateTypes)
    public let consumedEpsilon: Float64
    public let consumedDelta: Float64
}
public enum TierAscendingQueryProtocol {
    public static func computeLocal(query: TierAscendingQuery, /* … */) -> RecallResult
    public static func applyDPToContribution(_ result: RecallResult, /* params … */) -> RecallResult
    public static func combine(local: RecallResult, /* peer responses … */) -> RecallResult
}
public struct PrivacyLedger: Sendable {
    public let dailyBudget: DPParameters
    public init(dailyBudget: DPParameters = DPParameters())
    public func remaining(peer: UUID) -> (epsilon: Float64, delta: Float64)
    public func canConsume(peer: UUID, query: DPParameters) -> Bool
    public mutating func consume(peer: UUID, query: DPParameters)
    public mutating func dailyReset()
}
```

```rust
pub enum TargetTier { Peer, FleetAggregate, IndustryAggregate }
pub struct TierAscendingQuery { /* originating_estate, primitive_name, primitive_input,
                                  target_tier, privacy_budget, query_hlc */ }
pub struct PeerResponse { pub peer_estate: u128, pub contribution: RecallResult,
                          pub consumed_epsilon: f64, pub consumed_delta: f64 }
impl TierAscendingQueryProtocol {
    pub fn compute_local(query: &TierAscendingQuery, /* … */) -> RecallResult;
    pub fn apply_dp_to_contribution(result: &RecallResult, /* … */) -> RecallResult;
    pub fn combine(local: &RecallResult, /* … */) -> RecallResult;
}
pub struct PrivacyLedger { /* daily_budget + per-peer spend */ }
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
    public var successRate: Float32 { get }       // computed: successCount/totalCount; 0 when empty
    public var wilsonLowerBound: Float32 { get }  // computed: 95 % Wilson LB; always ≤ successRate
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
    public let epsilon: Float64
    public let delta: Float64
    public let kAnonymity: Int
    public init(epsilon: Float64 = 1.0, delta: Float64 = 1e-9, kAnonymity: Int = 3)
}
public enum DPORReduction {
    public static func reduce(fingerprints: [Fingerprint256],
                              params: DPParameters,
                              rngSeed: UInt64) -> Fingerprint256
}
```

```rust
pub struct DPParameters { pub epsilon: f64, pub delta: f64, pub k_anonymity: usize }
impl DPORReduction {
    pub fn reduce(fingerprints: &[Fingerprint256], params: &DPParameters, rng_seed: u64) -> Fingerprint256;
}
```

### `LLMCalibrationCurve`

SPEC § 5.17.

Bucketed reliability curve over (claimed-confidence, observed-outcome)
pairs. Lives in the Rust `calibration` module.

```swift
public struct LLMCalibrationCurve: Sendable {
    public init()
    public mutating func observe(claimedConfidence: Float32, actualOutcome: Bool)
    public func actualRate(in bucket: Int) -> Float32?
    public static func midpoint(of bucket: Int) -> Float32
    public func expectedCalibrationError() -> Float32
    public func brierScore() -> Float32
    public mutating func decay(factor: Float32)
}
```

```rust
// In substrate_ml::calibration
pub struct LLMCalibrationCurve { /* per-bucket counters */ }
impl LLMCalibrationCurve {
    pub fn new() -> Self;
    pub fn observe(&mut self, claimed_confidence: f32, actual_outcome: bool);
    pub fn actual_rate(&self, bucket: usize) -> Option<f32>;
    pub fn expected_calibration_error(&self) -> f32;
    pub fn brier_score(&self) -> f32;
    pub fn decay(&mut self, factor: f32);
}
```

### `InformationTheory`

SPEC § 5.18.

```swift
public enum InformationTheory {
    public static func entropy(_ p: [Float32]) -> Float32
    public static func mutualInformation(joint: [[Float32]]) -> Float32
    public static func klDivergence(_ p: [Float32], _ q: [Float32]) -> Float32
    public static func crossEntropy(_ p: [Float32], _ q: [Float32]) -> Float32
    public static func jensenShannon(_ p: [Float32], _ q: [Float32]) -> Float32
    public static func normalizedMutualInformation(joint: [[Float32]]) -> Float32
}
```

```rust
// info_theory module (free functions / impl InformationTheory)
pub fn entropy(p: &[f32]) -> f32;
pub fn mutual_information(joint: &[Vec<f32>]) -> f32;
pub fn kl_divergence(p: &[f32], q: &[f32]) -> f32;
pub fn cross_entropy(p: &[f32], q: &[f32]) -> f32;
pub fn jensen_shannon(p: &[f32], q: &[f32]) -> f32;
pub fn normalized_mutual_information(joint: &[Vec<f32>]) -> f32;
```

### `WindowLevel`, `TemporalWindow`, `TemporalCompression`

SPEC § 5.19.

```swift
public enum WindowLevel: Int, Comparable, Sendable {
    case hour = 0, day = 1, week = 2, month = 3, quarter = 4, year = 5
}
public struct TemporalWindow: Equatable, Sendable {
    public let startHLC: HLC
    public let endHLC: HLC
    public let level: WindowLevel
    public let fingerprint: Fingerprint256
    public let rowCount: UInt32
    public init(startHLC: HLC, endHLC: HLC, level: WindowLevel, /* … */)
    public static func empty(level: WindowLevel) -> TemporalWindow
}
public enum TemporalCompression {
    public static func compress(rows: [Fingerprint256], startHLC: HLC, endHLC: HLC,
                                level: WindowLevel) -> TemporalWindow
    public static func rollup(windows: [TemporalWindow], to targetLevel: WindowLevel) -> TemporalWindow
    public static func cascadeRollup(hourWindows: [TemporalWindow],
                                     upTo finalLevel: WindowLevel) -> [WindowLevel: [TemporalWindow]]
}
```

```rust
pub enum WindowLevel { Hour, Day, Week, Month, Quarter, Year }
pub struct TemporalWindow { pub start_hlc: HLC, pub end_hlc: HLC, pub level: WindowLevel,
                            pub fingerprint: Fingerprint256, pub row_count: u32 }
impl TemporalCompression {
    pub fn compress(rows: &[Fingerprint256], start_hlc: HLC, end_hlc: HLC, level: WindowLevel) -> TemporalWindow;
    pub fn rollup(windows: &[TemporalWindow], target_level: WindowLevel) -> TemporalWindow;
    pub fn cascade_rollup(hour_windows: &[TemporalWindow], up_to: WindowLevel) -> HashMap<WindowLevel, Vec<TemporalWindow>>;
}
```

### `AnomalyDetection`, `CommunityDetection`, `Calibration`

SPEC § 5.26 (AnomalyDetection behavioral contract); see also § 8 (VizGraph telemetry).

```swift
public enum AnomalyDetection {
    /// Classic z-score: (value − mean) / stddev. Returns 0 when stddev is zero.
    @inlinable
    public static func zScore(value: Float32, mean: Float32, stddev: Float32) -> Float32

    /// Rolling-window z-score using the supplied window as the baseline distribution.
    /// Empty window returns 0.
    /// Emits `VizGraphSignals.anomalyFlag` (abs z-score, method: "z_score", estate, window_size)
    /// when monitoring is enabled; off-path cost is a single atomic-bool load.
    public static func rollingZScore(window: [Float32], current: Float32,
                                     estate: String = "", ts: Double = 0) -> Float32

    /// Modified z-score: 0.6745 × (value − median) / MAD. Returns 0 when MAD is zero.
    /// The 0.6745 constant makes the score consistent with the normal-distribution z-score.
    public static func modifiedZScore(value: Float32, median: Float32, mad: Float32) -> Float32

    /// Rolling modified z-score. Computes median and MAD from the window in-place.
    /// Empty window returns 0.
    /// Emits `VizGraphSignals.anomalyFlag` (abs modified z-score, method: "modified_z_score",
    /// estate, window_size) when monitoring is enabled; off-path cost is a single atomic-bool load.
    public static func rollingModifiedZScore(window: [Float32], current: Float32,
                                              estate: String = "", ts: Double = 0) -> Float32

    /// Returns true when |zScore| >= threshold.
    /// Default threshold 3.0 yields ~0.27% false positive rate under a normal distribution.
    @inlinable
    public static func isAnomalous(zScore: Float32, threshold: Float32 = 3.0) -> Bool
}

public enum CommunityDetection {
    public typealias Adjacency = [[(neighbor: Int, weight: Double)]]

    /// Louvain phase 1 (local-move) — the per-level engine.
    public static func detect(adjacency: Adjacency,
                              maxPasses: Int = 10,
                              estate: String = "",
                              ts: Double = 0) -> [Int]

    /// Full Louvain: phase 1 + phase-2 aggregation loop, with a
    /// Reichardt–Bornholdt resolution parameter (1.0 = classical).
    /// Emits exactly one community.assignment signal for the final
    /// partition; per-level cores are non-emitting.
    public static func detectFull(adjacency: Adjacency,
                                  maxLevels: Int = 10,
                                  maxPasses: Int = 10,
                                  resolution: Double = 1.0,
                                  estate: String = "",
                                  ts: Double = 0) -> [Int]

    /// Renumber labels 0..K-1 in order of first appearance.
    public static func canonicalize(_ labels: [Int]) -> [Int]
}

public struct LLMCalibrationCurve { /* … see § 5.17 */ }
```

```rust
pub struct AnomalyDetection;
impl AnomalyDetection {
    /// Classic z-score. Returns 0 when stddev is zero.
    pub fn z_score(value: f32, mean: f32, stddev: f32) -> f32;
    /// Rolling-window z-score. Empty window returns 0.
    /// Emits VizGraphSignals::ANOMALY_FLAG (abs z-score, method: "z_score") when monitoring is enabled.
    pub fn rolling_z_score(window: &[f32], current: f32, estate: &str, ts: f64) -> f32;
    /// Modified z-score using MAD. Returns 0 when MAD is zero.
    pub fn modified_z_score(value: f32, median: f32, mad: f32) -> f32;
    /// Rolling modified z-score. Computes median and MAD in-place.
    /// Emits VizGraphSignals::ANOMALY_FLAG (abs modified z-score, method: "modified_z_score")
    /// when monitoring is enabled.
    pub fn rolling_modified_z_score(window: &[f32], current: f32, estate: &str, ts: f64) -> f32;
    /// No default threshold in Rust; caller must supply explicitly (Swift default: 3.0).
    pub fn is_anomalous(z_score: f32, threshold: f32) -> bool;
}

pub mod community_detection {
    pub struct CommunityDetection;
    impl CommunityDetection {
        /// Louvain phase 1 (local-move) — the per-level engine.
        pub fn detect(adjacency: &[Vec<(usize, f64)>], max_passes: usize,
                      estate: &str, ts: f64) -> Vec<usize>;

        /// Full Louvain: phase 1 + phase-2 aggregation loop, with a
        /// Reichardt–Bornholdt resolution parameter (1.0 = classical).
        pub fn detect_full(adjacency: &[Vec<(usize, f64)>],
                           max_levels: usize, max_passes: usize,
                           resolution: f64,
                           estate: &str, ts: f64) -> Vec<usize>;

        /// Renumber labels 0..K-1 in order of first appearance.
        pub fn canonicalize(labels: &[usize]) -> Vec<usize>;
    }
}

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

### `TemporalFieldCoord`, `TemporalAuditEntry`, `TemporalCausalityKey`, `TemporalCausalityFold`

SPEC § 5.22. The temporal-causality fold scans capture/expunge audit
entries within a sliding window and emits directional, lag-bucketed
(source → target) coordinate-pair deltas for the T matrix.

```swift
public struct TemporalFieldCoord: Hashable, Sendable, Codable {
    public let fieldPath: String
    public let valueRepr: String           // e.g. "bitmap:42", "string:x", "integer:-1"
    public init(fieldPath: String, valueRepr: String)
}
public struct TemporalAuditEntry: Sendable {
    public let hlc: HLC
    public let fieldCoords: [TemporalFieldCoord]
    public init(hlc: HLC, fieldCoords: [TemporalFieldCoord])
}
public struct TemporalCausalityKey: Hashable, Sendable, Codable {
    public let source: TemporalFieldCoord
    public let target: TemporalFieldCoord
    public let lagBucket: Int              // one of {1, 2, 4, 8, 16, 32, 64, 128} minutes
    public init(source: TemporalFieldCoord, target: TemporalFieldCoord, lagBucket: Int)
}
/// Named result of a fold pass. Mirrors Rust `FoldResult`.
public struct FoldResult: Sendable {
    public let deltas: [(TemporalCausalityKey, Int64)]
    public let newWatermark: HLC
    public init(deltas: [(TemporalCausalityKey, Int64)], newWatermark: HLC)
}
public enum TemporalCausalityFold {
    public static let lagBuckets: [Int]          // [1, 2, 4, 8, 16, 32, 64, 128] — log-spaced bucket boundaries (minutes)
    public static let defaultWindowMinutes: Int  // 256 — window cap for T (cookbook §6.4)
    public static let maxWindowOccupancy: Int    // 512 — pairing-buffer occupancy cap; bounds fold to O(n × cap)
    public static func lagBucket(forMinutes minutes: Int) -> Int
    public static func fold(
        entries: [TemporalAuditEntry],
        windowMinutes: Int = defaultWindowMinutes,
        startWatermark: HLC
    ) -> FoldResult
}
```

```rust
pub struct TemporalFieldCoord { pub field_path: String, pub value_repr: String }
pub struct TemporalAuditEntry { pub hlc: HLC, pub field_coords: Vec<TemporalFieldCoord> }
pub struct TemporalCausalityKey { pub source: TemporalFieldCoord, pub target: TemporalFieldCoord, pub lag_bucket: i64 }
/// Named result struct; Swift mirrors as `public struct FoldResult`.
pub struct FoldResult { pub deltas: Vec<(TemporalCausalityKey, i64)>, pub new_watermark: HLC }
impl TemporalCausalityFold {
    pub const LAG_BUCKETS: [i32; 8];         // [1, 2, 4, 8, 16, 32, 64, 128]; re-exports module const
    pub const DEFAULT_WINDOW_MINUTES: i32;   // 256; re-exports module const
    // MAX_WINDOW_OCCUPANCY (= 512, usize) is a module-level pub const, not re-exported on the impl
    pub fn lag_bucket(minutes: i64) -> i64;
    pub fn fold(entries: &[TemporalAuditEntry], window_minutes: i64, start_watermark: HLC) -> FoldResult;
}
```

### `SVDResult`, `JacobiSVD`

SPEC § 5.23.

One-sided cyclic Jacobi SVD for real matrices (m × n, m ≥ n). Bit-identical
output in Swift and Rust is guaranteed by a fixed sweep count, a fixed
round-robin tournament column-pair order (column-disjoint within each round,
enabling parallel sweeps), identical scalar Float32 arithmetic, and a
canonical sign convention (force the largest-magnitude component of each left
singular vector positive). Consumed by CorpusKit's `LsaProvider` for LSA
distributional embeddings. Default sweep count: 30 (pinned in both ports).

```swift
/// Result of a JacobiSVD decomposition: A ≈ U · diag(singularValues) · Vᵀ.
public struct SVDResult: Sendable {
    public let U: [[Float]]             // m × rank, row-major left singular vectors
    public let singularValues: [Float]  // rank values in non-increasing order (≥ 0)
    public let Vt: [[Float]]            // rank × n, row-major right singular vectors
    public let rank: Int                // requested truncation rank k
    public init(U: [[Float]], singularValues: [Float], Vt: [[Float]], rank: Int)
}
public enum JacobiSVD {
    // Preconditions: A non-empty, rectangular, m ≥ n, rank ≥ 1, sweeps ≥ 0.
    // rank is clamped to min(m, n). Violations trigger precondition (process-terminating).
    public static func decompose(A: [[Float]], rank: Int, sweeps: Int = 30) -> SVDResult
    // Round-robin tournament schedule for n columns. Each round contains
    // column-disjoint (p, q) pairs so a full sweep covers every unordered
    // pair exactly once. Pairs within a round are sorted (p < q) for
    // determinism. Pure integer function of n — no floats, no drift.
    public static func tournamentRounds(_ n: Int) -> [[(p: Int, q: Int)]]
}
```

```rust
// substrate_ml::svd
pub struct SvdResult {
    pub u: Vec<Vec<f32>>,             // m × rank, row-major
    pub singular_values: Vec<f32>,    // non-increasing, all ≥ 0
    pub vt: Vec<Vec<f32>>,            // rank × n, row-major
    pub rank: usize,
}
pub struct JacobiSvd;
impl JacobiSvd {
    // Preconditions same as Swift; violations panic.
    pub fn decompose(a: &[Vec<f32>], rank: usize, sweeps: usize) -> SvdResult;
    pub fn tournament_rounds(n: usize) -> Vec<Vec<(usize, usize)>>;
}
```

### `DistillationFeatureType`, `TypedDecayWeighting`

SPEC § 5.24.

Feature type classification and type-specific exponential decay weighting for
the distillation pipeline. `DistillationFeatureType` carries the canonical
type tag (`ENT`, `REL`, `TMP`, `NUM`) and its associated λ. Higher λ means
faster staleness — NUM (version numbers) decays fastest; ENT (domain concepts)
persists longest.

```swift
public enum DistillationFeatureType: String, Sendable, Codable, CaseIterable {
    case entity    = "ENT"   // λ = 0.1
    case relation  = "REL"   // λ = 0.2
    case temporal  = "TMP"   // λ = 0.5
    case numerical = "NUM"   // λ = 0.8
    public var decayLambda: Float32 { get }
}
public enum TypedDecayWeighting {
    // w = exp(-λ × max(0, ageInUnits)). Returns 1.0 at age 0.
    public static func weight(featureType: DistillationFeatureType, ageInUnits: Float32) -> Float32
    // Weighted document frequency per DISTILLATION_MATH_DIFFUSION.md §2.
    // Returns 0 when allMemoryTimestamps is empty.
    public static func weightedDocFrequency(
        featureType: DistillationFeatureType,
        presenceTimestamps: [Date],
        allMemoryTimestamps: [Date],
        referenceDate: Date,
        timeUnit: Double = 86_400   // 1 day in seconds
    ) -> Float32
}
```

```rust
// substrate_ml::typed_decay_weighting
pub enum DistillationFeatureType { Entity, Relation, Temporal, Numerical }
impl DistillationFeatureType {
    pub fn decay_lambda(&self) -> f32;
}
pub struct TypedDecayWeighting;
impl TypedDecayWeighting {
    pub fn weight(feature_type: DistillationFeatureType, age_in_units: f32) -> f32;
    // Timestamps are epoch-second f64 in Rust (Rust has no Date type).
    pub fn weighted_doc_frequency(
        feature_type: DistillationFeatureType,
        presence_timestamps: &[f64],
        all_memory_timestamps: &[f64],
        reference_date: f64,
        time_unit: f64,
    ) -> f32;
}
```

### `DeltaType`, `DeltaAnalysis`, `DeltaFeatureExtractor`

SPEC § 5.24 (Stage 2.5).

Trajectory analysis for a feature's value sequence across a memory cluster.
Stage 2.5 of the distillation pipeline: rescues CONVERGENT and MONOTONE
features that would otherwise fail the structural recurrence threshold.

```swift
public enum DeltaType: String, Sendable, Codable, Equatable {
    case `static`    = "STATIC"      // all values identical
    case convergent  = "CONVERGENT"  // categorical sequence converges to stable terminal
    case monotone    = "MONOTONE"    // numerical sequence trends monotonically
    case oscillating = "OSCILLATING" // period-2 pattern A→B→A→B
    case divergent   = "DIVERGENT"   // no classifiable pattern
}
public struct DeltaAnalysis: Sendable, Equatable {
    public let deltaType: DeltaType
    public let terminalValue: String    // most recent value in the sequence
    public let convergenceScore: Float32 // k/M trailing matches (categorical); 1.0 for MONOTONE/STATIC
    public let slope: Float32?           // average per-step diff; non-nil for MONOTONE only
    public let confidence: Float32
    public init(deltaType: DeltaType, terminalValue: String,
                convergenceScore: Float32, slope: Float32?, confidence: Float32)
}
public enum DeltaFeatureExtractor {
    // sequence: chronologically ordered (value, timestamp) pairs, oldest first.
    // decayLambda: convergence threshold (default 0.5 for categorical, 0.8 for numerical).
    public static func analyzeCategorical(
        sequence: [(value: String, timestamp: Date)], decayLambda: Float32 = 0.5
    ) -> DeltaAnalysis
    public static func analyzeNumerical(
        sequence: [(value: Double, timestamp: Date)], decayLambda: Float32 = 0.8
    ) -> DeltaAnalysis
}
```

```rust
// substrate_ml::delta_feature_extractor
pub enum DeltaType { Static, Convergent, Monotone, Oscillating, Divergent }
impl DeltaType { pub fn as_str(&self) -> &'static str; }
pub struct DeltaAnalysis {
    pub delta_type: DeltaType,
    pub terminal_value: String,
    pub convergence_score: f32,
    pub slope: Option<f32>,
    pub confidence: f32,
}
pub struct DeltaFeatureExtractor;
impl DeltaFeatureExtractor {
    // Timestamps are (String, f64) / (f64, f64) epoch seconds in Rust.
    pub fn analyze_categorical(sequence: &[(String, f64)], decay_lambda: f32) -> DeltaAnalysis;
    pub fn analyze_numerical(sequence: &[(f64, f64)], decay_lambda: f32) -> DeltaAnalysis;
}
```

### `ExtractedFeature`, `DistillationSNR`, `FeatureGraph`, `DistillationScorer`

SPEC § 5.24.

Core distillation scoring types and namespace. All methods are pure functions
— no I/O, no state, no randomness. Per DISTILLATION_MATH_SSA.md §2–6.

```swift
public struct ExtractedFeature: Sendable, Equatable {
    public let type: DistillationFeatureType
    public let value: String              // canonical stem; vocabulary dedup and fingerprint key
    public let display: String            // surface form for prose (defaults to value)
    public var docFrequency: Float32      // df(f) = count_present / M
    public var weightedDocFrequency: Float32
    public var structuralScore: Float32   // σ(f) = df × (1 − H(df)), set by computeStructuralScores
    public init(type: DistillationFeatureType, value: String, docFrequency: Float32,
                display: String? = nil)
}
public struct DistillationSNR: Sendable, Equatable {
    public let snr: Float32
    public let structuralSignal: Float32  // Σ df(f) for features with df ≥ τ
    public let episodicNoise: Float32     // Σ df(f) for features below threshold
    public let readyToDistill: Bool       // snr ≥ 2.0
}
public struct FeatureGraph: Sendable {
    public let nodes: [ExtractedFeature]
    public let pmiMatrix: [[Float32]]     // symmetric; diagonal 0; -∞ when joint = 0
    public let components: [[Int]]        // connected components, sorted by total weighted df desc
}
public enum DistillationScorer {
    public static func structuralThreshold(M: Int) -> Float32   // 2 / M
    public static func applyStructuralThreshold(features: [ExtractedFeature], M: Int)
        -> (passing: [ExtractedFeature], failing: [ExtractedFeature])
    public static func computeSNR(features: [ExtractedFeature], M: Int) -> DistillationSNR
    public static func computeStructuralScores(features: inout [ExtractedFeature])
    public static func buildPMIGraph(thresholdFeatures: [ExtractedFeature],
                                     incidenceMatrix: [[Bool]], M: Int) -> FeatureGraph
    public static func selectDominantComponent(graph: FeatureGraph) -> [ExtractedFeature]
    public static func computeConfidence(selected: [ExtractedFeature],
                                         allThreshold: [ExtractedFeature]) -> Float32
}
```

```rust
// substrate_ml::distillation_scorer
pub struct ExtractedFeature {
    pub feature_type: DistillationFeatureType,
    pub value: String,
    pub display: String,
    pub doc_frequency: f32,
    pub weighted_doc_frequency: f32,
    pub structural_score: f32,
}
impl ExtractedFeature {
    pub fn new(feature_type: DistillationFeatureType, value: impl Into<String>,
               doc_frequency: f32) -> Self;
    pub fn new_with_display(feature_type: DistillationFeatureType, value: impl Into<String>,
                            display: impl Into<String>, doc_frequency: f32) -> Self;
}
pub struct DistillationSNR { pub snr: f32, pub structural_signal: f32,
                             pub episodic_noise: f32, pub ready_to_distill: bool }
pub struct FeatureGraph { pub nodes: Vec<ExtractedFeature>,
                          pub pmi_matrix: Vec<Vec<f32>>, pub components: Vec<Vec<usize>> }
pub struct DistillationScorer;
impl DistillationScorer {
    pub fn structural_threshold(m: usize) -> f32;
    pub fn apply_structural_threshold(features: &[ExtractedFeature], m: usize)
        -> (Vec<ExtractedFeature>, Vec<ExtractedFeature>);
    pub fn compute_snr(features: &[ExtractedFeature], m: usize) -> DistillationSNR;
    pub fn compute_structural_scores(features: &mut Vec<ExtractedFeature>);
    pub fn build_pmi_graph(threshold_features: &[ExtractedFeature],
                           incidence_matrix: &[Vec<bool>], m: usize) -> FeatureGraph;
    pub fn select_dominant_component(graph: &FeatureGraph) -> Vec<ExtractedFeature>;
    pub fn compute_confidence(selected: &[ExtractedFeature],
                              all_threshold: &[ExtractedFeature]) -> f32;
}
```

### `DistillationInput`, `DistillationOutput`, `DistilledHeader`, `DistillationPipeline`

SPEC § 5.24.

Five-stage cold-path distillation pipeline. Per DISTILLATION_MATH_SSA.md §1–7
and DISTILLATION_MATH_DIFFUSION.md §1–8. Feature extraction is injected via the
`FeatureExtractor` typealias so callers (NeuronKit) supply the EideticLib HMM
tagger or a test stub. `DistilledHeader.parse` is co-located with the pipeline
because the code that writes the format owns the parser.

**Swift/Rust timestamp difference:** `DistillationInput.memoryTimestamps` is
`[Date]?` in Swift; Rust uses `Option<Vec<f64>>` (epoch seconds). Semantics
are identical; the port adapts at the boundary.

```swift
public struct DistillationInput: Sendable {
    public let memoryContents: [String]
    public let memoryTimestamps: [Date]?
    public let clusterID: String
    public let sourceIDs: [String]
    public var M: Int { get }   // memoryContents.count
    public init(memoryContents: [String], memoryTimestamps: [Date]? = nil,
                clusterID: String, sourceIDs: [String])
}
public struct DistillationOutput: Sendable {
    public let drawerContent: String    // "[DIST|conf=X.XX|src=N|snr=Y.YY|delta=Z] prose"
    public let confidence: Float32      // conf(F*) ∈ [0, 1]
    public let uncertain: Bool          // conf ∈ [0.4, 0.7)
    public let snr: Float32
    public let deltaType: DeltaType?    // non-nil when a delta feature was dominant
    public let succeeded: Bool          // conf ≥ 0.4 and SNR gate passed
    public let failureReason: String?
    public let featureFingerprint: Fingerprint256  // OR-reduce of featureHash(f.value)
}
public struct DistilledHeader: Sendable, Equatable {
    public let prose: String
    public let confidence: Float32
    public let sourceCount: Int
    public let snr: Float32
    public let deltaType: DeltaType?
    public let uncertain: Bool
    // Returns nil if content does not start with "[DIST|".
    public static func parse(_ content: String) -> DistilledHeader?
}
public enum DistillationPipeline {
    public typealias FeatureExtractor =
        @Sendable (String, DistillationFeatureType) -> [ExtractedFeature]
    // "DISTILLA" encoded as ASCII big-endian UInt64. Changing this invalidates all stored fingerprints.
    public static let featureSimHashSeed: UInt64  // 0x44495354494C4C41
    public static func featureHash(_ value: String) -> Fingerprint256
    public static func queryFingerprint(query: String,
                                        extractFeatures: FeatureExtractor) -> Fingerprint256
    public static let defaultExtractor: FeatureExtractor   // capitalization-heuristic stub
    public static func run(input: DistillationInput,
                           extractFeatures: FeatureExtractor,
                           intraItem: Bool = false) -> DistillationOutput
}
```

```rust
// substrate_ml::distillation_pipeline
// FeatureExtractor is a fn pointer in Rust (not a closure/Fn trait).
pub type FeatureExtractor = fn(&str, DistillationFeatureType) -> Vec<ExtractedFeature>;
pub struct DistillationInput {
    pub memory_contents: Vec<String>,
    pub memory_timestamps: Option<Vec<f64>>,   // epoch seconds; Swift uses [Date]?
    pub cluster_id: String,
    pub source_ids: Vec<String>,
}
impl DistillationInput {
    pub fn new(memory_contents: Vec<String>, memory_timestamps: Option<Vec<f64>>,
               cluster_id: String, source_ids: Vec<String>) -> Self;
    pub fn m(&self) -> usize;
}
pub struct DistillationOutput {
    pub drawer_content: String,
    pub confidence: f32,
    pub uncertain: bool,
    pub snr: f32,
    pub delta_type: Option<DeltaType>,
    pub succeeded: bool,
    pub failure_reason: Option<String>,
    pub feature_fingerprint: Fingerprint256,
}
pub struct DistilledHeader {
    pub prose: String, pub confidence: f32, pub source_count: usize,
    pub snr: f32, pub delta_type: Option<DeltaType>, pub uncertain: bool,
}
impl DistilledHeader { pub fn parse(content: &str) -> Option<DistilledHeader>; }
pub struct DistillationPipeline;
impl DistillationPipeline {
    pub const FEATURE_SIM_HASH_SEED: u64;  // 0x44495354494C4C41
    pub fn feature_hash(value: &str) -> Fingerprint256;
    pub fn query_fingerprint(query: &str, extract_features: FeatureExtractor) -> Fingerprint256;
    pub fn default_extractor(text: &str, feature_type: DistillationFeatureType) -> Vec<ExtractedFeature>;
    pub fn run(input: &DistillationInput, extract_features: FeatureExtractor,
               intra_item: bool) -> DistillationOutput;
}
```

### `ConflictCueKind`, `ConflictCueResult`, `ConflictCue`

SPEC § 5.25.

Deterministic pairwise text-conflict screen backed by `ShingleSimilarity`
(already conformance-gated to f32 bit-identity). Three cues checked
strongest-first: `valueDivergence` (same token template, digit-bearing
positions differ), `negationAsymmetry` (negation cue on exactly one side over
substantially similar content), `markerRevision` (revision/supersession marker
over substantially similar content). Results are bit-identical across ports.

**Rust note:** `ConflictCue` is not a named Rust type — `evaluate` is a free
function in the `conflict_cue` module (same pattern as `FloatSimHash`,
`FFT`, and other namespace-enum → free-fn mappings).

```swift
public enum ConflictCueKind: String, Sendable, Equatable {
    case valueDivergence   = "value_divergence"
    case negationAsymmetry = "negation_asymmetry"
    case markerRevision    = "marker_revision"
    case none              = "none"
}
public struct ConflictCueResult: Sendable, Equatable {
    public let kind: ConflictCueKind
    public let score: Float   // confidence in [0, 1]; always 0 when kind == .none
    public init(kind: ConflictCueKind, score: Float)
}
public enum ConflictCue {
    public static let strongThreshold: Float      // 0.70 — auto-propose contradicts tunnel
    public static let borderlineThreshold: Float  // 0.45 — surface for BYOAI adjudication
    public static func evaluate(_ a: String, _ b: String) -> ConflictCueResult
}
```

```rust
// substrate_ml::conflict_cue
pub enum ConflictCueKind { ValueDivergence, NegationAsymmetry, MarkerRevision, None }
impl ConflictCueKind { pub fn as_str(&self) -> &'static str; }
pub struct ConflictCueResult { pub kind: ConflictCueKind, pub score: f32 }
pub const STRONG_THRESHOLD: f32;      // 0.70
pub const BORDERLINE_THRESHOLD: f32;  // 0.45
// No ConflictCue type in Rust — free function at module level.
pub fn evaluate(a: &str, b: &str) -> ConflictCueResult;
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
| `FFT.forward` / `RhythmAnalysis.analyze` precondition | non-power-of-two signal length (or non-positive bucket duration) |
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
  - `JacobiSVDTests.swift`
  - `TypedDecayWeightingTests.swift`
  - `DeltaFeatureExtractorTests.swift`
  - `DistillationScorerTests.swift`
  - `DistillationPipelineTests.swift`
  - `DistillationConformanceTests.swift`
  - `ConflictCueTests.swift`
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

// Project a row's state as of a specific HLC (events passed in any order).
let projection = AuditLogFold.projectStateAt(
    rowId: someRowId, nounType: .drawer, events: events, asOf: someHLC)

// Decay a matrix in place using the field-presence half-life.
var decaying = DecayingMatrix(rows: 36, cols: 6, /* … */)
MatrixDecay.apply(to: &decaying /*, asOf: now */)

// Train a Bradley-Terry estimator on preference observations.
var bt = BradleyTerryEstimator(learningRate: 0.05, l2: 0.001)
for obs in observations { bt.observe(obs) }
let s = bt.strength(of: someRowID)

// Build a tier-contribution wire record for federation.
let contrib = TierContributionFingerprint.build(
    estateUUID: myEstate, case: .household /*, … */)
```

```rust
use substrate_types::*;
use substrate_ml::{AuditLogFold, MatrixDecay, bradley_terry::BradleyTerryEstimator,
                   TierContributionFingerprint};

let projection = AuditLogFold::project_state_at(row_id, NounType::Drawer, &events, as_of);

let mut bt = BradleyTerryEstimator::new(0.05, 0.001);
for obs in &observations { bt.observe(obs); }
let s = bt.strength(some_row_id);

let contrib = TierContributionFingerprint::build(my_estate, FederationCase::Household /*, … */);
```

## § 7 — Swift/Rust Concordance

This section enumerates the COMPLETE top-level public surface of SubstrateML
in both ports, one row per public concept. Every row is anchored to the
conformance test that proves the two ports agree.

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
| Shingle-similarity namespace | `ShingleSimilarity` (enum) | `shingle_similarity` (pub mod free fns) | public | Swift enum namespace / Rust free fns; identical f32 Jaccard (conformance CRC `0x8a5d8888`) | `ShingleSimilarityTests.swift` / `rust:shingle_similarity::tests` | Confirmed |
| Complex number | `Complex` | `Complex` | public | identical | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| FFT namespace | `FFT` (enum) | — (`fft::forward`/`inverse` free fns) | public | Swift enum namespace / Rust free fn (no type) | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| Rhythm result | `RhythmResult` | `RhythmResult` | public | identical | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| Rhythm-analysis namespace | `RhythmAnalysis` (enum) | — (`fft::analyze` free fn) | public | Swift enum namespace / Rust free fn (no type) | `FFTTests.swift` / `rust:fft::tests` | Confirmed |
| Eigenvalue centrality namespace | `EigenvalueCentrality` (enum) | `EigenvalueCentrality` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `EigenvalueCentralityTests.swift`, `EigenvalueCentralityDirectedTests.swift` / `rust:eigenvalue_centrality::tests` | Confirmed |
| SplitMix64 RNG | `SplitMix64` | `SplitMix64` | public | identical (deterministic seed) | `RandomWalksTests.swift` / `rust:random_walks::tests` | Confirmed |
| Random-walks namespace | `RandomWalks` (enum) | `RandomWalks` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; Swift precondition / Rust panic | `RandomWalksTests.swift`, `RandomWalksDomainTests.swift` / `rust:random_walks::tests` | Confirmed |
| RowId walk (restart) | `RandomWalks.walkWithRestart(seed:steps:restartProbability:rngSeed:adjacency:)` → `[RowId:Int]` | `RandomWalks::walk_with_restart(seed, steps, restart_probability, rng_seed, adjacency)` → `HashMap<RowId,u64>` | public both | Swift `[RowId:[RowId]]` adjacency / Rust `&HashMap<RowId,Vec<RowId>>`; same SplitMix64 PRNG; visit counts: Swift `Int` / Rust `u64`; RNG seed derived by caller via FNV hash64 | `RandomWalksDomainTests.swift` (WR-1..5) / `rust:random_walks::tests` (WR-1..5) | Confirmed |
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
| Float SimHash namespace | `FloatSimHash` (enum) | — (`float_simhash::project` free fn) | public | Swift enum namespace / Rust free fn (no type) | `FloatSimHashTests.swift` / `rust:float_simhash::tests` | Confirmed |
| Row-lite summary | `RowLite` | `RowLite` | public | identical | `MomentSummaryTests.swift` / `rust:moment_summary::tests` | Confirmed |
| Moment-summary namespace | `MomentSummary` (enum) | `MomentSummary` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `MomentSummaryTests.swift` / `rust:moment_summary::tests` | Confirmed |
| Partial-state recall namespace | `PartialStateRecall` (enum) | `PartialStateRecall` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `PartialStateRecallTests.swift`, `PartialStateRecallValidationTests.swift` / `rust:partial_state_recall::tests` | Confirmed |
| Pairing nonce | `PairingNonce` | `PairingNonce` | public | identical | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Pairing record | `PairingRecord` | `PairingRecord` | public | identical | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Pairing-handshake namespace | `PairingHandshake` (enum) | `PairingHandshake` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Pairing audit payload | `PairingAuditPayload` (top-level) | `PairingAuditPayload` (flat) | public | Both top-level. `peerEstate: UUID` (Swift) / `peer_estate: [u8; 16]` (Rust) — byte-equivalent. | `PairingHandshakeTests.swift` / `rust:pairing::tests` | Confirmed |
| Federation case | `FederationCase` (enum: UInt32) | `FederationCase` (enum) | public | identical — `household`/`fleet`/`industry` = 1/2/3 in both ports | `TierContributionFingerprintTests.swift` / `rust:tier_contribution::tests` | Confirmed |
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
| Temporal-causality fold result | `FoldResult` (named struct) | `FoldResult` (flat struct) | public | Both named structs. Fields: `deltas: [(TemporalCausalityKey, Int64)]` / `Vec<(TemporalCausalityKey, i64)>` and `newWatermark: HLC` / `new_watermark: HLC`. | `TemporalCausalityFoldTests.swift` / `rust:temporal_causality_fold::tests` | Confirmed |
| NMF-DF² factorization | `NMFDoubleFrobeniusSquaredFactorization` (struct) | `NMFDoubleFrobeniusSquaredFactorization` (struct) | public | identical — `w: [[Double]]` / `Vec<Vec<f64>>`, `h: [[Double]]` / `Vec<Vec<f64>>`, `reconstructionError: Double` / `reconstruction_error: f64` (raw Frobenius², NOT RMS); production-gated (SubstrateML exposes the type; caller decides enablement) | `NMFDoubleFrobeniusSquaredTests.swift` / `rust:nmf_double_frobenius_squared::tests` | Confirmed |
| NMF-DF² namespace | `NMFDoubleFrobeniusSquared` (enum) | `NMFDoubleFrobeniusSquared` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; delegates to canonical f32 NMF internally | `NMFDoubleFrobeniusSquaredTests.swift` / `rust:nmf_double_frobenius_squared::tests` | Confirmed |
| Sampling namespace | `Sampling` (enum) | `sampling` (pub mod, no type) | public | Swift caseless `enum` groups static fns; Rust `pub mod sampling` exposes free fns. No Rust type named `Sampling` — a Swift namespace enum without a Rust type mirror (see § 7.2). | `SamplingTests.swift` / `rust:sampling (inline tests)` | Confirmed |
| VizGraph signal names | `VizGraphSignals` (enum-of-statics) | `VizGraphSignals` (`pub mod` consts) | public | Swift caseless enum of `static let` metric-name strings / Rust `pub mod` of `pub const` strings — same five names (`community.assignment`, `centrality.score`, `nmf.factor`, `anomaly.flag`, `edge.decayed_weight`) | `VizGraphSignalsTests.swift` / `rust:viz_graph_signals_tests` | Confirmed |
| SVD result | `SVDResult` | `SvdResult` | public | Swift `U/Vt` (CamelCase) / Rust `u/vt` (snake_case); `[[Float]]`/`Vec<Vec<f32>>`, `[Float]`/`Vec<f32>`; identical field semantics | `JacobiSVDTests.swift` / `rust:svd::tests` | Confirmed |
| Jacobi SVD namespace | `JacobiSVD` (enum) | `JacobiSvd` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; `decompose` + `tournamentRounds` in both; Swift precondition / Rust panic; `sweeps` default 30 pinned in both | `JacobiSVDTests.swift` / `rust:svd::tests` | Confirmed |
| Distillation feature type | `DistillationFeatureType` (enum: String) | `DistillationFeatureType` (enum) | public | Identical cases (`entity/relation/temporal/numerical`); raw String values in Swift (`ENT`/`REL`/`TMP`/`NUM`); `decay_lambda()` method in both | `TypedDecayWeightingTests.swift` / `rust:typed_decay_weighting::tests` | Confirmed |
| Typed decay weighting namespace | `TypedDecayWeighting` (enum) | `TypedDecayWeighting` (unit struct) | public | Swift `[Date]` timestamps / Rust `&[f64]` epoch seconds (semantic equivalent); `weight` and `weightedDocFrequency`/`weighted_doc_frequency` in both | `TypedDecayWeightingTests.swift` / `rust:typed_decay_weighting::tests` | Confirmed |
| Delta type | `DeltaType` (enum: String) | `DeltaType` (enum) | public | Identical cases; raw String values (`STATIC`/`CONVERGENT`/`MONOTONE`/`OSCILLATING`/`DIVERGENT`) in Swift | `DeltaFeatureExtractorTests.swift` / `rust:delta_feature_extractor::tests` | Confirmed |
| Delta analysis | `DeltaAnalysis` | `DeltaAnalysis` | public | Identical fields (snake_case Rust); sequence timestamps `Date` (Swift) vs `f64` epoch seconds (Rust) — boundary adaptation | `DeltaFeatureExtractorTests.swift` / `rust:delta_feature_extractor::tests` | Confirmed |
| Delta feature extractor namespace | `DeltaFeatureExtractor` (enum) | `DeltaFeatureExtractor` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; `analyzeCategorical`/`analyzeNumerical` in both; `Date` vs `f64` timestamp boundary (see § 7.2) | `DeltaFeatureExtractorTests.swift` / `rust:delta_feature_extractor::tests` | Confirmed |
| Extracted feature | `ExtractedFeature` | `ExtractedFeature` | public | Identical fields (Swift `type: DistillationFeatureType` / Rust `feature_type`); `display` defaults to `value` | `DistillationScorerTests.swift` / `rust:distillation_scorer::tests` | Confirmed |
| Distillation SNR | `DistillationSNR` | `DistillationSNR` | public | Identical fields (snake_case Rust); `readyToDistill`/`ready_to_distill` (snr ≥ 2.0) | `DistillationScorerTests.swift` / `rust:distillation_scorer::tests` | Confirmed |
| Feature graph | `FeatureGraph` | `FeatureGraph` | public | Identical fields; `components: [[Int]]` / `Vec<Vec<usize>>` sorted by total weighted df desc | `DistillationScorerTests.swift` / `rust:distillation_scorer::tests` | Confirmed |
| Distillation scorer namespace | `DistillationScorer` (enum) | `DistillationScorer` (unit struct) | public | Swift enum namespace / Rust unit-struct namespace; all seven public methods present in both | `DistillationScorerTests.swift` / `rust:distillation_scorer::tests` | Confirmed |
| Distillation input | `DistillationInput` | `DistillationInput` | public | `memoryTimestamps: [Date]?` (Swift) / `memory_timestamps: Option<Vec<f64>>` (Rust) epoch seconds — semantically equivalent; all other fields identical | `DistillationPipelineTests.swift` / `rust:distillation_pipeline::tests` | Confirmed |
| Distillation output | `DistillationOutput` | `DistillationOutput` | public | Identical fields (snake_case Rust); `featureFingerprint`/`feature_fingerprint: Fingerprint256` | `DistillationPipelineTests.swift` / `rust:distillation_pipeline::tests` | Confirmed |
| Distilled header | `DistilledHeader` | `DistilledHeader` | public | Identical fields; `parse`/`parse` static method returns `Optional`/`Option` | `DistillationConformanceTests.swift` / `rust:distillation_pipeline::tests` | Confirmed |
| Distillation pipeline namespace | `DistillationPipeline` (enum) | `DistillationPipeline` (unit struct) | public | Swift `FeatureExtractor` is `@Sendable` closure / Rust `FeatureExtractor` is fn pointer (see § 7.2); `featureSimHashSeed`/`FEATURE_SIM_HASH_SEED` identical; `run` in both | `DistillationPipelineTests.swift`, `DistillationConformanceTests.swift` / `rust:distillation_pipeline::tests` | Confirmed |
| Conflict cue kind | `ConflictCueKind` (enum: String) | `ConflictCueKind` (enum) | public | Identical cases; `as_str()` method in Rust (Swift uses `rawValue`) | `ConflictCueTests.swift` / `rust:conflict_cue::tests` | Confirmed |
| Conflict cue result | `ConflictCueResult` | `ConflictCueResult` | public | Identical fields | `ConflictCueTests.swift` / `rust:conflict_cue::tests` | Confirmed |
| Conflict cue namespace | `ConflictCue` (enum) | — (free fns in `conflict_cue` mod) | public | Swift enum namespace / Rust free fn; `strongThreshold`/`STRONG_THRESHOLD` = 0.70, `borderlineThreshold`/`BORDERLINE_THRESHOLD` = 0.45; bit-identical `evaluate` results | `ConflictCueTests.swift` / `rust:conflict_cue::tests` | Confirmed |

### § 7.2 — Notes on apparent asymmetries (verified non-drift)

- **Swift namespace enums with no Rust type** (`MatrixDecay`, `FFT`,
  `RhythmAnalysis`, `FloatSimHash`, `AprioriMining`):
  Swift groups the static functions under an empty `enum`; Rust exposes the
  same calls as module-level `pub fn`s (and `DecayHalfLives` as a `pub mod`
  of constants). No Rust top-level *type* is created. Behavior is bound by
  the shared conformance suites cited above — not drift. (The five
  ambient-source extractors are concrete structs in both ports — there is
  no `FeatureExtractors` Interface type.)
- **Rust unit-struct namespaces** (`AuditLogFold`, `NMFAlternatingLeastSquares`,
  `EigenvalueCentrality`, `RandomWalks`, `UDCTreeDistance`, `LatticeDistance`,
  `WikidataGraphDistance`, `CompositeDistance`, `MomentSummary`,
  `PartialStateRecall`, `PairingHandshake`, `TierContributionFingerprint`,
  `TierAscendingQueryProtocol`, `DPORReduction`, `InformationTheory`,
  `TemporalCompression`, `AnomalyDetection`, `CommunityDetection`,
  `StabilityEstimator`, `TemporalCausalityFold`): Rust names the namespace as
  `pub struct X;` with an `impl X`; Swift uses `enum X`. Same call surface.
- **Metric-name namespace as PascalCase `pub mod`** (`VizGraphSignals`):
  the VizGraph telemetry metric names ship as a Swift caseless `enum` of
  `static let` strings and a Rust `pub mod VizGraphSignals` of `pub const`
  strings. The Rust module is deliberately PascalCase (not the usual
  snake_case) so call sites read `VizGraphSignals::COMMUNITY_ASSIGNMENT`,
  mirroring Swift `VizGraphSignals.communityAssignment`. Same five names,
  same string values — a namespace-as-type concept, not drift. (This is the
  one PascalCase `pub mod` in the tree; the lowercase `decay::half_lives`
  above is the ordinary-module variant paired with Swift `DecayHalfLives`.)
- **`FoldResult`** is `public struct FoldResult` in both Swift and Rust —
  both named, both flat, same field set.
- **`PairingAuditPayload`** is top-level in both Swift and Rust.
  `peerEstate: UUID` (Swift) vs `peer_estate: [u8; 16]` (Rust) are
  byte-equivalent (UUID is 16-byte big-endian).
- **`RowId`** (FCA-local, `formal_concept_analysis.rs`): flat Rust `pub type RowId = u32`
  vs nested Swift `FormalContext.RowID = UInt32`. This is a scoping choice:
  Rust module-scoping already isolates the FCA-local index, while Swift must
  nest to avoid collision with LocusKit's module-level `RowID = String`. This
  is a scoping convention, not contract drift.
- **No platform-bound types** exist in SubstrateML. The package is pure
  cold-path math/CRDT with no Metal/BNNS/CoreML/CloudKit/Keychain surface;
  every concept has a real counterpart in both ports.
- **`ConflictCue` (Swift namespace enum) has no Rust named type.** `evaluate`
  is a free function at `conflict_cue` module level; the threshold constants
  are module-level `pub const`. This is the same pattern as `FloatSimHash`,
  `FFT`, `RhythmAnalysis`, and `AprioriMining`.
- **Timestamp types in distillation and delta-feature types:** Swift uses
  `Date` for `DistillationInput.memoryTimestamps`, `DeltaFeatureExtractor`
  sequence timestamps, and `TypedDecayWeighting.weightedDocFrequency`. The
  Rust ports use `f64` epoch seconds at those boundaries. Semantics are
  identical; the boundary adapter converts at the kit interface.
- **`DistillationPipeline.FeatureExtractor`** is `@Sendable (String,
  DistillationFeatureType) -> [ExtractedFeature]` in Swift (a closure type);
  in Rust it is `pub type FeatureExtractor = fn(&str, DistillationFeatureType)
  -> Vec<ExtractedFeature>` (a plain fn pointer). Behavior is equivalent for
  stateless extractors (the only kind the pipeline uses).
- **`SVDResult` / `SvdResult`** naming: Rust uses all-lowercase `u`, `vt`,
  `singular_values` while Swift uses `U`, `Vt`, `singularValues`. Both carry
  row-major `Float`/`f32` nested arrays for the singular-vector matrices.

### § 7.3 — Cross-module type bindings

The following types are 1:1 across ports; Rust idioms differ (snake_case,
`Vec` for Swift arrays, `u128` for Swift `UUID`, `Option` for Swift
optionals).

#### Audit-projection types

| Swift | Rust module | Rust type/fn | Notes |
|---|---|---|---|
| `RowAuditValue` | `row_attribute_view` | `pub enum RowAuditValue` | `Bitmap(u64)`, `Integer(i64)`, `Null` |
| `RowAuditEntry` | `row_attribute_view` | `pub struct RowAuditEntry` | `row_id: u128` mirrors Swift `UUID`; `hlc: HLC` from `substrate_types` |
| `RowAttributeView` | `row_attribute_view` | `pub struct RowAttributeView` | `attributes: Vec<(u8, u8)>` sorted ascending |
| `RowAttributeView.from(auditEntries:)` | `row_attribute_view` | `RowAttributeView::from(audit_entries: &[RowAuditEntry])` | Same algorithm: vocab cap 64, latest-HLC dedup, sorted output by (tier, row_id UUID string) |

#### Recall vocabulary

`tier_query.rs` uses the canonical recall vocabulary from `substrate_types`,
which mirrors the Swift vocabulary in `SubstrateTypes/RecallTypes.swift`.

| Swift (SubstrateTypes) | Rust (`substrate_types`) | Notes |
|---|---|---|
| `RecallScore` | `RecallScore` | `row_id: RowId` (newtype `u128`), `score: f32` |
| `RecallResult` | `RecallResult` | `rows`, `breakdown: DistanceBreakdown`, `confidence_interval: Option<(f32,f32)>`, `primitive_name` |
| `DistanceBreakdown` | `DistanceBreakdown` | Four `f32` contributions; `ZERO` constant |
| `RowProjection` | `RowProjection` | `row_id`, `capture_hlc`, `fingerprint`, `lattice`, `bitmaps: (u64,u64,u64)`, `row_state: u8` |

`TierAscendingQuery`, `PeerResponse`, `TierAscendingQueryProtocol`, and
`PrivacyLedger` in `tier_query.rs` use `RecallResult` and `RecallScore`
from `substrate_types` throughout.

#### HLC

`temporal_causality_fold.rs` uses the canonical `substrate_types::HLC`
across module boundaries. The canonical `HLC` fields are
`physical_time: i64`, `logical_count: i32`, `node_id: i32`.

## § 8 — VizGraph telemetry interface

SPEC § 8.

### `VizGraphSignals` (new)

Canonical metric name constants for the five VizGraph telemetry signals.
Both ports define the same string constants; use these at every call site
to prevent typos from producing orphaned metrics.

```swift
// VizGraphSignals.swift
public enum VizGraphSignals {
    public static let communityAssignment: String  // "community.assignment"
    public static let centralityScore: String       // "centrality.score"
    public static let nmfFactor: String             // "nmf.factor"
    public static let anomalyFlag: String           // "anomaly.flag"
    public static let edgeDecayedWeight: String     // "edge.decayed_weight"
}
```

```rust
// viz_graph_signals.rs
pub mod VizGraphSignals {
    pub const COMMUNITY_ASSIGNMENT: &str;   // "community.assignment"
    pub const CENTRALITY_SCORE: &str;       // "centrality.score"
    pub const NMF_FACTOR: &str;             // "nmf.factor"
    pub const ANOMALY_FLAG: &str;           // "anomaly.flag"
    pub const EDGE_DECAYED_WEIGHT: &str;    // "edge.decayed_weight"
}
```

### Updated algorithm signatures

The following algorithms gained two optional/trailing parameters for
VizGraph telemetry. The `estate` and `ts` parameters are forwarded
directly to the IntellectusLib emit; they do not alter the algorithm's
computation.

**Swift** — all parameters have default values (`estate: String = ""`,
`ts: Double = 0`), so existing callers require no changes.

**Rust** — parameters are positional (`estate: &str`, `ts: f64`).
Internal callers were updated to pass `"", 0.0`.

| Algorithm | New Swift parameters | New Rust parameters |
|---|---|---|
| `CommunityDetection.detect` | `estate: String = ""`, `ts: Double = 0` | `estate: &str`, `ts: f64` |
| `EigenvalueCentrality.compute` | `estate: String = ""`, `ts: Double = 0` | `estate: &str`, `ts: f64` |
| `NMFAlternatingLeastSquares.factorize` | `estate: String = ""`, `ts: Double = 0` | `estate: &str`, `ts: f64` |
| `AnomalyDetection.rollingZScore` | `estate: String = ""`, `ts: Double = 0` | `estate: &str`, `ts: f64` |
| `AnomalyDetection.rollingModifiedZScore` | `estate: String = ""`, `ts: Double = 0` | `estate: &str`, `ts: f64` |
| `MatrixDecay.apply(to:nowSeconds:)` | `estate: String = ""`, `ts: Double = 0` | `estate: &str`, `ts: f64` |

### Dependency change

`Package.swift` — `IntellectusLib` added to SubstrateML target and test
target dependencies (authority: `the package-dependency rule`).

`Cargo.toml` — `intellectus-lib = { path = "../../IntellectusLib/rust" }` added.

## Changelog

### 1.2.0 -- 2026-08-06

- `ShingleSimilarity.similarity(_:_:)` gains a `Set<String>` overload
  (Rust: `similarity_sets`); the string overload delegates to it.

### 1.1.2 -- 2026-07-16
Additive (audit): closed two CRITICAL gaps left after the 1.1.1 pass.
(1) `AnomalyDetection`: expanded the placeholder `{ /* … */ }` stub to all five
public methods (`zScore`, `rollingZScore`, `modifiedZScore`, `rollingModifiedZScore`,
`isAnomalous`) in both Swift and Rust; updated SPEC cross-reference to § 5.26.
(2) `TemporalCausalityFold`: added the three public constants
(`lagBuckets`/`defaultWindowMinutes`/`maxWindowOccupancy` in Swift;
`LAG_BUCKETS`/`DEFAULT_WINDOW_MINUTES` as associated consts + `MAX_WINDOW_OCCUPANCY`
as module-level pub const in Rust) to the existing signature block.

### 1.1.1 -- 2026-07-16
Additive (audit): documented six previously-undocumented Swift source files and
their Rust counterparts, all present in the shipped package but missing from the
interface doc. Updated file count (29 → 39) and purpose paragraph. Added § 2
sections for: `SVDResult`/`JacobiSVD` (Jacobi SVD for LSA);
`DistillationFeatureType`/`TypedDecayWeighting` (Ds2 type-specific decay);
`DeltaType`/`DeltaAnalysis`/`DeltaFeatureExtractor` (Ds1 Stage 2.5 trajectory
analysis); `ExtractedFeature`/`DistillationSNR`/`FeatureGraph`/`DistillationScorer`
(Ds3 scoring); `DistillationInput`/`DistillationOutput`/`DistilledHeader`/
`DistillationPipeline` (Ds4 five-stage pipeline); `ConflictCueKind`/
`ConflictCueResult`/`ConflictCue` (pairwise text-conflict screen). Added 21
concordance rows to § 7.1, three asymmetry notes to § 7.2, and 8 test file
references to § 5.

### 1.1.0 -- 2026-06-17
Additive (A-2 exploratory-recall): added `RandomWalks.walkWithRestart` in both ports —
a RowId-space walk (A-2, cookbook § 19.1) consumed by CognitionKit's
`recall_exploratory` recipe. Swift signature: `walkWithRestart(seed:steps:restartProbability:rngSeed:adjacency:) -> [RowId:Int]`
(adjacency `[RowId:[RowId]]`, visit counts `Int`). Rust signature:
`walk_with_restart(seed, steps, restart_probability, rng_seed, adjacency) -> HashMap<RowId,u64>`
(adjacency `HashMap<RowId,Vec<RowId>>`, visit counts `u64`). Both use the same
SplitMix64 PRNG and restart logic; the PRNG seed is derived by the caller via FNV
hash64. Updated the signature block for `RandomWalks` in the API section and added
a concordance row. The existing indexed `walk(adjacency:start:length:...)` is unchanged.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
