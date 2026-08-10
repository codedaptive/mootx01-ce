// RecipeRunErrorTests.swift
//
// TDD conformance tests for the Swift `RecipeRunError` / `SubstrateError`
// mirror types (force-mirror parity ruling, code-parity Phase-0, 2026-06-05).
//
// Assertions:
//   1. `SubstrateError` carries operation + detail, description matches Rust
//      Display format byte-for-byte.
//   2. `RecipeRunError.recipe` wraps a `RecipeError` and delegates description.
//   3. `RecipeRunError.substrate` wraps a `SubstrateError` and delegates
//      description.
//   4. `RecipeRunError` is Equatable, distinguishing arms and payloads.
//   5. Conversion helpers (`init(_:)` and `asRunError`) produce correct arms.
//   6. Case names match the Rust variants (structural parity assertion via
//      pattern-matching exhaustiveness — the compiler enforces it).

import Testing
import Foundation
import GeniusLocusKit
@testable import CognitionKit

@Suite("RecipeRunErrorTests")
struct RecipeRunErrorTests {

    // MARK: - SubstrateError

    @Test("SubstrateError carries operation and detail")
    func substrateErrorFields() {
        let err = SubstrateError(operation: "derive_branch", detail: "estate locked")
        #expect(err.operation == "derive_branch")
        #expect(err.detail == "estate locked")
    }

    @Test("SubstrateError description mirrors Rust Display: 'SubstrateError.{op}: {detail}'")
    func substrateErrorDescription() {
        let err = SubstrateError(operation: "benchmark", detail: "corpus empty")
        // Rust Display: `write!(f, "SubstrateError.{}: {}", self.operation, self.detail)`
        #expect(err.description == "SubstrateError.benchmark: corpus empty")
    }

    @Test("SubstrateError is Equatable — same fields equal, differing fields unequal")
    func substrateErrorEquatable() {
        let a = SubstrateError(operation: "recall", detail: "timeout")
        let b = SubstrateError(operation: "recall", detail: "timeout")
        let c = SubstrateError(operation: "capture", detail: "timeout")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - RecipeRunError.recipe arm

    @Test("RecipeRunError.recipe wraps RecipeError and delegates description")
    func recipeArmDescription() {
        let inner = RecipeError.duplicatePlanName("plan-x")
        let err = RecipeRunError.recipe(inner)
        // Description delegates to RecipeError — no extra prefix added.
        #expect(err.description == inner.description)
        #expect(err.description.contains("duplicatePlanName"))
        #expect(err.description.contains("plan-x"))
    }

    @Test("RecipeRunError.recipe unwrap accessor returns inner error")
    func recipeArmUnwrap() {
        let inner = RecipeError.missingCapability(.hybridRecall)
        let err = RecipeRunError.recipe(inner)
        #expect(err.recipeError == inner)
        #expect(err.substrateError == nil)
    }

    // MARK: - RecipeRunError.substrate arm

    @Test("RecipeRunError.substrate wraps SubstrateError and delegates description")
    func substrateArmDescription() {
        let inner = SubstrateError(operation: "recall", detail: "index missing")
        let err = RecipeRunError.substrate(inner)
        // Description delegates to SubstrateError — no extra prefix added.
        #expect(err.description == inner.description)
        #expect(err.description.contains("SubstrateError.recall"))
        #expect(err.description.contains("index missing"))
    }

    @Test("RecipeRunError.substrate unwrap accessor returns inner error")
    func substrateArmUnwrap() {
        let inner = SubstrateError(operation: "derive_branch", detail: "full")
        let err = RecipeRunError.substrate(inner)
        #expect(err.substrateError == inner)
        #expect(err.recipeError == nil)
    }

    // MARK: - Equatable

    @Test("RecipeRunError equatable — same arm same payload equals")
    func equatableSameArm() {
        let a = RecipeRunError.recipe(.tournamentNoWinner(disqualifiedCount: 2))
        let b = RecipeRunError.recipe(.tournamentNoWinner(disqualifiedCount: 2))
        #expect(a == b)
    }

    @Test("RecipeRunError equatable — same arm different payload unequal")
    func equatableDifferentPayload() {
        let a = RecipeRunError.recipe(.tournamentNoWinner(disqualifiedCount: 2))
        let b = RecipeRunError.recipe(.tournamentNoWinner(disqualifiedCount: 3))
        #expect(a != b)
    }

    @Test("RecipeRunError equatable — different arms are unequal")
    func equatableDifferentArms() {
        let recipe = RecipeRunError.recipe(.duplicatePlanName("p"))
        let substrate = RecipeRunError.substrate(SubstrateError(operation: "recall", detail: "x"))
        #expect(recipe != substrate)
    }

    // MARK: - Conversion helpers

    @Test("RecipeRunError init from RecipeError wraps into recipe arm")
    func initFromRecipeError() {
        let inner = RecipeError.insufficientBranches(minimum: 2, provided: 1)
        let err = RecipeRunError(inner)
        #expect(err == .recipe(inner))
    }

    @Test("RecipeRunError init from SubstrateError wraps into substrate arm")
    func initFromSubstrateError() {
        let inner = SubstrateError(operation: "benchmark", detail: "empty")
        let err = RecipeRunError(inner)
        #expect(err == .substrate(inner))
    }

    @Test("RecipeError.asRunError lifts into recipe arm")
    func asRunError() {
        let inner = RecipeError.userConfirmationRequired(action: "promote")
        let err = inner.asRunError
        #expect(err == .recipe(inner))
        #expect(err.recipeError == inner)
    }

    // MARK: - All six RecipeError cases round-trip through RecipeRunError

    @Test("All six RecipeError cases survive RecipeRunError.recipe round-trip")
    func allCasesRoundTrip() {
        let branchID = BranchID()
        let cases: [RecipeError] = [
            .missingCapability(.synthesize),
            .insufficientBranches(minimum: 1, provided: 0),
            .duplicatePlanName("dup"),
            .silentConceptLoss(branchID: branchID, lostConcepts: ["a", "b"]),
            .tournamentNoWinner(disqualifiedCount: 3),
            .userConfirmationRequired(action: "confirm"),
        ]
        for c in cases {
            let wrapped = RecipeRunError(c)
            #expect(wrapped.recipeError == c,
                "RecipeError.\(c) did not survive RecipeRunError round-trip")
            // Description round-trips through the wrapper unchanged.
            #expect(wrapped.description == c.description)
        }
    }

    // MARK: - Case name parity (structural)
    // The compiler enforces Swift exhaustiveness. If a Swift variant is added
    // or removed, this switch will fail to compile. This protects the Swift
    // enum, but does not automatically detect Rust enum changes; a Rust-side
    // change also requires updating the Swift mirror type and this switch.

    @Test("RecipeRunError switch is exhaustive over both arms")
    func exhaustiveSwitch() {
        func describe(_ e: RecipeRunError) -> String {
            switch e {
            case .recipe(let inner):
                // RecipeError is itself exhaustive over its cases.
                switch inner {
                case .missingCapability: return "recipe.missingCapability"
                case .insufficientBranches: return "recipe.insufficientBranches"
                case .duplicatePlanName: return "recipe.duplicatePlanName"
                case .silentConceptLoss: return "recipe.silentConceptLoss"
                case .tournamentNoWinner: return "recipe.tournamentNoWinner"
                case .userConfirmationRequired: return "recipe.userConfirmationRequired"
                case .tooManyPlans: return "recipe.tooManyPlans"
                case .tooManyOriginEntries: return "recipe.tooManyOriginEntries"
                case .invalidCap: return "recipe.invalidCap"
                }
            case .substrate:
                return "substrate"
            }
        }
        #expect(describe(.recipe(.missingCapability(.hybridRecall))) == "recipe.missingCapability")
        #expect(describe(.substrate(.init(operation: "x", detail: "y"))) == "substrate")
    }
}
