// RecipeCatalogTests.swift
//
// The catalog is the "broader reach" primitive: it must enumerate every
// shipped recipe and each descriptor must match the recipe's own
// metadata, so any enumerator (MCP surface, agent, composing recipe)
// sees the truth.

import XCTest
@testable import CognitionKit

final class RecipeCatalogTests: XCTestCase {

    func testCatalogListsAllShippedRecipes() {
        XCTAssertEqual(RecipeCatalog.names.sorted(),
                       ["grounded_synthesis", "migration_benchmark"])
    }

    func testDescriptorMatchesLiveRecipeMetadata() {
        // The descriptor projection must equal what the live recipe
        // reports — no drift between the catalog and the recipe.
        let gs = GroundedSynthesis()
        let descriptor = try? XCTUnwrap(
            RecipeCatalog.descriptor(named: gs.name))
        XCTAssertEqual(descriptor?.version, gs.version)
        XCTAssertEqual(descriptor?.description, gs.description)
        XCTAssertEqual(descriptor?.requiredCapabilities, gs.requiredCapabilities)
    }

    func testDescriptorProjectionFromRecipe() {
        let mb = MigrationBenchmark()
        let descriptor = RecipeDescriptor(mb)
        XCTAssertEqual(descriptor.name, "migration_benchmark")
        XCTAssertEqual(descriptor.requiredCapabilities,
                       [.deriveBranch, .benchmark, .promoteBranch])
    }

    func testUnknownNameYieldsNilDescriptor() {
        XCTAssertNil(RecipeCatalog.descriptor(named: "no_such_recipe"))
    }

    func testDescriptorRoundTripsThroughCodable() throws {
        let original = RecipeDescriptor(GroundedSynthesis())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecipeDescriptor.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
