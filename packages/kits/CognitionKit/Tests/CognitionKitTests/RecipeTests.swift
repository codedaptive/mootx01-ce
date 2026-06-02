// RecipeTests.swift
//
// Peer to `Sources/CognitionKit/Recipe.swift`: the conformance contract
// every recipe implements (COGNITIONKIT_SPEC § 2). The protocol's
// behavioral claims are asserted through a minimal conforming mock:
// the capability gate runs BEFORE any execution (B-5, no partial
// execution), recipes are stateless between calls (B-4), and the
// metadata surface (name/version/description/requiredCapabilities)
// is complete.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Records the work a recipe performs, so the gate-first claim is
/// observable: if the gate throws, the log must stay empty.
private actor WorkLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

/// Minimal `Recipe` conformance: typed value-type boundary, capability
/// gate as the first step, deterministic output. The host capability
/// set is injected so the gate is testable against a reduced host.
private struct EchoRecipe: Recipe {
    struct Input: Sendable {
        let text: String
        let log: WorkLog
    }
    struct Output: Sendable, Equatable {
        let echoed: String
    }

    let name = "echo"
    let version = "1.0.0"
    let description = "Echoes its input after the capability gate."
    let requiredCapabilities: [NeuronKitCapability] = [.synthesize]
    let hostCapabilities: Set<NeuronKitCapability>

    func run(
        input: Input,
        estate: EstateHandle,
        kit: GeniusLocusKit
    ) async throws -> Output {
        // Spec § 2 / B-5: the gate is the FIRST step.
        try verifyCapabilities(
            required: requiredCapabilities, available: hostCapabilities)
        await input.log.record("work")
        return Output(echoed: input.text)
    }
}

@Suite("RecipeTests")
struct RecipeTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "recipe-test"))
        return (kit, handle)
    }

    @Test("metadata surface is complete")
    func metadataSurfaceIsComplete() {
        let recipe = EchoRecipe(hostCapabilities: shippedNeuronKitCapabilities)
        #expect(!recipe.name.isEmpty)
        #expect(!recipe.version.isEmpty)
        #expect(!recipe.description.isEmpty)
        #expect(!recipe.requiredCapabilities.isEmpty)
    }

    // Spec § 2, B-5: a missing capability fails the recipe BEFORE any
    // execution — the recipe never partially executes.
    @Test("capability gate runs before any work")
    func capabilityGateRunsBeforeAnyWork() async throws {
        let (kit, handle) = try await openEstate()
        let log = WorkLog()
        let host: Set<NeuronKitCapability> =
            shippedNeuronKitCapabilities.subtracting([.synthesize])
        let recipe = EchoRecipe(hostCapabilities: host)

        await #expect(throws: RecipeError.missingCapability(.synthesize)) {
            _ = try await recipe.run(
                input: .init(text: "hello", log: log), estate: handle, kit: kit)
        }
        #expect(await log.entries.isEmpty, "no partial execution past the gate")
    }

    // Spec B-4: recipes are stateless between calls — the same input
    // produces the same output on every run.
    @Test("recipe is stateless between calls")
    func recipeIsStatelessBetweenCalls() async throws {
        let (kit, handle) = try await openEstate()
        let log = WorkLog()
        let recipe = EchoRecipe(hostCapabilities: shippedNeuronKitCapabilities)

        let first = try await recipe.run(
            input: .init(text: "same", log: log), estate: handle, kit: kit)
        let second = try await recipe.run(
            input: .init(text: "same", log: log), estate: handle, kit: kit)

        #expect(first == second)
        #expect(await log.entries == ["work", "work"])
    }
}
