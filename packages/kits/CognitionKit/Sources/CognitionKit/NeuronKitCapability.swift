// NeuronKitCapability.swift
//
// The set of NeuronKit reasoning capabilities a recipe may declare it
// depends on. Per COGNITIONKIT_SPEC § 2, every recipe declares the
// NeuronKit functions it will call in `requiredCapabilities`, and that
// declaration is verified BEFORE any execution begins — a recipe that
// cannot be fully executed fails immediately at the capability check
// (`RecipeError.missingCapability`), never mid-execution (spec B-5).
//
// Each case names a NeuronKit surface that is ACTUALLY SHIPPED in
// `packages/kits/NeuronKit/Sources/NeuronKit/` (verified against source,
// not the v0.8 spec body which reads as if some are deferred):
//   - hybridRecall       → HybridRecall.swift (free function)
//   - synthesize         → ContextSynthesizer.synthesize (enum static)
//   - deriveBranch       → BranchOps.swift (NeuronKit static)
//   - promoteBranch      → BranchOps.swift (NeuronKit static)
//   - benchmark          → BenchmarkAlgorithm.swift (NeuronKit static)
//   - runTournament      → Tournament.swift (NeuronKit static)
//
// The enum is intentionally a closed set of *shipped* capabilities.
// Capabilities that exist only in the stale v0.1 spec (elicitFraming,
// saveScenarioProfile) are deliberately absent — a recipe cannot
// declare a dependency on a function that does not exist, so the
// capability check is a real gate and not a rubber stamp.

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
}

/// The full set of NeuronKit capabilities shipped in the current
/// in-tree NeuronKit. The default host capability set a recipe is
/// checked against when the caller does not supply a narrower one.
///
/// This is `NeuronKitCapability.allCases` today because every declared
/// capability maps to a shipped NeuronKit surface. The seam exists so a
/// future host running against a reduced NeuronKit (e.g. a version that has
/// not yet implemented branch ops) can pass a narrower set and have
/// recipes that need the missing surface fail cleanly at the gate.
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
