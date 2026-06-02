// CapabilityGateTests.swift
//
// Phase-1 conformance for the capability gate (spec § 2, B-5): a recipe
// verifies its declared NeuronKit capabilities are available BEFORE any
// execution begins, and fails deterministically with
// `RecipeError.missingCapability` naming the first missing capability in
// `NeuronKitCapability.allCases` order.

import Testing
import Foundation
@testable import CognitionKit

@Suite("CapabilityGateTests")
struct CapabilityGateTests {

    @Test("all shipped capabilities are available by default")
    func allShippedCapabilitiesAreAvailableByDefault() throws {
        // Every declared capability maps to a shipped NeuronKit surface,
        // so the default host set covers all of them.
        try verifyCapabilities(required: NeuronKitCapability.allCases)
        #expect(shippedNeuronKitCapabilities == Set(NeuronKitCapability.allCases))
    }

    @Test("empty requirement always passes")
    func emptyRequirementAlwaysPasses() throws {
        try verifyCapabilities(required: [])
        try verifyCapabilities(required: [], available: [])
    }

    @Test("missing capability throws naming it")
    func missingCapabilityThrowsNamingIt() {
        // Host supports only hybridRecall; a recipe needing runTournament
        // must fail at the gate.
        let available: Set<NeuronKitCapability> = [.hybridRecall]
        #expect(throws: RecipeError.missingCapability(.runTournament)) {
            try verifyCapabilities(required: [.hybridRecall, .runTournament],
                                   available: available)
        }
    }

    @Test("first missing is reported in declaration order")
    func firstMissingIsReportedInDeclarationOrder() {
        // With two missing, the FIRST in allCases order is reported so the
        // failure is deterministic. allCases order:
        // hybridRecall, synthesize, deriveBranch, promoteBranch,
        // benchmark, runTournament. deriveBranch precedes benchmark.
        let available: Set<NeuronKitCapability> = [.hybridRecall, .synthesize]
        #expect(throws: RecipeError.missingCapability(.deriveBranch)) {
            try verifyCapabilities(required: [.benchmark, .deriveBranch],
                                   available: available)
        }
    }

    @Test("capability metadata is declared")
    func capabilityMetadataIsDeclared() {
        // Wire rawValues must match the Rust serde renames byte-for-byte
        // so the capability gate is identical across the two versions.
        #expect(NeuronKitCapability.associationRuleMining.rawValue == "associationRuleMining")
        #expect(NeuronKitCapability.formalConceptAnalysis.rawValue == "formalConceptAnalysis")
        // Both new capabilities appear in allCases and therefore in
        // shippedNeuronKitCapabilities.
        #expect(NeuronKitCapability.allCases.contains(.associationRuleMining))
        #expect(NeuronKitCapability.allCases.contains(.formalConceptAnalysis))
    }

    @Test("RecipeError is equatable and described")
    func recipeErrorIsEquatableAndDescribed() {
        let err = RecipeError.silentConceptLoss(
            branchID: UUID(), lostConcepts: ["a", "b"])
        #expect(err.description.contains("silentConceptLoss"))
        #expect(err.description.contains("2 concept"))
    }
}
