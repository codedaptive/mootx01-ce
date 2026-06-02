// FormalConceptsTests.swift
//
// End-to-end tests for the FormalConcepts recipe against a real
// GeniusLocusKit estate over in-memory storage — no mocks. Verifies
// the full through-line: GLK recall → FormalContext construction
// (one row per drawer, field-value labels as attributes) →
// BoundedConceptMiner → typed output.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// `.serialized`: estate-touching tests run one at a time.
@Suite("FormalConceptsTests", .serialized)
struct FormalConceptsTests {

    // MARK: - Harness

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "fa-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        room: String,
        kind: ContentKind = .prose,
        channel: CaptureChannel = .typed
    ) async throws {
        let frame = CaptureFrame(
            content: "test content",
            channel: channel,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "fa-test",
            embeddingModelID: "test-v1",
            kind: kind)
        _ = try await kit.capture(handle, frame)
    }

    // MARK: - Tests

    // CK-FA-1: empty estate — no drawers, no concepts.
    @Test("empty estate yields no concepts")
    func emptyEstateYieldsNoConcepts() async throws {
        let (kit, handle) = try await openEstate()
        let input = FormalConcepts.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            miner: .init(minSupport: 1, maxIntentSize: 8, maxConcepts: 8))
        let out = try await FormalConcepts().run(
            input: input, estate: handle, kit: kit)
        #expect(out.concepts.isEmpty)
        #expect(out.drawerCount == 0)
    }

    // CK-FA-2: two disjoint cohorts produce two concepts.
    //
    // 3 drawers: room "study", kind prose, channel typed →
    //   attributes include ("locus","room","study"), ("locus","kind","prose"),
    //   ("locus","channel","typed"), ("locus","sensitivity","normal")
    // 2 drawers: room "work", kind code, channel voiced →
    //   attributes include ("locus","room","work"), ("locus","kind","code"),
    //   ("locus","channel","voiced"), ("locus","sensitivity","normal")
    //
    // The two cohorts share only sensitivity:normal. Each sub-cohort's
    // room+kind+channel labels close together → two distinct concepts
    // (plus potentially a shared concept for sensitivity:normal alone).
    // We assert at least 2 concepts and that their extents are non-trivial.
    @Test("two disjoint cohorts yield at least two concepts")
    func twoCohorts() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 {
            try await capture(kit, handle, room: "study", kind: .prose, channel: .typed)
        }
        for _ in 0..<2 {
            try await capture(kit, handle, room: "work", kind: .code, channel: .voiced)
        }

        let input = FormalConcepts.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            miner: .init(minSupport: 2, maxIntentSize: 8, maxConcepts: 10))
        let out = try await FormalConcepts().run(
            input: input, estate: handle, kit: kit)

        #expect(out.drawerCount == 5)
        // At least the sensitivity:normal concept (all 5 drawers) and
        // one cohort-specific concept.
        #expect(out.concepts.count >= 2)
        // Concepts are sorted by support descending.
        if out.concepts.count >= 2 {
            #expect(out.concepts[0].support >= out.concepts[1].support)
        }
    }

    // CK-FA-3: concept extents and intents are non-empty and have string labels.
    @Test("concept fields are populated")
    func conceptFieldsPopulated() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<2 {
            try await capture(kit, handle, room: "study", kind: .prose, channel: .typed)
        }

        let input = FormalConcepts.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            miner: .init(minSupport: 1, maxIntentSize: 8, maxConcepts: 8))
        let out = try await FormalConcepts().run(
            input: input, estate: handle, kit: kit)

        #expect(!out.concepts.isEmpty)
        for concept in out.concepts {
            #expect(concept.support > 0)
            #expect(!concept.intent.isEmpty)
            // Drawer IDs are returned as strings.
            #expect(!concept.extentDrawerIDs.isEmpty)
        }
    }

    // CK-FA-4: capability gate fires — the recipe declares .formalConceptAnalysis
    // and verifyCapabilities correctly rejects when that capability is absent.
    @Test("capability declaration is formalConceptAnalysis")
    func capabilityDeclaration() {
        let recipe = FormalConcepts()
        #expect(recipe.requiredCapabilities == [.formalConceptAnalysis])
        // The gate correctly rejects a host that does not supply this capability.
        #expect(throws: RecipeError.missingCapability(.formalConceptAnalysis)) {
            try verifyCapabilities(
                required: recipe.requiredCapabilities,
                available: [.hybridRecall])
        }
    }

    // CK-FA-5: determinism — same recalled set yields identical concepts.
    @Test("two runs on the same estate produce identical concepts")
    func conceptsAreDeterministic() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 {
            try await capture(kit, handle, room: "study", kind: .prose, channel: .typed)
        }
        for _ in 0..<2 {
            try await capture(kit, handle, room: "work", kind: .code, channel: .voiced)
        }

        let input = FormalConcepts.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]),
            miner: .init(minSupport: 1, maxIntentSize: 8, maxConcepts: 10))
        let first = try await FormalConcepts().run(input: input, estate: handle, kit: kit)
        let second = try await FormalConcepts().run(input: input, estate: handle, kit: kit)

        #expect(first.concepts.count == second.concepts.count)
        for (a, b) in zip(first.concepts, second.concepts) {
            #expect(a.intent == b.intent)
            #expect(a.support == b.support)
        }
    }
}
