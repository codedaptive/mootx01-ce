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
        // (LENS_DISCOVERABILITY_DECISION v2.0): the 2 foundational recipes
        // plus the 14 reasoning lenses plus the 3 analytics lenses plus
        // the 4 new temporal/entropy lenses (moment, rhythm, precedence,
        // complexity) = 23 total.
        #expect(RecipeCatalog.names.sorted() == [
            "anticipate",
            "apriori_rules",
            "association_rules",
            "bias",
            "complexity",
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
            "moment",
            "partial_cue_recall",
            "precedence",
            "rhythm",
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

    @Test("catalog names match catalog.rs declaration order — 23 entries")
    func catalogNamesMatchRustDeclarationOrder() {
        // Literal ordered list mirroring `recipe_catalog()` in catalog.rs.
        // Any reordering on either side, or a recipe added on one side but not
        // the other, breaks this test — that is its purpose.
        #expect(RecipeCatalog.names == [
            "grounded_synthesis",
            "migration_benchmark",
            "keystones",
            "constellation",
            "free_association",
            "theme_weather",
            "latent_themes",
            "bias",
            "drift",
            "contradiction",
            "trust_grounded_synthesis",
            "partial_cue_recall",
            "anticipate",
            "tunnel_successor",
            "mind_overlap",
            "estate_divergence",
            "association_rules",
            "formal_concepts",
            "apriori_rules",
            "moment",
            "rhythm",
            "precedence",
            "complexity",
        ])
    }

    @Test("apriori_rules descriptor matches catalog.rs byte-for-byte")
    func aprioriRulesDescriptorMatchesCatalogRS() throws {
        // Byte-for-byte parity anchor with the Rust apriori_rules descriptor
        // in catalog.rs. The Rust test `apriori_rules_descriptor_matches_swift`
        // mirrors this test — both must stay in sync.
        let d = try #require(RecipeCatalog.descriptor(named: "apriori_rules"))
        #expect(d.version == "1.0.0")
        #expect(d.description ==
            "Read the estate's audit log and mine multi-antecedent association rules via the Apriori algorithm.")
        #expect(d.requiredCapabilities == [.associationRuleMining])
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
