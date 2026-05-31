// CapabilityGateTests.swift
//
// Phase-1 conformance for the capability gate (spec § 2, B-5): a recipe
// verifies its declared NeuronKit capabilities are available BEFORE any
// execution begins, and fails deterministically with
// `RecipeError.missingCapability` naming the first missing capability in
// `NeuronKitCapability.allCases` order.

import XCTest
@testable import CognitionKit

final class CapabilityGateTests: XCTestCase {

    func testAllShippedCapabilitiesAreAvailableByDefault() throws {
        // Every declared capability maps to a shipped NeuronKit surface,
        // so the default host set covers all of them.
        XCTAssertNoThrow(
            try verifyCapabilities(required: NeuronKitCapability.allCases)
        )
        XCTAssertEqual(shippedNeuronKitCapabilities,
                       Set(NeuronKitCapability.allCases))
    }

    func testEmptyRequirementAlwaysPasses() throws {
        XCTAssertNoThrow(try verifyCapabilities(required: []))
        XCTAssertNoThrow(try verifyCapabilities(required: [], available: []))
    }

    func testMissingCapabilityThrowsNamingIt() {
        // Host supports only hybridRecall; a recipe needing runTournament
        // must fail at the gate.
        let available: Set<NeuronKitCapability> = [.hybridRecall]
        XCTAssertThrowsError(
            try verifyCapabilities(required: [.hybridRecall, .runTournament],
                                   available: available)
        ) { error in
            XCTAssertEqual(error as? RecipeError,
                           .missingCapability(.runTournament))
        }
    }

    func testFirstMissingIsReportedInDeclarationOrder() {
        // With two missing, the FIRST in allCases order is reported so the
        // failure is deterministic. allCases order:
        // hybridRecall, synthesize, deriveBranch, promoteBranch,
        // benchmark, runTournament. deriveBranch precedes benchmark.
        let available: Set<NeuronKitCapability> = [.hybridRecall, .synthesize]
        XCTAssertThrowsError(
            try verifyCapabilities(required: [.benchmark, .deriveBranch],
                                   available: available)
        ) { error in
            XCTAssertEqual(error as? RecipeError,
                           .missingCapability(.deriveBranch))
        }
    }

    func testRecipeErrorIsEquatableAndDescribed() {
        let err = RecipeError.silentConceptLoss(
            branchID: UUID(), lostConcepts: ["a", "b"])
        XCTAssertTrue(err.description.contains("silentConceptLoss"))
        XCTAssertTrue(err.description.contains("2 concept"))
    }
}
