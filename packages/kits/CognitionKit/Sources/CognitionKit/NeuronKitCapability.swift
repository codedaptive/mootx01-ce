// NeuronKitCapability.swift
//
// The set of NeuronKit reasoning capabilities a recipe may declare it
// depends on. Per COGNITIONKIT_SPEC § 2, every recipe declares the
// NeuronKit functions it will call in `requiredCapabilities`, and that
// declaration is verified BEFORE any execution begins — a recipe that
// cannot be fully executed fails immediately at the capability check
// (`RecipeError.missingCapability`), never mid-execution (spec B-5).
//
// Each case names a shipped surface that is ACTUALLY PRESENT in the
// in-tree kit or library:
//   - hybridRecall          → HybridRecall.swift (NeuronKit free function)
//   - synthesize            → ContextSynthesizer.synthesize (NeuronKit enum static)
//   - deriveBranch          → BranchOps.swift (NeuronKit static)
//   - promoteBranch         → BranchOps.swift (NeuronKit static)
//   - benchmark             → BenchmarkAlgorithm.swift (NeuronKit static)
//   - runTournament         → Tournament.swift (NeuronKit static)
//   - associationRuleMining → AssociationRuleMining.swift (SubstrateML free function)
//   - formalConceptAnalysis → FormalConceptAnalysis.swift (SubstrateML BoundedConceptMiner)
//   - exploratoryRecall     → RandomWalks.walkWithRestart (SubstrateML; consumed by
//                             ExploratoryRecall.swift / exploratory_recall_recipe.rs)
//
// The enum is intentionally a closed set of *shipped* capabilities.
// Capabilities that exist only in the stale v0.1 spec (elicitFraming,
// saveScenarioProfile) are deliberately absent — a recipe cannot
// declare a dependency on a function that does not exist, so the
// capability check is a real gate and not a rubber stamp.
//
// The four lenses added by TASK-MXE-ASSIGNED (moment, rhythm, precedence,
// complexity) are pure math free functions (no SubstrateML gate, no branch
// or recall capability). They declare requiredCapabilities: [] intentionally.
// No new cases were added: each calls an already-gated NeuronKit free function
// (momentSignature, rhythm, precedence, complexity) whose inputs are pre-shaped
// by the recipe — the capability gate exists at the function level, not the
// recipe level, and these functions carry no capability declaration of their own.

import Foundation

/// A NeuronKit reasoning capability a recipe sequences. The host
/// declares which capabilities it supports; a recipe declares which it
/// needs; the check (`RecipeError.missingCapability`) runs before the
/// recipe executes (spec § 2, B-5).
public enum NeuronKitCapability: String, Sendable, Hashable, CaseIterable, Codable {
    /// `NeuronKit.hybridRecall(_:handle:on:tuning:)` — RRF + MMR recall
    /// over the GLK recall verb, paged into a `RecallStream`.
    case hybridRecall

    /// `ContextSynthesizer.synthesize(from:estate:)` — read-only
    /// synthesis of a recall page into a `ContextDocument`.
    case synthesize

    /// `NeuronKit.deriveBranch(name:from:in:)` — derive a COW branch
    /// (thin forward over `GeniusLocusKit.glkDeriveBranch`).
    case deriveBranch

    /// `NeuronKit.promoteBranch(_:replacing:in:)` — promote a branch
    /// into its parent estate (thin forward over `glkPromoteBranch`).
    case promoteBranch

    /// `NeuronKit.benchmark(branch:against:queries:now:)` — recall-
    /// fidelity benchmark of a branch against an external corpus.
    case benchmark

    /// `NeuronKit.runTournament(branches:against:baseline:queries:evaluatedAt:interval:)`
    /// — benchmark + zero-silent-loss gate + survivor ranking.
    case runTournament

    /// `mineAssociationRules(matrix:activeRowCount:thresholds:)` — pairwise
    /// association-rule mining over the co-occurrence matrix O. A recipe
    /// builds a `MatrixO` from the recalled drawer set's field-value
    /// co-occurrence and delegates all rule-metric computation here.
    case associationRuleMining

    /// `BoundedConceptMiner.mine(context:)` — bounded formal concept analysis
    /// over a materialized `FormalContext`. A recipe builds the context from
    /// the recalled drawer set's field-value attributes (one row per drawer)
    /// and delegates all closure/dedup/ordering logic here.
    case formalConceptAnalysis

    /// `RandomWalks.walkWithRestart(seed:steps:restartProbability:rngSeed:adjacency:)`
    /// — estate-graph exploratory recall in RowId space, aggregating visits by
    /// row. Consumed by the `recall_exploratory` recipe
    /// (`ExploratoryRecall.swift`; Rust: `exploratory_recall_recipe.rs`).
    case exploratoryRecall
}

/// The full set of capabilities shipped in the current in-tree kits
/// (NeuronKit + SubstrateML). The default host capability set a recipe
/// is checked against when the caller does not supply a narrower one.
///
/// This is `NeuronKitCapability.allCases` today because every declared
/// capability maps to a shipped surface. The seam exists so a future host
/// running against a reduced kit version can pass a narrower set and have
/// recipes that need the missing surface fail cleanly at the gate.
/// Currently 9 capabilities: hybridRecall, synthesize, deriveBranch,
/// promoteBranch, benchmark, runTournament, associationRuleMining,
/// formalConceptAnalysis, exploratoryRecall.
public let shippedNeuronKitCapabilities: Set<NeuronKitCapability> =
    Set(NeuronKitCapability.allCases)

/// Verify that `available` covers every capability in `required`.
///
/// Throws `RecipeError.missingCapability` naming the FIRST required
/// capability not present in `available`, in the stable declaration
/// order of `NeuronKitCapability.allCases` so the failure is
/// deterministic. Returns normally when every requirement is met.
///
/// Recipes call this at the top of `run(...)` before any substrate
/// touch, satisfying spec B-5 (a recipe never partially executes).
public func verifyCapabilities(
    required: [NeuronKitCapability],
    available: Set<NeuronKitCapability> = shippedNeuronKitCapabilities
) throws {
    let requiredSet = Set(required)
    // Walk allCases (not the unordered Set) so the first-missing report
    // is stable across runs and platforms.
    for capability in NeuronKitCapability.allCases
    where requiredSet.contains(capability) && !available.contains(capability) {
        throw RecipeError.missingCapability(capability)
    }
}
