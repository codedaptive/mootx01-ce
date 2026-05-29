import XCTest
import EngramLib
import PersistenceKit
import PersistenceKitInMemory
@testable import VectorKit

/// Tests for `VectorStore` — SQLite-backed CRUD over the `vectors`
/// table. Per spec I-4 every stored vector is tagged with the model
/// ID and version that produced it; the round-trip and multi-model
/// tests below enforce that invariant.
///
/// Each test creates a fresh database in a temporary directory and
/// tears it down on completion so tests do not share state.
final class VectorStoreTests: XCTestCase {

    private func makeStore() async throws -> VectorStore {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage)
    }

    /// Round-trip: bytes written via `addVector` match bytes read via
    /// `getVector`. Confirms the Engram BLOB encoding is lossless.
    func testAddGetRoundTripPreservesEngramBytes() async throws {
        let store = try await makeStore()
        let engram = Engram(blocks: 0xDEAD_BEEF_CAFE_BABE,
                            0x0123_4567_89AB_CDEF,
                            0xFFFF_0000_FFFF_0000,
                            0x0000_FFFF_0000_FFFF)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.addVector(drawerID: "drawer-A",
                            engram: engram,
                            modelID: "minilm",
                            modelVersion: "1.0.0",
                            filedAt: now)

        let fetched = try await store.getVector(drawerID: "drawer-A",
                                          modelID: "minilm")
        XCTAssertEqual(fetched, engram)
    }

    /// Unknown drawer ID returns nil — `getVector` does not throw on
    /// missing rows, it surfaces absence as Optional.none.
    func testGetVectorReturnsNilForUnknownDrawer() async throws {
        let store = try await makeStore()
        let result = try await store.getVector(drawerID: "never-existed",
                                         modelID: "minilm")
        XCTAssertNil(result)
    }

    /// Two models for the same drawer: each is independently
    /// retrievable. Confirms `(drawer_id, model_id)` is the effective
    /// lookup key and the two rows do not collide.
    func testMultipleModelsStoredForSameDrawer() async throws {
        let store = try await makeStore()
        let minilmEngram = Engram(blocks: 0x1111, 0x2222, 0x3333, 0x4444)
        let gemmaEngram  = Engram(blocks: 0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD)
        let now = Date(timeIntervalSince1970: 1_700_000_100)

        try await store.addVector(drawerID: "drawer-X",
                            engram: minilmEngram,
                            modelID: "minilm",
                            modelVersion: "1.0.0",
                            filedAt: now)
        try await store.addVector(drawerID: "drawer-X",
                            engram: gemmaEngram,
                            modelID: "gemma",
                            modelVersion: "300m",
                            filedAt: now)

        let __r1 = try await store.getVector(drawerID: "drawer-X",
                                           modelID: "minilm")
        XCTAssertEqual(__r1,
                       minilmEngram)
        let __r2 = try await store.getVector(drawerID: "drawer-X",
                                           modelID: "gemma")
        XCTAssertEqual(__r2,
                       gemmaEngram)
    }

    /// `vectors(forDrawerID:)` returns all rows for one drawer in
    /// `filed_at` ASC order. Equal timestamps are not exercised here
    /// (mission spec calls for ASC order, no tiebreak guarantee).
    func testVectorsForDrawerReturnsAllOrderedByFiledAtAscending() async throws {
        let store = try await makeStore()
        let e1 = Engram(blocks: 1, 0, 0, 0)
        let e2 = Engram(blocks: 2, 0, 0, 0)
        let e3 = Engram(blocks: 3, 0, 0, 0)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_100)
        let t3 = Date(timeIntervalSince1970: 1_700_000_200)

        // Insert out of chronological order to exercise the ORDER BY.
        try await store.addVector(drawerID: "drawer-Y", engram: e2,
                            modelID: "mB", modelVersion: "1", filedAt: t2)
        try await store.addVector(drawerID: "drawer-Y", engram: e3,
                            modelID: "mC", modelVersion: "1", filedAt: t3)
        try await store.addVector(drawerID: "drawer-Y", engram: e1,
                            modelID: "mA", modelVersion: "1", filedAt: t1)

        let all = try await store.vectors(forDrawerID: "drawer-Y")
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.engram), [e1, e2, e3])
        XCTAssertEqual(all.map(\.modelID), ["mA", "mB", "mC"])
    }

    /// `deleteVector` removes exactly the matching `(drawer_id,
    /// model_id)` row; subsequent fetch returns nil.
    func testDeleteVectorRemovesRow() async throws {
        let store = try await makeStore()
        let engram = Engram(blocks: 0x42, 0, 0, 0)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.addVector(drawerID: "drawer-Z",
                            engram: engram,
                            modelID: "minilm",
                            modelVersion: "1.0.0",
                            filedAt: now)
        try await store.deleteVector(drawerID: "drawer-Z", modelID: "minilm")

        let __nil1 = try await store.getVector(drawerID: "drawer-Z",
                                          modelID: "minilm")
        XCTAssertNil(__nil1)
    }

    /// `modelID` and `modelVersion` round-trip on `vectors(forDrawerID:)`
    /// — the StoredVector record carries the spec I-4 tagging.
    func testModelAndVersionRoundTrip() async throws {
        let store = try await makeStore()
        let engram = Engram(blocks: 0xAA, 0xBB, 0xCC, 0xDD)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.addVector(drawerID: "drawer-V",
                            engram: engram,
                            modelID: "minilm-v6",
                            modelVersion: "1.0.0-alpha.3",
                            filedAt: now)

        let rows = try await store.vectors(forDrawerID: "drawer-V")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].drawerID, "drawer-V")
        XCTAssertEqual(rows[0].modelID, "minilm-v6")
        XCTAssertEqual(rows[0].modelVersion, "1.0.0-alpha.3")
        XCTAssertEqual(rows[0].engram, engram)
    }

    /// `addVector` twice with the same `(drawerID, modelID)` replaces
    /// the prior engram (upsert) — the second engram is what comes
    /// back on fetch, and `vectors(forDrawerID:)` returns exactly one
    /// row. Exercises the `ON CONFLICT(drawer_id, model_id) DO UPDATE`
    /// path required by mission Verification item 4.
    func testAddVectorUpsertsOnSameDrawerAndModel() async throws {
        let store = try await makeStore()
        let first  = Engram(blocks: 1, 2, 3, 4)
        let second = Engram(blocks: 5, 6, 7, 8)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_500)

        try await store.addVector(drawerID: "drawer-UP",
                            engram: first,
                            modelID: "minilm",
                            modelVersion: "1.0.0",
                            filedAt: t1)
        try await store.addVector(drawerID: "drawer-UP",
                            engram: second,
                            modelID: "minilm",
                            modelVersion: "1.0.1",
                            filedAt: t2)

        // The conflict path UPDATEs in place; the stored engram is the
        // most recent one and only one row exists for this drawer.
        let __r3 = try await store.getVector(drawerID: "drawer-UP",
                                            modelID: "minilm")
        XCTAssertEqual(__r3,
                       second)
        let rows = try await store.vectors(forDrawerID: "drawer-UP")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].engram, second)
        XCTAssertEqual(rows[0].modelVersion, "1.0.1")
    }

    /// Fresh store: `vectors(forDrawerID:)` for an unknown drawer
    /// returns the empty array, not nil.
    func testFreshStoreReturnsEmptyForUnknownDrawer() async throws {
        let store = try await makeStore()
        let rows = try await store.vectors(forDrawerID: "no-such-drawer")
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - VEC-04 — findNearest / findByKeyword

    /// Helper: load a small corpus into `store` under `modelID`. The
    /// engrams differ in low bits so Hamming distance from the probe
    /// (all zeros) is determined by `popcount(engram)`.
    private func seedCorpus(_ store: VectorStore,
                            modelID: String = "minilm") async throws {
        // Hamming distance from zero-engram:
        //   alpha:   1 bit  (block0 = 0x1)
        //   bravo:   2 bits (block0 = 0x3)
        //   charlie: 3 bits (block0 = 0x7)
        //   delta:   4 bits (block0 = 0xF)
        let entries: [(String, UInt64)] = [
            ("alpha-doc",   0x1),
            ("bravo-doc",   0x3),
            ("charlie-doc", 0x7),
            ("delta-doc",   0xF),
        ]
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (drawer, bits) in entries {
            try await store.addVector(drawerID: drawer,
                                engram: Engram(blocks: bits, 0, 0, 0),
                                modelID: modelID,
                                modelVersion: "1.0.0",
                                filedAt: now)
        }
    }

    /// `findNearest` returns exactly K results, sorted by Hamming
    /// distance ascending. With a zero probe and the seeded corpus,
    /// the K=2 result must be the two engrams with smallest popcount.
    func testFindNearestReturnsKResultsSortedByDistanceAscending() async throws {
        let store = try await makeStore()
        try await seedCorpus(store)
        let probe = Engram(blocks: 0, 0, 0, 0)

        let matches = try await store.findNearest(probe: probe,
                                             modelID: "minilm",
                                             limit: 2)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.drawerID), ["alpha-doc", "bravo-doc"])
        XCTAssertEqual(matches.map(\.distance), [1, 2])
        // Verify sort order is preserved across the full result list.
        for i in 1..<matches.count {
            XCTAssertLessThanOrEqual(matches[i - 1].distance,
                                     matches[i].distance)
        }
    }

    /// K > corpus size returns every row exactly once, still sorted
    /// distance ascending. Probes a zero engram against a 4-row corpus
    /// with K=10 — must return 4 matches in popcount-ascending order.
    func testFindNearestWithKLargerThanCorpusReturnsAllRows() async throws {
        let store = try await makeStore()
        try await seedCorpus(store)
        let probe = Engram(blocks: 0, 0, 0, 0)

        let matches = try await store.findNearest(probe: probe,
                                             modelID: "minilm",
                                             limit: 10)
        XCTAssertEqual(matches.count, 4)
        XCTAssertEqual(matches.map(\.drawerID),
                       ["alpha-doc", "bravo-doc", "charlie-doc", "delta-doc"])
        XCTAssertEqual(matches.map(\.distance), [1, 2, 3, 4])
    }

    /// Empty store: `findNearest` returns the empty array without
    /// error. Absence is modeled as `[]`, not as a thrown error.
    func testFindNearestOnEmptyStoreReturnsEmpty() async throws {
        let store = try await makeStore()
        let probe = Engram(blocks: 0xFFFF, 0, 0, 0)
        let matches = try await store.findNearest(probe: probe,
                                             modelID: "minilm",
                                             limit: 5)
        XCTAssertTrue(matches.isEmpty)
    }

    /// Each `VectorMatch.drawerID` must correspond to the row whose
    /// engram produced the reported `distance`. Re-derive each match's
    /// distance from the stored engram and confirm the result agrees.
    func testFindNearestIndicesMapToCorrectDrawerIDs() async throws {
        let store = try await makeStore()
        try await seedCorpus(store)
        let probe = Engram(blocks: 0, 0, 0, 0)

        let matches = try await store.findNearest(probe: probe,
                                             modelID: "minilm",
                                             limit: 4)
        XCTAssertEqual(matches.count, 4)
        for m in matches {
            let stored = try await store.getVector(drawerID: m.drawerID,
                                             modelID: "minilm")
            XCTAssertNotNil(stored)
            let computed = EngramLib.distance(probe, stored!)
            XCTAssertEqual(m.distance, computed,
                           "drawer \(m.drawerID): distance mismatch")
            XCTAssertEqual(m.modelID, "minilm")
        }
    }

    /// `findByKeyword` returns drawer IDs whose tokens match the FTS5
    /// query. Tokens are derived from `drawer_id` (FTS5 default
    /// `unicode61` tokenizer splits on hyphens), so a search for
    /// "alpha" finds "alpha-doc" but not "bravo-doc".
    func testFindByKeywordReturnsMatchingDrawers() async throws {
        let store = try await makeStore()
        try await seedCorpus(store)
        let hits = try await store.findByKeyword("alpha", limit: 10)
        XCTAssertEqual(hits, ["alpha-doc"])
    }

    /// `findByKeyword` returns the empty array when no row matches —
    /// no thrown error, no nil.
    func testFindByKeywordReturnsEmptyForNoMatch() async throws {
        let store = try await makeStore()
        try await seedCorpus(store)
        let hits = try await store.findByKeyword("zebra", limit: 10)
        XCTAssertTrue(hits.isEmpty)
    }

    /// Hybrid retrieval: a drawer that is both a Hamming neighbour
    /// AND an FTS5 keyword hit shows up in both result lists. Sanity-
    /// checks that the two retrieval modes are over the same corpus
    /// and do not partition rows.
    func testHybridFindNearestAndFindByKeywordOverlap() async throws {
        let store = try await makeStore()
        try await seedCorpus(store)
        let probe = Engram(blocks: 0, 0, 0, 0)

        let nearest = try await store.findNearest(probe: probe,
                                             modelID: "minilm",
                                             limit: 4)
        let keyword = try await store.findByKeyword("alpha", limit: 10)

        XCTAssertTrue(nearest.contains { $0.drawerID == "alpha-doc" })
        XCTAssertTrue(keyword.contains("alpha-doc"))
    }
}
