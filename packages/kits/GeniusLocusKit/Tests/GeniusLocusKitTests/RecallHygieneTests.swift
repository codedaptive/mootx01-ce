// RecallHygieneTests.swift
//
// TDD coverage for recall-hygiene fix (fix/recall-hygiene-charters-ghosts):
//
// Bug A — Charter pollution:
//   Wing `_charter` drawers (room == "_charter", embeddingModelID == "none") are
//   wing metadata seeded at provision time. They must NOT surface as content hits
//   in scored recall (locusOnly, unionBest, or any lane). They remain reachable
//   via estate-map / enumerate but are excluded from the recall candidate set.
//
// Bug B — Ghost IDs:
//   Every hit returned by recall must have a non-nil `drawer` field that resolves
//   to a live, hydratable content drawer. Nil-drawer hits (ghost IDs — IDs in the
//   recall candidate pool that have no backing row in the drawers table) must be
//   dropped before the result is returned.
//
// Tests:
//   H1  locusOnly excludes charter drawers — all returned hits are non-charter rooms
//   H2  unionBest excludes charter drawers — same, via the full multi-lane pipeline
//   H3  locusOnly hit count == content drawer count (not charter + content)
//   H4  unionBest hit count == content drawer count (not charter + content)
//   H5  all recalled hits have non-nil drawer (ghost guard — locusOnly)
//   H6  all recalled hits have non-nil drawer (ghost guard — unionBest)
//   H7  charter drawers are still reachable via allDrawers (not deleted, just excluded)
//   H8  recall returns correct content after fix (content drawers still rank)

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
@testable import GeniusLocusKit

/// Number of default wings seeded by provision(). Charter drawers == one per wing.
private let defaultWingCount = LocusKit.defaultWings.count

@Suite("Recall hygiene — charter exclusion and ghost-ID guard")
struct RecallHygieneTests {

    // MARK: - Estate factory

    /// Provision a GLK estate (InMemory) with `contentCount` user-memory drawers.
    /// Returns the kit, handle, and the captured user drawers.
    ///
    /// After provision, the estate has `defaultWingCount` charter drawers in
    /// room `_charter` plus `contentCount` content drawers in room "hygiene-test".
    /// Charter drawers have `embeddingModelID == "none"` (excluded from BM25/vector).
    /// Content drawers have `embeddingModelID == "test-model-v1"` (eligible for
    /// BM25/vector if a corpus is wired).
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

        // Capture N content drawers in a non-charter room.
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

    // MARK: - H1: locusOnly excludes charter drawers

    /// locusOnly recall on a provisioned estate must return ZERO hits in the
    /// `_charter` room. Charter drawers are wing metadata, not recallable content.
    @Test
    func locusOnlyExcludesCharterDrawers() async throws {
        let (kit, handle, _) = try await provisionedEstate(contentCount: 4)
        let request = GLKRecallRequest(
            frame: fullFrame(),
            mode: .locusOnly,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)

        let charterHits = result.hits.filter { hit in
            hit.drawer?.room == LocusKit.charterRoom
        }
        #expect(charterHits.isEmpty,
            "locusOnly recall must return zero charter hits; got \(charterHits.count)")
    }

    // MARK: - H2: unionBest excludes charter drawers

    /// unionBest recall (the full multi-lane pipeline) must return ZERO hits in
    /// the `_charter` room, regardless of locus/BM25/vector lane contributions.
    @Test
    func unionBestExcludesCharterDrawers() async throws {
        let (kit, handle, _) = try await provisionedEstate(contentCount: 4)
        let request = GLKRecallRequest(
            frame: fullFrame(),
            mode: .unionBest,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: "user memory")
        let result = try await kit.recall(handle, request)

        let charterHits = result.hits.filter { hit in
            hit.drawer?.room == LocusKit.charterRoom
        }
        #expect(charterHits.isEmpty,
            "unionBest recall must return zero charter hits; got \(charterHits.count)")
    }

    // MARK: - H3: locusOnly hit count == content drawer count

    /// After excluding charter drawers, locusOnly must return exactly as many hits
    /// as there are content drawers (not content + charter).
    @Test
    func locusOnlyHitCountEqualsContentDrawerCount() async throws {
        let contentCount = 4
        let (kit, handle, _) = try await provisionedEstate(contentCount: contentCount)
        let request = GLKRecallRequest(
            frame: fullFrame(limit: 100),
            mode: .locusOnly,
            scoring: .raw,
            limit: 100,
            fallback: .allowDegraded,
            queryText: nil)
        let result = try await kit.recall(handle, request)

        #expect(result.hits.count == contentCount,
            "locusOnly must return \(contentCount) content hits, not \(result.hits.count) (charter drawers must be excluded)")
    }

    // MARK: - H4: unionBest hit count == content drawer count

    /// After excluding charter drawers, unionBest must return exactly as many hits
    /// as there are content drawers when querying with text that matches only content.
    @Test
    func unionBestHitCountEqualsContentDrawerCount() async throws {
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

        #expect(result.hits.count == contentCount,
            "unionBest must return \(contentCount) content hits, not \(result.hits.count) (charter drawers must be excluded)")
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

    // MARK: - H7: charter drawers still exist in the estate

    /// Excluding charters from recall must not delete them. They remain accessible
    /// via `estate.allDrawers()` (the estate-map path, not the recall path).
    @Test
    func charterDrawersStillExistInEstate() async throws {
        let contentCount = 4
        let (kit, handle, _) = try await provisionedEstate(contentCount: contentCount)
        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()

        let charterDrawers = allDrawers.filter { $0.room == LocusKit.charterRoom }
        let contentDrawers = allDrawers.filter { $0.room != LocusKit.charterRoom }

        // Charter drawers must still be in the estate (just not in recall).
        #expect(charterDrawers.count == defaultWingCount,
            "estate must still have \(defaultWingCount) charter drawers; got \(charterDrawers.count)")
        // Content drawers must all be present.
        #expect(contentDrawers.count == contentCount,
            "estate must have \(contentCount) content drawers; got \(contentDrawers.count)")
    }

    // MARK: - H8: recall returns correct content drawers after fix

    /// After charter exclusion, the returned hits must be exactly the captured
    /// content drawers — no more, no less, all correctly hydrated.
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
        #expect(returnedIDs == contentIDs,
            "locusOnly must return exactly the content drawer IDs, not the charter set")
    }
}
