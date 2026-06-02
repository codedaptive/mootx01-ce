---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-06-01
version: v0.85
supersedes: NEURONKIT_INTERFACE_v0.8.md
package: NeuronKit
languages: [swift, rust]
relates_to:
  - NEURONKIT_SPEC_v0.85.md  (the contract this interface implements)
purpose: |
  Public API surface of NeuronKit in both ports: the lattice-anchor
  inference path, the hybrid-recall + MMR reasoning surface, context
  synthesis, branch operations, the migration benchmark, tournament
  ranking, the Bradley-Terry batch MLE fitter, the dreaming and
  maintenance autonomic daemons with their seam protocols, and the
  reasoning-lens surface — the structural, topic, preference, and
  prediction lenses that shape the gated SubstrateML / GeniusLocusKit
  math primitives into substrate-shaped reasoning results. The
  companion SPEC carries the behavioral contracts (invariants I-1…I-18,
  behaviors B-1…B-8, conformance C-1…C-18).
---

# NeuronKit Interface

> **Supersedes NEURONKIT_INTERFACE_v0.8.** v0.85 carries the entire v0.8
> surface forward unchanged and **adds the reasoning-lens surface** —
> nine result types (§ 2) and eight lens functions (§ 3) — promoted from
> the Rust-only cluster to first-class bilingual design (SPEC § 7, § 8;
> C-18). The lens functions are specified Swift-first: the Swift leg is
> currently absent and is authored to these signatures, then the Rust
> leg (already present but "poorly implemented") is corrected to match.

## § 1 — Package layout

**Swift:** `packages/kits/NeuronKit/`

- `Sources/NeuronKit/NeuronKit.swift` — the `NeuronKit` namespace,
  `inferLatticeAnchor`, the `dreamingDaemon` facade, `LinguisticPipelineMode`
- `Sources/NeuronKit/LatticeAnchorInference.swift` — `LatticeAnchorInference`,
  `AnchorConfidence`, `EnrichmentStatus`
- `Sources/NeuronKit/HybridRecall.swift` — `hybridRecall`,
  `RecallFrameTuning`, `RecallStream` (+ `Page`), `Drawer` typealias
- `Sources/NeuronKit/MMRRank.swift` — standalone Engram-distance `mmrRank`
- `Sources/NeuronKit/ContextSynthesizer.swift` — `ContextSynthesizer`,
  `ContextDocument`
- `Sources/NeuronKit/ScenarioProfile.swift` — `ScenarioProfile`
- `Sources/NeuronKit/BranchOps.swift` — `deriveBranch` / `promoteBranch` /
  `mergeDrawers`
- `Sources/NeuronKit/BenchmarkAlgorithm.swift` — `benchmark`, `BenchmarkReport`
- `Sources/NeuronKit/Tournament.swift` — `runTournament`, `TournamentReport`,
  `BranchScore`, `DisqualifiedBranch`, `DisqualificationReason`
- `Sources/NeuronKit/Tournament/BradleyTerry.swift` — `bradleyTerry`,
  `MOOTx01Error`
- `Sources/NeuronKit/Tournament/BradleyTerryScore.swift`,
  `Sources/NeuronKit/Tournament/PairwiseOutcome.swift`
- `Sources/NeuronKit/Lenses/Keystones.swift` — `keystones`, `Keystone`
- `Sources/NeuronKit/Lenses/Constellation.swift` — `constellations`,
  `Constellation`
- `Sources/NeuronKit/Lenses/SpreadingActivation.swift` —
  `spreadingActivation`, `Activation`
- `Sources/NeuronKit/Lenses/ThemeWeather.swift` — `themeWeather`,
  `recencyWeight`, `CategoryMomentum`
- `Sources/NeuronKit/Lenses/LatentThemes.swift` — `latentThemes`,
  `LatentThemes`, `ThemeLoading`
- `Sources/NeuronKit/Lenses/Bias.swift` — `representationBias`,
  `learnedPreference`, `CategoryBias`, `PreferenceStrength`
- `Sources/NeuronKit/Lenses/Anticipation.swift` — `anticipate`,
  `ActionObservation`, `ActionPrediction`
- `Sources/NeuronKit/Lenses/Drift.swift` — `drift`, `DriftScore`
- `Sources/NeuronKit/Lenses/AnomalyScan.swift` — `anomalies`, `Anomaly`
- `Sources/NeuronKit/Dreaming/` — `DreamingDaemon`, `DreamingPolicy`
  (+ `DreamingPolicyStore`, `InMemoryDreamingPolicyStore`),
  `DreamingTriggerMode`, `RewardSource` (+ `RewardSourceKind`,
  `RecallTraceRewardSource`), and the seam value types
- `Sources/NeuronKit/Maintenance/` — `MaintenanceDaemon`,
  `MaintenancePolicy` (+ store), and the seam value types
- `Tests/NeuronKitTests/`, `Package.swift`

**Rust:** `packages/kits/NeuronKit/rust/` (crate `neuron-kit`, lib
`neuron_kit`)

- `src/lib.rs` — `VERSION`, `linguistic_pipeline_mode`, `infer_lattice_anchor`
- `src/lattice_anchor.rs`, `src/hybrid_recall.rs`,
  `src/context_synthesizer.rs`, `src/scenario_profile.rs`,
  `src/tournament.rs`
- the reasoning lenses: `src/keystones.rs`, `src/constellation.rs`,
  `src/spreading_activation.rs`, `src/theme_weather.rs`,
  `src/latent_themes.rs`, `src/bias.rs`, `src/anticipation.rs`
- depends on `eidetic-lib`, `serde`, `serde_json`, and — for the gated
  lens math — `substrate-ml` (centrality, communities, random-walk,
  decay, action-outcome matrix, Bradley-Terry) and `genius-locus-kit`
  (the matrix-tier `MatrixNMF`). The Rust version still has **no**
  LocusKit / GeniusLocusKit estate-verb / EngramLib dependency, so the
  daemons, branch ops, benchmark, tournament orchestration, and the
  standalone Engram-distance `mmrRank` remain Swift-only; the lenses are
  pure math shapes and need only the gated primitives (SPEC I-17, I-18).

## § 2 — Public types

Behavioral contracts: SPEC § 4–§ 5, § 7.

### `NeuronKit` (module namespace)

The roll-up namespace. Carries the module version and the compile-time
linguistic-pipeline mode; reasoning and autonomic entry points hang off
it via extensions (§ 3).

**Swift:**

```swift
public enum NeuronKit {
    public static let version: String           // "0.1.0"
    public static var linguisticPipelineMode: LinguisticPipelineMode
}
```

**Rust:** (free items in `neuron_kit`, no namespace type)

```rust
pub const VERSION: &str;                              // "0.1.0"
pub const fn linguistic_pipeline_mode() -> LinguisticPipelineMode;
```

### `LinguisticPipelineMode`

The compile-time pipeline mode recorded in the estate manifest.

**Swift:**

```swift
public enum LinguisticPipelineMode: String, Sendable, Codable {
    case deterministicReference = "deterministic-reference"
    case appleNLAccel           = "apple-nl-accel"   // Apple NL acceleration; federation-disabled
}
```

**Rust:**

```rust
#[serde(rename_all = "kebab-case")]
pub enum LinguisticPipelineMode { DeterministicReference, AppleNlAccel }
// linguistic_pipeline_mode() always returns DeterministicReference in Rust.
```

### `LatticeAnchorInference`

The output of lattice-anchor inference: the FDC code, optional Wikidata
Q-ID, packed confidence, and the provenance enrichment-status bit
transition (cookbook § 2.5). Pure data; identical shape across ports.

**Swift:**

```swift
public struct LatticeAnchorInference: Equatable, Sendable, Codable {
    public let code: String                        // "" => the FDC encoder matched nothing
    public let wikidataQID: String?                // nil => qidPending
    public let confidence: UInt8                   // packed 6-bit field value
    public let enrichmentStatusBits: UInt8         // OR into provenance bits 36-41
    public let pipelineMode: LinguisticPipelineMode
    public init(code: String, wikidataQID: String?, confidence: UInt8,
                enrichmentStatusBits: UInt8, pipelineMode: LinguisticPipelineMode)
}

public enum AnchorConfidence: UInt8 { case null = 0, low = 16, medium = 32, high = 48, verified = 56 }
public enum EnrichmentStatus: UInt8 { case none = 0, qidPending = 1, qidCompleted = 2, closureCached = 3 }
```

**Rust:**

```rust
pub struct LatticeAnchorInference {
    pub code: String,
    pub wikidata_qid: Option<String>,
    pub confidence: u8,
    pub enrichment_status_bits: u8,
    pub pipeline_mode: LinguisticPipelineMode,
}
#[repr(u8)] pub enum AnchorConfidence { Null = 0, Low = 16, Medium = 32, High = 48, Verified = 56 }
#[repr(u8)] pub enum EnrichmentStatus { None = 0, QidPending = 1, QidCompleted = 2, ClosureCached = 3 }
// EnrichmentStatus::raw(self) -> u8 ; AnchorConfidence::raw(self) -> u8
```

### `RecallFrameTuning`

Hybrid-recall fusion / rerank / page-size knobs (SPEC § 5, B-6).

**Swift:**

```swift
public struct RecallFrameTuning: Sendable, Equatable {
    public let bm25Weight: Float    // 0.3
    public let vectorWeight: Float  // 0.7
    public let rrfK: Int            // 60
    public let mmrLambda: Float     // 0.7
    public let pageSize: Int        // 50
    public init(bm25Weight: Float = 0.3, vectorWeight: Float = 0.7,
                rrfK: Int = 60, mmrLambda: Float = 0.7, pageSize: Int = 50)
    public static let `default`: RecallFrameTuning
}
```

**Rust:**

```rust
pub struct RecallFrameTuning {
    pub bm25_weight: f32, pub vector_weight: f32,
    pub rrf_k: i32, pub mmr_lambda: f32, pub page_size: i32,
}
impl RecallFrameTuning { pub const fn default_tuning() -> Self; }   // also impl Default
```

### `Drawer` / `RecallStream` (Swift) — `DrawerRow` / `RecallPage` (Rust)

**Swift:**

```swift
public typealias Drawer = LocusKit.Drawer   // cosmetic alias; storage truth stays LocusKit.Drawer

public struct RecallStream: AsyncSequence, Sendable {
    public typealias Element = Page
    public struct Page: Sendable, Equatable {
        public let rows: [Drawer]
        public let pageIndex: Int
        public let isLast: Bool
        public init(rows: [Drawer], pageIndex: Int, isLast: Bool)
    }
    public func makeAsyncIterator() -> AsyncIterator
    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async -> Page?
    }
    // Even an empty result emits one page (rows empty, isLast == true). SPEC C-8.
}
```

**Rust:**

```rust
pub struct DrawerRow { pub id: String, pub content: String }
pub struct RecallPage { pub rows: Vec<DrawerRow>, pub page_index: i32, pub is_last: bool }
```

### `ContextDocument`

The ephemeral synthesis output handed to a foundation model; never
persisted (SPEC § 4.2, C-9).

**Swift:**

```swift
public struct ContextDocument: Sendable, Equatable, Codable {
    public let summary: String
    public let patterns: [String]          // count desc, ties by first appearance
    public let successRate: Float          // fraction currently-believed, [0,1]
    public let averageReward: Float        // 0.0 at v0.8 (no Drawer reward field)
    public let recommendations: [String]
    public let keyInsights: [String]
    public init(summary: String, patterns: [String], successRate: Float,
                averageReward: Float, recommendations: [String], keyInsights: [String])
}
```

**Rust:** (synthesis takes per-row metadata explicitly, since Rust has
no `Drawer`)

```rust
pub struct ContextDocument { /* same fields: summary, patterns, success_rate,
                                average_reward, recommendations, key_insights */ }
pub struct DrawerRowMeta { pub wing: String, pub room: String, pub is_currently_believed: bool }
```

### `ScenarioProfile`

Persisted preference signal saved alongside a tournament outcome
(SPEC § 9 open question — the `tournamentReport` field is deferred).

**Swift:**

```swift
public struct ScenarioProfile: Sendable, Equatable, Codable {
    public let profileID: UUID
    public let name: String
    public let framingParameters: [String: String]   // [String: Any] narrowed for Codable
    public let scoringBreakdown: [String: Float]
    public let preferenceWeights: [String: Float]
    public let createdAt: Date                        // caller-supplied; stored ISO8601 TEXT
    public let trainingEligible: Bool                 // value-type Bool; not a SQLite entity (B-1)
    public init(profileID: UUID = UUID(), name: String, framingParameters: [String: String],
                scoringBreakdown: [String: Float], preferenceWeights: [String: Float],
                createdAt: Date, trainingEligible: Bool = false)
}
```

**Rust:**

```rust
pub struct ScenarioProfile {
    pub profile_id: String, pub name: String,
    pub framing_parameters: BTreeMap<String, String>,
    pub scoring_breakdown: BTreeMap<String, f32>,
    pub preference_weights: BTreeMap<String, f32>,
    pub created_at: String,            // ISO8601
    pub training_eligible: bool,
}   // ScenarioProfile::new(...)
```

### `PairwiseOutcome` / `BradleyTerryScore`

Input record and fitted-strength output of the Bradley-Terry fitter
(SPEC § 4.4). `strength` is on the log BT scale, gauge-fixed so all
returned strengths sum to zero; the CI is symmetric (`strength ± 1.96·SE`).

**Swift:**

```swift
public struct PairwiseOutcome: Sendable, Equatable, Codable {
    public let winner: String
    public let loser: String
    public let count: Int   // default 1; non-positive contributes nothing; winner != loser
    public init(winner: String, loser: String, count: Int = 1)
}

public struct BradleyTerryScore: Sendable, Equatable, Codable {
    public let competitorID: String
    public let strength: Double          // log scale, sums to zero
    public let confidenceLow: Double     // strength - 1.96*SE
    public let confidenceHigh: Double    // strength + 1.96*SE
    public init(competitorID: String, strength: Double, confidenceLow: Double, confidenceHigh: Double)
}
```

**Rust:**

```rust
pub struct PairwiseOutcome { pub winner: String, pub loser: String, pub count: i64 }
impl PairwiseOutcome { pub fn new(winner: &str, loser: &str, count: i64) -> Self;
                       pub fn single(winner: &str, loser: &str) -> Self; }  // count == 1
pub struct BradleyTerryScore {
    pub competitor_id: String, pub strength: f64, pub confidence_low: f64, pub confidence_high: f64,
}
```

### Branch / benchmark / tournament types


```swift
public struct BenchmarkReport: Sendable, Equatable {
    public let branchID: BranchID
    public let queryCount: Int
    public let recallOverlap: Float        // |found ∩ expected| / |found ∪ expected|
    public let recallPrecision: Float      // |found ∩ expected| / |found|
    public let meanReciprocalRank: Float
    public let notFoundInBranch: [String]  // C-13 zero-tolerance signal; sorted
    public let newInBranch: [String]       // sorted
    public let evaluatedAt: Date
    public init(...)                        // public initializer for fixtures
}

public enum DisqualificationReason: Sendable, Equatable { case silentLoss(notFoundCount: Int) }

public struct BranchScore: Sendable, Equatable {        // not Codable (BranchHandle not Codable)
    public let branch: any BranchHandle
    public let report: BenchmarkReport
    public let combinedScore: Float                     // recallOverlap * meanReciprocalRank
    public init(branch: any BranchHandle, report: BenchmarkReport, combinedScore: Float)
}

public struct DisqualifiedBranch: Sendable, Equatable {
    public let branch: any BranchHandle
    public let reason: DisqualificationReason
    public let report: BenchmarkReport
    public init(...)
}

public struct TournamentReport: Sendable, Equatable {
    public let winner: BranchScore?                     // advisory only (I-16); nil if no survivor
    public let ranking: [BranchScore]                   // score desc, ties by branchID string
    public let disqualified: [DisqualifiedBranch]
    public let evaluatedAt: Date
    public let interval: DateInterval
    public init(...)
}
```

### Reasoning-lens result types (SPEC § 7)

Pure data carried out of the lenses; identical shape across ports (member
names match; the only sanctioned cross-port divergence anywhere in
NeuronKit is the fitter error name in § 4, SPEC C-6). All Swift result
types are `Sendable, Equatable, Codable`; all Rust result types derive
`Debug, Clone, PartialEq` and serde where serialised.

**Swift:**

```swift
// § 7.1 Structure
public struct Keystone: Sendable, Equatable, Codable {
    public let id: String
    public let centrality: Double
    public init(id: String, centrality: Double)
}

public struct Constellation: Sendable, Equatable, Codable {
    public let communities: [[String]]        // each community = ascending-sorted drawer ids
    public init(communities: [[String]])
}

public struct Activation: Sendable, Equatable, Codable {
    public let node: Int
    public let activation: Double              // normalised visit frequency, seed excluded
    public init(node: Int, activation: Double)
}

// § 7.2 Topics
public struct CategoryMomentum: Sendable, Equatable, Codable {
    public let category: String
    public let momentum: Double                // attention share − historical share
    public init(category: String, momentum: Double)
}

public struct ThemeLoading: Sendable, Equatable, Codable {
    public let label: String
    public let loadings: [Double]              // soft membership over k themes
    public let dominantTheme: Int              // argmax index into loadings
    public init(label: String, loadings: [Double], dominantTheme: Int)
}

public struct LatentThemes: Sendable, Equatable, Codable {
    public let k: Int                          // effective theme count (clamped to label count)
    public let loadings: [ThemeLoading]
    public let reconstructionError: Double     // Frobenius residual of the NMF factorisation
    public init(k: Int, loadings: [ThemeLoading], reconstructionError: Double)
}

// § 7.3 Preference
public struct CategoryBias: Sendable, Equatable, Codable {
    public let label: String
    public let estateShare: Double
    public let referenceShare: Double
    public let bias: Double                    // estateShare − referenceShare
    public init(label: String, estateShare: Double, referenceShare: Double, bias: Double)
}

public struct PreferenceStrength: Sendable, Equatable, Codable {
    public let label: String
    public let strength: Double                // BT log strength, baseline re-centred to 0
    public let confidenceLow: Double
    public let confidenceHigh: Double
    public let endorsements: Int
    public let dismissals: Int
    public init(label: String, strength: Double, confidenceLow: Double,
                confidenceHigh: Double, endorsements: Int, dismissals: Int)
}

// § 7.4 Prediction
public struct ActionObservation: Sendable, Equatable, Codable {
    public let action: UInt8
    public let outcome: UInt8
    public let success: Bool
    public init(action: UInt8, outcome: UInt8, success: Bool)
}

public struct ActionPrediction: Sendable, Equatable, Codable {
    public let action: UInt8
    public let successRate: Float              // Wilson lower bound, ranked desc
    public let count: UInt32                   // observations supporting this action
    public init(action: UInt8, successRate: Float, count: UInt32)
}

public struct DriftScore: Sendable, Equatable, Codable {
    public let jensenShannon: Float            // symmetric, bounded — primary signal
    public let klDivergence: Float             // D(p‖q), asymmetric
    public init(jensenShannon: Float, klDivergence: Float)
}

public struct Anomaly: Sendable, Equatable, Codable {
    public let index: Int                      // position in the input series
    public let zScore: Float                   // signed — negative = below the mean
    public init(index: Int, zScore: Float)
}
```

**Rust:**

```rust
// § 7.1 Structure
pub struct Keystone { pub id: String, pub centrality: f64 }
pub struct Constellation { pub communities: Vec<Vec<String>> }
pub struct Activation { pub node: usize, pub activation: f64 }

// § 7.2 Topics
pub struct CategoryMomentum { pub category: String, pub momentum: f64 }
pub struct ThemeLoading { pub label: String, pub loadings: Vec<f64>, pub dominant_theme: usize }
pub struct LatentThemes { pub k: usize, pub loadings: Vec<ThemeLoading>, pub reconstruction_error: f64 }

// § 7.3 Preference
pub struct CategoryBias { pub label: String, pub estate_share: f64, pub reference_share: f64, pub bias: f64 }
pub struct PreferenceStrength {
    pub label: String, pub strength: f64,
    pub confidence_low: f64, pub confidence_high: f64,
    pub endorsements: i64, pub dismissals: i64,
}

// § 7.4 Prediction
pub struct ActionObservation { pub action: u8, pub outcome: u8, pub success: bool }
pub struct ActionPrediction { pub action: u8, pub success_rate: f32, pub count: u32 }

// § 7.5 Surprise
pub struct DriftScore { pub jensen_shannon: f32, pub kl_divergence: f32 }
pub struct Anomaly { pub index: usize, pub z_score: f32 }
```

### Dreaming daemon surface

```swift
public actor DreamingDaemon { /* see § 3 for methods */ }

public struct DreamingPolicy: Sendable, Equatable, Codable {
    public var minSuccessRate: Float   // 0.6
    public var minConfidence: Float    // 0.7
    public var minAttempts: Int        // 3
    public var tickIntervalMs: Int     // 30_000
    public init(minSuccessRate: Float = 0.6, minConfidence: Float = 0.7,
                minAttempts: Int = 3, tickIntervalMs: Int = 30_000)
    public static let `default`: DreamingPolicy
}

public protocol DreamingPolicyStore: Sendable {
    func loadPolicy() async throws -> DreamingPolicy?
    func savePolicy(_ policy: DreamingPolicy) async throws
}
public actor InMemoryDreamingPolicyStore: DreamingPolicyStore { public init(_ initial: DreamingPolicy? = nil) }

public enum DreamingTriggerMode: String, Sendable, Codable, CaseIterable, Equatable {
    case timer, event, hybrid                 // only .timer is live at v0.8 (SPEC § 9)
    public static let `default`: DreamingTriggerMode   // .timer
}

public enum RewardSourceKind: String, Sendable, Codable, CaseIterable, Equatable {
    case recallTrace, explicitDiaryReward     // only recallTrace live at v0.8 (C-15)
}
public protocol RewardSource: Sendable {
    var kind: RewardSourceKind { get }
    func reward(for item: RecallTraceItem) -> Float   // [0,1]
}
public struct RecallTraceRewardSource: RewardSource { public init() }   // used -> 1.0, else 0.0

// Daemon seams (the B-1 boundary the Brain-layer adapter will bind to verbs):
public protocol DreamingSubstrateReader: Sendable {
    func recentRecallTraces(since: Date, now: Date) async throws -> [RecallTraceItem]
    func coOccurrenceObservations() async throws -> [CoOccurrenceObservation]
    func existingTunnels() async throws -> [Tunnel]
}
public protocol DreamingProposalSink: Sendable {
    func propose(_ frame: ProposeFrame) async throws       // ONLY write besides diary (I-1); no Tunnel-create method (B-2)
    func recordCycleDiary(_ entry: DiaryEntry) async throws
}
public struct CoOccurrenceObservation: Sendable, Equatable, Hashable {
    public let endpointA: RowID, endpointB: RowID, attempts: Int
    public let evidenceTargets: [RowID]
    public init(...)
}
public struct DreamingCycleReport: Sendable, Equatable {
    public let tickedAt: Date
    public let candidatesConsidered: Int
    public let proposalsEmitted: [ProposeFrame]
    public let suppressedDuplicates: Int
    public let belowThreshold: Int
    public let candidateScores: [String: Float]     // post-EWC++ effective confidence
    public let rewardByTarget: [RowID: Float]       // C-15: used -> 1.0
    public let diaryEntry: DiaryEntry
}
```

### Maintenance daemon surface

```swift
public actor MaintenanceDaemon { /* see § 3 for methods */ }

public struct MaintenancePolicy: Sendable, Equatable, Codable {
    public var tickIntervalMs: Int                  // 300_000
    public var auditCheckIntervalMs: Int            // 300_000
    public var decayWindowSeconds: Double           // 2_592_000 (30d)
    public var tombstoneGraceSeconds: Double        // 604_800 (7d)
    public var fingerprintDriftThreshold: Float     // 0.25
    public var byReferenceDriftThreshold: Float     // 0.25
    public init(...)
    public static let `default`: MaintenancePolicy
}
public protocol MaintenancePolicyStore: Sendable {
    func loadPolicy() async throws -> MaintenancePolicy?
    func savePolicy(_ policy: MaintenancePolicy) async throws
}
public actor InMemoryMaintenancePolicyStore: MaintenancePolicyStore { public init(_ initial: MaintenancePolicy? = nil) }

public protocol MaintenanceSubstrateReader: Sendable {
    func activeDrawers() async throws -> [Drawer]
    func tombstonedDrawers() async throws -> [Drawer]
    func learnedReferences() async throws -> [LearnedReferenceObservation]
    func fingerprintBaselines() async throws -> [FingerprintDriftObservation]
    func currentAuditLog() async throws -> UnifiedAuditLog
}
public protocol MaintenanceProposalSink: Sendable {
    func propose(_ frame: ProposeFrame) async throws       // no remediation method (B-2)
    func recordCycleDiary(_ entry: DiaryEntry) async throws
}
public struct LearnedReferenceObservation: Sendable, Equatable {
    public let referenceRowID: RowID, sourceDriftFraction: Float
    public init(...)
}
public struct FingerprintDriftObservation: Sendable, Equatable {
    public let scopeKey: String, driftFraction: Float
    public init(...)
}
public struct MaintenanceCycleReport: Sendable, Equatable {
    public let tickedAt: Date
    public let auditChecked: Bool
    public let auditReport: AuditChainReport?
    public let proposalsEmitted: [ProposeFrame]
    public let decayCandidates: Int
    public let tombstoneCandidates: Int
    public let forbiddenCombinations: Int
    public let fingerprintDrifts: Int
    public let byReferenceDrifts: Int
    public let suppressedDuplicates: Int
    public let diaryEntry: DiaryEntry
}
```

## § 3 — Public functions

Behavioral contracts: SPEC § 4–§ 5, § 7. Functions on the `NeuronKit`
namespace are listed first, then the daemon actor methods, then the
reasoning lenses.

### Lattice-anchor inference (SPEC § 4.0)

**Swift:**

```swift
extension NeuronKit {
    public static func inferLatticeAnchor(_ content: String) -> LatticeAnchorInference
}
```

**Rust:**

```rust
pub fn infer_lattice_anchor(content: &str) -> LatticeAnchorInference;
```

### Hybrid recall + standalone MMR (SPEC § 4.1, B-6, C-8)

**Swift:**

```swift
// RRF + MMR over the GLK recall verb; pages into a RecallStream. B-1 boundary.
public func hybridRecall(_ frame: RecallFrame, handle: EstateHandle,
                         on glk: GeniusLocusKit,
                         tuning: RecallFrameTuning = .default) async throws -> RecallStream

// Standalone canonical Engram-distance MMR (§ 4.1 step 4). Caller supplies
// the per-row fingerprint derivation, keeping mmrRank free of estate context.
public func mmrRank(candidates: [Drawer], query: Engram, lambda: Float, k: Int,
                    fingerprint: (Drawer) -> Engram) -> [Drawer]
```

**Rust:** (pure rerank + paging only — no estate, no `mmrRank`)

```rust
pub fn rerank(drawers: &[DrawerRow], tuning: &RecallFrameTuning) -> Vec<DrawerRow>;
pub fn page_recall(rows: &[DrawerRow], page_size: i32) -> Vec<RecallPage>;
pub fn shingles(s: &str) -> std::collections::BTreeSet<String>;     // 3-char lowercase
pub fn shingle_similarity(a: &str, b: &str) -> f32;                 // Jaccard
```

### Context synthesis (SPEC § 4.2, C-9)

**Swift:**

```swift
public enum ContextSynthesizer {
    // estate is reserved and untouched (C-9): present only for shape parity.
    public static func synthesize(from page: RecallStream.Page,
                                  estate: EstateHandle) async throws -> ContextDocument
}
```

**Rust:**

```rust
pub fn synthesize(page: &RecallPage, meta: &[DrawerRowMeta]) -> ContextDocument;
// empty meta => every row treated as DrawerRowMeta::default()
```

### Branch operations (SPEC § 4.3, I-15)

Thin forwards over the GeniusLocusKit COW branch verbs; NeuronKit stores
no branch state.

**Swift:**

```swift
extension NeuronKit {
    public static func deriveBranch(name: String, from estate: EstateHandle,
                                    in kit: GeniusLocusKit) async throws -> any BranchHandle
    public static func promoteBranch(_ branch: any BranchHandle, replacing estate: EstateHandle,
                                     in kit: GeniusLocusKit) async throws
    @discardableResult
    public static func mergeDrawers(_ drawerIDs: [DrawerID], from branch: any BranchHandle,
                                    into estate: EstateHandle, in kit: GeniusLocusKit) async throws -> MergeReport
}
```

### Migration benchmark + tournament (SPEC § 4.4, § 4.7, C-13, I-16)

**Swift:**

```swift
extension NeuronKit {
    // READ-ONLY: drives only BranchHandle.recall(_:). now passed in (B-5).
    public static func benchmark(branch: any BranchHandle, against origin: ExternalCorpus,
                                 queries: [RecallFrame] = [], now: Date) async throws -> BenchmarkReport

    // Benchmarks each branch, applies the zero-silent-loss gate BEFORE ranking,
    // ranks survivors by recallOverlap * meanReciprocalRank. Never promotes (I-16).
    public static func runTournament(branches: [any BranchHandle], against baseline: ExternalCorpus,
                                     queries: [RecallFrame] = [], evaluatedAt: Date,
                                     interval: DateInterval) async throws -> TournamentReport
}
```

### Bradley-Terry batch MLE (SPEC § 4.4, § 6)

**Swift:**

```swift
public func bradleyTerry(outcomes: [PairwiseOutcome]) throws -> [BradleyTerryScore]
// Throws MOOTx01Error.selfPairing / .disconnectedComparisonGraph. Empty input -> [].
```

**Rust:**

```rust
pub fn bradley_terry(outcomes: &[PairwiseOutcome]) -> Result<Vec<BradleyTerryScore>, TournamentError>;
// Err(TournamentError::SelfPairing(id)) / Err(DisconnectedComparisonGraph). Empty -> Ok(vec![]).
```

### Dreaming daemon (SPEC § 3.1)

**Swift:**

```swift
extension NeuronKit {
    public static func dreamingDaemon(reader: DreamingSubstrateReader, sink: DreamingProposalSink,
                                      policyStore: DreamingPolicyStore,
                                      rewardSource: RewardSource = RecallTraceRewardSource(),
                                      triggerMode: DreamingTriggerMode = .default) -> DreamingDaemon
}

public actor DreamingDaemon {
    public init(reader: DreamingSubstrateReader, sink: DreamingProposalSink,
                rewardSource: RewardSource = RecallTraceRewardSource(),
                policyStore: DreamingPolicyStore, triggerMode: DreamingTriggerMode = .default,
                policy: DreamingPolicy = .default)
    public func registerDreamingPolicy(minSuccessRate: Float = 0.6, minConfidence: Float = 0.7,
                                       minAttempts: Int = 3, tickIntervalMs: Int = 30_000) async throws
    public func loadPersistedPolicy() async throws
    public func currentPolicy() -> DreamingPolicy
    public func currentTriggerMode() -> DreamingTriggerMode
    public func rewardSourceKind() -> RewardSourceKind
    public func pump(now: Date) async throws -> DreamingCycleReport?       // fires iff interval elapsed
    @discardableResult
    public func triggerDreamingCycle(now: Date) async throws -> DreamingCycleReport   // on-demand
}
```

### Maintenance daemon (SPEC § 3.2, § 3.5)

**Swift:**

```swift
public actor MaintenanceDaemon {
    public init(reader: MaintenanceSubstrateReader, sink: MaintenanceProposalSink,
                policyStore: MaintenancePolicyStore, policy: MaintenancePolicy = .default)
    public func registerMaintenancePolicy(tickIntervalMs: Int = 300_000, auditCheckIntervalMs: Int = 300_000,
                                          decayWindowSeconds: Double = 2_592_000,
                                          tombstoneGraceSeconds: Double = 604_800,
                                          fingerprintDriftThreshold: Float = 0.25,
                                          byReferenceDriftThreshold: Float = 0.25) async throws
    public func loadPersistedPolicy() async throws
    public func currentPolicy() -> MaintenancePolicy
    public func pump(now: Date) async throws -> MaintenanceCycleReport?
    @discardableResult
    public func triggerMaintenanceCycle(now: Date) async throws -> MaintenanceCycleReport
}
```

### Reasoning lenses (SPEC § 7, § 8)

Pure, deterministic shapes over the gated SubstrateML / matrix-tier
primitives (I-17, I-18). Each is total over edge inputs (B-8, C-16)
except `learnedPreference`, which forwards the fitter's typed error.
Authored Swift-first; the Rust leg is corrected to match (C-18). Swift
lenses hang off the `NeuronKit` namespace; Rust lenses are free functions
in `neuron_kit`.

**Swift:**

```swift
extension NeuronKit {
    // § 7.1 Structure — over the drawer/tunnel graph (undirected, weight 1).
    public static func keystones(nodeIDs: [String], edges: [(String, String)],
                                 topK: Int) -> [Keystone]
    public static func constellations(nodeIDs: [String], edges: [(String, String)],
                                       maxPasses: Int) -> Constellation
    public static func spreadingActivation(adjacency: [[(node: Int, weight: Double)]],
                                           seed: Int, walkLength: Int, restartProb: Double,
                                           rngSeed: UInt64, k: Int) -> [Activation]

    // § 7.2 Topics.
    public static func recencyWeight(elapsedSeconds: Double, halfLifeSeconds: Double) -> Double
    public static func themeWeather(categories: [(category: String, rawCount: Double,
                                                  weightedMass: Double)]) -> [CategoryMomentum]
    public static func latentThemes(labels: [String],
                                    cooccurrence: [(labelA: String, labelB: String, weight: Double)],
                                    k: Int, seed: UInt64) -> LatentThemes

    // § 7.3 Preference.
    public static func representationBias(estate: [(label: String, mass: Double)],
                                          reference: [(label: String, mass: Double)]) -> [CategoryBias]
    // Throws MOOTx01Error.selfPairing only if a room is named the baseline sentinel;
    // cannot raise .disconnectedComparisonGraph (anchor reduction, SPEC § 7.3). Empty -> [].
    public static func learnedPreference(records: [(label: String, endorsements: Int,
                                                    dismissals: Int)]) throws -> [PreferenceStrength]

    // § 7.4 Prediction.
    public static func anticipate(observations: [ActionObservation], targetOutcome: UInt8,
                                  k: Int, minObservations: UInt32) -> [ActionPrediction]

    // § 7.5 Surprise.
    public static func drift(from p: [Float], to q: [Float]) -> DriftScore
    public static func anomalies(values: [Float], threshold: Float) -> [Anomaly]
}
```

**Rust:**

```rust
// § 7.1 Structure
pub fn keystones(node_ids: &[String], edges: &[(String, String)], top_k: usize) -> Vec<Keystone>;
pub fn constellations(node_ids: &[String], edges: &[(String, String)], max_passes: usize) -> Constellation;
pub fn spreading_activation(adjacency: &[Vec<(usize, f64)>], seed: usize, walk_length: usize,
                            restart_prob: f64, rng_seed: u64, k: usize) -> Vec<Activation>;

// § 7.2 Topics
pub fn recency_weight(elapsed_seconds: f64, half_life_seconds: f64) -> f64;
pub fn theme_weather(categories: &[(String, f64, f64)]) -> Vec<CategoryMomentum>;
pub fn latent_themes(labels: &[String], cooccurrence: &[(String, String, f64)],
                     k: usize, seed: u64) -> LatentThemes;

// § 7.3 Preference
pub fn representation_bias(estate: &[(String, f64)], reference: &[(String, f64)]) -> Vec<CategoryBias>;
pub fn learned_preference(records: &[(String, i64, i64)])
    -> Result<Vec<PreferenceStrength>, TournamentError>;   // cannot return DisconnectedComparisonGraph

// § 7.4 Prediction
pub fn anticipate(observations: &[ActionObservation], target_outcome: u8,
                  k: usize, min_observations: u32) -> Vec<ActionPrediction>;
```

## § 4 — Errors

NeuronKit's only typed errors are the Bradley-Terry fitter's, shared by
the `learnedPreference` preference lens (SPEC § 7.3). NeuronKit owns its
module `MOOTx01Error` enum (fleet convention; behavioral meaning in
SPEC § 6). All other operations — including every other lens — are total
(edge inputs return empty / neutral) or forward upstream GeniusLocusKit
verb errors unchanged.

**Swift:**

```swift
public enum MOOTx01Error: Error, Sendable, Equatable {
    case selfPairing(competitor: String)        // winner == loser
    case disconnectedComparisonGraph            // win graph not strongly connected => MLE not finite
}
```

**Rust:** (crate-local name; cases mirror the Swift enum — documented
drift, SPEC § 6, C-6)
```rust
pub enum TournamentError {
    SelfPairing(String),
    DisconnectedComparisonGraph,
}
```

## § 5 — Conformance test entry points

**Swift:**

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path packages/kits/NeuronKit
```

(Target: `NeuronKitTests` — `BradleyTerryTests`, `ContextSynthesizerTests`,
`DreamingDaemonTests`, `HybridRecallTests`, `MaintenanceDaemonTests`,
`MMRRankTests`, `NeuronKitTests`, `NK_BR_01_BranchBenchmarkTests`,
`ScenarioProfileTests`, `TournamentTests`, and the lens suites
`KeystonesTests`, `ConstellationTests`, `SpreadingActivationTests`,
`ThemeWeatherTests`, `LatentThemesTests`, `BiasTests`,
`AnticipationTests`.)

**Rust:**

```
cargo test -p neuron-kit
```

(Exercises the pure reasoning engines shared with Swift — lattice anchor,
hybrid-recall rerank / shingle / paging, context synthesis, Bradley-Terry
— and every § 7 lens, against the shared cross-port vectors of C-Det.)

## § 6 — Examples

```swift
import NeuronKit

// 1. Lattice-anchor inference — pure, deterministic.
let anchor = NeuronKit.inferLatticeAnchor("the migratory patterns of the arctic tern")
// anchor.enrichmentStatusBits OR'd into the provenance column by the capture path.

// 2. Hybrid recall — RRF + MMR, paged. The GLK recall verb is the only B-1 boundary.
let stream = try await hybridRecall(frame, handle: handle, on: glk)
for await page in stream {
    let doc = try await ContextSynthesizer.synthesize(from: page, estate: handle) // C-9: read-only
    feed(doc)                                                                     // to a foundation model
}

// 3. Bradley-Terry ranking — typed errors, deterministic CI bounds.
let scores = try bradleyTerry(outcomes: [
    PairwiseOutcome(winner: "A", loser: "B", count: 5),
    PairwiseOutcome(winner: "B", loser: "A"),
    PairwiseOutcome(winner: "A", loser: "C"),
    PairwiseOutcome(winner: "C", loser: "B"),
])  // strongest first; throws if the win graph is not strongly connected.

// 4. Dreaming daemon — autonomic, proposes only, injectable clock (B-5).
let daemon = NeuronKit.dreamingDaemon(reader: reader, sink: sink, policyStore: store)
try await daemon.registerDreamingPolicy()
if let report = try await daemon.pump(now: clock.now) {
    // report.proposalsEmitted are ProposeFrames; the human confirms via the associate verb.
}

// 5. Reasoning lenses — pure shapes over gated math; CognitionKit derives the inputs.
//    Structure: load-bearing memories + emergent clusters over the same graph.
let spine = NeuronKit.keystones(nodeIDs: ids, edges: tunnelPairs, topK: 10)
let groups = NeuronKit.constellations(nodeIDs: ids, edges: tunnelPairs, maxPasses: 8)
//    Structure: free association from a seed (deterministic for a fixed rngSeed).
let assoc = NeuronKit.spreadingActivation(adjacency: adj, seed: 0, walkLength: 1_000,
                                          restartProb: 0.15, rngSeed: 42, k: 5)
//    Topics: which themes are heating up.
let weather = NeuronKit.themeWeather(categories: perCategoryMasses)   // hottest first
//    Preference: learned from curation (confirmations vs withdrawals).
let prefs = try NeuronKit.learnedPreference(records: perRoomCuration) // strongest first
//    Prediction: which action reliably reaches the target outcome.
let plan = NeuronKit.anticipate(observations: events, targetOutcome: 1, k: 3, minObservations: 5)
```

---

*End of NeuronKit Interface v0.85.*
