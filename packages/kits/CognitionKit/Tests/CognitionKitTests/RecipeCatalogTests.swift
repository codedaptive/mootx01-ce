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
        // Both versions of every recipe ship, so every recipe registers
        // (LENS_DISCOVERABILITY_DECISION v2.0): the 2 foundational
        // recipes plus the 14 reasoning lenses plus the 2 analytics lenses.
        #expect(RecipeCatalog.names.sorted() == [
            "anticipate",
            "association_rules",
            "bias",
            "constellation",
            "contradiction",
            "drift",
            "estate_divergence",
            "formal_concepts",
            "free_association",
            "grounded_synthesis",
            "keystones",
            "latent_themes",
            "migration_benchmark",
            "mind_overlap",
            "partial_cue_recall",
            "theme_weather",
            "trust_grounded_synthesis",
            "tunnel_successor",
        ])
    }

    @Test("lens descriptors carry their capability gates")
    func lensDescriptorsCarryCapabilityGates() throws {
        // trust_grounded_synthesis sequences NeuronKit synthesize and
        // declares it; the other lenses sequence no declared capability
        // and register with an empty set.
        let trust = try #require(RecipeCatalog.descriptor(named: "trust_grounded_synthesis"))
        #expect(trust.requiredCapabilities == [.synthesize])
        let keystones = try #require(RecipeCatalog.descriptor(named: "keystones"))
        #expect(keystones.requiredCapabilities.isEmpty)
        // Analytics lenses carry their respective capability requirements.
        let ar = try #require(RecipeCatalog.descriptor(named: "association_rules"))
        #expect(ar.requiredCapabilities == [.associationRuleMining])
        let fca = try #require(RecipeCatalog.descriptor(named: "formal_concepts"))
        #expect(fca.requiredCapabilities == [.formalConceptAnalysis])
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
