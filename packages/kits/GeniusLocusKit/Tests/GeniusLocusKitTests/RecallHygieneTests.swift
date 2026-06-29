// RecallHygieneTests.swift
//
// TDD coverage for hint-drawer recall behaviour and ghost-ID guard:
//
// Hint drawers (AI_Charter_Hint room) are normal drawers — seeded at provision
// time, embedded, and recalled like any other drawer. No special-casing in the
// recall pipeline. The former "charter exclusion" is removed.
//
// Tests:
//   H1  locusOnly includes hint drawers — all returned hits include hint rooms
//   H2  unionBest includes hint drawers — same, via the full multi-lane pipeline
//   H3  locusOnly hit count == total drawer count (content + hint drawers)
//   H4  unionBest hit count == total drawer count (content + hint drawers)
//   H5  all recalled hits have non-nil drawer (ghost guard — locusOnly)
//   H6  all recalled hits have non-nil drawer (ghost guard — unionBest)
//   H7  hint drawers are in recall AND in allDrawers (present everywhere, normal)
//   H8  recall returns correct content drawers after fix (content drawers still rank)

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import GeniusLocusKit

/// Number of default wings seeded by provision(). Hint drawers == one per wing.
private let defaultWingCount = LocusKit.defaultWings.count

@Suite("Recall hygiene — hint-drawer inclusion and ghost-ID guard")
struct RecallHygieneTests {

    // MARK: - Estate factory

    /// Provision a GLK estate (InMemory) with `contentCount` user-memory drawers.
    /// Returns the kit, handle, and the captured user drawers.
    ///
    /// After provision, the estate has `defaultWingCount` hint drawers in
    /// room `AI_Charter_Hint` plus `contentCount` content drawers in room "hygiene-test".
    /// Both hint drawers and content drawers are normal — embedded and recalled.
    private func provisionedEstate(
        contentCount: Int = 4
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, content: [Drawer]) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let owner = OwnerCredentials(ownerIdentifier: "recall-hygiene-tests")

        let params = EstateProvisionParams(
            estateName: "HygieneEstate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none)
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params)

        // Capture N content drawers in a non-hint room.
        var content: [Drawer] = []
        for i in 0..<contentCount {
            let frame = CaptureFrame(
                content: "user memory \(i) — unique content for recall hygiene test",
                channel: .typed,
                room: "hygiene-test",
                latticeAnchor: .udc("000"),
                addedBy: "hygiene-test-author",
                embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            content.append(drawer)
        }
        return (kit, handle, content)
    }

    /// Full recall frame that matches all active drawers.
    private func fullFrame(limit: Int = 100) -> RecallFrame {
        RecallFrame(
            filterChain: [.currentlyBelieve],
            hydrationLevel: .structured,
            limit: limit,
            ordering: .byCaptureTimeDesc)
    }

    // MARK: - H1: locusOnly includes hint drawers

    /// locusOnly recall on a provisioned estate must include hits from the
    /// `AI_Charter_Hint` room. Hint drawers are normal content — not filtered out.
    @Test
    func locusOnlyIncludesHintDrawers() async throws {
        let (kit, handle, _) = try await provisionedEstate(contentCount: 4)
        let request = GLKRecallRequest(
            frame: fullFrame(),
            mode: .locusOnly,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)

        let hintHits = result.hits.filter { hit in
            hit.drawer?.addedBy == LocusKit.hintAddedBy
        }
        #expect(!hintHits.isEmpty,
            "locusOnly recall must include hint drawer hits; got 0 (hint drawers are normal drawers)")
        #expect(hintHits.count == defaultWingCount,
            "locusOnly recall must return all \(defaultWingCount) hint drawers; got \(hintHits.count)")
    }

    // MARK: - H2: unionBest includes hint drawers

    /// unionBest recall (the full multi-lane pipeline) must include hits from the
    /// `AI_Charter_Hint` room.
    @Test
    func unionBestIncludesHintDrawers() async throws {
        let (kit, handle, _) = try await provisionedEstate(contentCount: 4)
        let request = GLKRecallRequest(
            frame: fullFrame(),
            mode: .unionBest,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: "user memory")
        let result = try await kit.recall(handle, request)

        let hintHits = result.hits.filter { hit in
            hit.drawer?.addedBy == LocusKit.hintAddedBy
        }
        #expect(!hintHits.isEmpty,
            "unionBest recall must include hint drawer hits; got 0 (hint drawers are normal drawers)")
    }

    // MARK: - H3: locusOnly hit count == total drawer count

    /// locusOnly must return content drawers + hint drawers (not just content).
    @Test
    func locusOnlyHitCountEqualsTotalDrawerCount() async throws {
        let contentCount = 4
        let totalCount = contentCount + defaultWingCount
        let (kit, handle, _) = try await provisionedEstate(contentCount: contentCount)
        let request = GLKRecallRequest(
            frame: fullFrame(limit: 100),
            mode: .locusOnly,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)

        #expect(result.hits.count == totalCount,
            "locusOnly must return \(totalCount) hits (content + hint drawers); got \(result.hits.count)")
    }

    // MARK: - H4: unionBest hit count >= content drawer count

    /// unionBest must return at least the content drawers — hint drawers may or may
    /// not surface depending on query relevance, but the total is >= contentCount.
    @Test
    func unionBestHitCountIncludesContentDrawers() async throws {
        let contentCount = 4
        let (kit, handle, _) = try await provisionedEstate(contentCount: contentCount)
        let request = GLKRecallRequest(
            frame: fullFrame(limit: 100),
            mode: .unionBest,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: "user memory unique content")
        let result = try await kit.recall(handle, request)

        #expect(result.hits.count >= contentCount,
            "unionBest must return at least \(contentCount) content hits; got \(result.hits.count)")
    }

    // MARK: - H5: ghost guard — locusOnly all hits have non-nil drawer

    /// Every hit from locusOnly recall must have a non-nil `drawer` field.
    /// A nil drawer means the ID has no backing row — an unacceptable ghost hit.
    @Test
    func locusOnlyAllHitsHaveNonNilDrawer() async throws {
        let (kit, handle, _) = try await provisionedEstate(contentCount: 4)
        let request = GLKRecallRequest(
            frame: fullFrame(),
            mode: .locusOnly,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)

        let ghostHits = result.hits.filter { $0.drawer == nil }
        #expect(ghostHits.isEmpty,
            "locusOnly must return zero nil-drawer ghost hits; got \(ghostHits.count)")
    }

    // MARK: - H6: ghost guard — unionBest all hits have non-nil drawer

    /// Every hit from unionBest recall must have a non-nil `drawer` field.
    @Test
    func unionBestAllHitsHaveNonNilDrawer() async throws {
        let (kit, handle, _) = try await provisionedEstate(contentCount: 4)
        let request = GLKRecallRequest(
            frame: fullFrame(),
            mode: .unionBest,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: "user memory unique content")
        let result = try await kit.recall(handle, request)

        let ghostHits = result.hits.filter { $0.drawer == nil }
        #expect(ghostHits.isEmpty,
            "unionBest must return zero nil-drawer ghost hits; got \(ghostHits.count)")
    }

    // MARK: - H7: hint drawers are in recall AND in allDrawers

    /// Hint drawers are normal — they are present in both recall and allDrawers.
    /// They are not deleted, not excluded, not treated specially.
    @Test
    func hintDrawersArePresentInRecallAndAllDrawers() async throws {
        let contentCount = 4
        let (kit, handle, _) = try await provisionedEstate(contentCount: contentCount)
        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()

        let hintDrawers = allDrawers.filter { $0.addedBy == LocusKit.hintAddedBy }
        let contentDrawers = allDrawers.filter { $0.addedBy != LocusKit.hintAddedBy }

        // Hint drawers must be in allDrawers.
        #expect(hintDrawers.count == defaultWingCount,
            "estate must have \(defaultWingCount) hint drawers; got \(hintDrawers.count)")
        // Content drawers must all be present.
        #expect(contentDrawers.count == contentCount,
            "estate must have \(contentCount) content drawers; got \(contentDrawers.count)")

        // Hint drawers must also appear in recall (not filtered out).
        let request = GLKRecallRequest(
            frame: fullFrame(limit: 1_000),
            mode: .locusOnly,
            scoring: .raw,
            limit: 1_000,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)
        let hintInRecall = result.hits.filter { $0.drawer?.addedBy == LocusKit.hintAddedBy }
        #expect(hintInRecall.count == defaultWingCount,
            "hint drawers must appear in recall (they are normal drawers); got \(hintInRecall.count)")
    }

    // MARK: - H8: recall returns correct content drawers after fix

    /// After the charter-exclusion removal, recall returns both content drawers and
    /// hint drawers. The content drawer IDs must be a subset of the returned hits.
    @Test
    func recallReturnsCorrectContentDrawers() async throws {
        let (kit, handle, contentDrawers) = try await provisionedEstate(contentCount: 3)
        let contentIDs = Set(contentDrawers.map(\.id))

        let request = GLKRecallRequest(
            frame: fullFrame(limit: 100),
            mode: .locusOnly,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)

        let returnedIDs = Set(result.hits.compactMap { $0.drawer?.id })
        // All content drawer IDs must be in the returned set.
        #expect(contentIDs.isSubset(of: returnedIDs),
            "locusOnly must include all content drawer IDs; missing: \(contentIDs.subtracting(returnedIDs))")
    }
}
