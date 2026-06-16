import Testing
import Foundation
import LocusKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

/// Round-trip tests for the captureKGFact and retireKGFact verb methods
/// added in GLK-VERB-EXT-01.
///
/// Tests cover the anchored-fact path (sourceDrawerID provided), the
/// freestanding path (sourceDrawerID = ""), same-SPO double-capture
/// (both rows land because captureKGFact generates per-call UUID ids),
/// retirement (retired facts exit the RowState Cluster-A active filter), and
/// the stale-handle guard.
@Suite("KGFact verb surface — captureKGFact and retireKGFact")
struct KGFactVerbTests {

    // MARK: - Scaffolding

    private func openOneEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-kgfact-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// A fixed test timestamp shared across tests that need a deterministic
    /// capture instant. January 1 2026 00:00:00 UTC.
    private var testNow: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - Test 1: captureKGFact with source drawer

    /// File a fact anchored to a named drawer, then recall it through
    /// `recallKGFacts`. The fact must appear with matching SPO fields.
    @Test("captureKGFact with sourceDrawerID: fact appears in recallKGFacts")
    func captureKGFactAnchored() async throws {
        let (kit, handle) = try await openOneEstate()
        let sourceID = "drawer-anchor-001"

        let captured = try await kit.captureKGFact(
            handle,
            subject: "Alice",
            predicate: "knows",
            object: "Bob",
            sourceDrawerID: sourceID,
            now: testNow
        )

        let facts = try await kit.recallKGFacts(handle)
        let match = facts.first { $0.id == captured.id }
        #expect(match != nil)
        #expect(match?.subject == "Alice")
        #expect(match?.predicate == "knows")
        #expect(match?.object == "Bob")
        #expect(match?.sourceDrawerID == sourceID)
    }

    // MARK: - Test 2: captureKGFact freestanding (empty sourceDrawerID)

    /// File a freestanding fact (sourceDrawerID = "") — the unanchored
    /// sentinel accepted by GLK-VERB-EXT-01. The fact must appear in
    /// recall results; the empty sourceDrawerID must round-trip.
    @Test("captureKGFact with empty sourceDrawerID: freestanding fact appears in recall")
    func captureKGFactFreestanding() async throws {
        let (kit, handle) = try await openOneEstate()

        let captured = try await kit.captureKGFact(
            handle,
            subject: "Paris",
            predicate: "isCapitalOf",
            object: "France",
            sourceDrawerID: "",
            now: testNow
        )

        let facts = try await kit.recallKGFacts(handle)
        let match = facts.first { $0.id == captured.id }
        #expect(match != nil)
        #expect(match?.subject == "Paris")
        #expect(match?.sourceDrawerID == "")
    }

    // MARK: - Test 3: captureKGFact same SPO twice

    /// Capture the same SPO triple twice with empty sourceDrawerID.
    /// Each call generates a fresh UUID for `id`, so both rows land and
    /// both appear in recall results. captureKGFact has no SPO-level
    /// deduplication; deduplication (if needed) is a caller responsibility.
    @Test("captureKGFact same SPO twice: both rows appear in recall")
    func captureKGFactSameSPOTwice() async throws {
        let (kit, handle) = try await openOneEstate()

        let first = try await kit.captureKGFact(
            handle,
            subject: "X",
            predicate: "relatesTo",
            object: "Y",
            sourceDrawerID: "",
            now: testNow
        )
        let second = try await kit.captureKGFact(
            handle,
            subject: "X",
            predicate: "relatesTo",
            object: "Y",
            sourceDrawerID: "",
            now: testNow
        )

        // Each capture generates a distinct id, so they do not conflict.
        #expect(first.id != second.id)

        let facts = try await kit.recallKGFacts(handle)
        let ids = facts.map(\.id)
        #expect(ids.contains(first.id))
        #expect(ids.contains(second.id))
    }

    // MARK: - Test 4: retireKGFact

    /// Capture a fact then retire it by rowID. After retirement the fact
    /// must no longer appear in `recallKGFacts` (the RowState Cluster-A
    /// active filter excludes State.withdrawn = 18, which is Cluster B).
    @Test("retireKGFact: retired fact exits active recall")
    func retireKGFactExitsRecall() async throws {
        let (kit, handle) = try await openOneEstate()

        let fact = try await kit.captureKGFact(
            handle,
            subject: "Sun",
            predicate: "isStarIn",
            object: "SolarSystem",
            sourceDrawerID: "",
            now: testNow
        )

        // Confirm it is recalled before retirement.
        let before = try await kit.recallKGFacts(handle)
        #expect(before.contains { $0.id == fact.id })

        try await kit.retireKGFact(handle, rowID: fact.id)

        // Must not appear in active recall after retirement.
        let after = try await kit.recallKGFacts(handle)
        #expect(!after.contains { $0.id == fact.id })
    }

    // MARK: - Test 5: stale handle

    /// After closing an estate, captureKGFact on the stale handle must
    /// throw `GeniusLocusKitError.estateNotOpen`.
    @Test("captureKGFact with stale handle throws estateNotOpen")
    func captureKGFactStaleHandle() async throws {
        let (kit, handle) = try await openOneEstate()
        try await kit.close(handle)

        await #expect(throws: GeniusLocusKitError.estateNotOpen(
            estateUUID: handle.estateUUID
        )) {
            _ = try await kit.captureKGFact(
                handle,
                subject: "stale",
                predicate: "test",
                object: "value",
                now: testNow
            )
        }
    }

    // MARK: - Test 6: recallKGFactTimeline shows active + retired

    /// File a fact, retire it, then call recallKGFactTimeline.
    /// The timeline must contain BOTH the active history (before retirement)
    /// and the retired entry, time-ordered. The fact is present once — its
    /// state transitions in-place — but it must appear in the timeline
    /// with the retired lifecycle tag (adjectiveBitmap bits 0-5 at/above the
    /// RowState active upper bound, i.e. RowState Cluster B/C).
    /// recallKGFacts (active-only) must NOT show it after retirement.
    @Test("recallKGFactTimeline: retired fact appears in timeline, not in active recall")
    func factTimelineShowsRetiredFact() async throws {
        let (kit, handle) = try await openOneEstate()

        let fact = try await kit.captureKGFact(
            handle,
            subject: "Earth",
            predicate: "orbits",
            object: "Sun",
            sourceDrawerID: "",
            now: testNow
        )

        // Before retirement: both active recall and timeline show the fact.
        let activeBefore = try await kit.recallKGFacts(handle)
        #expect(activeBefore.contains { $0.id == fact.id })

        let timelineBefore = try await kit.recallKGFactTimeline(handle)
        #expect(timelineBefore.contains { $0.id == fact.id })

        // Retire the fact.
        try await kit.retireKGFact(handle, rowID: fact.id)

        // After retirement: active recall must NOT show it.
        let activeAfter = try await kit.recallKGFacts(handle)
        #expect(!activeAfter.contains { $0.id == fact.id })

        // After retirement: timeline must show it at/above the active upper
        // bound (adjectiveBitmap bits 0-5 set to State.withdrawn rawValue = 18).
        let timelineAfter = try await kit.recallKGFactTimeline(handle)
        let retiredRow = timelineAfter.first { $0.id == fact.id }
        #expect(retiredRow != nil)
        let stateCluster = (retiredRow?.adjectiveBitmap ?? 0) & 0x3F
        // State.withdrawn rawValue is 18; 18 >= 16 (RowState Cluster B) confirms retired.
        #expect(stateCluster >= Int64(RowState.activeClusterUpperBoundRaw))
    }

    // MARK: - Test 7: fact_timeline entity filter

    /// File two facts with different subjects; recallKGFactTimeline with
    /// entity filter should return only the matching fact.
    @Test("recallKGFactTimeline entity filter: only matching facts returned")
    func factTimelineEntityFilter() async throws {
        let (kit, handle) = try await openOneEstate()

        let factAlice = try await kit.captureKGFact(
            handle,
            subject: "Alice",
            predicate: "worksAt",
            object: "ACME",
            sourceDrawerID: "",
            now: testNow
        )
        let factBob = try await kit.captureKGFact(
            handle,
            subject: "Bob",
            predicate: "worksAt",
            object: "ACME",
            sourceDrawerID: "",
            now: testNow
        )

        // Filter by "Alice" — must return Alice's fact, not Bob's.
        let filtered = try await kit.recallKGFactTimeline(handle, entity: "Alice")
        let ids = filtered.map(\.id)
        #expect(ids.contains(factAlice.id))
        #expect(!ids.contains(factBob.id))
    }

    // MARK: - Test 8: fact_search regression guard (active-only)

    /// Retire a fact; fact_search (recallKGFacts) must not return it.
    /// This is the regression guard ensuring recallKGFacts is unchanged.
    @Test("recallKGFacts regression: active-only — retired fact absent")
    func factSearchActiveOnlyRegression() async throws {
        let (kit, handle) = try await openOneEstate()

        let fact = try await kit.captureKGFact(
            handle,
            subject: "Pluto",
            predicate: "classifiedAs",
            object: "planet",
            sourceDrawerID: "",
            now: testNow
        )

        try await kit.retireKGFact(handle, rowID: fact.id)

        // Active-recall must not include the retired fact.
        let active = try await kit.recallKGFacts(handle)
        #expect(!active.contains { $0.id == fact.id })

        // Timeline includes it — the timeline and active paths are distinct.
        let timeline = try await kit.recallKGFactTimeline(handle)
        #expect(timeline.contains { $0.id == fact.id })
    }
}
