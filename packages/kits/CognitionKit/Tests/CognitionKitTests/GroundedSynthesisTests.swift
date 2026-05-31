// GroundedSynthesisTests.swift
//
// End-to-end test of the GroundedSynthesis recipe against a real
// GeniusLocusKit estate over in-memory storage — no mocks. Proves the
// full through-line: GLK capture/recall → NeuronKit hybridRecall +
// ContextSynthesizer → CognitionKit recipe output.

import XCTest
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import CognitionKit

final class GroundedSynthesisTests: XCTestCase {

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

    func testSynthesizesOverRecalledDrawers() async throws {
        let (kit, handle) = try await makeEstate(capturing: [
            "the organic chemistry of carbon compounds",
            "carbon based life and biochemistry",
            "introduction to quantum mechanics",
        ])

        // Recall the freshly-captured (unconfirmed) drawers. The recall
        // evaluator defaults the confirmation axis to userConfirmed when
        // unconstrained, so .unconfirmed is required to see them.
        let input = GroundedSynthesis.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]))
        let out = try await GroundedSynthesis().run(
            input: input, estate: handle, kit: kit)

        XCTAssertEqual(out.drawerCount, 3)
        XCTAssertFalse(out.context.summary.isEmpty,
                       "summary should be populated for a non-empty recall")
        // The dominant room is "lab" — the summary names it.
        XCTAssertTrue(out.context.summary.contains("lab"),
                      "summary should name the dominant room")
        // "carbon" appears in two drawers → a dominant pattern.
        XCTAssertTrue(out.context.patterns.contains("carbon"),
                      "repeated token should surface as a pattern")
    }

    func testEmptyRecallYieldsEmptyContext() async throws {
        let (kit, handle) = try await makeEstate(capturing: [])

        let input = GroundedSynthesis.Input(
            frame: LocusKit.RecallFrame(filterChain: [.unconfirmed]))
        let out = try await GroundedSynthesis().run(
            input: input, estate: handle, kit: kit)

        XCTAssertEqual(out.drawerCount, 0)
        XCTAssertTrue(out.context.summary.isEmpty)
        XCTAssertTrue(out.context.patterns.isEmpty)
    }

    func testCapabilityMetadataIsDeclared() {
        let recipe = GroundedSynthesis()
        XCTAssertEqual(recipe.name, "grounded_synthesis")
        XCTAssertEqual(Set(recipe.requiredCapabilities),
                       [.hybridRecall, .synthesize])
    }
}
