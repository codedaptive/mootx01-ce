// RecipeCatalogTests.swift
//
// The catalog is the "broader reach" primitive: it must enumerate every
// shipped recipe and each descriptor must match the recipe's own
// metadata, so any enumerator (MCP surface, agent, composing recipe)
// sees the truth.

import Testing
import Foundation
@testable import CognitionKit

@Suite("RecipeCatalogTests")
struct RecipeCatalogTests {

    @Test("catalog lists all shipped recipes")
    func catalogListsAllShippedRecipes() {
        #expect(RecipeCatalog.names.sorted() == ["grounded_synthesis", "migration_benchmark"])
    }

    @Test("descriptor matches live recipe metadata")
    func descriptorMatchesLiveRecipeMetadata() throws {
        // The descriptor projection must equal what the live recipe
        // reports — no drift between the catalog and the recipe.
        let gs = GroundedSynthesis()
        let descriptor = try #require(RecipeCatalog.descriptor(named: gs.name))
        #expect(descriptor.version == gs.version)
        #expect(descriptor.description == gs.description)
        #expect(descriptor.requiredCapabilities == gs.requiredCapabilities)
    }

    @Test("descriptor projection from recipe")
    func descriptorProjectionFromRecipe() {
        let mb = MigrationBenchmark()
        let descriptor = RecipeDescriptor(mb)
        #expect(descriptor.name == "migration_benchmark")
        #expect(descriptor.requiredCapabilities == [.deriveBranch, .benchmark, .promoteBranch])
    }

    @Test("unknown name yields nil descriptor")
    func unknownNameYieldsNilDescriptor() {
        #expect(RecipeCatalog.descriptor(named: "no_such_recipe") == nil)
    }

    @Test("descriptor round-trips through Codable")
    func descriptorRoundTripsThroughCodable() throws {
        let original = RecipeDescriptor(GroundedSynthesis())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecipeDescriptor.self, from: data)
        #expect(decoded == original)
    }
}
