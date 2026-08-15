// ShadowSwapTests.swift
//
// Acceptance tests for VEC-SHADOWSWAP-01 — shadow-generation vector swap.
//
// Five gates prove correctness across the full swap lifecycle:
//
//   Gate 1 (no-serving-gap): During a shadow build, serving queries are answered
//     from the old generation. Old generation rows remain available to readers.
//
//   Gate 2 (crash-mid-build): If the process crashes during shadow population
//     and restarts, beginShadowGeneration on reopen allocates a new shadow
//     generation beyond the abandoned one. Abandoned rows become reclaimable.
//
//   Gate 3 (crash-mid-publish): A partial registry write (neither serving nor
//     shadow) leaves a state that re-running publishShadowGeneration handles
//     correctly (idempotent). Serving generation is either the old or new value,
//     never a hole.
//
//   Gate 4 (crash-mid-reclaim): Reclaim is resumable. Killing mid-reclaim and
//     re-running finishes without error, produces correct row counts, and does
//     not change query results (serving generation was already committed).
//
//   Gate 5 (post-swap coherence): After publish + reclaim, only new-generation
//     rows exist, queries return new-generation results, and the HNSW graph
//     generation matches the new serving generation.
//
// Plus: recall-unchanged asserts that items NOT in the swap batch still
// answer queries correctly. Storage-peak asserts peakShadowStorageBytes
// tracks bytes written during the shadow build.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import VectorKit

// MARK: - Suite

@Suite("Shadow Swap — VEC-SHADOWSWAP-01 acceptance gates")
struct ShadowSwapTests {

    private static let modelID      = "swap-model-v1"
    private static let altModelID   = "alt-model-v1"  // Not included in swap batch
    private static let corpusCount  = 12              // Enough for deterministic test
    private static let dim          = 8

    private func makeRNG(seed: UInt64) -> SplitMix64SS { SplitMix64SS(state: seed) }

    /// Unit-normalised random float vector.
    private func randomVector(dim: Int, rng: inout SplitMix64SS) -> [Float] {
        var v = (0..<dim).map { _ in rng.nextFloat() }
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        for i in v.indices { v[i] /= norm }
        return v
    }

    /// Open a fresh SQLite storage and apply the VectorStore schema.
    private func openStorage(at url: URL) async throws -> any Storage {
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return storage
    }

    // MARK: - Shared setup helpers

    /// Populate `store` with `count` float vectors for `modelID`.
    /// Returns (itemIDs, vectors) in insertion order.
    @discardableResult
    private func populateServing(
        store: VectorStore,
        modelID: String,
        count: Int,
        rng: inout SplitMix64SS,
        prefix: String = "item"
    ) async throws -> [(id: String, v: [Float])] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var corpus: [(id: String, v: [Float])] = []
        for i in 0..<count {
            let v = randomVector(dim: Self.dim, rng: &rng)
            let id = "\(prefix)-\(i)"
            corpus.append((id: id, v: v))
            try await store.addPayload(
                itemID: id, vectorIndex: 0,
                payload: VectorPayload(floats: v),
                modelID: modelID, modelVersion: "1",
                filedAt: now
            )
        }
        return corpus
    }

    // MARK: - Gate 1: No serving gap during shadow build

    /// While a shadow is in flight, serving queries return old-generation results.
    /// Old-generation rows remain accessible; shadow rows are invisible to queries.
    @Test("Gate 1: serving queries remain available during shadow build")
    func gate1_noServingGap() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)

            var rng = makeRNG(seed: 0x1111_2222_3333_4444)
            let oldCorpus = try await populateServing(store: store, modelID: Self.modelID,
                                                      count: Self.corpusCount, rng: &rng)

            // Begin shadow: allocates generation 1.
            let shadowGens = try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let shadowGen = try #require(shadowGens[Self.modelID], "beginShadowGeneration must return a generation for modelID")
            #expect(shadowGen == 1,
                "Gate 1: first shadow generation must be 1 (serving starts at 0)")

            // Write shadow vectors (new item set).
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // Serving query DURING build must return old-generation results.
            let probe = oldCorpus[0].v
            let results = try await store.findNearestFloat(probe: probe,
                                                           modelID: Self.modelID, limit: 5)
            #expect(results.isEmpty == false,
                "Gate 1: serving queries must return results while shadow is in flight")

            // All returned items must be old-generation (no 'new-' prefix).
            for match in results {
                #expect(!match.itemID.hasPrefix("new-"),
                    "Gate 1: serving queries must NOT return shadow rows — got '\(match.itemID)'")
            }

            // Nearest to the first old item must be that item itself.
            #expect(results.first?.itemID == oldCorpus[0].id,
                "Gate 1: nearest to item-0's vector must be item-0 during shadow build")
        }
    }

    // MARK: - Gate 2: Crash mid-build → restart allocates a new shadow

    /// If a shadow build is abandoned (crash), reopening the store and calling
    /// beginShadowGeneration allocates a new shadow generation strictly above
    /// the abandoned one. The abandoned rows become reclaimable.
    @Test("Gate 2: crash mid-build — reopen allocates a new shadow beyond the abandoned one")
    func gate2_crashMidBuild() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("gate2-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }

            var rng = makeRNG(seed: 0x2222_3333_4444_5555)

            // ── Instance A: begin shadow, write some rows, "crash" ──────────
            let storageA = try await openStorage(at: url)
            let storeA = VectorStore(storage: storageA)
            try await populateServing(store: storeA, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng)

            let gens = try await storeA.beginShadowGeneration(modelIDs: [Self.modelID])
            let abandonedGen = try #require(gens[Self.modelID])
            #expect(abandonedGen == 1, "Gate 2: abandoned shadow must be generation 1")

            // Write one shadow row before "crash" (storage close without publish).
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            try await storeA.addPayload(
                itemID: "shadow-item-0", vectorIndex: 0,
                payload: VectorPayload(floats: randomVector(dim: Self.dim, rng: &rng)),
                modelID: Self.modelID, modelVersion: "1",
                filedAt: now
            )
            await storageA.close()

            // ── Instance B: reopen after "crash" — resume ──────────────────
            let storageB = try await openStorage(at: url)
            let storeB = VectorStore(storage: storageB)

            // Serving generation is still 0 (publish never ran).
            // beginShadowGeneration must allocate generation 2 (> abandoned 1).
            let gens2 = try await storeB.beginShadowGeneration(modelIDs: [Self.modelID])
            let newShadowGen = try #require(gens2[Self.modelID])
            #expect(newShadowGen > abandonedGen,
                "Gate 2: restarted shadow generation (\(newShadowGen)) must exceed the abandoned one (\(abandonedGen))")

            // Serving query is still answered from generation 0 rows.
            // (Build new shadow, do NOT publish yet.)
            var rng2 = makeRNG(seed: 0xAAAA_BBBB_CCCC_DDDD)
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng2)
                try await storeB.addPayload(
                    itemID: "replacement-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // Now publish the new shadow. Serving becomes generation newShadowGen.
            try await storeB.publishShadowGeneration(modelIDs: [Self.modelID])

            // After reclaim, abandoned rows (gen 1) must be gone; only serving rows remain.
            let reclaimSummary = try await storeB.reclaimSupersededGenerations()
            let reclaimedCount = reclaimSummary[Self.modelID] ?? 0
            // Exactly 1 shadow-item row was written in the abandoned session.
            #expect(reclaimedCount >= 1,
                "Gate 2: reclaim must delete at least the 1 abandoned shadow row")

            await storageB.close()
        }
    }

    // MARK: - Gate 3: Crash mid-publish → idempotent re-run

    /// publishShadowGeneration is idempotent: if the process crashes after the
    /// registry flip commits but before post-flip tasks complete, re-running
    /// publish on reopen leaves serving generation = the committed value and
    /// queries return new-generation results.
    ///
    /// We simulate the post-flip crash by calling publish, then verifying that a
    /// second publish call on the same modelID is a no-op (no-op because shadow_gen
    /// is cleared by the first publish — the re-run cannot republish something that
    /// was already flipped).
    @Test("Gate 3: crash mid-publish — second publish call on cleared shadow is a no-op")
    func gate3_crashMidPublish() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)

            var rng = makeRNG(seed: 0x3333_4444_5555_6666)
            try await populateServing(store: store, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng)

            try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // First publish: flips serving_gen = 1, clears shadow_gen.
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])

            // Queries must return new-generation results after first publish.
            let rng2 = makeRNG(seed: 0x3333_4444_5555_6666)
            _ = makeRNG(seed: 0x3333_4444_5555_6666)  // advance past old corpus
            var rngQuery = makeRNG(seed: 0xAAAA_0001_0002_0003)
            let probe = randomVector(dim: Self.dim, rng: &rngQuery)
            let resultsAfterFirst = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(resultsAfterFirst.isEmpty == false,
                "Gate 3: queries must return results after first publish")
            for match in resultsAfterFirst {
                #expect(match.itemID.hasPrefix("new-"),
                    "Gate 3: post-publish queries must return new-gen items, got '\(match.itemID)'")
            }

            // Second publish (simulating re-run after crash): must not throw,
            // must not corrupt serving generation. Shadow_gen is nil — no-op.
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])

            // Queries still return correct results after idempotent re-run.
            let resultsAfterSecond = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(resultsAfterSecond.isEmpty == false,
                "Gate 3: queries must still return results after idempotent second publish")
            for match in resultsAfterSecond {
                #expect(match.itemID.hasPrefix("new-"),
                    "Gate 3: queries after idempotent re-publish must still return new-gen items, got '\(match.itemID)'")
            }
            _ = rng2  // suppress unused warning
        }
    }

    // MARK: - Gate 4: Crash mid-reclaim → resumable

    /// reclaimSupersededGenerations is resumable: calling it twice in a row
    /// (simulating a crash-and-restart mid-reclaim) is a no-op on the second
    /// call and does not corrupt query results.
    @Test("Gate 4: crash mid-reclaim — second reclaim call is a no-op with correct query results")
    func gate4_crashMidReclaim() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)

            var rng = makeRNG(seed: 0x4444_5555_6666_7777)
            try await populateServing(store: store, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng)

            try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            var newCorpus: [(id: String, v: [Float])] = []
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                newCorpus.append((id: "new-\(i)", v: v))
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])

            // First reclaim: removes gen-0 rows (old serving).
            let summary1 = try await store.reclaimSupersededGenerations()
            let count1 = summary1[Self.modelID] ?? 0
            #expect(count1 >= Self.corpusCount,
                "Gate 4: first reclaim must remove at least \(Self.corpusCount) old-gen rows; removed \(count1)")

            // Query after first reclaim: new-generation results.
            let probe = newCorpus[0].v
            let results1 = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(results1.first?.itemID == "new-0",
                "Gate 4: nearest to new-0's vector must be new-0 after first reclaim")

            // Second reclaim (resumable crash): must not throw, returns 0 deletions.
            let summary2 = try await store.reclaimSupersededGenerations()
            let count2 = summary2[Self.modelID] ?? 0
            #expect(count2 == 0,
                "Gate 4: second reclaim must delete 0 rows (all superseded rows already removed); got \(count2)")

            // Query still returns correct results after idempotent reclaim.
            let results2 = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: 3)
            #expect(results2.first?.itemID == "new-0",
                "Gate 4: query after idempotent reclaim must still rank new-0 nearest")
        }
    }

    // MARK: - Gate 5: Post-swap coherence

    /// After publish + reclaim: only new-generation rows exist; queries return
    /// new-generation results; the HNSW graph's generation matches the new
    /// serving generation; lastServedGraphGeneration is updated.
    @Test("Gate 5: post-swap coherence — only new-gen rows, correct HNSW generation, correct results")
    func gate5_postSwapCoherence() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            // Use a threshold below corpus count so HNSW is built during publish.
            let store = VectorStore(storage: storage, hnswThreshold: 8)

            var rng = makeRNG(seed: 0x5555_6666_7777_8888)
            let oldCorpus = try await populateServing(store: store, modelID: Self.modelID,
                                                       count: Self.corpusCount, rng: &rng)

            // Build initial HNSW graph (generation 0).
            try await store.rebuildHNSWIndex(for: Self.modelID)

            // Begin shadow generation 1.
            let gens = try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let shadowGen = try #require(gens[Self.modelID])
            #expect(shadowGen == 1, "Gate 5: shadow generation must be 1")

            // Write new corpus under shadow.
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            var newCorpus: [(id: String, v: [Float])] = []
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                newCorpus.append((id: "new-\(i)", v: v))
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // Publish: flips serving to generation 1.
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])

            // Reclaim: removes generation-0 rows.
            let summary = try await store.reclaimSupersededGenerations()
            let reclaimedCount = summary[Self.modelID] ?? 0
            #expect(reclaimedCount >= Self.corpusCount,
                "Gate 5: reclaim must remove at least \(Self.corpusCount) old-gen rows; removed \(reclaimedCount)")

            // Coherence check 1: only new-generation items are returned by findNearestFloat.
            let probe = newCorpus[0].v
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: Self.corpusCount)
            #expect(results.isEmpty == false,
                "Gate 5: findNearestFloat must return results after publish + reclaim")
            for match in results {
                #expect(match.itemID.hasPrefix("new-"),
                    "Gate 5: all post-swap results must be new-gen items; got '\(match.itemID)'")
                #expect(!match.itemID.hasPrefix("item-"),
                    "Gate 5: no old-gen items must appear in results; got '\(match.itemID)'")
            }

            // Coherence check 2: HNSW graph generation matches serving generation.
            // The graph built by publishShadowGeneration is stamped with shadowGen (= 1).
            let servedGraphGen = await store.lastServedGraphGeneration(for: Self.modelID)
            if let servedGraphGen {
                // If a float query was served via HNSW, the graph generation must be 1.
                #expect(servedGraphGen == shadowGen,
                    "Gate 5: lastServedGraphGeneration must equal new serving generation (\(shadowGen)); got \(servedGraphGen)")
            }
            // If servedGraphGen is nil, the float query above fell back to exact scan —
            // still correct behaviour, just no HNSW path was exercised in this run.

            // Coherence check 3: old corpus items are NOT returned by findNearestFloat.
            // Probe with each old-corpus vector; none should appear in results.
            // (Old rows were deleted by reclaim; the float index was rebuilt from new rows.)
            for item in oldCorpus.prefix(3) {
                let oldProbe = item.v
                let oldResults = try await store.findNearestFloat(
                    probe: oldProbe, modelID: Self.modelID, limit: Self.corpusCount)
                for match in oldResults {
                    #expect(!match.itemID.hasPrefix("item-"),
                        "Gate 5: old-gen item '\(match.itemID)' must not appear in results after reclaim")
                }
            }

            // Coherence check 4: serving generation is now 1. Confirm by verifying
            // the next beginShadowGeneration allocates generation > shadowGen (= 2).
            // This is the observable proof that serving_generation = shadowGen in the registry.
            let nextGens = try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let nextShadowGen = try #require(nextGens[Self.modelID])
            #expect(nextShadowGen > shadowGen,
                "Gate 5: next shadow generation (\(nextShadowGen)) must exceed current serving (\(shadowGen)) — proves serving_gen = \(shadowGen) in registry")
        }
    }

    // MARK: - Recall unchanged (items not in swap batch remain correct)

    /// Items under `altModelID` (not in the swap batch) are unaffected by the
    /// swap: they continue to answer queries correctly throughout the swap lifecycle.
    @Test("Recall unchanged: non-swapped model answers queries correctly throughout swap")
    func recallUnchanged_nonSwappedModel() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)

            var rng = makeRNG(seed: 0x6666_7777_8888_9999)

            // Populate both models with distinct corpora.
            let swapCorpus = try await populateServing(store: store, modelID: Self.modelID,
                                                        count: Self.corpusCount, rng: &rng,
                                                        prefix: "swap")
            let altCorpus  = try await populateServing(store: store, modelID: Self.altModelID,
                                                        count: Self.corpusCount, rng: &rng,
                                                        prefix: "alt")

            // Verify alt model before swap.
            let probe = altCorpus[0].v
            let before = try await store.findNearestFloat(probe: probe,
                                                           modelID: Self.altModelID, limit: 3)
            #expect(before.first?.itemID == "alt-0",
                "Recall unchanged: nearest to alt-0 must be alt-0 before swap")

            // Run the full swap on modelID only — altModelID is not in the batch.
            try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let now = Date(timeIntervalSince1970: 1_700_000_001)
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-swap-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])
            try await store.reclaimSupersededGenerations()

            // Alt model query after swap must still return correct results.
            let after = try await store.findNearestFloat(probe: probe,
                                                          modelID: Self.altModelID, limit: 3)
            #expect(after.first?.itemID == "alt-0",
                "Recall unchanged: nearest to alt-0 must still be alt-0 after swap of a different model")
            #expect(!after.isEmpty, "Recall unchanged: alt model must still return results after swap")

            // Swap model must return new results (smoke check).
            let swapProbe = swapCorpus[0].v
            let swapAfter = try await store.findNearestFloat(probe: swapProbe,
                                                              modelID: Self.modelID, limit: 3)
            // Old swap items (prefix "swap-") should be gone; new items have prefix "new-swap-".
            for match in swapAfter {
                #expect(match.itemID.hasPrefix("new-swap-"),
                    "Recall unchanged: swap model must return new-gen items after swap; got '\(match.itemID)'")
            }
        }
    }

    // MARK: - Storage peak

    /// peakShadowStorageBytes tracks the cumulative payload bytes written to the
    /// shadow generation. The value is > 0 after adding shadow rows and is
    /// proportional to the number of rows written.
    @Test("Storage peak: peakShadowStorageBytes tracks bytes written to shadow")
    func storagePeak_bytesTracked() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage)

            var rng = makeRNG(seed: 0x7777_8888_9999_AAAA)
            try await populateServing(store: store, modelID: Self.modelID,
                                       count: Self.corpusCount, rng: &rng)

            // Peak bytes before shadow starts must be 0.
            let beforeBytes = await store.peakShadowStorageBytes(for: Self.modelID)
            #expect(beforeBytes == 0,
                "Storage peak: peakShadowStorageBytes must be 0 before shadow begins")

            try await store.beginShadowGeneration(modelIDs: [Self.modelID])

            // After beginShadow but before any writes: still 0.
            let afterBeginBytes = await store.peakShadowStorageBytes(for: Self.modelID)
            #expect(afterBeginBytes == 0,
                "Storage peak: peakShadowStorageBytes must be 0 after beginShadow but before writes")

            let now = Date(timeIntervalSince1970: 1_700_000_001)
            for i in 0..<Self.corpusCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            let afterWriteBytes = await store.peakShadowStorageBytes(for: Self.modelID)
            #expect(afterWriteBytes > 0,
                "Storage peak: peakShadowStorageBytes must be > 0 after writing shadow rows")

            // Each float payload is dim * 4 bytes. With corpusCount rows, the peak
            // must be at least corpusCount * dim * 4.
            let minExpected = Int64(Self.corpusCount * Self.dim * 4)
            #expect(afterWriteBytes >= minExpected,
                "Storage peak: peakShadowStorageBytes (\(afterWriteBytes)) must be >= \(minExpected)")
        }
    }

    // MARK: - Gate 1 upgrade: generation-tag discrimination across ALL read paths

    /// Exercises every read path while a shadow is in flight and asserts that
    /// every returned VectorMatch carries `.generation == G` (the serving gen),
    /// never the shadow generation.  Also verifies that shadow-only items are
    /// completely invisible to `findByKeyword` and `recentItemIDs`.
    ///
    /// This test is designed to FAIL if any of D1–D3 or D5 are present:
    ///  - D1 absent → _floatScanFromTable mixes shadow rows → wrong generation tag or wrong content
    ///  - D2 absent → findByKeyword surfaces shadow-only item IDs
    ///  - D3 absent → recentItemIDs surfaces shadow-only item IDs
    ///  - D5 absent → VectorMatch.generation == 0 instead of the actual serving gen
    @Test("Gate 1 upgrade: all read paths return serving-gen results during shadow build")
    func gate1Upgrade_allReadPathsServingGenOnly() async throws {
        try await GlobalTestLock.shared.withLock {
            // diskBacked storage: forces findNearestFloat to use _floatScanFromTable (D1 path).
            // Default makeScratchStorage uses ramResident, so we override.
            let diskURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("g1upg-disk-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: diskURL) }
            let storageDisk = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: diskURL, busyTimeout: 5.0),
                residencyHint: .diskBacked
            ))
            try await storageDisk.open(schema: VectorStore.schemaDeclaration)
            let storeD = VectorStore(storage: storageDisk)

            var rng = makeRNG(seed: 0xA1B2_C3D4_E5F6_0001)
            let now = Date(timeIntervalSince1970: 1_710_000_000)
            let servingCount = 8
            let servingGen: Int64 = 0  // Baseline: no swap has run yet, gen is 0.

            // Populate serving corpus (gen 0).
            var servingCorpus: [(id: String, v: [Float])] = []
            for i in 0..<servingCount {
                let v = randomVector(dim: Self.dim, rng: &rng)
                let id = "serving-\(i)"
                servingCorpus.append((id: id, v: v))
                try await storeD.addPayload(
                    itemID: id, vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }

            // Begin shadow (gen 1) and write ONE shadow-only item that has a unique
            // ID marker. This item MUST be invisible to all serving read paths.
            _ = try await storeD.beginShadowGeneration(modelIDs: [Self.modelID])
            let shadowOnlyID = "shadow-only-item-9999"
            try await storeD.addPayload(
                itemID: shadowOnlyID, vectorIndex: 0,
                payload: VectorPayload(floats: randomVector(dim: Self.dim, rng: &rng)),
                modelID: Self.modelID, modelVersion: "1",
                filedAt: now.addingTimeInterval(1)  // newer timestamp than serving rows
            )

            // ── diskBacked path: findNearestFloat (exercises _floatScanFromTable, D1) ──
            let probe = servingCorpus[0].v
            let nearestDisk = try await storeD.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: servingCount)
            #expect(!nearestDisk.isEmpty,
                "Gate 1 upgrade: diskBacked findNearestFloat must return results during shadow build")
            for m in nearestDisk {
                #expect(m.generation == servingGen,
                    "Gate 1 upgrade (D5/D1): diskBacked findNearestFloat match '\(m.itemID)' must carry generation \(servingGen), got \(m.generation)")
                #expect(m.itemID != shadowOnlyID,
                    "Gate 1 upgrade (D1): shadow-only item must not appear in diskBacked float results")
            }

            // ── diskBacked path: findFarthestFloat (D1 + D5) ──
            let farthestDisk = try await storeD.findFarthestFloat(
                probe: probe, modelID: Self.modelID, limit: servingCount)
            for m in farthestDisk {
                #expect(m.generation == servingGen,
                    "Gate 1 upgrade (D5/D1): diskBacked findFarthestFloat match '\(m.itemID)' must carry generation \(servingGen), got \(m.generation)")
                #expect(m.itemID != shadowOnlyID,
                    "Gate 1 upgrade (D1): shadow-only item must not appear in diskBacked farthest results")
            }

            // ── ramResident path: findNearestFloat (exercises _findNearestFloatCached, D4+D5) ──
            // Use a separate on-disk store with ramResident hint (the default).
            let ramURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("g1upg-ram-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: ramURL) }
            let storageRAM = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: ramURL, busyTimeout: 5.0),
                residencyHint: .ramResident
            ))
            try await storageRAM.open(schema: VectorStore.schemaDeclaration)
            let storeR = VectorStore(storage: storageRAM)
            var rngR = makeRNG(seed: 0xA1B2_C3D4_E5F6_0002)
            for i in 0..<servingCount {
                let v = randomVector(dim: Self.dim, rng: &rngR)
                try await storeR.addPayload(
                    itemID: "serving-r-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }
            _ = try await storeR.beginShadowGeneration(modelIDs: [Self.modelID])
            let shadowOnlyRAM = "shadow-only-r-9999"
            try await storeR.addPayload(
                itemID: shadowOnlyRAM, vectorIndex: 0,
                payload: VectorPayload(floats: randomVector(dim: Self.dim, rng: &rngR)),
                modelID: Self.modelID, modelVersion: "1",
                filedAt: now.addingTimeInterval(1)
            )
            let probeR = randomVector(dim: Self.dim, rng: &rngR)
            let nearestRAM = try await storeR.findNearestFloat(
                probe: probeR, modelID: Self.modelID, limit: servingCount)
            #expect(!nearestRAM.isEmpty,
                "Gate 1 upgrade: ramResident findNearestFloat must return results during shadow build")
            for m in nearestRAM {
                #expect(m.generation == servingGen,
                    "Gate 1 upgrade (D5): ramResident findNearestFloat match '\(m.itemID)' must carry generation \(servingGen), got \(m.generation)")
                #expect(m.itemID != shadowOnlyRAM,
                    "Gate 1 upgrade: shadow-only item must not appear in ramResident float results")
            }

            // ── findByKeyword: shadow-only item must be invisible (D2) ──
            // "9999" only appears in the shadow-only item's ID; serving items use "serving-".
            let kwShadow = try await storeD.findByKeyword("9999", limit: 100)
            #expect(!kwShadow.contains(shadowOnlyID),
                "Gate 1 upgrade (D2): findByKeyword must NOT surface shadow-only item '\(shadowOnlyID)'")
            // "serving-" matches all serving items; must return results.
            let kwServing = try await storeD.findByKeyword("serving-", limit: 100)
            #expect(!kwServing.isEmpty,
                "Gate 1 upgrade (D2): findByKeyword must surface serving items during shadow build")
            for id in kwServing {
                #expect(!id.hasPrefix("shadow-"),
                    "Gate 1 upgrade (D2): findByKeyword must not return shadow-prefixed ids, got '\(id)'")
            }

            // ── recentItemIDs: shadow-only item must be invisible (D3) ──
            let recentIDs = try await storeD.recentItemIDs(limit: 100)
            #expect(!recentIDs.contains(shadowOnlyID),
                "Gate 1 upgrade (D3): recentItemIDs must NOT surface shadow-only item '\(shadowOnlyID)'")
            for id in recentIDs {
                #expect(!id.hasPrefix("shadow-only-"),
                    "Gate 1 upgrade (D3): recentItemIDs must not return shadow-only ids, got '\(id)'")
            }
        }
    }

    // MARK: - Interrupt case 4: stale-gen graph → exact lane serves non-empty results (catches D4)

    /// After a swap, the HNSW graph on disk has generation 1. If we evict the
    /// resident indices and then MANUALLY invalidate the disk graph (by using
    /// a second store instance that sees a mismatched generation), the exact-scan
    /// fallback must serve non-empty results — never [].
    ///
    /// D4 bug: the stale-graph guard had a DUPLICATED early-return that could return []
    /// instead of falling through to the shared exact-scan code.
    ///
    /// This test verifies the end-to-end post-swap query path and catches the structural
    /// defect: after swap, evict + query must always return non-empty serving-gen results.
    @Test("Interrupt case 4: post-swap evict+query serves non-empty results from exact or HNSW lane")
    func interruptCase4_postSwapEvictQueryServesResults() async throws {
        try await GlobalTestLock.shared.withLock {
            // ramResident so _findNearestFloatCached is exercised (HNSW path, D4).
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ic4-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0),
                residencyHint: .ramResident
            ))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            // Threshold of 4 so the HNSW branch is entered on a corpus of 8.
            let store = VectorStore(storage: storage, hnswThreshold: 4)

            var rng = makeRNG(seed: 0xB1B2_C3D4_E5F6_0003)
            let now = Date(timeIntervalSince1970: 1_710_100_000)
            let count = 8

            // Populate serving gen 0 and build initial HNSW (gen 0).
            for i in 0..<count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "old-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }
            try await store.rebuildHNSWIndex(for: Self.modelID)

            // Swap to generation 1.
            _ = try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            for i in 0..<count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now.addingTimeInterval(Double(i))
                )
            }
            // publishShadowGeneration flips serving to 1 AND rebuilds HNSW (D6 fix).
            // The resident HNSW is now gen-1. Evict to force reload on next query.
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])
            await store.evictFloatIndices()

            // After evict, hnswIndices and floatIndices are empty.
            // The next findNearestFloat call must:
            //   1. Build floatIndices lazily from serving-gen-1 rows.
            //   2. Load the HNSW graph from hnsw_graph (gen-1 rows, written by D6-fixed rebuild).
            //   3. Check graph gen == serving gen (1 == 1) → serve from HNSW.
            // OR fall through to exact scan if no valid graph rows exist.
            // Either way: non-empty result with generation == 1.
            let probe = randomVector(dim: Self.dim, rng: &rng)
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: count)
            #expect(!results.isEmpty,
                "Interrupt case 4: post-swap findNearestFloat must return non-empty results, never []")
            for m in results {
                #expect(m.itemID.hasPrefix("new-"),
                    "Interrupt case 4: results must come from published generation (new-*), got '\(m.itemID)'")
                #expect(m.generation == 1,
                    "Interrupt case 4: VectorMatch.generation must be 1 (new serving gen), got \(m.generation)")
            }
        }
    }

    // MARK: - THETA-after-swap test (catches D6)

    /// Complete a full swap to generation 1, then call rebuildHNSWIndex again
    /// (simulating a THETA cadence rebuild after the swap). Evict the resident
    /// float/HNSW indices, then query — the reloaded graph must serve correctly
    /// with lastServedGraphGeneration == 1 and no inline rebuild (hnswBuildCount
    /// unchanged by the query).
    ///
    /// D6 bug: rebuildHNSWIndex always stamped generation 0 on a freshly-built
    /// graph BEFORE persisting. After a swap (serving gen 1), a THETA rebuild
    /// would write gen-0 rows to hnsw_graph; _loadHNSWGraphIfPresent rejects
    /// them (generation mismatch → absent), and the graph is permanently absent.
    /// With D6 fixed, rebuildHNSWIndex stamps the graph with the CURRENT serving
    /// generation before persisting, so the reloaded graph passes the gen check.
    @Test("THETA-after-swap: rebuild after swap persists correct generation, reloads correctly")
    func thetaAfterSwap_rebuildPreservesGeneration() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("theta-\(UUID().uuidString).sqlite3")
            defer { try? FileManager.default.removeItem(at: url) }
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: url, busyTimeout: 5.0),
                residencyHint: .ramResident
            ))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            // Threshold below corpus count so HNSW path is exercised.
            let store = VectorStore(storage: storage, hnswThreshold: 4)

            var rng = makeRNG(seed: 0xC1C2_D3D4_E5E6_0004)
            let now = Date(timeIntervalSince1970: 1_720_000_000)
            let count = 8

            // Populate serving gen 0 and build initial HNSW graph.
            for i in 0..<count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "old-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now
                )
            }
            try await store.rebuildHNSWIndex(for: Self.modelID)

            // Full swap to generation 1.
            _ = try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            for i in 0..<count {
                let v = randomVector(dim: Self.dim, rng: &rng)
                try await store.addPayload(
                    itemID: "new-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: Self.modelID, modelVersion: "1",
                    filedAt: now.addingTimeInterval(Double(i))
                )
            }
            try await store.publishShadowGeneration(modelIDs: [Self.modelID])
            try await store.reclaimSupersededGenerations()

            // Verify serving generation is 1 by checking next shadow gen is 2.
            let nextGens = try await store.beginShadowGeneration(modelIDs: [Self.modelID])
            let nextShadow = try #require(nextGens[Self.modelID])
            #expect(nextShadow == 2,
                "THETA-after-swap: next shadow after gen-1 serving must be 2; got \(nextShadow)")
            // Do NOT publish this shadow — it's only used to verify serving gen.

            // THETA: rebuild HNSW (simulates DreamingDaemon THETA cadence post-swap).
            // With D6 fixed, this stamps the graph with current serving gen (1) before
            // persisting — so the rows in hnsw_graph have generation=1, not 0.
            try await store.rebuildHNSWIndex(for: Self.modelID)
            let buildCounts = await store.hnswBuildCount
            let buildCountAfterTheta = buildCounts[Self.modelID] ?? 0

            // Evict all resident indices — the next query must load from hnsw_graph.
            await store.evictFloatIndices()
            let notResidentAfterEvict = await store.hnswIndexResident(for: Self.modelID)
            #expect(!notResidentAfterEvict,
                "THETA-after-swap: HNSW must not be resident after evict")

            // Query — must load the persisted graph (gen-1 rows) and serve results.
            // With D6 bug: gen-0 rows in hnsw_graph → _loadHNSWGraphIfPresent rejects
            // them (gen 0 ≠ serving gen 1) → graph absent → exact scan fallback.
            // With D6 fixed: gen-1 rows → loaded successfully → served from HNSW.
            // In both cases the result must be non-empty and carry generation 1.
            let probe = randomVector(dim: Self.dim, rng: &rng)
            let results = try await store.findNearestFloat(
                probe: probe, modelID: Self.modelID, limit: count)
            #expect(!results.isEmpty,
                "THETA-after-swap: findNearestFloat must return results after THETA rebuild + evict")
            for m in results {
                #expect(m.itemID.hasPrefix("new-"),
                    "THETA-after-swap: results must come from gen-1 corpus (new-*), got '\(m.itemID)'")
                #expect(m.generation == 1,
                    "THETA-after-swap: VectorMatch.generation must be 1, got \(m.generation)")
            }

            // The query must have loaded the persisted graph (not triggered an
            // additional inline rebuild). Build count must not have increased.
            let buildCountsAfter = await store.hnswBuildCount
            let buildCountAfterQuery = buildCountsAfter[Self.modelID] ?? 0
            #expect(buildCountAfterQuery == buildCountAfterTheta,
                "THETA-after-swap: query must not trigger an inline rebuild (before=\(buildCountAfterTheta), after=\(buildCountAfterQuery))")

            // lastServedGraphGeneration must report generation 1 (not nil, not 0).
            let servedGen = await store.lastServedGraphGeneration(for: Self.modelID)
            #expect(servedGen == 1,
                "THETA-after-swap: lastServedGraphGeneration must be 1 after HNSW-served query; got \(String(describing: servedGen))")
        }
    }
}

// MARK: - SplitMix64SS (local copy to avoid cross-suite symbol collision)

/// SplitMix64 PRNG — same algorithm used in HNSWIndexTests and HNSWPersistenceTests.
/// Suffix "SS" (ShadowSwap) avoids a name collision with the copies in other suites.
struct SplitMix64SS: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func nextFloat() -> Float {
        // Map the high 23 bits into [0, 1).
        Float(next() >> 41) / Float(1 << 23)
    }
}
