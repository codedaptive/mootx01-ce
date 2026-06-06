---
status: draft
authors: Bob Pankratz (via Skippy)
date: 2026-06-01
version: v0.85
supersedes: COGNITIONKIT_INTERFACE_v0.1.md
package: CognitionKit
languages: [swift, rust]
relates_to:
  - COGNITIONKIT_SPEC_v0.85.md  (the behavioral contract these signatures satisfy)
  - NEURONKIT_INTERFACE_v0.85.md  (the reasoning surface every recipe sequences)
purpose: |
  Public API surface of CognitionKit: the Recipe contract, the capability
  set, the recipe-error model, the foundational recipes, the fourteen
  reasoning-lens recipes, and the catalog. Type signatures and member
  shapes per version. Behavioral promises live in the SPEC and are cited
  by section.
---

# CognitionKit Interface

Signatures only; behavior is cited to `COGNITIONKIT_SPEC_v0.85`. Where the
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

Both ports expose the same three public error types. The Rust port was the
richer surface; the Swift port gained `SubstrateError` and `RecipeRunError`
via the force-mirror ruling (code-parity Phase-0, 2026-06-05). The prior
note "Swift uses propagated `throws`" is **SUPERSEDED** by the force-mirror
ruling — Swift now exposes explicit typed wrapper types on its public surface.

**Swift**

```swift
public enum RecipeError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingCapability(NeuronKitCapability)
    case insufficientBranches(minimum: Int, provided: Int)
    case duplicatePlanName(String)
    case silentConceptLoss(branchID: BranchID, lostConcepts: [String])
    case tournamentNoWinner(disqualifiedCount: Int)
    case userConfirmationRequired(action: String)

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
}

pub struct SubstrateError { pub operation: String, pub detail: String }
impl SubstrateError { pub fn new(operation: impl Into<String>, detail: impl Into<String>) -> Self; }

pub enum RecipeRunError {
    Recipe(RecipeError),
    Substrate(SubstrateError),
}
impl From<RecipeError> for RecipeRunError;
impl From<SubstrateError> for RecipeRunError;
```

The `RecipeError` cases and their `Display`/`description` strings match
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

Throws `duplicatePlanName` (two plans share a name) and
`insufficientBranches` (empty plans) before deriving any branch; the
zero-silent-loss gate (SPEC C-5) disqualifies a branch whose recall lost an
origin concept.

**Rust** — `migration_orchestration.rs` / `migration_ranking.rs` /
`migration_live.rs` mirror the orchestration, ranking, and live-substrate
binding; the catalog descriptor matches the Swift values (§ 7).

## § 6 — Reasoning-lens recipes (SPEC § 4.2)

The fourteen lens recipes. **Rust signatures are shipped** in
`packages/kits/CognitionKit/rust/src/*_recipe.rs`. The **Swift versions are
the contracted target (SPEC C-7) and are not yet authored** — each must be
written before its lens can graduate into the catalog (SPEC § 8). They are
listed here as the surface both versions must converge on.

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
    pub dismissal: Vec<(String, f64)>,        // per-room withdrawal rate, most-dismissed first
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

pub struct ContradictionOutput { pub outliers: Vec<String>, pub considered: usize }
pub fn run_contradiction(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, threshold: f32, now: i64,
) -> Result<ContradictionOutput, RecipeRunError>;
```

### Grounding / trust (category 6)

```rust
pub struct TrustGroundedOutput {
    pub context: ContextDocument,
    pub ranked_ids: Vec<String>,       // most-trusted first
    pub high_trust_count: usize,       // Canonical or User source type
}
pub fn run_trust_grounded_synthesis(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, now: i64,
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

### Federated (category 9)

```rust
pub struct MindOverlap { pub overlap: f64, pub a_count: usize, pub b_count: usize }
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
versions — today **grounded_synthesis** and **migration_benchmark**; a lens
recipe enters only when both versions land together (SPEC § 8).

---

## Swift/Rust Concordance

> Added: code-parity Phase-0, 2026-06-05 (force-mirror ruling).
> Completed (full public-surface enumeration): code-parity table-completion
> pass, 2026-06-05. Every row below is read-anchored to a real symbol in
> both ports (file:line cited); shape-rule deviations are sanctioned only
> where named; remaining mismatches are marked **DRIFT**.

One row per public CONCEPT. The Swift column and Rust column each name a
real top-level public symbol found in source. **Shape rule** records how
the two ports are permitted to differ. **Test/vector binding** names the
conformance/parity test that proves Swift == Rust. **Status**:
Confirmed (both present + test-bound) | Exempt (platform binding) | DRIFT.

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
| Capability set | `NeuronKitCapability` enum (`NeuronKitCapability.swift:34`) | `NeuronKitCapability` enum (`capability.rs:19`) | public both | 8 cases; camelCase ↔ PascalCase; `rawValue`/`raw_value` strings match byte-for-byte | `NeuronKitCapabilityTests.swift` + `capability.rs #[cfg(test)]` | Confirmed |
| Shipped capabilities | `shippedNeuronKitCapabilities` let (`NeuronKitCapability.swift:81`) | `shipped_capabilities()` fn (`capability.rs:82`) | public both | Swift constant `Set` / Rust fn returning `Vec` (same membership) | `NeuronKitCapabilityTests.swift` + `capability.rs #[cfg(test)]` | Confirmed |
| Capability verify | `verifyCapabilities(...)` fn (`NeuronKitCapability.swift:93`) | `verify_capabilities(...)` fn (`capability.rs:93`) | public both | Swift `throws` / Rust `Result` — deterministic first-missing order matches | `NeuronKitCapabilityTests.swift` + `capability.rs #[cfg(test)]` | Confirmed |
| Recipe error | `RecipeError` enum (`RecipeError.swift:24`) | `RecipeError` enum (`error.rs:14`) | public both | 6 cases — names, payloads, `description`/`Display` strings match byte-for-byte | `RecipeErrorTests.swift` + `error.rs #[cfg(test)]` (case-mirror gate) | Confirmed |
| Substrate error | `SubstrateError` struct (`RecipeRunError.swift:36`) | `SubstrateError` struct (`error.rs:98`) | public both | `operation: String, detail: String`; `"SubstrateError.{op}: {detail}"` | `RecipeRunErrorTests.swift` + `error.rs #[cfg(test)]` | Confirmed |
| Run-error wrapper | `RecipeRunError` enum (`RecipeRunError.swift:70`) | `RecipeRunError` enum (`error.rs:131`) | public both | 2 cases `.recipe`/`.substrate`; Swift `init`+`asRunError`, Rust `From` impls | `RecipeRunErrorTests.swift` (15) + `error.rs #[cfg(test)]` (case-mirror gate) | Confirmed |
| Recipe descriptor | `RecipeDescriptor` struct (`RecipeCatalog.swift:21`) | `RecipeDescriptor` struct (`catalog.rs:20`) | public both | identical fields; Rust serde-renames `required_capabilities`→`requiredCapabilities` | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` | Confirmed |
| Catalog accessors | `RecipeCatalog` enum (`RecipeCatalog.swift:57`) | `recipe_catalog()` / `recipe_descriptor(_)` / `recipe_names()` (`catalog.rs:33,200,206`) | public both | Swift enum-namespace static members / Rust free fns; descriptor strings byte-for-byte | `RecipeCatalogTests.swift` + `catalog.rs #[cfg(test)]` | Confirmed |

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
| Live migration recipe | `MigrationBenchmark` struct (`MigrationBenchmark.swift:147`) | `LiveRecipeSubstrate` struct (`migration_live.rs:49`) + `run_migration_benchmark` over it | public both | Swift `Recipe` (`async throws` over `GeniusLocusKit`) / Rust sync `LiveRecipeSubstrate` over `EstateCoordinator` (no async runtime — sanctioned live seam) | `MigrationBenchmarkTests.swift` + `migration_live.rs #[cfg(test)]` | Confirmed |
| Promotion confirm step | `MigrationBenchmark.confirmPromotion(...)` (`MigrationBenchmark.swift:415,468`) | `confirm_migration_promotion` / `confirm_migration_promotion_by_id` fns (`migration_live.rs:234,180`) | public both | Swift instance method / Rust free fns; gated two-step promote (B-3) | `MigrationBenchmarkTests.swift` + `migration_live.rs #[cfg(test)]` | Confirmed |
| Migration plan (live) | `MigrationPlan` struct (`MigrationBenchmark.swift:56`) | *(folded into `PlanInput`, `migration_orchestration.rs:37`)* | Swift public; Rust: live form folded into core `PlanInput` | Swift carries `AdjectiveSensitivity`/`BranchID`-typed live form; Rust live path reuses core `PlanInput` (sanctioned: Rust has one plan type, Swift splits live vs core) | `MigrationBenchmarkTests.swift` (live) / core vectors | Confirmed |
| Branch ranking (live) | `BranchRanking` struct (`MigrationBenchmark.swift:85`) | *(maps to `RankedPlan`, `migration_ranking.rs:32`)* | Swift public; Rust: `RankedPlan` | Swift live form carries `BranchID`; Rust returns core `RankedPlan` (live/core split is Swift-side, sanctioned) | `MigrationBenchmarkTests.swift` ↔ shared ranking vectors | Confirmed |
| Disqualified plan (live) | `DisqualifiedPlan` struct (`MigrationBenchmark.swift:107`) | *(maps to `DisqualifiedCore`, `migration_ranking.rs:41`)* | Swift public; Rust: `DisqualifiedCore` | Swift live form carries `BranchID`; Rust core `DisqualifiedCore` | `MigrationBenchmarkTests.swift` ↔ shared ranking vectors | Confirmed |
| Comparison report (live) | `MigrationComparisonReport` struct (`MigrationBenchmark.swift:125`) | *(maps to `CoreReport`, `migration_orchestration.rs:106`)* | Swift public; Rust: `CoreReport` | Swift live form (`BranchID` winner) / Rust `CoreReport` (string winner) — live/core split | `MigrationBenchmarkTests.swift` ↔ core vectors | Confirmed |

### Reasoning-lens recipes (SPEC § 4.2)

> NOTE — supersedes § 6: the prior § 6 claim "the Swift lens versions
> are not yet authored" is **STALE**. All fourteen lenses are authored
> in both ports today (Swift caseless-`enum` namespaces with a
> `public static func run`; Rust free `run_*` fns).

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
| Dismissal rate | `DismissalRate` struct (`Bias.swift:8`) | *(Rust `BiasReport.dismissal: Vec<(String, f64)>`, `bias_recipe.rs:37`)* | Swift public struct; Rust: inline tuple | Swift names the `(room, rate)` pair as a struct; Rust inlines it as a tuple field in `BiasReport` (sanctioned: same data, Swift gives it a nominal type) | `BiasTests.swift` + `bias_recipe.rs #[cfg(test)]` (report parity) | Confirmed |
| Drift (surprise) | `Drift` enum (`Drift.swift:29`) | `run_drift` fn (`drift_recipe.rs:38`) | public both | Swift enum-namespace `static run` / Rust free fn | `DriftTests.swift` + `drift_recipe.rs #[cfg(test)]` | Confirmed |
| Drift output | `DriftOutput` struct (`Drift.swift:7`) | `DriftOutput` struct (`drift_recipe.rs:22`) | public both | `drift: DriftScore`, before/after counts; identical | `DriftTests.swift` + `drift_recipe.rs #[cfg(test)]` | Confirmed |
| Contradiction (surprise) | `Contradiction` enum (`Contradiction.swift:28`) | `run_contradiction` fn (`contradiction_recipe.rs:32`) | public both | Swift enum-namespace `static run` / Rust free fn | `ContradictionTests.swift` + `contradiction_recipe.rs #[cfg(test)]` | Confirmed |
| Contradiction output | `ContradictionOutput` struct (`Contradiction.swift:8`) | `ContradictionOutput` struct (`contradiction_recipe.rs:22`) | public both | `outliers: [String]`, `considered: Int`; identical | `ContradictionTests.swift` + `contradiction_recipe.rs #[cfg(test)]` | Confirmed |
| Trust lens (grounding) | `TrustLens` enum (`TrustLens.swift:43`) | `run_trust_grounded_synthesis` fn (`trust_lens_recipe.rs:62`) | public both | Swift enum-namespace `static run` / Rust free fn | `TrustLensTests.swift` + `trust_lens_recipe.rs #[cfg(test)]` | Confirmed |
| Trust output | `TrustGroundedOutput` struct (`TrustLens.swift:9`) | `TrustGroundedOutput` struct (`trust_lens_recipe.rs:31`) | public both | `context`, `rankedIDs`/`ranked_ids`, `highTrustCount`/`high_trust_count` | `TrustLensTests.swift` + `trust_lens_recipe.rs #[cfg(test)]` | Confirmed |
| Partial-cue recall (associative) | `PartialCueRecall` enum (`PartialCueRecall.swift:62`) | `run_partial_cue_recall` fn (`feels_like_recipe.rs:59`) | public both | Swift enum-namespace `static run` / Rust free fn | `PartialCueRecallTests.swift` + `feels_like_recipe.rs #[cfg(test)]` | Confirmed |
| Cue mode | `CueMode` enum (`PartialCueRecall.swift:9`) | `CueMode` enum (`feels_like_recipe.rs:27`) | public both | 3 cases `feelsLike`/`aboutThis`/`fromThen` ↔ `FeelsLike`/`AboutThis`/`FromThen` | `PartialCueRecallTests.swift` + `feels_like_recipe.rs #[cfg(test)]` | Confirmed |
| Cue match | `CueMatch` struct (`PartialCueRecall.swift:28`) | `CueMatch` struct (`feels_like_recipe.rs:50`) | public both | `id: String`, `score: Double/f64`; identical | `PartialCueRecallTests.swift` + `feels_like_recipe.rs #[cfg(test)]` | Confirmed |
| Anchor-not-recalled error | `AnchorNotInRecalledSetError` struct (`PartialCueRecall.swift:41`) | `AnchorNotInRecalledSetError` struct (`error.rs`) | public both | Swift `public struct … : Error, Equatable`; Rust `#[derive(Debug, Clone, PartialEq, Eq)]` + `std::error::Error`. Wrapped in `SubstrateError` at the `RecipeRunError` boundary (return type unchanged); `Display` string matches Swift prefix so callers can identify it. | `PartialCueRecallTests.swift` + `error.rs #[cfg(test)]` (4 tests: field, display, equatable, Error impl) | Confirmed |
| Anticipate (prediction) | `Anticipate` enum (`Anticipate.swift:29`) | `run_anticipate` fn (`anticipate_recipe.rs:54`) | public both | Swift enum-namespace `static run` / Rust free fn; result `ActionPrediction` from NeuronKit | `AnticipateTests.swift` + `anticipate_recipe.rs #[cfg(test)]` | Confirmed |
| Tunnel successor (prediction) | `TunnelSuccessor` enum (`TunnelSuccessor.swift:30`) | `run_tunnel_successor` fn (`tunnel_successor_recipe.rs:35`) | public both | Swift enum-namespace `static run` / Rust free fn | `TunnelSuccessorTests.swift` + `tunnel_successor_recipe.rs #[cfg(test)]` | Confirmed |
| Successor result | `Successor` struct (`TunnelSuccessor.swift:6`) | `Successor` struct (`tunnel_successor_recipe.rs:27`) | public both | `id: String`, `weight: Int/usize`; identical | `TunnelSuccessorTests.swift` + `tunnel_successor_recipe.rs #[cfg(test)]` | Confirmed |
| Mind overlap (federated) | `MindOverlapLens` enum (`MindOverlap.swift:44`) | `run_mind_overlap` fn (`mind_overlap_recipe.rs:53`) | public both | Swift `…Lens` namespace / Rust free fn (generic over frame factory) | `MindOverlapTests.swift` + `mind_overlap_recipe.rs #[cfg(test)]` | Confirmed |
| Mind overlap result | `MindOverlap` struct (`MindOverlap.swift:10`) | `MindOverlap` struct (`mind_overlap_recipe.rs:32`) | public both | `overlap`, `aCount`/`a_count`, `bCount`/`b_count` | `MindOverlapTests.swift` + `mind_overlap_recipe.rs #[cfg(test)]` | Confirmed |
| Estate divergence (federated) | `EstateDivergenceLens` enum (`EstateDivergence.swift:40`) | `run_estate_divergence` fn (`estate_divergence_recipe.rs:54`) | public both | Swift `…Lens` namespace / Rust free fn | `EstateDivergenceTests.swift` + `estate_divergence_recipe.rs #[cfg(test)]` | Confirmed |
| Estate divergence result | `EstateDivergence` struct (`EstateDivergence.swift:8`) | `EstateDivergence` struct (`estate_divergence_recipe.rs:29`) | public both | `divergence: DriftScore`, `aCount`/`a_count`, `bCount`/`b_count` | `EstateDivergenceTests.swift` + `estate_divergence_recipe.rs #[cfg(test)]` | Confirmed |

### Knowledge-discovery recipes (association-rule + FCA family)

| Concept | Swift symbol | Rust symbol | Visibility | Shape rule | Test/vector binding | Status |
|---|---|---|---|---|---|---|
| Association rules recipe | `AssociationRules` struct (`AssociationRules.swift:98`) | `run_association_rules` fn (`association_rules_recipe.rs:94`) | public both | Swift `Recipe` struct (async) + nested `Output` / Rust free fn + `AssociationRulesOutput` | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` | Confirmed |
| Association rule result | `AssociationRuleResult` struct (`AssociationRules.swift:69`) | `AssociationRuleResult` struct (`association_rules_recipe.rs:60`) | public both | identical fields (`support`/`confidence`/`lift`/`conviction`/`leverage`) | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` | Confirmed |
| Association rules output | `AssociationRules.Output` (`AssociationRules.swift:112`) | `AssociationRulesOutput` struct (`association_rules_recipe.rs:74`) | public both | Swift nested `Output` / Rust flat `AssociationRulesOutput`; same fields | `AssociationRulesTests.swift` + `association_rules_recipe.rs #[cfg(test)]` | Confirmed |
| Apriori rules recipe | `AprioriRules` struct (`AssociationRules.swift:205`) | `run_apriori_rules` fn + `AprioriRulesOutput` struct (`association_rules_recipe.rs`) | public both | Swift `Recipe` struct (async, delegates to `GeniusLocusKit.mineAprioriRules`) / Rust free fn (delegates to `EstateCoordinator::mine_apriori_rules`, which synthesises `RowAuditEntry` from drawer bitmap columns — sanctioned Rust-side adaptation, no in-memory audit log); output preserves engine `AprioriRule` values verbatim | `AssociationRulesTests.swift` (CK-AP-1,2,3) + `association_rules_recipe.rs #[cfg(test)]` (mirror tests) | Confirmed |
| Formal concepts recipe | `FormalConcepts` struct (`FormalConcepts.swift:88`) | `run_formal_concepts` fn (`formal_concepts_recipe.rs:93`) | public both | Swift `Recipe` struct (async) + nested `Output` / Rust free fn + `FormalConceptsOutput` | `FormalConceptsTests.swift` + `formal_concepts_recipe.rs #[cfg(test)]` | Confirmed |
| Formal concept result | `FormalConceptResult` struct (`FormalConcepts.swift:63`) | `FormalConceptResult` struct (`formal_concepts_recipe.rs:67`) | public both | `intent`, `extentDrawerIDs`/extent, `support`, `stability` | `FormalConceptsTests.swift` + `formal_concepts_recipe.rs #[cfg(test)]` | Confirmed |
| Formal concepts output | `FormalConcepts.Output` (`FormalConcepts.swift:117`) | `FormalConceptsOutput` struct (`formal_concepts_recipe.rs:79`) | public both | Swift nested `Output` / Rust flat `FormalConceptsOutput`; same fields | `FormalConceptsTests.swift` + `formal_concepts_recipe.rs #[cfg(test)]` | Confirmed |

### Shared-vector conformance artifact

The migration-ranking family is gated against a **shared JSON artifact**:
`Tests/CognitionKitTests/Fixtures/cognition_vectors.json` is read by both
`CognitionVectorConformanceTests.swift` and
`rust/tests/cognition_conformance.rs`, so the two ports are checked
against the same inputs and expected outputs (not merely against each
other). Regenerate with `RECORD_COGNITION_VECTORS=1 swift test --filter
CognitionVectorConformance`.

### Drift register (this pass)

Two genuine cross-port gaps were found while completing the table. Per
Bob's force-mirror standard, "Swift-only by design" is **not** a waiver
unless the type is a true Apple platform binding (Metal/BNNS/CoreML/
CloudKit/Keychain) — neither of these is:

1. **`AprioriRules`** — **Closed (2026-06-05, branch t1-cognition).**
   Rust port: `run_apriori_rules` + `AprioriRulesOutput` in
   `association_rules_recipe.rs`. Coordinator integration:
   `EstateCoordinator::mine_apriori_rules` in `GeniusLocusKit/rust/src/coordinator.rs`
   (synthesises `RowAuditEntry` rows from drawer bitmap columns, delegates
   to `SubstrateML::mine_apriori_rules`). Descriptor added to `catalog.rs`
   (`"apriori_rules"`, v1.0.0, byte-identical to Swift). Tests: CK-AP-1,
   CK-AP-2, CK-AP-3 (mirror Swift `AssociationRulesTests.swift:201–259`).
   Rust 103 passing; Swift 122 passing.

2. **`AnchorNotInRecalledSetError`** — **Closed (2026-06-05, branch t1-cognition).**
   Rust port: nominal `AnchorNotInRecalledSetError` struct in `error.rs`
   (`Debug`, `Clone`, `PartialEq`, `Eq`, `Error`, `Display`). Display
   string matches Swift: `"AnchorNotInRecalledSetError: anchor drawer
   '{id}' not in recalled set"`. Wrapped in `SubstrateError` at the
   `RecipeRunError` boundary so the return type stays consistent; callers
   can detect the cause from the detail string prefix. Tests: 4 unit tests
   in `error.rs`; CK-FL-2 updated to assert both the prefix and the
   anchor_id appear in the error message.

No Apple-platform-binding types exist in CognitionKit, so nothing is
proposed for the audit ignore-list.

**Post-closure drift register: empty.** All known Swift/Rust gaps in
CognitionKit are confirmed closed as of 2026-06-05.

---

*End of CognitionKit Interface v0.85.*
