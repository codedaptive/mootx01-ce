// DistilledRecallTests.swift
//
// End-to-end tests for the DistilledRecall recipe over a real
// GeniusLocusKit in-memory estate. No mocks.
//
// SPEC_DISTILLATION_STORAGE §10.3: `distilled_recall` is exact-search
// geometry over ORIGINALS + distilled hydration of the hits. These tests
// pin the §13.4 recall-equivalence criterion (identical ids and order to
// the exact-search path), the §10.2 fallback marker, and per-hit token
// counts (§6).
//
// Coverage:
//   CK-DR-1: distilled estate — hits hydrate the distilled rendering with
//            token counts; payloads are strictly smaller than content.
//   CK-DR-2: recall equivalence — ids and order identical to the
//            exact-search request for the same query (§13.4).
//   CK-DR-3: undistilled rows fall back to content with the
//            served-from-content marker (§10.2).
//   CK-DR-4: empty estate → matches = [], no crash.

import Testing
import Foundation
import EngramLib
import GeniusLocusKit
import LocusKit
import NeuronKit
import VectorKit
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

    /// Capture one ordinary drawer; optionally distill it (on-row columns).
    @discardableResult
    private func capture(
        _ content: String,
        distill: Bool,
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
        if distill {
            try await kit.distillItem(
                handle: handle, drawerID: drawer.id, content: content,
                distillFn: GeniusLocusKit.defaultDistillFn, now: t0)
        }
        return drawer.id
    }

    /// The exact-search request DistilledRecall mirrors, run directly —
    /// the §13.4 comparison arm.
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
            queryText: query)
        let result = try await kit.recall(handle, request)
        return result.hits.compactMap { $0.drawer?.id }
    }

    // MARK: - CK-DR-1: distilled hydration

    @Test("CK-DR-1: hits hydrate the distilled rendering with token counts")
    func distilledHydration() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()
            let body = "The reactor schedule moved to March. Sarah approved the reactor plan. "
                + "The reactor uptime is twelve percent better."
            let id = try await capture(body, distill: true, kit: kit, handle: handle)

            let output = try await DistilledRecall().run(
                input: DistilledRecall.Input(query: "reactor schedule"),
                estate: handle, kit: kit)

            let match = try #require(output.matches.first { $0.id == id })
            #expect(!match.servedFromContent, "a distilled row serves its representation")
            #expect(match.tokenCount != nil, "per-hit token count must be present (§13.4)")
            // The rendering is the row's distilled column — denser than content.
            #expect(match.text != body)
            #expect(match.text.utf8.count < body.utf8.count,
                "distilled payloads are strictly smaller on distilled rows")
            #expect(!match.text.hasPrefix("[DIST|"))
        }
    }

    // MARK: - CK-DR-2: recall equivalence (§13.4)

    @Test("CK-DR-2: ranking is identical to the exact-search path (ids and order)")
    func recallEquivalence() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()
            for body in [
                "The reactor schedule moved to March. Sarah approved the plan. Uptime improved.",
                "Vendor contracts were renewed yesterday. The vendor is in Geneva. Terms held.",
                "Travel policy updates landed. Flights require approval. Hotels are capped.",
            ] {
                _ = try await capture(body, distill: true, kit: kit, handle: handle)
            }

            for query in ["reactor schedule", "vendor Geneva", "travel policy"] {
                let exact = try await exactSearchIDs(kit, handle, query: query)
                let distilled = try await DistilledRecall().run(
                    input: DistilledRecall.Input(query: query),
                    estate: handle, kit: kit)
                #expect(distilled.matches.map(\.id) == exact,
                    "§13.4: distilled recall must rank identically to exact search")
            }
        }
    }

    // MARK: - CK-DR-3: §10.2 fallback

    @Test("CK-DR-3: undistilled rows fall back to content with the marker")
    func fallbackMarker() async throws {
        try await withCognitionLock {
            let (kit, handle) = try await openEstate()
            let body = "The undistilled reactor note stands alone."
            let id = try await capture(body, distill: false, kit: kit, handle: handle)

            let output = try await DistilledRecall().run(
                input: DistilledRecall.Input(query: "reactor note"),
                estate: handle, kit: kit)

            let match = try #require(output.matches.first { $0.id == id })
            #expect(match.servedFromContent, "§10.2: pre-sweep rows serve content, marked")
            #expect(match.text == body, "the fallback payload is the verbatim content")
            #expect(match.tokenCount == nil, "no representation → no stored token count")
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
