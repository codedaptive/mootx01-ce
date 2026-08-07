// RecipeErrorTests.swift
//
// Peer to `Sources/CognitionKit/RecipeError.swift`: CognitionKit's
// single typed error enum (COGNITIONKIT_SPEC § 5). Asserts each case's
// `description` names the case and carries its payload (so a failure
// is diagnosable from the message alone), and that Equatable
// distinguishes payloads (so tests can assert the exact failure).

import Testing
import Foundation
import GeniusLocusKit
@testable import CognitionKit

@Suite("RecipeErrorTests")
struct RecipeErrorTests {

    @Test("missingCapability describes the capability")
    func missingCapabilityDescription() {
        let error = RecipeError.missingCapability(.synthesize)
        #expect(error.description.contains("missingCapability"))
        #expect(error.description.contains(NeuronKitCapability.synthesize.rawValue))
    }

    @Test("insufficientBranches describes minimum and provided")
    func insufficientBranchesDescription() {
        let error = RecipeError.insufficientBranches(minimum: 2, provided: 1)
        #expect(error.description.contains("insufficientBranches"))
        #expect(error.description.contains("2"))
        #expect(error.description.contains("1"))
    }

    @Test("duplicatePlanName describes the colliding name")
    func duplicatePlanNameDescription() {
        let error = RecipeError.duplicatePlanName("plan-a")
        #expect(error.description.contains("duplicatePlanName"))
        #expect(error.description.contains("plan-a"))
    }

    @Test("silentConceptLoss describes the branch and lost concepts")
    func silentConceptLossDescription() {
        let branchID = BranchID()
        let error = RecipeError.silentConceptLoss(
            branchID: branchID, lostConcepts: ["alpha", "beta"])
        #expect(error.description.contains("silentConceptLoss"))
        #expect(error.description.contains(branchID.uuidString))
        #expect(error.description.contains("alpha, beta"))
    }

    @Test("tournamentNoWinner describes the disqualified count")
    func tournamentNoWinnerDescription() {
        let error = RecipeError.tournamentNoWinner(disqualifiedCount: 3)
        #expect(error.description.contains("tournamentNoWinner"))
        #expect(error.description.contains("3"))
    }

    @Test("userConfirmationRequired describes the gated action")
    func userConfirmationRequiredDescription() {
        let error = RecipeError.userConfirmationRequired(action: "promote branch")
        #expect(error.description.contains("userConfirmationRequired"))
        #expect(error.description.contains("promote branch"))
    }

    // Equatable distinguishes payloads, so a test can assert the EXACT
    // failure (e.g. promoting a disqualified branch, not just "an error").
    @Test("equatable distinguishes cases and payloads")
    func equatableDistinguishesCasesAndPayloads() {
        #expect(RecipeError.duplicatePlanName("a") == RecipeError.duplicatePlanName("a"))
        #expect(RecipeError.duplicatePlanName("a") != RecipeError.duplicatePlanName("b"))
        #expect(
            RecipeError.insufficientBranches(minimum: 2, provided: 1)
                != RecipeError.tournamentNoWinner(disqualifiedCount: 1))
    }

    /// C2 — `invalidCap` carries the invalid value and its description names
    /// the case. Mirrors Rust `RecipeError::InvalidCap` via the
    /// `Display` implementation in `error.rs`.
    @Test("invalidCap describes the invalid cap value")
    func invalidCapDescription() {
        let errorNeg = RecipeError.invalidCap(value: -1)
        #expect(errorNeg.description.contains("invalidCap"),
                "description must name the case")
        #expect(errorNeg.description.contains("-1"),
                "description must carry the invalid value")

        let errorZero = RecipeError.invalidCap(value: 0)
        #expect(errorZero.description.contains("invalidCap"))
        #expect(errorZero.description.contains("0"))

        // Equatable parity.
        #expect(RecipeError.invalidCap(value: -1) == RecipeError.invalidCap(value: -1))
        #expect(RecipeError.invalidCap(value: -1) != RecipeError.invalidCap(value: -2))
        #expect(RecipeError.invalidCap(value: 0) != RecipeError.tournamentNoWinner(disqualifiedCount: 0))
    }
}
