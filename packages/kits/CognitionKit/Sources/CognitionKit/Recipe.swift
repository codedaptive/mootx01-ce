// Recipe.swift
//
// The conformance contract every CognitionKit recipe implements. Per
// COGNITIONKIT_SPEC § 2, a recipe is a named, reusable workflow that
// SEQUENCES NeuronKit reasoning calls and GeniusLocusKit estate verbs —
// it implements no algorithm and owns no substrate state (B-1 / B-2).
//
// Signature reconciliation against shipped reality: the v0.1 spec's
// `run(input:estate:neuronKit:)` named a `NeuronKitHandle` parameter.
// NO SUCH TYPE EXISTS — NeuronKit's surface is free functions / static
// members on the `NeuronKit` enum namespace, reached by `import
// NeuronKit`. The estate boundary is the `GeniusLocusKit` actor plus the
// value-type `EstateHandle` it issues. So the run signature is
// `run(input:estate:kit:)` where `estate: EstateHandle` addresses the
// estate and `kit: GeniusLocusKit` is the actor verbs dispatch through.
// Recipes call NeuronKit functions directly (this module is NeuronKit's
// first in-tree consumer).
//
// Recipes are stateless between calls (spec B-4): state between steps
// lives in local variables or in NeuronKit/GLK nouns (BranchHandle,
// TournamentReport). No recipe persists state outside the estate.

import Foundation
import GeniusLocusKit

/// The contract all CognitionKit recipes implement.
///
/// A recipe declares the NeuronKit capabilities it sequences
/// (`requiredCapabilities`) so the host can verify support before
/// execution (spec § 2, B-5); the recipe's `run` should call
/// `verifyCapabilities(required:...)` as its first step. `Input` and
/// `Output` are the recipe's typed boundary — plain value types, never
/// substrate handles the recipe would own.
public protocol Recipe: Sendable {
    /// The recipe's typed input. A value type carrying the parameters
    /// the workflow needs (queries, plans, framings) — never a live
    /// substrate handle.
    associatedtype Input: Sendable

    /// The recipe's typed output. A value type carrying the workflow's
    /// result (reports, synthesized context, branch handles to confirm).
    associatedtype Output: Sendable

    /// Stable recipe name, surfaced to callers and tool surfaces
    /// (e.g. "grounded_synthesis").
    var name: String { get }

    /// Recipe version string, bumped when the workflow's observable
    /// behaviour changes.
    var version: String { get }

    /// One-line human-readable description of what the recipe does.
    var description: String { get }

    /// The NeuronKit capabilities this recipe will call. Verified
    /// against the host's available set before `run` executes (spec § 2).
    /// The declaration is complete — no undeclared capability calls
    /// (spec C-2).
    var requiredCapabilities: [NeuronKitCapability] { get }

    /// Execute the recipe.
    ///
    /// - Parameters:
    ///   - input: the recipe's typed parameters.
    ///   - estate: the estate handle to operate against. The recipe does
    ///     not own or open estates — it is passed in (spec § 2).
    ///   - kit: the GeniusLocusKit actor verbs and branch operations
    ///     dispatch through. The recipe does not instantiate it.
    /// - Returns: the recipe's typed output.
    /// - Throws: `RecipeError` for recipe-level faults (capability gate,
    ///   silent concept loss, missing confirmation) and any upstream
    ///   NeuronKit / GeniusLocusKit error unchanged.
    func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output
}
