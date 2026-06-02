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

**Swift** — one typed enum; substrate faults propagate through untyped
`throws`.

```swift
public enum RecipeError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingCapability(NeuronKitCapability)
    case insufficientBranches(minimum: Int, provided: Int)
    case duplicatePlanName(String)
    case silentConceptLoss(branchID: BranchID, lostConcepts: [String])
    case tournamentNoWinner(disqualifiedCount: Int)
    case userConfirmationRequired(action: String)

    public var description: String { get }
}
```

**Rust** — the same closed guard set, plus an explicit `SubstrateError`
arm (the Rust encoding of Swift's propagated `throws`), unified as
`RecipeRunError`.

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
across versions byte-for-byte (SPEC § 6). The lens recipes return
`RecipeRunError` (read-only ⇒ in practice only the `Substrate` arm or an
empty/neutral result); the foundational recipes use `RecipeError`.

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
the contracted target (SPEC C-7)** and land lens by lens — each category
below notes which Swift versions are shipped (in
`Sources/CognitionKit/`); the rest are not yet authored. Both versions of
a lens must exist before it can graduate into the catalog (SPEC § 8). The
signatures are listed here as the surface both versions must converge on.

Every lens `run_*` takes the estate coordinator and handle, a recall frame
or wing/anchor, lens-specific parameters, and (where it recalls) a `now`;
each returns its reasoning result or a `RecipeRunError` (read-only;
SPEC § 5, I-6).

### Structure (category 1)

Swift versions shipped: `Keystones`, `Constellation`, `FreeAssociation`.

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

Swift versions shipped: `ThemeWeather`, `LatentThemesLens`. The
field-value label vocabulary both versions emit spells the Swift case
names (`kind:prose`, `channel:typed`, `sensitivity:normal`, …).

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

Swift versions shipped: `Bias` (the dismissal pairs surface as a
`DismissalRate` value type in Swift).

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

Swift versions shipped: `Drift` (`splitAt`/window math over `Date`,
matching the Swift capture surface).

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

Swift versions shipped: `TrustLens`.

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

Swift versions shipped: `PartialCueRecall` (an unknown anchor throws
the typed `AnchorNotInRecalledSetError` — the Swift face of the fault
the Rust version reports through its `Substrate` arm, § 4).

```rust
pub enum CueMode { FeelsLike, AboutThis, FromThen }
pub struct CueMatch { pub id: String, pub score: f64 }
pub fn run_partial_cue_recall(
    coord: &EstateCoordinator, handle: &EstateHandle,
    frame: RecallFrame, anchor_id: &str, mode: CueMode, k: usize, now: i64,
) -> Result<Vec<CueMatch>, RecipeRunError>;
```

### Prediction (category 8)

Swift versions shipped: `TunnelSuccessor`, `Anticipate`.

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

Swift versions shipped: `EstateDivergenceLens`, `MindOverlapLens`
(each takes one `RecallFrame` value for both recalls; the Rust
`make_frame` closures exist for ownership reasons, not contract).

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

*End of CognitionKit Interface v0.85.*
