---
title: NeuronKit Interface
status: active
version: 1.5.0
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-07-16
description: Public API surface for NeuronKit in both the Swift and Rust ports.
package: NeuronKit
languages: [swift, rust]
relates_to:
  - NEURONKIT_SPEC.md  (the contract this interface implements)
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

This interface covers the full NeuronKit surface in both ports, including
the reasoning-lens surface — nine result types (§ 2) and eight lens
functions (§ 3) — specified as first-class bilingual design (SPEC § 7,
§ 8; C-18). The lens functions share one signature set across the Swift
and Rust legs.

## § 1 — Package layout

**Swift:** `packages/kits/NeuronKit/`

- `Sources/NeuronKit/NeuronKit.swift` — the `NeuronKit` namespace,
  `inferLatticeAnchor`, the `dreamingDaemon` Interface, `LinguisticPipelineMode`
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
- `Sources/NeuronKit/BenchmarkScoring.swift` — `BenchmarkScoring` (enum, nested `Score`), `BenchmarkScoring.score(…)`
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
- `Sources/NeuronKit/Lenses/AnomalyScan.swift` — `anomalies`, `Anomaly`
- `Sources/NeuronKit/Lenses/Drift.swift` — `drift`, `DriftScore`
- `Sources/NeuronKit/Lenses/PartialRecall.swift` — `partialRecall`,
  `FingerprintBlock`, `PartialMatch`
- `Sources/NeuronKit/Lenses/MindOverlap.swift` — `dpSummary`, `summaryOverlap`
- `Sources/NeuronKit/Lenses/Distillation.swift` — `distillCluster`,
  `DistillationLensResult`, `InjectionDepth`
- `Sources/NeuronKit/Lenses/HMMFeatureExtractor.swift` — `hmmFeatureExtractor`
  (the production HMM-tagger-backed `DistillationPipeline.FeatureExtractor`)
- `Sources/NeuronKit/Lenses/NodeMotion.swift` — `NodeMotion`, `NodeAnomaly`,
  `NodeMotionLens` (diffusion node-layer lens: `fold`, `classify`, `run`, `anomaly`)
- `Sources/NeuronKit/Lenses/QueryPrecision.swift` — `NeuronKit.queryPrecision`,
  `NeuronKit.hasDistinctiveTokens`, `NeuronKit.containmentSatisfied`
- `Sources/NeuronKit/Dreaming/CorpusGrowthProbe.swift` — `CorpusGrowthProbe`
  protocol, `EstateCorpusGrowthProbe`, `autoReindexVocabGrowthFraction`,
  `autoReindexVocabGrowthFloor`
- `Sources/NeuronKit/Dreaming/` — `DreamingDaemon`, `DreamingPolicy`
  (+ `DreamingPolicyStore`, `InMemoryDreamingPolicyStore`),
  `DreamingTriggerMode`, `RewardSource` (+ `RewardSourceKind`,
  `RecallTraceRewardSource`), and the seam value types
- `Sources/NeuronKit/Maintenance/` — `MaintenanceDaemon`,
  `MaintenancePolicy` (+ store), and the seam value types
- `Sources/NeuronKit/Governor/AutonomicGovernor.swift` — `AutonomicGovernor`
  (actor), `GovernorReport`, `TopologyInputsToken`,
  `autonomicGovernorDefaultTopologyCadenceMs()`,
  `autonomicGovernorDefaultPoolReduceCadenceMs()`
- `Sources/NeuronKit/Governor/GraphCentralityProducer.swift` — `GraphCentralityCache`,
  `GraphCentralityAdjacency`
- `Sources/NeuronKit/Governor/PreferenceProducer.swift` — `PreferenceCache`,
  `PreferenceOutcomes`
- `Sources/NeuronKit/Reduction/ReductionSignals.swift` — `ReductionCandidate`,
  `ReductionQuery`, `ReductionSignal`, `NeuronKit.reductionScore(_:query:candidate:)`
- `Sources/NeuronKit/Reduction/ReductionComposition.swift` — `WeightedSignal`,
  `ReductionComposition`, `NeuronKit.reduce(composition:query:candidates:limit:)`,
  `NeuronKit.reduceLate(composition:query:candidates:limit:survivorMultiple:hydrate:)`
- `Sources/NeuronKit/Reduction/CompositionGrid.swift` — `NeuronKit.CompositionGrid`
- `Tests/NeuronKitTests/`, `Package.swift`

**Rust:** `packages/kits/NeuronKit/rust/` (crate `neuron-kit`, lib
`neuron_kit`)

- `src/lib.rs` — `VERSION`, `linguistic_pipeline_mode`, `infer_lattice_anchor`
- `src/lattice_anchor.rs`, `src/hybrid_recall.rs`,
  `src/context_synthesizer.rs`, `src/scenario_profile.rs`,
  `src/tournament.rs`
- `src/hmm_feature_extractor.rs` — `hmm_feature_extractor()`, `hmm_extract`,
  `is_year` (the production HMM-tagger-backed `FeatureExtractor` fn pointer)
- `src/benchmark_scoring.rs` — `BenchmarkScore`, `score`
- `src/query_precision.rs` — `query_precision`, `has_distinctive_tokens`,
  `containment_satisfied`, `DEFAULT_DISTINCTIVE_BONUS`
- `src/reduction_signals.rs` — `ReductionCandidate`, `ReductionQuery`, `ReductionSignal`,
  `reduction_score`, `hamming_similarity`, `lattice_proximity`, `squash`, `clamp01`,
  `temporal_text_score`, `token_exact_rate`, `reference_codes`
- `src/reduction_composition.rs` — `WeightedSignal`, `ReductionComposition`, `reduce`,
  `reduce_late`, `mmr_diversity_rerank`, `assembly_expand`,
  `DEFAULT_SURVIVOR_MULTIPLE`
- `src/composition_grid.rs` — `composition_grid::all()`, `composition_grid::named()`,
  `composition_grid::names()`, `DEFAULT_NAME`
- `src/graph_centrality.rs` — `GraphCentralityCache`, `CentralityGraph`,
  `build_centrality_graph`, `compute_centrality_scores`
- `src/preference_producer.rs` — `PreferenceCache`, `PreferenceRecord`,
  `preference_outcomes`, `compute_preference_scores`
- `src/autonomic_governor.rs` — `AutonomicGovernor` (struct), `GovernorReport`,
  `GRAPH_CENTRALITY_SCAN_NODE_CAP`, `POOL_REDUCE_FILE_CAP`
- `src/governor_topology_sink.rs` — topology-sink type wired by the governor
- `src/diffusion/node_motion.rs` — `NodeMotion`, `fold`, `DEFAULT_NODE_LAMBDA`
- `src/diffusion/node_anomaly.rs` — `NodeAnomaly`, `classify`, `DEFAULT_CHURN_THRESHOLD`
- the reasoning lenses: `src/keystones.rs`, `src/constellation.rs`,
  `src/spreading_activation.rs`, `src/theme_weather.rs`,
  `src/latent_themes.rs`, `src/bias.rs`, `src/anticipation.rs`,
  `src/anomaly_scan.rs`, `src/drift.rs`, `src/partial_recall.rs`,
  `src/mind_overlap.rs`, `src/structure_graph.rs` (shared adjacency builder)
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
public enum EnrichmentStatus: UInt8 { case none = 0, qidPending = 1, qidCompleted = 2, closureCached = 3, qidProposed = 4 }
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
#[repr(u8)] pub enum EnrichmentStatus { None = 0, QidPending = 1, QidCompleted = 2, ClosureCached = 3, QidProposed = 4 }
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
    public let averageReward: Float        // 0.0 (no Drawer reward field)
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

Persisted preference signal saved alongside a tournament outcome (SPEC § 4.6).

`tournamentReport` / `tournament_report` is a **runtime-only** field: it is
excluded from JSON serialisation because `TournamentReport` carries
`any BranchHandle` which is not `Codable` / serde-serialisable. The JSON wire
shape never contains the key; the field is always `nil` / `None` after
deserialisation, and populated by `saveScenarioProfile` at creation time.

**Swift:**

```swift
public struct ScenarioProfile: Sendable, Equatable, Codable {
    public let profileID: UUID
    public let name: String
    public let framingParameters: [String: String]   // [String: Any] narrowed for Codable
    public let scoringBreakdown: [String: Double]
    public let preferenceWeights: [String: Double]
    public let createdAt: Date                        // caller-supplied; stored ISO8601 TEXT
    public let trainingEligible: Bool                 // value-type Bool; not a SQLite entity (B-1)
    // Runtime-only — NOT in JSON. Custom CodingKeys + init(from:) exclude it.
    public let tournamentReport: TournamentReport?
    public init(profileID: UUID = UUID(), name: String, framingParameters: [String: String],
                scoringBreakdown: [String: Double], preferenceWeights: [String: Double],
                createdAt: Date, trainingEligible: Bool = false,
                tournamentReport: TournamentReport? = nil)
}
// Custom Equatable: excludes tournamentReport so decode(encode(p)) == p
```

**Rust:**

```rust
pub struct ScenarioProfile {
    pub profile_id: String, pub name: String,
    pub framing_parameters: BTreeMap<String, String>,
    pub scoring_breakdown: BTreeMap<String, f64>,
    pub preference_weights: BTreeMap<String, f64>,
    pub created_at: String,                          // ISO8601
    pub training_eligible: bool,
    #[serde(skip)]
    pub tournament_report: Option<TournamentReport>, // runtime-only, excluded from JSON
}
// ScenarioProfile::new(...)       — tournament_report: None
// ScenarioProfile::with_report(..., tournament_report: TournamentReport)
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

// § 7.5 Anomaly / drift / partial-recall lenses
public struct Anomaly: Sendable, Equatable, Codable {
    public let index: Int                      // series position flagged
    public let zScore: Float                   // signed z-score of the entry
    public init(index: Int, zScore: Float)
}

public struct DriftScore: Sendable, Equatable, Codable {
    public let jensenShannon: Float            // symmetric, bounded — primary drift signal
    public let klDivergence: Float             // D(p‖q), asymmetric
    public init(jensenShannon: Float, klDivergence: Float)
}

public enum FingerprintBlock: Int, Sendable, Equatable, Codable, CaseIterable {
    case structure = 0, concept = 1, temporal = 2, channel = 3
}

public struct PartialMatch: Sendable, Equatable, Codable {
    public let rowID: UUID
    public let score: Double                   // combined match/differ score
    public init(rowID: UUID, score: Double)
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

// § 7.5 Anomaly / drift / partial-recall lenses
pub struct Anomaly { pub index: usize, pub z_score: f32 }
pub struct DriftScore { pub jensen_shannon: f32, pub kl_divergence: f32 }
pub enum FingerprintBlock { Structure = 0, Concept = 1, Temporal = 2, Channel = 3 }
impl FingerprintBlock { pub fn as_block_index(self) -> u8; }   // raw u8 block index
// partial_recall returns Vec<(RowId, f64)> inline — no PartialMatch wrapper type
pub const BLOCK_STRUCTURE: u8; pub const BLOCK_CONCEPT: u8;
pub const BLOCK_TEMPORAL: u8;  pub const BLOCK_CHANNEL: u8;
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
    func loadBandit() async throws -> SolverBandit?                  // default: nil
    func saveBandit(_ bandit: SolverBandit) async throws            // default: no-op
    func loadDaemonState() async throws -> DreamingDaemonState?     // default: nil   (F6)
    func saveDaemonState(_ state: DreamingDaemonState) async throws // default: no-op (F6)
}
public actor InMemoryDreamingPolicyStore: DreamingPolicyStore { public init(_ initial: DreamingPolicy? = nil) }
// Manifest-backed store (F6 / ADR-020): persists policy, bandit, and daemon cycle
// state to the estate manifest through kit.estate(for:) -> Estate.meta/setMeta.
public struct EstateManifestDreamingPolicyStore: DreamingPolicyStore {
    public init(handle: EstateHandle, kit: GeniusLocusKit)
}
// Daemon cycle state carried across restarts (F6): lastTickAt, proposedKeys,
// lastReindexVocab, consolidated, cycleCount. Codable.
public struct DreamingDaemonState: Sendable, Equatable, Codable { /* … */ }

public enum DreamingTriggerMode: String, Sendable, Codable, CaseIterable, Equatable {
    case timer, event, hybrid                 // only .timer is live (SPEC § 9)
    public static let `default`: DreamingTriggerMode   // .timer
}

public enum RewardSourceKind: String, Sendable, Codable, CaseIterable, Equatable {
    case recallTrace          // implicit: RecallTraceItem.used (default, C-15)
    case explicitDiaryReward  // explicit: DiaryEntry.reward (live since schema v1)
}
public protocol RewardSource: Sendable {
    var kind: RewardSourceKind { get }
    func reward(for item: RecallTraceItem) -> Float   // [0,1]
}
public struct RecallTraceRewardSource: RewardSource { public init() }   // used -> 1.0, else 0.0
// Explicit diary reward (NEURONKIT_SPEC § 3.1 step 1a).
// Precedence: explicit → fallback (RecallTraceRewardSource when target absent).
public struct ExplicitDiaryRewardSource: RewardSource {
    public let rewardsByTarget: [String: Float]   // keyed by DrawerTarget ID
    public let fallback: any RewardSource         // default: RecallTraceRewardSource
    public init(rewardsByTarget: [String: Float], fallback: any RewardSource = RecallTraceRewardSource())
    public var kind: RewardSourceKind { .explicitDiaryReward }
    public func reward(for item: RecallTraceItem) -> Float  // explicit ?? fallback.reward(for:)
}

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

### `BenchmarkScoring`

The pure benchmark scoring core — separates the per-query score computation
from the benchmark orchestration (`BenchmarkAlgorithm`). Swift-only live path;
Rust has the flat `BenchmarkScore` struct and free `score` function.

**Swift:**

```swift
public enum BenchmarkScoring {
    public struct Score: Sendable, Equatable {
        public let queryCount: Int
        public let recallOverlap: Float
        public let recallPrecision: Float
        public let meanReciprocalRank: Float
        public let notFoundInBranch: [String]
        public let newInBranch: [String]
    }
    public static func score(expected: [String: Set<String>],
                             found: [String: [String]]) -> Score
}
```

**Rust:**

```rust
pub struct BenchmarkScore {
    pub recall_overlap: f32, pub recall_precision: f32,
    pub mean_reciprocal_rank: f32, pub not_found: Vec<String>, pub new_in_branch: Vec<String>,
}
pub fn score(expected_ids: &[String], found_per_query: &[Vec<String>]) -> BenchmarkScore;
```

### `CorpusGrowthProbe` / `EstateCorpusGrowthProbe`

Seam protocol injected into `DreamingDaemon` for auto-reindex triggering.
The daemon calls `vocabAnchor()` each cycle to measure vocabulary growth since
the last retrain, then calls `reindex(now:)` when growth crosses the
configured fraction/floor thresholds. Swift-only (GLK-bound); the Rust daemon
has no corpus-auto-reindex seam.

```swift
public let autoReindexVocabGrowthFraction: Double   // 0.10 — 10 % vocab growth
public let autoReindexVocabGrowthFloor: Int          // 25 — absolute term floor

public protocol CorpusGrowthProbe: Sendable {
    func vocabAnchor() async throws -> Int
    func reindex(now: Date) async throws
}
public struct EstateCorpusGrowthProbe: CorpusGrowthProbe {
    public init(handle: EstateHandle, kit: GeniusLocusKit)
    public func vocabAnchor() async throws -> Int
    public func reindex(now: Date) async throws
}
```

### Node-motion / diffusion types (SPEC § 11 diffusion, ADR-DIFFUSION-001)

The diffusion node-layer lens. `NodeMotion` and `NodeAnomaly` are pure data,
identical across ports. `NodeMotionLens` owns the fold + classify algorithms
(both ports) plus the estate-reading entry points `run` / `anomaly` (Swift
only — GLK-bound).

**Swift:**

```swift
public struct NodeMotion: Sendable, Equatable {
    public let rowID: UUID
    public let volatility: Double          // decay-weighted mutation mass; high → churning
    public let eventCount: Int             // distinct HLC mutation moments
    public let lastEventPhysicalMs: Int64? // most-recent event physical ms, or nil
    public let anchorTrajectory: [UInt64]  // ordered UDC anchors the node has held
    public var currentAnchor: UInt64?      // anchorTrajectory.last
    public var reanchored: Bool            // Set(anchorTrajectory).count > 1
    public init(rowID:volatility:eventCount:lastEventPhysicalMs:anchorTrajectory:)
}

public struct NodeAnomaly: Sendable, Equatable {
    public let rowID: UUID
    public let volatility: Double
    public let isChurning: Bool    // volatility ≥ churnThreshold (default 3.0)
    public let reanchored: Bool
    public let currentAnchor: UInt64?
    public var isAnomalous: Bool   // isChurning || reanchored
    public init(rowID:volatility:isChurning:reanchored:currentAnchor:)
}

public enum NodeMotionLens {
    public static let defaultNodeLambda: Double       // 0.5 — per-day decay constant
    public static let defaultChurnThreshold: Double   // 3.0 — volatility churn gate
    // Pure folds (both ports):
    public static func fold(entries: [UnifiedAuditEntry], rowID: UUID,
                            now: Date, lambdaPerDay: Double) -> NodeMotion
    public static func classify(motion: NodeMotion,
                                churnThreshold: Double = defaultChurnThreshold) -> NodeAnomaly
    // Estate-reading entry points (Swift-only, GLK-bound):
    public static func run(kit: GeniusLocusKit, handle: EstateHandle, rowID: String,
                           now: Date, lambdaPerDay: Double) async throws -> NodeMotion
    public static func anomaly(kit: GeniusLocusKit, handle: EstateHandle, rowID: String,
                               now: Date, lambdaPerDay: Double,
                               churnThreshold: Double) async throws -> NodeAnomaly
}
```

**Rust:** (pure folds only; no GLK-bound entry points)

```rust
pub struct NodeMotion {
    pub row_id: uuid::Uuid, pub volatility: f64, pub event_count: usize,
    pub last_event_physical_ms: Option<i64>, pub anchor_trajectory: Vec<u64>,
}
// current_anchor() -> Option<u64> ; reanchored() -> bool
pub const DEFAULT_NODE_LAMBDA: f64;     // 0.5
pub fn fold(entries: &[UnifiedAuditEntry], row_id: Uuid, now_ms: i64,
            lambda_per_day: f64) -> NodeMotion;

pub struct NodeAnomaly {
    pub row_id: uuid::Uuid, pub volatility: f64,
    pub is_churning: bool, pub reanchored: bool, pub current_anchor: Option<u64>,
}
// is_anomalous() -> bool
pub const DEFAULT_CHURN_THRESHOLD: f64; // 3.0
pub fn classify(motion: &NodeMotion, churn_threshold: f64) -> NodeAnomaly;
```

### Reduction pipeline types

The precise-reduction pipeline: pure, deterministic re-rank of a coarse
hybrid-recall pool into an exact-answer-first bounded set. All types live
in NeuronKit on both ports; CognitionKit's `PreciseRecall` recipe orchestrates.

**Swift:**

```swift
// One candidate in the reduction pool.
public struct ReductionCandidate: Sendable {
    public let id: String
    public let content: String
    public let room: String
    public let score: RecallScoreVector      // dense recall signal from GLK Step 2
    public let udcCode: String
    public let udcFacets: String?
    public let coarseRank: Int               // 0-based position in coarse-grab pool
    public let eventTime: Date?
    public let isCurrentlyBelieved: Bool     // drawer state Cluster A
    public let precisionScore: Double        // stamped by reduce fold; 0 before scoring
    public init(id:content:room:score:udcCode:udcFacets:coarseRank:eventTime:isCurrentlyBelieved:precisionScore:)
    public static func from(hit: RecallHit, coarseRank: Int) -> ReductionCandidate
}

// Query side: text + optional lattice anchor.
public struct ReductionQuery: Sendable, Equatable {
    public let text: String
    public let udcCode: String    // "" when unanchored
    public init(text: String, udcCode: String = "")
}

// Named per-candidate signal component.
public enum ReductionSignal: String, Sendable, CaseIterable, Codable {
    case text, hamming, matrix, lattice, bm25, vector, dense
    case tokenExact, temporalState, temporalText, assembly, mmr
    public var isSetLevel: Bool   // mmr, assembly — handled by compose fold, not score
    public var needsContent: Bool // text, tokenExact, mmr, temporalText, assembly need body
}

// One weighted term in a composition.
public struct WeightedSignal: Sendable, Equatable, Codable {
    public let signal: ReductionSignal
    public let weight: Double
    public init(_ signal: ReductionSignal, weight: Double = 1.0)
}

// Named, declarative reduction composition.
public struct ReductionComposition: Sendable, Equatable, Codable {
    public let name: String
    public let terms: [WeightedSignal]
    public let mmrLambda: Double    // default 0.7; used only when mmr term present
    public init(name: String, terms: [WeightedSignal], mmrLambda: Double = 0.7)
}
```

**Rust:** (identical shapes; `WeightedSignal` is also a named struct on the Rust side)

```rust
pub struct ReductionCandidate { /* same fields */ }
impl ReductionCandidate { pub fn from_hit(hit: &RecallHit, coarse_rank: usize) -> Self; }
pub struct ReductionQuery { pub text: String, pub udc_code: String }
impl ReductionQuery { pub fn new(text: impl Into<String>) -> Self; }
pub enum ReductionSignal { Text, Hamming, Matrix, Lattice, Bm25, Vector, Dense,
                           TokenExact, TemporalState, TemporalText, Assembly, Mmr }
impl ReductionSignal { pub fn is_set_level(self) -> bool; pub fn needs_content(self) -> bool; }
pub struct WeightedSignal { pub signal: ReductionSignal, pub weight: f64 }
impl WeightedSignal { pub fn new(signal: ReductionSignal) -> Self;
                      pub fn weighted(signal: ReductionSignal, weight: f64) -> Self; }
pub struct ReductionComposition { pub name: String, pub terms: Vec<WeightedSignal>,
                                  pub mmr_lambda: f64 }
impl ReductionComposition { pub fn new(…) -> Self; pub fn with_lambda(…) -> Self;
                             pub fn has_mmr(&self) -> bool; pub fn has_assembly(&self) -> bool;
                             pub fn dense_per_candidate_terms(&self) -> Vec<WeightedSignal>;
                             pub fn needs_content(&self) -> bool; }
pub const DEFAULT_SURVIVOR_MULTIPLE: usize;  // 8
```

### `CompositionGrid`

The named ablation grid of all shipped `ReductionComposition` values. Adding
a composition is one entry here; the optimizer enumerates the grid against the
recall gauntlet. Both ports expose the grid; Rust uses free functions in the
`composition_grid` module rather than a namespace enum.

**Swift:**

```swift
public enum CompositionGrid {
    public static let defaultName: String       // "text"
    public static let all: [ReductionComposition]
    public static func named(_ name: String?) -> ReductionComposition
    public static var names: [String]
}
```

**Rust:**

```rust
pub const DEFAULT_NAME: &str;                         // "text"
pub fn all() -> Vec<ReductionComposition>;
pub fn named(name: Option<&str>) -> ReductionComposition;
pub fn names() -> Vec<String>;
pub fn is_known(name: &str) -> bool;                  // Rust-only convenience predicate
```

### Governor types

The `AutonomicGovernor` is the production wiring that sequences all
background autonomic duties — dreaming, maintenance, graph-centrality cache
updates, preference score updates, topology snapshots, GC sweeps, and the
bounded pool-reduce pass. Both ports have an `AutonomicGovernor`; the Rust
governor is a struct (sync; no async actor isolation). `TopologyInputsToken`
and the producer cache types (`GraphCentralityCache`, `PreferenceCache`) are
part of the governor surface.

**Swift:**

```swift
public func autonomicGovernorDefaultTopologyCadenceMs() -> Int   // 300_000
public func autonomicGovernorDefaultPoolReduceCadenceMs() -> Int // 300_000

public actor AutonomicGovernor {
    public init(kit: GeniusLocusKit, handles: [EstateHandle], …)
    public struct GovernorReport: Sendable {
        public let dreamingFired: Bool
        public let maintenanceFired: Bool
        public let signalsTicked: Bool
        public let graphAnalyticsFired: Bool
        public let graphCentralityFired: Bool
        public let preferenceFired: Bool
        public let topologySnapshotFired: Bool
        public let poolReduceFired: Bool
        public let tableSwapped: Bool
        public let tableVersion: UInt64
        public let gcSweepFired: Bool
    }
    public func run() async
    public func tick(now: Date) async -> GovernorReport
    public static func graphCentralityScan(…) async throws -> GraphCentralityCache
    public static func preferenceScan(…) async throws -> PreferenceCache
    public static func topologySnapshotDuty(…) async throws
}

// Stable token representing topology inputs: digest changes only when
// drawer/tunnel/fact counts or max timestamps change; avoids redundant snapshot recomputes.
public struct TopologyInputsToken: Sendable, Equatable {
    public let drawerCount: Int
    public let tunnelCount: Int
    public let factCount: Int
    public let deadDrawerCount: Int
    public let deadTunnelCount: Int
    public let maxFiledAt: Date?
    public let maxEventTime: Date?
    public let inputsDigest: UInt64
    public var fingerprint: String
}

// Read-only centrality-score cache produced by graphCentralityScan.
public final class GraphCentralityCache: GraphCache, Sendable {
    public init(scores: [String: Float])
    public func graphScore(for drawerID: String) -> Float
    public var count: Int
}

// Adjacency builder helper used by graphCentralityScan (Swift public for testing).
public enum GraphCentralityAdjacency {
    public static let kgFactGroupCap: Int   // 50
    public struct Graph: Sendable {
        public let nodeIDs: [String]
        public let edges: [(String, String)]
    }
    public static func build(drawers: [Drawer], tunnels: [Tunnel], facts: [KGFact]) -> Graph
}

// Read-only preference-score cache produced by preferenceScan.
public final class PreferenceCache: PreferenceStore, Sendable {
    public init(scores: [String: Float])
    public func preferenceScore(for drawerID: String) -> Float
    public var count: Int
}

public enum PreferenceOutcomes {
    public struct Record: Sendable, Equatable {
        public let label: String
        public let endorsements: Int
        public let dismissals: Int
        public init(label: String, endorsements: Int, dismissals: Int)
    }
    public static func build(traces: [RecallTraceItem]) -> [Record]
}
```

**Rust:**

```rust
pub const GRAPH_CENTRALITY_SCAN_NODE_CAP: usize;   // 10_000
pub const POOL_REDUCE_FILE_CAP: usize;             // 500
pub struct AutonomicGovernor { /* … */ }
pub struct GovernorReport { /* same fields as Swift, snake_case */ }
impl AutonomicGovernor { pub fn new(…) -> Self; pub fn stop(&self);
    pub fn tick(&mut self, …); pub fn register_standing_signal(…); /* … */ }

pub struct GraphCentralityCache { /* … */ }
impl GraphCentralityCache { pub fn new(scores: HashMap<String, f32>) -> Self;
    pub fn count(&self) -> usize; }
pub struct CentralityGraph { /* node_ids, edges */ }
pub fn build_centrality_graph(…) -> CentralityGraph;
pub fn compute_centrality_scores(graph: &CentralityGraph) -> GraphCentralityCache;

pub struct PreferenceCache { /* … */ }
impl PreferenceCache { pub fn new(scores: HashMap<String, f32>) -> Self;
    pub fn count(&self) -> usize; }
pub struct PreferenceRecord { pub label: String, pub endorsements: i64, pub dismissals: i64 }
pub fn preference_outcomes(traces: &[RecallTraceItem]) -> Vec<PreferenceRecord>;
pub fn compute_preference_scores(records: &[PreferenceRecord]) -> PreferenceCache;
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
    func loadDaemonState() async throws -> MaintenanceDaemonState?     // default: nil   (F6)
    func saveDaemonState(_ state: MaintenanceDaemonState) async throws // default: no-op (F6)
}
public actor InMemoryMaintenancePolicyStore: MaintenancePolicyStore { public init(_ initial: MaintenancePolicy? = nil) }
// Manifest-backed store (F6 / ADR-020): persists policy + daemon cycle state to
// the estate manifest through kit.estate(for:) -> Estate.meta/setMeta.
public struct EstateManifestMaintenancePolicyStore: MaintenancePolicyStore {
    public init(handle: EstateHandle, kit: GeniusLocusKit)
}
// Daemon cycle state carried across restarts (F6): lastTickAt, lastAuditCheckAt,
// proposedKeys, cycleCount. Codable.
public struct MaintenanceDaemonState: Sendable, Equatable, Codable { /* … */ }

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

**Rust:** (GLK entry point + rerank + paging — no `mmrRank`)

```rust
// GLK entry point — routes through EstateCoordinator::recall (B-1), applies
// RRF+MMR rerank, emits 3 telemetry metrics, returns paged results.
pub fn hybrid_recall(
    coordinator: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, tuning: &RecallFrameTuning, now: i64,
) -> Result<Vec<RecallPage>, VerbDispatchError>;

// Pure rerank + paging engine (no estate dependency).
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
    // Runs full Louvain (SubstrateML detectFull) at maxLevels =
    // topologyMaxLevels and resolution = topologyResolution; maxPasses is
    // the caller-supplied per-level pass budget.
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

    // § 7.5 Anomaly / drift / partial-recall.
    public static func anomalies(values: [Float], threshold: Float) -> [Anomaly]
    public static func drift(from p: [Float], to q: [Float]) -> DriftScore
    public static func partialRecall(anchor: Fingerprint256,
                                     rows: [(rowID: UUID, fingerprint: Fingerprint256)],
                                     matchBlocks: Set<FingerprintBlock>,
                                     differBlocks: Set<FingerprintBlock>,
                                     k: Int) -> [PartialMatch]

    // Mind overlap — differentially-private aggregate summary + cross-estate overlap.
    public static func dpSummary(fingerprints: [Fingerprint256], epsilon: Double,
                                 delta: Double, kAnonymity: Int, seed: UInt64) -> Fingerprint256
    public static func summaryOverlap(_ a: Fingerprint256, _ b: Fingerprint256) -> Double

    // § 7.5 Substrate-signal lenses (SPEC § 7.5).
    // OR-reduces a fingerprinted time window into a signature and ranks candidates
    // by ascending Hamming distance (ties: input order / stable sort).
    public static func momentSignature(fingerprints: [RowLite],
                                       candidates: [Fingerprint256]) -> MomentSignatureResult

    // Dominant spectral periods in a boolean activity series via FFT.
    public static func rhythm(buckets: [Bool], bucketDurationSeconds: Double,
                               topK: Int) -> [DominantPeriod]

    // T-matrix antecedent ranker: filters pre-folded pairs by target, sorts by count desc.
    public static func precedence(pairs: [(TemporalCausalityKey, Int64)],
                                  target: TemporalFieldCoord, k: Int) -> [AntecedentRank]

    // Shannon entropy + (optional) mutual information over raw count distributions.
    public static func complexity(countsA: [Float32], countsB: [Float32]?,
                                   joint: [[Float32]]?) -> ComplexityResult

    // Maps claimed confidence values through a MatrixCalibrationCurve (GLK).
    public static func calibrate(curve: MatrixCalibrationCurve,
                                 claimed: [Float]) -> [CalibratedValue]
}
```

**Rust:**

```rust
// § 7.1 Structure
pub fn keystones(node_ids: &[String], edges: &[(String, String)], top_k: usize) -> Vec<Keystone>;
// Runs full Louvain (substrate_ml detect_full) at TOPOLOGY_MAX_LEVELS and
// TOPOLOGY_RESOLUTION; max_passes is the caller-supplied per-level budget.
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

// § 7.5 Anomaly / drift / partial-recall
pub fn anomalies(values: &[f32], threshold: f32) -> Vec<Anomaly>;
pub fn drift(p: &[f32], q: &[f32]) -> DriftScore;
pub fn partial_recall(anchor: Fingerprint256, rows: &[(RowId, Fingerprint256)],
                      match_blocks: &HashSet<u8>, differ_blocks: &HashSet<u8>,
                      k: usize) -> Vec<(RowId, f64)>;   // inline tuples, no PartialMatch type

// Mind overlap
pub fn dp_summary(fingerprints: &[Fingerprint256], epsilon: f64, delta: f64,
                  k_anonymity: usize, seed: u64) -> Fingerprint256;
pub fn summary_overlap(a: Fingerprint256, b: Fingerprint256) -> f64;

// § 7.5 Substrate-signal lenses (SPEC § 7.5)
pub fn moment_signature(fingerprints: &[RowLite], candidates: &[Engram]) -> MomentSignatureResult;
pub fn rhythm(buckets: &[bool], bucket_duration_seconds: f64, top_k: usize) -> Vec<DominantPeriod>;
pub fn precedence(pairs: &[(TemporalCausalityKey, i64)], target: &TemporalFieldCoord,
                  k: usize) -> Vec<AntecedentRank>;
pub fn complexity(counts_a: &[f32], counts_b: Option<&[f32]>,
                  joint: Option<&[Vec<f32>]>) -> ComplexityResult;
pub fn calibrate(curve: &MatrixCalibrationCurve, claimed: &[f32]) -> Vec<CalibratedValue>;
```

### Query-precision scoring (SPEC pure text math, no SubstrateML gate)

Discriminative re-rank signal for the precise-recall recipe: content-word
match plus a bounded distinctive-token bonus. Pure, total, deterministic.
Both ports; identical ASCII-folded tokenisation rules.

**Swift:**

```swift
extension NeuronKit {
    // Precision of candidate as an answer to query, in [0, 1]. Returns 0 when
    // either side is empty. distinctiveBonus (default 0.25) is the max additive
    // contribution of numeric / proper-noun token matches.
    public static func queryPrecision(query: String, candidate: String,
                                      distinctiveBonus: Float = 0.25) -> Float

    // True when query contains at least one distinctive token (number or
    // capitalised word). When true, the exact-token gate in moot_recall_precise
    // applies; used by RecipeTools without re-implementing tokenisation.
    public static func hasDistinctiveTokens(_ query: String) -> Bool

    // True when any candidateContents satisfies the distinctive-token
    // containment gate for query, or when query has no distinctive tokens.
    // Returns false → recall set should be suppressed as not_found.
    public static func containmentSatisfied(query: String,
                                            candidateContents: [String]) -> Bool
}
```

**Rust:**

```rust
pub const DEFAULT_DISTINCTIVE_BONUS: f32;   // 0.25
pub fn query_precision(query: &str, candidate: &str, distinctive_bonus: f32) -> f32;
pub fn has_distinctive_tokens(query: &str) -> bool;
pub fn containment_satisfied(query: &str, candidate_contents: &[&str]) -> bool;
pub fn word_tokens(s: &str) -> Vec<String>;          // shared tokeniser
pub fn distinctive_tokens(s: &str) -> BTreeSet<String>;
```

### Reduction pipeline functions (SPEC bounded re-rank discipline)

**Swift:**

```swift
extension NeuronKit {
    // Per-candidate score for signal in [0, 1]. Set-level signals (mmr, assembly)
    // return 0.5 (neutral). Total and deterministic.
    public static func reductionScore(_ signal: ReductionSignal, query: ReductionQuery,
                                      candidate: ReductionCandidate) -> Double

    // Re-rank candidates under composition against query; return top limit in
    // precision order. Never prunes pool below limit (bounded-reduce discipline).
    // Steps: weighted-sum, stable sort, optional MMR re-rank, optional assembly
    // expansion, bounded truncate.
    public static func reduce(composition: ReductionComposition, query: ReductionQuery,
                              candidates: [ReductionCandidate], limit: Int) -> [ReductionCandidate]

    // Narrow-then-hydrate reduce: body-free dense signals score the wide pool first,
    // a bounded survivor set is hydrated via the hydrate closure, then the full
    // composition scores the survivors. Equivalent to reduce when composition has
    // no dense terms (falls back to full-pool hydration) or no content terms
    // (selects body-free, hydrates top-k for output). survivorMultiple defaults to 8.
    public static func reduceLate(
        composition: ReductionComposition, query: ReductionQuery,
        candidates: [ReductionCandidate], limit: Int, survivorMultiple: Int = 8,
        hydrate: ([String]) async throws -> [String: String]
    ) async throws -> [ReductionCandidate]
}
```

**Rust:**

```rust
pub fn reduction_score(signal: ReductionSignal, query: &ReductionQuery,
                        candidate: &ReductionCandidate) -> f64;
pub fn reduce(composition: &ReductionComposition, query: &ReductionQuery,
              candidates: &[ReductionCandidate], limit: usize) -> Vec<ReductionCandidate>;
pub fn reduce_late<F>(composition: &ReductionComposition, query: &ReductionQuery,
                      candidates: &[ReductionCandidate], limit: usize,
                      survivor_multiple: usize,
                      hydrate: F) -> Result<Vec<ReductionCandidate>, …>
where F: Fn(&[String]) -> Result<HashMap<String, String>, …>;
```

### Analytics capabilities (not NeuronKit surfaces)

Two analytics capabilities appear in CognitionKit's `NeuronKitCapability`
enum — `associationRuleMining` and `formalConceptAnalysis` — but are NOT
NeuronKit surfaces. They are CognitionKit gate vocabulary that points
directly to SubstrateML engines (`AssociationRuleMining` and
`BoundedConceptMiner`). NeuronKit neither owns nor wraps these engines;
a recipe that declares `.associationRuleMining` or `.formalConceptAnalysis`
calls SubstrateML directly. They are listed here so readers of the
`NeuronKitCapability` enum are not confused by names absent from this
interface document.

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
`MMRRankTests`, `NeuronKitTests`, `BranchBenchmarkTests`,
`ScenarioProfileTests`, `TournamentTests`, and the lens suites
`KeystonesTests`, `ConstellationTests`, `SpreadingActivationTests`,
`ThemeWeatherTests`, `LatentThemesTests`, `BiasTests`,
`AnticipationTests`, `AnomalyScanTests`, `DriftTests`,
`PartialRecallTests`, `MindOverlapTests`, `StructureLensTests`, and
the cross-port `LensVectorConformanceTests`.)

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

## § 7 — Swift/Rust Concordance

This is the authoritative one-row-per-concept parity table; every top-level
public declaration in `Sources/NeuronKit/**` (Swift `public
struct|enum|protocol|class|actor|typealias`) and `rust/src/**` (Rust
top-level `pub struct|enum|trait|type`) is anchored to a row here.
Cross-port behavioral parity for the pure engines and every § 7 lens is
proved by the shared deterministic vector harness — Swift
`LensVectorConformanceTests` and Rust `lens_conformance` — replaying the
same JSON fixtures — plus the per-concept domain suites named below.
The sub-tables that follow the main table record specific cross-port
shape deltas.

### Concordance table

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Module namespace | `NeuronKit` (enum) `NeuronKit.swift:22` | `neuron_kit` crate free items `lib.rs` | `public` / `pub` | Swift roll-up enum carries `version` + extensions; Rust has no namespace type (free `VERSION` const + free fns) — sanctioned idiom | `NeuronKitTests.swift` | Confirmed |
| Linguistic pipeline mode | `LinguisticPipelineMode` `NeuronKit.swift:136` | `LinguisticPipelineMode` `lattice_anchor.rs:55` | `public` / `pub` | identical (kebab serde; Rust always `DeterministicReference`) | `LatticeAnchorInferenceTests.swift` ; `lattice_anchor.rs` tests | Confirmed |
| Lattice-anchor result | `LatticeAnchorInference` `LatticeAnchorInference.swift:21` | `LatticeAnchorInference` `lattice_anchor.rs:19` | `public` / `pub` | identical (snake/camel field idiom) | `LatticeAnchorInferenceTests.swift` ; `lattice_anchor.rs` tests | Confirmed |
| Anchor confidence band | `AnchorConfidence` `LatticeAnchorInference.swift:70` | `AnchorConfidence` `lattice_anchor.rs:74` | `public` / `pub` | identical `u8`-raw enum | `LatticeAnchorInferenceTests.swift` | Confirmed |
| Enrichment status | `EnrichmentStatus` `LatticeAnchorInference.swift:80` | `EnrichmentStatus` `lattice_anchor.rs:92` | `public` / `pub` | identical `u8`-raw enum | `LatticeAnchorInferenceTests.swift` | Confirmed |
| Recall fusion tuning | `RecallFrameTuning` `HybridRecall.swift:94` | `RecallFrameTuning` `hybrid_recall.rs:31` | `public` / `pub` | identical (Swift `Int`/`Float`, Rust `i32`/`f32` idiom) | `HybridRecallTests.swift` ; `hybrid_recall.rs` tests | Confirmed |
| Drawer row alias | `Drawer` typealias `HybridRecall.swift:53` | `DrawerRow` `hybrid_recall.rs:22` | `public` / `pub` | Swift aliases `LocusKit.Drawer` (storage truth); Rust has no estate dep so `DrawerRow` is a flat `{id, content}` projection — sanctioned (Rust: no LocusKit/EngramLib dep, SPEC I-17/I-18) | `HybridRecallTests.swift` ; `hybrid_recall.rs` rerank tests | Confirmed |
| Recall page / stream | `RecallStream` (+ nested `Page`) `HybridRecall.swift:140` | `RecallPage` `hybrid_recall.rs:63` | `public` / `pub` | Swift `AsyncSequence` of `Page`; Rust sync `Vec<RecallPage>` (no async runtime — sanctioned, cf. policy-store seam) | `HybridRecallTests.swift` ; `hybrid_recall.rs` paging tests | Confirmed |
| Context document | `ContextDocument` `ContextSynthesizer.swift:23` | `ContextDocument` `context_synthesizer.rs:16` | `public` / `pub` | identical fields | `ContextSynthesizerTests.swift` ; `context_synthesizer.rs` tests | Confirmed |
| Context synthesizer | `ContextSynthesizer` (enum) `ContextSynthesizer.swift:77` | free fn `synthesize` `context_synthesizer.rs` | `public` / `pub` | Swift caseless-enum namespace `async` taking `EstateHandle`; Rust free `synthesize` takes explicit `&[DrawerRowMeta]` (no estate) — sanctioned (Rust: no estate dep) | `ContextSynthesizerTests.swift` ; `context_synthesizer.rs` tests | Confirmed |
| Synthesis row metadata | (inline `Drawer` fields, Swift) | `DrawerRowMeta` `context_synthesizer.rs:32` | — / `pub` | Swift reads metadata off `Drawer`; Rust needs an explicit per-row meta struct since it has no `Drawer` — sanctioned (Rust: no estate dep) | `context_synthesizer.rs` tests | Confirmed |
| Scenario profile | `ScenarioProfile` `ScenarioProfile.swift:34` | `ScenarioProfile` `scenario_profile.rs:23` | `public` / `pub` | identical (UUID→String, `[String:_]`→`BTreeMap` idiom; ISO8601 TEXT date); `tournamentReport`/`tournament_report: Option<TournamentReport>` is runtime-only — excluded from JSON via CodingKeys (Swift) / `#[serde(skip)]` (Rust); custom `Equatable` (Swift) / auto `PartialEq` (Rust) excludes it from equality | `ScenarioProfileTests.swift` ; `scenario_profile.rs` tests | Confirmed |
| Pairwise outcome | `PairwiseOutcome` `Tournament/PairwiseOutcome.swift:36` | `PairwiseOutcome` `tournament.rs:45` | `public` / `pub` | identical (`Int`/`i64` count idiom) | `BradleyTerryTests.swift` ; `tournament.rs` tests | Confirmed |
| Bradley-Terry score | `BradleyTerryScore` `Tournament/BradleyTerryScore.swift:45` | `BradleyTerryScore` `tournament.rs:77` | `public` / `pub` | identical | `BradleyTerryTests.swift` ; `tournament.rs` tests | Confirmed |
| Fitter error | `MOOTx01Error` `Tournament/BradleyTerry.swift:34` | `TournamentError` `tournament.rs:87` | `public` / `pub` | sanctioned name drift, cases mirror (SPEC § 6, C-6): Swift module `MOOTx01Error` vs crate-local `TournamentError` | `BradleyTerryTests.swift` ; `tournament.rs` tests | Confirmed |
| Benchmark report | `BenchmarkReport` `BenchmarkAlgorithm.swift:19` | `BenchmarkReport` `benchmark_live.rs:30` | `public` / `pub` | identical scored fields (Swift adds `branchID`/`evaluatedAt` caller fields) | `BranchBenchmarkTests.swift` ; `benchmark_live.rs` tests | Confirmed |
| Benchmark scoring core | `BenchmarkScoring` (enum, nested `Score`) `BenchmarkScoring.swift:23` | `BenchmarkScore` (+ free `score`) `benchmark_scoring.rs:21` | `public` / `pub` | Swift nested `BenchmarkScoring.Score` / Rust flat `BenchmarkScore`; pure scoring fn shared, fixture-gated | `BenchmarkScoringTests.swift` ; `benchmark_scoring.rs` tests | Confirmed |
| Disqualification reason | `DisqualificationReason` `Tournament.swift:42` | `DisqualificationReason` `tournament_live.rs:26` | `public` / `pub` | identical | `TournamentTests.swift` ; `tournament_live.rs` tests | Confirmed |
| Branch score | `BranchScore` `Tournament.swift:62` | `BranchScore` `tournament_live.rs:34` | `public` / `pub` | identical (Swift `branch: any BranchHandle` vs Rust id-string — Rust has no estate handle, sanctioned) | `TournamentTests.swift` ; `tournament_live.rs` tests | Confirmed |
| Disqualified branch | `DisqualifiedBranch` `Tournament.swift:101` | `DisqualifiedBranch` `tournament_live.rs:43` | `public` / `pub` | identical (same handle idiom note) | `TournamentTests.swift` ; `tournament_live.rs` tests | Confirmed |
| Tournament report | `TournamentReport` `Tournament.swift:133` | `TournamentReport` `tournament_live.rs:53` | `public` / `pub` | identical | `TournamentTests.swift` ; `tournament_live.rs` tests | Confirmed |
| Keystone (structure) | `Keystone` `Lenses/Keystones.swift:8` | `Keystone` `keystones.rs:14` | `public` / `pub` | identical | `KeystonesTests.swift`/`StructureLensTests.swift` ; `lens_conformance.rs` + `keystones.rs` | Confirmed |
| Constellation (structure) | `Constellation` `Lenses/Constellation.swift:9` | `Constellation` `constellation.rs:19` | `public` / `pub` | identical | `ConstellationTests.swift` ; `lens_conformance.rs` + `constellation.rs` | Confirmed |
| Activation (structure) | `Activation` `Lenses/SpreadingActivation.swift:12` | `Activation` `spreading_activation.rs:14` | `public` / `pub` | identical (`Int`/`usize` node idiom) | `SpreadingActivationTests.swift` ; `lens_conformance.rs` + `spreading_activation.rs` | Confirmed |
| Category momentum (topic) | `CategoryMomentum` `Lenses/ThemeWeather.swift:12` | `CategoryMomentum` `theme_weather.rs:11` | `public` / `pub` | identical | `ThemeWeatherTests.swift`/`TopicLensTests.swift` ; `lens_conformance.rs` + `theme_weather.rs` | Confirmed |
| Theme loading (topic) | `ThemeLoading` `Lenses/LatentThemes.swift:11` | `ThemeLoading` `latent_themes.rs:13` | `public` / `pub` | identical (`Int`/`usize` index idiom) | `LatentThemesTests.swift` ; `lens_conformance.rs` + `latent_themes.rs` | Confirmed |
| Latent themes (topic) | `LatentThemes` `Lenses/LatentThemes.swift:23` | `LatentThemes` `latent_themes.rs:21` | `public` / `pub` | identical | `LatentThemesTests.swift` ; `lens_conformance.rs` + `latent_themes.rs` | Confirmed |
| Category bias (pref) | `CategoryBias` `Lenses/Bias.swift:11` | `CategoryBias` `bias.rs:22` | `public` / `pub` | identical | `BiasTests.swift`/`PreferenceLensTests.swift` ; `lens_conformance.rs` + `bias.rs` | Confirmed |
| Preference strength (pref) | `PreferenceStrength` `Lenses/Bias.swift:27` | `PreferenceStrength` `bias.rs:32` | `public` / `pub` | identical (`Int`/`i64` count idiom) | `PreferenceLensTests.swift` ; `lens_conformance.rs` + `bias.rs` | Confirmed |
| Action observation (pred) | `ActionObservation` `Lenses/Anticipation.swift:13` | `ActionObservation` `anticipation.rs:14` | `public` / `pub` | identical | `AnticipationTests.swift`/`PredictionLensTests.swift` ; `lens_conformance.rs` + `anticipation.rs` | Confirmed |
| Action prediction (pred) | `ActionPrediction` `Lenses/Anticipation.swift:26` | `ActionPrediction` `anticipation.rs:23` | `public` / `pub` | identical | `PredictionLensTests.swift` ; `lens_conformance.rs` + `anticipation.rs` | Confirmed |
| Anomaly (scan lens) | `Anomaly` `Lenses/AnomalyScan.swift:15` | `Anomaly` `anomaly_scan.rs:17` | `public` / `pub` | identical | `AnomalyScanTests.swift` ; `anomaly_scan.rs` tests | Confirmed |
| Drift score (lens) | `DriftScore` `Lenses/Drift.swift:15` | `DriftScore` `drift.rs:17` | `public` / `pub` | identical (JS + KL divergence) | `DriftTests.swift` ; `drift.rs` tests | Confirmed |
| Fingerprint block | `FingerprintBlock` `Lenses/PartialRecall.swift:20` | `FingerprintBlock` `partial_recall.rs:34` | `public` / `pub` | Swift `Int`-raw enum + `Set<FingerprintBlock>`; Rust enum + `as_block_index()->u8` with `HashSet<u8>` — API shape differs, semantics identical (see FingerprintBlock sub-table) | `PartialRecallTests.swift`/`MindOverlapTests.swift` ; `lens_conformance.rs` partial_recall | Confirmed |
| Partial-recall match | `PartialMatch` `Lenses/PartialRecall.swift:28` | (inline tuple return of `partial_recall`) `partial_recall.rs:57` | `public` / `pub fn` | Swift wraps `(rowID, score)` in a `PartialMatch` struct; Rust `partial_recall` returns the ranked matches inline (no wrapper type) — sanctioned shape idiom, behavior is vector-bound | `PartialRecallTests.swift` ; `lens_conformance.rs` partial_recall cases | Confirmed |
| Mind overlap (function-only lens) | `dpSummary` / `summaryOverlap` `Lenses/MindOverlap.swift:21,46` | `dp_summary` / `summary_overlap` `mind_overlap.rs:24,46` | `public` / `pub fn` | function-only lens, no new result type (returns `Fingerprint256` / `Double`); identical math (DP-OR reduction + 192-bit content-block overlap) | `MindOverlapTests.swift` ; `lens_conformance.rs` mind_overlap cases | Confirmed |
| Dreaming policy | `DreamingPolicy` `Dreaming/DreamingPolicy.swift:24` | `DreamingPolicy` `dreaming_cycle.rs:107` | `public` / `pub` | identical (see policy field-completeness sub-table) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Dreaming policy store | `DreamingPolicyStore` `Dreaming/DreamingPolicy.swift:71` | `DreamingPolicyStore` `dreaming_cycle.rs:138` | `public` / `pub` | Swift `async` protocol / Rust sync trait (no async runtime — sanctioned, policy-store seam) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| In-memory dreaming store | `InMemoryDreamingPolicyStore` (actor) `Dreaming/DreamingPolicy.swift:84` | `InMemoryDreamingPolicyStore` (struct) `dreaming_cycle.rs:151` | `public` / `pub` | Swift actor / Rust struct (sync, not actor-isolated — sanctioned, policy-store seam) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Dreaming trigger mode | `DreamingTriggerMode` `Dreaming/DreamingTriggerMode.swift:27` | (inline; only `.timer` live) | `public` / — | Swift enum; Rust has no separate trigger-mode type (only timer path live, SPEC § 9) — sanctioned (Rust: daemon is timer-only, no event seam) | `DreamingDaemonTests.swift` | Confirmed |
| Reward source kind | `RewardSourceKind` `Dreaming/RewardSource.swift:31` | `RewardSourceKind` `dreaming_cycle.rs:96` | `public` / `pub` | identical (PascalCase cases; see reward-source sub-table) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Reward source | `RewardSource` `Dreaming/RewardSource.swift:46` | `RewardSource` `dreaming_cycle.rs:188` | `public` / `pub` | Swift protocol / Rust trait; both carry the `kind()` accessor (reward-source sub-table) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Recall-trace reward source | `RecallTraceRewardSource` `Dreaming/RewardSource.swift:62` | `RecallTraceRewardSource` `dreaming_cycle.rs:198` | `public` / `pub` | identical (`used→1.0` else `0.0`) | `RewardSourceTests.swift` ; `dreaming_cycle.rs` rs1/rs2 tests | Confirmed |
| Explicit diary reward source | `ExplicitDiaryRewardSource` `Dreaming/RewardSource.swift:81` | `ExplicitDiaryRewardSource` `dreaming_cycle.rs:225` | `public` / `pub` | Swift has `rewardsByTarget + fallback`; Rust has `rewards_by_target + fallback: Box<dyn RewardSource>`. Precedence: explicit → fallback. | `RewardSourceTests.swift` ; `dreaming_cycle.rs` rs3/rs4/rs5 tests | Confirmed |
| Dreaming substrate reader | `DreamingSubstrateReader` `Dreaming/DreamingDaemon.swift:40` | `DreamingSubstrateReader` `dreaming_cycle.rs:173` | `public` / `pub` | Swift `async` protocol / Rust sync trait (no async runtime — sanctioned seam) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Dreaming proposal sink | `DreamingProposalSink` `Dreaming/DreamingDaemon.swift:70` | `DreamingProposalSink` `dreaming_cycle.rs:216` | `public` / `pub` | Swift `async` protocol / Rust sync trait (sanctioned seam) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Co-occurrence observation | `CoOccurrenceObservation` `Dreaming/DreamingDaemon.swift:81` | `CoOccurrenceObservation` `dreaming_cycle.rs:40` | `public` / `pub` | identical | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Dreaming cycle report | `DreamingCycleReport` `Dreaming/DreamingDaemon.swift:108` | `DreamingCycleReport` `dreaming_cycle.rs:79` | `public` / `pub` | identical | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Dreaming daemon | `DreamingDaemon` (actor) `Dreaming/DreamingDaemon.swift:143` | `DreamingDaemon` (struct) `dreaming_cycle.rs:236` | `public` / `pub` | Swift actor / Rust struct (sync seam, no async runtime — sanctioned) | `DreamingDaemonTests.swift` ; `dreaming_cycle.rs` tests | Confirmed |
| Estate dreaming reader | `EstateDreamingReader` `Dreaming/EstateDreamingReader.swift:31` | `EstateDreamingReader` `estate_dreaming_reader.rs:35` | `public` / `pub` | Swift binds GLK verbs / Rust generic over `DrawerStore` (no estate dep, sanctioned) | `EstateDreamingReaderTests.swift` ; `estate_dreaming_reader.rs` tests | Confirmed |
| Estate dreaming sink | `EstateDreamingSink` `Dreaming/EstateDreamingSink.swift:45` | `EstateDreamingSink<'a>` `estate_dreaming_sink.rs:64` | `public` / `pub` | Swift binds GLK verbs / Rust binds GLK coordinator (B-1 parity) | `EstateDreamingSinkTests.swift` ; `estate_dreaming_sink.rs` tests | Confirmed |
| Dreaming decision core | `DreamingDecision` (enum, nested `Observation`/`EmittedCandidate`/`Outcome`) `Dreaming/DreamingDecision.swift:29` | `dreaming_decision.rs` free fns + flat `Observation`/`EmittedCandidate`/`Outcome` | `public` / `pub` | Swift nests the decision sub-shapes under `DreamingDecision`; Rust declares them flat (`Observation` `:43`, `EmittedCandidate` `:53`, `Outcome` `:64`) — Swift nested X.Y / Rust flat XY | `DreamingDaemonTests.swift` ; `dreaming_decision.rs` tests | Confirmed |
| Dreaming-decision observation | `DreamingDecision.Observation` (nested) | `Observation` `dreaming_decision.rs:43` | `public` / `pub` | Swift nested / Rust flat | `dreaming_decision.rs` tests | Confirmed |
| Dreaming-decision emitted candidate | `DreamingDecision.EmittedCandidate` (nested) | `EmittedCandidate` `dreaming_decision.rs:53` | `public` / `pub` | Swift nested / Rust flat | `dreaming_decision.rs` tests | Confirmed |
| Dreaming-decision outcome | `DreamingDecision.Outcome` (nested) | `Outcome` `dreaming_decision.rs:64` | `public` / `pub` | Swift nested / Rust flat | `dreaming_decision.rs` tests | Confirmed |
| Maintenance policy | `MaintenancePolicy` `Maintenance/MaintenancePolicy.swift:27` | `MaintenancePolicy` `maintenance_cycle.rs:66` | `public` / `pub` | identical (see policy field-completeness sub-table) | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Maintenance policy store | `MaintenancePolicyStore` `Maintenance/MaintenancePolicy.swift:101` | `MaintenancePolicyStore` `maintenance_cycle.rs:108` | `public` / `pub` | Swift `async` protocol / Rust sync trait (sanctioned seam) | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| In-memory maintenance store | `InMemoryMaintenancePolicyStore` (actor) `Maintenance/MaintenancePolicy.swift:114` | `InMemoryMaintenancePolicyStore` (struct) `maintenance_cycle.rs:121` | `public` / `pub` | Swift actor / Rust struct (sync — sanctioned seam) | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Maintenance substrate reader | `MaintenanceSubstrateReader` `Maintenance/MaintenanceSeams.swift:87` | `MaintenanceSubstrateReader` `maintenance_cycle.rs:163` | `public` / `pub` | Swift `async` protocol returning substrate types / Rust sync trait returning `MaintenanceScan` (no estate dep — sanctioned) | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Maintenance proposal sink | `MaintenanceProposalSink` `Maintenance/MaintenanceSeams.swift:125` | `MaintenanceProposalSink` `maintenance_cycle.rs:169` | `public` / `pub` | Swift `async` protocol / Rust sync trait (sanctioned seam) | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Learned-reference observation | `LearnedReferenceObservation` `Maintenance/MaintenanceSeams.swift:38` | (folded into `MaintenanceScan.reference_drift` `DriftRow`) | `public` / `pub` | Swift seam value type read async; Rust folds it into the gathered `MaintenanceScan` (`DriftRow` rows) since it has no estate dep — sanctioned shape idiom | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Fingerprint-drift observation | `FingerprintDriftObservation` `Maintenance/MaintenanceSeams.swift:64` | (folded into `MaintenanceScan.fingerprint_drift` `DriftRow`) | `public` / `pub` | Swift seam value type; Rust folds into `MaintenanceScan` `DriftRow` rows — sanctioned shape idiom | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Maintenance cycle report | `MaintenanceCycleReport` `Maintenance/MaintenanceSeams.swift:141` | `MaintenanceCycleReport` `maintenance_cycle.rs:51` | `public` / `pub` | identical | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Maintenance daemon | `MaintenanceDaemon` (actor) `Maintenance/MaintenanceDaemon.swift:48` | `MaintenanceDaemon` (struct) `maintenance_cycle.rs:194` | `public` / `pub` | Swift actor / Rust struct (sync seam — sanctioned) | `MaintenanceDaemonTests.swift` ; `maintenance_cycle.rs` tests | Confirmed |
| Estate maintenance reader | `EstateMaintenanceReader` `Maintenance/EstateMaintenanceReader.swift:33` | `EstateMaintenanceReader` `estate_maintenance_reader.rs:59` | `public` / `pub` | Swift binds GLK verbs / Rust gathers `MaintenanceScan` (no estate dep — sanctioned) | `EstateMaintenanceReaderTests.swift` ; `estate_maintenance_reader.rs` tests | Confirmed |
| Estate maintenance sink | `EstateMaintenanceSink` `Maintenance/EstateMaintenanceSink.swift:43` | `EstateMaintenanceSink<S>` `estate_maintenance_sink.rs:52` | `public` / `pub` | Swift binds GLK verbs / Rust generic over `DrawerStore` (sanctioned) | `EstateMaintenanceSinkTests.swift` ; `estate_maintenance_sink.rs` tests | Confirmed |
| Maintenance gathered scan | (read via `MaintenanceSubstrateReader` async methods, Swift) | `MaintenanceScan` `maintenance_cycle.rs:147` | — / `pub` | Swift gathers scan inputs across async reader methods returning substrate types; Rust groups them into one `MaintenanceScan` struct (no estate dep) — sanctioned shape idiom | `maintenance_cycle.rs` tests | Confirmed |
| Maintenance decision core | `MaintenanceDecision` (enum, nested `Category`/`Decision`/`AuditVerdict`/`AgedRow`/`DriftRow`/`Outcome`) `Maintenance/MaintenanceDecision.swift:33` | `maintenance_decision.rs` free `decide` + flat sub-types | `public` / `pub` | Swift nests sub-shapes under `MaintenanceDecision`; Rust declares them flat — Swift nested X.Y / Rust flat XY | `MaintenanceDaemonTests.swift` ; `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision category | `MaintenanceDecision.Category` (nested) | `Category` `maintenance_decision.rs:27` | `public` / `pub` | Swift nested / Rust flat | `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision decision | `MaintenanceDecision.Decision` (nested) | `Decision` `maintenance_decision.rs:41` | `public` / `pub` | Swift nested / Rust flat | `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision audit verdict | `MaintenanceDecision.AuditVerdict` (nested) | `AuditVerdict` `maintenance_decision.rs:52` | `public` / `pub` | Swift nested / Rust flat | `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision aged row | `MaintenanceDecision.AgedRow` (nested) | `AgedRow` `maintenance_decision.rs:62` | `public` / `pub` | Swift nested / Rust flat | `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision drift row | `MaintenanceDecision.DriftRow` (nested) | `DriftRow` `maintenance_decision.rs:70` | `public` / `pub` | Swift nested / Rust flat | `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision outcome | `MaintenanceDecision.Outcome` (nested) | `Outcome` `maintenance_decision.rs:79` | `public` / `pub` | Swift nested / Rust flat | `maintenance_decision.rs` tests | Confirmed |
| Maintenance-decision inputs | (flat parameter list of `MaintenanceDecision.decide`, Swift) | `Inputs<'a>` `maintenance_decision.rs:103` | — / `pub` | Swift passes a flat parameter list; Rust groups borrowed params in an `Inputs<'a>` struct for call-site readability — sanctioned Rust idiom | `maintenance_decision.rs` tests | Confirmed |
| Seam: propose-frame out | (Swift `ProposeFrame` from GLK, not NeuronKit-owned) | `ProposeFrameOut` `dreaming_cycle.rs:60` / re-export `maintenance_cycle.rs:31` | — / `pub` | Rust owns a local `ProposeFrameOut` (param of both proposal sinks) because it has no GLK `ProposeFrame` dep — sanctioned; pub because external sink implementors must name it (see seam-helper sub-table) | `dreaming_cycle.rs`/`maintenance_cycle.rs` tests | Confirmed |
| Seam: cycle diary entry | (Swift `DiaryEntry` from GLK, not NeuronKit-owned) | `DreamingDiaryEntry` `dreaming_cycle.rs:69` / `MaintenanceDiaryEntry` `maintenance_cycle.rs:40` | — / `pub` | Rust owns local diary-entry params (no GLK `DiaryEntry` dep) — sanctioned; pub because external sink implementors must name them (seam-helper sub-table) | `dreaming_cycle.rs`/`maintenance_cycle.rs` tests | Confirmed |
| Seam: tunnel link | (Swift `Tunnel` from LocusKit) | `TunnelLink` `dreaming_cycle.rs:51` | — / `pub` | Rust owns a local `TunnelLink` (return of `DreamingSubstrateReader::existing_tunnels`) — no LocusKit `Tunnel` dep, sanctioned; pub for external implementors | `dreaming_cycle.rs` tests | Confirmed |
| Seam: recall-trace item | (Swift `RecallTraceItem` from GLK) | `RecallTraceItem` `dreaming_cycle.rs:32` | — / `pub` | Rust owns a local `RecallTraceItem` (param of `RewardSource::reward`) — sanctioned; pub for external implementors | `dreaming_cycle.rs` tests | Confirmed |
| Solver bandit | `SolverBandit` (`SolverBandit.swift:39`) | `SolverBandit` (`solver_bandit.rs:108`) | both public/pub | identical 4-field struct: `id: String`, `wins: Int`/`u64`, `trials: Int`/`u64`, `prior: Double`/`f64`; Thompson-sampling bandit state for recipe/arm selection; `expectedReward`/`expected_reward` computed property (Beta mean) | `SolverBanditTests.swift` / `solver_bandit.rs #[cfg(test)]` | Confirmed |
| Bandit arm (Rust) | — | `Arm` (`solver_bandit.rs:80`) | — / pub struct | Rust-side named struct grouping a `SolverBandit` and an opaque `name: String`; Swift code handles the (bandit, name) pair inline. The named `Arm` struct is a Rust ergonomics convenience — behaviour is identical, test-bound via solver-bandit parity suite. | `solver_bandit.rs #[cfg(test)]` | **Confirmed (Rust-only named grouping; Swift handles inline)** |
| Moment-signature result | `MomentSignatureResult` (`Lenses/MomentSignature.swift:27`) | `MomentSignatureResult` (`moment_signature.rs:26`) | both public/pub | identical: `bestMatch: WindowRank`/`best_match: WindowRank`, `allMatches: [WindowRank]`/`all_matches: Vec<WindowRank>`, `query: Fingerprint256`/`query: Engram` (same 256-bit type, name idiom) | `MomentSignatureTests.swift` / `lens_conformance.rs` moment-signature cases | Confirmed |
| Window rank | `WindowRank` (`Lenses/MomentSignature.swift:14`) | `WindowRank` (`moment_signature.rs:17`) | both public/pub | identical 3-field struct: `index: Int`/`usize`, `distance: Int`/`i32` (Hamming), `score: Float`/`f32` | `MomentSignatureTests.swift` / `lens_conformance.rs` moment-signature cases | Confirmed |
| Dominant period | `DominantPeriod` (`Lenses/Rhythm.swift:19`) | `DominantPeriod` (`rhythm.rs:16`) | both public/pub | identical 3-field struct: `periodBuckets: Int`/`period_buckets: usize`, `strength: Float`/`f32`, `phaseOffset: Int`/`phase_offset: usize` | `RhythmTests.swift` / `lens_conformance.rs` rhythm cases | Confirmed |
| Complexity result | `ComplexityResult` (`Lenses/Complexity.swift:13`) | `ComplexityResult` (`complexity.rs:17`) | both public/pub | identical 3-field struct: `marginalEntropy: Float`/`marginal_entropy: f32`, `jointEntropy: Float?`/`joint_entropy: Option<f32>`, `mutualInfo: Float?`/`mutual_info: Option<f32>` | `ComplexityTests.swift` / `lens_conformance.rs` complexity cases | Confirmed |
| Calibrated value | `CalibratedValue` (`Lenses/Calibration.swift:17`) | `CalibratedValue` (`calibration_lens.rs:19`) | both public/pub | identical 2-field struct: `raw: Float`/`f32`, `calibrated: Float`/`f32` — one calibrated score from the matrix calibration curve | `CalibrationTests.swift` / `lens_conformance.rs` calibration cases | Confirmed |
| Antecedent rank | `AntecedentRank` (`Lenses/Precedence.swift:14`) | `AntecedentRank` (`precedence.rs:17`) | both public/pub | identical 2-field struct: `id: String`, `score: Float`/`f32` — one ranked antecedent drawer from the temporal-precedence lens | `PrecedenceTests.swift` / `lens_conformance.rs` precedence cases | Confirmed |
| Reduction candidate | `ReductionCandidate` `Reduction/ReductionSignals.swift` | `ReductionCandidate` (`reduction_signals.rs`) | `public` / `pub struct` | Identical shape: dense recall signal + content + coarse rank + precision score. Swift factory: `ReductionCandidate.from(hit:coarseRank:)`; Rust: `from_hit`. Both public in NeuronKit; CognitionKit `PreciseRecall` is the caller, not the definer. | `NeuronKitTests.swift` / `reduction_signals.rs #[cfg(test)]` | Confirmed |
| Reduction query | `ReductionQuery` `Reduction/ReductionSignals.swift` | `ReductionQuery` (`reduction_signals.rs`) | `public` / `pub struct` | Named wrapper for query text + optional lattice anchor passed to the reduction pipeline. Identical fields both ports. Rust adds a `new(text)` constructor; Swift uses memberwise init. | `NeuronKitTests.swift` / `reduction_signals.rs #[cfg(test)]` | Confirmed |
| Reduction signal | `ReductionSignal` `Reduction/ReductionSignals.swift` | `ReductionSignal` (`reduction_signals.rs`) | `public` / `pub enum` | Named enum of signal components (`.text`, `.hamming`, `.matrix`, `.lattice`, `.bm25`, `.vector`, `.dense`, `.tokenExact`, `.temporalState`, `.temporalText`, `.assembly`, `.mmr`). Identical cases both ports. `isSetLevel`/`needsContent` predicates identical. | `NeuronKitTests.swift` / `reduction_signals.rs #[cfg(test)]` | Confirmed |
| Reduction composition | `ReductionComposition` `Reduction/ReductionComposition.swift` | `ReductionComposition` (`reduction_composition.rs`) | `public` / `pub struct` | Named declarative composition: ordered weighted terms + mmrLambda. Identical fields both ports. Swift codable; Rust serde-able. | `NeuronKitTests.swift` / `reduction_composition.rs #[cfg(test)]` | Confirmed |
| Weighted signal | `WeightedSignal` `Reduction/ReductionComposition.swift` | `WeightedSignal` (`reduction_composition.rs`) | `public` / `pub struct` | Both ports have a named `WeightedSignal { signal, weight }` struct. Swift `init(_ signal:weight:)` with weight defaulting to 1.0; Rust `new(signal)` and `weighted(signal, weight)`. Identical semantics. | `NeuronKitTests.swift` / `reduction_composition.rs #[cfg(test)]` | Confirmed |
| QID pending row (Rust maintenance) | — | `QidPendingRow` (`maintenance_cycle.rs:172`) | — / pub struct | Internal Rust struct carrying a pending QueueKit job ID and its enqueue timestamp during maintenance-cycle processing. Swift has no equivalent named type — it threads the ID directly through the `MaintenanceProposalSink` protocol call. Rust names it for grouped `MaintenanceScan` accumulation. | `maintenance_cycle.rs #[cfg(test)]` | **Confirmed (Rust-only named accumulator; concept present both ports as protocol parameter)** |
| Benchmark scoring core | `BenchmarkScoring` (enum, nested `Score`) `BenchmarkScoring.swift` | `BenchmarkScore` (struct) + free `score` fn `benchmark_scoring.rs` | `public` / `pub` | Swift nests the score result under `BenchmarkScoring.Score`; Rust has a flat `BenchmarkScore` and a free `score` function. Pure scoring logic shared; fixture-gated. | `BenchmarkScoringTests.swift` ; `benchmark_scoring.rs` tests | Confirmed |
| Query precision | `NeuronKit.queryPrecision` `Lenses/QueryPrecision.swift` | `query_precision` `query_precision.rs` | `public` / `pub fn` | Identical algorithm: content-word match rate + distinctive-token bonus, clamped to [0, 1]. ASCII-folded tokenisation (`lowercased()`/`to_lowercase()`). Conformance vectors cover the key discriminator cases. | `NeuronKitTests.swift` / `query_precision.rs #[cfg(test)]` | Confirmed |
| Has-distinctive-tokens gate | `NeuronKit.hasDistinctiveTokens` `Lenses/QueryPrecision.swift` | `has_distinctive_tokens` `query_precision.rs` | `public` / `pub fn` | Identical predicate: returns true when query contains a digit-bearing or capitalised (non-stopword) token. Public so `RecipeTools` can apply the gate without re-implementing tokenisation. | `NeuronKitTests.swift` / `query_precision.rs #[cfg(test)]` | Confirmed |
| Containment-satisfied gate | `NeuronKit.containmentSatisfied` `Lenses/QueryPrecision.swift` | `containment_satisfied` `query_precision.rs` | `public` / `pub fn` | Identical: gate passes when query has no distinctive tokens OR at least one candidate contains one. False → suppress results with not_found discrimination. | `NeuronKitTests.swift` / `query_precision.rs #[cfg(test)]` | Confirmed |
| Reduction score | `NeuronKit.reductionScore` `Reduction/ReductionSignals.swift` | `reduction_score` `reduction_signals.rs` | `public` / `pub fn` | Per-candidate score for one `ReductionSignal`, in [0, 1]. Set-level signals return 0.5 (neutral). Total and deterministic. Identical scoring functions both ports; conformance-gated. | `NeuronKitTests.swift` / `reduction_signals.rs #[cfg(test)]` | Confirmed |
| Reduction reduce | `NeuronKit.reduce(composition:query:candidates:limit:)` `Reduction/ReductionComposition.swift` | `reduce` `reduction_composition.rs` | `public` / `pub fn` | Weighted-sum → stable sort → optional MMR → optional assembly → bounded truncate. Deterministic sort tie-breaks: precision desc, content asc, coarse-rank asc. Identical both ports; conformance-gated. | `NeuronKitTests.swift` / `reduction_composition.rs #[cfg(test)]` | Confirmed |
| Reduction reduce-late | `NeuronKit.reduceLate(…hydrate:)` `Reduction/ReductionComposition.swift` | `reduce_late` `reduction_composition.rs` | `public` / `pub fn` | Narrow-then-hydrate path: dense signals score the wide pool body-free; survivors hydrated; full composition re-scores. `DEFAULT_SURVIVOR_MULTIPLE = 8`. Equivalent to `reduce` on pure-content or pure-dense compositions. | `NeuronKitTests.swift` / `reduction_composition.rs #[cfg(test)]` | Confirmed |
| Composition grid | `NeuronKit.CompositionGrid` `Reduction/CompositionGrid.swift` | `composition_grid` module `composition_grid.rs` | `public` / `pub` | Swift namespace enum; Rust free functions (`all()`, `named()`, `names()`, `is_known()`). Same named entries and default ("text"). | `NeuronKitTests.swift` / `composition_grid.rs #[cfg(test)]` | Confirmed |
| Node motion (diffusion) | `NodeMotion` `Lenses/NodeMotion.swift` | `NodeMotion` `diffusion/node_motion.rs` | `public` / `pub struct` | Identical data: `rowID`/`row_id`, `volatility: f64`, `eventCount`/`event_count`, `lastEventPhysicalMs`/`last_event_physical_ms`, `anchorTrajectory`/`anchor_trajectory: Vec<u64>`. Computed: `currentAnchor`, `reanchored`. | `NodeMotionTests.swift` / `diffusion/node_motion.rs #[cfg(test)]` | Confirmed |
| Node anomaly (diffusion) | `NodeAnomaly` `Lenses/NodeMotion.swift` | `NodeAnomaly` `diffusion/node_anomaly.rs` | `public` / `pub struct` | Identical data: `rowID`, `volatility`, `isChurning`/`is_churning`, `reanchored`, `currentAnchor`/`current_anchor`. `isAnomalous`/`is_anomalous()`. | `NodeMotionTests.swift` / `diffusion/node_anomaly.rs #[cfg(test)]` | Confirmed |
| Node-motion fold (pure, both ports) | `NodeMotionLens.fold` `Lenses/NodeMotion.swift` | `fold` `diffusion/node_motion.rs` | `public` / `pub fn` | Pure deterministic fold: HLC-ordered audit entries → `NodeMotion`. Decay weight `exp(-λ·Δt_days)`. HLC dedup keys on full `(physical, logical, node)` triple. 40-bit physical-ms mask for age math (wrap-safe). Identical algorithm both ports. | `NodeMotionTests.swift` / `diffusion/node_motion.rs` | Confirmed |
| Node-anomaly classify (pure, both ports) | `NodeMotionLens.classify` `Lenses/NodeMotion.swift` | `classify` `diffusion/node_anomaly.rs` | `public` / `pub fn` | Pure: classify a `NodeMotion` as churning/reanchored/stable given `churnThreshold`. Identical both ports. | `NodeMotionTests.swift` / `diffusion/node_anomaly.rs` | Confirmed |
| Node-motion estate reader (Swift-only) | `NodeMotionLens.run` / `NodeMotionLens.anomaly` `Lenses/NodeMotion.swift` | — | `public` / — | GLK-bound estate-reading entry points. `run(kit:handle:rowID:now:lambdaPerDay:)` calls `kit.nodeAuditEntries` then `fold`; `anomaly(…)` adds `classify`. Rust has no GLK estate dependency for this module — the pure `fold`/`classify` fns are the Rust surface. | `NodeMotionTests.swift` | Confirmed (Swift-only GLK entry points) |
| Corpus growth probe | `CorpusGrowthProbe` / `EstateCorpusGrowthProbe` `Dreaming/CorpusGrowthProbe.swift` | — | `public` / — | Swift-only: protocol seam + production GLK adapter for dreaming auto-reindex. Rust dreaming daemon has no corpus-reindex seam. `autoReindexVocabGrowthFraction = 0.10`; `autoReindexVocabGrowthFloor = 25`. | `DreamingDaemonTests.swift` | Confirmed (Swift-only) |
| Autonomic governor | `AutonomicGovernor` (actor) `Governor/AutonomicGovernor.swift` | `AutonomicGovernor` (struct) `autonomic_governor.rs` | `public` / `pub` | Swift actor / Rust struct (sync, no async runtime — sanctioned). Both sequence background duties: dreaming, maintenance, graph-centrality, preference, topology snapshots, GC sweeps, pool-reduce. | `AutonomicGovernorTests.swift` / `autonomic_governor.rs #[cfg(test)]` | Confirmed |
| Governor report | `AutonomicGovernor.GovernorReport` `Governor/AutonomicGovernor.swift` | `GovernorReport` `autonomic_governor.rs` | `public` / `pub struct` | Boolean tick-result summary. Swift nests it under `AutonomicGovernor`; Rust declares it flat. Same fields both ports (snake/camel idiom). | `AutonomicGovernorTests.swift` / `autonomic_governor.rs #[cfg(test)]` | Confirmed |
| Topology inputs token (Swift-only) | `TopologyInputsToken` `Governor/AutonomicGovernor.swift` | — | `public` / — | Stable change-detection token: digest over drawer/tunnel/fact counts and max timestamps. Avoids redundant topology recomputes. Swift-only governor surface; Rust governor does not use a token. | `AutonomicGovernorTests.swift` | Confirmed (Swift-only) |
| Graph-centrality cache | `GraphCentralityCache` `Governor/GraphCentralityProducer.swift` | `GraphCentralityCache` `graph_centrality.rs` | `public` / `pub struct` | Read-only `[DrawerID → Float]` centrality score cache produced by `graphCentralityScan` / `compute_centrality_scores`. Identical semantics both ports. | `AutonomicGovernorTests.swift` / `graph_centrality.rs #[cfg(test)]` | Confirmed |
| Graph-centrality adjacency builder | `GraphCentralityAdjacency` `Governor/GraphCentralityProducer.swift` | `CentralityGraph` + `build_centrality_graph` `graph_centrality.rs` | `public` / `pub` | Swift namespace enum with nested `Graph` struct; Rust flat `CentralityGraph` and free `build_centrality_graph` fn. Semantics identical: assembles undirected adjacency over tunnels+kgFacts for centrality computation. `kgFactGroupCap = 50` (Swift constant, Rust constant). | `AutonomicGovernorTests.swift` / `graph_centrality.rs #[cfg(test)]` | Confirmed |
| Preference cache | `PreferenceCache` `Governor/PreferenceProducer.swift` | `PreferenceCache` `preference_producer.rs` | `public` / `pub struct` | Read-only `[DrawerID → Float]` preference score cache produced by `preferenceScan` / `compute_preference_scores`. Identical semantics both ports. | `AutonomicGovernorTests.swift` / `preference_producer.rs #[cfg(test)]` | Confirmed |
| Preference outcomes builder | `PreferenceOutcomes` `Governor/PreferenceProducer.swift` | `PreferenceRecord` + `preference_outcomes` `preference_producer.rs` | `public` / `pub` | Swift namespace enum with `Record` struct and `build(traces:)` static method; Rust flat `PreferenceRecord` and free `preference_outcomes(traces:)`. Aggregates recall-trace endorsements/dismissals per room label. | `AutonomicGovernorTests.swift` / `preference_producer.rs #[cfg(test)]` | Confirmed |

### Policy-store seam

| Swift | Rust | Visibility | Notes |
|---|---|---|---|
| `DreamingPolicyStore` protocol | `DreamingPolicyStore` trait | `pub` | In `dreaming_cycle.rs` |
| `InMemoryDreamingPolicyStore` actor | `InMemoryDreamingPolicyStore` struct | `pub` | In `dreaming_cycle.rs`; not actor-isolated in Rust (sync, no async runtime) |
| `MaintenancePolicyStore` protocol | `MaintenancePolicyStore` trait | `pub` | In `maintenance_cycle.rs` |
| `InMemoryMaintenancePolicyStore` actor | `InMemoryMaintenancePolicyStore` struct | `pub` | In `maintenance_cycle.rs`; same sync/non-actor note |

### Reward-source taxonomy

| Swift | Rust | Visibility | Notes |
|---|---|---|---|
| `RewardSourceKind` enum | `RewardSourceKind` enum | `pub` | `RecallTrace` / `ExplicitDiaryReward` cases; Rust uses PascalCase case names |
| `RewardSource` protocol — `var kind: RewardSourceKind { get }` | `RewardSource` trait — `fn kind(&self) -> RewardSourceKind` | `pub` | Kind accessor present on both legs |
| `RewardSource` protocol — `func reward(for:) -> Float` | `RewardSource` trait — `fn reward(&self, item: &RecallTraceItem) -> f32` | `pub` | |
| `RecallTraceRewardSource` struct | `RecallTraceRewardSource` struct | `pub` | `kind()` returns `RecallTrace`; `used → 1.0` otherwise `0.0` |

### FingerprintBlock enum

| Swift | Rust | Visibility | Notes |
|---|---|---|---|
| `FingerprintBlock` enum — `.structure`, `.concept`, `.temporal`, `.channel` | `FingerprintBlock` enum — `Structure`, `Concept`, `Temporal`, `Channel` | `pub` | In `partial_recall.rs`; Rust raw value same index as BLOCK_* constant |
| `FingerprintBlock.rawValue: Int` | `FingerprintBlock::as_block_index() -> u8` | `pub` | Named accessor; Rust enum `as u8` conversion |
| Swift uses `Set<FingerprintBlock>` | Rust uses `HashSet<u8>` via `as_block_index()` | — | API shape differs; semantics identical |
| `BLOCK_STRUCTURE / CONCEPT / TEMPORAL / CHANNEL` constants | `BLOCK_STRUCTURE / BLOCK_CONCEPT / BLOCK_TEMPORAL / BLOCK_CHANNEL: u8` | `pub` | Constants retained alongside the enum for `HashSet<u8>` construction |

### Seam helper types (pub — cannot demote)

These types are parameters of the seam trait methods. Any external code implementing `DreamingProposalSink`, `MaintenanceProposalSink`, or `DreamingSubstrateReader` must be able to name them. Demotion to `pub(crate)` would break external implementors.

| Type | Module | Why pub |
|---|---|---|
| `ProposeFrameOut` | `dreaming_cycle` | Parameter of `DreamingProposalSink::propose()` |
| `DreamingDiaryEntry` | `dreaming_cycle` | Parameter of `DreamingProposalSink::record_cycle_diary()` |
| `TunnelLink` | `dreaming_cycle` | Return type of `DreamingSubstrateReader::existing_tunnels()` |
| `ProposeFrameOut` (re-exported as `MaintenanceProposeFrameOut`) | `maintenance_cycle` | Parameter of `MaintenanceProposalSink::propose()` |
| `MaintenanceDiaryEntry` | `maintenance_cycle` | Parameter of `MaintenanceProposalSink::record_cycle_diary()` |

### DreamingPolicy / MaintenancePolicy field completeness

The Rust structs carry the same timer fields as Swift:

| Swift field | Rust field | Default |
|---|---|---|
| `DreamingPolicy.tickIntervalMs: Int` | `DreamingPolicy.tick_interval_ms: i64` | `30_000` |
| `MaintenancePolicy.tickIntervalMs: Int` | `MaintenancePolicy.tick_interval_ms: i64` | `300_000` |
| `MaintenancePolicy.auditCheckIntervalMs: Int` | `MaintenancePolicy.audit_check_interval_ms: i64` | `300_000` |

The timer fields are held by the daemon for its tick-elapsed check, and are present on the Rust config struct for store-seam round-trip fidelity.

---

## § 8 — Telemetry interface additions

### Swift: new import

```swift
import IntellectusLib
```

Added to `HybridRecall.swift`, `DreamingDaemon.swift`, and
`BradleyTerry.swift`. No change to any public function signature.

### Swift: new Package.swift dependency

```swift
// Package.swift — NeuronKit target
.product(name: "IntellectusLib", package: "IntellectusLib"),
```

### Rust: new Cargo.toml dependency

```toml
intellectus-lib = { path = "../../../libs/IntellectusLib/rust" }
```

Added to `NeuronKit/rust/Cargo.toml`.

### Emit sites (both ports)

| Function | Language | Metric(s) emitted |
|---|---|---|
| `hybridRecall()` / `hybrid_recall::rerank` | Swift | `neuronkit.recall.latency_ms`, `neuronkit.recall.candidate_count`, `neuronkit.recall.result_count` |
| `DreamingDaemon.runCycle()` / `DreamingDaemon::run_cycle` | Swift + Rust | `neuronkit.dream.cycle` (status=start), `neuronkit.dream.cycle` (status=complete) |
| `bradleyTerry(outcomes:)` / `bradley_terry` | Swift + Rust | `neuronkit.tournament.bt_update`, `neuronkit.tournament.competitor_count` |

Note: `hybridRecall` recall-latency metrics are Swift-only (the Rust
`rerank` function is a pure math function without an `EstateHandle`
in scope). The dreaming cycle and tournament metrics are emitted on
both ports.

### Conformance invariant

`Intellectus.setEnabled(false)` / `Intellectus::set_enabled(false)` is
the off-path gate. When disabled: zero metric emissions, zero
autoclosure evaluation, zero allocation. Algorithm output is
bit-identical on and off (enforced by §5 conformance tests in both
Swift and Rust suites).

---

## § 9 — Swift/Rust Concordance — topology analysis

Pure analysis over plain descriptors; the caller (aria-mcp) performs all
estate I/O. See NEURONKIT_SPEC.md § TOPOLOGY_ANALYSIS for the contract.

### Entry point

```swift
// Swift — Sources/NeuronKit/Lenses/TopologyAnalysis.swift
public static func graphTopology(drawers: [TopologyDrawerInput],
                                 tunnels: [TopologyTunnelInput],
                                 facts: [TopologyFactInput],
                                 estate: String,
                                 now: Date) -> GraphTopology
public static let topologyMaxPasses = 20      // Louvain passes per level
public static let topologyMaxLevels = 10      // phase-2 aggregation levels
public static let topologyResolution = 0.05   // Reichardt–Bornholdt γ (see SPEC § TOPOLOGY_ANALYSIS)
public static let kgFactCliqueCap = 50        // max drawers per KGFact shared-subject clique
```

```rust
// Rust — rust/src/topology_analysis.rs
pub fn graph_topology(drawers: &[TopologyDrawerInput],
                      tunnels: &[TopologyTunnelInput],
                      facts: &[TopologyFactInput],
                      estate: &str,
                      ts: f64) -> GraphTopology;
pub const TOPOLOGY_MAX_PASSES: usize = 20;    // Louvain passes per level
pub const TOPOLOGY_MAX_LEVELS: usize = 10;    // phase-2 aggregation levels
pub const TOPOLOGY_RESOLUTION: f64 = 0.05;    // Reichardt–Bornholdt gamma
pub const KGFACT_CLIQUE_CAP: usize = 50;      // max drawers per KGFact shared-subject clique
pub fn epoch_to_iso8601(secs: i64) -> String; // Rust-only formatting helper
```

### Input descriptors

| Swift | Rust | Notes |
|---|---|---|
| `TopologyDrawerInput { id, udcCode, filedAt: Date, eventTime: Date, tombstoned: Bool, tombstonedAt: Date? }` | `TopologyDrawerInput { id, udc_code, filed_at: i64, event_time: i64, tombstoned: bool, tombstoned_at: Option<i64> }` | caller resolves the dead signal + instant |
| `TopologyTunnelInput { sourceDrawerId: String?, targetDrawerId: String?, filedAt, tombstonedAt }` | `TopologyTunnelInput { source_drawer_id, target_drawer_id, filed_at, tombstoned_at }` | absent endpoint ⇒ no graph contribution |
| `TopologyFactInput { subject, sourceDrawerID }` | `TopologyFactInput { subject, source_drawer_id }` | shared-subject bonding inputs |

### Output types

| Swift | Rust | Wire field names (camelCase JSON at ARIA) |
|---|---|---|
| `GraphTopologyNode { id, communityId: Int, centrality: Double, lastActiveTs: String?, createdTs: String?, tombstonedTs: String?, udcCode: String? }` | `GraphTopologyNode { id, community_id: i64, centrality: f64, last_active_ts, created_ts, tombstoned_ts: Option<String>, udc_code: Option<String> }` | `communityId` -1 = dead sentinel; `udcCode` nil = unanchored (empty-string input normalised to nil; dead nodes retain their code) |
| `GraphTopologyEdge { source, target, edgeType: String, weight: Double, createdTs, tombstonedTs }` | `GraphTopologyEdge { source, target, edge_type: &'static str, weight: f64, created_ts, tombstoned_ts }` | `edgeType` ∈ tunnel, kgFact, lattice |
| `GraphTopologyCommunity { id: Int, size: Int, dominantUdcCode: String }` | `GraphTopologyCommunity { id: i64, size: usize, dominant_udc_code: String }` | live members only |
| `GraphTopology { nodes, edges, communityCount: Int, communities }` | `GraphTopology { nodes, edges, community_count: usize, communities }` | communities sorted size desc, id asc |

### Conformance

Both legs implement identical assembly (live/dead partition, weighted
adjacency 1.0/0.3/0.2, dominant-code tie-breaks, sort orders, lattice star
bonding, adjacency split before EigenvalueCentrality) over the same
SubstrateML primitives. Test suites mirror: Swift
`TopologyAnalysisTests` and Rust `topology_analysis::tests`, including the
`epoch_to_iso8601` known-vector cases and the L-series lattice cases. Both
legs ship; the aria-mcp handler computes real Louvain/centrality.

---

## § Distillation lens

NeuronKit owns the production feature extractor and the thin lens projection
over `DistillationPipeline`. All production callers reach distillation through
these two entry points.

### `hmmFeatureExtractor`

The canonical production `DistillationPipeline.FeatureExtractor`, backed by
the LatticeLib HMM/Viterbi tagger. Byte-identical Swift↔Rust (integer Viterbi,
no float rounding; UAX#29 tokenizer on both sides).

**Swift:**

```swift
// Static closure on NeuronKit — pass as the extractFeatures argument.
NeuronKit.hmmFeatureExtractor: DistillationPipeline.FeatureExtractor
// FeatureExtractor == @Sendable (String, DistillationFeatureType) -> [ExtractedFeature]
```

Extraction rules (same both ports):

- `.entity` (ENT) — tokens tagged `.noun` by the HMM tagger (lowercased).
- `.relation` (REL) — tokens tagged `.verb` by the HMM tagger (lowercased).
- `.numerical` (NUM) — tokens where every byte is an ASCII decimal digit
  (0x30–0x39); pure byte-class scan, no regex.
- `.temporal` (TMP) — 4-digit year tokens (YYYY, all ASCII digits, length 4);
  pure byte-class scan. ISO dates are split by the UAX#29 tokenizer into
  year/month/day tokens; only the year component satisfies the 4-digit check.

`docFrequency` is 0.0 on every emitted feature — the pipeline sets the real
value from the incidence matrix (Stage 2). Callers must not read `docFrequency`
before the pipeline has set it.

**Rust:**

```rust
pub fn hmm_feature_extractor() -> FeatureExtractor
// FeatureExtractor == fn(&str, DistillationFeatureType) -> Vec<ExtractedFeature>
```

### `distillCluster`

Lens projection of `DistillationPipeline.run` into a `DistillationLensResult`.
Uses `hmmFeatureExtractor` as the default extractor; accepts an explicit
`extractFeatures` override for test injection.

**Swift:**

```swift
extension NeuronKit {
    public static func distillCluster(
        input: DistillationInput,
        extractFeatures: DistillationPipeline.FeatureExtractor = NeuronKit.hmmFeatureExtractor
    ) -> DistillationLensResult
}
```

**Rust** (in `distillation.rs`):

```rust
pub fn distill_cluster(
    input: &DistillationInput,
    extract_features: Option<FeatureExtractor>,
) -> DistillationLensResult
// None → hmm_feature_extractor() is used.
```

### `DistillationLensResult`

| Field | Swift type | Rust type | Note |
|---|---|---|---|
| `drawerContent` | `String` | `String` | DIST header content for the factoid drawer |
| `confidence` | `Float32` | `f32` | 0…1; pass-through from pipeline |
| `uncertain` | `Bool` | `bool` | computed; `confidence < 0.7` |
| `snr` | `Float32` | `f32` | structuralSignal / episodicNoise |
| `deltaType` | `String?` | `Option<String>` | pipeline-supplied or nil |
| `succeeded` | `Bool` | `bool` | `true` iff pipeline reached the factoid stage |
| `failureReason` | `String?` | `Option<String>` | set when `succeeded == false` |
| `injectionDepth` | `InjectionDepth` | `InjectionDepth` | see enum below |

### `InjectionDepth`

Three cases keyed on `confidence`:

| Case | Swift | Rust | Threshold |
|---|---|---|---|
| Full factoid only | `.factoidOnly` | `FactoidOnly` | `confidence ≥ 0.7` |
| Factoid + meta | `.factoidWithMeta` | `FactoidWithMeta` | `0.4 ≤ confidence < 0.7` |
| Factoid + provenance | `.factoidWithProvenance` | `FactoidWithProvenance` | `confidence < 0.4` |

---

*End of NeuronKit Interface.*

## Changelog

### 1.5.0 -- 2026-07-16
Audit pass: added all surface items shipped since 1.4.0 that were absent
from the doc. Additions:

- **§ 1 layout** — added `BenchmarkScoring.swift`, `Lenses/NodeMotion.swift`,
  `Lenses/QueryPrecision.swift`, `Dreaming/CorpusGrowthProbe.swift`,
  `Governor/AutonomicGovernor.swift`, `Governor/GraphCentralityProducer.swift`,
  `Governor/PreferenceProducer.swift`, `Reduction/ReductionSignals.swift`,
  `Reduction/ReductionComposition.swift`, `Reduction/CompositionGrid.swift` (Swift);
  `benchmark_scoring.rs`, `query_precision.rs`, `reduction_signals.rs`,
  `reduction_composition.rs`, `composition_grid.rs`, `graph_centrality.rs`,
  `preference_producer.rs`, `autonomic_governor.rs`, `governor_topology_sink.rs`,
  `diffusion/node_motion.rs`, `diffusion/node_anomaly.rs` (Rust).
- **§ 2 types** — `BenchmarkScoring` + nested `Score`; `CorpusGrowthProbe` /
  `EstateCorpusGrowthProbe`; `NodeMotion`, `NodeAnomaly`, `NodeMotionLens`;
  `ReductionCandidate`, `ReductionQuery`, `ReductionSignal`, `WeightedSignal`,
  `ReductionComposition`; `CompositionGrid`; governor types: `AutonomicGovernor`,
  `GovernorReport`, `TopologyInputsToken`, `GraphCentralityCache`,
  `GraphCentralityAdjacency`, `PreferenceCache`, `PreferenceOutcomes`.
- **§ 3 functions** — `NeuronKit.queryPrecision`, `hasDistinctiveTokens`,
  `containmentSatisfied`; `NeuronKit.reductionScore`, `reduce`, `reduceLate`.
- **§ 7 concordance** — corrected rows for Reduction candidate, Reduction query,
  Reduction signal (was misdescribed as a signal vector struct; it is an enum of
  signal-case names), Reduction composition, and Weighted signal (was marked
  Rust-only; Swift also has `WeightedSignal` as a public struct). Added 21 new
  concordance rows covering the diffusion lens, query-precision helpers, reduction
  pipeline functions, composition grid, benchmark scoring, governor types, and
  corpus-growth probe.

### 1.4.0 -- 2026-06-25
Rust dreaming-daemon parity (closes the 1.3.0 port differences). The Rust
`DreamingDaemon` now holds the Thompson-Sampling `SolverBandit` and observes
reward + re-selects the trigger mode each cycle (NEURONKIT_SPEC § 3.4), matching
the Swift Brain algorithm; `DreamingPolicyStore` gains `load_bandit`/`save_bandit`
(default impls) and the manifest store persists the bandit under
`neuronkit.dreaming.bandit`. The Rust `MaintenanceDaemon` now owns the audit-check
cadence (`last_audit_check_epoch_secs` ≡ Swift `lastAuditCheckAt`, gated by
`audit_check_interval_ms`), so `MaintenanceDaemonState` matches the Swift shape.
Both ports are now structurally equal: same daemon algorithms, same persisted
state. (Supersedes the 1.3.0 note about Rust holding no bandit.)

### 1.3.0 -- 2026-06-25
F6 / ADR-020 — manifest-backed daemon persistence. `DreamingPolicyStore` and
`MaintenancePolicyStore` gain `loadDaemonState`/`saveDaemonState` seams (default
no-op) plus the `DreamingDaemonState` / `MaintenanceDaemonState` codable carriers;
new `EstateManifestDreamingPolicyStore` / `EstateManifestMaintenancePolicyStore`
persist policy, bandit (dreaming), and daemon cycle state to the estate manifest
via `Estate.meta/setMeta` (Rust: through `DrawerStore::get_meta/set_meta`). The
production `AutonomicGovernor` wires the manifest-backed stores; daemons load state
on start and save after each cycle, so a restart resumes the prior run's
idempotency/cycle memory. Both ports. (Rust dreaming store is policy+state only —
the Rust dreaming daemon holds no bandit, a pre-existing port difference.)

### 1.2.0 -- 2026-06-22
Rust parity: added `hybrid_recall()` GLK entry point (§4.1, B-1 compliant)
with 3 telemetry metrics. Updated `EstateDreamingSink` parity row — now
`EstateDreamingSink<'a>` binding GLK coordinator (was generic over DrawerStore).
PAR-R5.

### 1.1.0 -- 2026-06-19
Added distillation lens surface: `NeuronKit.hmmFeatureExtractor` (production
HMM-tagger-backed `FeatureExtractor`, both ports), `NeuronKit.distillCluster`
(lens projection with HMM default), `DistillationLensResult`, `InjectionDepth`.
Added §Distillation lens section. Updated §1 package layout for both ports.
Added Rust `src/hmm_feature_extractor.rs` entry. Feat:
feat/distillation-hmm-extractor.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
