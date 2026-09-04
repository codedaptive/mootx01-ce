// HNSWIndexTests.swift
//
// Lane D tests: HNSWIndex insert/search/tombstone/compact/clear, recall quality
// vs an exact oracle, and VectorStore threshold crossover.
//
// Design notes:
//   • HNSWIndex is an actor. Every public method is awaited.
//   • Recall quality is tested by comparing HNSW top-k against an inline
//     brute-force oracle (cosine distance); cross-platform bit-identity is NOT
//     asserted (HNSW graph topology is deterministic within one port, not
//     across Swift↔Rust).
//   • The crossover test uses VectorStore with hnswThreshold: 10 so 20 inserts
//     are enough to activate the HNSW routing path without a 5 000-vector corpus.
//   • Float determinism: these tests assert rank order and recall fraction,
//     never bit-identical float distances (arch spec §6).

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
@testable import SynapseKit

// MARK: - Private helpers

/// SplitMix64 state (identical algorithm to HNSWIndex.nextRandom and GauntletRNG).
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// Uniform Float in [-1, 1].
    mutating func nextFloat() -> Float {
        let bits = UInt32(truncatingIfNeeded: next() >> 33)
        let f = Float(bits) / Float(UInt32.max)   // [0, 1]
        return f * 2.0 - 1.0                       // [-1, 1]
    }
}

/// Build a random `dim`-dimensional unit-norm float vector using the given RNG.
private func randomVector(dim: Int, rng: inout SplitMix64) -> [Float] {
    var v = (0..<dim).map { _ in rng.nextFloat() }
    let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    guard norm > 0 else { return v }
    for i in v.indices { v[i] /= norm }
    return v
}

/// Cosine distance between two equal-length float vectors.
private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
        na  += a[i] * a[i]
        nb  += b[i] * b[i]
    }
    let denom = na.squareRoot() * nb.squareRoot()
    guard denom > 0 else { return 1.0 }
    let sim = max(-1.0, min(1.0, dot / denom))
    return 1.0 - sim
}

/// Exact brute-force top-k by cosine distance (oracle for recall quality tests).
private func bruteForceNearest(
    probe: [Float],
    corpus: [(itemID: String, vector: [Float])],
    k: Int
) -> Set<String> {
    let ranked = corpus
        .map { (id: $0.itemID, dist: cosineDistance(probe, $0.vector)) }
        .sorted { $0.dist < $1.dist }
    return Set(ranked.prefix(k).map(\.id))
}

// MARK: - Suite

@Suite("HNSWIndex — Lane D approximate nearest-neighbour")
struct HNSWIndexTests {

    private static let modelID = "hnsw-test-model"

    // MARK: - HI-1: basic insert and search

    /// Insert three vectors with clear cosine separations; search must rank nearest first.
    @Test("HI-1: insert then search returns correct nearest item")
    func hi1_insertAndSearchReturnsNearest() async throws {
        let idx = HNSWIndex()

        // x-axis (nearest to probe)
        await idx.insert(itemID: "near", modelID: Self.modelID, vector: [1, 0, 0])
        // y-axis (orthogonal to probe)
        await idx.insert(itemID: "mid", modelID: Self.modelID, vector: [0, 1, 0])
        // z-axis (also orthogonal, same cosine distance as mid)
        await idx.insert(itemID: "far", modelID: Self.modelID, vector: [0, 0, 1])

        // Probe along x-axis — "near" must rank first.
        let results = try await idx.search(probe: [1, 0, 0], modelID: Self.modelID, k: 3)
        #expect(results.isEmpty == false, "search must return at least one result")
        #expect(results[0].itemID == "near", "nearest item must rank first")
    }

    // MARK: - HI-2: tombstone excludes from search

    /// After tombstoning an item, search must not return it.
    @Test("HI-2: tombstoned item is excluded from search results")
    func hi2_tombstoneExcludesFromSearch() async throws {
        let idx = HNSWIndex()
        await idx.insert(itemID: "a", modelID: Self.modelID, vector: [1, 0])
        await idx.insert(itemID: "b", modelID: Self.modelID, vector: [1, 0])
        await idx.insert(itemID: "c", modelID: Self.modelID, vector: [0, 1])

        await idx.tombstone(itemID: "a")

        let results = try await idx.search(probe: [1, 0], modelID: Self.modelID, k: 3)
        let ids = results.map(\.itemID)
        #expect(!ids.contains("a"), "tombstoned item must not appear in search results")
    }

    // MARK: - HI-3: compact reduces live count

    /// compact() must remove tombstoned nodes so liveCount decreases.
    @Test("HI-3: compact reduces liveCount by the number of tombstoned nodes")
    func hi3_compactReducesLiveCount() async throws {
        let idx = HNSWIndex()
        await idx.insert(itemID: "x", modelID: Self.modelID, vector: [1, 0])
        await idx.insert(itemID: "y", modelID: Self.modelID, vector: [0, 1])
        await idx.insert(itemID: "z", modelID: Self.modelID, vector: [-1, 0])

        let beforeCompact = await idx.liveCount
        #expect(beforeCompact == 3, "all 3 nodes live before compaction")

        await idx.tombstone(itemID: "y")
        await idx.compact()

        let afterCompact = await idx.liveCount
        #expect(afterCompact == 2, "liveCount must decrease by 1 after compacting one tombstone")
    }

    // MARK: - HI-4: clear resets the index

    /// clear() must remove all nodes and reset entry point.
    @Test("HI-4: clear resets totalCount and liveCount to 0")
    func hi4_clearResetsIndex() async throws {
        let idx = HNSWIndex()
        await idx.insert(itemID: "p", modelID: Self.modelID, vector: [1.0, 2.0])
        await idx.insert(itemID: "q", modelID: Self.modelID, vector: [3.0, 4.0])

        let beforeClear = await idx.totalCount
        #expect(beforeClear == 2, "setup: 2 nodes before clear")

        await idx.clear()

        let afterTotal = await idx.totalCount
        let afterLive  = await idx.liveCount
        #expect(afterTotal == 0, "totalCount must be 0 after clear")
        #expect(afterLive == 0, "liveCount must be 0 after clear")
    }

    // MARK: - HI-5: recall quality vs exact oracle

    /// At n=200 random 64-dim unit vectors with efSearch=50, HNSW must return ≥90%
    /// of the exact oracle's top-10 neighbours across 10 distinct query vectors.
    ///
    /// This is the conformance gate: approximation is accepted only when the
    /// practical recall is high enough to make HNSW a useful substitute for
    /// the exact brute-force lane at/above the crossover threshold.
    @Test("HI-5: recall quality ≥ 90% at n=200, k=10, dim=64")
    func hi5_recallQuality() async throws {
        let dim = 64
        let n   = 200
        let k   = 10
        let queries = 10

        var rng = SplitMix64(state: 0xDEADBEEF_CAFEBABE)
        let idx = HNSWIndex(seed: 42)

        // Build corpus: n random unit vectors.
        var corpus: [(itemID: String, vector: [Float])] = []
        for i in 0..<n {
            let v = randomVector(dim: dim, rng: &rng)
            corpus.append((itemID: "item-\(i)", vector: v))
            await idx.insert(itemID: "item-\(i)", modelID: Self.modelID, vector: v)
        }

        // Query phase: compare HNSW top-k against the exact oracle for each probe.
        var totalRecall: Double = 0
        for _ in 0..<queries {
            let probe = randomVector(dim: dim, rng: &rng)
            let hnswResults = try await idx.search(probe: probe, modelID: Self.modelID, k: k)
            let hnswSet = Set(hnswResults.map(\.itemID))
            let oracleSet = bruteForceNearest(probe: probe, corpus: corpus, k: k)
            let overlap = Double(hnswSet.intersection(oracleSet).count)
            totalRecall += overlap / Double(k)
        }

        let meanRecall = totalRecall / Double(queries)
        #expect(meanRecall >= 0.90,
            "HNSW recall@\(k) must be ≥ 90% at n=\(n), got \(String(format: "%.1f", meanRecall * 100))%")
    }

    // MARK: - HI-6: VectorStore threshold crossover

    /// With hnswThreshold: 10 and 20 vectors inserted, findNearestFloat must route
    /// through HNSWIndex and return results consistent with cosine distance.
    ///
    /// At n=20 the efSearch=50 beam exceeds the corpus size, so HNSW behaves as an
    /// exact scan — results are rank-correct, not merely approximate.
    @Test("HI-6: VectorStore routes findNearestFloat through HNSW above threshold")
    func hi6_vectorStoreHNSWCrossover() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            // Low threshold so 20 insertions suffice to activate HNSW.
            let store = VectorStore(storage: storage, hnswThreshold: 10)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let dim = 8

            // Insert 20 random vectors into the same modelID partition.
            var rng = SplitMix64(state: 0x12345678_ABCDEF00)
            var corpus: [(itemID: String, vector: [Float])] = []
            for i in 0..<20 {
                let v = randomVector(dim: dim, rng: &rng)
                corpus.append((itemID: "item-\(i)", vector: v))
                try await store.addPayload(
                    itemID: "item-\(i)", vectorIndex: 0,
                    payload: VectorPayload(floats: v),
                    modelID: "cross-model", modelVersion: "1",
                    filedAt: now
                )
            }

            // Pick a probe clearly nearest to item-0's direction.
            let probe = corpus[0].vector

            // findNearestFloat triggers lazy build of FloatBruteForceIndex and
            // then HNSW (since 20 >= threshold 10). At n=20, efSearch=50 >> n,
            // so the approximate index returns the exact top-k.
            let results = try await store.findNearestFloat(
                probe: probe, modelID: "cross-model", limit: 5)

            #expect(results.isEmpty == false,
                "findNearestFloat must return results after threshold crossover")
            // item-0 is the exact direction of the probe → must rank first.
            #expect(results[0].itemID == "item-0",
                "probe direction must rank nearest after HNSW routing")
        }
    }
}
