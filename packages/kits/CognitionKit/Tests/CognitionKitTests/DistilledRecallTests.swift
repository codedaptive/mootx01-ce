// DistilledRecallTests.swift
//
// End-to-end tests for the DistilledRecall recipe over a real
// GeniusLocusKit in-memory estate. No mocks.
//
// Inline rendering: distillation is computed at read time from the
// verbatim content column via ContextDistillLib. There is no sweep,
// no "not yet distilled" state, and no fallback path — every captured
// item renders on its first recall hit.
//
// Coverage:
//   CK-DR-1: hit hydrates the inline distilled rendering with a token count.
//   CK-DR-2: recall equivalence — ids and order identical to the
//            exact-search request for the same query.
//   CK-DR-3: every row renders inline — no fallback marker, no sweep needed.
//   CK-DR-4: empty estate → matches = [], no crash.

import Testing
import Foundation
import EngramLib
import GeniusLocusKit
import LocusKit
import NeuronKit
import SynapseKit
import SubstrateML
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("DistilledRecallTests")
struct DistilledRecallTests {

    /// Deterministic seed time — never Date() in tests that assert ordering.
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Helpers

    /// Open an in-memory estate (locus recall lane; the exact-search
    /// request degrades gracefully with no corpus registered).
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "distilled-recall-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Capture one ordinary drawer. Inline rendering requires no sweep step.
    @discardableResult
    private func capture(
        _ content: String,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "notes",
            latticeAnchor: .udc("0"),
            addedBy: "distilled-recall-tests",
            embeddingModelID: "test-v1")
        let drawer = try await kit.capture(handle, frame)
        return drawer.id
    }

    /// The exact-search request DistilledRecall mirrors, run directly —
    /// the ranking-equivalence comparison arm.
    private func exactSearchIDs(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, query: String, limit: Int = 20
    ) async throws -> [String] {
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.currentlyBelieve], hydrationLevel: .full, limit: limit),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: limit,
            fallback: .allowDegraded,
            queryText: query,
            origin: .internal)
        let result = try await kit.recall(handle, request)
        return result.hits.compactMap { $0.drawer?.id }
    }

    // MARK: - CK-DR-1: inline distilled hydration

    @Test("CK-DR-1: hits hydrate the inline distilled rendering with token counts")
    func distilledHydration() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()
            let body = "The reactor schedule moved to March. Sarah approved the reactor plan. "
                + "The reactor uptime is twelve percent better."
            let id = try await capture(body, kit: kit, handle: handle)

            let output = try await DistilledRecall().run(
                input: DistilledRecall.Input(query: "reactor schedule"),
                estate: handle, kit: kit)

            let match = try #require(output.matches.first { $0.id == id })
            // Every row renders inline — the text is ContextDistillLib's
            // rendering of the verbatim content. Payload is the converter's
            // output; for a short body the exact-span converter may keep
            // every source byte, so the contract is identity with the converter.
            #expect(match.text == GeniusLocusKit.distilledRendering(of: body))
            #expect(match.tokenCount == GeniusLocusKit.estimatedTokenCount(of: match.text),
                "per-hit token count must equal estimatedTokenCount for the rendered text")
            #expect(!match.text.hasPrefix("[DIST|"))
        }
    }

    // MARK: - CK-DR-2: recall equivalence

    @Test("CK-DR-2: ranking is identical to the exact-search path (ids and order)")
    func recallEquivalence() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()
            for body in [
                "The reactor schedule moved to March. Sarah approved the plan. Uptime improved.",
                "Vendor contracts were renewed yesterday. The vendor is in Geneva. Terms held.",
                "Travel policy updates landed. Flights require approval. Hotels are capped.",
            ] {
                _ = try await capture(body, kit: kit, handle: handle)
            }

            for query in ["reactor schedule", "vendor Geneva", "travel policy"] {
                let exact = try await exactSearchIDs(kit, handle, query: query)
                let distilled = try await DistilledRecall().run(
                    input: DistilledRecall.Input(query: query),
                    estate: handle, kit: kit)
                #expect(distilled.matches.map(\.id) == exact,
                    "distilled recall must rank identically to exact search")
            }
        }
    }

    // MARK: - CK-DR-3: inline rendering on every row

    @Test("CK-DR-3: every row renders inline — no sweep needed, no fallback")
    func everyRowRendersInline() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()
            let body = "The inline rendering note stands alone."
            let id = try await capture(body, kit: kit, handle: handle)

            let output = try await DistilledRecall().run(
                input: DistilledRecall.Input(query: "inline rendering note"),
                estate: handle, kit: kit)

            let match = try #require(output.matches.first { $0.id == id })
            // Inline rendering: the text is the converter output, computed at
            // read time. There is no stored column, no sweep, no fallback.
            #expect(match.text == GeniusLocusKit.distilledRendering(of: body))
            #expect(match.tokenCount == GeniusLocusKit.estimatedTokenCount(of: match.text))
        }
    }

    // MARK: - CK-DR-4: Empty estate

    @Test("CK-DR-4: empty estate returns empty matches without crash")
    func emptyEstateReturnsEmpty() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()

            let output = try await DistilledRecall().run(
                input: DistilledRecall.Input(query: "anything"),
                estate: handle, kit: kit)

            #expect(output.matches.isEmpty)
            #expect(output.discrimination == .single,
                "empty result must yield .single discrimination")
        }
    }
}
