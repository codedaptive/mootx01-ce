---
title: CognitionKit Interface
version: 1.5.0
status: active
date: 2026-07-16
description: Public API surface for CognitionKit in both the Swift and Rust ports.
spec_type: kit
authors: MOOTx01 maintainers
relates_to:
  - COGNITIONKIT_SPEC.md
  - NEURONKIT_INTERFACE.md
---

# CognitionKit Interface

Signatures only; behavior is cited to `COGNITIONKIT_SPEC.md`. Where the
Swift and Rust versions diverge in surface shape, both are shown. A recipe
realized in one version and not yet the other is marked — the SPEC requires
both (C-7), so an unmatched signature is a visible gap, not a contract.

## § 1 — Package layout

**Swift:** `packages/kits/CognitionKit/`
- `Sources/CognitionKit/` — public API + implementation
- `Tests/CognitionKitTests/` — conformance tests (swift-testing)
- `Package.swift` — manifest

**Rust:** `packages/kits/CognitionKit/rust/`
- `src/` — public API + implementation, inline `#[cfg(test)]` conformance tests
- `Cargo.toml` — manifest

## § 2 — The Recipe contract (SPEC § 4)

**Swift** — a protocol; each recipe is a conforming type.

```swift
public protocol Recipe: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    var name: String { get }
    var version: String { get }
    var description: String { get }
    var requiredCapabilities: [NeuronKitCapability] { get }

    func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output
}
```

**Rust** — each recipe is a free `run_*` function returning a typed
`Result`; the descriptor metadata lives in the catalog (§ 7). There is no
`Recipe` trait; the function signature is the contract.

## § 3 — Capabilities (SPEC § 4, B-5)

**Swift**

```swift
public enum NeuronKitCapability: String, Sendable, Hashable, CaseIterable, Codable {
    case hybridRecall
    case synthesize
    case deriveBranch
    case promoteBranch
    case benchmark
    case runTournament
    case associationRuleMining
    case formalConceptAnalysis
    case exploratoryRecall      // gates RandomWalks.walkWithRestart (ExploratoryRecall.swift)
}

public let shippedNeuronKitCapabilities: Set<NeuronKitCapability>

public func verifyCapabilities(
    required: [NeuronKitCapability],
    available: Set<NeuronKitCapability> = shippedNeuronKitCapabilities
) throws
```

**Rust**

```rust
pub enum NeuronKitCapability {
    HybridRecall, Synthesize, DeriveBranch, PromoteBranch, Benchmark, RunTournament,
    AssociationRuleMining, FormalConceptAnalysis, ExploratoryRecall,
}
impl NeuronKitCapability { pub fn raw_value(&self) -> &'static str; }

pub fn verify_capabilities(
    required: &[NeuronKitCapability],
    available: &HashSet<NeuronKitCapability>,
) -> Result<(), RecipeError>;
```

`verifyCapabilities` / `verify_capabilities` walks the stable
`CaseIterable` / declaration order and throws `missingCapability` naming
the first absent requirement (deterministic; SPEC § 4, B-5).

## § 4 — Error model (SPEC § 6)

Both ports expose the same three public error types. Both ports expose
`SubstrateError` and `RecipeRunError` as explicit typed wrapper types on
their public surface.

**Swift**

```swift
public enum RecipeError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingCapability(NeuronKitCapability)
    case insufficientBranches(minimum: Int, provided: Int)
    case duplicatePlanName(String)
    case silentConceptLoss(branchID: BranchID, lostConcepts: [String])
    case tournamentNoWinner(disqualifiedCount: Int)
    case userConfirmationRequired(action: String)
    /// More plans than the recipe admits (maximum: 20). Each plan derives a
    /// COW branch and runs concurrent heavy work, so an unbounded count is a
    /// resource-exhaustion vector. Raised before any branch is derived.
    case tooManyPlans(count: Int, maximum: Int)
    /// More origin entries than the recipe admits (maximum: 5000). Each entry
    /// is captured into every branch, making unbounded input O(plans × entries)
    /// work. Raised before any branch is derived.
    case tooManyOriginEntries(count: Int, maximum: Int)

    public var description: String { get }
    public var asRunError: RecipeRunError { get }
}

public struct SubstrateError: Error, Sendable, Equatable, CustomStringConvertible {
    public let operation: String
    public let detail: String
    public init(operation: String, detail: String)
    public var description: String { get }   // "SubstrateError.{operation}: {detail}"
}

public enum RecipeRunError: Error, Sendable, Equatable, CustomStringConvertible {
    case recipe(RecipeError)
    case substrate(SubstrateError)
    public init(_ e: RecipeError)
    public init(_ e: SubstrateError)
    public var recipeError: RecipeError? { get }
    public var substrateError: SubstrateError? { get }
    public var description: String { get }
}
```

**Rust**

```rust
pub enum RecipeError {
    MissingCapability(NeuronKitCapability),
    InsufficientBranches { minimum: i64, provided: i64 },
    DuplicatePlanName(String),
    SilentConceptLoss { branch_id: String, lost_concepts: Vec<String> },
    TournamentNoWinner { disqualified_count: i64 },
    UserConfirmationRequired { action: String },
    /// DoS bound: plans.len() > MAX_MIGRATION_PLANS (20). Raised before any
    /// branch is derived. Mirrors Swift `RecipeError.tooManyPlans`.
    TooManyPlans { count: usize, maximum: usize },
    /// DoS bound: origin.len() > MAX_MIGRATION_ORIGIN_ENTRIES (5000). Raised
    /// before any branch is derived. Mirrors Swift `RecipeError.tooManyOriginEntries`.
    TooManyOriginEntries { count: usize, maximum: usize },
}

/// DoS bounds on attacker-influenceable migration input.
pub const MAX_MIGRATION_PLANS: usize = 20;
pub const MAX_MIGRATION_ORIGIN_ENTRIES: usize = 5000;

pub struct SubstrateError { pub operation: String, pub detail: String }
impl SubstrateError { pub fn new(operation: impl Into<String>, detail: impl Into<String>) -> Self; }

pub enum RecipeRunError {
    Recipe(RecipeError),
    Substrate(SubstrateError),
}
impl From<RecipeError> for RecipeRunError;
impl From<SubstrateError> for RecipeRunError;
```

The `RecipeError` cases (8 total) and their `Display`/`description` strings match
across versions byte-for-byte (SPEC § 6). The `SubstrateError` description
format `"SubstrateError.{operation}: {detail}"` matches across versions.
The `RecipeRunError` description delegates to the inner type unchanged.
The lens recipes return `RecipeRunError` (read-only ⇒ in practice only the
`Substrate` arm or an empty/neutral result); the foundational recipes use
`RecipeError`.

## § 5 — Foundational recipes (SPEC § 4.1)

### Grounded synthesis

**Swift**

```swift
public struct GroundedSynthesis: Recipe {
    public struct Input: Sendable {
        public let frame: RecallFrame
        public let tuning: RecallFrameTuning      // default .default
        public init(frame: RecallFrame, tuning: RecallFrameTuning = .default)
    }
    public struct Output: Sendable {
        public let context: ContextDocument
        public let drawerCount: Int
        public init(context: ContextDocument, drawerCount: Int)
    }
    public init()
    public let name = "grounded_synthesis"
    public let version = "1.0.0"
    public let description: String
    public let requiredCapabilities: [NeuronKitCapability]  // [.hybridRecall, .synthesize]

    public func run(input: Input, estate: EstateHandle, kit: GeniusLocusKit) async throws -> Output
}
```

**Rust** — exposed as `run_grounded_synthesis` returning the synthesized
`ContextDocument` and drawer count (see `grounded_synthesis.rs`); the
descriptor (name/version/description/capabilities) matches the Swift values
byte-for-byte (§ 7).

### Migration benchmark

**Swift** — the orchestration core, estate-agnostic over a
`RecipeSubstrate` seam:

```swift
public enum MigrationOrchestration {
    public struct OriginEntry: Sendable, Equatable { public let id: String; public let content: String }
    public struct PlanInput: Sendable, Equatable {
        public let name: String
        public let room: String
        public let latticeCode: String
        public let embeddingModelID: String
        public let sensitivity: Int
    }
    public struct CorpusEntry: Sendable, Equatable { public let id: String; public let content: String }
    public struct BenchmarkOutcome: Sendable, Equatable {
        public let recallOverlap: Float
        public let meanReciprocalRank: Float
        public let notFound: [String]
    }
    public struct PlanResultCore: Sendable, Equatable {
        public let name: String
        public let branchID: String
        public let recallOverlap: Float
        public let meanReciprocalRank: Float
        public let lost: [String]
    }
    public struct CoreReport: Sendable, Equatable {
        public let planResults: [PlanResultCore]
        public let rankings: [MigrationRanking.RankedPlan]
        public let disqualified: [MigrationRanking.DisqualifiedCore]
        public let winner: String?
    }

    public static func run(
        substrate: RecipeSubstrate,
        plans: [PlanInput],
        origin: [OriginEntry]
    ) throws -> CoreReport
}
```

Throws `insufficientBranches` (empty plans), `tooManyPlans` (plans count
exceeds MAX_MIGRATION_PLANS = 20), or `tooManyOriginEntries` (origin entries
exceed MAX_MIGRATION_ORIGIN_ENTRIES = 5000) before deriving any branch —
these are DoS bounds that protect every caller; throws `duplicatePlanName`
(two plans share a name) after the bounds check; the zero-silent-loss gate
(SPEC C-5) disqualifies a branch whose recall lost an origin concept.

**Rust** — `migration_orchestration.rs` / `migration_ranking.rs` /
`migration_live.rs` mirror the orchestration, ranking, and live-substrate
binding; the catalog descriptor matches the Swift values (§ 7).

## § 6 — Reasoning-lens recipes (SPEC § 4.2)

The twenty lens recipes. **Both ports are authored** (SPEC C-7): the
Rust signatures ship in `packages/kits/CognitionKit/rust/src/*_recipe.rs`
and the Swift versions ship as caseless-`enum` namespaces with a
`public static func run` in `Sources/CognitionKit/*.swift` (each `…Lens`
or bare-name enum; see the concordance below for the per-lens symbol and
test binding). The Rust signatures are reproduced below as the canonical
shape both ports converge on; the Swift entry points mirror them per the
sanctioned Swift-namespace ↔ Rust-free-`run_*`-fn idiom (concordance
naming-pattern note).

Every lens `run_*` takes the estate coordinator and handle, a recall frame
or wing/anchor, lens-specific parameters, and (where it recalls) a `now`;
each returns its reasoning result or a `RecipeRunError` (read-only;
SPEC § 5, I-6).

### Structure (category 1)

```rust
pub fn run_keystones(
    coord: &EstateCoordinator, handle: &EstateHandle,
    wing: &str, top_k: usize,
) -> Result<Vec<Keystone>, RecipeRunError>;          // Keystone from neuron_kit

pub fn run_constellation(
    coord: &EstateCoordinator, handle: &EstateHandle, wing: &str,
) -> Result<Constellation, RecipeRunError>;          // Constellation from neuron_kit

pub struct Association { pub drawer_id: String, pub activation: f64 }
pub fn run_free_association(
    coord: &EstateCoordinator, handle: &EstateHandle,
    wing: &str, seed_drawer_id: &str, walk_length: usize, k: usize,
) -> Result<Vec<Association>, RecipeRunError>;
```

### Topics (category 2)

```rust
pub fn run_latent_themes(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, k: usize, now: i64,
) -> Result<LatentThemes, RecipeRunError>;            // LatentThemes from neuron_kit

pub fn run_theme_weather(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, half_life_seconds: f64, now: i64,
) -> Result<Vec<CategoryMomentum>, RecipeRunError>;   // CategoryMomentum from neuron_kit
```

### Preference (category 4)

```rust
pub struct BiasReport {
    pub biased_for: Vec<CategoryBias>,        // bias > 0, most-favored first
    pub biased_against: Vec<CategoryBias>,    // bias < 0, most-avoided last
    pub dismissal: Vec<(String, f64)>,        // per-parentNodeId withdrawal rate, most-dismissed first
    pub learned: Vec<PreferenceStrength>,     // Bradley-Terry, re-centered on neutral, strongest first
}
pub fn run_bias(
    coord: &EstateCoordinator, handle: &EstateHandle,
    reference: &[(String, f64)], now: i64,
) -> Result<BiasReport, RecipeRunError>;
```

### Surprise (category 5)

```rust
pub struct DriftOutput { pub drift: DriftScore, pub before_count: usize, pub after_count: usize }
pub fn run_drift(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, split_at: i64, now: i64,
) -> Result<DriftOutput, RecipeRunError>;

// Catalog name: "cohesion" (statistical content-cohesion anomaly detection;
// previously catalog-named "contradiction" — renamed to distinguish from the
// explicit KG contradiction lens below).
pub struct ContradictionOutput { pub outliers: Vec<String>, pub considered: usize }
pub fn run_contradiction(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, threshold: f32, now: i64,
) -> Result<ContradictionOutput, RecipeRunError>;
```

**Catalog-only lens entries** (descriptor registered; implementing recipe forthcoming in both ports):

- `cohesion` — "flag the recalled memories whose content cohesion with their peers is anomalously low — the odd-ones-out." (`ContradictionOutput` / `run_contradiction` is the backing implementation registered under this name.)
- `lens_contradiction` — "surface genuine contradictions — drawer pairs linked by a `contradicts` tunnel and KG facts with conflicting objects for the same subject+predicate key."

### Diffusion node layer (ADR-DIFFUSION-001)

**Catalog-only lens entry** (descriptor registered; implementing recipe forthcoming in both ports):

- `node_motion` — "how a single memory has MOVED over time — its mutation volatility (decay-weighted recent-churn mass), its topic trajectory (the UDC anchors it has occupied), whether it reanchored, and a write-time anomaly verdict (churning / reanchored / stable). Reads the memory's fresh audit history."

### Grounding / trust (category 6)

```rust
pub struct TrustGroundedOutput {
    pub context: ContextDocument,
    pub ranked_ids: Vec<String>,                              // most-trusted first
    pub high_trust_count: usize,                             // Canonical or User source type
    pub calibrated_confidences: Option<Vec<CalibratedValue>>, // v1.1.0: present only when curve supplied
}
// v1.1.0: calibration_curve = None → v1.0.0 behaviour (no calibrated confidences).
pub fn run_trust_grounded_synthesis(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, calibration_curve: Option<&MatrixCalibrationCurve>, now: i64,
) -> Result<TrustGroundedOutput, RecipeRunError>;
```

### Associative (category 7)

```rust
pub enum CueMode { FeelsLike, AboutThis, FromThen }
pub struct CueMatch { pub id: String, pub score: f64 }
pub fn run_partial_cue_recall(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, anchor_id: &str, mode: CueMode, k: usize, now: i64,
) -> Result<Vec<CueMatch>, RecipeRunError>;
```

### Prediction (category 8)

```rust
pub fn run_anticipate(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, target_outcome: u8, k: usize, min_observations: u32, now: i64,
) -> Result<Vec<ActionPrediction>, RecipeRunError>;   // ActionPrediction from neuron_kit

pub struct Successor { pub id: String, pub weight: usize }
pub fn run_tunnel_successor(
    coord: &EstateCoordinator, handle: &EstateHandle,
    wing: &str, anchor_id: &str, k: usize,
) -> Result<Vec<Successor>, RecipeRunError>;
```

### Time (category 3) — temporal fingerprint and periodicity

```rust
pub struct MomentOutput {
    pub result: MomentSignatureResult, // from neuron_kit
    pub window_count: usize,
    pub comparison_counts: Vec<usize>,
}
// Pure function — accepts pre-fetched fingerprints (Rust GLK dormant surface gap).
pub fn run_moment(
    window_fingerprints: &[Fingerprint256],
    comparison_fps: &[Vec<Fingerprint256>],
) -> MomentOutput;

pub struct RhythmOutput {
    pub periods: Vec<DominantPeriod>, // from neuron_kit
    pub bucket_count: usize,
}
// Pure function — accepts pre-fetched buckets (Rust GLK dormant surface gap).
pub fn run_rhythm(
    buckets: &[bool], bucket_duration_seconds: f64, top_k: usize,
) -> RhythmOutput;

pub struct PrecedenceOutput {
    pub antecedents: Vec<AntecedentRank>, // from neuron_kit
    pub entry_count: usize,
}
// Pure function — accepts pre-fetched TemporalAuditEntry slice.
pub fn run_precedence(
    entries: &[TemporalAuditEntry], target: &TemporalFieldCoord,
    k: usize, window_minutes: i32,
) -> PrecedenceOutput;
```

Note: the Swift recipes for moment, rhythm, and precedence read their
inputs through GeniusLocusKit (`glkFingerprintsCaptured`,
`glkFingerprintBitSeries`, `glkEventLagPairs`). The Rust recipes accept
pre-fetched data because the Rust `EstateCoordinator` does not yet expose
the corresponding dormant GLK surfaces. This is the same pattern used by
`run_precedence`'s Rust inputs.

### Information-theoretic (category 2 extension)

```rust
pub struct ComplexityOutput {
    pub result: ComplexityResult,  // from neuron_kit: entropy_a, entropy_b?, mutual_information?
    pub total_count: usize,
}
// Recalls via frame; supported field names: "room", "wing", "addedBy", "embeddingModelID".
pub fn run_complexity(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, field_a: &str, field_b: Option<&str>, now: i64,
) -> Result<ComplexityOutput, RecipeRunError>;
```

### Federated (category 9)

```rust
pub struct MindOverlap { pub overlap: f64, pub a_sufficient: bool, pub b_sufficient: bool }
pub fn run_mind_overlap<F: Fn() -> RecallFrame>(
    coord: &EstateCoordinator, handle_a: &EstateHandle, handle_b: &EstateHandle,
    make_frame: F, now: i64,
) -> Result<MindOverlap, RecipeRunError>;

pub struct EstateDivergence { pub divergence: DriftScore, pub a_count: usize, pub b_count: usize }
pub fn run_estate_divergence<F: Fn() -> RecallFrame>(
    coord: &EstateCoordinator, handle_a: &EstateHandle, handle_b: &EstateHandle,
    make_frame: F, now: i64,
) -> Result<EstateDivergence, RecipeRunError>;
```

## § 6a — Distillation-family recipes (SPEC § 4.5)

Three catalog-registered `Recipe`-conforming types that operate on the
distilled memory tier. All declare empty `requiredCapabilities`. The Rust
entry points are synchronous over `EstateCoordinator` (async↔sync seam
sanctioned, same pattern as the live-seam recipes).

### Consolidate

**Swift**

```swift
public struct Consolidate: Recipe {
    public struct Input: Sendable {
        public let clusterID: String?   // accepted no-op; sweep is estate-wide
        public let includeHeld: Bool    // accepted no-op; sweep skips only tombstoned items
        public init(clusterID: String? = nil, includeHeld: Bool = false)
    }
    public struct Output: Sendable {
        public let factoidsProduced: Int
        public init(factoidsProduced: Int)
    }
    public let name = "consolidate"
    public let version = "1.0.0"
    public let description: String
    public let requiredCapabilities: [NeuronKitCapability]  // []
    public init()
    public func run(input: Input, estate: EstateHandle, kit: GeniusLocusKit) async throws -> Output
}
```

**Rust**

```rust
pub struct ConsolidateInput { pub cluster_id: Option<String>, pub include_held: bool }
impl ConsolidateInput { pub fn new() -> Self; }  // defaults: None, false

pub struct ConsolidateOutput { pub factoids_produced: usize }

pub fn run_consolidate(
    _input: &ConsolidateInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    now: i64,
) -> Result<ConsolidateOutput, VerbDispatchError>;
```

`clusterID`/`cluster_id` and `includeHeld`/`include_held` are accepted
no-ops in both ports. The sweep delegates entirely to
`GeniusLocusKit.distillItemsSweep` / `EstateCoordinator::distill_items_sweep`,
which operates estate-wide. Note: Rust returns `VerbDispatchError` (not
`RecipeRunError`) because the sweep cannot surface a recipe-guard error.

### DistilledRecall

**Swift**

```swift
public enum DistilledDiscriminationLevel: Sendable, Equatable {
    case single    // fewer than two results
    case high      // topGap >= 0.25
    case medium    // partial separation
    case low       // effectively unranked
}

public struct DistilledMatch: Sendable, Equatable, Codable {
    public let id: String
    public let prose: String
    public let confidence: Float32
    public let sourceCount: Int
    public let snr: Float32
    public let deltaType: String?
    public let uncertain: Bool
    public let injectionDepth: InjectionDepth
    public init(id: String, prose: String, confidence: Float32, sourceCount: Int,
                snr: Float32, deltaType: String?, uncertain: Bool,
                injectionDepth: InjectionDepth)
}

public struct DistilledRecall: Recipe {
    public struct Input: Sendable {
        public let query: String
        public let filter: LocusKit.Filter   // default .unconfirmed
        public let limit: Int                // default 20
        public let pool: Int                 // default max(limit * 5, 50)
        public init(query: String, filter: LocusKit.Filter = .unconfirmed,
                    limit: Int = 20, pool: Int? = nil)
    }
    public struct Output: Sendable {
        public let matches: [DistilledMatch]
        public let discrimination: DistilledDiscriminationLevel
        public init(matches: [DistilledMatch], discrimination: DistilledDiscriminationLevel)
    }
    public let name = "distilled_recall"
    public let version = "1.0.0"
    public let description: String
    public let requiredCapabilities: [NeuronKitCapability]  // []
    public init()
    public func run(input: Input, estate: EstateHandle, kit: GeniusLocusKit) async throws -> Output
}

public func classifyDistilledDiscrimination(_ scores: [Double]) -> DistilledDiscriminationLevel
// (module-internal in practice; public in Rust for testing parity)
```

**Rust**

```rust
pub enum DistilledDiscriminationLevel { Single, High, Medium, Low }

pub struct DistilledMatch {
    pub id: String, pub prose: String, pub confidence: f32,
    pub source_count: usize, pub snr: f32, pub delta_type: Option<String>,
    pub uncertain: bool, pub injection_depth: InjectionDepth,
}

pub struct DistilledRecallInput {
    pub query: String, pub limit: usize, pub pool: usize, pub filter: Filter,
}
impl DistilledRecallInput {
    pub fn new(query: impl Into<String>) -> Self;
    pub fn with_limit(query: impl Into<String>, limit: usize) -> Self;
    pub fn with_filter(query: impl Into<String>, filter: Filter) -> Self;
}

pub struct DistilledRecallOutput {
    pub matches: Vec<DistilledMatch>,
    pub discrimination: DistilledDiscriminationLevel,
}

pub fn run_distilled_recall(
    input: &DistilledRecallInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    _now: i64,  // accepted for API parity; unused — Hamming NN is clock-free
) -> Result<DistilledRecallOutput, RecipeRunError>;

pub fn classify_distilled_discrimination(scores: &[f64]) -> DistilledDiscriminationLevel;
```

Thresholds: `HIGH_MARGIN = 0.25`, `LOW_MARGIN = 0.05`, `LOW_SPREAD = 0.15`.
These match across ports byte-for-byte.

### Recollect

**Swift**

```swift
public struct ExpandedSource: Sendable, Equatable, Codable {
    public let id: String
    public let room: String
    public let content: String
    public init(id: String, room: String, content: String)
}

public enum RecollectError: Error, Sendable, Equatable {
    case notADistilledDrawer(id: String)
    case factoidNotFound(id: String)
    case noSourceTunnels(id: String)
}

public struct Recollect: Recipe {
    public struct Input: Sendable {
        public let factoidDrawerID: String
        public init(factoidDrawerID: String)
    }
    public struct Output: Sendable {
        public let factoidID: String
        public let prose: String
        public let confidence: Float32
        public let sourceCount: Int
        public let deltaType: String?
        public let sources: [ExpandedSource]
        // No public init — Output is constructed internally by run().
    }
    public let name = "recollect"
    public let version = "1.0.0"
    public let description: String
    public let requiredCapabilities: [NeuronKitCapability]  // []
    public init()
    public func run(input: Input, estate: EstateHandle, kit: GeniusLocusKit) async throws -> Output
}
```

**Rust**

```rust
pub struct ExpandedSource { pub id: String, pub room: String, pub content: String }

pub enum RecollectError {
    FactoidNotFound { id: String },
    NotADistilledDrawer { id: String },
    NoSourceTunnels { id: String },
    VerbDispatch(String),  // propagated VerbDispatchError
}
impl std::fmt::Display for RecollectError;
impl From<VerbDispatchError> for RecollectError;

pub struct RecollectInput { pub factoid_drawer_id: String }
impl RecollectInput { pub fn new(factoid_drawer_id: impl Into<String>) -> Self; }

pub struct RecollectOutput {
    pub factoid_id: String, pub prose: String, pub confidence: f32,
    pub source_count: usize, pub delta_type: Option<String>,
    pub sources: Vec<ExpandedSource>,
}

pub fn run_recollect(
    input: &RecollectInput,
    coord: &EstateCoordinator,
    handle: &EstateHandle,
    _now: i64,  // accepted for API compatibility; by-ids hydration is clock-free
) -> Result<RecollectOutput, RecollectError>;
```

**Swift/Rust parity note for RecollectError:** Swift raises `RecollectError` (3
cases); Rust adds a fourth `VerbDispatch(String)` arm to propagate substrate
I/O errors that Swift surfaces as `throw` (the `async throws` boundary). The
three structural invariant cases match byte-for-byte in their `Display`/
`description` strings. There is no `RecipeRunError` wrapper: the error is
`RecollectError` on both ports.

## § 6b — Dataset analysis utilities (non-catalog)

Standalone analysis namespaces that accept user-supplied column-value rows
from the tool layer (typically fetched from a `DatasetStore`). These are
**not catalog-registered Recipe types** — they have no `run(input:estate:kit:)`
boundary and no capability gate. They are pure stateless functions callable
directly from the tool layer.

### DatasetAssociations

Dataset-targeted twin of the `association_rules` lens: applies the same
`MatrixO` + `mineAssociationRules` path over caller-supplied
`(columnName, value)` row dictionaries instead of Drawer categorical facets.
Label cap: 64 distinct `"columnName:value"` labels (alphabetical overflow).

**Swift**

```swift
public enum DatasetAssociations {
    public struct Output: Sendable {
        public let rules: [AssociationRuleResult]
        public let rowCount: Int
        public let labelOverflow: Bool
        public init(rules: [AssociationRuleResult], rowCount: Int, labelOverflow: Bool)
    }
    public static func run(
        rows: [[String: String]],
        thresholds: MiningThresholds
    ) -> Output
}
```

**Rust**

```rust
pub struct DatasetAssociationsOutput {
    pub rules: Vec<AssociationRuleResult>,
    pub row_count: usize,
    pub label_overflow: bool,
}
pub fn run_dataset_associations(
    rows: &[HashMap<String, String>],
    thresholds: MiningThresholds,
) -> DatasetAssociationsOutput;
```

### DatasetCohesion

Column-value anomaly scorer for dataset rows. Numeric columns use the robust
z-score (`|x - median| / (1.4826 × MAD)`); categorical columns use
information-theoretic rarity (`-log₂(count(v) / total_non_null)`). Row
scores are the sum of per-column signals. Processes up to `scanCap` rows.

**Swift**

```swift
public enum DatasetColumnValue: Sendable, Equatable {
    case numeric(Double)
    case categorical(String)
    case null
}

public struct RowAnomalyScore: Sendable, Equatable {
    public let rowIndex: Int
    public let score: Double
    public init(rowIndex: Int, score: Double)
}

public struct DatasetCohesionOutput: Sendable, Equatable {
    public let topAnomalies: [RowAnomalyScore]  // sorted score desc, rowIndex asc for ties
    public let rowsScored: Int
    public init(topAnomalies: [RowAnomalyScore], rowsScored: Int)
}

public enum DatasetCohesion {
    public static let scanCap: Int  // = 10_000
    public static func run(
        rows: [[DatasetColumnValue]],
        topN: Int = 10,
        maxRows: Int = DatasetCohesion.scanCap
    ) -> DatasetCohesionOutput
}
```

**Rust**

```rust
pub enum DatasetColumnValue { Numeric(f64), Categorical(String), Null }
pub struct RowAnomalyScore { pub row_index: usize, pub score: f64 }
pub struct DatasetCohesionOutput {
    pub top_anomalies: Vec<RowAnomalyScore>,
    pub rows_scored: usize,
}
pub const SCAN_CAP: usize = 10_000;
pub fn run_dataset_cohesion(
    rows: &[Vec<DatasetColumnValue>],
    top_n: usize,
    max_rows: usize,
) -> DatasetCohesionOutput;
```

All arithmetic is `f64` (Double) on both ports. Sort order: score descending,
row index ascending for ties — deterministic across ports.

### DatasetComplexity

Dataset-targeted twin of the `complexity` lens: applies the same
`NeuronKit.complexity` path (Shannon entropy, optional mutual information) over
caller-supplied `[String?]` column-value arrays instead of recalled Drawer
label fields. Null values are excluded from entropy computation.

**Swift**

```swift
public enum DatasetComplexity {
    public struct ColumnEntropyOutput: Sendable, Equatable {
        public let result: ComplexityResult  // entropyA; entropyB+mutualInformation when columnB supplied
        public let nonNullCount: Int         // count of rows where all supplied columns are non-null
        public let nullCount: Int            // rows excluded due to at least one nil value
        public init(result: ComplexityResult, nonNullCount: Int, nullCount: Int)
    }
    public static func runColumn(
        columnA: [String?],
        columnB: [String?]? = nil
    ) -> ColumnEntropyOutput
}
```

**Rust**

```rust
pub struct ColumnEntropyOutput {
    pub result: ComplexityResult,
    pub non_null_count: usize,
    pub null_count: usize,
}
pub fn run_dataset_column_entropy<'a>(
    column_a: &[Option<&'a str>],
    column_b: Option<&[Option<&'a str>]>,
) -> ColumnEntropyOutput;
```

Distinct-value bins are sorted alphabetically on both ports for determinism.
`nonNullCount`/`non_null_count` for the two-column case counts rows where
BOTH columns are non-null.

## § 7 — The catalog (SPEC § 8)

**Swift**

```swift
public struct RecipeDescriptor: Sendable, Equatable, Codable {
    public let name: String
    public let version: String
    public let description: String
    public let requiredCapabilities: [NeuronKitCapability]
}

public enum RecipeCatalog {
    public static var all: [RecipeDescriptor] { get }
    public static func descriptor(named: String) -> RecipeDescriptor?
    public static var names: [String] { get }
}
```

**Rust**

```rust
pub struct RecipeDescriptor {
    pub name: String,
    pub version: String,
    pub description: String,
    pub required_capabilities: Vec<NeuronKitCapability>,   // serde rename: "requiredCapabilities"
}

pub fn recipe_catalog() -> Vec<RecipeDescriptor>;
pub fn recipe_descriptor(name: &str) -> Option<RecipeDescriptor>;
pub fn recipe_names() -> Vec<String>;
```

The descriptor strings and field shape match across versions byte-for-byte
(SPEC § 8, C-8). The catalog lists exactly the recipes present in both
versions; a recipe enters only when both ports land together (SPEC § 8).
Today that is all thirty shipped recipes: the two foundational recipes
**grounded_synthesis** and **migration_benchmark**; the twenty reasoning
lenses (`keystones`, `constellation`, `free_association`, `latent_themes`,
`theme_weather`, `bias`, `drift`, `cohesion`, `lens_contradiction`,
`node_motion`, `trust_grounded_synthesis`, `partial_cue_recall`,
`anticipate`, `tunnel_successor`, `mind_overlap`, `estate_divergence`,
`moment`, `rhythm`, `precedence`, `complexity`); the three
knowledge-discovery recipes `association_rules`, `apriori_rules`, and
`formal_concepts`; the steerable-fusion recipe `shaped_recall`; the
exploratory-recall recipe `recall_exploratory`; and the three
distillation-family recipes `consolidate`, `distilled_recall`, and
`recollect`.

**Catalog-only lens note:** `cohesion`, `lens_contradiction`, and
`node_motion` are registered as descriptors in both versions but their
implementing `Recipe` types are forthcoming. `cohesion` is backed by the
`Contradiction.swift` / `run_contradiction` implementation (the statistical
content-cohesion anomaly detector registered under its new catalog name);
`lens_contradiction` and `node_motion` have no implementing body yet.

---

## Swift/Rust Concordance

One row per public CONCEPT. The Swift column and Rust column each name a
real top-level public symbol. **Shape rule** records how the two ports are
permitted to differ. **Test/vector binding** names the conformance/parity
test that proves Swift == Rust. **Status**: Confirmed (both present +
test-bound) | Exempt (platform binding).

### Naming-pattern note (sanctioned, structural)

CognitionKit uses a deliberate cross-port idiom that recurs in nearly
every row, so it is stated once here rather than repeated:

- **Recipe entry points.** Swift exposes each recipe as a *type with a
  member* — either a `Recipe`-conforming `struct` with an `async throws`
  `run(input:estate:kit:)`, or a caseless `enum` namespace with a
  `public static func run(...)`. Rust exposes each recipe as a *free
  `run_*` function*. There is no `Recipe` trait in Rust; the function
  signature is the contract (§ 2). This Swift-type-namespace ↔
  Rust-free-function shape is the sanctioned recipe idiom and is recorded
  as **Shape rule "Swift enum/struct namespace + run / Rust free run_\*
  fn"** below.
- **async/sync seam.** The live, estate-bound Swift recipes are `async
  throws` over `GeniusLocusKit`; the Rust ports are synchronous over an
  `EstateCoordinator` (no async runtime — sanctioned, cf. NeuronKit
  policy-store seam).
- **camelCase ↔ PascalCase** enum cases, and **ID ↔ Id** idiom
  (`drawerID`/`drawer_id`), are sanctioned and not flagged as drift.

### Core contract, capabilities, errors, catalog

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Recipe contract | `Recipe` protocol (`Recipe.swift:34`) | *(no trait)* — free `run_*` fn convention | Swift public protocol; Rust: convention only | Swift protocol / Rust free-fn convention (§ 2) — sanctioned recipe idiom | `RecipeTests.swift` | Confirmed |
| Capability set | `NeuronKitCapability` enum (`NeuronKitCapability.swift:34`) | `NeuronKitCapability` enum (`capability.rs:19`) | public both | 9 cases; camelCase ↔ PascalCase; `rawValue`/`raw_value` strings match byte-for-byte | `NeuronKitCapabilityTests.swift` + `capability.rs #[cfg(test)]` | Confirmed |
| Shipped capabilities | `shippedNeuronKitCapabilities` let (`NeuronKitCapability.swift:81`) | `shipped_capabilities()` fn (`capability.rs:82`) | public both | Swift constant `Set` / Rust fn returning `Vec` (same membership) | `NeuronKitCapabilityTests.swift` + `capability.rs #[cfg(test)]` | Confirmed |
| Capability verify | `verifyCapabilities(...)` fn (`NeuronKitCapability.swift:93`) | `verify_capabilities(...)` fn (`capability.rs:93`) | public both | Swift `throws` / Rust `Result` — deterministic first-missing order matches | `NeuronKitCapabilityTests.swift` + `capability.rs #[cfg(test)]` | Confirmed |
| Recipe error | `RecipeError` enum (`RecipeError.swift:24`) | `RecipeError` enum (`error.rs:18`) | public both | 8 cases — names, payloads, `description`/`Display` strings match byte-for-byte; includes DoS-guard cases `tooManyPlans`/`TooManyPlans` and `tooManyOriginEntries`/`TooManyOriginEntries` | `RecipeErrorTests.swift` + `error.rs #[cfg(test)]` (case-mirror gate) | Confirmed |
| Substrate error | `SubstrateError` struct (`RecipeRunError.swift:36`) | `SubstrateError` struct (`error.rs:102`) | public both | `operation: String, detail: String`; `"SubstrateError.{op}: {detail}"` | `RecipeRunErrorTests.swift` + `error.rs #[cfg(test)]` | Confirmed |
| Run-error wrapper | `RecipeRunError` enum (`RecipeRunError.swift:70`) | `RecipeRunError` enum (`error.rs:135`) | public both | 2 cases `.recipe`/`.substrate`; Swift `init`+`asRunError`, Rust `From` impls | `RecipeRunErrorTests.swift` (15) + `error.rs #[cfg(test)]` (case-mirror gate) | Confirmed |
| Recipe descriptor | `RecipeDescriptor` struct (`RecipeCatalog.swift:21`) | `RecipeDescriptor` struct (`catalog.rs:20`) | public both | identical fields; Rust serde-renames `required_capabilities`→`requiredCapabilities` | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` | Confirmed |
| Catalog accessors | `RecipeCatalog` enum (`RecipeCatalog.swift:57`) | `recipe_catalog()` / `recipe_descriptor(_)` / `recipe_names()` (`catalog.rs:33,208,214`) | public both | Swift enum-namespace static members / Rust free fns; descriptor strings byte-for-byte | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` | Confirmed |

### Foundational recipes (SPEC § 4.1)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Grounded synthesis | `GroundedSynthesis` struct (`GroundedSynthesis.swift:37`) | `run_grounded_synthesis` fn + `GroundedOutput` struct (`grounded_synthesis.rs:48,39`) | public both | Swift `Recipe` struct (async) + nested `Output` / Rust free fn + flat `GroundedOutput`; descriptor matches | `GroundedSynthesisTests.swift` + `grounded_synthesis.rs #[cfg(test)]` | Confirmed |
| Migration orchestration core | `MigrationOrchestration` enum (`MigrationOrchestration.swift:68`) | `run_migration_benchmark` fn (`migration_orchestration.rs:123`) | public both | Swift enum-namespace `static run` + nested types / Rust free fn + flat types | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Recipe-substrate seam | `RecipeSubstrate` protocol (`MigrationOrchestration.swift:41`) | `RecipeSubstrate` trait (`migration_orchestration.rs:66`) | public both | Swift `AnyObject` protocol / Rust trait — estate-agnostic seam | `MigrationOrchestrationTests.swift` (mock substrate) | Confirmed |
| Origin entry | `MigrationOrchestration.OriginEntry` (`MigrationOrchestration.swift:71`) | `OriginEntry` struct (`migration_orchestration.rs:30`) | public both | Swift nested `MigrationOrchestration.OriginEntry` / Rust flat `OriginEntry` | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Plan input | `MigrationOrchestration.PlanInput` (`MigrationOrchestration.swift:82`) | `PlanInput` struct (`migration_orchestration.rs:37`) | public both | Swift nested / Rust flat; fields match (Swift `sensitivity: Int` ↔ Rust field) | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Corpus entry | `MigrationOrchestration.CorpusEntry` (`MigrationOrchestration.swift:102`) | `CorpusEntry` struct (`migration_orchestration.rs:48`) | public both | Swift nested / Rust flat | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Benchmark outcome | `MigrationOrchestration.BenchmarkOutcome` (`MigrationOrchestration.swift:114`) | `BenchmarkOutcome` struct (`migration_orchestration.rs:56`) | public both | Swift nested / Rust flat; `recallOverlap`/`meanReciprocalRank`/`notFound` | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Plan result (core) | `MigrationOrchestration.PlanResultCore` (`MigrationOrchestration.swift:129`) | `PlanResultCore` struct (`migration_orchestration.rs:95`) | public both | Swift nested / Rust flat | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Core report | `MigrationOrchestration.CoreReport` (`MigrationOrchestration.swift:140`) | `CoreReport` struct (`migration_orchestration.rs:106`) | public both | Swift nested / Rust flat; same field shape | `MigrationOrchestrationTests.swift` + `migration_orchestration.rs #[cfg(test)]` | Confirmed |
| Ranking namespace | `MigrationRanking` enum (`MigrationRanking.swift:22`) | `rank()` / `first_duplicate()` / `lost_concepts()` / `partition_origin()` fns (`migration_ranking.rs:106,57,70,85`) | public both | Swift enum-namespace static members / Rust free fns; **shared-vector gated** | `CognitionVectorConformanceTests.swift` ↔ `rust/tests/cognition_conformance.rs` (`Fixtures/cognition_vectors.json`) | Confirmed |
| Plan outcome | `MigrationRanking.PlanOutcome` (`MigrationRanking.swift:26`) | `PlanOutcome` struct (`migration_ranking.rs:21`) | public both | Swift nested / Rust flat | `CognitionVectorConformanceTests.swift` (shared vectors) | Confirmed |
| Ranked plan | `MigrationRanking.RankedPlan` (`MigrationRanking.swift:47`) | `RankedPlan` struct (`migration_ranking.rs:32`) | public both | Swift nested / Rust flat; `combinedScore` | `CognitionVectorConformanceTests.swift` (shared vectors) | Confirmed |
| Disqualified (core) | `MigrationRanking.DisqualifiedCore` (`MigrationRanking.swift:55`) | `DisqualifiedCore` struct (`migration_ranking.rs:41`) | public both | Swift nested / Rust flat | `CognitionVectorConformanceTests.swift` (shared vectors) | Confirmed |
| Ranking result | `MigrationRanking.Result` (`MigrationRanking.swift:62`) | `RankingResult` struct (`migration_ranking.rs:48`) | public both | Swift nested `Result` / Rust `RankingResult` (rename — `Result` is reserved-by-convention in Rust); same fields | `CognitionVectorConformanceTests.swift` (shared vectors) | Confirmed |

### Migration benchmark — live (GeniusLocusKit-bound) seam

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Live migration recipe | `MigrationBenchmark` struct (`MigrationBenchmark.swift:147`) | `LiveRecipeSubstrate` struct (`migration_live.rs:49`) + `run_migration_benchmark` over it; production entry point `run_migration_benchmark_sqlite` (`migration_live.rs`) opens a durable WAL-mode `SqliteDrawerStore`-backed `EstateCoordinator` — parity with Swift's `MigrationBenchmark.run(input:estate:kit:)` entry shape (same config surface: origin corpus, plans, `now` passed in) | public both | Swift `Recipe` (`async throws` over `GeniusLocusKit`) / Rust sync `LiveRecipeSubstrate` over `EstateCoordinator` (no async runtime — sanctioned live seam) | `MigrationBenchmarkTests.swift` + `migration_live.rs #[cfg(test)]` (InMemory and durable SQLite, including a reopen primitive-decode round-trip) | Confirmed |
| Promotion confirm step | `MigrationBenchmark.confirmPromotion(...)` (`MigrationBenchmark.swift:415,468`) | `confirm_migration_promotion` / `confirm_migration_promotion_by_id` fns (`migration_live.rs:234,180`) | public both | Swift instance method / Rust free fns; gated two-step promote (B-3) | `MigrationBenchmarkTests.swift` + `migration_live.rs #[cfg(test)]` | Confirmed |
| Migration plan (live) | `MigrationPlan` struct (`MigrationBenchmark.swift:56`) | *(folded into `PlanInput`, `migration_orchestration.rs:37`)* | Swift public; Rust: live form folded into core `PlanInput` | Swift carries `AdjectiveSensitivity`/`BranchID`-typed live form; Rust live path reuses core `PlanInput` (sanctioned: Rust has one plan type, Swift splits live vs core) | `MigrationBenchmarkTests.swift` (live) / core vectors | Confirmed |
| Branch ranking (live) | `BranchRanking` struct (`MigrationBenchmark.swift:85`) | *(maps to `RankedPlan`, `migration_ranking.rs:32`)* | Swift public; Rust: `RankedPlan` | Swift live form carries `BranchID`; Rust returns core `RankedPlan` (live/core split is Swift-side, sanctioned) | `MigrationBenchmarkTests.swift` ↔ shared ranking vectors | Confirmed |
| Disqualified plan (live) | `DisqualifiedPlan` struct (`MigrationBenchmark.swift:107`) | *(maps to `DisqualifiedCore`, `migration_ranking.rs:41`)* | Swift public; Rust: `DisqualifiedCore` | Swift live form carries `BranchID`; Rust core `DisqualifiedCore` | `MigrationBenchmarkTests.swift` ↔ shared ranking vectors | Confirmed |
| Comparison report (live) | `MigrationComparisonReport` struct (`MigrationBenchmark.swift:125`) | *(maps to `CoreReport`, `migration_orchestration.rs:106`)* | Swift public; Rust: `CoreReport` | Swift live form (`BranchID` winner) / Rust `CoreReport` (string winner) — live/core split | `MigrationBenchmarkTests.swift` ↔ core vectors | Confirmed |

### Reasoning-lens recipes (SPEC § 4.2)

> NOTE: all twenty lenses are authored in both ports (Swift
> caseless-`enum` namespaces with a `public static func run`; Rust free
> `run_*` fns), as § 6 states. Each row below is read-anchored to both.
> The three catalog-only entries (`cohesion`, `lens_contradiction`,
> `node_motion`) are described in separate concordance rows below.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Keystones (structure) | `Keystones` enum (`Keystones.swift:21`) | `run_keystones` fn (`keystones_recipe.rs:30`) | public both | Swift enum-namespace `static run` / Rust free fn; result `Keystone` from NeuronKit | `KeystonesTests.swift` + `keystones_recipe.rs #[cfg(test)]` | Confirmed |
| Constellation (structure) | `ConstellationLens` enum (`Constellation.swift:22`) | `run_constellation` fn (`constellation_recipe.rs:23`) | public both | Swift `…Lens` namespace / Rust free fn; result `Constellation` from NeuronKit | `ConstellationTests.swift` + `constellation_recipe.rs #[cfg(test)]` | Confirmed |
| Free association (structure) | `FreeAssociationLens` enum (`FreeAssociation.swift:36`) | `run_free_association` fn (`free_association_recipe.rs:44`) | public both | Swift `…Lens` namespace / Rust free fn | `FreeAssociationTests.swift` + `free_association_recipe.rs #[cfg(test)]` | Confirmed |
| Association result | `Association` struct (`FreeAssociation.swift:11`) | `Association` struct (`free_association_recipe.rs:34`) | public both | `drawerID`/`drawer_id` (ID idiom); `activation` | `FreeAssociationTests.swift` + `free_association_recipe.rs #[cfg(test)]` | Confirmed |
| Latent themes (topics) | `LatentThemesLens` enum (`LatentThemes.swift:30`) | `run_latent_themes` fn (`latent_themes_recipe.rs:93`) | public both | Swift `…Lens` namespace / Rust free fn; result `LatentThemes` from NeuronKit | `LatentThemesTests.swift` + `latent_themes_recipe.rs #[cfg(test)]` | Confirmed |
| Theme weather (topics) | `ThemeWeather` enum (`ThemeWeather.swift:15`) | `run_theme_weather` fn (`theme_weather_recipe.rs:22`) | public both | Swift enum-namespace `static run` / Rust free fn; result `CategoryMomentum` from NeuronKit | `ThemeWeatherTests.swift` + `theme_weather_recipe.rs #[cfg(test)]` | Confirmed |
| Bias (preference) | `Bias` enum (`Bias.swift:63`) | `run_bias` fn (`bias_recipe.rs:83`) | public both | Swift enum-namespace `static run` / Rust free fn | `BiasTests.swift` + `bias_recipe.rs #[cfg(test)]` | Confirmed |
| Bias report | `BiasReport` struct (`Bias.swift:18`) | `BiasReport` struct (`bias_recipe.rs:37`) | public both | `biasedFor`/`biased_for` etc. (snake idiom); same fields | `BiasTests.swift` + `bias_recipe.rs #[cfg(test)]` | Confirmed |
| Dismissal rate | `DismissalRate` struct (`Bias.swift:8`) | *(Rust `BiasReport.dismissal: Vec<(String, f64)>`, `bias_recipe.rs:37`)* | Swift public struct; Rust: inline tuple | Swift names the `(nodeId, rate)` pair as a struct (ADR-017: nodeId = parentNodeId); Rust inlines it as a tuple field in `BiasReport` (sanctioned: same data, Swift gives it a nominal type) | `BiasTests.swift` + `bias_recipe.rs #[cfg(test)]` (report parity) | Confirmed |
| Drift (surprise) | `Drift` enum (`Drift.swift:29`) | `run_drift` fn (`drift_recipe.rs:38`) | public both | Swift enum-namespace `static run` / Rust free fn | `DriftTests.swift` + `drift_recipe.rs #[cfg(test)]` | Confirmed |
| Drift output | `DriftOutput` struct (`Drift.swift:7`) | `DriftOutput` struct (`drift_recipe.rs:22`) | public both | `drift: DriftScore`, before/after counts; identical | `DriftTests.swift` + `drift_recipe.rs #[cfg(test)]` | Confirmed |
| Cohesion / contradiction (surprise) | `Contradiction` enum (`Contradiction.swift:28`) | `run_contradiction` fn (`contradiction_recipe.rs:32`) | public both | Swift enum-namespace `static run` / Rust free fn; catalog name `cohesion` (renamed from `contradiction` — statistical shingle-similarity anomaly detection) | `ContradictionTests.swift` + `contradiction_recipe.rs #[cfg(test)]` | Confirmed |
| Contradiction output | `ContradictionOutput` struct (`Contradiction.swift:8`) | `ContradictionOutput` struct (`contradiction_recipe.rs:22`) | public both | `outliers: [String]`, `considered: Int`; identical | `ContradictionTests.swift` + `contradiction_recipe.rs #[cfg(test)]` | Confirmed |
| Cohesion catalog entry | *(literal descriptor in `RecipeCatalog.swift`)* | *(literal descriptor in `catalog.rs`)* | catalog-only both | No dedicated `Recipe` type; backed by `Contradiction`/`run_contradiction`; descriptor registered in both versions | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` (catalog-all count) | Confirmed |
| Lens contradiction catalog entry | *(literal descriptor in `RecipeCatalog.swift`)* | *(literal descriptor in `catalog.rs`)* | catalog-only both | Explicit KG contradiction detection; implementing recipe forthcoming; descriptor registered in both versions | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` (catalog-all count) | Confirmed |
| Node motion catalog entry | *(literal descriptor in `RecipeCatalog.swift`)* | *(literal descriptor in `catalog.rs`)* | catalog-only both | Diffusion node layer; implementing recipe forthcoming; descriptor registered in both versions | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` (catalog-all count) | Confirmed |
| Trust lens (grounding) | `TrustLens` enum (`TrustLens.swift:43`) | `run_trust_grounded_synthesis` fn (`trust_lens_recipe.rs:62`) | public both | Swift enum-namespace `static run` / Rust free fn | `TrustLensTests.swift` + `trust_lens_recipe.rs #[cfg(test)]` | Confirmed |
| Trust output | `TrustGroundedOutput` struct (`TrustLens.swift:9`) | `TrustGroundedOutput` struct (`trust_lens_recipe.rs:31`) | public both | v1.1.0: `context`, `rankedIDs`/`ranked_ids`, `highTrustCount`/`high_trust_count`, `calibratedConfidences`/`calibrated_confidences` (optional) | `TrustLensTests.swift` + `trust_lens_recipe.rs #[cfg(test)]` | Confirmed |
| Partial-cue recall (associative) | `PartialCueRecall` enum (`PartialCueRecall.swift:62`) | `run_partial_cue_recall` fn (`feels_like_recipe.rs:59`) | public both | Swift enum-namespace `static run` / Rust free fn | `PartialCueRecallTests.swift` + `feels_like_recipe.rs #[cfg(test)]` | Confirmed |
| Cue mode | `CueMode` enum (`PartialCueRecall.swift:9`) | `CueMode` enum (`feels_like_recipe.rs:27`) | public both | 3 cases `feelsLike`/`aboutThis`/`fromThen` ↔ `FeelsLike`/`AboutThis`/`FromThen` | `PartialCueRecallTests.swift` + `feels_like_recipe.rs #[cfg(test)]` | Confirmed |
| Cue match | `CueMatch` struct (`PartialCueRecall.swift:28`) | `CueMatch` struct (`feels_like_recipe.rs:50`) | public both | `id: String`, `score: Double/f64`; identical | `PartialCueRecallTests.swift` + `feels_like_recipe.rs #[cfg(test)]` | Confirmed |
| Anchor-not-recalled error | `AnchorNotInRecalledSetError` struct (`PartialCueRecall.swift:41`) | `AnchorNotInRecalledSetError` struct (`error.rs:180`) | public both | Swift `public struct … : Error, Equatable`; Rust `#[derive(Debug, Clone, PartialEq, Eq)]` + `std::error::Error`. Wrapped in `SubstrateError` at the `RecipeRunError` boundary (return type unchanged); `Display` string matches Swift prefix so callers can identify it. | `PartialCueRecallTests.swift` + `error.rs #[cfg(test)]` (4 tests: field, display, equatable, Error impl) | Confirmed |
| Anticipate (prediction) | `Anticipate` enum (`Anticipate.swift:29`) | `run_anticipate` fn (`anticipate_recipe.rs:54`) | public both | Swift enum-namespace `static run` / Rust free fn; result `ActionPrediction` from NeuronKit | `AnticipateTests.swift` + `anticipate_recipe.rs #[cfg(test)]` | Confirmed |
| Tunnel successor (prediction) | `TunnelSuccessor` enum (`TunnelSuccessor.swift:30`) | `run_tunnel_successor` fn (`tunnel_successor_recipe.rs:35`) | public both | Swift enum-namespace `static run` / Rust free fn | `TunnelSuccessorTests.swift` + `tunnel_successor_recipe.rs #[cfg(test)]` | Confirmed |
| Successor result | `Successor` struct (`TunnelSuccessor.swift:6`) | `Successor` struct (`tunnel_successor_recipe.rs:27`) | public both | `id: String`, `weight: Int/usize`; identical | `TunnelSuccessorTests.swift` + `tunnel_successor_recipe.rs #[cfg(test)]` | Confirmed |
| Mind overlap (federated) | `MindOverlapLens` enum (`MindOverlap.swift:44`) | `run_mind_overlap` fn (`mind_overlap_recipe.rs:53`) | public both | Swift `…Lens` namespace / Rust free fn (generic over frame factory) | `MindOverlapTests.swift` + `mind_overlap_recipe.rs #[cfg(test)]` | Confirmed |
| Mind overlap result | `MindOverlap` struct (`MindOverlap.swift:10`) | `MindOverlap` struct (`mind_overlap_recipe.rs:32`) | public both | `overlap`, `aSufficient`/`a_sufficient`, `bSufficient`/`b_sufficient` (k-anonymity flags; exact counts not exposed) | `MindOverlapTests.swift` + `mind_overlap_recipe.rs #[cfg(test)]` | Confirmed |
| Estate divergence (federated) | `EstateDivergenceLens` enum (`EstateDivergence.swift:40`) | `run_estate_divergence` fn (`estate_divergence_recipe.rs:54`) | public both | Swift `…Lens` namespace / Rust free fn | `EstateDivergenceTests.swift` + `estate_divergence_recipe.rs #[cfg(test)]` | Confirmed |
| Estate divergence result | `EstateDivergence` struct (`EstateDivergence.swift:8`) | `EstateDivergence` struct (`estate_divergence_recipe.rs:29`) | public both | `divergence: DriftScore`, `aCount`/`a_count`, `bCount`/`b_count` | `EstateDivergenceTests.swift` + `estate_divergence_recipe.rs #[cfg(test)]` | Confirmed |
| Moment (time) | `Moment` enum (`Moment.swift`) | `run_moment` fn (`moment_recipe.rs`) | public both | Swift reads GLK surface (glkFingerprintsCaptured); Rust accepts pre-fetched `&[Fingerprint256]` slices (GLK dormant surface gap — sanctioned) | `MomentTests.swift` + `moment_recipe.rs #[cfg(test)]` | Confirmed |
| Moment output | `MomentOutput` struct (`Moment.swift`) | `MomentOutput` struct (`moment_recipe.rs`) | public both | `result: MomentSignatureResult`, `windowCount`/`window_count`, `comparisonCounts`/`comparison_counts` | `MomentTests.swift` + `moment_recipe.rs #[cfg(test)]` | Confirmed |
| Rhythm (time) | `Rhythm` enum (`Rhythm.swift`) | `run_rhythm` fn (`rhythm_recipe.rs`) | public both | Swift reads GLK surface (glkFingerprintBitSeries); Rust accepts pre-fetched `&[bool]` (GLK dormant surface gap — sanctioned) | `RhythmTests.swift` + `rhythm_recipe.rs #[cfg(test)]` | Confirmed |
| Rhythm output | `RhythmOutput` struct (`Rhythm.swift`) | `RhythmOutput` struct (`rhythm_recipe.rs`) | public both | `periods: [DominantPeriod]`, `bucketCount`/`bucket_count` | `RhythmTests.swift` + `rhythm_recipe.rs #[cfg(test)]` | Confirmed |
| Precedence (prediction) | `Precedence` enum (`Precedence.swift`) | `run_precedence` fn (`precedence_recipe.rs`) | public both | Swift reads GLK surface (glkEventLagPairs); Rust accepts pre-fetched `&[TemporalAuditEntry]` (GLK dormant surface gap — sanctioned) | `PrecedenceTests.swift` + `precedence_recipe.rs #[cfg(test)]` | Confirmed |
| Precedence output | `PrecedenceOutput` struct (`Precedence.swift`) | `PrecedenceOutput` struct (`precedence_recipe.rs`) | public both | `antecedents: [AntecedentRank]`, `entryCount`/`entry_count` | `PrecedenceTests.swift` + `precedence_recipe.rs #[cfg(test)]` | Confirmed |
| Complexity (topics) | `Complexity` enum (`Complexity.swift`) | `run_complexity` fn (`complexity_recipe.rs`) | public both | Swift: `GeniusLocusKit.recall`; Rust: `EstateCoordinator::recall`. Both identical flow: recall → distribution → NeuronKit.complexity | `ComplexityTests.swift` + `complexity_recipe.rs #[cfg(test)]` | Confirmed |
| Complexity output | `ComplexityOutput` struct (`Complexity.swift`) | `ComplexityOutput` struct (`complexity_recipe.rs`) | public both | `result: ComplexityResult`, `totalCount`/`total_count` | `ComplexityTests.swift` + `complexity_recipe.rs #[cfg(test)]` | Confirmed |

### Knowledge-discovery recipes (association-rule + FCA family)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Association rules recipe | `AssociationRules` struct (`AssociationRules.swift:98`) | `run_association_rules` fn (`association_rules_recipe.rs:94`) | public both | Swift `Recipe` struct (async) + nested `Output` / Rust free fn + `AssociationRulesOutput` | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` | Confirmed |
| Association rule result | `AssociationRuleResult` struct (`AssociationRules.swift:69`) | `AssociationRuleResult` struct (`association_rules_recipe.rs:60`) | public both | identical fields (`support`/`confidence`/`lift`/`conviction`/`leverage`) | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` | Confirmed |
| Association rules output | `AssociationRules.Output` (`AssociationRules.swift:112`) | `AssociationRulesOutput` struct (`association_rules_recipe.rs:74`) | public both | Swift nested `Output` / Rust flat `AssociationRulesOutput`; same fields | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` | Confirmed |
| Apriori rules recipe | `AprioriRules` struct (`AssociationRules.swift:205`) | `run_apriori_rules` fn + `AprioriRulesOutput` struct (`association_rules_recipe.rs`) | public both | Swift `Recipe` struct (async, delegates to `GeniusLocusKit.mineAprioriRules`) / Rust free fn (delegates to `EstateCoordinator::mine_apriori_rules`, which synthesises `RowAuditEntry` from drawer bitmap columns — sanctioned Rust-side adaptation, no in-memory audit log); output preserves engine `AprioriRule` values verbatim | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` (mirror tests) | Confirmed |
| Formal concepts recipe | `FormalConcepts` struct (`FormalConcepts.swift:88`) | `run_formal_concepts` fn (`formal_concepts_recipe.rs:93`) | public both | Swift `Recipe` struct (async) + nested `Output` / Rust free fn + `FormalConceptsOutput` | `FormalConceptsTests.swift` + `formal_concepts_recipe.rs #[cfg(test)]` | Confirmed |
| Formal concept result | `FormalConceptResult` struct (`FormalConcepts.swift:63`) | `FormalConceptResult` struct (`formal_concepts_recipe.rs:67`) | public both | `intent`, `extentDrawerIDs`/extent, `support`, `stability` | `FormalConceptsTests.swift` + `formal_concepts_recipe.rs #[cfg(test)]` | Confirmed |
| Formal concepts output | `FormalConcepts.Output` (`FormalConcepts.swift:117`) | `FormalConceptsOutput` struct (`formal_concepts_recipe.rs:79`) | public both | Swift nested `Output` / Rust flat `FormalConceptsOutput`; same fields | `FormalConceptsTests.swift` + `formal_concepts_recipe.rs #[cfg(test)]` | Confirmed |
| Precise-recall match | `PreciseMatch` (`PreciseRecall.swift:9`) | `PreciseMatch` (`precise_recall.rs:66`) | public both | identical 4-field struct: `id: String`, `room: String`, `content: String`, `score: Double`/`f64` — the ranked result of one precise-recall candidate. Swift camelCase / Rust snake_case fields — idiom. | `CognitionKitTests.swift` (precise-recall suite) / `precise_recall.rs #[cfg(test)]` | Confirmed |
| Precise-recall runner | `PreciseRecall` (`PreciseRecall.swift:66`) | `run_precise_recall` free fn + `DEFAULT_POOL as PRECISE_DEFAULT_POOL` (`precise_recall.rs:82`) | Swift public caseless-enum namespace / Rust pub free fn | Swift caseless-enum namespace `PreciseRecall.run(kit:handle:query:filter:limit:pool:composition:)` (async throws) / Rust free `run_precise_recall(coord, query, filter, limit, pool, composition)` (sync Result) — sanctioned recipe idiom: Swift-type-namespace ↔ Rust-free-run_*-fn; async↔sync seam. `defaultPool`/`DEFAULT_POOL` = 30 on both ports. | `CognitionKitTests.swift` / `precise_recall.rs #[cfg(test)]` | **Confirmed (swift enum namespace / Rust free-fn idiom)** |
| Shaped-recall recipe | `ShapedRecall` struct (`ShapedRecall.swift`) | `run_shaped_recall` free fn + `ShapedRecallOutput` struct (`shaped_recall.rs`) | public both | Swift `Recipe` struct (async) `ShapedRecall().run(input:estate:kit:)` with nested `Input` (query/preset/filter/limit) + `Output` (matches/appliedPreset) / Rust free `run_shaped_recall(coord, handle, query, preset, filter, limit, now)` (sync Result) returning `ShapedRecallOutput`. Resolves a named GLK `RecallShape.preset` and runs `.unionBest`/`.matrixAware` recall with it; `"balanced"`/unknown ⇒ unsteered. Reuses `PreciseMatch` for matches. Registered as `shaped_recall` in the catalog. | `ShapedRecallTests.swift` / `shaped_recall.rs #[cfg(test)]` | Confirmed |
| Exploratory-recall recipe | `ExploratoryRecall` struct (`ExploratoryRecall.swift`) | `run_exploratory_recall` free fn + `ExploratoryRecallOutput` struct (`exploratory_recall_recipe.rs`) | public both | Swift `Recipe` struct (async) with nested `Input` (wing/seedDrawerID/steps/restartProbability/k) + `Output` (results/visitedCount) / Rust free `run_exploratory_recall(coord, handle, wing, seed_drawer_id, steps, restart_probability, k)` (sync Result) returning `ExploratoryRecallOutput`. Both build a RowId adjacency from the tunnel graph, derive the RNG seed via FNV hash64, and delegate to `SubstrateML.RandomWalks.walkWithRestart`/`walk_with_restart`. Excludes seed from results; k=0 returns all. Declares `exploratoryRecall` capability. | `ExploratoryRecallTests.swift` (7 tests) / `exploratory_recall_recipe.rs #[cfg(test)]` (7 tests, CK-ER-1..7) | Confirmed |
| Exploratory result | `ExploratoryResult` struct (`ExploratoryRecall.swift`) | `ExploratoryResult` struct (`exploratory_recall_recipe.rs`) | public both | `drawerID`/`drawer_id`: UUID string; `visitCount`/`visit_count`: Int/u64 — visit count for that drawer. Sorted descending by visit count, then ascending by drawer id (stable tie-break, cross-version identical). | `ExploratoryRecallTests.swift` + `exploratory_recall_recipe.rs #[cfg(test)]` | Confirmed |

### Distillation-family recipes (SPEC § 4.5)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Consolidate recipe | `Consolidate` struct (`Consolidate.swift:31`) | `run_consolidate` fn + `ConsolidateInput`/`ConsolidateOutput` structs (`consolidate.rs`) | public both | Swift `Recipe` struct (async) / Rust free fn (sync). `clusterID`/`cluster_id` and `includeHeld`/`include_held` are no-ops on both ports (API-stability parameters). Rust error type is `VerbDispatchError` (not `RecipeRunError`) — no recipe-guard error possible. | `ConsolidateTests.swift` + `consolidate.rs #[cfg(test)]` | Confirmed |
| Consolidate input | `Consolidate.Input` (`Consolidate.swift:36`) | `ConsolidateInput` struct (`consolidate.rs`) | public both | Swift nested / Rust flat; `clusterID`/`cluster_id` (Optional String), `includeHeld`/`include_held` (Bool/bool) | `ConsolidateTests.swift` + `consolidate.rs #[cfg(test)]` | Confirmed |
| Consolidate output | `Consolidate.Output` (`Consolidate.swift:73`) | `ConsolidateOutput` struct (`consolidate.rs`) | public both | `factoidsProduced`/`factoids_produced`: Int/usize — count of factoid drawers produced | `ConsolidateTests.swift` + `consolidate.rs #[cfg(test)]` | Confirmed |
| Distilled discrimination level | `DistilledDiscriminationLevel` enum (`DistilledRecall.swift:36`) | `DistilledDiscriminationLevel` enum (`distilled_recall.rs:49`) | public both | 4 cases `single/Single`, `high/High`, `medium/Medium`, `low/Low`; same thresholds (HIGH_MARGIN=0.25, LOW_MARGIN=0.05, LOW_SPREAD=0.15) | `DistilledRecallTests.swift` + `distilled_recall.rs #[cfg(test)]` | Confirmed |
| Distilled match | `DistilledMatch` struct (`DistilledRecall.swift:48`) | `DistilledMatch` struct (`distilled_recall.rs:64`) | public both | `id`, `prose`, `confidence: Float32/f32`, `sourceCount`/`source_count`, `snr`, `deltaType`/`delta_type` (Optional String), `uncertain`, `injectionDepth`/`injection_depth: InjectionDepth`. Swift additionally conforms to `Codable` (InjectionDepth serialised as raw String name). | `DistilledRecallTests.swift` + `distilled_recall.rs #[cfg(test)]` | Confirmed |
| DistilledRecall recipe | `DistilledRecall` struct (`DistilledRecall.swift:142`) | `run_distilled_recall` fn + `DistilledRecallInput`/`DistilledRecallOutput` structs (`distilled_recall.rs`) | public both | Swift `Recipe` struct (async) / Rust free fn (sync; `_now` accepted for API parity, unused). Discrimination classifier also public in Rust (`classify_distilled_discrimination`). | `DistilledRecallTests.swift` + `distilled_recall.rs #[cfg(test)]` | Confirmed |
| Expanded source | `ExpandedSource` struct (`Recollect.swift:23`) | `ExpandedSource` struct (`recollect.rs:56`) | public both | `id: String`, `room: String`, `content: String`; identical. Swift additionally conforms to `Codable`. | `RecollectTests.swift` + `recollect.rs #[cfg(test)]` | Confirmed |
| Recollect error | `RecollectError` enum (`Recollect.swift:41`) | `RecollectError` enum (`recollect.rs:74`) | public both | Swift: 3 cases (`notADistilledDrawer(id:)`, `factoidNotFound(id:)`, `noSourceTunnels(id:)`). Rust: same 3 structural cases (named fields) + `VerbDispatch(String)` arm for substrate I/O errors (the `async throws` boundary absorbs these in Swift). `Display`/`description` strings match for the 3 structural cases. | `RecollectTests.swift` + `recollect.rs #[cfg(test)]` | Confirmed |
| Recollect recipe | `Recollect` struct (`Recollect.swift:69`) | `run_recollect` fn + `RecollectInput`/`RecollectOutput` structs (`recollect.rs`) | public both | Swift `Recipe` struct (async throws `RecollectError`) / Rust free fn (`Result<RecollectOutput, RecollectError>`; `_now` accepted for API compatibility, unused). Output fields: `factoidID`/`factoid_id`, `prose`, `confidence`, `sourceCount`/`source_count`, `deltaType`/`delta_type`, `sources: [ExpandedSource]`. | `RecollectTests.swift` + `recollect.rs #[cfg(test)]` | Confirmed |

### Dataset analysis utilities (non-catalog, SPEC § 4b)

Not `Recipe`-conforming. No catalog entry. No capability gate. Pure stateless
functions intended to be called directly from the tool layer with
pre-fetched dataset column data.

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Dataset associations | `DatasetAssociations` enum (`DatasetAssociations.swift:32`) | `run_dataset_associations` fn + `DatasetAssociationsOutput` struct (`dataset_associations.rs`) | public both | Swift caseless-enum namespace `static run` / Rust free fn. Input: `rows: [[String:String]]` / `rows: &[HashMap<String,String>]`. Label cap 64. Output: `rules: [AssociationRuleResult]`, `rowCount`/`row_count`, `labelOverflow`/`label_overflow`. | `DatasetAssociationsTests.swift` + `dataset_associations.rs #[cfg(test)]` | Confirmed |
| Dataset cohesion column value | `DatasetColumnValue` enum (`DatasetCohesion.swift:9`) | `DatasetColumnValue` enum (`dataset_cohesion.rs`) | public both | 3 cases `numeric(Double/f64)`, `categorical(String)`, `null/Null`; identical | `DatasetCohesionTests.swift` + `dataset_cohesion.rs #[cfg(test)]` | Confirmed |
| Row anomaly score | `RowAnomalyScore` struct (`DatasetCohesion.swift:19`) | `RowAnomalyScore` struct (`dataset_cohesion.rs`) | public both | `rowIndex`/`row_index: Int/usize`, `score: Double/f64`; identical. Sort: score desc, index asc for ties — deterministic across ports. | `DatasetCohesionTests.swift` + `dataset_cohesion.rs #[cfg(test)]` | Confirmed |
| Dataset cohesion output | `DatasetCohesionOutput` struct (`DatasetCohesion.swift:32`) | `DatasetCohesionOutput` struct (`dataset_cohesion.rs`) | public both | `topAnomalies`/`top_anomalies`, `rowsScored`/`rows_scored: Int/usize` | `DatasetCohesionTests.swift` + `dataset_cohesion.rs #[cfg(test)]` | Confirmed |
| Dataset cohesion scorer | `DatasetCohesion` enum (`DatasetCohesion.swift:92`) | `run_dataset_cohesion` fn + `SCAN_CAP: usize` (`dataset_cohesion.rs`) | public both | Swift caseless-enum namespace; Rust free fn + constant. `scanCap`/`SCAN_CAP = 10_000`. All arithmetic f64/Double — no Float32. | `DatasetCohesionTests.swift` + `dataset_cohesion.rs #[cfg(test)]` | Confirmed |
| Column entropy output | `DatasetComplexity.ColumnEntropyOutput` struct (`DatasetComplexity.swift:29`) | `ColumnEntropyOutput` struct (`dataset_complexity.rs`) | public both | `result: ComplexityResult`, `nonNullCount`/`non_null_count`, `nullCount`/`null_count: Int/usize`. Swift nested / Rust flat. | `DatasetComplexityTests.swift` + `dataset_complexity.rs #[cfg(test)]` | Confirmed |
| Dataset column entropy | `DatasetComplexity` enum (`DatasetComplexity.swift:26`) | `run_dataset_column_entropy` fn (`dataset_complexity.rs`) | public both | Swift caseless-enum namespace `static runColumn(columnA:columnB:)` / Rust free `run_dataset_column_entropy<'a>(column_a, column_b)`. Input: `[String?]` / `&[Option<&str>]`. Two-column case: `nullCount` counts rows where EITHER column is nil. Bins sorted alphabetically for determinism. | `DatasetComplexityTests.swift` + `dataset_complexity.rs #[cfg(test)]` | Confirmed |

### Shared-vector conformance artifact

The migration-ranking family is gated against a **shared JSON artifact**:
`Tests/CognitionKitTests/Fixtures/cognition_vectors.json` is read by both
`CognitionVectorConformanceTests.swift` and
`rust/tests/cognition_conformance.rs`, so the two ports are checked
against the same inputs and expected outputs (not merely against each
other).

## § 8 — Telemetry API (SPEC § 11)

CognitionKit emits self-report metrics through IntellectusLib. The emit API
is internal to each recipe — callers do not invoke it directly.

### Swift

```swift
// CognitionKitTelemetry.swift (module-internal)
public enum CognitionKitMetrics {
    /// Stable metric name for recipe-run activity.
    public static let recipeRun = "cognitionkit.recipe.run"
}

// Module-internal helpers — not part of the public API.
@inline(__always)
func emitRecipeStart(name: String, ts: Double)

@inline(__always)
func emitRecipeComplete(name: String, stepCount: Int, ts: Double)
```

Both helpers call `Intellectus.report(.metric(...))`. When
`Intellectus.isEnabled` is false, the `@autoclosure` argument is never
evaluated: off-path cost is a single atomic load plus branch.

### Rust

```rust
// grounded_synthesis.rs (pub(crate))
pub(crate) const METRIC_RECIPE_RUN: &str = "cognitionkit.recipe.run";

pub(crate) fn emit_recipe_start(recipe: &str, ts: f64)
pub(crate) fn emit_recipe_complete(recipe: &str, step_count: usize, ts: f64)

// migration_orchestration.rs (module-private)
fn emit_recipe_start_mb(ts: f64)
fn emit_recipe_complete_mb(step_count: usize, ts: f64)
```

All helpers call the `report!` macro which short-circuits when monitoring is
disabled.

### Emit sites

| Recipe | Language | Start placement | Complete placement |
|---|---|---|---|
| GroundedSynthesis | Swift | After `verifyCapabilities` | Before `return Output(...)` |
| GroundedSynthesis | Rust | After `verify_capabilities(...)` | Before `Ok(GroundedOutput { ... })` |
| MigrationBenchmark | Swift | After `guard !input.plans.isEmpty` + `firstDuplicate` checks | Before `return Output(...)` |
| MigrationBenchmark | Rust | After `first_duplicate` check | Before `Ok(CoreReport { ... })` |

### Swift/Rust concordance for telemetry

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| Metric name constant | `CognitionKitMetrics.recipeRun` | `METRIC_RECIPE_RUN` | Same string value |
| Start emit helper | `emitRecipeStart(name:ts:)` | `emit_recipe_start(recipe, ts)` | Internal/pub(crate) |
| Complete emit helper | `emitRecipeComplete(name:stepCount:ts:)` | `emit_recipe_complete(recipe, step_count, ts)` | Internal/pub(crate) |
| GroundedSynthesis step_count | `allRows.count` (drawer count) | `drawer_count` (recalled drawer count) | Parity: same value |
| MigrationBenchmark step_count | `input.plans.count` | `plans.len()` | Parity: same value |

---

*End of CognitionKit Interface.*

## Changelog

### 1.5.0 -- 2026-07-16
Closed two missing RecipeError cases in both ports (verifier gap):

- § 4 Swift `RecipeError`: added `tooManyPlans(count: Int, maximum: Int)` and
  `tooManyOriginEntries(count: Int, maximum: Int)` (cases 7 and 8); both were
  present in `RecipeError.swift:63,69` but absent from the doc.
- § 4 Rust `RecipeError`: added `TooManyPlans { count: usize, maximum: usize }` and
  `TooManyOriginEntries { count: usize, maximum: usize }` (cases 7 and 8); added
  public constants `MAX_MIGRATION_PLANS = 20` and `MAX_MIGRATION_ORIGIN_ENTRIES = 5000`
  (`error.rs:65-66`).
- § 4 prose note: updated case count reference from 6 to 8.
- § 5 migration benchmark throws description: added `tooManyPlans` and
  `tooManyOriginEntries` guards (DoS bounds) to the guard sequence, placed before
  `duplicatePlanName` to match the enforcement order in `migration_orchestration.rs`.
- Concordance table "Recipe error" row: updated "6 cases" to "8 cases" and named the
  two new DoS-guard cases.

### 1.4.0 -- 2026-07-16
Additive audit (MX-TAB dataset series + distillation-family + new lenses):

- § 6 header updated: "eighteen" → "twenty" reasoning-lens recipes.
- § 6 Surprise: updated `contradiction` entry to reflect catalog rename to
  `cohesion`; added `lens_contradiction` and `node_motion` as catalog-only
  lens entries (descriptor registered, implementing recipe forthcoming in both
  ports).
- Added § 6a — Distillation-family recipes: full Swift/Rust signatures for
  `Consolidate`, `DistilledRecall` (with `DistilledDiscriminationLevel` and
  `DistilledMatch`), and `Recollect` (with `ExpandedSource` and
  `RecollectError`). Notes the `VerbDispatchError` vs `RecipeRunError`
  difference in `run_consolidate`, and the extra `VerbDispatch` arm in
  Rust's `RecollectError`.
- Added § 6b — Dataset analysis utilities: full Swift/Rust signatures for
  `DatasetAssociations`, `DatasetCohesion` (with `DatasetColumnValue`,
  `RowAnomalyScore`, `DatasetCohesionOutput`), and `DatasetComplexity`
  (with `ColumnEntropyOutput`). Noted as non-catalog, non-Recipe utilities.
- § 7 catalog count updated: 25 → 30; full catalog listing updated.
  Added catalog-only lens note.
- Concordance tables: updated `contradiction` row (catalog name now `cohesion`);
  added rows for `cohesion`, `lens_contradiction`, and `node_motion` catalog
  entries; added distillation-family concordance section (7 new rows);
  added dataset analysis utilities concordance section (7 new rows).

### 1.3.0 -- 2026-06-21
ADR-017 native node ID migration (NT-K1): renamed `DismissalRate.room` →
`DismissalRate.nodeId` (Swift struct field, `Bias.swift:9`). The field now
carries the parentNodeId UUID (room node in the containment tree) rather than
a display room name. Updated concordance row for DismissalRate (§ 5, row 589).
Rust port uses inline tuple `(String, f64)` — unaffected by field rename.

### 1.2.0 -- 2026-06-17
Additive (A-2 exploratory-recall): added `exploratoryRecall` to the capability enum
(§ 3, 8→9 cases) in both ports. Added the `recall_exploratory` recipe (both ports):
Swift `ExploratoryRecall: Recipe` with nested `Input`/`Output` + `ExploratoryResult`;
Rust `run_exploratory_recall` + `ExploratoryRecallOutput` + `ExploratoryResult`. Both
build a RowId adjacency from the tunnel graph and delegate to
`RandomWalks.walkWithRestart`/`walk_with_restart`; RNG seed derived via FNV hash64.
Added concordance rows for the recipe and its result type. Updated catalog count
(24→25) and added `recall_exploratory` to the catalog prose.

### 1.1.0 -- 2026-06-17
Additive (GLK-RECALL-SHAPE-PRESETS): new `ShapedRecall` recipe (both ports) — a
single parameterized recall recipe driven by a named GLK `RecallShape` preset
(`shaped_recall` in the catalog). Swift `ShapedRecall: Recipe` with nested
`Input` (query/preset/filter/limit) and `Output` (matches/appliedPreset); Rust
`run_shaped_recall` returning `ShapedRecallOutput`. Resolves the preset to its
signed-weight shape via `RecallShape.preset` and runs `.unionBest`/`.matrixAware`
recall with it; `"balanced"` (and any unknown name) runs unsteered, byte-identical
to today's `.unionBest`. Reuses `PreciseMatch` as the per-match result. The catalog
gains one entry (`shaped_recall`), shifting the count to 24. Conformance:
`ShapedRecallTests.swift` / `shaped_recall.rs #[cfg(test)]` + the catalog parity
tests.

### 1.0.0 -- 2026-06-14
Established under VERSIONING.md: version number removed from the filename; front matter normalized; baselined at 1.0.0.
