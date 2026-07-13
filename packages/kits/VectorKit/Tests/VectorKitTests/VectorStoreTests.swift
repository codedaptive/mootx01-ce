import Testing
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import Foundation
import IntellectusLib
@testable import VectorKit

/// Tests for `VectorStore` — SQLite-backed CRUD over the `vectors`
/// table. Per spec I-4 every stored vector is tagged with the model
/// ID and version that produced it; the round-trip and multi-model
/// tests below enforce that invariant.
///
/// Each test creates a fresh on-disk SQLite store (makeScratchStorage) — the
/// real persistent backend, never the in-RAM one — so tests exercise the same
/// type round-trip production uses and do not share state.
///
/// CRITICAL — GlobalTestLock:
///   These tests call addVector, findNearest, and findByKeyword, all of
///   which emit telemetry via the Intellectus global singleton when
///   monitoring is enabled. VectorKitTelemetryTests runs concurrently in
///   the same test binary and toggles the singleton. To prevent
///   contamination, every test here acquires GlobalTestLock.shared for
///   its entire duration, serialising with the telemetry suite.
///   See GlobalTestLock.swift for the design rationale.
@Suite("VectorStore", .serialized)
struct VectorStoreTests {

    private func makeStore() async throws -> VectorStore {
        let storage = try makeScratchStorage()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage)
    }

    /// Reopen regression: a vector stored over a real on-disk SQLite estate must
    /// remain searchable via `findNearest` after the store is dropped and a NEW
    /// VectorStore is opened on the same file (a process restart). This is the
    /// test that would have caught the dark-recall-on-reopen bug — the InMemory
    /// backend preserves the inserted `.uuid`/`.timestamp` TypedValues, so the
    /// in-memory tests passed while `storedVector` rejected the PRIMITIVE forms
    /// (`.text` id, ISO-8601 `.text` filed_at) the SQLite backend returns. With
    /// those rejected, `findNearest` over a reopened estate returned no matches
    /// and the vector recall lane went dark in production.
    @Test func findNearestSurvivesReopenSQLite() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vectorkit-reopen-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            let engram = Engram(blocks: 0xDEAD_BEEF_CAFE_BABE,
                                0x0123_4567_89AB_CDEF,
                                0xFFFF_0000_FFFF_0000,
                                0x0000_FFFF_0000_FFFF)
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            // First session: store a vector over a real SQLite estate, then drop
            // the store so nothing stays resident.
            do {
                let storage = try SQLiteStorage(configuration: EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: url, busyTimeout: 5.0)
                ))
                try await storage.open(schema: VectorStore.schemaDeclaration)
                let store = VectorStore(storage: storage)
                try await store.addVector(itemID: "drawer-reopen",
                                          engram: engram,
                                          modelID: "minilm",
                                          modelVersion: "1.0.0",
                                          filedAt: now)
            }

            // Second session: new VectorStore over the SAME on-disk estate. The
            // persisted vector must decode from the SQLite read-back primitives,
            // or findNearest returns nothing.
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0)
            ))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let reopened = VectorStore(storage: storage)
            let matches = try await reopened.findNearest(probe: engram, modelID: "minilm", limit: 5)

            #expect(matches.contains { $0.itemID == "drawer-reopen" && $0.distance == 0 })
        }
    }

    /// Round-trip: bytes written via `addVector` match bytes read via
    /// `getVector`. Confirms the Engram BLOB encoding is lossless.
    @Test func testAddGetRoundTripPreservesEngramBytes() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let engram = Engram(blocks: 0xDEAD_BEEF_CAFE_BABE,
                                0x0123_4567_89AB_CDEF,
                                0xFFFF_0000_FFFF_0000,
                                0x0000_FFFF_0000_FFFF)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try await store.addVector(itemID: "drawer-A",
                                engram: engram,
                                modelID: "minilm",
                                modelVersion: "1.0.0",
                                filedAt: now)

            let fetched = try await store.getVector(itemID: "drawer-A",
                                              modelID: "minilm")
            #expect(fetched == engram)
        }
    }

    /// Unknown item ID returns nil — `getVector` does not throw on
    /// missing rows, it surfaces absence as Optional.none.
    @Test func testGetVectorReturnsNilForUnknownItem() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let result = try await store.getVector(itemID: "never-existed",
                                             modelID: "minilm")
            #expect(result == nil)
        }
    }

    /// Two models for the same item: each is independently
    /// retrievable. Confirms `(item_id, vector_index, model_id)` is the
    /// effective uniqueness key; this test uses vector_index=0 for both.
    @Test func testMultipleModelsStoredForSameItem() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let minilmEngram = Engram(blocks: 0x1111, 0x2222, 0x3333, 0x4444)
            let gemmaEngram  = Engram(blocks: 0xAAAA, 0xBBBB, 0xCCCC, 0xDDDD)
            let now = Date(timeIntervalSince1970: 1_700_000_100)

            try await store.addVector(itemID: "drawer-X",
                                engram: minilmEngram,
                                modelID: "minilm",
                                modelVersion: "1.0.0",
                                filedAt: now)
            try await store.addVector(itemID: "drawer-X",
                                engram: gemmaEngram,
                                modelID: "gemma",
                                modelVersion: "300m",
                                filedAt: now)

            let __r1 = try await store.getVector(itemID: "drawer-X",
                                               modelID: "minilm")
            #expect(__r1 == minilmEngram)
            let __r2 = try await store.getVector(itemID: "drawer-X",
                                               modelID: "gemma")
            #expect(__r2 == gemmaEngram)
        }
    }

    /// `vectors(forItemID:)` returns all rows for one item in
    /// `filed_at` ASC order.
    @Test func testVectorsForItemReturnsAllOrderedByFiledAtAscending() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let e1 = Engram(blocks: 1, 0, 0, 0)
            let e2 = Engram(blocks: 2, 0, 0, 0)
            let e3 = Engram(blocks: 3, 0, 0, 0)
            let t1 = Date(timeIntervalSince1970: 1_700_000_000)
            let t2 = Date(timeIntervalSince1970: 1_700_000_100)
            let t3 = Date(timeIntervalSince1970: 1_700_000_200)

            // Insert out of chronological order to exercise the ORDER BY.
            try await store.addVector(itemID: "drawer-Y", engram: e2,
                                modelID: "mB", modelVersion: "1", filedAt: t2)
            try await store.addVector(itemID: "drawer-Y", engram: e3,
                                modelID: "mC", modelVersion: "1", filedAt: t3)
            try await store.addVector(itemID: "drawer-Y", engram: e1,
                                modelID: "mA", modelVersion: "1", filedAt: t1)

            let all = try await store.vectors(forItemID: "drawer-Y")
            #expect(all.count == 3)
            #expect(all.map(\.engram) == [e1, e2, e3])
            #expect(all.map(\.modelID) == ["mA", "mB", "mC"])
        }
    }

    /// `deleteVector` removes the matching `(itemID, vectorIndex: 0, modelID)`
    /// row via the single-vector API; subsequent fetch returns nil.
    @Test func testDeleteVectorRemovesRow() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let engram = Engram(blocks: 0x42, 0, 0, 0)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try await store.addVector(itemID: "drawer-Z",
                                engram: engram,
                                modelID: "minilm",
                                modelVersion: "1.0.0",
                                filedAt: now)
            try await store.deleteVector(itemID: "drawer-Z", modelID: "minilm")

            let __nil1 = try await store.getVector(itemID: "drawer-Z",
                                              modelID: "minilm")
            #expect(__nil1 == nil)
        }
    }

    /// `modelID` and `modelVersion` round-trip on `vectors(forItemID:)`
    /// — the StoredVector record carries the spec I-4 tagging.
    @Test func testModelAndVersionRoundTrip() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let engram = Engram(blocks: 0xAA, 0xBB, 0xCC, 0xDD)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try await store.addVector(itemID: "drawer-V",
                                engram: engram,
                                modelID: "minilm-v6",
                                modelVersion: "1.0.0-alpha.3",
                                filedAt: now)

            let rows = try await store.vectors(forItemID: "drawer-V")
            #expect(rows.count == 1)
            #expect(rows[0].itemID == "drawer-V")
            #expect(rows[0].modelID == "minilm-v6")
            #expect(rows[0].modelVersion == "1.0.0-alpha.3")
            #expect(rows[0].engram == engram)
        }
    }

    /// `addVector` twice with the same `(itemID, modelID)` replaces
    /// the prior engram (upsert) — the second engram is what comes
    /// back on fetch, and `vectors(forItemID:)` returns exactly one
    /// row. Exercises the `ON CONFLICT(item_id, vector_index, model_id) DO UPDATE`
    /// path required by mission Verification item 4.
    @Test func testAddVectorUpsertsOnSameItemAndModel() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let first  = Engram(blocks: 1, 2, 3, 4)
            let second = Engram(blocks: 5, 6, 7, 8)
            let t1 = Date(timeIntervalSince1970: 1_700_000_000)
            let t2 = Date(timeIntervalSince1970: 1_700_000_500)

            try await store.addVector(itemID: "drawer-UP",
                                engram: first,
                                modelID: "minilm",
                                modelVersion: "1.0.0",
                                filedAt: t1)
            try await store.addVector(itemID: "drawer-UP",
                                engram: second,
                                modelID: "minilm",
                                modelVersion: "1.0.1",
                                filedAt: t2)

            // The conflict path UPDATEs in place; the stored engram is the
            // most recent one and only one row exists for this item.
            let __r3 = try await store.getVector(itemID: "drawer-UP",
                                                modelID: "minilm")
            #expect(__r3 == second)
            let rows = try await store.vectors(forItemID: "drawer-UP")
            #expect(rows.count == 1)
            #expect(rows[0].engram == second)
            #expect(rows[0].modelVersion == "1.0.1")
        }
    }

    /// Fresh store: `vectors(forItemID:)` for an unknown item
    /// returns the empty array, not nil.
    @Test func testFreshStoreReturnsEmptyForUnknownItem() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let rows = try await store.vectors(forItemID: "no-such-item")
            #expect(rows.isEmpty)
        }
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
        for (item, bits) in entries {
            try await store.addVector(itemID: item,
                                engram: Engram(blocks: bits, 0, 0, 0),
                                modelID: modelID,
                                modelVersion: "1.0.0",
                                filedAt: now)
        }
    }

    /// `findNearest` returns exactly K results, sorted by Hamming
    /// distance ascending. With a zero probe and the seeded corpus,
    /// the K=2 result must be the two engrams with smallest popcount.
    @Test func testFindNearestReturnsKResultsSortedByDistanceAscending() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let probe = Engram(blocks: 0, 0, 0, 0)

            let matches = try await store.findNearest(probe: probe,
                                                 modelID: "minilm",
                                                 limit: 2)
            #expect(matches.count == 2)
            #expect(matches.map(\.itemID) == ["alpha-doc", "bravo-doc"])
            #expect(matches.map(\.distance) == [1, 2])
            // Verify sort order is preserved across the full result list.
            for i in 1..<matches.count {
                #expect(matches[i - 1].distance <= matches[i].distance)
            }
        }
    }

    /// K > corpus size returns every row exactly once, still sorted
    /// distance ascending. Probes a zero engram against a 4-row corpus
    /// with K=10 — must return 4 matches in popcount-ascending order.
    @Test func testFindNearestWithKLargerThanCorpusReturnsAllRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let probe = Engram(blocks: 0, 0, 0, 0)

            let matches = try await store.findNearest(probe: probe,
                                                 modelID: "minilm",
                                                 limit: 10)
            #expect(matches.count == 4)
            #expect(matches.map(\.itemID) ==
                           ["alpha-doc", "bravo-doc", "charlie-doc", "delta-doc"])
            #expect(matches.map(\.distance) == [1, 2, 3, 4])
        }
    }

    /// Empty store: `findNearest` returns the empty array without
    /// error. Absence is modeled as `[]`, not as a thrown error.
    @Test func testFindNearestOnEmptyStoreReturnsEmpty() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let probe = Engram(blocks: 0xFFFF, 0, 0, 0)
            let matches = try await store.findNearest(probe: probe,
                                                 modelID: "minilm",
                                                 limit: 5)
            #expect(matches.isEmpty)
        }
    }

    /// Each `VectorMatch.itemID` must correspond to the row whose
    /// engram produced the reported `distance`. Re-derive each match's
    /// distance from the stored engram and confirm the result agrees.
    @Test func testFindNearestIndicesMapToCorrectItemIDs() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let probe = Engram(blocks: 0, 0, 0, 0)

            let matches = try await store.findNearest(probe: probe,
                                                 modelID: "minilm",
                                                 limit: 4)
            #expect(matches.count == 4)
            for m in matches {
                let stored = try await store.getVector(itemID: m.itemID,
                                                 modelID: "minilm")
                #expect(stored != nil)
                let computed = EngramLib.distance(probe, stored!)
                #expect(m.distance == computed,
                        "item \(m.itemID): distance mismatch")
                #expect(m.modelID == "minilm")
            }
        }
    }

    /// `findByKeyword` returns item IDs matching the query.
    @Test func testFindByKeywordReturnsMatchingItems() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let hits = try await store.findByKeyword("alpha", limit: 10)
            #expect(hits == ["alpha-doc"])
        }
    }

    /// `limit` counts DISTINCT item IDs, not table rows. The vectors table
    /// holds many rows per item (one binary row per model slot, plus float
    /// rows), so a row-scoped limit silently shrinks the probe window ~10×
    /// on production ensembles — the contradiction hunter and
    /// VectorSimilaritySignal both size their sweeps in ITEMS. Regression:
    /// three items under two models each (6 rows); limit 3 must return all
    /// three items, not the two items the first three rows dedupe to.
    @Test func testFindByKeywordLimitCountsDistinctItemsNotRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            for item in ["probe-a", "probe-b", "probe-c"] {
                for model in ["model-one", "model-two"] {
                    try await store.addVector(
                        itemID: item,
                        engram: Engram(blocks: 1, 2, 3, 4),
                        modelID: model,
                        modelVersion: "1.0",
                        filedAt: t0)
                }
            }
            let hits = try await store.findByKeyword("probe", limit: 3)
            #expect(hits == ["probe-a", "probe-b", "probe-c"],
                "limit must count distinct items — a row-scoped limit returns only the items the first N rows cover")
        }
    }

    /// `findByKeyword` returns the empty array when no row matches —
    /// no thrown error, no nil.
    @Test func testFindByKeywordReturnsEmptyForNoMatch() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let hits = try await store.findByKeyword("zebra", limit: 10)
            #expect(hits.isEmpty)
        }
    }

    /// Hybrid retrieval: an item that is both a Hamming neighbour
    /// AND a keyword hit shows up in both result lists. Sanity-
    /// checks that the two retrieval modes are over the same corpus
    /// and do not partition rows.
    @Test func testHybridFindNearestAndFindByKeywordOverlap() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let probe = Engram(blocks: 0, 0, 0, 0)

            let nearest = try await store.findNearest(probe: probe,
                                                 modelID: "minilm",
                                                 limit: 4)
            let keyword = try await store.findByKeyword("alpha", limit: 10)

            #expect(nearest.contains { $0.itemID == "alpha-doc" })
            #expect(keyword.contains("alpha-doc"))
        }
    }

    /// `findNearest` returns exactly `limit` results when the corpus is
    /// larger than `limit`. Inserts 100 vectors and requests 5 — the
    /// result count must be exactly 5.
    @Test func findNearestReturnsBoundedCountEqualToLimit() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            for i in 1...100 {
                try await store.addVector(
                    itemID: "drawer-\(String(format: "%03d", i))",
                    engram: Engram(blocks: UInt64(i), 0, 0, 0),
                    modelID: "minilm",
                    modelVersion: "1.0.0",
                    filedAt: now
                )
            }
            let probe = Engram(blocks: 0, 0, 0, 0)
            let result = try await store.findNearest(probe: probe,
                                                     modelID: "minilm",
                                                     limit: 5)
            #expect(result.count == 5)
        }
    }

    /// `findNearest` results are sorted by Hamming distance ascending.
    @Test func findNearestResultsAreSortedByDistanceAscending() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            try await seedCorpus(store)
            let probe = Engram(blocks: 0, 0, 0, 0)
            let matches = try await store.findNearest(probe: probe,
                                                      modelID: "minilm",
                                                      limit: 4)
            for i in 1..<matches.count {
                #expect(matches[i - 1].distance <= matches[i].distance)
            }
        }
    }

    /// When two candidates have identical Hamming distance from the
    /// probe, `findNearest` breaks the tie by `itemID` ascending.
    ///
    /// Engram(blocks: 1, 0, 0, 0) (popcount=1) and
    /// Engram(blocks: 2, 0, 0, 0) (popcount=1) are both distance 1
    /// from the zero probe. The item with the lexicographically
    /// smaller ID ("aaa-drawer") must appear first.
    @Test func findNearestTieBreakByItemIDIsStable() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeStore()
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            // Both engrams have popcount 1 — identical distance from zero probe.
            try await store.addVector(itemID: "zzz-drawer",
                                      engram: Engram(blocks: 1, 0, 0, 0),
                                      modelID: "minilm",
                                      modelVersion: "1.0.0",
                                      filedAt: now)
            try await store.addVector(itemID: "aaa-drawer",
                                      engram: Engram(blocks: 2, 0, 0, 0),
                                      modelID: "minilm",
                                      modelVersion: "1.0.0",
                                      filedAt: now)
            let probe = Engram(blocks: 0, 0, 0, 0)
            let matches = try await store.findNearest(probe: probe,
                                                      modelID: "minilm",
                                                      limit: 2)
            #expect(matches.count == 2)
            #expect(matches[0].itemID == "aaa-drawer")
            #expect(matches[1].itemID == "zzz-drawer")
        }
    }

    // MARK: - VEC-MIH-WIRING — threshold policy and index-selection identity

    /// Helper: make a store with an overridden MIH threshold for tests
    /// that need to cross the boundary with a small corpus.
    private func makeStore(mihThreshold: UInt32) async throws -> VectorStore {
        let storage = try makeScratchStorage()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage, mihThreshold: mihThreshold)
    }

    /// MIH threshold crossing — identical results.
    ///
    /// Loads `threshold` binary vectors into a store whose MIH threshold is
    /// set to that same count, so the (threshold)th insert crosses into MIH
    /// territory. Then asserts that `findNearest` returns IDENTICAL results
    /// to a brute-force-only store (threshold set to UInt32.max) over the
    /// same corpus and probe.
    ///
    /// This is the VectorStore-level gate that complements MIHIndexTests'
    /// bit-for-bit lane conformance test. It verifies the threshold routing
    /// logic itself produces no result divergence.
    @Test func findNearestIsIdenticalAcrossMIHThreshold() async throws {
        try await GlobalTestLock.shared.withLock {
            // Use threshold=20 so we can cross it with a small corpus.
            let threshold: UInt32 = 20
            let storeWithMIH = try await makeStore(mihThreshold: threshold)
            let storeAlwaysBF = try await makeStore(mihThreshold: UInt32.max)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = Int(threshold) + 10  // 30 vectors — 10 above threshold

            // Use a deterministic pseudo-random corpus (same seed for both stores).
            // LCG constants from Knuth §3.3.4 (64-bit); wrapping arithmetic produces
            // a full-period sequence. UInt64 avoids signed-overflow UB.
            for i in 0..<n {
                // Spread bits across all four blocks for realistic MIH probing.
                let b0: UInt64 = UInt64(bitPattern: Int64(bitPattern: UInt64(i)))
                    &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let b1 = b0 &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let b2 = b1 &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let b3 = b2 &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let engram = Engram(blocks: b0, b1, b2, b3)
                let itemID = "item-\(String(format: "%04d", i))"
                try await storeWithMIH.addVector(
                    itemID: itemID, engram: engram,
                    modelID: "minilm", modelVersion: "1.0", filedAt: now
                )
                try await storeAlwaysBF.addVector(
                    itemID: itemID, engram: engram,
                    modelID: "minilm", modelVersion: "1.0", filedAt: now
                )
            }

            // The store with MIH should now be using MIHIndex (count > threshold).
            let probe = Engram(blocks: 0xDEAD_BEEF_CAFE_BABE,
                               0x0123_4567_89AB_CDEF,
                               0xFFFF_0000_FFFF_0000,
                               0x0000_FFFF_0000_FFFF)
            let k = 10

            let mihMatches = try await storeWithMIH.findNearest(
                probe: probe, modelID: "minilm", limit: k)
            let bfMatches = try await storeAlwaysBF.findNearest(
                probe: probe, modelID: "minilm", limit: k)

            // Exact identity: same count, same itemIDs, same distances, same order.
            #expect(mihMatches.count == bfMatches.count,
                    "result count diverged: MIH=\(mihMatches.count) BF=\(bfMatches.count)")
            for (m, b) in zip(mihMatches, bfMatches) {
                #expect(m.itemID == b.itemID,
                        "itemID diverged: MIH=\(m.itemID) BF=\(b.itemID)")
                #expect(m.distance == b.distance,
                        "distance diverged for \(m.itemID): MIH=\(m.distance) BF=\(b.distance)")
            }

            // Sanity: results are sorted distance ASC, itemID ASC.
            for i in 1..<mihMatches.count {
                let prev = mihMatches[i - 1], curr = mihMatches[i]
                #expect(
                    prev.distance < curr.distance ||
                    (prev.distance == curr.distance && prev.itemID <= curr.itemID),
                    "MIH result ordering violated at index \(i)"
                )
            }
        }
    }

    /// MIH wiring — threshold demotion.
    ///
    /// Loads past the threshold, then deletes enough vectors to drop back
    /// below. Verifies that `findNearest` still returns correct results
    /// (brute-force takes over) and matches a brute-force-only store.
    @Test func findNearestCorrectAfterDemotionBelowThreshold() async throws {
        try await GlobalTestLock.shared.withLock {
            let threshold: UInt32 = 5
            let storeWithPolicy = try await makeStore(mihThreshold: threshold)
            let storeAlwaysBF   = try await makeStore(mihThreshold: UInt32.max)
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            // Load 8 vectors (above threshold=5).
            for i in 0..<8 {
                let engram = Engram(blocks: UInt64(i + 1), 0, 0, 0)
                let itemID = "item-\(i)"
                try await storeWithPolicy.addVector(
                    itemID: itemID, engram: engram,
                    modelID: "m", modelVersion: "1", filedAt: now
                )
                try await storeAlwaysBF.addVector(
                    itemID: itemID, engram: engram,
                    modelID: "m", modelVersion: "1", filedAt: now
                )
            }

            // Delete 4 — drops count to 4, below threshold=5 (demote to BF).
            for i in 0..<4 {
                try await storeWithPolicy.deleteVector(itemID: "item-\(i)", modelID: "m")
                try await storeAlwaysBF.deleteVector(itemID: "item-\(i)", modelID: "m")
            }

            let probe = Engram(blocks: 0, 0, 0, 0)
            let policyMatches = try await storeWithPolicy.findNearest(
                probe: probe, modelID: "m", limit: 10)
            let bfMatches = try await storeAlwaysBF.findNearest(
                probe: probe, modelID: "m", limit: 10)

            #expect(policyMatches.map(\.itemID) == bfMatches.map(\.itemID))
            #expect(policyMatches.map(\.distance) == bfMatches.map(\.distance))
        }
    }

    /// MIH wiring — performance comparison at large N.
    ///
    /// Directly builds BruteForceIndex and MIHIndex from a 100_000-vector
    /// ResidentVectorArray and measures per-query latency for each,
    /// asserting MIH < brute-force (in release builds). The measured numbers
    /// are emitted to stdout for the mission perf report.
    ///
    /// Data distribution: clustered near-duplicates (realistic for SimHash
    /// fingerprints of semantically similar content). Random uniform codes
    /// have expected NN distance ~128 bits, forcing MIH's progressive-radius
    /// loop to r~110+ (enormous flip enumeration). Clustered codes have NN
    /// distances of 5-20 bits, where MIH's sub-linear advantage materialises.
    ///
    /// LCG constants from Knuth §3.3.4 — full-period UInt64 sequence, used
    /// for deterministic prototype generation and per-vector bit-flip selection.
    ///
    /// I-7 satisfied: BruteForceIndex and MIHIndex both delegate all Hamming
    /// arithmetic to EngramLib → SubstrateKernel. This test measures the
    /// candidate-generation speedup of MIH, not a different distance kernel.
    @Test func mihFasterThanBruteForceAtLargeN() async throws {
        let n = 100_000

        // 20 prototype codes, LCG-generated deterministically.
        // Each vector is a near-duplicate of one prototype with 5 random
        // bits flipped, giving expected NN distance of ~5 bits. Real
        // SimHash fingerprints of near-duplicate content look like this.
        let nProtos = 20
        let bitsToFlip = 5

        var protoWords = [[UInt64]]()  // nProtos × 4 words
        var lcgState: UInt64 = 0xCAFE_BABE_DEAD_BEEF
        for _ in 0..<nProtos {
            var words = [UInt64](repeating: 0, count: 4)
            for w in 0..<4 {
                lcgState = lcgState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                words[w] = lcgState
            }
            protoWords.append(words)
        }

        var keys:    [VectorRecordKey] = []
        var storage: [UInt8]           = [UInt8](repeating: 0, count: n * 32)
        keys.reserveCapacity(n)

        // Build corpus: assign each vector to a prototype (round-robin),
        // then flip `bitsToFlip` bits deterministically via LCG.
        storage.withUnsafeMutableBytes { buf in
            for i in 0..<n {
                let proto = protoWords[i % nProtos]
                var w = proto  // copy prototype words

                // Flip bitsToFlip distinct bits using LCG for position selection.
                var flipped = Set<Int>()
                while flipped.count < bitsToFlip {
                    lcgState = lcgState &* 6_364_136_223_846_793_005
                        &+ 1_442_695_040_888_963_407
                    let pos = Int(lcgState >> 56) % 256  // bit 0..255
                    if flipped.insert(pos).inserted {
                        let word = pos / 64
                        let bit  = pos % 64
                        w[word] ^= UInt64(1) << bit
                    }
                }

                let base = i * 32
                buf.storeBytes(of: w[0].littleEndian, toByteOffset: base +  0, as: UInt64.self)
                buf.storeBytes(of: w[1].littleEndian, toByteOffset: base +  8, as: UInt64.self)
                buf.storeBytes(of: w[2].littleEndian, toByteOffset: base + 16, as: UInt64.self)
                buf.storeBytes(of: w[3].littleEndian, toByteOffset: base + 24, as: UInt64.self)
            }
        }
        for i in 0..<n {
            keys.append(VectorRecordKey(
                itemID: "v\(String(format:"%07d", i))",
                vectorIndex: 0, modelID: "m", modelVersion: "1"
            ))
        }

        // Build model partition index for BruteForceIndex scope.
        let partitions = BruteForceIndex.buildPartitions(keys: keys, tombstones: [])
        let arrayWithPartitions = ResidentVectorArray(
            kind: .binary, stride: 32, count: UInt32(n),
            storage: Data(storage), keys: keys,
            modelPartitions: partitions, tombstones: []
        )

        let bfIndex  = BruteForceIndex()
        let mihIndex = MIHIndex(bandCount: .m16)
        await bfIndex.build(from: arrayWithPartitions)
        await mihIndex.build(from: arrayWithPartitions)

        // Probe: near-duplicate of prototype 0 (5 bits flipped from proto[0]).
        let p0 = protoWords[0]
        let probe = Engram(blocks: p0[0] ^ 0x1F, p0[1], p0[2], p0[3])
        let probePayload = VectorPayload(engram: probe)
        let filter: MetadataFilter? = nil
        let k = 10
        let runs = 5

        // Warm-up (not measured).
        _ = try await bfIndex.search(probe: probePayload, metric: .hamming, k: k, filter: filter)
        _ = try await mihIndex.search(probe: probePayload, metric: .hamming, k: k, filter: filter)

        // Measure brute-force.
        var bfTotalMs = 0.0
        for _ in 0..<runs {
            let t0 = Date().timeIntervalSince1970
            _ = try await bfIndex.search(probe: probePayload, metric: .hamming, k: k, filter: filter)
            bfTotalMs += (Date().timeIntervalSince1970 - t0) * 1000.0
        }
        let bfAvgMs = bfTotalMs / Double(runs)

        // Measure MIH.
        var mihTotalMs = 0.0
        for _ in 0..<runs {
            let t0 = Date().timeIntervalSince1970
            _ = try await mihIndex.search(probe: probePayload, metric: .hamming, k: k, filter: filter)
            mihTotalMs += (Date().timeIntervalSince1970 - t0) * 1000.0
        }
        let mihAvgMs = mihTotalMs / Double(runs)

        print("[VEC-MIH-PERF] n=\(n) k=\(k) bitsFlipped=\(bitsToFlip) " +
              "BF=\(String(format:"%.3f",bfAvgMs))ms " +
              "MIH=\(String(format:"%.3f",mihAvgMs))ms " +
              "speedup=\(String(format:"%.1f",bfAvgMs/mihAvgMs))x")

        // The speedup is only reliably measurable in release/optimized builds.
        // In debug mode the hash-table overhead dominates the simple SIMD scan.
        // Correctness (identical results) is verified in all configurations.
        #if !DEBUG
        #expect(mihAvgMs < bfAvgMs)
        #endif

        // Identical results: MIH == brute-force on the same corpus.
        let bfHits  = try await bfIndex.search(probe: probePayload, metric: .hamming, k: k, filter: filter)
        let mihHits = try await mihIndex.search(probe: probePayload, metric: .hamming, k: k, filter: filter)
        #expect(bfHits.map(\.key.itemID) == mihHits.map(\.key.itemID))
        #expect(bfHits.map(\.rawDistance) == mihHits.map(\.rawDistance))
    }
}
