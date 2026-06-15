// GroundedSynthesisTests.swift
//
// End-to-end test of the GroundedSynthesis recipe against a real
// GeniusLocusKit estate over in-memory storage — no mocks. Proves the
// full through-line: GLK capture/recall → NeuronKit hybridRecall +
// ContextSynthesizer → CognitionKit recipe output.
//
// ISOLATION: all tests that call GroundedSynthesis.run() acquire the
// process-wide cognitionTestMutex (CognitionTestLock.swift). After the
// cp-cognitionkit-report telemetry addition, recipe-run functions emit
// to the Intellectus global singleton. A concurrent telemetry test that
// holds the singleton enabled would otherwise receive this test's
// emissions into its capturing sink and corrupt exact-count assertions.
// This is the same discipline NeuronKit applies to BradleyTerry/Dreaming/
// HybridRecall tests (IntellectusTestLock.swift).
//
// Tests that do NOT call run() (metadata-only) do not need the lock.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("GroundedSynthesisTests")
struct GroundedSynthesisTests {

    /// Open a fresh in-memory estate and capture the supplied contents
    /// into a single room. Returns the kit and its handle.
    private func makeEstate(
        capturing contents: [String]
    ) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "grounded-synth-test"))
        for text in contents {
            let frame = CaptureFrame(
                content: text,
                channel: .typed,
                room: "lab",
                latticeAnchor: .udc("540"),
                addedBy: "tester",
                embeddingModelID: "test-v1")
            _ = try await kit.capture(handle, frame)
        }
        return (kit, handle)
    }

    @Test("synthesizes over recalled drawers")
    func synthesizesOverRecalledDrawers() async throws {
        // Acquire the process-wide lock: GroundedSynthesis.run emits
        // cognitionkit.recipe.run to Intellectus; a concurrent telemetry
        // test holding the singleton enabled would count this test's
        // emissions in its capturing sink. See file-level comment.
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [
                "the organic chemistry of carbon compounds",
                "carbon based life and biochemistry",
                "introduction to quantum mechanics",
            ])

            // Recall the freshly-captured drawers. All rows written via
            // Estate.capture are stamped Confirmation.userConfirmed at write time,
            // so .userConfirmed is the correct filter to surface them.
            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.userConfirmed]))
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)

            #expect(out.drawerCount == 3)
            #expect(!out.context.summary.isEmpty,
                    "summary should be populated for a non-empty recall")
            // The dominant room is "lab" — the summary names it.
            #expect(out.context.summary.contains("lab"),
                    "summary should name the dominant room")
            // "carbon" appears in two drawers → a dominant pattern.
            #expect(out.context.patterns.contains("carbon"),
                    "repeated token should surface as a pattern")
        }
    }

    @Test("empty recall yields empty context")
    func emptyRecallYieldsEmptyContext() async throws {
        // Acquire the lock: GroundedSynthesis.run emits to Intellectus.
        // See file-level comment.
        try await withCognitionLock {
            let (kit, handle) = try await makeEstate(capturing: [])

            let input = GroundedSynthesis.Input(
                frame: LocusKit.RecallFrame(filterChain: [.userConfirmed]))
            let out = try await GroundedSynthesis().run(
                input: input, estate: handle, kit: kit)

            #expect(out.drawerCount == 0)
            #expect(out.context.summary.isEmpty)
            #expect(out.context.patterns.isEmpty)
        }
    }

    @Test("capability metadata is declared")
    func capabilityMetadataIsDeclared() {
        let recipe = GroundedSynthesis()
        #expect(recipe.name == "grounded_synthesis")
        #expect(Set(recipe.requiredCapabilities) == [.hybridRecall, .synthesize])
    }
}
