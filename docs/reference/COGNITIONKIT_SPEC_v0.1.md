---
status: draft specification, v0.1
authors: Bob Pankratz (via/ claude)
date: 2026-05-10
version: 0.1
package: CognitionKit
kind: Kit
relates_to:
  - COGNITIONKIT_INTERFACE_v0.1.md (the API surface this spec contracts)
  - NEURONKIT_SPEC_v0.1.md (NeuronKit provides all algorithms CognitionKit calls)
  - GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md (substrate contract)
  - GENIUSLOCUS_IMPLEMENTATION_PLAN_v0.35.md (build order: CognitionKit is Phase 6)
---

# CognitionKit Specification — v0.1

CognitionKit is the behavior recipe layer of the GeniusLocus architecture.
It assembles NeuronKit reasoning calls into named, reusable workflows. It
contains no algorithms of its own.

**A recipe is a sequence of NeuronKit calls, not an implementation.**

When a recipe needs a capability that the lower kit interfaces do not
directly expose, that capability belongs in NeuronKit — not in the recipe.
A recipe that implements an algorithm has leaked across its boundary.

**CognitionKit has no direct substrate access.** Every read and write passes
through NeuronKit or the GeniusLocusKit estate handle. CognitionKit never
executes SQL, never touches LocusKit, VectorKit, or CorpusKit directly, and
never calls GeniusLocusKit verbs directly except through NeuronKit's
reasoning layer or a passed estate handle.

**Three-question check for recipe design:**
1. Does this step need an algorithm? → That algorithm lives in NeuronKit.
2. Does this step need to store something? → That storage lives in the substrate.
3. Is this step sequencing calls that already exist? → This is recipe territory.

---

## § 1 — Scope

This specification defines:
- What a recipe is and how it is structured
- The Recipe protocol that all v1.0 recipes implement
- The three v1.0 recipes: FulcrumDailyFraming, MigrationBenchmark, ScenarioSkill
- Conformance requirements for recipe implementations

CognitionKit does not define:
- Any algorithm (NeuronKit spec territory)
- Any storage schema (substrate spec territory)
- Any estate verb (GeniusLocusKit spec territory)
- Cross-estate mediation (ARIA_MCP spec territory)

---

## § 2 — The Recipe protocol

Every CognitionKit recipe implements the Recipe protocol:

```swift
protocol Recipe {
    associatedtype Input
    associatedtype Output

    var name: String { get }
    var version: String { get }
    var description: String { get }
    var requiredNeuronKitCapabilities: [NeuronKitCapability] { get }

    func run(
        input: Input,
        estate: EstateHandle,
        neuronKit: NeuronKitHandle
    ) async throws -> Output
}
```

**RequiredNeuronKitCapabilities** declares which NeuronKit reasoning functions
the recipe will call. This declaration is used at recipe initialization to
verify NeuronKit is configured to support the recipe before execution begins.

**EstateHandle** is passed in — recipes do not own or open estates.
**NeuronKitHandle** is passed in — recipes do not instantiate NeuronKit.

A recipe that fails its capability check throws `RecipeError.missingCapability`
before any execution begins. It never partially executes.

---

## § 3 — v1.0 recipes

Three recipes ship in v1.0.

### § 3.1 — FulcrumDailyFraming

**Purpose:** Run 2–X competing framings of the day's work in parallel,
score them at end of day, surface the winner for confirmation.

**Domain:** Fulcrum obligation management. Weighted toward `stateProgressionRate`
because advancing the state of obligations is the primary signal that a
framing is working.

**Input:**

```swift
struct FulcrumDailyFramingInput {
    let framings: [FramingParameters]  // 2–X, produced by elicitFraming or user-defined
    let evaluationTime: Date           // when to run the end-of-day tournament
    let scoringConfig: ScoringConfig   // default: stateProgressionRate weight 0.4, rest 0.15
}
```

**Sequence:**

1. `NeuronKit.deriveBranch(name: framing.name, from: estate)` × N — one branch per framing
2. Register EndOfDayTournamentSignal at `evaluationTime`
3. User captures into estate throughout the day (captures are mirrored to all active branches, or routed per user choice — configurable)
4. At `evaluationTime`: `NeuronKit.runTournament(over: activeBranches, scoring: scoringConfig, interval: today)`
5. Surface `TournamentReport` to user
6. On user confirmation: `NeuronKit.promoteBranch(winner)`, `branch.discard()` × N-1

**Output:**

```swift
struct FulcrumDailyFramingOutput {
    let tournamentReport: TournamentReport
    let promotedBranch: BranchHandle
    let discardedBranches: [BranchHandle]
    let scenarioProfile: ScenarioProfile?  // saved if user opts in
}
```

**Scoring config defaults for Fulcrum:**

```swift
ScoringConfig(
    rewardWeight: 0.15,
    proposalAcceptanceWeight: 0.15,
    tunnelFormationWeight: 0.15,
    stateProgressionWeight: 0.40,  // primary signal for obligation management
    recallPrecisionWeight: 0.15
)
```

**Required NeuronKit capabilities:**
`deriveBranch`, `runTournament`, `promoteBranch`

---

### § 3.2 — MigrationBenchmark

**Purpose:** Compare N structural migration plans for a MemPalace import.
Each plan is derived as a branch with its own structural parameters. The
plan whose branch benchmarks best against the origin corpus is promoted.

**Domain:** MemPalace migration. Zero silent concept loss is a hard
requirement — a plan that loses concepts silently is disqualified before
the user sees it.

**Input:**

```swift
struct MigrationBenchmarkInput {
    let origin: ExternalCorpus          // MemPalace export or equivalent
    let plans: [MigrationPlan]          // 2–4 structural parameter plans
    let benchmarkQueries: [RecallFrame] // queries the origin can answer; used for comparison
}

struct MigrationPlan {
    let name: String
    let latticeStrategy: LatticeStrategy       // how to assign UDC codes
    let sensitivityClassification: SensitivityClassification
    let wingRoomTaxonomy: WingRoomTaxonomy
    let customParameters: [String: Any]
}
```

**Sequence:**

1. `NeuronKit.deriveBranch(name: plan.name, from: stagingEstate)` × N
2. For each branch: run migration tooling against `origin` with `plan` parameters
3. `NeuronKit.benchmark(branch: branch, against: origin, queries: benchmarkQueries)` × N
4. Disqualify any branch with `BenchmarkReport.notFoundInBranch.count > 0`
   (silent concept loss is disqualifying — surface to user before proceeding)
5. Score remaining branches on `recallOverlap`, `recallPrecision`, `meanReciprocalRank`
6. Surface comparison report to user
7. On user confirmation: `NeuronKit.promoteBranch(winner)`, `branch.discard()` × N-1

**Output:**

```swift
struct MigrationBenchmarkOutput {
    let benchmarkReports: [BenchmarkReport]    // one per plan
    let disqualified: [BranchHandle]           // branches with silent concept loss
    let comparisonReport: MigrationComparisonReport
    let promotedBranch: BranchHandle?          // nil until user confirms
}

struct MigrationComparisonReport {
    let winner: BranchHandle?
    let rankings: [BranchRanking]
    let disqualifiedReasons: [BranchHandle: String]
}
```

**Hard constraint:** Any plan with `notFoundInBranch.count > 0` is
disqualified and surfaced to the user with the list of lost concepts
before any promotion decision is made. The recipe throws
`RecipeError.silentConceptLoss` if the user attempts to promote a
disqualified branch.

**Required NeuronKit capabilities:**
`deriveBranch`, `benchmark`, `promoteBranch`

---

### § 3.3 — ScenarioSkill

**Purpose:** Given user answers to 5 structured questions, derive two
competing scenarios (A and B), run them in parallel, surface findings
from each, capture the user's preference, and save the preference weights
as a reusable ScenarioProfile.

**Domain:** Any estate. General-purpose scenario exploration.

**Input:**

```swift
struct ScenarioSkillInput {
    let questions: [String]   // 5 questions, pre-generated or user-defined
    let answers: [String]     // user's answers, one per question
    let querySet: [RecallFrame] // queries to run against both scenarios
    let saveName: String?       // if provided, save as a named ScenarioProfile
    let trainingEligible: Bool  // user consent for tiny-model training
}
```

**Sequence:**

1. `NeuronKit.elicitFraming(questions: questions, answers: answers)` → FramingParameters
2. If `divergenceScore < 0.3` → surface warning to user; user confirms to proceed or revises answers
3. `NeuronKit.deriveBranch(name: "Scenario A", from: estate)` → branchA
4. `NeuronKit.deriveBranch(name: "Scenario B", from: estate)` → branchB
5. Populate branches — either from FramingParameters-driven captures or
   foundation model population (implementation choice)
6. `NeuronKit.hybridRecall(frame, estate: branchA)` × querySet → resultsA
7. `NeuronKit.hybridRecall(frame, estate: branchB)` × querySet → resultsB
8. `NeuronKit.synthesize(from: resultsA, estate: branchA)` → contextA
9. `NeuronKit.synthesize(from: resultsB, estate: branchB)` → contextB
10. Surface contextA and contextB to user as findings
11. User selects preferred scenario
12. `NeuronKit.runTournament(over: [branchA, branchB], ...)` → TournamentReport
13. If `saveName != nil`: `NeuronKit.saveScenarioProfile(name:, from:, trainingEligible:)` → ScenarioProfile
14. `NeuronKit.promoteBranch(winner)` on user confirmation
15. `branch.discard()` for the losing scenario (audit trail preserved)

**Output:**

```swift
struct ScenarioSkillOutput {
    let framingParameters: FramingParameters
    let contextA: ContextDocument
    let contextB: ContextDocument
    let userPreference: BranchHandle
    let tournamentReport: TournamentReport
    let scenarioProfile: ScenarioProfile?  // non-nil if saveName was provided
}
```

**Required NeuronKit capabilities:**
`elicitFraming`, `deriveBranch`, `hybridRecall`, `synthesize`,
`runTournament`, `promoteBranch`, `saveScenarioProfile`

---

## § 4 — Recipe composition

Recipes compose. A CognitionKit caller may run recipes in sequence, passing
the output of one as input to another.

**Example composition:** Run ScenarioSkill to identify the preferred framing,
then run FulcrumDailyFraming using the winning FramingParameters as the
starting framing for the day.

```swift
let scenarioOutput = try await ScenarioSkill().run(
    input: scenarioInput,
    estate: estate,
    neuronKit: neuronKit
)

let dailyInput = FulcrumDailyFramingInput(
    framings: [scenarioOutput.framingParameters.scenarioA],
    evaluationTime: Calendar.current.endOfDay(for: .now),
    scoringConfig: .fulcrumDefaults
)

let dailyOutput = try await FulcrumDailyFraming().run(
    input: dailyInput,
    estate: estate,
    neuronKit: neuronKit
)
```

The composition is the caller's responsibility — CognitionKit provides the
recipes, not the orchestration between them.

---

## § 5 — Error model

```swift
enum RecipeError: Error {
    case missingCapability(NeuronKitCapability)
    case insufficientBranches(minimum: Int, provided: Int)
    case silentConceptLoss(branch: BranchHandle, lostConcepts: [String])
    case lowDivergenceScore(score: Float, threshold: Float)
    case tournamentNoWinner(report: TournamentReport)
    case userConfirmationRequired(action: String)
}
```

**RecipeError.silentConceptLoss** is non-recoverable in MigrationBenchmark.
The caller must surface the lost concepts to the user and restart with a
revised plan. The recipe never silently proceeds past a concept-loss detection.

**RecipeError.userConfirmationRequired** is thrown when a recipe reaches
a step that requires human confirmation (promotion, discard of multiple
branches) and no confirmation mechanism has been provided. Recipes never
auto-confirm on the caller's behalf.

---

## § 6 — Behavioral contracts

**B-1:** Recipes implement no algorithms. Any step that requires computation
beyond sequencing calls delegates to NeuronKit.

**B-2:** Recipes have no direct substrate access. Every read and write passes
through NeuronKit or a passed estate handle.

**B-3:** Recipes never auto-promote or auto-discard. Every destructive action
(promotion, discard, merge) is gated behind explicit user confirmation.

**B-4:** Recipes are stateless between calls. State between recipe steps is
held in local variables or passed through NeuronKit nouns (BranchHandle,
TournamentReport). No recipe persists state outside the estate manifest.

**B-5:** Recipe capability declarations are verified before execution. A
recipe that cannot be fully executed fails immediately at capability check,
not mid-execution.

---

## § 7 — Conformance requirements

**C-1:** Every recipe implements the Recipe protocol.

**C-2:** Every recipe declares all NeuronKit capabilities it calls in
`requiredNeuronKitCapabilities`. The declaration is complete — no undeclared
capability calls.

**C-3:** No recipe calls a substrate kit directly (LocusKit, VectorKit,
CorpusKit, or GeniusLocusKit SQL).

**C-4:** No recipe implements an algorithm (sorting, ranking, scoring,
training, mining). These live in NeuronKit.

**C-5:** MigrationBenchmark throws `RecipeError.silentConceptLoss` when
any plan has `notFoundInBranch.count > 0`. It never promotes a plan with
silent concept loss.

**C-6:** ScenarioSkill surfaces a low-divergence warning and requires
user confirmation before proceeding when `divergenceScore < 0.3`.

**C-7:** No recipe calls `promoteBranch()` without surfacing the
TournamentReport to the user first.

---

## § 8 — v0.1 scope

Three recipes ship in v1.0: FulcrumDailyFraming, MigrationBenchmark,
ScenarioSkill.

Future recipes (not deferred — simply not yet designed):
- Weekly review recipe (surfaces the week's dreaming daemon output,
  maintenance proposals, and SolverBandit acceptance test results)
- Cross-estate learning recipe (ARIA_MCP-mediated scenario comparison
  across multiple estates owned by one user)

Out of CognitionKit scope entirely:
- Any algorithm → NeuronKit
- Any storage → substrate kits
- Cross-estate mediation → ARIA_MCP

---

*End of CognitionKit Specification v0.1.*
